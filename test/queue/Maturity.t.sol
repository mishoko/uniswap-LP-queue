// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {LimitSwapper, MutantQueueHook} from "./Controls.t.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

/// @title MATURITY — the terminal state of every QUEUE deployment, which nothing tested.
///
/// @notice `QueueHook.sol`'s own "why there is no `recenter()`" note states the consequence of the
///         fixed range in plain words:
///
///             "If the price leaves the band it goes one-sided and stops earning ... the only exit
///              is to withdraw and redeploy into a new pool. QUEUE is a fixed-term instrument."
///
///         So `withdraw` is the ONLY way capital leaves at the end of the instrument's life, and
///         the expected in-band life is 61 days (benign) / 19 days (normal) / 1.4 days (toxic).
///         **Price outside the band is not an edge case: it is where every deployment ends up.**
///         Before this file, the whole test tree exercised withdrawal, transfer, buyout, rent and
///         the sweep only with the price INSIDE the band. `Adversarial.t.sol` reaches the lower
///         tick exactly (`test_6_3`, `test_6_4`) and stops there — one direction, one boundary, and
///         a position that had been collapsed by withdrawals rather than converted by a swap.
///
/// @dev **LAW 1, AND IT IS THE REASON THIS FILE IS SHAPED IN MIRRORED PAIRS.** 18/6 decimals and a
///      1:4 start price, and every claim is executed in BOTH directions — price out of the band
///      BELOW `tickLower` and price out of the band ABOVE `tickUpper`. Out of range the position
///      holds exactly one token, so "out of band" is two different states, not one, and every
///      quantity that is compared against a quantity in the other token has two different answers.
///      The premium's own history on this project is precisely that: a units bug that existed in
///      one direction only, on the 18/6 pool the deploy script ships (PITFALLS 5.124).
///
///      **LAW 3 AS AMENDED.** Conservation is asserted on CUSTODY — PoolManager's own ERC20
///      balance NET OF `protocolFeesAccrued`, plus the hook's own balance — because that pair is
///      the only place a withdrawn wei can come from. It is asserted as the IDENTITY
///      `custodyBefore - custodyAfter == paid`, never as a bound (PITFALLS 5.53), and the holder's
///      own balance is asserted to have risen by exactly the same number.
///
///      **THE PRICE IS DRIVEN OUT BY A REAL SWAP, WITH AN EXPLICIT PRICE LIMIT.** The queue is the
///      sole LP, so an unbounded swap walks through empty ticks and slams into `MIN_SQRT_PRICE` —
///      a state so extreme that a passing test says nothing about the ordinary end of an ordinary
///      deployment. `LimitSwapper` stops the price four spacings clear of the band edge, which is
///      where a real pool with any wing at all comes to rest. `_matureDown`/`_matureUp` assert
///      STRICT exit (`tick < tickLower`, `tick >= tickUpper`) so no test here can pass while the
///      price is still in the band.
/// @dev **CONTROL — THE `sweptBook` BRANCH OF `_settlePremium`, DELETED, AND NOTHING ELSE.**
///
///      **THIS SUBCLASS HAS BEEN REPLACED AND THE REASON IS THE ONE THIS PROJECT KEEPS PAYING FOR.**
///      It used to override `_accruePremium` to pass `0` for `excludedL` — the payer exclusion,
///      deleted — and `test_M7d` used it to prove `test_M7`'s stranding assertions were falsifiable.
///      Production now passes `0` ITSELF on a whole-book sweep, which is exactly the terminal fill
///      `test_M7` drives, so that subclass became an EQUIVALENT MUTANT of the fix: it produced a
///      contract that behaves identically to production on the only fill the test makes, and a
///      control that cannot fail reads as coverage. That is the third time on this project
///      (`CompoundingPremiumHook` in Phase 8, PITFALLS 5.128a; M86 in 5.135; `UnfixedTransferQueueHook`
///      below).
///
///      What replaces it removes the branch instead of duplicating it. `_settlePremium` is
///      `virtual`; this override is production's body with the two `sweptBook` lines taken out, so
///      a fill that reaches every standing seat once again excludes every one of them, `w` is zero
///      to the wei, and `_accruePremium` takes its HOLD branch. **That is the pre-fix contract, and
///      `test_M7d` asserts what it does: the pot is held whole, no seat can claim a wei of it, and
///      once the roster exits the pool is BRICKED.** `test_M7`, `test_M7f` and `test_M13` are
///      therefore falsifiable, which is the only thing that makes them findings rather than
///      observations about a fixture.
///
///      The mark loop is kept EXACTLY as production has it, because the two halves of the exclusion
///      have to agree and moving one without the other strands the money a different way — see
///      `_settlePremium`'s own docblock. One divergence, not two (PITFALLS 5.105).
contract NoSweptBookQueueHook is QueueHarness {
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

    function _settlePremium(uint256 ord, uint256 start, uint256 touchedEnd, bool outIsOne, uint256 pot)
        internal
        override
    {
        uint256 last = touchedEnd - 1;

        uint256 lTouched;
        for (uint256 i = start; i <= last; i++) {
            lTouched += q[_idAt(ord, i)].liquidity;
        }

        // THE MUTATION, and it is the whole of it: production tests `standingL == lTouched` here and
        // passes `0` instead, returning before the mark loop. This does neither.
        _accruePremium(outIsOne, pot, lTouched);

        uint256 g = outIsOne ? premGrowth0 : premGrowth1;
        for (uint256 i = start; i <= last; i++) {
            Seat storage seat_ = q[_idAt(ord, i)];
            if (outIsOne) {
                seat_.snap0 = g;
            } else {
                seat_.snap1 = g;
            }
        }
    }
}

/// @dev **NEGATIVE CONTROL — the INVARIANT L branch, REMOVED. This subclass has been INVERTED, and
///      the inversion is the whole point of keeping it.**
///
///      It was born as the opposite: production `_onSeatTransfer` unchanged, plus the one line the
///      hook was missing, proving the missing branch was the whole defect (L, F and R all closed and
///      `unattributed == seatL` to the wei). **That line is now IN PRODUCTION**, so adding it again
///      applied it TWICE and the subclass read `80000000000000000010 != 40000000000000000005` —
///      exactly 2x. It had become an EQUIVALENT MUTANT of the fix it proved, the same way
///      `CompoundingPremiumHook` did in Phase 8 (PITFALLS 5.128a) and M86 did in 5.135.
///
///      A retired case with a reason is evidence; a deleted one is a gap (M59's precedent). So
///      rather than retire it, it now removes what production does: it runs production unchanged and
///      then puts `liquidityUnattributed` back where it found it, which restores the pre-fix
///      behaviour exactly. That is strictly STRONGER than what it was. It has stopped being a
///      one-shot proof that a fix works and become a STANDING GUARD that fails the moment anybody
///      deletes line ~1987 of `QueueHook.sol` — and given this is the one-rule-two-writers family
///      for the seventh time on this project (5.37, 5.50, 5.52 twice, 5.73, 5.125, 5.132), a
///      standing guard on that specific line is worth more than a historical proof.
///
///      **THE UNDO IS WRITTEN AS "PUT IT BACK", NOT AS "SUBTRACT `had - burned`", DELIBERATELY.**
///      Re-deriving the burn from `positionLiquidity` would be a SECOND copy of production's
///      arithmetic living in the control, and this file has already been bitten once by a mirrored
///      pair agreeing through arithmetic accident. It also breaks outright on the
///      `_settleRankOnTransfer` path, where a buyer's deposit MINTS liquidity and the re-derivation
///      underflows. Reading the pot before and after and capping it is exact, is immune to both,
///      and cannot silently drift from the line it is inverting: the `rest` branch only ever
///      DECREASES the pot, so an increase across the call is the fixed branch and nothing else.
contract UnfixedTransferQueueHook is QueueHarness {
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

    function _onSeatTransfer(uint256 seatId, address from) internal override {
        uint256 unattBefore = liquidityUnattributed;
        super._onSeatTransfer(seatId, from);
        if (liquidityUnattributed > unattBefore) liquidityUnattributed = unattBefore;
    }
}

/// @dev **CONTROL — dust policy F1, REMOVED.** `_applyDustPolicy` is `virtual` precisely so a
///      control can pay FACE VALUE instead of `min(face, available)`. At maturity the position holds
///      none of the dead token and the float is empty, so a face-value payout underflows `float1`
///      inside `_payOut`. That is what makes `test_M1`/`test_M2c` falsifiable: the maturity exit
///      works BECAUSE of the clamp, not incidentally.
contract FaceValueQueueHook is QueueHarness {
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

    function _applyDustPolicy(uint256 w0, uint256 w1) internal pure override returns (uint256, uint256) {
        return (w0, w1);
    }
}

contract MaturityTest is QueueFixture {
    using StateLibrary for IPoolManager;

    // **THE DEFECT THIS SUITE FOUND IS FIXED AND THE WHOLE FILE IS GREEN.** `test_M12` / `test_M12b`
    // were written RED — they assert the CORRECT behaviour of an `_onSeatTransfer` defect that
    // orphaned a departing seat's contributed depth — and stayed red until the missing branch landed
    // in `QueueHook.sol`. They are regression tests now. `test_M12c` began as the proof that the
    // one-line fix was the WHOLE defect, became an equivalent mutant of that fix the moment it
    // shipped, and has been INVERTED into the standing guard that fires if the line is ever deleted.
    // Nothing in this file edited `src/`.

    /// @dev The SHIPPING φ, read off `script/QueueDeployBase.sol`'s `PREMIUM_BPS`. The whole point
    ///      of this suite is what the product does at maturity, so it runs the product's own
    ///      parameter rather than the fixture's φ = 0 control.
    uint256 constant PHI = 7_900;

    address constant A = address(0xA11CE);
    address constant B = address(0xB0B);
    address constant C = address(0xCAF1);
    address constant D = address(0xD00D);
    address constant E = address(0xE11E);

    /// @dev Five seats, equal capital. Equal capital is load-bearing for question 3: if the seats
    ///      differed in size, a difference in outcome between rank 0 and rank 4 could be the size
    ///      rather than the rank.
    uint128 constant SEAT_L = 40e18;

    address[5] holders;
    uint256[5] init0;
    uint256[5] init1;

    function _premiumBps() internal view virtual override returns (uint256) {
        return PHI;
    }

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        dec0 = 18;
        dec1 = 6; // LAW 1 — asymmetric decimals AND a non-unit price
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();

        holders = [A, B, C, D, E];
        address[] memory r = new address[](5);
        for (uint256 i; i < 5; i++) {
            r[i] = holders[i];
        }
        _deployHookUnfundedRoster(0x4D01, r);
        _initPool();
        _fundEverySeat();
    }

    /// @dev `QueueFixture._roster` tops out at four. This suite needs five ranks to say anything
    ///      about the middle of the queue, so the array is built by the caller.
    function _deployHookUnfundedRoster(uint160 nonce, address[] memory roster) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(roster), a);
        hook = QueueHarness(a);
    }

    /// @dev A SECOND pool, identical in every respect but φ, seeded exactly as `setUp` seeds the
    ///      first. It exists for one test and that test is the reason to trust the rest: LAW 5's
    ///      first corollary says the strongest control is one that could falsify the headline, and
    ///      the headline here is "the terminal fill strands the whole premium pot". At φ = 0 there
    ///      is no pot, so the stranded remainder MUST collapse to residual scale while every other
    ///      quantity survives unchanged. It is not a rerun of the same arithmetic against itself.
    function _rebuildAtPhi(uint160 nonce, uint256 phi) internal {
        address a = address(FLAGS ^ (nonce << 144));
        address[] memory r = new address[](5);
        for (uint256 i; i < 5; i++) {
            r[i] = holders[i];
        }
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgsPremium(r, phi), a);
        hook = QueueHarness(a);
        _initPool();
        _fundEverySeat();
    }

    /// @dev Deposit IN THE BAND'S OWN RATIO. An off-ratio deposit on a concentrated band lands
    ///      almost entirely in float, and a maturity test whose capital never entered the position
    ///      would be measuring the float rather than the instrument.
    function _fundEverySeat() internal {
        (uint256 a0, uint256 a1) = _amountsFor(SEAT_L);
        for (uint256 i; i < 5; i++) {
            _addTo(holders[i], i, a0, a1);
            (init0[i], init1[i]) = hook.seat(i);
        }
        assertGt(hook.positionLiquidity(), 0, "nothing entered the position: this fixture proves nothing");
    }

    function _amountsFor(uint128 L) internal view returns (uint256 a0, uint256 a1) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        (,, int24 lower, int24 upper) = hook.pool();
        a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(upper), L, true);
        a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(lower), sqrtP, L, true);
    }

    // ------------------------------------------------------------------- driving the pool to maturity

    function _swapper() internal returns (LimitSwapper s) {
        s = new LimitSwapper(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(s), 1e33);
        MockERC20(Currency.unwrap(c1)).mint(address(s), 1e33);
    }

    /// @notice Convert the whole position to token0 and leave the price STRICTLY below the band.
    function _matureDown() internal {
        (,, int24 tl,) = hook.pool();
        int24 target = tl - 4 * SPACING;
        int24 floor_ = TickMath.minUsableTick(SPACING);
        if (target < floor_) target = floor_;
        _swapper().swapTo(k, true, 1e28, TickMath.getSqrtPriceAtTick(target));

        (uint160 p, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertLt(tick, tl, "nothing happened: the price never left the band downward");
        assertLt(p, TickMath.getSqrtPriceAtTick(tl), "the price is AT the band edge, not below it");
    }

    /// @notice The mirror: convert the whole position to token1 and leave the price STRICTLY above.
    function _matureUp() internal {
        (,,, int24 tu) = hook.pool();
        int24 target = tu + 4 * SPACING;
        int24 ceil_ = TickMath.maxUsableTick(SPACING);
        if (target > ceil_) target = ceil_;
        _swapper().swapTo(k, false, 1e28, TickMath.getSqrtPriceAtTick(target));

        (uint160 p, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertGe(tick, tu, "nothing happened: the price never left the band upward");
        assertGt(p, TickMath.getSqrtPriceAtTick(tu), "the price is AT the band edge, not above it");
    }

    /// @dev What the position is actually made of, from PoolManager. Out of range this is the
    ///      claim under test: one token, and zero of the other.
    function _positionComposition() internal view returns (uint256 a0, uint256 a1) {
        return _positionValue();
    }

    // ---------------------------------------------------------------------------- CUSTODY (LAW 3)

    /// @dev The only two places a withdrawn wei can come from: PoolManager (the position), net of
    ///      protocol fees which sit inside PoolManager's ERC20 balance until collected, and the
    ///      hook's own balance (the float, the escrow). A raw-PoolManager conservation test reads
    ///      0 wei of error while a position is short (LAW 3 as amended); this one cannot.
    function _custody() internal view returns (uint256 a0, uint256 a1) {
        a0 = _pmBal(c0) - poolManager.protocolFeesAccrued(c0) + _hookBal(c0);
        a1 = _pmBal(c1) - poolManager.protocolFeesAccrued(c1) + _hookBal(c1);
    }

    /// @dev Withdraw and assert the two identities that make a payout honest, with no bound
    ///      anywhere: custody fell by exactly what was paid, and the holder rose by exactly the
    ///      same. `_withdrawTracked` is deliberately NOT used — it maintains the fixture's witness,
    ///      and the witness's allocator does not model the premium (φ > 0 here), so feeding it
    ///      would make a later assertion fail for a reason that has nothing to do with maturity.
    function _wd(uint256 seatId, uint256 w0, uint256 w1, string memory tag) internal returns (uint256 p0, uint256 p1) {
        address who = hook.ownerOf(seatId);
        (uint256 c0Before, uint256 c1Before) = _custody();
        uint256 h0 = MockERC20(Currency.unwrap(c0)).balanceOf(who);
        uint256 h1 = MockERC20(Currency.unwrap(c1)).balanceOf(who);

        vm.prank(who);
        (p0, p1) = hook.withdraw(seatId, w0, w1);

        (uint256 c0After, uint256 c1After) = _custody();
        assertEq(c0Before - c0After, p0, string.concat(tag, ": custody0 != paid0"));
        assertEq(c1Before - c1After, p1, string.concat(tag, ": custody1 != paid1"));
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(who) - h0, p0, string.concat(tag, ": holder0 != paid0"));
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(who) - h1, p1, string.concat(tag, ": holder1 != paid1"));
    }

    // =============================================================================================
    // 0. THE FIXTURE ITSELF — before any claim, prove the state under test was actually reached.
    // =============================================================================================

    /// @notice The maturity state, both directions, asserted rather than assumed.
    /// @dev Out of range a v4 position is 100% one token. If that is not true here, every other
    ///      test in this file is testing an in-range position and proves nothing (PITFALLS 5.54).
    function test_M0_maturityIsOneSidedBelowTheBand() public {
        (uint256 b0, uint256 b1) = _positionComposition();
        assertGt(b0, 0, "the fixture position holds no token0 to begin with");
        assertGt(b1, 0, "the fixture position holds no token1 to begin with");

        _matureDown();
        (uint256 d0, uint256 d1) = _positionComposition();
        assertGt(d0, b0, "below the band the position did not take in token0");
        assertEq(d1, 0, "below the band the position still holds token1");
    }

    /// @notice The mirror. A rule that lives once per direction has been wrong four times on this
    ///         project (PITFALLS 5.52). It is a SEPARATE test rather than the second half of the one
    ///         above because re-running `setUp()` inside a test body redeploys the whole v4 stack
    ///         and exceeds the block gas limit.
    function test_M0b_maturityIsOneSidedAboveTheBand() public {
        (uint256 b0, uint256 b1) = _positionComposition();
        assertGt(b0, 0, "the fixture position holds no token0 to begin with");
        assertGt(b1, 0, "the fixture position holds no token1 to begin with");

        _matureUp();
        (uint256 u0, uint256 u1) = _positionComposition();
        assertEq(u0, 0, "above the band the position still holds token0");
        assertGt(u1, b1, "above the band the position did not take in token1");
    }

    // =============================================================================================
    // 1. CAN EVERY SEAT GET ITS MONEY OUT? — the only question that matters at maturity, because
    //    `withdraw` is the only exit the instrument has.
    // =============================================================================================

    function test_M1_everySeatWithdrawsInFullBelowTheBand() public {
        _matureDown();
        _everySeatWithdrawsInFull("below");
    }

    function test_M1b_everySeatWithdrawsInFullAboveTheBand() public {
        _matureUp();
        _everySeatWithdrawsInFull("above");
    }

    /// @dev **THE IDENTITY, NOT A BOUND.** Every seat asks for its ENTIRE ledger balance; custody
    ///      (PoolManager net of protocol fees, plus the hook) must fall by exactly what was paid,
    ///      and the holder must rise by exactly the same number. `_wd` asserts both, per call, per
    ///      token, for all five seats.
    function _everySeatWithdrawsInFull(string memory dir) internal {
        uint256 paid0;
        uint256 paid1;
        for (uint256 i; i < 5; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            assertTrue(a0 != 0 || a1 != 0, "nothing happened: the seat is already empty, this proves nothing");
            (uint256 p0, uint256 p1) = _wd(i, a0, a1, string.concat(dir, " full"));
            paid0 += p0;
            paid1 += p1;
        }
        // The seat the maturity swap converted must have been paid REAL money, not dust — otherwise
        // the loop above could pass against a queue that held nothing (PITFALLS 5.54).
        assertGt(paid0 + paid1, 1e18, "the whole roster withdrew dust: this test proves nothing");

        // Whatever the dust policy could not pay is what the seats are still owed. It is residual
        // scale, and it is asserted as such rather than assumed to be zero.
        (uint256 t0, uint256 t1) = hook.totals();
        assertLt(t0 + t1, 1_000, "seats are still owed real money after withdrawing in full");

        _checkInvariantF(string.concat(dir, " after full withdrawal"), 1_000);
        _checkInvariantL(string.concat(dir, " after full withdrawal"));
        _checkInvariantR(string.concat(dir, " after full withdrawal"));
    }

    // ---------------------------------------------------------------------- partial withdrawal

    function test_M2_partialWithdrawalWorksBelowTheBand() public {
        _matureDown();
        _partialThenTheRest("below", true);
    }

    function test_M2b_partialWithdrawalWorksAboveTheBand() public {
        _matureUp();
        _partialThenTheRest("above", false);
    }

    /// @dev Half, then the remainder, ON THE LIVE LEG. Two claims: a partial request against a
    ///      one-sided position is paid IN FULL (it is not silently clamped), and the seat can come
    ///      back for the rest afterwards — which is what a holder who exits in tranches depends on.
    ///
    ///      **THE LIVE LEG IS NAMED EXPLICITLY AND THAT IS NOT COSMETIC.** The first draft asked
    ///      for half of BOTH legs and passed above the band and failed below it, for a reason that
    ///      has nothing to do with the direction: the maturity swap leaves a few wei of the dead
    ///      token on the boundary seat, half of 3 wei is 1 and half of 1 wei is 0, so one direction
    ///      happened to request an unpayable wei and the other happened not to. A pair of mirrored
    ///      tests that agree by arithmetic accident is worth nothing. The dead-side residue gets its
    ///      own claim in `test_M2c`, where it is asserted rather than dodged.
    /// @param liveIsZero which token the out-of-range position can still release.
    function _partialThenTheRest(string memory dir, bool liveIsZero) internal {
        uint256 shortfalls;
        for (uint256 i; i < 5; i++) {
            shortfalls += _twoTranches(i, dir, liveIsZero);
        }
        // **AT MOST ONE TRANCHE IN THE WHOLE ROSTER MAY FALL SHORT, AND ONLY THE LAST ONE.** A
        // clamp that appeared twice would not be the terminal §E.4 residue; it would be a payout
        // path that under-delivers, and this loop would not be able to tell the difference without
        // this line.
        assertLe(shortfalls, 1, "more than one tranche was clamped: this is not the terminal residue");
        console.log("tranches short of face by the terminal residue", shortfalls);
        _checkInvariantF(string.concat(dir, " after partial withdrawals"), 1_000);
        _checkInvariantL(string.concat(dir, " after partial withdrawals"));
    }

    /// @dev One seat's two tranches, in its own frame: `_partialThenTheRest` is at the stack limit
    ///      without `via_ir` and the shortfall counter is the local that tips it over.
    function _twoTranches(uint256 i, string memory dir, bool liveIsZero) internal returns (uint256) {
        (uint256 a0, uint256 a1) = hook.seat(i);
        uint256 live = liveIsZero ? a0 : a1;
        assertGt(live, 1, "nothing happened: this seat holds no live-side balance");
        uint256 half = live / 2;

        (uint256 p0, uint256 p1) = _wd(i, liveIsZero ? half : 0, liveIsZero ? 0 : half, string.concat(dir, " half"));
        assertEq(liveIsZero ? p0 : p1, half, "a partial live-leg request out of band was clamped");

        // ...and the seat still holds the rest, to the wei. The IDENTITY, not a bound: the seat is
        // debited by what was PAID and by nothing else.
        (uint256 r0, uint256 r1) = hook.seat(i);
        assertEq(r0, a0 - p0, "the seat was debited more token0 than it was paid");
        assertEq(r1, a1 - p1, "the seat was debited more token1 than it was paid");

        uint256 rest = liveIsZero ? r0 : r1;
        (p0, p1) = _wd(i, liveIsZero ? rest : 0, liveIsZero ? 0 : rest, string.concat(dir, " rest"));
        return _assertPaidInFullOrNothingWasLeft(liveIsZero ? p0 : p1, rest, liveIsZero);
    }

    /// @notice **A TRANCHE IS PAID IN FULL, OR THERE WAS NOTHING ANYWHERE LEFT TO PAY IT WITH.**
    ///
    /// @dev **THIS ASSERTION WAS `assertEq(paid, rest)` AND IT WENT RED BY EXACTLY ONE WEI ON THE
    ///      LAST TRANCHE OF THE LAST SEAT, BELOW THE BAND ONLY. Diagnosed rather than widened, and
    ///      the diagnosis is the reason the shape below is an identity and not a tolerance.**
    ///
    ///      Measured, seat by seat, below the band: seats 0-3 are paid both tranches to the wei.
    ///      Seat 4 asks for `3944511495245597924`; the ENTIRE remaining position redeems for
    ///      `3944511495245597923` and the float is empty, so `positionLiquidity` goes
    ///      `20479677823723506557 -> 0` and `_positionValue` goes to zero with it. **Nothing was
    ///      left behind. Face value simply exceeded redeemable value by one wei** — §E.4, and the
    ///      case `_payOut`'s own docblock names: "Paying face exactly makes the LAST withdrawer's
    ///      call revert; F1 spreads the residual over whoever withdraws instead of dumping it on
    ///      them."
    ///
    ///      **WHY IT ONLY APPEARS BELOW THE BAND, since an asymmetry that is not explained is a
    ///      defect that has not been found.** `_liquidityToCover` adds one unit of liquidity to
    ///      cover the two truncations (`if (d != 0) d += 1`) and then clamps `d > liquidity`. Every
    ///      earlier tranche leaves surplus position behind, so the `+1` survives and the release
    ///      covers face; the FINAL draining request is the one where the clamp eats it. Above the
    ///      band the last seat's live-leg face happens to land under redeemable and the clamp does
    ///      not bite — an arithmetic accident of the direction, which is exactly what this
    ///      function's own docblock warns mirrored pairs about.
    ///
    ///      **AND WHY IT WAS NOT VISIBLE BEFORE.** The terminal fill used to HOLD the whole premium
    ///      pot, so the ledger sat ~0.0496e18 BELOW what the position could release and that slack
    ///      absorbed the residue. The pot now reaches the roster (`test_M7`) and the ledger is tight
    ///      against the position — total gap two wei over a 38.58e18 exit — so the residue has
    ///      nowhere left to hide. Confirmed by running this test against the pre-fix contract, where
    ///      it passes.
    ///
    ///      **THE ASSERTION, therefore, is `paid == rest` OR the position and the float were BOTH
    ///      emptied by the attempt.** A payout that clamps while any capital remains — the defect
    ///      this test exists to catch — goes red, because it would leave `positionLiquidity` or the
    ///      live-leg value non-zero. Nothing here is widened: the equality is still asserted on
    ///      every tranche that had anything left to draw on.
    /// @return one if this tranche fell short, zero otherwise.
    function _assertPaidInFullOrNothingWasLeft(uint256 paid, uint256 rest, bool liveIsZero)
        internal
        view
        returns (uint256)
    {
        if (paid == rest) return 0;
        assertLt(paid, rest, "the payout EXCEEDED the request");
        assertEq(
            uint256(hook.positionLiquidity()), 0, "the tranche was clamped while the position still held liquidity"
        );
        (uint256 f0, uint256 f1) = hook.floats();
        assertEq(liveIsZero ? f0 : f1, 0, "the tranche was clamped while the float still held the token");
        (uint256 pv0, uint256 pv1) = _positionValue();
        assertEq(liveIsZero ? pv0 : pv1, 0, "the tranche was clamped while the position still held the token");
        // The §E.4 bound is sub-wei per swap; a whole-roster exit cannot accumulate a tranche of it.
        assertLe(rest - paid, 1_000, "the shortfall is capital, not the rounding residue");
        return 1;
    }

    /// @notice **THE DEAD-SIDE RESIDUE IS UNPAYABLE, AND THAT IS DUST POLICY F1 RATHER THAN A
    ///         DEFECT — but it is a disclosure, because face value stops being payable at maturity
    ///         and no other test in the project says so.**
    ///
    /// @dev The maturity swap leaves a few wei of the OUTGOING token on the seat the fill stopped
    ///      inside. Out of range the position holds none of that token and the float is empty, so
    ///      `_liquidityToCover` correctly answers "none" and `_applyDustPolicy` pays zero. The seat
    ///      keeps a ledger entry it can never redeem. The claim asserted here is that the residue is
    ///      RESIDUAL SCALE — a handful of wei, not a tranche of capital — and that asking for it
    ///      returns zero rather than reverting, which is the half that matters: a revert on this
    ///      path would block the whole exit (`withdraw` takes both legs in one call).
    function test_M2c_deadSideDustIsUnpayableAndDoesNotRevert() public {
        _matureDown();

        uint256 stuck;
        for (uint256 i; i < 5; i++) {
            (, uint256 a1) = hook.seat(i);
            if (a1 == 0) continue;
            stuck += a1;
            (, uint256 p1) = _wd(i, 0, a1, "dead-side dust");
            assertEq(p1, 0, "the position paid a token1 it does not hold");
            (, uint256 r1) = hook.seat(i);
            assertEq(r1, a1, "the seat was debited for a payment it never received");
        }
        assertGt(stuck, 0, "nothing happened: no dead-side residue exists, this test proves nothing");
        assertLt(stuck, 1_000, "the dead-side residue is NOT dust: real capital is stranded");
    }

    // ------------------------------------------------------------- and with a protocol fee on

    /// @notice LAW 3 as amended, executed: the same exit with the protocol fee at its maximum.
    /// @dev `protocolFeesAccrued` sits INSIDE PoolManager's ERC20 balance until it is collected, so
    ///      a raw-balance conservation test reads 0 wei of error while the position is short. This
    ///      runs the whole maturity exit with the fee switched on in both directions at once, so
    ///      the custody identity in `_wd` is being asserted against a PoolManager balance that
    ///      genuinely contains money the queue does not own.
    function test_M3_theExitIsConservativeWithAProtocolFee() public {
        _setProtocolFee(k, uint24(1000) | (uint24(1000) << 12));
        _matureDown();
        assertGt(poolManager.protocolFeesAccrued(c0), 0, "no protocol fee accrued: this test proves nothing");
        _everySeatWithdrawsInFull("pf below");
    }

    // =============================================================================================
    // 2. DOES ANYTHING REVERT? — the three named hazards, out of band, in both directions.
    // =============================================================================================

    /// @notice PITFALLS 5.77 — a zero span is an ANSWER, not an error, and `FullMath.mulDiv`
    ///         reports it as EMPTY REVERT DATA.
    ///
    /// @dev Out of range the position holds exactly one token, so asking how much liquidity
    ///      releases the OTHER one divides by a zero span. The answer must be "none", and the
    ///      question must be asked in BOTH directions: below the band the dead leg is token1, above
    ///      it is token0. A test that only went one way would have passed against a contract that
    ///      guarded one branch and not the other — the exact shape that has been wrong five times
    ///      on this project.
    function test_M4_zeroSpanSizingAnswersNoneInBothDirections() public {
        // POSITIVE CONTROL first, in the middle of the range: both legs size. Without it, a zero
        // below could just mean the helper always returns zero.
        assertGt(hook.liquidityToCover(1e6, 0), 0, "the token0 leg does not size in mid-range");
        assertGt(hook.liquidityToCover(0, 1e6), 0, "the token1 leg does not size in mid-range");

        _matureDown();
        assertEq(hook.liquidityToCover(0, 1), 0, "below the band, sizing a token1 request did not answer none");
        assertGt(hook.liquidityToCover(1e6, 0), 0, "below the band, the LIVE token0 leg stopped sizing");
    }

    function test_M4b_zeroSpanSizingAnswersNoneAboveTheBand() public {
        assertGt(hook.liquidityToCover(1e6, 0), 0, "the token0 leg does not size in mid-range");
        assertGt(hook.liquidityToCover(0, 1e6), 0, "the token1 leg does not size in mid-range");

        _matureUp();
        assertEq(hook.liquidityToCover(1, 0), 0, "above the band, sizing a token0 request did not answer none");
        assertGt(hook.liquidityToCover(0, 1e6), 0, "above the band, the LIVE token1 leg stopped sizing");
    }

    /// @notice PITFALLS 5.74 — never predict the sign of a balance change from the sign of the
    ///         request you made, and PITFALLS 5.76 — a leg that is not binding must not decide the
    ///         outcome.
    ///
    /// @dev A matured position is full of realised-but-uncollected LP fees in BOTH tokens (the
    ///      maturity swap paid them), and out of range it can only absorb ONE of them. So a deposit
    ///      here mints on one leg while `modifyLiquidity` hands back fees on the other: the classic
    ///      shape in which `unlockCallback` picked its subtraction direction from the sign of the
    ///      request, underflowed, and bricked both paths capital has into the queue.
    function test_M5_depositSurvivesOutOfBandBelow() public {
        _matureDown();
        _depositSurvives("below", true);
    }

    function test_M5b_depositSurvivesOutOfBandAbove() public {
        _matureUp();
        _depositSurvives("above", false);
    }

    /// @dev Split out of `_depositSurvives` purely for the stack: that function is at the limit
    ///      without `via_ir`, and two more locals is the difference between building and not.
    function _exitSeat(uint256 seatId, string memory tag) internal {
        (uint256 s0, uint256 s1) = hook.seat(seatId);
        _wd(seatId, s0, s1, tag);
    }

    /// @param liveIsZero which token the out-of-range position can still absorb.
    function _depositSurvives(string memory dir, bool liveIsZero) internal {
        uint128 lBefore = hook.positionLiquidity();

        // 1. The DEAD leg alone. It can mint nothing — `_liquidityForAmounts` sizes the out-of-range
        //    branch on the live token only — so the whole deposit must become float, the seat must
        //    still be credited every wei of it, and it must not revert.
        uint256 dead = liveIsZero ? 5e6 : 5e18;
        (uint256 b0, uint256 b1) = hook.seat(1);
        _fund(B, liveIsZero ? 0 : dead, liveIsZero ? dead : 0);
        vm.prank(B);
        hook.addToSeat(1, liveIsZero ? 0 : dead, liveIsZero ? dead : 0);
        (uint256 a0, uint256 a1) = hook.seat(1);
        assertEq(liveIsZero ? a1 - b1 : a0 - b0, dead, string.concat(dir, ": the dead leg was not credited"));
        assertEq(uint256(hook.positionLiquidity()), uint256(lBefore), "the dead leg minted depth it cannot back");
        (uint256 f0, uint256 f1) = hook.floats();
        assertEq(liveIsZero ? f1 : f0, dead, string.concat(dir, ": the dead leg did not land in float"));

        // 2. The LIVE leg. This one really does mint, against a position holding uncollected fees
        //    in both tokens — so the callback settles a DEBIT on one currency and a CREDIT on the
        //    other in the same call.
        uint256 live = liveIsZero ? 5e18 : 5e6;
        (b0, b1) = hook.seat(2);
        _fund(C, liveIsZero ? live : 0, liveIsZero ? 0 : live);
        vm.prank(C);
        hook.addToSeat(2, liveIsZero ? live : 0, liveIsZero ? 0 : live);
        (a0, a1) = hook.seat(2);
        assertEq(liveIsZero ? a0 - b0 : a1 - b1, live, string.concat(dir, ": the live leg was not credited"));
        assertGt(uint256(hook.positionLiquidity()), uint256(lBefore), "nothing happened: the live leg minted no depth");

        _checkInvariantF(string.concat(dir, " after out-of-band deposits"), 1_000);
        _checkInvariantL(string.concat(dir, " after out-of-band deposits"));
        _checkInvariantR(string.concat(dir, " after out-of-band deposits"));

        // ...and the money still comes back out afterwards.
        _exitSeat(2, "post-deposit exit");
    }

    // =============================================================================================
    // 3. WHAT DOES A SEAT ACTUALLY HOLD AT MATURITY? — the business question, executed.
    // =============================================================================================

    /// @notice **RANK 0 ENDS UP STRICTLY WORSE THAN RANK 4, ON IDENTICAL CAPITAL, IN BOTH
    ///         DIRECTIONS. Being first in line means being first into the losing side, and the
    ///         ordering is perfectly monotone in rank.**
    ///
    /// @dev Five seats, EQUAL capital, so a difference in outcome cannot be a difference in size.
    ///      Front-first allocation converts the head first, which on a one-way move means the head
    ///      sells at the STALEST prices of that move and the tail sells at the freshest. At maturity
    ///      every seat is fully converted, so the whole difference shows up as the amount of the
    ///      surviving token each rank ends holding.
    ///
    ///      This is the same statement as `docs/research/seat-economics`' execution-price result —
    ///      "the head eats the stalest end of every move" — measured here on the CONTRACT rather
    ///      than in the simulator, at the one moment where it is not recoverable by any later trade.
    ///
    ///      The assertion is STRICT and per-adjacent-pair, not a head-vs-tail bound: a bound would
    ///      be satisfied by a single outlier, and the claim being made is that the effect is
    ///      ORDERED. Nothing here is a tolerance.
    function test_M6_theHeadEndsWorseOffBelowTheBand() public {
        _matureDown();
        _reportRanks("below", true);
    }

    function test_M6b_theHeadEndsWorseOffAboveTheBand() public {
        _matureUp();
        _reportRanks("above", false);
    }

    /// @param liveIsZero which token every seat is left holding once the band is behind the price.
    function _reportRanks(string memory dir, bool liveIsZero) internal view {
        uint256 prev;
        uint256 head;
        uint256 tail;
        for (uint256 i; i < 5; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            uint256 got = liveIsZero ? a0 : a1;
            console.log(dir, i, got);
            if (i == 0) head = got;
            if (i == 4) tail = got;
            if (i != 0) {
                assertGt(got, prev, "the maturity outcome is NOT monotone in rank: the claim is wrong");
            }
            prev = got;
        }
        // Both seats put in the same capital, so this ratio is the whole of the rank effect.
        uint256 gapBps = FullMath.mulDiv(tail - head, 10_000, head);
        console.log("head-to-tail gap, bps", gapBps);
        assertGt(gapBps, 100, "nothing happened: the ranks ended within 1% of each other");
    }

    // =============================================================================================
    // 4. DO THE OTHER MECHANISMS STILL BEHAVE OUT OF BAND?
    // =============================================================================================

    /// @notice **THE TERMINAL FILL PAYS THE WHOLE PREMIUM POT TO THE WHOLE ROSTER. THIS TEST USED
    ///         TO ASSERT THE OPPOSITE, AND THE OPPOSITE WAS A BRICKED POOL.**
    ///
    /// @dev **WHAT IT USED TO SAY, kept because the scenario it executes is the evidence the fix
    ///      was needed.** `_settlePremium` excluded the ranks the fill reached, `[start, next]`,
    ///      from the accrual denominator, because including the boundary seat let a last-wei holder
    ///      take an entire pot (`test_7_14`). A fill that reaches the TAIL therefore excluded EVERY
    ///      rank, and `w = standingL - lTouched` was ZERO to the wei — INVARIANT L says `standingL`
    ///      IS the sum of the seats. So `_accruePremium` took its `w == 0` branch, `premGrowth` did
    ///      not move, and the whole pot landed in `premiumHeld`.
    ///
    ///      That was called a DEFERRAL. It was not one. **A held pot is money the position holds
    ///      that `standing0`/`standing1` does not count**, so the ledger goes short of what the
    ///      position can pay, and the next fill in the other direction cannot be sourced: it reverts
    ///      `QueueUnderflow` from inside `_afterSwap`, which is a bricked pool rather than a lost
    ///      wei. Measured in this exact state: the position held 4.9567e16 wei of token0 against
    ///      2.573e17 of liquidity it could not trade (`test_M7f`, `test_M13`).
    ///
    ///      **THE RULE NOW.** "The payer does not pay itself" has no meaning on a fill that swept
    ///      the whole book, because there is no seat that did not pay. The pot is divided over the
    ///      FULL `standingL` — everybody included — and no mark moves. `test_7_14`'s extraction is
    ///      unreachable from here: that needed exactly ONE unexcluded seat, this fires at ZERO.
    ///
    ///      Asserted four ways, because "accrued", "distributed pro-rata", "claimable" and
    ///      "withdrawable" are four different claims (LAW 3, second corollary): nothing is held and
    ///      the accumulator moved; every seat's credit is its share of the depth it contributed; the
    ///      credits sum to the pot up to the per-seat floor; and once the roster has withdrawn there
    ///      is nothing left in the position for a test-only burn to find.
    function test_M7_theTerminalFillPaysThePremiumToTheRosterBelowTheBand() public {
        _thePremiumReachesTheRoster(true);
    }

    /// @notice The mirror, and it is NOT free: the token0 and token1 halves of `_accruePremium` are
    ///         a duplicated rule, and a duplicated rule has been wrong in exactly one of its two
    ///         copies five times on this project (PITFALLS 5.125).
    function test_M7b_theTerminalFillPaysThePremiumToTheRosterAboveTheBand() public {
        _thePremiumReachesTheRoster(false);
    }

    /// @dev The measurement half, in its own frame for the stack. Nothing is asserted against a
    ///      tolerance chosen to pass: the depth bound is 2% of what the pool was born with, and the
    ///      two numbers it is derived from are logged next to it.
    function _reportStranding(bool down, uint256 owed, uint128 lAtBirth) internal view {
        (uint256 contributed,,) = hook.liquidityTotals();
        assertLt(contributed, uint256(lAtBirth) / 50, "the roster still holds real depth");
        console.log("premium distributed at maturity (wei)", owed);
        console.log("as bps of the roster's capital in that token", FullMath.mulDiv(owed, 10_000, _capital(down)));
        console.log("standing depth left, of", contributed, uint256(lAtBirth));
    }

    /// @dev What the five seats put in, in the token the pot is denominated in. The premium is
    ///      skimmed off the INCOMING token, which on a downward maturity swap is token0.
    function _capital(bool down) internal view returns (uint256 s_) {
        for (uint256 i; i < 5; i++) {
            s_ += down ? init0[i] : init1[i];
        }
    }

    /// @dev The three statements about the pot itself, in their own frame: `_thePremiumReachesTheRoster`
    ///      is at the stack limit without `via_ir` and four more locals is the difference between
    ///      building and not. **All three are the INVERSION of what they were.**
    function _potReachedTheRoster(bool down) internal view returns (uint256 owed) {
        (uint256 owed0, uint256 owed1, uint256 held0, uint256 held1) = hook.premiums();
        (uint256 g0, uint256 g1) = hook.growths();
        owed = down ? owed0 : owed1;
        assertGt(owed, 0, "nothing happened: the terminal fill withheld no premium at all");
        assertEq(down ? held0 : held1, 0, "the pot was HELD: the ledger cannot source the next fill");
        assertGt(down ? g0 : g1, 0, "the accumulator did not move: the pot reached nobody");
    }

    /// @dev Settle one seat and assert its credit is its own share of the depth it contributed.
    ///      **THE PREDICTION IS BUILT FROM THE CONTRACT'S OWN NUMBERS** — `seatLiquidity` and
    ///      `liquidityTotals`, read before any settle moves anything — never from the fixture's
    ///      measurements of itself (PITFALLS 5.34). The allowance is TWO wei and it is derived, not
    ///      picked: `_accruePremium` floors `inc = pot·Q/standingL` and `_claims` floors
    ///      `L_i·inc/Q`, so a seat can lose at most one wei to each.
    function _settleAndCheckShare(uint256 i, bool down, uint256 pot, uint256 standingL_)
        internal
        returns (uint256 got)
    {
        (uint256 b0, uint256 b1) = hook.rawSeat(i);
        vm.prank(hook.ownerOf(i));
        hook.withdraw(i, 0, 0);
        (uint256 a0, uint256 a1) = hook.rawSeat(i);
        got = down ? a0 - b0 : a1 - b1;
        assertEq(down ? a1 : a0, down ? b1 : b0, "the settle credited the token the pot is not in");

        uint256 want = FullMath.mulDiv(pot, hook.seatLiquidity(i), standingL_);
        assertGt(want, 0, "this seat contributed no depth: the share assertion is vacuous");
        assertLe(got, want, "a seat was credited MORE than its share of the depth it contributed");
        assertGe(got + 2, want, "a seat was credited LESS than its share, beyond the two floors");
    }

    function _thePremiumReachesTheRoster(bool down) internal {
        uint128 lAtBirth = hook.positionLiquidity();
        if (down) _matureDown();
        else _matureUp();

        uint256 owed = _potReachedTheRoster(down);

        // The sweep really was TOTAL: the fill reached the tail. Asserted on the cursor rather than
        // inferred from the accumulator, so this is a second witness and not a restatement.
        (uint256 k0, uint256 k1) = hook.cursors();
        assertGe(down ? k1 : k0, 4, "the fill did not reach the tail: this is not the terminal fill");

        // **EVERY SEAT'S CLAIM IS REAL AND IS ITS OWN SHARE.** Read the denominator BEFORE the first
        // settle, because a settle moves balances and a later read would be a different number.
        (uint256 standingL_,,) = hook.liquidityTotals();
        uint256 credited;
        for (uint256 i; i < 5; i++) {
            credited += _settleAndCheckShare(i, down, owed, standingL_);
        }
        // THE IDENTITY, not a bound: what the roster was credited plus what is still owed is what
        // was withheld. Five seats, at most two wei of floor each.
        (uint256 rest0, uint256 rest1,,) = hook.premiums();
        assertEq(credited + (down ? rest0 : rest1), owed, "the pot did not conserve across the distribution");
        assertLe(down ? rest0 : rest1, 10, "more than the per-seat floor was left unclaimed");

        // The whole roster now takes everything it owns...
        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "premium exit");
        }
        (uint256 t0, uint256 t1) = hook.totals();
        assertLt(t0 + t1, 1_000, "the roster did not actually exit: this test proves nothing");

        // ...and there is NOTHING LEFT. This is the inversion that matters: the position used to
        // hold the whole pot after a full exit, reachable only by a function that does not exist in
        // `src/`. `QueueHarness.redeemAll` is TEST-ONLY — a permissionless position burn was removed
        // from the shipping contract as pure griefing — so it is the strongest possible reader here,
        // and it now finds residual scale rather than the premium.
        (uint256 r0, uint256 r1) = hook.redeemAll();
        assertLt(r0 + r1, 1_000, "the position still holds the premium after a full exit");
        assertGt(owed, 1_000, "the pot was residual scale to begin with: this test proves nothing");

        _reportStranding(down, owed, lAtBirth);
    }

    /// @notice **THE CONTROL THAT COULD FALSIFY THE ABOVE.** Same pool, same maturity swap, same
    ///         exit — φ = 0. There is no pot to strand, so the position leftover MUST collapse to
    ///         residual scale. If it did not, `test_M7`'s leftover would be measuring the §E.4
    ///         rounding residual or a withdrawal bug rather than the premium, and the finding would
    ///         be wrong.
    function test_M7c_atPhiZeroNothingIsStranded() public {
        _rebuildAtPhi(0x4D02, 0);
        _matureDown();

        (uint256 owed0,,,) = hook.premiums();
        assertEq(owed0, 0, "the control pool withheld a premium: it is not a control");

        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "phi-zero exit");
        }
        (uint256 r0, uint256 r1) = hook.redeemAll();
        assertLt(r0 + r1, 1_000, "the phi-zero pool stranded capital: the M7 leftover is not the premium");
    }

    // ------------------------------------------------------------------------------------- rent

    /// @notice **MUST BE DISCLOSED — a holder goes on paying rent on an instrument that can never
    ///         earn again, and the only way to stop is to give up the price on the seat.**
    ///
    /// @dev Rent is a pure time integral (`Rent.owed(price, elapsed, ...)`). Nothing in
    ///      `_settleSeat` looks at the band, the position, or whether the pool can still fill, so a
    ///      seat priced at maturity bleeds at exactly the rate it bled while the instrument was
    ///      alive. That is not an accident and it is not obviously wrong — an unpriced seat is free
    ///      to take, so the price is what the holder pays to keep the rank they may want in the
    ///      NEXT deployment. But it means a holder who walks away from a dead pool with a live price
    ///      keeps paying until the escrow empties and the seat forecloses.
    ///
    ///      The exit exists and is asserted here: `setSelfPrice(id, 0)` stops the meter dead. It
    ///      costs the holder the seat's sale price and its protection, which is the honest trade.
    function test_M8_rentStillAccruesOnADeadInstrumentAndTheOnlyExitIsToUnpriceTheSeat() public {
        _matureDown();

        uint256 price = 100e18;
        _fund(A, 10e18, 0);
        vm.startPrank(A);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        hook.setSelfPrice(0, price);
        vm.stopPrank();
        vm.prank(A);
        hook.fundRent(0, 10e18);

        (, uint256 esc0,,,) = hook.leaseOf(0);
        assertEq(esc0, 10e18, "the meter was not funded");

        vm.warp(block.timestamp + 30 days);
        assertGt(hook.rentDue(0), 0, "nothing happened: no rent accrued on the dead pool");
        hook.settleRent(0);

        (, uint256 esc1,,,) = hook.leaseOf(0);
        uint256 charged = esc0 - esc1;
        // The IDENTITY, not a bound: what the meter lost is exactly what the formula says it owes.
        assertEq(charged, (price * RENT_BPS * 30 days) / (10_000 * RENT_PERIOD), "the bill is not the rent formula");
        assertGt(charged, 0, "the meter did not move on a dead instrument");

        // THE EXIT. Unprice the seat and the meter stops, whatever the price does afterwards.
        vm.prank(A);
        hook.setSelfPrice(0, 0);
        vm.warp(block.timestamp + 365 days);
        (, uint256 esc2,,,) = hook.leaseOf(0);
        hook.settleRent(0);
        (, uint256 esc3,,,) = hook.leaseOf(0);
        assertEq(esc3, esc2, "unpricing the seat did not stop the meter");
        assertEq(hook.rentDue(0), 0, "an unpriced seat still shows rent due");
    }

    /// @notice **DEFECT-GRADE ASYMMETRY — ABOVE the band, rent charged goes to NOBODY.**
    ///
    /// @dev `_distributeRent` splits pro-rata by the recipients' `currency0` balance. Above the band
    ///      every seat is 100% currency1, so `w == 0` on every settlement, the payer's escrow is
    ///      debited anyway (it must be, or the balance identity breaks), and the money lands in
    ///      `unallocatedRent0` — a pot with no reader anywhere in `src/` except the next
    ///      distribution. At maturity above the band there is no next distribution with a recipient,
    ///      so the rent is charged and burnt.
    ///
    ///      **BELOW the band the identical code pays out perfectly**, because there every seat is
    ///      100% currency0. That is the whole point of running this in both directions: the rent
    ///      mechanism is intact in one terminal state and inert in the mirrored one, and a
    ///      single-direction test would have reported whichever half it happened to pick.
    function test_M9_rentIsDistributedProportionallyBelowTheBand() public {
        _matureDown();
        (uint256 credited, uint256 unalloc) = _chargeRentAtTail();
        assertGt(credited, 0, "below the band the rent reached nobody");
        assertEq(unalloc, 0, "below the band the rent was stranded");
    }

    /// @notice **ABOVE THE BAND EVERY RECIPIENT HOLDS ZERO currency0, AND THE DEPTH-WEIGHTED RULE
    ///         STILL PAYS THEM IN FULL.**
    ///
    /// @dev **RE-AIMED IN PHASE 12, AT A STRICTLY STRONGER CLAIM.** This test used to hunt for a
    ///      recipient holding a few wei of currency0 and bound how much of the pot it could take —
    ///      the `test_M9b` identity that caught "a seat standing with 1 wei claimed 100% of a
    ///      2.667e17 pot" back when rent was split by `a0`.
    ///
    ///      Rent now moves FORWARD, so the recipients are the seats AHEAD of the payer — and
    ///      front-first allocation converts those out of currency0 FIRST and most completely. Above
    ///      the band they hold **exactly zero**, not dust. So the old fixture cannot be built here:
    ///      there is no "dust holder" to bound.
    ///
    ///      **That makes the same defect testable as a BRANCH rather than as a share, which is a
    ///      better control, not a weaker one.** With every recipient at zero currency0, an
    ///      `a0`-weighted rule computes `w == 0` and HOLDS the entire pot; the depth-weighted rule
    ///      the contract actually implements distributes all of it. The two answers are `unalloc ==
    ///      charged` and `unalloc == 0` — maximally far apart, with nothing in between for a
    ///      tolerance to hide in. Reverting production to `a0` therefore turns this red on the very
    ///      first assertion instead of on a magnitude.
    ///
    ///      AGENTS §3 LAW 5's question — what would have to be true for this to read FAIL? Weight
    ///      by any currency BALANCE and the pot is held. Weight by contributed depth and it is paid.
    ///      Both are real implementations and the test separates them.
    function test_M9b_zeroCurrency0RecipientsAreStillPaidByDepthAboveTheBand() public {
        _matureUp();

        // Establish the state first, or the claim below is about a fixture nobody can place.
        uint256 balanceWeight;
        uint256 depthAhead;
        for (uint256 i; i < 4; i++) {
            uint256 id = hook.idAtRank(i);
            (uint256 a0, uint256 a1) = hook.seat(id);
            balanceWeight += a0;
            depthAhead += hook.seatLiquidity(id);
            assertGt(a1, 1e17, "a seat ahead of the payer holds no real capital at all");
            assertGt(hook.seatLiquidity(id), 0, "a recipient contributed no depth: fixture is wrong");
        }
        // THE STATE THAT WOULD BE FATAL TO A BALANCE-WEIGHTED RULE, asserted so the test proves it
        // was reached: the whole recipient set is worth ZERO on the old weight.
        assertEq(balanceWeight, 0, "the recipients still hold currency0: this is not the branch under test");
        assertGt(depthAhead, 0, "nobody ahead contributes depth: this is the w == 0 case, not this one");

        uint256[4] memory before_;
        for (uint256 i; i < 4; i++) {
            (, before_[i],,,) = hook.leaseOf(hook.idAtRank(i));
        }
        (uint256 credited, uint256 unalloc) = _chargeRentAtTail();

        // **THE BRANCH, AND IT IS THE WHOLE POINT.** An `a0`-weighted rule holds all of this.
        assertEq(unalloc, 0, "the rent was held rather than distributed: the weight is a BALANCE, not depth");
        assertGt(credited, 1e17, "nothing happened: no rent was charged, this test proves nothing");

        // **THE EXACT IDENTITY IS THE SUM, NOT THE PER-SEAT FLOOR.** `Allocation`'s remainder line
        // closes the split to the wei against the total, so one seat absorbs the residue of four
        // floored divisions. Asserting a per-seat `floor(pot*Li/W)` would therefore be WRONG by
        // exactly that residue, and widening it to an approximate match would be a tolerance chosen
        // to pass. So: the SUM is pinned exactly, each seat is pinned to its floor from BELOW, and
        // the residue is bounded by what the floors actually left over — every one of those numbers
        // comes from the CONTRACT (`seatLiquidity`), never from a fixture-side measurement
        // (PITFALLS 5.34).
        uint256 paid;
        uint256 floors;
        uint256 worst;
        for (uint256 i; i < 4; i++) {
            uint256 id = hook.idAtRank(i);
            (, uint256 e1,,,) = hook.leaseOf(id);
            uint256 g = e1 - before_[i];
            uint256 f = (credited * hook.seatLiquidity(id)) / depthAhead;
            assertGe(g, f, "a seat ahead was paid LESS than its floored depth share");
            assertGt(g, 0, "a recipient with real depth was floored to ZERO");
            if (g > worst) worst = g;
            paid += g;
            floors += f;
        }
        assertEq(paid, credited, "the distribution did not sum to the pot");
        assertLt(worst, credited, "one seat took the ENTIRE pot: the weight did not move off a balance");
        console.log("recipients' currency0 balance weight", balanceWeight);
        console.log("recipients' contributed depth       ", depthAhead);
        console.log("pot distributed                     ", credited);
    }

    /// @notice The `w == 0` branch itself, reached deliberately: charge the TAIL, which has nobody
    ///         behind it at all. The money leaves the payer's escrow and lands in `unallocatedRent0`
    ///         — a pot with no reader anywhere in `src/` but the next distribution, and at maturity
    ///         there is no next distribution with a recipient.
    /// @dev **INVERTED IN PHASE 12: THE SEAT WITH NOBODY TO PAY IS NOW RANK 0, NOT THE TAIL.** Rent
    ///      moves forward, so the front seat is the one that structurally has no recipient — and
    ///      that is correct rather than a gap: rank 0 buys protection from nobody, so it owes
    ///      nobody. Everything this test asserts about the held-pot identity is unchanged.
    function test_M9c_rentFromTheHeadIsHeldWithNobodyToPayItTo() public {
        _matureUp();
        uint256 payer = hook.idAtRank(0);
        address who = hook.ownerOf(payer);
        _fund(who, 10e18, 0);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        hook.setSelfPrice(payer, 100e18);
        hook.fundRent(payer, 10e18);
        vm.stopPrank();

        (, uint256 unallocBefore) = hook.rentTotals();
        (, uint256 e0,,,) = hook.leaseOf(payer);
        vm.warp(block.timestamp + 30 days);
        hook.settleRent(payer);
        (, uint256 e1,,,) = hook.leaseOf(payer);
        (, uint256 unallocAfter) = hook.rentTotals();

        uint256 charged = e0 - e1;
        assertGt(charged, 0, "nothing happened: the head was not charged");
        // THE IDENTITY the `_distributeRent` docstring states:
        //     Sigma credited + unallocatedAfter == charged + unallocatedBefore
        // with Sigma credited == 0 on this branch, because there is nobody ahead of rank 0.
        assertEq(unallocAfter, charged + unallocBefore, "the held-rent identity does not close");
        _checkInvariantR("after a head rent settlement at maturity");
    }

    /// @dev Charge one seat's rent and report where it went: `Σ credited` to the seats behind, and
    ///      what fell into `unallocatedRent0`. Reads the CONTRACT's escrows on both sides — nothing
    ///      here is a fixture-side re-derivation (PITFALLS 5.34).
    /// @dev **PHASE 12: THE PAYER IS THE TAIL, NOT RANK 0.** Rent moves FORWARD, so a charge from
    ///      rank 0 has no recipient and lands in the held pot — under which every "the rent reached
    ///      somebody" assertion in this suite holds vacuously at zero. The held branch still has a
    ///      directed test; it is `test_M9c`, inverted onto rank 0 for the same reason.
    function _chargeRentAtTail() internal returns (uint256 credited, uint256 unalloc) {
        uint256 payer = hook.idAtRank(4);
        address who = hook.ownerOf(payer);
        _fund(who, 10e18, 0);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        hook.setSelfPrice(payer, 100e18);
        hook.fundRent(payer, 10e18);
        vm.stopPrank();

        uint256 aheadBefore = _escrowsAhead(4);
        (, uint256 e0,,,) = hook.leaseOf(payer);
        vm.warp(block.timestamp + 30 days);
        hook.settleRent(payer);
        (, uint256 e1,,,) = hook.leaseOf(payer);

        assertGt(e0 - e1, 0, "nothing happened: the payer was not charged");
        credited = _escrowsAhead(4) - aheadBefore;
        (, unalloc) = hook.rentTotals();
        _checkInvariantR("after a maturity rent settlement");
    }

    function _escrowsAhead(uint256 rank) internal view returns (uint256 s) {
        for (uint256 i; i < rank; i++) {
            (, uint256 e,,,) = hook.leaseOf(hook.idAtRank(i));
            s += e;
        }
    }

    // ----------------------------------------------------------------------------------- buyout

    /// @notice The buyout still works at maturity, in both directions. §B.8 made the evacuation
    ///         path unblockable ON PURPOSE, and a revert here would hand every incumbent a veto on
    ///         their own buyout at exactly the moment the seat is worth arguing about.
    function test_M10_aSeatCanStillBeBoughtBelowTheBand() public {
        _matureDown();
        _buyoutStillWorks("below");
    }

    function test_M10b_aSeatCanStillBeBoughtAboveTheBand() public {
        _matureUp();
        _buyoutStillWorks("above");
    }

    function _buyoutStillWorks(string memory dir) internal {
        address mallory = address(0x11A11);
        uint256 seatId = hook.idAtRank(0);
        address seller = hook.ownerOf(seatId);

        vm.prank(seller);
        hook.setSelfPrice(seatId, 50e18);

        (uint256 was0, uint256 was1) = hook.seat(seatId);
        assertTrue(was0 != 0 || was1 != 0, "nothing happened: the seat is empty, the buyout proves nothing");

        _fund(mallory, 100e18, 0);
        uint256 sellerBefore = MockERC20(Currency.unwrap(c0)).balanceOf(seller);
        vm.prank(mallory);
        hook.buySeat(seatId, 50e18, 10e18);

        assertEq(hook.ownerOf(seatId), mallory, string.concat(dir, ": the buyout was blocked at maturity"));
        (uint256 now0, uint256 now1) = hook.seat(seatId);
        assertEq(now0 + now1, 0, string.concat(dir, ": the seat did not leave EMPTY - rank carried depth"));

        // The seller was paid: the capital came out (or is claimable) and the price was credited.
        uint256 gained = MockERC20(Currency.unwrap(c0)).balanceOf(seller) - sellerBefore;
        (uint256 pend0, uint256 pend1) = hook.pendingOf(seller);
        assertGt(gained + pend0 + pend1, 0, string.concat(dir, ": the seller received nothing"));
        assertEq(pend0 + gained >= 50e18, true, string.concat(dir, ": the seller was not paid the price"));

        _checkInvariantF(string.concat(dir, " after a maturity buyout"), 1_000);
        _checkInvariantR(string.concat(dir, " after a maturity buyout"));
        // INVARIANT L is DELIBERATELY NOT asserted here. It BREAKS on this path, and it breaks in
        // band as well as at maturity — see `test_M12`, which is the finding rather than a
        // side-effect of this one. Asserting it here too would report one defect as three.
    }

    // =============================================================================================
    // 5. THE SWEEP — does it strand float out of range?
    // =============================================================================================

    /// @notice **MUST BE DISCLOSED — out of band `sweepFloatIntoPosition` deploys the live token and
    ///         PERMANENTLY STRANDS the other one in the float.** It does not revert and it loses
    ///         nobody a wei, but pool depth stops being restorable.
    ///
    /// @dev This is a property of a fixed-range v4 position rather than a bug in the sweep:
    ///      out of range the position can only hold one token, so `_liquidityForAmounts` correctly
    ///      sizes on that leg alone and the other one has nowhere to go. It matters because the
    ///      sweep's own comment calls it REQUIRED — "without this, pool depth degrades monotonically
    ///      as the queue is used" — and at maturity that guarantee is simply switched off in one
    ///      direction. The float is still owed to the seats by INVARIANT F, so the exposure is
    ///      depth, not capital.
    function test_M11_theSweepStrandsTheDeadSideBelowTheBand() public {
        _matureDown();
        _sweepOutOfBand("below", true);
    }

    function test_M11b_theSweepStrandsTheDeadSideAboveTheBand() public {
        _matureUp();
        _sweepOutOfBand("above", false);
    }

    /// @param liveIsZero which token the out-of-range position can still absorb.
    function _sweepOutOfBand(string memory dir, bool liveIsZero) internal {
        // Put REAL float on both sides, through the production deposit path.
        _fund(D, 5e18, 5e6);
        vm.prank(D);
        hook.addToSeat(3, 5e18, 5e6);

        (uint256 f0, uint256 f1) = hook.floats();
        assertGt(liveIsZero ? f1 : f0, 0, "nothing happened: there is no dead-side float to strand");

        uint128 lBefore = hook.positionLiquidity();
        uint128 added = hook.sweepFloatIntoPosition();
        (uint256 g0, uint256 g1) = hook.floats();

        assertGt(uint256(added), 0, string.concat(dir, ": the sweep deployed nothing at all"));
        assertEq(
            uint256(hook.positionLiquidity()), uint256(lBefore) + uint256(added), "the sweep mis-reported what it added"
        );
        // The live side went to work...
        assertLt(liveIsZero ? g0 : g1, liveIsZero ? f0 : f1, string.concat(dir, ": the live float was not deployed"));
        // ...and the dead side did not move, and a second sweep cannot move it either.
        assertEq(liveIsZero ? g1 : g0, liveIsZero ? f1 : f0, string.concat(dir, ": the dead float moved"));
        assertEq(uint256(hook.sweepFloatIntoPosition()), 0, "a second sweep found work the first one left");
        (uint256 h0, uint256 h1) = hook.floats();
        assertEq(liveIsZero ? h1 : h0, liveIsZero ? f1 : f0, string.concat(dir, ": the dead float is not stranded"));

        _checkInvariantF(string.concat(dir, " after an out-of-band sweep"), 1_000);
        _checkInvariantL(string.concat(dir, " after an out-of-band sweep"));
        _checkInvariantR(string.concat(dir, " after an out-of-band sweep"));
    }

    // =============================================================================================
    // 6. THE DEFECT THIS SUITE FOUND. It is NOT a maturity bug — maturity is only where it is
    //    unavoidable. **DO NOT FIX FROM HERE.** Reported to the owner; `src/queue/QueueHook.sol` is
    //    owned by another workstream this session.
    // =============================================================================================

    /// @notice **DEFECT — `_onSeatTransfer` DELETES A SEAT'S CONTRIBUTED LIQUIDITY WITHOUT
    ///         DESTROYING OR RE-ATTRIBUTING THE DEPTH, AND INVARIANT L BREAKS BY THE DIFFERENCE.**
    ///
    /// @dev The seat evacuation zeroes `s.liquidity` and takes the WHOLE of it out of `standingL`:
    ///
    ///          uint128 had = s.liquidity;
    ///          if (had != 0) { s.liquidity = 0; standingL -= had; }
    ///          uint256 rest = burnedOnExit > had ? burnedOnExit - had : 0;   // <-- one direction
    ///          if (rest != 0) { ... liquidityUnattributed / liquidityShortfall ... }
    ///
    ///      That is correct when the exit BURNS at least as much depth as the seat contributed. The
    ///      MIRROR CASE IS NOT HANDLED: when `_payOut` burns LESS than `had` — or nothing at all,
    ///      because the float covered the whole payout — the difference `had - burnedOnExit` is
    ///      simply deleted from the ledger. The depth is still in the v4 position; no pot records
    ///      it; `liquidityShortfall`, which exists to measure exactly this residue, does not see it
    ///      because it is only ever fed from the `rest` branch above.
    ///
    ///      **This is the §5 asymmetry lens exactly: two branches of one comparison, one of them
    ///      written.** `withdraw`'s `_chargeBurn` gets it right — it debits only `min(burned,
    ///      s.liquidity)` and never more — so the two writers of `liquidityContributed` disagree.
    ///
    ///      **WHY NOTHING CAUGHT IT.** INVARIANT L is not in the Phase 6/8 invariant campaign — the
    ///      campaign has I1-I8e and no L — and the six directed tests that do call
    ///      `_checkInvariantL` never call it after an evacuation whose payout the float could
    ///      cover. `Evacuation.t.sol`'s "sybil buyout episode" comes closest and passes, because in
    ///      mid-band a seat still holds BOTH tokens and the token1 leg forces a burn of roughly the
    ///      seat's whole contribution.
    ///
    ///      **CONSEQUENCE.** `standingL` is the premium's denominator. Each evacuation on this path
    ///      erases one seat's depth from it while the depth goes on earning inside the position,
    ///      credited to nobody and recorded nowhere. Drive `standingL` to zero this way and
    ///      `_accruePremium`'s `w == 0` branch holds every pot for ever — the Phase 7/8 mechanism
    ///      switches itself off while the fee flow it is a share of continues. No token is lost:
    ///      INVARIANT F and INVARIANT R both still hold, and they are asserted below so the scope of
    ///      the claim is exact.
    ///
    ///      **STATUS: FIXED, AND THIS IS NOW THE REGRESSION TEST.** It was written RED, asserting
    ///      the CORRECT behaviour rather than the observed one — writing the broken identity down as
    ///      if it were the specification is how a defect becomes a feature — and it stayed red until
    ///      the missing branch landed in `QueueHook.sol` (~line 1987,
    ///      `if (had > burnedOnExit) liquidityUnattributed += had - burnedOnExit;`). It is green
    ///      because the hook changed, not because the assertion did. `test_M12c` is the standing
    ///      guard that fires if that line is ever removed.
    function test_M12_evacuationOrphansDepthWhenTheFloatCoversThePayout() public {
        // ---- IN BAND. The price never leaves the band, so nothing about this is about maturity.
        _swapper().swapTo(k, true, 12e18, TickMath.getSqrtPriceAtTick(-24000));
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        (,, int24 tl, int24 tu) = hook.pool();
        assertTrue(tick >= tl && tick < tu, "the setup swap left the band: this is not the in-band case");
        _checkInvariantL("in band, before the buyout");

        // The head has been drained of token1 by an ordinary front-first fill. That is the DESIGN,
        // not an edge case: INVARIANT C says every seat below `cursor1` holds zero token1.
        uint256 seatId = hook.idAtRank(0);
        (uint256 a0, uint256 a1) = hook.seat(seatId);
        assertEq(a1, 0, "the head still holds token1: the float cannot cover the whole payout");
        assertGt(a0, 0, "the head holds nothing: this test proves nothing");

        // A buyout credits the price into `float0` BEFORE the evacuation pays out, so a price above
        // the head's token0 balance means `_payOut` burns nothing at all.
        address seller = hook.ownerOf(seatId);
        vm.prank(seller);
        hook.setSelfPrice(seatId, 50e18);
        assertGt(50e18, a0, "the price does not cover the seat: the float will not absorb the payout");

        uint128 seatL = hook.seatLiquidity(seatId);
        uint128 posBefore = hook.positionLiquidity();
        assertGt(uint256(seatL), 0, "the seat contributed no depth: this test proves nothing");

        address mallory = address(0x11A11);
        _fund(mallory, 100e18, 0);
        vm.prank(mallory);
        hook.buySeat(seatId, 50e18, 10e18);

        // The depth is STILL IN THE POSITION — nothing was burned...
        assertEq(uint256(hook.positionLiquidity()), uint256(posBefore), "the exit burned depth: wrong case");
        // ...and the seat's contribution has been deleted from every ledger that tracked it.
        assertEq(uint256(hook.seatLiquidity(seatId)), 0, "the seat kept its contribution");
        (uint256 contributed, uint256 unattributed, uint256 shortfall) = hook.liquidityTotals();
        console.log("orphaned depth (wei of L)", uint256(seatL));
        console.log("contributed / unattributed", contributed, unattributed);
        console.log("shortfall", shortfall);

        // Tokens are NOT lost. Stating the scope precisely is part of the finding.
        _checkInvariantF("in band after the buyout", 1_000);
        _checkInvariantR("in band after the buyout");

        // THE CLAIM. The depth left behind belongs in `liquidityUnattributed` — the pot whose whole
        // purpose is depth that is credited to nobody — exactly as `sweepFloatIntoPosition` puts it
        // there. This is what the missing branch would do, and it is what INVARIANT L requires.
        _checkInvariantL("IN BAND, after a buyout whose payout the float covered");
    }

    /// @notice The same defect at maturity, where it is not a corner case but the ordinary shape of
    ///         every buyout: out of range a seat holds ONE token, so a buyout priced in currency0
    ///         below the band funds the entire payout from the float by construction.
    ///
    /// @dev **FIXED; regression test.** See `test_M12`.
    function test_M12b_theSameDefectIsTheDefaultShapeOfAMaturityBuyout() public {
        _matureDown();
        uint256 seatId = hook.idAtRank(0);
        (uint256 a0, uint256 a1) = hook.seat(seatId);
        assertEq(a1, 0, "below the band the seat still holds token1");
        assertGt(a0, 0, "the seat holds nothing");

        address seller = hook.ownerOf(seatId);
        vm.prank(seller);
        hook.setSelfPrice(seatId, 50e18);

        uint128 posBefore = hook.positionLiquidity();
        address mallory = address(0x11A11);
        _fund(mallory, 100e18, 0);
        vm.prank(mallory);
        hook.buySeat(seatId, 50e18, 10e18);

        assertEq(uint256(hook.positionLiquidity()), uint256(posBefore), "the exit burned depth: wrong case");
        _checkInvariantF("maturity buyout", 1_000);
        _checkInvariantL("AT MATURITY, after a buyout whose payout the float covered");
    }

    // =============================================================================================
    // 7. THE CONTROLS. LAW 5: before believing any of the above, break the line it covers and watch
    //    it go red. `script/mutate.py` is not run here and `src/` is not edited — both are owned
    //    elsewhere this session — so each control is a SUBCLASS that changes exactly one thing,
    //    which is the same idiom `Controls.t.sol` and `Premium.t.sol` already use.
    // =============================================================================================

    /// @dev Deploy a chosen mutant over the same roster, same φ, same pool shape, and seed it
    ///      identically. One deviation, everywhere else production.
    function _rebuildAs(string memory artifact, uint160 nonce, uint256 phi) internal {
        address a = address(FLAGS ^ (nonce << 144));
        address[] memory r = new address[](5);
        for (uint256 i; i < 5; i++) {
            r[i] = holders[i];
        }
        deployCodeTo(artifact, _ctorArgsPremium(r, phi), a);
        hook = QueueHarness(a);
        _initPool();
        _fundEverySeat();
    }

    /// @notice **THE CONTROL FOR `test_M6`, and it is the kind LAW 5's second corollary asks for:
    ///         its answer is known IN ADVANCE — it is the corollary AGENTS.md LAW 5 states in so
    ///         many words.** Under AVERAGE pricing every seat in a fill is credited at the swap's
    ///         own average rate BY CONSTRUCTION, so five seats that started with identical capital
    ///         must end identical: the 449 bps head-to-tail gap has to collapse, while the maturity
    ///         itself — one-sided position, front-first drain, real money on every seat — survives
    ///         untouched. Only the PRICE CURVE is removed; the ordering is production's.
    ///
    /// @dev If this did NOT collapse, `test_M6` would be measuring something other than where in
    ///      the move each rank was filled — the deposit split, the decimals, the price path — and
    ///      "being first in line means being first into the losing side" would be unsupported.
    ///      `MutantQueueHook` in `AVERAGE_PRICE` mode is the project's own N6 control, reused rather
    ///      than rewritten. (`PRO_RATA` was tried first and is the WRONG control here: it replaces
    ///      the ordering as well as the pricing, and its hand-rolled remainder line underflows on a
    ///      fill that sweeps the whole book — it would have gone red for a reason that has nothing
    ///      to do with the claim, which is the LAW 2 failure this project keeps paying for.)
    function test_M6c_underAveragePricingTheRankEffectDisappears() public {
        address a = address(FLAGS ^ (uint160(0x4D03) << 144));
        address[] memory r = new address[](5);
        for (uint256 i; i < 5; i++) {
            r[i] = holders[i];
        }
        // φ = 0: `MutantQueueHook` overrides `_allocate` wholesale and does not run the premium at
        // all, so a non-zero φ would be a SECOND difference from production and the control would
        // die of the difference it is not testing (LAW 2).
        deployCodeTo("Controls.t.sol:MutantQueueHook", _ctorArgsPremium(r, 0), a);
        MutantQueueHook(a).setMode(MutantQueueHook(a).AVERAGE_PRICE());
        hook = QueueHarness(a);
        _initPool();
        _fundEverySeat();

        _matureDown();
        (, uint256 d1) = _positionComposition();
        assertEq(d1, 0, "the control pool did not mature: it is not comparable");

        (uint256 head,) = hook.seat(0);
        (uint256 tail,) = hook.seat(4);
        assertGt(head, 1e18, "nothing happened: the control's head holds no money");
        uint256 gapBps =
            head > tail ? FullMath.mulDiv(head - tail, 10_000, tail) : FullMath.mulDiv(tail - head, 10_000, head);
        console.log("average-priced head-to-tail gap, bps", gapBps);
        // Production measures 449 bps here (`test_M6`). Average pricing cannot produce a rank
        // effect at all, so anything above rounding would mean the instrument is reading something
        // else.
        assertLt(gapBps, 10, "the rank effect survived average pricing: test_M6 measures something else");
    }

    /// @notice **THE CONTROL FOR `test_M7`, `test_M7f` AND `test_M13`, AND IT IS WHAT MAKES THEM
    ///         FALSIFIABLE.** Delete the `sweptBook` branch and the terminal fill holds the whole
    ///         pot again, no seat can claim a wei of it, and once the roster exits the pool BRICKS.
    ///
    /// @dev **THE ASSERTIONS ARE THE PRE-FIX BEHAVIOUR, EXECUTED RATHER THAN DESCRIBED.** Each one
    ///      is the exact inverse of an assertion `test_M7`/`test_M7f` makes on production:
    ///
    ///        * `premGrowth` does not move / production: it does;
    ///        * the pot lands whole in `premiumHeld` / production: `premiumHeld == 0`;
    ///        * a settle credits no seat anything / production: every seat gets its pro-rata share;
    ///        * after a full exit the position still holds the pot and every one-for-zero swap
    ///          reverts `QueueUnderflow` / production: the position is empty and the swap goes
    ///          through.
    ///
    ///      If any of these fails, the fix is not what closed those tests and they prove nothing.
    ///
    ///      **THE BRICK IS THE HALF THAT MATTERS AND IT IS ASSERTED BY REASON, NOT BY "IT
    ///      REVERTED"** (LAW 2). v4 wraps a hook's own error in `CustomRevert.WrappedError`, so the
    ///      selector is unwrapped before it is matched (PITFALLS 5.83/5.84).
    function test_M7d_deletingTheSweptBookBranchStrandsThePotAndBricksThePool() public {
        _rebuildAs("Maturity.t.sol:NoSweptBookQueueHook", 0x4D04, PHI);
        _matureDown();

        (uint256 owed0,, uint256 held0,) = hook.premiums();
        (uint256 g0,) = hook.growths();
        assertGt(owed0, 0, "the control withheld no premium: it is not comparable");
        assertEq(g0, 0, "the accumulator moved WITHOUT the branch: test_M7 cannot fail");
        assertEq(held0, owed0, "the pot was not held whole without the branch: test_M7 cannot fail");
        console.log("without the swept-book branch: held", held0);

        // No seat can claim a wei of it — a settle moves nothing.
        for (uint256 i; i < 5; i++) {
            (uint256 b0, uint256 b1) = hook.rawSeat(i);
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
            (uint256 a0, uint256 a1) = hook.rawSeat(i);
            assertEq(a0, b0, "a seat was credited token0 the accumulator says does not exist");
            assertEq(a1, b1, "a seat was credited token1 the accumulator says does not exist");
        }

        // ...and after the exit the pool advertises depth it cannot trade.
        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "control exit");
        }
        assertGt(uint256(hook.positionLiquidity()), 0, "the position is empty: nothing to be bricked");
        (uint256 stillThere,) = _positionValue();
        assertApproxEqAbs(stillThere, owed0, 1_000, "the position leftover is not the stranded premium");

        bytes memory reason = _expectSwapRevert(
            false, 1e20, bytes4(keccak256("QueueUnderflow(uint256)")), "the control did NOT brick: test_M7f cannot fail"
        );
        assertApproxEqAbs(uint256(bytes32(_word(reason))), owed0, 1_000, "the shortfall is not the stranded premium");
    }

    /// @notice **THE STANDING GUARD ON THE INVARIANT L BRANCH. Delete line ~1987 of
    ///         `QueueHook.sol` and this test goes RED.**
    ///
    /// @dev It ran as `test_M12c` in its first life and proved the opposite thing: production
    ///      `_onSeatTransfer` plus the one missing line, after which L, F and R all closed and
    ///      `unattributed == seatL` to the wei. That is what got the line written. Once it was in
    ///      production the subclass applied it a SECOND time and read `8.0e19 != 4.0e19` — an
    ///      equivalent mutant of its own fix. It is inverted rather than deleted (M59: a retired case
    ///      with a reason is evidence, a deleted one is a gap).
    ///
    ///      **TWO ASSERTIONS, AND THEY ARE DIFFERENT CLAIMS.** First, that the project's own
    ///      instrument fires — `_checkInvariantL`, the same function eleven other call sites rely
    ///      on, is executed against the unfixed hook and must revert. Second, that the gap has the
    ///      RIGHT SHAPE: it is exactly the departing seat's contributed liquidity, to the wei. The
    ///      first without the second would pass if L broke for any unrelated reason; the second
    ///      without the first would not prove the instrument can see it. Neither is a bound.
    ///
    ///      **AND A POSITIVE CONTROL, because a negative one alone proves nothing** (§3b): the
    ///      identical sequence on the SHIPPING hook, where the same gap must close to zero. Without
    ///      it, a subclass that broke L some other way — or a fixture that never reached the
    ///      float-covered path at all — would read as success.
    function test_M12c_deletingTheInvariantLBranchIsCaughtByTheInstrument() public {
        // ---- NEGATIVE: production minus the branch.
        _rebuildAs("Maturity.t.sol:UnfixedTransferQueueHook", 0x4D05, PHI);
        uint128 seatL = _floatCoveredBuyoutAtTheHead();

        (uint256 contributed, uint256 unattributed, uint256 shortfall) = hook.liquidityTotals();
        uint256 got = contributed + unattributed;
        uint256 want = uint256(hook.positionLiquidity()) + shortfall;
        // THE SHAPE: the ledger is short by exactly the departing seat's contribution.
        assertEq(want - got, uint256(seatL), "the gap is not the orphaned contribution: L broke some other way");

        // THE MATCHER IS CHECKED BEFORE IT IS TRUSTED. `_mentionsInvariantL` returning `true`
        // unconditionally would satisfy every assertion below it, which is the exact tautology LAW 5
        // is about and the one `Adversarial.t.sol`'s `_contains` carries the same warning for. So it
        // is handed a payload it MUST NOT match first.
        assertFalse(
            _mentionsInvariantL(bytes("INVARIANT F token0: some other assertion entirely")),
            "the reason matcher matches anything: every assertion below it is vacuous"
        );

        // THE INSTRUMENT: `_checkInvariantL` itself must fire on this state.
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.probeInvariantL, ()));
        assertFalse(ok, "INVARIANT L did not fire against the unfixed hook: the guard is asleep");
        assertTrue(
            _mentionsInvariantL(err), "INVARIANT L fired for the WRONG reason: the message is not the L mismatch"
        );

        // ---- POSITIVE: the shipping hook, identical sequence, gap closed.
        _rebuildAs("QueueHarness.sol:QueueHarness", 0x4D09, PHI);
        uint128 shippedSeatL = _floatCoveredBuyoutAtTheHead();
        assertGt(uint256(shippedSeatL), 0, "the positive control never reached the float-covered path");

        (contributed, unattributed, shortfall) = hook.liquidityTotals();
        assertEq(
            contributed + unattributed,
            uint256(hook.positionLiquidity()) + shortfall,
            "the SHIPPING hook does not close INVARIANT L on the float-covered path"
        );
        assertEq(unattributed, uint256(shippedSeatL), "production did not book the orphaned depth");
        _checkInvariantL("the shipping hook");
        _checkInvariantF("the shipping hook", 1_000);
        _checkInvariantR("the shipping hook");
    }

    /// @dev The sequence both arms run: mature down, then buy the head at a price its whole
    ///      remaining balance fits inside, so `buySeat` credits the price into `float0` before
    ///      `_payOut` and NOTHING is burned. Returns the contribution the departing seat had, which
    ///      is the quantity both arms are asserted against.
    ///
    ///      It ASSERTS that nothing was burned rather than assuming it: if the position burned, this
    ///      is not the float-covered case and neither arm proves anything (PITFALLS 5.54).
    function _floatCoveredBuyoutAtTheHead() internal returns (uint128 seatL) {
        _matureDown();
        uint256 seatId = hook.idAtRank(0);
        (uint256 a0, uint256 a1) = hook.seat(seatId);
        assertEq(a1, 0, "below the band the seat still holds token1");
        assertGt(a0, 0, "the seat holds nothing: this proves nothing");
        assertGt(50e18, a0, "the price does not cover the seat: the float will not absorb the payout");

        address seller = hook.ownerOf(seatId);
        vm.prank(seller);
        hook.setSelfPrice(seatId, 50e18);

        seatL = hook.seatLiquidity(seatId);
        assertGt(uint256(seatL), 0, "the seat contributed no depth: this proves nothing");
        uint128 posBefore = hook.positionLiquidity();

        address mallory = address(0x11A11);
        _fund(mallory, 100e18, 0);
        vm.prank(mallory);
        hook.buySeat(seatId, 50e18, 10e18);

        assertEq(uint256(hook.positionLiquidity()), uint256(posBefore), "the exit burned depth: wrong case");
        assertEq(uint256(hook.seatLiquidity(seatId)), 0, "the seat kept its contribution");
    }

    /// @dev External so the negative control can capture the instrument's own failure.
    function probeInvariantL() external view {
        _checkInvariantL("negative control");
    }

    /// @dev A forge-std assertion failure is not a typed error, so the reason is matched on its
    ///      TEXT rather than a selector. Searching the whole payload avoids depending on how
    ///      forge-std happens to wrap the message this release — the point is that the message is
    ///      the L mismatch and not some unrelated revert (LAW 2).
    function _mentionsInvariantL(bytes memory err) internal pure returns (bool) {
        bytes memory needle = bytes("INVARIANT L");
        if (err.length < needle.length) return false;
        for (uint256 i; i + needle.length <= err.length; i++) {
            bool hit = true;
            for (uint256 j; j < needle.length; j++) {
                if (err[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    /// @notice **THE CONTROL FOR `test_M1` AND `test_M2c`.** Remove dust policy F1 and the maturity
    ///         exit stops working: asking for the dead-side wei the terminal fill left behind
    ///         underflows `float1` inside `_payOut`, and the whole `withdraw` — both legs, including
    ///         the live one — reverts.
    ///
    /// @dev LAW 2: the reason is asserted, not merely "it reverted". A `float1 -= w1` underflow is
    ///      Solidity PANIC 0x11, and v4 wraps a hook's revert in
    ///      `CustomRevert.WrappedError(target, selector, reason, details)` — so the payload has to
    ///      be unwrapped before it can be read (PITFALLS 5.83). `_unwrap` is the fixture's own
    ///      peeler; a bare `vm.expectRevert(...)` against the raw selector would NOT match.
    function test_M1c_withoutTheDustPolicyTheMaturityExitReverts() public {
        _rebuildAs("Maturity.t.sol:FaceValueQueueHook", 0x4D06, PHI);
        _matureDown();

        // Find the seat the terminal fill stopped inside — it is the one holding dead-side dust.
        uint256 seatId = type(uint256).max;
        uint256 want1;
        for (uint256 i; i < 5; i++) {
            (, uint256 a1) = hook.seat(i);
            if (a1 != 0) {
                seatId = i;
                want1 = a1;
                break;
            }
        }
        assertTrue(seatId != type(uint256).max, "no dead-side dust exists: this control proves nothing");
        (, uint256 f1) = hook.floats();
        assertLt(f1, want1, "the float could cover it: the clamp would not be binding here");

        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.faceWithdraw, (seatId, want1)));
        assertFalse(ok, "the face-value control did not revert: test_M1 cannot fail");
        bytes memory inner = _unwrap(err);
        assertEq(bytes4(inner), bytes4(0x4e487b71), "went red for the WRONG reason: not a Solidity panic");
        assertEq(uint256(bytes32(_word(inner))), 0x11, "went red for the WRONG reason: not an arithmetic underflow");

        // POSITIVE CONTROL: production, same state, same request, pays zero instead of reverting.
        // Without it, "the mutant reverts" could be a property of the state rather than the clamp.
        _rebuildAs("QueueHarness.sol:QueueHarness", 0x4D07, PHI);
        _matureDown();
        (, uint256 p1) = _wd(seatId, 0, want1, "production at the same point");
        assertEq(p1, 0, "production paid a token it does not hold");
    }

    // =============================================================================================
    // 8. IS THE STRANDED POT REACHABLE THROUGH PRODUCTION AT ALL? Asked because the answer decides
    //    whether finding 3 is a disclosure or a defect, and answered by EXECUTION rather than by
    //    reading the call graph.
    // =============================================================================================

    /// @notice **THE POT IS CLAIMABLE OUT OF BAND, WITH NO RETURN TO THE BAND AND NO FURTHER TRADE.
    ///         THIS TEST ASSERTED THE OPPOSITE AND IS INVERTED, NOT DELETED.**
    ///
    /// @dev It used to be called `theStrandedPotIsReleasedOnlyByReturningToTheBand`, and the four
    ///      steps it executed were the honest answer to "is the stranded pot recoverable": stranded
    ///      by the terminal fill, then a one-for-zero swap back into the band, then a SMALL
    ///      zero-for-one fill leaving somebody unexcluded so `w > 0`, and only then could the head
    ///      claim. **Every step of that was a consequence of the terminal fill holding, and it holds
    ///      no longer** — so the recovery sequence has nothing to recover.
    ///
    ///      What is asserted instead is the strictly stronger property the fix produced, and it is
    ///      the one a holder actually cares about: **at maturity, out of band, with no counterparty
    ///      and no further trade of any kind, every seat can settle its share of the terminal pot
    ///      and take it out as tokens.** The old sequence is kept underneath as the second half —
    ///      the pool must STILL trade back into the band afterwards, which is what the brick
    ///      destroyed.
    function test_M7e_theMaturityPotIsClaimableOutOfBandWithNoFurtherTrade() public {
        _matureDown();
        (uint256 owed0,, uint256 held0,) = hook.premiums();
        (uint256 g0,) = hook.growths();
        assertGt(owed0, 0, "nothing was withheld: this test proves nothing");
        // THE INVERSION. These used to read `assertGt(held0, 0)` and `assertEq(g0, 0)`.
        assertEq(held0, 0, "the pot was stranded: it is unreachable out of band");
        assertGt(g0, 0, "the accumulator never moved: there is nothing to claim");

        // **CLAIMED AND PAID OUT, NOT MERELY ACCRUED** (LAW 3, second corollary). Each seat settles
        // and then withdraws exactly what the settle credited, so the money leaves the contract.
        uint256 paidOut;
        for (uint256 i; i < 5; i++) {
            (uint256 b0,) = hook.rawSeat(i);
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
            (uint256 a0,) = hook.rawSeat(i);
            uint256 credit = a0 - b0;
            assertGt(credit, 0, "a seat was credited nothing out of the terminal pot");
            (uint256 p0,) = _wd(i, credit, 0, "maturity premium");
            assertEq(p0, credit, "the seat could not actually take its premium out");
            paidOut += p0;
        }
        assertApproxEqAbs(paidOut, owed0, 10, "what left the contract is not the pot");
        console.log("premium claimed out of band, no further trade (wei)", paidOut);

        // ...and the pool STILL TRADES. This is the sequence the old test needed for recovery and
        // that the brick destroyed: an ordinary trader walks the price back into the band.
        (,, int24 tl, int24 tu) = hook.pool();
        _swapper().swapTo(k, false, 1e28, TickMath.getSqrtPriceAtTick(tl + (tu - tl) / 2));
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick >= tl && tick < tu, "the pool did not come back into the band");
    }

    /// @notice **AFTER THE EXIT THE POOL STILL SWAPS. THIS TEST ASSERTED THAT EVERY SWAP REVERTED,
    ///         AND THAT IS THE WHOLE POINT OF THE FIX — SO THIS TEST IS THE PROOF.**
    ///
    /// @dev **THE STATE IT USED TO MEASURE**, after `_matureDown()` and five full withdrawals:
    ///
    ///          totals              (0, 3)
    ///          floats              (0, 0)
    ///          position token0     49,566,884,481,303,539     <-- the stranded pot, to 3 wei
    ///          positionLiquidity   257,348,426,066,536,964     <-- the pool still QUOTES this
    ///
    ///      The pool advertised depth it could not trade. A one-for-zero swap — the only direction
    ///      that could take that token0 out, and the direction that would walk the price back INTO
    ///      the band — asked `_allocate` for output the seats did not have, because the money
    ///      belonged to `premiumOwed` and `_allocate` sources only from seat balances. It reverted
    ///      `QueueUnderflow(49566884481303539)` at every size, one wei included. **That is a live
    ///      Uniswap pool advertising liquidity and refusing every trade in one direction.**
    ///
    ///      Now the terminal fill distributes the pot, the roster withdraws it with everything else,
    ///      and there is nothing left for a swap to be short of. The assertions are the mirror: the
    ///      position is empty to residual scale, and the recovery trade GOES THROUGH at both sizes.
    ///
    ///      **THE CONTROL IS `test_M7d`**, which deletes the `sweptBook` branch and reproduces the
    ///      brick — reason matched by selector and shortfall matched to the pot. Without it "the
    ///      swap succeeded" could be a property of this fixture rather than of the fix.
    ///
    ///      **IT ALSO RESOLVES A DOCUMENTED CONTRADICTION.** `Adversarial.t.sol`'s `test_6_15` states
    ///      in capitals that "`QueueUnderflow` IS STRUCTURALLY UNREACHABLE THROUGH THE POOL",
    ///      reasoning that "INVARIANT F ... says the position never exceeds the ledger, so
    ///      `amtOut <= Sigma a` always". Phase 7 falsified it: INVARIANT F is
    ///      `Sigma a + pending + premiumOwed == position + float`, so the position exceeds the SEAT
    ///      ledger by the unsettled premium. **That gap is what the fix closes at maturity**, and
    ///      `test_M7d` is where the falsifying state now lives.
    function test_M7f_afterTheExitThePoolStillSwaps() public {
        _matureDown();
        (uint256 owed0,, uint256 held0,) = hook.premiums();
        held0;
        assertGt(owed0, 1_000, "no premium was withheld: this test proves nothing");

        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "exit before probing");
        }
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 f0, uint256 f1) = hook.floats();
        assertLt(t0 + t1, 1_000, "the roster did not actually exit");
        assertEq(f0 + f1, 0, "the float could pay: a shortfall would not bind here anyway");

        // THE INVERSION. This used to be `assertGt(positionLiquidity, 0)` under the heading "the
        // pool still QUOTES depth" — the router-facing half of the defect. There is nothing left to
        // quote, because the pot went to the roster and the roster took it.
        (uint256 stillThere, uint256 stillThere1) = _positionValue();
        assertLt(stillThere + stillThere1, 1_000, "the position still holds the premium after a full exit");

        // THE RECOVERY TRADE, at two sizes three orders of magnitude apart. Both used to die with
        // `QueueUnderflow`. Neither may now — and "did not revert with QueueUnderflow" is the
        // assertion rather than "did not revert", because an empty pool legitimately refuses a swap
        // with v4's own `PriceLimitAlreadyExceeded` and conflating the two would let this pass, or
        // fail, for the wrong reason (LAW 2; the same distinction `test_M13c` carries).
        _assertNoUnderflow(1e20);
        _assertNoUnderflow(1e12);

        // The other direction is a defined no-op: the queue holds nothing to pay out.
        (uint256 b0, uint256 b1) = hook.totals();
        this.doSwap(true, 1e18);
        (uint256 a0_, uint256 a1_) = hook.totals();
        assertEq(a0_, b0, "a zero-for-one swap credited token0 to an empty queue");
        assertEq(a1_, b1, "a zero-for-one swap credited token1 to an empty queue");

        // ...and the TEST-ONLY burn — the strongest possible reader, and one that does not exist in
        // `src/` — finds nothing. `redeemAll` was removed from the shipping contract because a
        // permissionless position burn is pure griefing.
        (uint256 r0, uint256 r1) = hook.redeemAll();
        assertLt(r0 + r1, 1_000, "the position is still holding money nothing in the product can reach");
        console.log("left unreachable after exit (wei)", r0 + r1);
    }

    /// @dev One-for-zero at `amountIn` must die with the exact reason, and — when the swap is large
    ///      enough for the leftover to BIND — with the exact shortfall.
    ///
    ///      **`binding` is not a convenience, it is the correction to a wrong first draft.** The
    ///      shortfall is the part of THIS swap's `amtOut` the allocator could not source, so it is
    ///      `min(amtOut, pot)`, not the pot. A small swap underflows by only what it asked for
    ///      (measured: 4.41e12 on a 1e12 input). Asserting the pot at both sizes read as an identity
    ///      and was arithmetic: it happened to hold at the size where the pot binds and nowhere
    ///      else. Both claims are now made where they are true, and neither is a tolerance.
    function _assertUnderflows(uint256 amountIn, uint256 owed0, bool binding) internal {
        bytes memory reason = _expectSwapRevert(
            false, amountIn, bytes4(keccak256("QueueUnderflow(uint256)")), "the recovery trade did not underflow"
        );
        uint256 shortfall = uint256(bytes32(_word(reason)));
        assertGt(shortfall, 0, "QueueUnderflow reported a zero shortfall");
        if (binding) {
            assertApproxEqAbs(shortfall, owed0, 1_000, "the shortfall is not the unsettled premium");
        } else {
            assertLe(shortfall, owed0 + 1_000, "a small swap underflowed by MORE than the whole pot");
        }
    }

    /// @dev External so a control can capture the revert and read its reason.
    function faceWithdraw(uint256 seatId, uint256 w1) external {
        vm.prank(hook.ownerOf(seatId));
        hook.withdraw(seatId, 0, w1);
    }

    /// @dev The 32-byte word following a 4-byte selector. `abi.decode` cannot be used on a panic.
    function _word(bytes memory b) internal pure returns (bytes32 w) {
        require(b.length >= 36, "no payload word");
        assembly {
            w := mload(add(b, 36))
        }
    }

    // =============================================================================================
    // 9. THE BRICK, SEPARATED FROM THE STRANDED POT. Strip the premium framing and what is left is
    //    a live Uniswap pool that ADVERTISES liquidity and REVERTS every swap in one direction.
    //    That is product-breaking whether or not anybody ever claims the pot, so the symptom and
    //    the cause are tested apart.
    // =============================================================================================

    /// @notice **THE DEGENERATE PATH IS STILL GATED ON ZERO OUTPUT — AND NOTHING ELSE NEEDS IT ANY
    ///         MORE, BECAUSE THE POOL NO LONGER BRICKS. THE SECOND HALF OF THIS TEST IS INVERTED.**
    ///
    /// @dev **WHAT IT USED TO ESTABLISH, and why the section it sits in was written.** Strip the
    ///      premium framing off `test_M7f` and what was left was a live Uniswap pool that
    ///      ADVERTISED liquidity and REVERTED every swap in one direction. `_afterSwap`'s degenerate
    ///      branch is guarded by `if (amtOut == 0)` — a TOTAL absence of output — and has no notion
    ///      of a PARTIAL fill: by the time `_allocate` discovers it cannot source the swap,
    ///      `amtOut > 0` and that branch is long past. So the gate is "the pool paid nothing out",
    ///      not "the queue cannot pay for what the pool paid out", and the two are different states.
    ///      **And it would have been the wrong absorber even if it were reached**: the degenerate
    ///      path CREDITS the whole input to the seat the fill would have begun at, so applied to an
    ///      unsourceable fill it would credit seats for output they did not provide and INVARIANT F
    ///      would break in the other direction — trading a revert for a silent insolvency, which is
    ///      the worse of the two.
    ///
    ///      That analysis is why the fix landed in `_settlePremium` rather than in the degenerate
    ///      gate, and it is kept because it is the reasoning behind the design. What CHANGED is the
    ///      state: there is no unsourceable fill at maturity any more, so this test now asserts the
    ///      gate on one side and the ABSENCE of the brick on the other.
    ///
    ///      Both halves are executed rather than argued, and the gate half keeps its signature
    ///      assertion — the branch credits the WHOLE input and pays nothing out — so it cannot pass
    ///      on a swap that never reached the hook at all (PITFALLS 5.54).
    function test_M13_theDegeneratePathIsGatedOnZeroOutputAndNothingElseBricks() public {
        _matureDown();

        // The pool quotes depth and holds token0. Below the band a one-for-zero swap is the only
        // direction that can take it out — and it is the direction that used to revert at every
        // size, one wei included.
        assertGt(uint256(hook.positionLiquidity()), 0, "the position is empty: nothing to advertise");
        (uint256 stillThere,) = _positionValue();
        assertGt(stillThere, 1e16, "the position holds no token0: there is nothing to trade");

        // **SETTLE EVERY SEAT FIRST, AND THAT IS NOT TIDINESS.** The degenerate branch runs
        // `_syncSeat` on the seat the fill would have begun at, which CASHES that seat's accrued
        // premium into its ledger — and since the terminal fill now distributes the pot, the head
        // has a real claim waiting. `totals()` would therefore move by the head's premium share as
        // well as by the one wei, and the identity below would read as a defect. Draining the
        // claims first makes the one wei the only thing that can move. (Pre-fix this was invisible,
        // because the accumulator had not moved and there was no claim to cash.)
        for (uint256 i; i < 5; i++) {
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
        }

        // THE GATE, unchanged. A swap whose OUTPUT rounds to zero takes the degenerate branch: it
        // credits the whole input to the seat the fill would have begun at and pays nothing out, so
        // token1 rises by exactly the one wei that went in and token0 does not move.
        (uint256 b0, uint256 b1) = hook.totals();
        this.doSwap(false, 1);
        (uint256 a0_, uint256 a1_) = hook.totals();
        assertEq(a0_, b0, "the degenerate path paid token0 out of a queue that has none");
        assertEq(a1_ - b1, 1, "the degenerate branch was not entered: the input was not credited whole");

        // THE INVERSION. Three orders of magnitude, all of which used to die with `QueueUnderflow`.
        // "Not that revert" rather than "no revert": an emptied pool legitimately refuses a further
        // swap with v4's own `PriceLimitAlreadyExceeded`, and conflating the two would let this test
        // pass, or fail, for the wrong reason (LAW 2).
        _assertNoUnderflow(1e12);
        _assertNoUnderflow(1e15);
        _assertNoUnderflow(1e20);

        // ...and once the roster exits there is no advertised-but-untradeable depth left at all,
        // which is the router-facing half of the old defect.
        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "exit after probing");
        }
        (uint256 leftover0, uint256 leftover1) = _positionValue();
        assertLt(leftover0 + leftover1, 1_000, "the pool still quotes depth it cannot trade");
    }

    /// @notice **THE MIRROR, ABOVE THE BAND. The token0 and token1 halves of `_accruePremium` and
    ///         `_settlePremium` are a duplicated rule, and a duplicated rule has been wrong in
    ///         exactly one of its two copies six times on this project** (PITFALLS 5.37, 5.50, 5.52
    ///         twice, 5.73, 5.125).
    ///
    /// @dev It used to be `theShortfallIsBoundedByTheUnclaimablePot`: at maturity `premiumHeld`
    ///      equalled `premiumOwed` and the binding `QueueUnderflow` shortfall equalled both, which
    ///      was the fact a FIX needed — draw the shortfall from the narrow pot no seat can claim,
    ///      never from `premiumOwed`, which includes amounts seats can already claim. **That
    ///      design question is closed by the pot no longer existing**, so what is asserted here is
    ///      its absence: nothing is unclaimable, and there is no shortfall at any size.
    ///
    ///      Above the band the position is 100% token1 and the recovery direction is zero-for-one,
    ///      so every quantity in `test_M13` has its mirror here and none of them is the same number.
    function test_M13b_thereIsNoUnclaimablePotAboveTheBand() public {
        _matureUp();

        (, uint256 owed1,, uint256 held1) = hook.premiums();
        (, uint256 g1) = hook.growths();
        assertGt(owed1, 1_000, "the terminal fill withheld no token1 premium: this test proves nothing");
        // THE INVERSION. These used to read `assertEq(g1, 0)` and `assertEq(held1, owed1)`.
        assertEq(held1, 0, "a token1 pot is unclaimable: the shortfall class is live in this direction");
        assertGt(g1, 0, "the token1 accumulator never moved: the pot reached nobody");

        assertGt(uint256(hook.positionLiquidity()), 0, "the position is empty: nothing to advertise");
        (, uint256 stillThere) = _positionValue();
        assertGt(stillThere, 1e4, "the position holds no token1: there is nothing to trade");

        // THE GATE, in the mirror direction. Claims drained first for the reason `test_M13` gives.
        for (uint256 i; i < 5; i++) {
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
        }
        (uint256 b0, uint256 b1) = hook.totals();
        this.doSwap(true, 1);
        (uint256 a0_, uint256 a1_) = hook.totals();
        assertEq(a1_, b1, "the degenerate path paid token1 out of a queue that has none");
        assertEq(a0_ - b0, 1, "the degenerate branch was not entered: the input was not credited whole");

        // No shortfall at any size, three orders of magnitude apart.
        _assertNoUnderflowZeroForOne(1e12);
        _assertNoUnderflowZeroForOne(1e15);
        _assertNoUnderflowZeroForOne(1e20);

        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "exit after probing");
        }
        (uint256 leftover0, uint256 leftover1) = _positionValue();
        assertLt(leftover0 + leftover1, 1_000, "the pool still quotes depth it cannot trade");
    }

    /// @dev The zero-for-one twin of `_assertNoUnderflow`. Kept as its own function rather than a
    ///      flag on the other because the two are the duplicated-rule pair this file exists to
    ///      test, and a shared helper with a boolean is one place, not two.
    function _assertNoUnderflowZeroForOne(uint256 amountIn) internal {
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.doSwap, (true, amountIn)));
        if (ok) return;
        assertTrue(
            bytes4(_unwrap(err)) != bytes4(keccak256("QueueUnderflow(uint256)")),
            "a zero-for-one swap could not be sourced: the pool is bricked above the band"
        );
    }

    function _shortfallOf(uint256 amountIn) internal returns (uint256) {
        bytes memory reason = _expectSwapRevert(
            false, amountIn, bytes4(keccak256("QueueUnderflow(uint256)")), "the recovery trade did not underflow"
        );
        return uint256(bytes32(_word(reason)));
    }

    /// @notice **THE CONTROL THAT PINS THE ROOT CAUSE, and its answer is known in advance.** Same
    ///         pool, same terminal fill, same full exit — φ = 0. There is no pot, so nothing is left
    ///         in the position for a swap to be short of, and the brick MUST NOT happen.
    ///
    /// @dev If the pool bricked here too, the cause would be something else — the §E.4 residual, the
    ///      dust policy, the withdrawal path — and `test_M13`'s diagnosis would be wrong. It is the
    ///      difference between "a pool at maturity bricks" and "the PREMIUM bricks a pool at
    ///      maturity", and only the second one tells anybody what to fix.
    function test_M13c_atPhiZeroTheBrickDoesNotHappen() public {
        _rebuildAtPhi(0x4D08, 0);
        _matureDown();
        (uint256 owed0,,,) = hook.premiums();
        assertEq(owed0, 0, "the control withheld a premium: it is not a control");

        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "phi-zero exit");
        }
        (uint256 t0, uint256 t1) = hook.totals();
        assertLt(t0 + t1, 1_000, "the roster did not actually exit");

        // The position is empty to residual scale — there is nothing to be short of...
        (uint256 leftover,) = _positionValue();
        assertLt(leftover, 1_000, "the phi-zero pool stranded capital: the diagnosis is wrong");

        // ...and the trade that bricks the φ > 0 pool at every size does NOT underflow here.
        //
        // The assertion is "not `QueueUnderflow`", not "does not revert", and the distinction is
        // deliberate: once the first sweep has walked an empty pool to `MAX_SQRT_PRICE`, v4 itself
        // refuses the next one with `PriceLimitAlreadyExceeded`. That is Uniswap declining a
        // pointless trade, not the hook being short of money, and conflating the two would let this
        // control pass — or fail — for the wrong reason (LAW 2).
        _assertNoUnderflow(1e12);
        _assertNoUnderflow(1e15);
        _assertNoUnderflow(1e20);
    }

    /// @dev The swap may or may not go through; what it may NOT do is die because the queue could
    ///      not source it.
    function _assertNoUnderflow(uint256 amountIn) internal {
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.doSwap, (false, amountIn)));
        if (ok) return;
        assertTrue(
            bytes4(_unwrap(err)) != bytes4(keccak256("QueueUnderflow(uint256)")),
            "the phi-zero pool bricked too: the diagnosis is wrong"
        );
    }
}
