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
/// @dev **CONTROL — the premium's payer exclusion, DELETED, and nothing else.** `_accruePremium` is
///      `virtual` for exactly this purpose. Production removes the weight of the ranks the fill just
///      paid from the denominator, which on a fill that reaches the tail removes ALL of it and takes
///      the `w == 0` hold branch. This subclass passes `0` for `excludedL` instead, so the same
///      terminal fill accrues normally and `test_M7`'s assertions MUST go red against it. Without
///      this control, "the accumulator did not move" could be a property of the fixture rather than
///      of the exclusion, and the finding would rest on reading the source.
contract NoExclusionQueueHook is QueueHarness {
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

    function _accruePremium(bool inIsZero, uint256 pot, uint256) internal override {
        super._accruePremium(inIsZero, pot, 0);
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
        for (uint256 i; i < 5; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            uint256 live = liveIsZero ? a0 : a1;
            assertGt(live, 1, "nothing happened: this seat holds no live-side balance");
            uint256 half = live / 2;

            (uint256 p0, uint256 p1) = _wd(i, liveIsZero ? half : 0, liveIsZero ? 0 : half, string.concat(dir, " half"));
            assertEq(liveIsZero ? p0 : p1, half, "a partial live-leg request out of band was clamped");

            // ...and the seat still holds the rest, to the wei. The IDENTITY, not a bound: the seat
            // is debited by what was PAID and by nothing else.
            (uint256 r0, uint256 r1) = hook.seat(i);
            assertEq(r0, a0 - p0, "the seat was debited more token0 than it was paid");
            assertEq(r1, a1 - p1, "the seat was debited more token1 than it was paid");

            uint256 rest = liveIsZero ? r0 : r1;
            (p0, p1) = _wd(i, liveIsZero ? rest : 0, liveIsZero ? 0 : rest, string.concat(dir, " rest"));
            assertEq(liveIsZero ? p0 : p1, rest, "the second tranche was clamped");
        }
        _checkInvariantF(string.concat(dir, " after partial withdrawals"), 1_000);
        _checkInvariantL(string.concat(dir, " after partial withdrawals"));
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

    /// @notice **DEFECT-GRADE FINDING — THE TERMINAL FILL WITHHOLDS THE ENTIRE PREMIUM POT FROM
    ///         EVERY SEAT THAT PAID IT, AND ONCE THE ROSTER WITHDRAWS IT CAN NEVER BE RELEASED TO
    ///         ANYBODY.**
    ///
    /// @dev The mechanism is `_settlePremium` doing exactly what it was written to do. It excludes
    ///      the ranks the fill reached, `[start, next]`, from the accrual denominator, because
    ///      including the boundary seat let a last-wei holder take an entire pot (`test_7_14`). A
    ///      fill that reaches the TAIL therefore excludes EVERY rank, and `w = standingL - lTouched`
    ///      is then ZERO to the wei — INVARIANT L says `standingL` IS the sum of the seats. So
    ///      `_accruePremium` takes its `w == 0` branch, `premGrowth` does not move, and the whole
    ///      pot lands in `premiumHeld`.
    ///
    ///      In the middle of an instrument's life that is a DEFERRAL and the comment in
    ///      `_settlePremium` says so honestly: held pots fold forward into the next accrual. **At
    ///      maturity there is no next accrual.** The fill that ends the instrument's life is, by
    ///      construction, a fill that sweeps the whole queue — so the pot that is stranded is the
    ///      pot skimmed off the single largest trade the pool will ever see.
    ///
    ///      And it gets strictly worse rather than better after the exit. Every holder then
    ///      withdraws, `standingL` goes to zero, and `w == 0` becomes PERMANENT: no future swap, at
    ///      any price, in any direction, can ever move `premGrowth` again. The money is not
    ///      deferred at that point, it is gone — it sits inside the v4 position with no code path in
    ///      `src/` that can reach it. `QueueHarness.redeemAll()` recovers it here, and `redeemAll`
    ///      is TEST-ONLY: it was deliberately removed from the shipping contract because a
    ///      permissionless position burn is pure griefing.
    ///
    ///      Asserted three ways, because "conserved" and "claimable" are two different claims
    ///      (LAW 3, second corollary): the accumulator never moved, every seat's claim is zero, and
    ///      the position still holds the money after the whole roster has withdrawn everything it
    ///      owns.
    function test_M7_theTerminalFillStrandsTheWholePremiumPotBelowTheBand() public {
        _thePremiumIsStranded(true);
    }

    /// @notice The mirror, and it is NOT free: the token0 and token1 halves of `_accruePremium` are
    ///         a duplicated rule, and a duplicated rule has been wrong in exactly one of its two
    ///         copies five times on this project (PITFALLS 5.125).
    function test_M7b_theTerminalFillStrandsTheWholePremiumPotAboveTheBand() public {
        _thePremiumIsStranded(false);
    }

    /// @dev The measurement half, in its own frame for the stack. Nothing is asserted against a
    ///      tolerance chosen to pass: the depth bound is 2% of what the pool was born with, and the
    ///      two numbers it is derived from are logged next to it.
    function _reportStranding(bool down, uint256 owed, uint128 lAtBirth) internal view {
        (uint256 contributed,,) = hook.liquidityTotals();
        assertLt(contributed, uint256(lAtBirth) / 50, "the roster still holds real depth");
        console.log("stranded premium (wei)", owed);
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

    /// @dev The three statements about the pot itself, in their own frame: `_thePremiumIsStranded`
    ///      is at the stack limit without `via_ir` and four more locals is the difference between
    ///      building and not.
    function _potHeldWhole(bool down) internal view returns (uint256 owed) {
        (uint256 owed0, uint256 owed1, uint256 held0, uint256 held1) = hook.premiums();
        (uint256 g0, uint256 g1) = hook.growths();
        owed = down ? owed0 : owed1;
        assertGt(owed, 0, "nothing happened: the terminal fill withheld no premium at all");
        assertEq(down ? held0 : held1, owed, "the pot was not held whole: some of it reached the accumulator");
        assertEq(down ? g0 : g1, 0, "the accumulator moved: the pot is claimable after all");
    }

    function _thePremiumIsStranded(bool down) internal {
        uint128 lAtBirth = hook.positionLiquidity();
        if (down) _matureDown();
        else _matureUp();

        uint256 owed = _potHeldWhole(down);

        // The exclusion really was TOTAL: the fill reached the tail, so `_settlePremium` excluded
        // every rank and `w == standingL - lTouched` was zero to the wei. Asserted on the cursor
        // rather than inferred from the accumulator, so this is a second witness and not a
        // restatement of the line above.
        (uint256 k0, uint256 k1) = hook.cursors();
        assertGe(down ? k1 : k0, 4, "the fill did not reach the tail: this is not the terminal fill");

        // Every seat's claim really is zero — asserted by SETTLING each seat (a zero withdrawal is
        // a settle) and showing its balance does not move. Reading the accumulator again would be
        // the same number twice.
        for (uint256 i; i < 5; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            vm.prank(hook.ownerOf(i));
            hook.withdraw(i, 0, 0);
            (uint256 b0, uint256 b1) = hook.seat(i);
            assertEq(b0, a0, "a settle credited token0 premium the accumulator says does not exist");
            assertEq(b1, a1, "a settle credited token1 premium the accumulator says does not exist");
        }

        // The whole roster now takes everything it owns...
        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "premium exit");
        }
        (uint256 t0, uint256 t1) = hook.totals();
        assertLt(t0 + t1, 1_000, "the roster did not actually exit: this test proves nothing");

        // ...and the money is still inside the position, reachable only by a function that does not
        // exist in `src/`. `QueueHarness.redeemAll` is TEST-ONLY — a permissionless position burn
        // was removed from the shipping contract as pure griefing — so this number is what NOTHING
        // in the product can reach.
        (uint256 r0, uint256 r1) = hook.redeemAll();
        uint256 left = down ? r0 : r1;
        assertApproxEqAbs(left, owed, 1_000, "the position leftover is not the stranded premium");

        // **WHAT IS NOT CLAIMED, said explicitly.** The pot is not PROVABLY unrecoverable: a future
        // in-band fill with any unexcluded standing would release it, because held pots fold
        // forward. What is proven is that at maturity there is no such fill — the price is outside
        // the band, the roster has exited, and the depth left to weigh an accrual against has
        // collapsed to under 2% of what the pool was born with. Measured, not asserted as a bound
        // chosen to pass: the numbers are logged.
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
        (uint256 credited, uint256 unalloc) = _chargeRentAtRankZero();
        assertGt(credited, 0, "below the band the rent reached nobody");
        assertEq(unalloc, 0, "below the band the rent was stranded");
    }

    /// @notice **DEFECT-GRADE ASYMMETRY, AND NOT THE ONE THIS TEST WAS WRITTEN TO FIND. ABOVE the
    ///         band the rent weight collapses to DUST, so a seat holding ONE WEI of currency0 takes
    ///         100% of the rent paid by every seat in front of it, while seats holding 1.9e18 of
    ///         currency1 and no currency0 take nothing.**
    ///
    /// @dev `_distributeRent` splits pro-rata by the recipients' `currency0` balance, and it carries
    ///      an explicit `w == 0` branch for "nobody behind holds any currency0" — the money is held
    ///      in `unallocatedRent0` rather than lost. **There is no branch for `w == 1`.** Above the
    ///      band every seat has been drained of currency0 by the terminal one-for-zero fill
    ///      (INVARIANT C: every seat below `cursor0` holds `a0 == 0`), except whichever seat the
    ///      fill stopped inside, which keeps a residual wei. Pro-rata over a total weight of one wei
    ///      hands that seat everything.
    ///
    ///      This is the same shape as `test_7_14` — the last-wei holder taking an entire pot — which
    ///      `_settlePremium` was given an explicit exclusion to close. The rent path never got the
    ///      equivalent, and the dust weight is not even a wei the beneficiary had to work for: it is
    ///      whatever the fill happened to leave behind.
    ///
    ///      **WHEN THE FIX LANDS THIS TEST INVERTS.** Re-weighting rent by `seat.liquidity` makes
    ///      the weight direction-invariant, so the dust capture becomes impossible and this becomes
    ///      the regression test for it: the assertion `e1 - e0 == credited` on a one-wei holder must
    ///      then FAIL, and the seats behind must split the pot by contributed depth exactly as
    ///      `test_M9` already shows them splitting it below the band. Whoever implements the change
    ///      should invert it here rather than delete it — the executed defect is the evidence that
    ///      the fix was needed.
    ///
    ///      **BELOW the band the identical code pays out perfectly**, because there every seat is
    ///      100% currency0 and the weights are real. That is the whole point of running this in both
    ///      directions: the rent mechanism is proportional in one terminal state and degenerate in
    ///      the mirrored one, and a single-direction test reports whichever half it happens to pick.
    function test_M9b_aDustWeightTakesTheWholeRentAboveTheBand() public {
        _matureUp();

        // Establish the state first, or the claim below is about a fixture nobody can place.
        uint256 dusty = type(uint256).max;
        uint256 weight;
        for (uint256 i = 1; i < 5; i++) {
            uint256 id = hook.idAtRank(i);
            (uint256 a0, uint256 a1) = hook.seat(id);
            weight += a0;
            if (a0 != 0 && dusty == type(uint256).max) dusty = id;
            assertGt(a1, 1e17, "a seat behind the payer holds no real capital at all");
        }
        assertTrue(
            dusty != type(uint256).max, "no seat behind holds any currency0: this is the w == 0 case, not this one"
        );
        assertLt(weight, 1_000, "the recipients' total weight is not dust: this test proves nothing");

        (, uint256 e0,,,) = hook.leaseOf(dusty);
        (uint256 credited, uint256 unalloc) = _chargeRentAtRankZero();
        (, uint256 e1,,,) = hook.leaseOf(dusty);

        assertEq(unalloc, 0, "the rent was held rather than distributed: wrong branch");
        // THE IDENTITY: the dust holder took the WHOLE pot, not merely most of it.
        assertEq(e1 - e0, credited, "the dust holder did not take the entire rent pot");
        assertGt(credited, 1e17, "nothing happened: no rent was charged, this test proves nothing");
        console.log("currency0 weight (wei)", weight);
        console.log("rent captured by it   ", credited);
    }

    /// @notice The `w == 0` branch itself, reached deliberately: charge the TAIL, which has nobody
    ///         behind it at all. The money leaves the payer's escrow and lands in `unallocatedRent0`
    ///         — a pot with no reader anywhere in `src/` but the next distribution, and at maturity
    ///         there is no next distribution with a recipient.
    function test_M9c_rentFromTheTailIsHeldWithNobodyToPayItTo() public {
        _matureUp();
        uint256 payer = hook.idAtRank(4);
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
        assertGt(charged, 0, "nothing happened: the tail was not charged");
        // THE IDENTITY the `_distributeRent` docstring states:
        //     Sigma credited + unallocatedAfter == charged + unallocatedBefore
        // with Sigma credited == 0 on this branch, because there is nobody behind the tail.
        assertEq(unallocAfter, charged + unallocBefore, "the held-rent identity does not close");
        _checkInvariantR("after a tail rent settlement at maturity");
    }

    /// @dev Charge one seat's rent and report where it went: `Σ credited` to the seats behind, and
    ///      what fell into `unallocatedRent0`. Reads the CONTRACT's escrows on both sides — nothing
    ///      here is a fixture-side re-derivation (PITFALLS 5.34).
    function _chargeRentAtRankZero() internal returns (uint256 credited, uint256 unalloc) {
        uint256 payer = hook.idAtRank(0);
        address who = hook.ownerOf(payer);
        _fund(who, 10e18, 0);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        hook.setSelfPrice(payer, 100e18);
        hook.fundRent(payer, 10e18);
        vm.stopPrank();

        uint256 behindBefore = _escrowsBehind(0);
        (, uint256 e0,,,) = hook.leaseOf(payer);
        vm.warp(block.timestamp + 30 days);
        hook.settleRent(payer);
        (, uint256 e1,,,) = hook.leaseOf(payer);

        assertGt(e0 - e1, 0, "nothing happened: the payer was not charged");
        credited = _escrowsBehind(0) - behindBefore;
        (, unalloc) = hook.rentTotals();
        _checkInvariantR("after a maturity rent settlement");
    }

    function _escrowsBehind(uint256 rank) internal view returns (uint256 s) {
        for (uint256 i = rank + 1; i < 5; i++) {
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

    /// @notice **THE CONTROL FOR `test_M7`.** Delete the premium's payer exclusion and the terminal
    ///         fill accrues normally: `premGrowth` moves, the pot does NOT land whole in
    ///         `premiumHeld`, and every assertion `test_M7` makes about stranding goes red. This is
    ///         what makes `test_M7` a finding rather than an observation about a fixture.
    function test_M7d_withoutThePayerExclusionThePotIsNotStranded() public {
        _rebuildAs("Maturity.t.sol:NoExclusionQueueHook", 0x4D04, PHI);
        _matureDown();

        (uint256 owed0,, uint256 held0,) = hook.premiums();
        (uint256 g0,) = hook.growths();
        assertGt(owed0, 0, "the control withheld no premium: it is not comparable");
        // The three statements `test_M7` asserts, INVERTED. If any of these fails, `test_M7` is
        // unfalsifiable and proves nothing.
        assertGt(g0, 0, "the accumulator did not move even without the exclusion: test_M7 cannot fail");
        assertLt(held0, owed0, "the pot was still held whole: test_M7 cannot fail");
        console.log("without the exclusion: growth", g0);

        // **WHAT THIS CONTROL DOES NOT SHOW, AND SAYING SO IS THE POINT.** Deleting the DENOMINATOR
        // half of the exclusion does not, on its own, make the pot claimable: `_settlePremium` also
        // moves the touched seats' MARKS past the accrual, and that half is not `virtual`, so the
        // pot lands in `premGrowth` with every seat already marked at it. The `_settlePremium`
        // docstring predicts exactly this shape from the other side ("doing only the second would
        // leave their share accrued to nobody"). The control's job is narrower and it does it:
        // `test_M7`'s two accumulator assertions are FALSIFIABLE — they go red here — so the
        // stranding it reports is a property of the exclusion and not of this fixture.
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

    /// @notice **THE RELEASE PATH EXISTS AND IS PRODUCTION-REACHABLE — but it requires the price to
    ///         come BACK INTO THE BAND and trade, which is the definition of the instrument NOT
    ///         being at maturity.**
    ///
    /// @dev The call graph admits exactly one writer of `premGrowth`: `_accruePremium`, reached only
    ///      from `_settlePremium`, reached only from `_allocate`, reached only from `_afterSwap`.
    ///      So a swap that produces a non-degenerate IN-BAND fill with at least one unexcluded rank
    ///      is the only thing that can release a held pot, and there is no `claim`, no `poke`, no
    ///      permissionless settle that reaches it. That much is structure. What is NOT structure,
    ///      and is what this test executes, is whether such a swap can still be constructed after a
    ///      terminal fill:
    ///
    ///        1. the pot is stranded by the downward terminal fill (`premiumHeld0`, growth 0)
    ///        2. a one-for-zero swap walks the price back INTO the band and re-credits token1 to the
    ///           seats front-first — note this fill strands a pot of its OWN in `premiumHeld1`
    ///        3. a SMALL zero-for-one fill that stops short of the tail leaves ranks unexcluded, so
    ///           `w > 0`, and `premGrowth0` finally moves
    ///        4. the head can then claim it
    ///
    ///      **SO THE HONEST ANSWER TO "is it recoverable" IS: yes, by trading the pool back to
    ///      health.** It is unreachable only in the state that actually obtains at maturity — price
    ///      outside the band, nobody quoting, holders exiting. `test_M7f` executes what happens once
    ///      they HAVE exited, which is the case that matters for the product claim.
    function test_M7e_theStrandedPotIsReleasedOnlyByReturningToTheBand() public {
        _matureDown();
        (uint256 owed0,, uint256 held0,) = hook.premiums();
        (uint256 g0Before,) = hook.growths();
        assertGt(held0, 0, "nothing was stranded: this test proves nothing");
        assertEq(g0Before, 0, "the pot was not stranded to begin with");

        // 2. back into the band. This is an ORDINARY swap by an ordinary trader.
        (,, int24 tl, int24 tu) = hook.pool();
        _swapper().swapTo(k, false, 1e28, TickMath.getSqrtPriceAtTick(tl + (tu - tl) / 2));
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick >= tl && tick < tu, "the pool did not come back into the band");
        (uint256 gMid,) = hook.growths();
        assertEq(gMid, 0, "a reverse fill released the token0 pot: the direction analysis is wrong");

        // 3. a SMALL zero-for-one fill, sized to stop short of the tail so somebody is left
        //    unexcluded. Asserted, not hoped: if it swept the book this test would prove nothing.
        (uint256 t1,) = (0, 0);
        (, t1) = hook.totals();
        assertGt(t1, 0, "the seats hold no token1: a zero-for-one fill cannot happen");
        this.doSwap(true, t1 / 50);
        (uint256 c0_, uint256 c1_) = hook.cursors();
        c0_;
        assertLt(c1_, 4, "the fill reached the tail: every rank is excluded and this proves nothing");

        (uint256 g0After,) = hook.growths();
        (,, uint256 heldAfter,) = hook.premiums();
        assertGt(g0After, 0, "the pot was NOT released by an in-band fill: it is unreachable, not deferred");
        assertLt(heldAfter, held0, "the held pot did not drain");
        console.log("stranded, then released (wei)", held0 - heldAfter);
        owed0;
    }

    /// @notice **THE CASE THAT DECIDES THE PRODUCT CLAIM, AND THE ANSWER IS NO. Once the roster has
    ///         exited — the documented end of every deployment — there is no production-reachable
    ///         action that releases the pot, because EVERY SWAP THAT COULD REACH IT REVERTS.**
    ///
    /// @dev Measured state after `_matureDown()` and five full withdrawals:
    ///
    ///          totals              (0, 3)
    ///          floats              (0, 0)
    ///          position token0     49,566,884,481,303,539     <-- the stranded pot, to 3 wei
    ///          positionLiquidity   257,348,426,066,536,964     <-- the pool still QUOTES this
    ///
    ///      The pool advertises depth it cannot trade. A one-for-zero swap — the only direction that
    ///      can take that token0 out, and the direction that would walk the price back INTO the band
    ///      — asks `_allocate` for output the seats do not have, because the money belongs to
    ///      `premiumOwed` and `_allocate` sources only from seat balances. It reverts
    ///      `QueueUnderflow(49566884481303539)` at every size, one wei included. The other direction
    ///      is a no-op: the position holds no token1, so `_afterSwap` returns on its degenerate
    ///      branch before `_allocate`.
    ///
    ///      **THIS ALSO REFUTES A DOCUMENTED CLAIM.** `Adversarial.t.sol`'s `test_6_15` states in
    ///      capitals that "`QueueUnderflow` IS STRUCTURALLY UNREACHABLE THROUGH THE POOL", reasoning
    ///      that "INVARIANT F ... says the position never exceeds the ledger, so `amtOut <= Sigma a`
    ///      always". Phase 7 falsified it: INVARIANT F is
    ///      `Sigma a + pending + premiumOwed == position + float`, so the position exceeds the SEAT
    ///      ledger by the unsettled premium, and that is exactly the shortfall the revert reports.
    ///      The claim was true when written and nothing re-examined it when `premiumOwed` was added
    ///      to the identity it rests on.
    ///
    ///      LAW 2: the reason is unwrapped from v4's `WrappedError` and matched by SELECTOR, and the
    ///      shortfall is asserted against `premiumOwed` as an IDENTITY — "it reverted" would not
    ///      name the cause, and this suite has already been caught once by a mirrored pair agreeing
    ///      through arithmetic accident.
    function test_M7f_afterTheExitEverySwapThatCouldReachThePotReverts() public {
        _matureDown();
        (uint256 owed0,, uint256 held0,) = hook.premiums();
        assertGt(owed0, 0, "nothing was stranded: this test proves nothing");

        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "exit before probing");
        }
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 f0, uint256 f1) = hook.floats();
        assertLt(t0 + t1, 1_000, "the roster did not actually exit");
        assertEq(f0 + f1, 0, "the float could pay: the shortfall would not bind here");

        // The pool still QUOTES depth. Without this the revert below could just be an empty pool.
        assertGt(uint256(hook.positionLiquidity()), 0, "the position is empty: nothing to be bricked");
        (uint256 stillThere,) = _positionValue();
        assertApproxEqAbs(stillThere, owed0, 1_000, "the position leftover is not the stranded premium");

        // THE RECOVERY TRADE, at two sizes three orders of magnitude apart. Both die, and the
        // shortfall IS the pot.
        _assertUnderflows(1e20, owed0, true);
        _assertUnderflows(1e12, owed0, false);

        // The other direction is a defined no-op, not a revert: the position holds no token1.
        (uint256 b0, uint256 b1) = hook.totals();
        this.doSwap(true, 1e18);
        (uint256 a0_, uint256 a1_) = hook.totals();
        assertEq(a0_, b0, "a zero-for-one swap credited token0 to an empty queue");
        assertEq(a1_, b1, "a zero-for-one swap credited token1 to an empty queue");

        (uint256 g0, uint256 g1) = hook.growths();
        assertEq(g0, 0, "the token0 accumulator moved after the roster exited");
        assertEq(g1, 0, "the token1 accumulator moved after the roster exited");

        // ...and it is still there, reachable only by the TEST-ONLY burn.
        (uint256 r0,) = hook.redeemAll();
        assertApproxEqAbs(r0, held0, 1_000, "the leftover is not the stranded pot");
        console.log("unreachable after exit (wei)", held0);
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

    /// @notice **THE EXISTING DEGENERATE PATH CANNOT ABSORB THIS, AND THE REASON IS ITS GATE.**
    ///
    /// @dev `_afterSwap`'s degenerate branch is guarded by `if (amtOut == 0)` — a TOTAL absence of
    ///      output. It has no notion of a PARTIAL fill: by the time `_allocate` discovers it cannot
    ///      source the swap, `amtOut > 0` and that branch is long past. So the gate is "the pool paid
    ///      nothing out", not "the queue cannot pay for what the pool paid out", and the two are
    ///      different states.
    ///
    ///      **AND IT WOULD BE THE WRONG ABSORBER EVEN IF IT WERE REACHED.** The degenerate path
    ///      CREDITS the whole input to the seat the fill would have begun at. Applied here it would
    ///      credit seats for output they did not provide, so the ledger would over-count the
    ///      position and INVARIANT F would break in the other direction — trading a revert for a
    ///      silent insolvency, which is the worse of the two.
    ///
    ///      Both halves are executed rather than argued: a swap small enough to round its output to
    ///      zero takes the degenerate branch and does NOT revert, on the very same bricked pool
    ///      where every larger swap does. That is the gate, demonstrated.
    function test_M13_theDegeneratePathIsGatedOnZeroOutputNotOnAnUnsourceableFill() public {
        _matureDown();
        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "exit before probing");
        }

        // The pool ADVERTISES depth. This is the router-facing half of the defect.
        assertGt(uint256(hook.positionLiquidity()), 0, "the position is empty: nothing to advertise");
        (uint256 stillThere,) = _positionValue();
        assertGt(stillThere, 1e16, "the position holds no token0: there is nothing to be short of");

        // A swap whose OUTPUT rounds to zero takes the degenerate branch and survives. Its
        // SIGNATURE is asserted, not merely its survival: the branch credits the WHOLE input to the
        // seat the fill would have begun at and pays nothing out, so token1 rises by exactly the one
        // wei that went in and token0 does not move. Without this the test could pass on a swap that
        // never reached the hook at all (PITFALLS 5.54).
        (uint256 b0, uint256 b1) = hook.totals();
        this.doSwap(false, 1);
        (uint256 a0_, uint256 a1_) = hook.totals();
        assertEq(a0_, b0, "the degenerate path paid token0 out of a queue that has none");
        assertEq(a1_ - b1, 1, "the degenerate branch was not entered: the input was not credited whole");

        // ...and every swap large enough to produce output does not. Three orders of magnitude.
        _expectSwapRevert(false, 1e12, bytes4(keccak256("QueueUnderflow(uint256)")), "1e12 did not brick");
        _expectSwapRevert(false, 1e15, bytes4(keccak256("QueueUnderflow(uint256)")), "1e15 did not brick");
        _expectSwapRevert(false, 1e20, bytes4(keccak256("QueueUnderflow(uint256)")), "1e20 did not brick");
    }

    /// @notice **THE SHORTFALL IS BOUNDED BY `premiumHeld`, AND THAT BOUND IS WHAT DETERMINES THE
    ///         FIX.** The money the allocator cannot source is exactly the pot that has no claimant.
    ///
    /// @dev `premiumOwed` is accrued-but-unsettled and INCLUDES amounts seats can already claim
    ///      (`premGrowth` has advanced past their marks). `premiumHeld` is the strictly narrower
    ///      pot: what never reached the accumulator at all, so no seat has a claim on a wei of it.
    ///      Drawing a shortfall from `premiumOwed` could rob a settled-but-unclaimed premium;
    ///      drawing it from `premiumHeld` cannot. Measured here: `held == owed` at maturity and the
    ///      binding shortfall equals both, so the narrow source is sufficient for this state — which
    ///      is the fact a fix needs and the one this test exists to establish.
    function test_M13b_theShortfallIsBoundedByTheUnclaimablePot() public {
        _matureDown();
        (uint256 owed0,, uint256 held0,) = hook.premiums();
        (uint256 g0,) = hook.growths();
        assertEq(g0, 0, "the accumulator moved: `held` is not the whole unclaimable pot here");
        assertEq(held0, owed0, "held and owed differ: the narrow source may not be sufficient");

        for (uint256 i; i < 5; i++) {
            _exitSeat(i, "exit before probing");
        }

        // Small swap: the shortfall is what THIS swap asked for, strictly inside the pot.
        uint256 small = _shortfallOf(1e12);
        assertGt(small, 0, "QueueUnderflow reported a zero shortfall");
        assertLt(small, held0, "a small swap underflowed by the WHOLE pot: it is not size-bounded");

        // Binding swap: the pot is the constraint, and the shortfall IS the pot.
        uint256 big = _shortfallOf(1e20);
        assertApproxEqAbs(big, held0, 1_000, "the binding shortfall is not the unclaimable pot");
        assertGt(big, small, "the shortfall did not grow with the swap: it is not min(amtOut, pot)");
        console.log("shortfall small / binding / premiumHeld0", small, big, held0);
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
