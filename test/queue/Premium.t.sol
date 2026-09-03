// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
}
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
/// **THAT GAP IS CLOSED AS OF PHASE 8, AND THE OLD WARNING IS KEPT HERE BECAUSE IT SAYS WHAT THIS
/// SUITE USED TO REST ON.** It read: "`QueueFixture`'s independent reference allocator does NOT
/// model the premium, so `_check`'s seat-by-seat composition assertion is unavailable at φ > 0 and
/// no test below calls it ... the per-seat SPLIT at φ > 0 rests on the controls in this file rather
/// than on the witness."
///
/// `_refAllocate` now models it. The witness computes each seat's share as the TRUE RATIONAL
/// pro-rata `floor(total_j·L_i/w_j)` — no accumulator, no fixed point, so it cannot agree with
/// `_accruePremium` by construction — and `_assertPremiumClaim` bounds the residual against the
/// hook's two floors in closed form. `test_7_1` drives it here; `PremiumDecimals.t.sol` drives it on
/// the 18/6 pool the deploy script actually ships; `PremiumWitness.t.sol` is the evidence that it
/// can go RED, with four one-line mutants each producing a gap of 1e20 wei against an allowance of
/// single wei. Everything below still holds independently: PoolManager's own balances, INVARIANT F,
/// the contract's two internally-maintained totals, and a live φ = 0 control pool.
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
    /// @dev **SINCE PHASE 8 THIS IS THE WHOLE WITNESS, NOT TWO NUMBERS.** `_refAllocate` now models
    ///      the premium, so a pool switch has to carry the seat ledger, the depth ledger, the
    ///      pending claims, the interval counts, the held pots AND φ itself — fourteen arrays and
    ///      ten scalars. `_saveWitness`/`_loadWitness` move the lot in one call precisely so that
    ///      this list cannot go stale the next time the witness grows a field.

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
        _saveWitness(address(hook));
        return (hook, k);
    }

    /// @dev Save the live pool's conservation state before pointing the fixture at another one.
    function _use(QueueHarness h, PoolKey memory key_) internal {
        if (address(hook) != address(0)) _saveWitness(address(hook));
        hook = h;
        k = key_;
        _loadWitness(address(h));
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
            // **THE INDEPENDENT WITNESS, WHICH THIS SUITE COULD NOT CALL BEFORE PHASE 8.** The two
            // assertions above are the contract's two internal writers agreeing with each other;
            // this one is a model that was never told how the contract works.
            _check(string.concat("7.1 swap ", vm.toString(i)));
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

    // ─────────────────────────── 7.7 a fill that sweeps the WHOLE BOOK pays the pot to the roster

    /// @notice **THIS TEST USED TO ASSERT THE DEFECT AS THE SPECIFICATION, AND THE SCENARIO IT
    ///         DRIVES IS EXACTLY THE ONE THAT BRICKED THE POOL.** It is inverted rather than
    ///         deleted: the executed scenario is the evidence the fix was needed.
    ///
    /// @dev It was written as "a pot with nobody standing is HELD, and later paid", and it drove
    ///      that state by draining token1 out of the entire book. On a fill that reaches every
    ///      standing seat, `_settlePremium` excluded every one of them, `w == standingL - lTouched`
    ///      was zero to the wei, and `_accruePremium` took its HOLD branch. **A held pot is money
    ///      the position holds that `standing0`/`standing1` does not count**, so the ledger goes
    ///      short of what the position can pay and the next fill in the other direction reverts
    ///      `QueueUnderflow` from inside `_afterSwap` — a bricked pool, not a lost wei
    ///      (`test_M7f`, `test_M13`).
    ///
    ///      The rule now: **"the payer does not pay itself" has no meaning on a fill that swept the
    ///      whole book**, because there is no seat that did not pay. The pot is divided over the
    ///      FULL `standingL` — everybody, payers included — and no mark moves, which is the only
    ///      pairing that conserves (`test_M7d`'s lesson, from the other side).
    ///
    ///      Asserted three ways, because "conserved", "distributed" and "claimable" are three
    ///      different claims: nothing is held, the accumulator moved, and every seat that
    ///      contributed depth can actually settle a share of it.
    function test_7_7_aFillThatSweepsTheWholeBookPaysThePotToTheRoster() public {
        _use(onHook, onKey);

        (uint256 g0Before,) = hook.growths();
        // Sized BEFORE the sweep: the drain drives `expT1` to dust, and `expT1 / 40` taken after it
        // is zero, which reverts the router rather than testing anything (7.12's lesson).
        uint256 base1 = expT1;

        // Drain token1 out of the whole book. Every standing seat is a payer, so this is the swept
        // book and nothing may be withheld from it.
        _swap(true, expT0 * 4);

        (uint256 k0Cur, uint256 k1Cur) = hook.cursors();
        k0Cur;
        assertGe(k1Cur, 7, "the fill did not reach the tail: this is not a whole-book sweep");

        (uint256 t0,) = hook.totals();
        (uint256 q0,, uint256 held0,) = hook.premiums();
        assertGt(q0, 0, "nothing was withheld: this test proves nothing");
        assertEq(t0 + q0, expT0, "a swept-book pot was lost rather than distributed");

        // THE INVERSION. It used to be `assertGt(held0, 0)`.
        assertEq(held0, 0, "the swept-book pot was HELD: the ledger cannot source the next fill");
        (uint256 g0After,) = hook.growths();
        assertGt(g0After, g0Before, "the accumulator did not move: the pot reached nobody");

        // **AND IT IS CLAIMABLE, WHICH IS A DIFFERENT CLAIM FROM "IT WAS ACCRUED"** (LAW 3, second
        // corollary). A settle with no payout credits the seat its share; the shares must sum to
        // the pot up to the per-seat floor, and every seat that contributed depth must get some.
        uint256 credited;
        uint256 paidSeats;
        for (uint256 i; i < 8; i++) {
            (uint256 b0,) = hook.rawSeat(i);
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
            (uint256 a0,) = hook.rawSeat(i);
            if (a0 > b0) {
                credited += a0 - b0;
                paidSeats++;
            }
        }
        assertEq(paidSeats, 8, "some seat that contributed depth was paid nothing out of the pot");
        // The IDENTITY, not a bound: the pot was 8 shares each floored by at most one wei.
        assertLe(credited, q0, "the seats were credited MORE than was ever withheld");
        assertGe(credited + 8, q0, "the seats were credited less than the pot minus its floors");

        (uint256 f0,) = hook.totals();
        (uint256 fq0,,,) = hook.premiums();
        assertEq(f0 + fq0, expT0, "conservation broke across the swept-book distribution");

        // **AND THE POOL STILL TRADES**, which is what the old behaviour destroyed. The reverse leg
        // is exactly the swap that used to revert `QueueUnderflow` from inside `_afterSwap`.
        _swap(false, base1 / 40);
        (uint256 z0,) = hook.totals();
        (uint256 zq0,,,) = hook.premiums();
        assertEq(z0 + zq0, expT0, "conservation broke on the swap that used to brick the pool");
    }

    // ─────────────────────────────── 7.8 a claim that rounds to nothing still consumes its interval

    /// @dev **THE MARK IS WRITTEN EVEN WHEN THE CLAIM FLOORS TO ZERO, AND M83 SURVIVED THE ENTIRE
    ///      SUITE UNTIL THIS TEST EXISTED.** A seat too small to earn a whole wei over some interval
    ///      still has that interval consumed; leaving its mark behind lets the SAME growth be
    ///      claimed again later against a balance that has since grown. Conservation is blind to it
    ///      — the wei moves out of `premiumOwed` and into the seat, so the books tie out — and
    ///      `test_7_6` is blind to it too, because that one settles a seat whose claim is non-zero.
    ///
    ///      Reachable because a claim is `a1 * pot / standing1`: a seat holding a few thousand wei
    ///      of token1 against a book holding 1e20 earns a floored zero on an ordinary swap.
    function test_7_8_aClaimThatRoundsToZeroStillConsumesItsInterval() public {
        _use(onHook, onKey);
        uint256 seatId = 7;
        address owner = hook.ownerOf(seatId);

        // Shrink the seat until a swap cannot pay it a whole wei.
        (uint256 h0, uint256 h1) = hook.seat(seatId);
        vm.prank(owner);
        hook.withdraw(seatId, h0, h1 - 1_000);
        (, uint256 small1) = hook.seat(seatId);
        assertEq(small1, 1_000, "the seat was not shrunk: this test proves nothing");

        _swap(true, expT0 / 40); // accrues premGrowth0; this seat's share floors to zero

        vm.prank(owner);
        hook.withdraw(seatId, 0, 0); // settle: nothing owed, but the interval is spent
        (uint256 afterSettle0, uint256 afterSettle1) = hook.seat(seatId);

        // Grow the seat, WITHOUT any swap in between — so there is no new growth for it to earn.
        uint256 top0 = 5e18;
        uint256 top1 = 5e18;
        deal(Currency.unwrap(c0), owner, top0);
        deal(Currency.unwrap(c1), owner, top1);
        vm.startPrank(owner);
        IERC20Like(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        IERC20Like(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        hook.addToSeat(seatId, top0, top1);
        vm.stopPrank();

        // **THE EXPECTATION IS COMPUTED HERE, NOT READ BACK FROM THE CONTRACT.** The first version
        // of this assertion compared `seat()` before the settle against `seat()` after it, and M83
        // survived it: `seat()` REPORTS the pending claim, so a stale mark inflated both sides
        // equally and the comparison was blind by construction. That is the tautological-witness
        // mistake this project keeps writing down (PITFALLS 5.34) — two numbers from the same
        // source cannot check each other.
        //
        // The seat was settled to zero owing, then funded, with no swap in between. So it owns
        // exactly what it had plus what it deposited, and nothing else.
        (uint256 got0, uint256 got1) = hook.seat(seatId);
        assertEq(got0, afterSettle0 + top0, "the seat was credited token0 for an interval it was not standing for");
        assertEq(got1, afterSettle1 + top1, "the seat was credited token1 for an interval it was not standing for");
        assertGt(got0, afterSettle0, "the deposit did not land: this test proves nothing");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 7.10-7.12 — THE HOLD BRANCH. A pot that is withheld must reach somebody, eventually.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev **THE INVARIANT ALL THREE OF THESE ASSERT.** Every wei `_accruePremium` takes out of a
    ///      fill is added to `premiumOwed`. It is only ever made PAYABLE through `premGrowth`, and
    ///      only ever RETAINED through `premiumHeld`. So a pot that moves neither is STRANDED: it is
    ///      conserved — INVARIANT F counts it on the ledger side — and it is claimable by nobody,
    ///      ever. "Conserved" and "payable" are two different claims, and this is the second one.
    function _assertPotWentSomewhere(bool inIsZero, uint256 g0, uint256 g1, uint256 h0, uint256 h1, string memory tag)
        internal
        view
    {
        (,, uint256 nh0, uint256 nh1) = hook.premiums();
        (uint256 ng0, uint256 ng1) = hook.growths();
        bool moved = inIsZero ? (ng0 > g0 || nh0 > h0) : (ng1 > g1 || nh1 > h1);
        assertTrue(moved, string.concat(tag, ": neither made claimable nor held - the pot is STRANDED"));
    }

    /// @notice A pot too small to move the accumulator was DESTROYED rather than kept.
    ///
    /// @dev `premGrowth += mulDiv(total, 2^64, w)` floors. On a book with `w` standing, any pot
    ///      below `w / 2^64` increments the accumulator by ZERO — and the pre-fix code set
    ///      `premiumHeld = 0` on the very same branch, so the wei left the allocation, entered
    ///      `premiumOwed`, and became unreachable. Here `w` is ~1e21, so the threshold is around
    ///      54,000 wei of pot, which an ordinary small swap is comfortably underneath. It needs no
    ///      attacker: every tiny swap silently burnt its own priority premium.
    function test_7_10_theSmallestPossiblePotReachesTheAccumulator() public {
        _use(onHook, onKey);
        (uint256 g0, uint256 g1) = hook.growths();
        (uint256 owedBefore,, uint256 h0, uint256 h1) = hook.premiums();

        // token0 in: the pot is token0 and the weight is token1 standing.
        _swap(true, _smallestPottedInput());

        (uint256 owedAfter,, uint256 h0After,) = hook.premiums();
        uint256 pot = owedAfter - owedBefore;
        (, uint256 w) = hook.standings();
        _assertSmallestPotRegisters(pot, w, "token0");
        h0After;
        _assertPotWentSomewhere(true, g0, g1, h0, h1, "tiny token0 pot");
    }

    /// @dev The MIRROR. It exists because the same rule living in two branches has been wrong in
    ///      exactly one of them four times on this project (PITFALLS 5.37, 5.50, 5.52 twice), and
    ///      nothing about `test_7_10` passing says anything at all about this branch.
    function test_7_11_theSmallestPossiblePotReachesTheAccumulator_token1Branch() public {
        _use(onHook, onKey);
        (uint256 g0, uint256 g1) = hook.growths();
        (, uint256 owedBefore, uint256 h0, uint256 h1) = hook.premiums();

        // token1 in: the pot is token1 and the weight is token0 standing.
        _swap(false, _smallestPottedInput());

        (, uint256 owedAfter,,) = hook.premiums();
        uint256 pot = owedAfter - owedBefore;
        (uint256 w,) = hook.standings();
        _assertSmallestPotRegisters(pot, w, "token1");
        _assertPotWentSomewhere(false, g0, g1, h0, h1, "tiny token1 pot");
    }

    /// @dev The SMALLEST input that still withholds a whole wei of premium, derived from the
    ///      contract's own parameters rather than picked. `_premiumOn` is
    ///      `mulDiv(amtIn, fee * phi, 1e6 * 10_000)`, so this is its inverse at a pot of one, rounded
    ///      up. A hardcoded size here would be a second unproven number, and it would silently stop
    ///      exercising the branch the day the fixture's book or phi changed.
    function _smallestPottedInput() internal pure returns (uint256) {
        uint256 d = uint256(FEE) * PHI;
        return (1e6 * 10_000 + d - 1) / d;
    }

    /// @dev **WHAT THESE TWO TESTS ASSERT CHANGED IN PHASE 8, AND THE OLD VERSION IS RECORDED HERE
    ///      RATHER THAN QUIETLY REPLACED.** They were written against an X64 accumulator, where the
    ///      SMALLEST POSSIBLE POT — one wei — moved `premGrowth` by `mulDiv(1, 2^64, 2.5e19) == 0`
    ///      and the wei was then destroyed outright. They asserted the precondition (`the pot really
    ///      does round away here`) and then that it was HELD rather than lost.
    ///
    ///      At X128 that precondition is FALSE and cannot be made true through the public API: it
    ///      needs `w > total * 2^128`, and a book of `uint128`-bounded balances cannot reach it. So
    ///      the tests now assert the thing the widening actually bought, which is strictly stronger:
    ///      **a one-wei pot REACHES THE ACCUMULATOR** instead of being stranded or held. Against the
    ///      old X64 code the same assertion is red.
    ///
    ///      The `inc == 0` branch survives in production as a floor, not as a live path. It is not
    ///      dead code with nothing depending on it (PITFALLS 5.49): `w == 0` still reaches it on any
    ///      swap that empties the book, and `test_N8` is the control proving that dropping instead
    ///      of holding there breaks conservation.
    function _assertSmallestPotRegisters(uint256 pot, uint256 w, string memory tag) internal {
        assertGt(pot, 0, string.concat(tag, ": no premium was withheld: this test proves nothing"));
        assertGt(w, 0, string.concat(tag, ": nothing is standing: this test proves nothing"));
        emit log_named_uint(string.concat(tag, " pot, wei"), pot);
        emit log_named_uint(string.concat(tag, " weight standing"), w);
        assertEq(pot, 1, string.concat(tag, ": this is not the smallest possible pot"));
        assertGt(
            FullMath.mulDiv(pot, hook.premiumQ(), w),
            0,
            string.concat(tag, ": a one-wei pot cannot register at this scale - the widening failed")
        );
    }

    /// @notice **A POT WITH NOBODY TO PAY IS HELD, AND THE WHOLE OF IT IS PAID BY THE NEXT ACCRUAL
    ///         THAT HAS A RECIPIENT.** Both directions, separately.
    ///
    /// @dev **WHAT THESE TWO TESTS USED TO ASSERT, AND WHY THE STATE THEY DRIVE HAS CHANGED TWICE.**
    ///      They were first written against the release rule `give = min(total, w)` and asserted the
    ///      closed form `heldAfter == heldBefore + pot − give`; that rule is gone, because bounding a
    ///      pot in the INCOMING token by a weight in the OUTGOING one is the units error that made
    ///      the premium inert on the shipped 18/6 pool (PITFALLS 5.126). They then reached the hold
    ///      branch by SWEEPING THE WHOLE BOOK, and that is what has changed now: a swept book no
    ///      longer holds, it distributes over the full denominator, because holding there is
    ///      precisely what bricked the pool at maturity (`test_M7f`, `test_7_7`).
    ///
    ///      **SO THE HOLD BRANCH IS NOW REACHABLE THROUGH EXACTLY ONE CONDITION — `standingL == 0`,
    ///      i.e. nobody has contributed depth at all — and these tests drive it there rather than
    ///      being re-specified away.** `_driveStandingLToZero` gets there with ordinary external
    ///      calls only (full exits, single-sided deposits that mint zero liquidity, and the
    ///      permissionless float sweep, which credits nobody); it asserts the state it reached, so a
    ///      route that stopped working would fail loudly instead of quietly testing something else.
    ///      **The property under test is unchanged: a held pot is DEFERRED, never destroyed, and it
    ///      is paid out whole.** The "nothing was held: this test proves nothing" guard is kept in
    ///      both — it is what caught the state becoming unreachable when the release rule changed
    ///      underneath these tests, and it is what caught it a second time here.
    function test_7_12_aHeldPotIsPaidInFullByTheNextAccrualWithARecipient() public {
        _use(onHook, onKey);
        _driveStandingLToZero(8, 10e18, 40e18);

        (uint256 owedBefore,,,) = hook.premiums();
        (uint256 g0Held,) = hook.growths();

        // Nobody has contributed depth, so this fill's pot has no recipient and must be HELD.
        _swap(true, 1e18);
        (uint256 owedAfterHold,, uint256 held0,) = hook.premiums();
        assertGt(held0, 0, "nothing was held: this test proves nothing");
        assertGt(owedAfterHold, owedBefore, "no premium was withheld at all");
        (uint256 g0AfterHold,) = hook.growths();
        assertEq(g0AfterHold, g0Held, "the accumulator moved on a pot with no recipient");
        emit log_named_uint("token0 held with nobody standing", held0);

        // The OTHER direction accrues a token1 pot and must leave `premiumHeld0` alone.
        _swap(false, 4e18);
        (,, uint256 stillHeld,) = hook.premiums();
        assertEq(stillHeld, held0, "the opposite-direction swap moved the token0 hold: wrong branch");

        // **A RECIPIENT APPEARS.** Rank 7 — the TAIL — re-funds in both tokens, so it contributes
        // depth while the fill below still stops at the head. The tail is chosen deliberately: if
        // the only depth-contributing seat were also the seat the fill touches, `lTouched` would
        // equal `standingL` and the swept-book branch would fire instead of the ordinary one, and
        // this test would be measuring the branch `test_7_7` already covers.
        _addTo(hook.ownerOf(7), 7, 1e18, 4e18);
        (uint256 standingL_,,) = hook.liquidityTotals();
        assertGt(standingL_, 0, "the recipient contributed no depth: this test proves nothing");

        (uint256 g0Before,) = hook.growths();
        _swap(true, 1e17);
        (, uint256 c1Cur) = hook.cursors();
        assertLt(c1Cur, 7, "the fill reached the tail: the swept-book branch fired, not the release");

        (uint256 owedAfter,, uint256 heldAfter,) = hook.premiums();
        (uint256 g0After,) = hook.growths();
        emit log_named_uint("token0 held afterwards          ", heldAfter);
        emit log_named_uint("accumulator advanced by         ", g0After - g0Before);

        assertGt(g0After, g0Before, "the held pot was not paid to the seats standing");
        assertEq(heldAfter, 0, "the held pot was not paid IN FULL");
        assertGt(owedAfter, owedAfterHold, "no premium was withheld by the releasing swap");
    }

    /// @dev The MIRROR. It exists because the same rule living in two branches has been wrong in
    ///      exactly one of them five times on this project (PITFALLS 5.37, 5.50, 5.52 twice, 5.125)
    ///      — and the fifth of those was caught on THIS pair of tests, when restoring the ratchet in
    ///      the token1 branch survived the whole suite because only the token0 test existed.
    function test_7_13_aHeldPotIsPaidInFullByTheNextAccrualWithARecipient_token1Branch() public {
        _use(onHook, onKey);
        _driveStandingLToZero(8, 10e18, 40e18);

        (, uint256 owedBefore,,) = hook.premiums();
        (, uint256 g1Held) = hook.growths();

        _swap(false, 4e18);
        (, uint256 owedAfterHold,, uint256 held1) = hook.premiums();
        assertGt(held1, 0, "nothing was held: this test proves nothing");
        assertGt(owedAfterHold, owedBefore, "no premium was withheld at all");
        (, uint256 g1AfterHold) = hook.growths();
        assertEq(g1AfterHold, g1Held, "the accumulator moved on a pot with no recipient");
        emit log_named_uint("token1 held with nobody standing", held1);

        _swap(true, 1e18);
        (,,, uint256 stillHeld) = hook.premiums();
        assertEq(stillHeld, held1, "the opposite-direction swap moved the token1 hold: wrong branch");

        _addTo(hook.ownerOf(7), 7, 1e18, 4e18);
        (uint256 standingL_,,) = hook.liquidityTotals();
        assertGt(standingL_, 0, "the recipient contributed no depth: this test proves nothing");

        (, uint256 g1Before) = hook.growths();
        _swap(false, 4e17);
        (uint256 c0Cur,) = hook.cursors();
        assertLt(c0Cur, 7, "the fill reached the tail: the swept-book branch fired, not the release");

        (, uint256 owedAfter,, uint256 heldAfter) = hook.premiums();
        (, uint256 g1After) = hook.growths();
        emit log_named_uint("token1 held afterwards          ", heldAfter);
        emit log_named_uint("accumulator advanced by         ", g1After - g1Before);

        assertGt(g1After, g1Before, "the held pot was not paid to the seats standing");
        assertEq(heldAfter, 0, "the held pot was not paid IN FULL");
        assertGt(owedAfter, owedAfterHold, "no premium was withheld by the releasing swap");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 7.14 — THE LAST-WEI CONCENTRATION. Written before the fix, red against the tree as it stood.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **A SEAT THAT CONTRIBUTED AN EIGHTH OF THE DEPTH TOOK THE WHOLE POT, BECAUSE IT
    ///         HAPPENED TO HOLD THE LAST WEI OF STANDING INVENTORY.**
    ///
    /// @dev Front-first drains the tail LAST, so after a book-emptying swap the tail seat is
    ///      systematically the only one left holding any of the outgoing token. The weight was that
    ///      inventory, so `premGrowth += mulDiv(pot, Q, 1)` and the tail's claim was
    ///      `mulDiv(1, d, Q) == the entire pot`. Measured on this fixture before the fix:
    ///      `standing1` fell to **1 wei** held by seat 7, and the whole **2.667e17** token0 pot
    ///      accrued to it — having paid only its own eighth of it. That is a strategy, not a
    ///      knife-edge, and it is a free lane in the AGENTS §5 sense.
    ///
    ///      **THE ASSERTION IS ON THE SHARE, NOT ON A MAGNITUDE**, so no tolerance can satisfy it:
    ///      a bound on wei would be met by any change that shrank the pot. The threshold is `pot/4`
    ///      — twice the equal-roster fair share of `1/8` — chosen so it cannot be passed by a small
    ///      improvement, only by the concentration actually being gone. Pre-fix the share is 100%.
    function test_7_14_theLastWeiHolderCannotTakeTheWholePot() public {
        _use(onHook, onKey);

        // A swap large enough to sweep the book. What is left standing is dust.
        _swap(true, expT0 * 4);
        (, uint256 st1) = hook.standings();
        assertGt(st1, 0, "the book emptied exactly: the concentration path was not entered");
        assertLt(st1, 1e6, "the book did not actually get swept: this test proves nothing");

        // Which seat is holding the residue, and what did the fill withhold?
        uint256 dustId = type(uint256).max;
        for (uint256 i; i < 8; i++) {
            (, uint256 a1) = hook.seat(i);
            if (a1 != 0) {
                assertEq(dustId, type(uint256).max, "more than one seat is standing: not the dust case");
                dustId = i;
            }
        }
        assertTrue(dustId != type(uint256).max, "no seat is standing: this test proves nothing");

        (uint256 owedBefore,,,) = hook.premiums();
        assertGt(owedBefore, 0, "no premium was withheld: this test proves nothing");

        // Settling the seat is what turns its accumulator claim into credited tokens, and the fall
        // in `premiumOwed0` is exactly what it took. Withdrawing zero pays nothing, so it settles
        // without moving capital and without costing the holder a rank.
        vm.prank(hook.ownerOf(dustId));
        hook.withdraw(dustId, 0, 0);
        (uint256 owedAfter,,,) = hook.premiums();
        uint256 claim = owedBefore - owedAfter;

        emit log_named_uint("seat holding the last wei    ", dustId);
        emit log_named_uint("token1 it was standing with  ", st1);
        emit log_named_uint("token0 pot withheld          ", owedBefore);
        emit log_named_uint("token0 it claimed            ", claim);
        emit log_named_uint("its share of the pot, %      ", (claim * 100) / owedBefore);

        assertLe(claim * 4, owedBefore, "THE DUST SEAT TOOK THE POT: last-wei concentration is live");
    }

    /// @notice **THE DEGENERATE FILL WITHHOLDS NO PREMIUM, SO IT NEEDS NO PAYER EXCLUSION — AND
    ///         THAT IS ASSERTED BY ENTERING THE BRANCH, NOT BY READING THE SOURCE.**
    ///
    /// @dev `_settlePremium` excludes the seats a fill PAID from the pot they generated. There is
    ///      exactly one other site that credits a seat out of a swap: the `amtOut == 0` path in
    ///      `_afterSwap`, where the pool took input and paid nothing out. If that path withheld a
    ///      premium, the seat it credits would be a payer and would need the same exclusion — one
    ///      rule, two sites, which has been wrong on this project five times (PITFALLS 5.37, 5.50,
    ///      5.52 twice, 5.73).
    ///
    ///      It does not: the branch returns before `_allocate`, so `_premiumOn` is never applied and
    ///      `_accruePremium` is never reached. The seat is credited the WHOLE input, which is the
    ///      consistent answer — no seat gave anything up, so nobody was jumped and nobody is owed
    ///      compensation. A comment saying so would be worth nothing; this drives the branch.
    function test_7_15_theDegenerateFillWithholdsNoPremium() public {
        _use(onHook, onKey);
        // Push `cursor0` forward with ordinary one-for-zero flow, so the degenerate credit lands
        // somewhere the assertions can see it. Same setup `Adversarial.t.sol::test_6_1` uses.
        for (uint256 i; i < 3; i++) {
            _swap(false, expT1 / 8);
        }

        (uint256 owed0Before, uint256 owed1Before, uint256 held0Before, uint256 held1Before) = hook.premiums();
        (uint256 g0Before, uint256 g1Before) = hook.growths();
        (uint256 t0Before,) = hook.totals();

        // A one-wei swap. The output rounds to zero on a 0.30% pool, which IS the degenerate fill.
        _swap(true, 1);

        (uint256 t0After,) = hook.totals();
        assertGt(t0After, t0Before, "nothing happened: the degenerate fill credited no seat, this test proves nothing");

        (uint256 owed0After, uint256 owed1After, uint256 held0After, uint256 held1After) = hook.premiums();
        (uint256 g0After, uint256 g1After) = hook.growths();

        // Nothing was withheld, nothing was held, and neither accumulator moved — so there is no
        // pot, hence no payer, hence nothing for an exclusion rule to do.
        // **`premiumOwed` CAN FALL HERE AND THAT IS NOT A POT.** The degenerate path settles the
        // seat it credits — it is one of the six sites that write a seat balance — and a settlement
        // moves wei OUT of `premiumOwed` into the seat. Only WITHHOLDING puts wei in. So the
        // assertion is one-sided, and the first draft of this test had it as an equality and failed
        // on a settlement of 3.1e15 that was the mechanism working correctly.
        assertLe(owed0After, owed0Before, "the degenerate fill withheld a token0 premium");
        assertLe(owed1After, owed1Before, "the degenerate fill withheld a token1 premium");
        assertEq(held0After, held0Before, "the degenerate fill held a token0 pot");
        assertEq(held1After, held1Before, "the degenerate fill held a token1 pot");
        assertEq(g0After, g0Before, "the degenerate fill moved premGrowth0");
        assertEq(g1After, g1Before, "the degenerate fill moved premGrowth1");

        // Neither accumulator moved and nothing was held, so no pot was formed at all — which is
        // what makes an exclusion rule unnecessary on this path rather than merely absent from it.
        assertGe(t0After - t0Before, 1, "the degenerate fill did not credit the input");
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
        QueueHook.Governance memory g
    ) QueueHarness(pm, c0_, c1_, f, sp, bhw, roster, g) {}

    function _accruePremium(bool inIsZero, uint256 pot, uint256 excludedL) internal override {
        if (inIsZero) {
            // **KEPT LINE-FOR-LINE IDENTICAL TO PRODUCTION EXCEPT FOR THE ONE MARKED LINE.** This
            // mutant used to carry the pre-Phase-8 guard `if (w < total) return;`, which was TWO
            // divergences once production stopped bounding the release — the control would then
            // have died of the difference it was not testing (PITFALLS 5.105). It also hardcoded
            // `1 << 64`; it reads `PREMIUM_Q` now, so a change of scale cannot silently strand it.
            uint256 total = pot + premiumHeld0;
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            // THE MUTATION: dropped, not held — and it returns BEFORE `premiumOwed0 += pot`,
            // because that is what DROPPING means. Returning after it would leave the wei counted
            // on the ledger side of INVARIANT F and the control would be invisible, which is
            // exactly how this control failed when the production branch order changed under it.
            if (inc == 0) return;
            premiumOwed0 += pot;
            premiumHeld0 = 0;
            unchecked {
                premGrowth0 += inc;
            }
        } else {
            uint256 total = pot + premiumHeld1;
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            if (inc == 0) return; // THE MUTATION.
            premiumOwed1 += pot;
            premiumHeld1 = 0;
            unchecked {
                premGrowth1 += inc;
            }
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

    /// @notice **THE COMPOUNDING CONTROL IS RETIRED, AND THAT IS A RESULT RATHER THAN A DELETION.**
    ///
    /// @dev It mutated `_syncSeat` to weight the token1 claim by an `a0` that had ALREADY absorbed
    ///      the token0 credit — compounding one settlement into the other, so the pot was handed out
    ///      faster than it was accrued and the last seats to settle found it empty. It went red on
    ///      `stdError.arithmeticError` and it was a good control.
    ///
    ///      **Phase 8 made the defect unexpressible.** The premium's weight is no longer the seat's
    ///      inventory in the opposite token — it is `liquidityContributed`, ONE quantity that both
    ///      accumulators divide by and that a settlement does not touch. There is no longer a
    ///      "first" credit that can contaminate a "second" weight, so the mutation is now an
    ///      EQUIVALENT MUTANT: it produces a contract that behaves identically to production, and a
    ///      control that cannot fail is worse than no control, because it reads as coverage.
    ///
    ///      What replaces it is the structural property the whole hazard rested on, asserted
    ///      directly. If a future change ever makes a settlement move the weight again, this goes
    ///      red and the compounding class is live once more.
    function test_N7_settlingCannotMoveTheWeightItIsPaidOn() public {
        _deployMutant("QueueHarness.sol:QueueHarness", 0xC400);
        // Accrue in BOTH directions, which is what the retired control needed to be reachable at
        // all — a one-directional swap moves only one accumulator (PITFALLS 5.54).
        _drive();

        uint256 moved;
        for (uint256 i; i < 8; i++) {
            uint128 lBefore = hook.seatLiquidity(i);
            // **THE CREDIT IS MEASURED ON `premiumOwed`, NOT ON `seat()`.** `seat()` reports raw
            // ledger PLUS accrued claim (PITFALLS 5.117), so it reads identically either side of a
            // settlement and a detector built on it registers nothing however much moved. The first
            // draft of this test did exactly that and its own "this test proves nothing" guard
            // caught it.
            (uint256 owed0Before, uint256 owed1Before,,) = hook.premiums();
            // `withdraw(id, 0, 0)` settles the seat without paying anything out, so nothing but the
            // premium credit can move — and it costs no rank, because nothing was paid.
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
            (uint256 owed0After, uint256 owed1After,,) = hook.premiums();
            if (owed0After != owed0Before || owed1After != owed1Before) moved++;
            assertEq(hook.seatLiquidity(i), lBefore, "settling moved the seat's premium weight");
        }
        assertGt(moved, 0, "no seat was actually credited: this test proves nothing");
    }

    /// @notice **THE CONTROL THAT PROVES CONSERVATION CAN SEE A DROPPED POT — REBUILT ON THE STATE
    ///         WHERE A POT IS STILL LEGITIMATELY HELD, BECAUSE ITS OLD ONE STOPPED EXISTING.**
    ///
    /// @dev It used to reach the hold branch by sweeping the whole book. That branch no longer
    ///      holds — a swept book distributes over the full denominator, which is the fix for the
    ///      maturity brick — so `DroppingPremiumHook`'s mutation became UNREACHABLE and the control
    ///      read "dropping the pot was invisible: this control proves nothing". A control that
    ///      cannot fire is worse than no control, because it reads as coverage (the `test_N7`
    ///      precedent).
    ///
    ///      It is rebuilt, not deleted, on the one state where `_accruePremium` still holds:
    ///      `standingL == 0`, reached through ordinary external calls by `_driveStandingLToZero`.
    ///      The mutation is unchanged and so is the claim: dropping a held pot leaves
    ///      `totals() + premiums()` SHORT of what PoolManager custody says went in, by the pot.
    ///
    ///      **THE POSITIVE CONTROL IS NOT OPTIONAL** (§3b): the identical sequence on the shipping
    ///      hook must tie out exactly, or a gap here could be the fixture rather than the mutation.
    function test_N8_droppingAHeldPotBreaksConservation() public {
        // ---- POSITIVE: production, same sequence, conservation exact.
        _deployMutant("QueueHarness.sol:QueueHarness", 0xC501);
        _driveStandingLToZero(8, 10e18, 40e18);
        _swap(true, 1e18);
        (uint256 pt0,) = hook.totals();
        (uint256 pq0,, uint256 pHeld0,) = hook.premiums();
        assertGt(pHeld0, 0, "the positive control never reached the hold branch: this proves nothing");
        assertEq(pt0 + pq0, expT0, "production lost a held pot: the negative control below is unreadable");

        // ---- NEGATIVE: the same, with the pot dropped instead of held.
        _deployMutant("Premium.t.sol:DroppingPremiumHook", 0xC500);
        _driveStandingLToZero(8, 10e18, 40e18);
        (uint256 b0,) = hook.totals();
        (uint256 bq0,,,) = hook.premiums();
        assertEq(b0 + bq0, expT0, "the mutant was already off the books before the drop");

        _swap(true, 1e18);
        (uint256 t0,) = hook.totals();
        (uint256 q0,, uint256 held0,) = hook.premiums();
        assertEq(held0, 0, "the mutant HELD the pot: it is not dropping anything");
        assertTrue(t0 + q0 != expT0, "dropping the pot was invisible: this control proves nothing");
        assertLt(t0 + q0, expT0, "the dropped pot did not leave the ledger SHORT");
        // THE SHAPE, not a bound: the gap is exactly the pot production would have held.
        assertEq(expT0 - (t0 + q0), pHeld0, "the gap is not the dropped pot: conservation broke some other way");
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
