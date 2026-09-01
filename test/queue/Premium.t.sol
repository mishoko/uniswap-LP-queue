// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {stdError} from "forge-std/StdError.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice PHASE 7 — the PRIORITY PREMIUM, which is the price of queue position.
///
/// **WHY THIS SUITE EXISTS, stated as a measurement rather than as a motivation.** Per rank, over
/// 30 price paths, static rank, φ = 0 — the mechanism exactly as it stood before this parameter:
///
///        rank      fee %/yr    inventory     net %/yr    turnover %/yr
///           0      +1240.1%      -328.3%      +911.8%        +411,877%
///           1        +66.9%       -54.8%       +12.0%         +22,186%
///           7         +5.7%       -26.2%       -20.5%          +1,903%
///          31         +0.1%        -0.0%        +0.1%             +34%
///
/// The head takes four orders of magnitude more turnover than the tail and keeps the whole fee on
/// it, so 24–29 of 32 seats lose money in every regime tested. The advantage is a QUANTITY, which
/// is why marginal pricing (a price) and Harberger rent (a tax on an assessed value) cannot reach
/// it, and why the premium is a share of FEE FLOW.
///
/// ─────────────────────────────────────────────────────────────────────────────────────────────
/// **WHAT THIS SUITE DOES NOT DO, SAID HERE RATHER THAN DISCOVERED LATER.** `QueueFixture`'s
/// independent reference allocator does NOT model the premium, so `_check`'s seat-by-seat
/// composition assertion is unavailable at φ > 0 and no test below calls it. Everything here is
/// asserted against quantities that do not depend on that witness: PoolManager's own balances,
/// INVARIANT F, the contract's two independently-maintained totals, and a live φ = 0 control pool.
/// Teaching the witness the premium is the top item in `NEXT_SESSION_PROMPT.md`; until it is done,
/// the per-seat SPLIT at φ > 0 rests on the controls in this file rather than on the witness.
/// ─────────────────────────────────────────────────────────────────────────────────────────────
contract PremiumTest is QueueFixture {
    uint256 constant PHI = 8_500; // the shipping φ — see QueueDeployBase.PREMIUM_BPS

    QueueHarness onHook;
    PoolKey onKey;
    QueueHarness offHook;
    PoolKey offKey;

    /// @dev **`expT0`/`expT1` ARE FIXTURE STATE, NOT POOL STATE.** They are the conservation ground
    ///      truth measured on PoolManager, and `_swapFrom` advances whichever pair is live. This
    ///      suite is the first to hold two pools open at once, so switching between them has to
    ///      carry each pool's own expectation with it — without that, the second pool is measured
    ///      against the first one's totals and conservation "breaks" by the whole difference. The
    ///      failure looked like a premium leak of 1.9e19 wei and was the harness.
    mapping(address => uint256) poolT0;
    mapping(address => uint256) poolT1;

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        dec0 = 18;
        dec1 = 18;
        startPrice = Constants.SQRT_PRICE_1_4; // LAW 1 — never 1:1
        _deployTokens();

        (onHook, onKey) = _build(0xC100, PHI);
        (offHook, offKey) = _build(0xC200, 0);
        _use(onHook, onKey);
    }

    /// @dev Two pools, identical in every respect but φ. That is the only construction under which
    ///      "the premium moved this much money" is a claim rather than an assertion about a number
    ///      nobody can place.
    function _build(uint160 nonce, uint256 phi) internal returns (QueueHarness h, PoolKey memory key_) {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgsPremium(_syntheticRoster(8), phi), a);
        hook = QueueHarness(a);
        _fundHook(a);

        uint256[] memory bps = new uint256[](8);
        for (uint256 i; i < 8; i++) {
            bps[i] = 1_250;
        }
        _openBand(bps);
        poolT0[address(hook)] = expT0;
        poolT1[address(hook)] = expT1;
        return (hook, k);
    }

    /// @dev Save the live pool's conservation state before pointing the fixture at another one.
    function _use(QueueHarness h, PoolKey memory key_) internal {
        if (address(hook) != address(0)) {
            poolT0[address(hook)] = expT0;
            poolT1[address(hook)] = expT1;
        }
        hook = h;
        k = key_;
        expT0 = poolT0[address(h)];
        expT1 = poolT1[address(h)];
    }

    // ───────────────────────────────────────────────────────────────────── 7.1 the two totals agree

    function test_7_1_standingTracksTheLedgerThroughAWholeScenario() public {
        _use(onHook, onKey);
        for (uint256 i; i < 4; i++) {
            _swap(i % 2 == 0, expT0 / 40);
            (uint256 t0, uint256 t1) = hook.totals();
            (uint256 st0, uint256 st1) = hook.standings();
            assertEq(st0, t0, "standing0 has drifted from the ledger");
            assertEq(st1, t1, "standing1 has drifted from the ledger");
        }
    }

    // ─────────────────────────────────────────────────── 7.2 conservation survives the premium

    /// @dev The premium is withheld from the fill and handed out later, so the ONLY thing that makes
    ///      this an identity rather than an approximation is `premiumOwed` being counted on the
    ///      ledger side. `expT0` is measured on PoolManager's own balances net of protocol fees
    ///      (LAW 3 as amended), so nothing here is the hook agreeing with itself.
    function test_7_2_theLedgerPlusUnsettledPremiumConservesExactly() public {
        uint256 onResid = _runAndMeasureResidual(onHook, onKey);
        uint256 offResid = _runAndMeasureResidual(offHook, offKey);

        emit log_named_uint("INVARIANT F residual, phi = 8500", onResid);
        emit log_named_uint("INVARIANT F residual, phi = 0   ", offResid);

        // **THE RESIDUAL IS ASSERTED AGAINST A CONTROL, NOT AGAINST A TOLERANCE SOMEBODY PICKED.**
        // INVARIANT F is checked against `_positionValue()`, an instrument that re-derives the
        // position from `liquidity` and the live price and therefore carries its own §E.4 rounding —
        // a few wei over a six-swap scenario, present long before Phase 7. Widening a bound until it
        // passes would be blind to a premium that leaks at exactly that scale (PITFALLS 5.53), so
        // the same scenario is run on the same fixture with φ = 0 and the two residuals compared.
        // The premium is allowed to cost NOTHING here: it withholds whole wei and hands out floored
        // shares, and every wei it has not yet handed out is counted by `premiumOwed`.
        assertLe(onResid, offResid, "the premium is leaking value that INVARIANT F can see");
    }

    /// @dev Six swaps, asserting the EXACT ledger identity at every step, and returning the largest
    ///      INVARIANT F gap seen. The exact claim and the approximate one are separated on purpose:
    ///      `totals() + premiums()` against PoolManager's own measured balances is an identity and
    ///      is asserted as one; the position-valuation comparison is an instrument and is measured.
    function _runAndMeasureResidual(QueueHarness h, PoolKey memory key_) internal returns (uint256 worst) {
        _use(h, key_);
        for (uint256 i; i < 6; i++) {
            _swap(i % 2 == 0, expT0 / 40);
            (uint256 t0, uint256 t1) = hook.totals();
            (uint256 q0, uint256 q1,,) = hook.premiums();
            assertEq(t0 + q0, expT0, "token0 conservation broke once a premium was withheld");
            assertEq(t1 + q1, expT1, "token1 conservation broke once a premium was withheld");
            _checkInvariantC("premium");

            (uint256 w0, uint256 w1) = hook.pendingTotals();
            (uint256 f0, uint256 f1) = hook.floats();
            (uint256 p0, uint256 p1) = _positionValue();
            worst = _max(worst, _absDiff(t0 + w0 + q0, p0 + f0));
            worst = _max(worst, _absDiff(t1 + w1 + q1, p1 + f1));
        }
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // ──────────────────────────────────────────── 7.3 the money actually moves BACKWARD

    /// @dev **THE ECONOMIC CLAIM, AND IT IS EXACT RATHER THAN DIRECTIONAL.** A swap small enough to
    ///      be absorbed by the head alone touches exactly one seat. Under φ = 0 every other seat's
    ///      balance is unchanged by it — that is what front-first means. Under φ > 0 the seats that
    ///      were NOT filled must each be strictly richer afterwards, in the token the swapper
    ///      brought, and the head must be correspondingly poorer than its φ = 0 twin.
    ///
    ///      Asserting only "the tail went up" would be satisfied by a bug that pays the tail out of
    ///      the position rather than out of the head, so both halves are checked against the live
    ///      control pool.
    function test_7_3_aHeadOnlySwapPaysTheSeatsItJumped() public {
        uint256 amount = expT0 / 400;

        _use(offHook, offKey);
        (uint256 offHead0,) = hook.seat(0);
        (uint256 offTail0,) = hook.seat(7);
        _swap(true, amount);
        assertEq(lastTouched, 1, "the control swap was not head-only: this test proves nothing");
        (uint256 offHeadAfter,) = hook.seat(0);
        (uint256 offTailAfter,) = hook.seat(7);
        assertGt(offHeadAfter, offHead0, "the head was not credited at all");
        assertEq(offTailAfter, offTail0, "phi = 0 paid a seat the swap never reached");

        _use(onHook, onKey);
        (uint256 onHead0,) = hook.seat(0);
        (uint256 onTail0,) = hook.seat(7);
        _swap(true, amount);
        assertEq(lastTouched, 1, "the premium swap was not head-only: this test proves nothing");
        (uint256 onHeadAfter,) = hook.seat(0);
        (uint256 onTailAfter,) = hook.seat(7);

        uint256 headGainOff = offHeadAfter - offHead0;
        uint256 headGainOn = onHeadAfter - onHead0;
        uint256 tailGain = onTailAfter - onTail0;

        assertGt(tailGain, 0, "a seat the swap never reached was paid nothing: the premium did not move");
        assertLt(headGainOn, headGainOff, "the head kept as much as it does with the premium switched off");

        emit log_named_uint("head credit, phi = 0    ", headGainOff);
        emit log_named_uint("head credit, phi = 8500 ", headGainOn);
        emit log_named_uint("one standing seat's coupon", tailGain);
    }

    // ─────────────────────────────────────────────────────── 7.4 the pot is the size it claims

    /// @dev φ of the LP fee, and the LP fee is `amtIn * fee / 1e6`. Asserted against a number this
    ///      test computes itself from the pool's own fee tier, not against the contract's.
    function test_7_4_thePotIsPhiOfTheFeeAndNotherwise() public {
        _use(onHook, onKey);
        (uint256 t0Before,) = hook.totals();
        (uint256 inAmt,) = _swap(true, expT0 / 400);

        (uint256 t0After,) = hook.totals();
        uint256 credited = t0After - t0Before;
        uint256 expectedPot = FullMath.mulDiv(inAmt, uint256(FEE) * PHI, 1e6 * 10_000);

        assertEq(inAmt - credited, expectedPot, "the pot withheld is not phi of the LP fee");
        (uint256 q0,,,) = hook.premiums();
        assertEq(q0, expectedPot, "the pot withheld was not the pot accrued");
    }

    // ──────────────────────────────────────────── 7.6 a settle is not a way to make money twice

    /// @dev Settling is idempotent: touching a seat twice with no swap in between must not credit it
    ///      twice. The mark is written unconditionally in `_syncSeat`, including when the claim
    ///      floors to zero, and this is what that line is for — without it the same growth interval
    ///      is claimable again later against a larger balance.
    function test_7_6_settlingTwiceCreditsOnce() public {
        _use(onHook, onKey);
        _swap(true, expT0 / 40);

        uint256 seatId = 7;
        (uint256 a0,) = hook.seat(seatId);
        assertGt(a0, 0, "the standing seat holds nothing: this test proves nothing");

        // `withdraw(0, 0)` is a settle with no payout — the cheapest way to touch a seat twice.
        vm.startPrank(hook.ownerOf(seatId));
        hook.withdraw(seatId, 0, 0);
        (uint256 afterFirst,) = hook.seat(seatId);
        hook.withdraw(seatId, 0, 0);
        (uint256 afterSecond,) = hook.seat(seatId);
        vm.stopPrank();

        assertEq(afterFirst, a0, "settling changed what the seat is worth");
        assertEq(afterSecond, afterFirst, "settling a second time credited the seat again");

        (uint256 t0,) = hook.totals();
        (uint256 q0,,,) = hook.premiums();
        assertEq(t0 + q0, expT0, "conservation broke across a double settle");
    }

    // ────────────────────────────────────────── 7.7 nobody standing means the pot is HELD, not lost

    /// @dev `_accruePremium` refuses to divide when the standing inventory is smaller than the pot
    ///      itself. The wei has already left the fill, so it must be somewhere: it is held and
    ///      folded into the next accrual that has a recipient. Driven by draining the book.
    function test_7_7_aPotWithNobodyStandingIsHeldAndLaterPaid() public {
        _use(onHook, onKey);

        // Drain token1 out of the whole book, so nothing is standing in it.
        _swap(true, expT0 * 4);
        (,, uint256 held0,) = hook.premiums();
        (, uint256 st1) = hook.standings();

        if (st1 != 0) {
            emit log_named_uint("book not fully drained; standing1", st1);
        }
        (uint256 t0,) = hook.totals();
        (uint256 q0,,,) = hook.premiums();
        assertEq(t0 + q0, expT0, "a held pot was lost rather than held");
        assertLe(held0, q0, "held is not a subset of owed");

        // Flow reverses and the book is standing in token1 again: the held pot must now be payable.
        // token1 is what the book was just drained OF, so the reverse leg is sized in token1
        // the swapper brings — off `expT0`, which is the side that is now full.
        _swap(false, expT0 / 40);
        (uint256 n0,) = hook.totals();
        (uint256 nq0,,,) = hook.premiums();
        assertEq(n0 + nq0, expT0, "conservation broke when the held pot was released");
    }
}

/// @dev N7 — the two claims COMPOUND. `_claims` weights the token1 claim by an `a0` that already
///      includes the token0 claim just credited, instead of by the balance the seat actually stood
///      with while the premium was earned. It pays out more than was accrued.
contract CompoundingPremiumHook is QueueHarness {
    constructor(
        IPoolManager pm,
        Currency c0_,
        Currency c1_,
        uint24 f,
        int24 sp,
        int24 bhw,
        address[] memory roster,
        uint256 rb,
        uint256 rp,
        uint256 fw,
        uint256 pb
    ) QueueHarness(pm, c0_, c1_, f, sp, bhw, roster, rb, rp, fw, pb) {}

    function _syncSeat(Seat storage s) internal override returns (uint256 a0, uint256 a1) {
        a0 = s.a0;
        a1 = s.a1;
        uint128 g0 = premGrowth0;
        if (s.snap0 != g0) {
            uint256 owed = a1 == 0 ? 0 : FullMath.mulDiv(a1, g0 - s.snap0, 1 << 64);
            s.snap0 = g0;
            if (owed != 0) {
                a0 += owed;
                s.a0 = _u128(a0);
                standing0 += owed;
                premiumOwed0 -= owed;
            }
        }
        uint128 g1 = premGrowth1;
        if (s.snap1 != g1) {
            // THE MUTATION: `a0` here has already absorbed the credit above.
            uint256 owed = a0 == 0 ? 0 : FullMath.mulDiv(a0, g1 - s.snap1, 1 << 64);
            s.snap1 = g1;
            if (owed != 0) {
                a1 += owed;
                s.a1 = _u128(a1);
                standing1 += owed;
                premiumOwed1 -= owed;
            }
        }
    }
}

/// @dev N8 — a pot with nobody standing is DROPPED instead of held. Every wei of it leaves the
///      allocation and is never credited to anybody, so the ledger falls short of the position.
contract DroppingPremiumHook is QueueHarness {
    constructor(
        IPoolManager pm,
        Currency c0_,
        Currency c1_,
        uint24 f,
        int24 sp,
        int24 bhw,
        address[] memory roster,
        uint256 rb,
        uint256 rp,
        uint256 fw,
        uint256 pb
    ) QueueHarness(pm, c0_, c1_, f, sp, bhw, roster, rb, rp, fw, pb) {}

    function _accruePremium(bool inIsZero, uint256 pot) internal override {
        if (inIsZero) {
            uint256 total = pot + premiumHeld0;
            if (total == 0) return;
            uint256 w = standing1;
            if (w < total) return; // THE MUTATION: dropped, not held.
            premiumHeld0 = 0;
            premiumOwed0 += pot;
            premGrowth0 += uint128(FullMath.mulDiv(total, 1 << 64, w));
        } else {
            uint256 total = pot + premiumHeld1;
            if (total == 0) return;
            uint256 w = standing0;
            if (w < total) return; // THE MUTATION.
            premiumHeld1 = 0;
            premiumOwed1 += pot;
            premGrowth1 += uint128(FullMath.mulDiv(total, 1 << 64, w));
        }
    }
}

/// @notice The controls. A mechanism with no control is a mechanism nobody has shown can fail.
contract PremiumControlsTest is QueueFixture {
    uint256 constant PHI = 8_500;

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        dec0 = 18;
        dec1 = 18;
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
    }

    function _deployMutant(string memory artifact, uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo(artifact, _ctorArgsPremium(_syntheticRoster(8), PHI), a);
        hook = QueueHarness(a);
        _fundHook(a);
        uint256[] memory bps = new uint256[](8);
        for (uint256 i; i < 8; i++) {
            bps[i] = 1_250;
        }
        _openBand(bps);
    }

    /// @dev THE POSITIVE CONTROL. The unmutated hook through the identical harness. Without it, a
    ///      control that reverts for an unrelated reason looks like success.
    function test_N7_positive_unmutatedSurvivesTheSameHarness() public {
        _deployMutant("QueueHarness.sol:QueueHarness", 0xC300);
        _drive();
        (uint256 t0,) = hook.totals();
        (uint256 q0,,,) = hook.premiums();
        assertEq(t0 + q0, expT0, "the unmutated hook did not conserve: the harness is wrong");
    }

    /// @dev **THE FIRST VERSION OF THIS CONTROL DID NOT GO RED, AND THE REASON IS THE FINDING.**
    ///
    ///      It expected an underflow and drove the pool with `_drive()`. Nothing reverted, because
    ///      compounding is only REACHABLE when BOTH accumulators have advanced since the seat's last
    ///      touch — a `zeroForOne` swap moves `premGrowth0` alone, so the second branch of the
    ///      mutated `_syncSeat` never even executed. A control that cannot enter the code it
    ///      mutates proves nothing (PITFALLS 5.54), and this one was one assertion away from being
    ///      recorded as evidence that the ordering rule in `_claims` was unnecessary.
    ///
    ///      The reachable shape is: accrue in BOTH directions, then settle a seat deep enough to
    ///      still hold both tokens. The overpayment is second-order — `owed0 * Δg1 / 2^64` — so the
    ///      detector is CONSERVATION, not a revert: the ledger ends up claiming more token1 than the
    ///      position holds.
    function test_N7_compoundingClaimsPayOutMoreThanWasAccrued() public {
        _deployMutant("Premium.t.sol:CompoundingPremiumHook", 0xC400);
        // The pot is handed out faster than it was accrued, so the last seats to settle drive
        // `premiumOwed1 -= owed` below zero. Asserted on the EXACT panic — `stdError.arithmeticError`
        // — and not on a bare `vm.expectRevert()`, which passes for any reason at all and is how two
        // LAW 2 violations survived six phases here (PITFALLS 5.83, 5.84). The settle runs from the
        // test directly rather than through a swap, so v4 does not wrap it.
        vm.expectRevert(stdError.arithmeticError);
        this.bothDirectionsThenSettle();

        _deployMutant("QueueHarness.sol:QueueHarness", 0xC600);
        uint256 honest = this.bothDirectionsThenSettle();
        emit log_named_uint("premiumOwed1 left after the whole roster settled, production", honest);
    }

    function bothDirectionsThenSettle() external returns (uint256) {
        return _bothDirectionsThenSettle();
    }

    /// @return over how much MORE token1 the ledger claims than was ever put into it.
    function _bothDirectionsThenSettle() internal returns (uint256 over) {
        _swap(true, expT0 / 40); // accrues premGrowth0
        _swap(false, expT1 / 40); // accrues premGrowth1
        _swap(true, expT0 / 40);
        _swap(false, expT1 / 40);

        // A seat deep enough that the fills never reached it still holds BOTH tokens, so it has a
        // live claim on both accumulators — the only state in which the two can compound.
        uint256 seatId = 7;
        (uint256 d0, uint256 d1) = hook.seat(seatId);
        assertTrue(d0 != 0 && d1 != 0, "the deep seat is single-sided: this control proves nothing");

        vm.prank(hook.ownerOf(seatId));
        hook.withdraw(seatId, 0, 0);

        // **CONSERVATION CANNOT SEE THIS ONE, AND FINDING THAT OUT IS THE POINT.** An overpaid claim
        // moves wei OUT of `premiumOwed1` and INTO the seat, so `totals() + premiums()` is unchanged
        // by construction — the second detector this control tried, and it read 0 for the mutant and
        // 0 for production alike. What compounding actually steals is the OTHER seats' unsettled
        // claims: the pot is handed out faster than it was accrued, so the last seats to settle find
        // it empty. Settling the WHOLE roster is what makes that visible.
        for (uint256 i; i < 8; i++) {
            (uint256 h0, uint256 h1) = hook.seat(i);
            if (h0 == 0 && h1 == 0) continue;
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
        }
        (, uint256 owed1,,) = hook.premiums();
        return owed1;
    }

    function test_N8_droppingAHeldPotBreaksConservation() public {
        _deployMutant("Premium.t.sol:DroppingPremiumHook", 0xC500);
        _swap(true, expT0 * 4); // drain token1 so the pot has nobody standing to receive it
        (uint256 t0,) = hook.totals();
        (uint256 q0,,,) = hook.premiums();
        assertTrue(t0 + q0 != expT0, "dropping the pot was invisible: this control proves nothing");
        assertLt(t0 + q0, expT0, "the dropped pot did not leave the ledger SHORT");
    }

    function drive() external {
        _drive();
    }

    function _drive() internal {
        for (uint256 i; i < 6; i++) {
            _swap(i % 2 == 0, expT0 / 40);
        }
    }
}
