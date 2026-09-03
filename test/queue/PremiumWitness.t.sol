// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title PHASE 8 — CAN THE PREMIUM WITNESS GO RED?
///
/// @notice `QueueFixture` now models the priority premium: `_refAccrue` computes each seat's share
///         as the TRUE RATIONAL pro-rata `floor(total_j·L_i/w_j)`, with no fixed point and no
///         accumulator anywhere, and `_assertPremiumClaim` bounds the residual against the hook's
///         two floors in closed form. **A witness nobody has ever seen fail is not a witness**
///         (LAW 2, LAW 5), so this file is the whole of the evidence that it can.
///
/// @dev Every mutant below subclasses `QueueHarness` and changes ONE rule. They are driven through
///      the identical harness as the positive control, and each one is asserted to push some seat
///      OUTSIDE the derived bound by `_premiumWitnessExcess()` — the same arithmetic `_check`
///      asserts, reported rather than enforced.
///
///      **THE POSITIVE CONTROL IS NOT OPTIONAL.** Without `test_W0` a mutant that diverged for an
///      unrelated reason — a fixture that cannot model this pool at all — would read as success.
abstract contract PremiumWitnessBase is QueueFixture {
    uint256 constant PHI = 8_500;
    uint256 constant SEATS = 4;

    function _premiumBps() internal view virtual override returns (uint256) {
        return PHI;
    }

    function _deployAt(string memory artifact, uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo(artifact, _ctorArgsPremium(_syntheticRoster(SEATS), PHI), a);
        hook = QueueHarness(a);
        _fundHook(a);
        uint256[] memory bps = new uint256[](SEATS);
        // DELIBERATELY UNEVEN. An equal split makes every seat's weight the same number, so a
        // mutation that used the wrong seat's weight would land on the right answer by accident.
        bps[0] = 4_000;
        bps[1] = 3_000;
        bps[2] = 2_000;
        bps[3] = 1_000;
        _openBand(bps);
    }

    /// @dev Both directions. A one-directional run moves only one accumulator, so half of every
    ///      mutation below would be unreachable (PITFALLS 5.54).
    ///
    ///      **AND THEN IT SETTLES EVERY SEAT, WHICH IS NOT TIDINESS — IT IS WHAT MAKES HALF THESE
    ///      MUTANTS REACHABLE AT ALL.** `seat()` reports raw ledger PLUS the claim computed by
    ///      `_claims`, which is not `virtual` and is therefore NEVER mutated here. So a defect that
    ///      lives in `_syncSeat` — the function that CASHES a claim — is invisible until a seat with
    ///      a non-zero pending claim is actually settled. Measured: without this sweep the front
    ///      seat is the only one ever settled, and it is the payer on every fill, so its claim is
    ///      zero whatever the weighting is; `M-W3` and `M-W4` both read `0 wei outside the bound`
    ///      and looked like surviving mutations. They were unreached paths (PITFALLS 5.54 again).
    ///
    ///      `withdraw(id, 0, 0)` settles without paying anything out and costs no rank, so it moves
    ///      nothing but the premium credit.
    function _drive() internal {
        for (uint256 i; i < 6; i++) {
            bool zeroForOne = i % 2 == 0;
            // **THE SIZE COMES FROM THE TOKEN BEING SPENT, NOT FROM `expT0` FOR BOTH DIRECTIONS.**
            // This suite runs 18/6, and the first draft sized a token1 swap off the token0 book —
            // a 1e12 error that pushed the price clean out of the band, made every fill part wing
            // and part queue, and showed up as a 2,110-wei "conservation failure" that was the
            // FIXTURE. LAW 1's decimals clause applies to the harness as much as to the code.
            _swap(zeroForOne, (zeroForOne ? expT0 : expT1) / 400);
        }
        for (uint256 i; i < SEATS; i++) {
            _withdrawTracked(i, 0, 0);
        }
    }
}

// ============================================================================== THE MUTANTS

/// @dev M-W1 — the payers are NOT excluded from the denominator. `_settlePremium` still moves their
///      marks past the accrual, so they collect nothing; the only effect is that everybody else's
///      share is divided by a larger `w`. The wei is stranded in `premiumOwed` and no conservation
///      assertion in the project notices. This is PITFALLS 5.124's shape, one dimension over.
contract NoExclusionHook is QueueHarness {
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
        excludedL = 0; // THE MUTATION, and nothing else on either branch.
        if (inIsZero) {
            uint256 total = pot + premiumHeld0;
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            premiumOwed0 += pot;
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            if (inc == 0) {
                premiumHeld0 = total;
                return;
            }
            premiumHeld0 = 0;
            unchecked {
                premGrowth0 += inc;
            }
        } else {
            uint256 total = pot + premiumHeld1;
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            premiumOwed1 += pot;
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            if (inc == 0) {
                premiumHeld1 = total;
                return;
            }
            premiumHeld1 = 0;
            unchecked {
                premGrowth1 += inc;
            }
        }
    }
}

/// @dev M-W2 — HALF THE POT reaches the accumulator. `premiumOwed` still counts the whole of it, so
///      INVARIANT F and every conservation assertion in the project still tie out to the wei: the
///      missing half is conserved and claimable by nobody. Only a witness that knows what each seat
///      SHOULD have been paid can see it.
contract HalfPotHook is QueueHarness {
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
            uint256 total = pot / 2 + premiumHeld0; // THE MUTATION
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            premiumOwed0 += pot;
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            if (inc == 0) {
                premiumHeld0 = total;
                return;
            }
            premiumHeld0 = 0;
            unchecked {
                premGrowth0 += inc;
            }
        } else {
            uint256 total = pot / 2 + premiumHeld1; // THE MUTATION
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            premiumOwed1 += pot;
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            if (inc == 0) {
                premiumHeld1 = total;
                return;
            }
            premiumHeld1 = 0;
            unchecked {
                premGrowth1 += inc;
            }
        }
    }
}

/// @dev M-W3 — **THE PRE-PHASE-8 RULE, RESTORED.** The claim is weighted by the seat's INVENTORY in
///      the token it is standing with rather than by the depth it contributed. That is the weighting
///      that made the accumulator's scale depend on the pair's decimals and let a seat drained to
///      its last wei collect an entire pot (`test_7_14`). It is expressed here through `_syncSeat`
///      because `_claims` is not `virtual`; the accrual side is untouched, so this is purely a
///      question of who the same pot is split between.
contract InventoryWeightHook is QueueHarness {
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

    function _syncSeat(Seat storage s) internal override returns (uint256 a0, uint256 a1) {
        a0 = s.a0;
        a1 = s.a1;
        uint256 owed0;
        uint256 owed1;
        unchecked {
            uint256 d0 = premGrowth0 - s.snap0;
            if (d0 != 0 && a1 != 0) owed0 = FullMath.mulDiv(a1, d0, PREMIUM_Q); // THE MUTATION
            uint256 d1 = premGrowth1 - s.snap1;
            if (d1 != 0 && a0 != 0) owed1 = FullMath.mulDiv(a0, d1, PREMIUM_Q); // THE MUTATION
        }
        // Clamp to what was actually accrued: the mutated weight is not the accumulator's own
        // denominator, so the shares no longer sum to the pot and an unclamped version underflows
        // `premiumOwed` rather than misallocating. The clamp keeps the mutation about WHO GETS PAID.
        if (owed0 > premiumOwed0) owed0 = premiumOwed0;
        if (owed1 > premiumOwed1) owed1 = premiumOwed1;

        if (owed0 != 0) {
            a0 += owed0;
            s.a0 = _u128(a0);
            standing0 += owed0;
            premiumOwed0 -= owed0;
        }
        if (owed1 != 0) {
            a1 += owed1;
            s.a1 = _u128(a1);
            standing1 += owed1;
            premiumOwed1 -= owed1;
        }
        s.snap0 = premGrowth0;
        s.snap1 = premGrowth1;
    }
}

/// @dev M-W4 — **THE CREDIT LANDS IN THE WRONG TOKEN.** A settlement pays the token OPPOSITE the
///      one the seat was standing with — you are paid, in the token the swapper brought, for the
///      token you did not get to sell. That rule is stated in `_claims`'s docblock and enforced
///      nowhere else: every conservation assertion in the project sums the two tokens separately,
///      but `premiumOwed0` and `premiumOwed1` are both decremented by the right amounts here, so
///      INVARIANT F still ties out on BOTH tokens while every seat holds the wrong thing.
contract WrongTokenHook is QueueHarness {
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

    function _syncSeat(Seat storage s) internal override returns (uint256 a0, uint256 a1) {
        uint256 wl = s.liquidity;
        a0 = s.a0;
        a1 = s.a1;
        uint256 owed0;
        uint256 owed1;
        if (wl != 0) {
            unchecked {
                uint256 d0 = premGrowth0 - s.snap0;
                if (d0 != 0) owed0 = FullMath.mulDiv(wl, d0, PREMIUM_Q);
                uint256 d1 = premGrowth1 - s.snap1;
                if (d1 != 0) owed1 = FullMath.mulDiv(wl, d1, PREMIUM_Q);
            }
        }
        // THE MUTATION: the token0 claim is credited to `a1` and the token1 claim to `a0`. The
        // ledgers are debited correctly, so nothing in the conservation half of the suite moves.
        if (owed0 != 0) {
            a1 += owed0;
            s.a1 = _u128(a1);
            standing1 += owed0;
            premiumOwed0 -= owed0;
        }
        if (owed1 != 0) {
            a0 += owed1;
            s.a0 = _u128(a0);
            standing0 += owed1;
            premiumOwed1 -= owed1;
        }
        s.snap0 = premGrowth0;
        s.snap1 = premGrowth1;
    }
}

// ============================================================================== THE SUITE

contract PremiumWitnessTest is PremiumWitnessBase {
    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        dec0 = 18;
        dec1 = 6; // LAW 1 as amended: 18/18 is to decimals what 1:1 is to price
        // 1 whole token0 buys 4 whole token1, at THESE decimals. `QueueDeployBase._sqrtPriceX96`.
        startPrice = uint160(FixedPointMathLib.sqrt((4 * (10 ** dec1) * (1 << 192)) / (10 ** dec0)));
        _deployTokens();
    }

    /// @notice **THE POSITIVE CONTROL.** The unmutated hook, at the shipping φ, on the 18/6 pool the
    ///         deploy script builds, through the identical harness. Without it a mutant that
    ///         diverged for an unrelated reason would read as success.
    function test_W0_positive_theUnmutatedHookIsINSIDETheDerivedBound() public {
        _deployAt("QueueHarness.sol:QueueHarness", 0xD100);
        _drive();
        _check("W0 unmutated");

        // PITFALLS 5.54 — prove the mechanism was actually exercised before believing the pass.
        (uint256 owed0, uint256 owed1,,) = hook.premiums();
        assertGt(owed0, 0, "no token0 premium was withheld: this control proves nothing");
        assertGt(owed1, 0, "no token1 premium was withheld: this control proves nothing");
        (uint256 g0, uint256 g1) = hook.growths();
        assertGt(g0, 0, "premGrowth0 never moved: this control proves nothing");
        assertGt(g1, 0, "premGrowth1 never moved: this control proves nothing");
        assertEq(_premiumWitnessExcess(), 0, "the unmutated hook is outside the derived bound");

        // **THE ERASURE COUNTER, REPORTED RATHER THAN ASSERTED, AND HERE IS WHY.**
        // `_settlePremium` advances the mark of every rank in `[start, next]`, and when the last
        // seat a fill reached was EXACTLY exhausted, `next` is one PAST the walk — so that seat's
        // mark moves without it ever having been settled, and anything it had already earned stops
        // being claimable by anybody while staying counted in `premiumOwed`. The witness models
        // that faithfully (it must, or the split comparison would describe a different contract)
        // and counts it here. A non-zero number is a real, permanent loss of a seat's earned
        // premium; zero means this run never hit the exact-fill boundary, NOT that the path is
        // safe. Asserting zero would turn an unreached path into a green tick (PITFALLS 5.54).
        emit log_named_uint("premium ERASED by a mark advanced without a settle, token0", refErased0);
        emit log_named_uint("premium ERASED by a mark advanced without a settle, token1", refErased1);
    }

    /// @notice **THE KNOWN-ANSWER CASE, and it is the one that actually protects the witness**
    ///         (LAW 5, third corollary: build the case whose answer you know in advance).
    ///
    /// @dev A ONE-SEAT roster. The sole seat is the payer on every fill AND the only contributor of
    ///      depth, so it is its own recipient: **the premium is a NO-OP for it.** It pays φ of the
    ///      fee out of the fill and gets the whole of it back through the accumulator, minus the
    ///      per-accrual floor. That is the right answer and it is knowable without running anything:
    ///      with nobody standing behind you, there is nothing you are paying FOR.
    ///
    ///      **THIS TEST HAS BEEN INVERTED AND THE OLD FORM IS WORTH RECORDING.** It used to assert
    ///      that the pot was HELD WHOLE — `held0 == owed0`, `g0 == 0` — because the sole seat was
    ///      excluded from its own denominator, `w` was zero, and `_accruePremium` took its hold
    ///      branch. **That is the maturity brick in miniature**: a held pot is money the position
    ///      holds that `standing0`/`standing1` does not count, and on a one-seat roster EVERY fill
    ///      held, so the shortfall grew without bound (`test_M7f`, `test_7_7`). A fill that sweeps
    ///      the whole book now distributes over the full `standingL` and moves no marks, which on
    ///      this roster hands the seat its own pot straight back.
    ///
    ///      No floor is involved in the accrual itself, so there is still no bound to hide inside:
    ///      if the sweep rule or the mark rule is wrong, this is off by the entire pot.
    function test_W1_knownAnswer_aSoleSeatIsItsOwnPayerAndItsOwnRecipient() public {
        address a = address(FLAGS ^ (uint160(0xD200) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgsPremium(_syntheticRoster(1), PHI), a);
        hook = QueueHarness(a);
        _fundHook(a);
        uint256[] memory bps = new uint256[](1);
        bps[0] = 10_000;
        _openBand(bps);

        for (uint256 i; i < 4; i++) {
            bool zeroForOne = i % 2 == 0;
            _swap(zeroForOne, (zeroForOne ? expT0 : expT1) / 400);
        }

        (uint256 owed0, uint256 owed1, uint256 held0, uint256 held1) = hook.premiums();
        assertGt(owed0 + owed1, 0, "nothing was withheld: this test proves nothing");

        // THE INVERSION. Both used to be `assertEq(held, owed)`.
        assertEq(held0, 0, "a token0 pot was HELD on a book the fill swept: the ledger goes short");
        assertEq(held1, 0, "a token1 pot was HELD on a book the fill swept: the ledger goes short");

        (uint256 g0, uint256 g1) = hook.growths();
        assertGt(g0, 0, "the sole seat was not paid back the token0 premium it withheld from itself");
        assertGt(g1, 0, "the sole seat was not paid back the token1 premium it withheld from itself");

        // **AND IT IS A NO-OP, WHICH IS A DIFFERENT CLAIM FROM "IT ACCRUED"** (LAW 3, second
        // corollary). Settle the seat and its ledger must absorb the WHOLE of what was withheld,
        // to the per-accrual floor — two token0 accruals and two token1 accruals, one wei each.
        (uint256 raw0Before, uint256 raw1Before) = hook.rawSeat(0);
        _withdrawTracked(0, 0, 0);
        (uint256 raw0After, uint256 raw1After) = hook.rawSeat(0);
        uint256 got0 = raw0After - raw0Before;
        uint256 got1 = raw1After - raw1Before;
        assertLe(got0, owed0, "the sole seat was credited MORE token0 than was ever withheld");
        assertGe(got0 + 2, owed0, "the sole seat did not get its own token0 pot back");
        assertLe(got1, owed1, "the sole seat was credited MORE token1 than was ever withheld");
        assertGe(got1 + 2, owed1, "the sole seat did not get its own token1 pot back");

        _check("W1 sole seat");
    }

    // ---------------------------------------------------------------------------- the mutants

    function _expectRed(string memory artifact, uint160 nonce, string memory what) internal {
        _deployAt(artifact, nonce);
        _drive();
        uint256 excess = _premiumWitnessExcess();
        emit log_named_uint(string.concat(what, ": wei outside the derived bound"), excess);
        assertGt(excess, 0, string.concat(what, ": THE WITNESS DID NOT NOTICE -- it is not a witness"));
    }

    function test_W2_theWitnessCatchesAMissingPayerExclusion() public {
        _expectRed("PremiumWitness.t.sol:NoExclusionHook", 0xD300, "M-W1 payers not excluded");
    }

    function test_W3_theWitnessCatchesHalfThePotGoingMissing() public {
        _expectRed("PremiumWitness.t.sol:HalfPotHook", 0xD400, "M-W2 half the pot");
    }

    function test_W4_theWitnessCatchesTheInventoryWeighting() public {
        _expectRed("PremiumWitness.t.sol:InventoryWeightHook", 0xD500, "M-W3 inventory weight");
    }

    function test_W5_theWitnessCatchesACreditThatLandsInTheWrongToken() public {
        _expectRed("PremiumWitness.t.sol:WrongTokenHook", 0xD600, "M-W4 wrong token");
    }

    // ======================================================= THE EXACT-EXHAUSTION BOUNDARY (case D)

    /// @notice **A FILL THAT EXACTLY EXHAUSTS A SEAT NO LONGER ERASES THE NEXT SEAT'S ACCRUED
    ///         PREMIUM. This test asserted the erasure; it is INVERTED, not deleted, because the
    ///         scenario it executes is the evidence the fix was needed.**
    ///
    /// @dev **THE DEFECT, recorded so the guard below is legible.** `_allocate` sets
    ///      `next = take == bal ? i + 1 : i` and then exits, because `st.remaining == 0`. `next` is
    ///      a CURSOR — where the next fill in this direction starts — and on an exact exhaustion it
    ///      is one PAST the last rank the walk touched. It was handed to `_settlePremium` as the far
    ///      end of the PAYER set, and `_settlePremium` writes `snap := g` for every rank in that
    ///      range. So the seat at that rank had its mark advanced having never been `_syncBal`'d.
    ///
    ///      Excluding that seat from THIS pot is harmless and is what the docblock defends. Moving
    ///      its MARK is not: the mark carries its claim on every EARLIER accrual, and advancing it
    ///      without settling first DESTROYS that claim. The wei stayed in `premiumOwed`, so
    ///      INVARIANT F tied out and conservation saw nothing — PITFALLS 5.124's family, money
    ///      conserved and claimable by nobody. **Measured on this fixture: 7.17e19 wei, and it was
    ///      the swapper's own choice, because any router exposes exact-output.**
    ///
    ///      `_allocate` now hoists its loop variable and hands `_settlePremium` the rank one past
    ///      the last one it actually TOUCHED. So the assertions are the mirror of what they were:
    ///      rank 1's mark does not move, it keeps what it had earned, and it can go on to COLLECT
    ///      it — which is a stronger statement than "the mark did not move", and it is the one that
    ///      would fail if the fix moved the money somewhere else instead of destroying it.
    ///
    ///      **THIS IS A DIRECTED TEST AND IT HAS TO BE.** The boundary needs a swap sized to the wei;
    ///      a fuzzer will not find it.
    function test_W6_anExactlyExhaustingFillKeepsTheNextSeatsAccruedPremium() public {
        _erasureCase(true, 0xD700);
    }

    /// @dev THE MIRROR. `_settlePremium` and `_accruePremium` keep one rule in two branches, and
    ///      this project has been wrong in exactly one of two copies six times (PITFALLS 5.37, 5.50,
    ///      5.52 twice, 5.73, 5.125). Nothing about the token0 case passing says anything about this.
    function test_W7_theSameBoundaryInTheOtherDirection() public {
        _erasureCase(false, 0xD800);
    }

    /// @param zeroForOne the direction of the EXACT-OUTPUT fill. `true` drains the head of token1
    ///        and accrues a token0 pot, so the claim at risk is token0.
    /// @dev The locals live in a struct because this function is otherwise `Stack too deep` without
    ///      `via_ir`, and the repo builds without it.
    struct Erasure {
        uint256 headBal;
        uint256 nextId;
        uint256 rawBefore;
        uint256 pendingBefore;
        uint256 owedBefore;
        uint256 rawGain;
        uint256 pendingAfter;
        uint256 owedRose;
    }

    function _erasureCase(bool zeroForOne, uint160 nonce) internal {
        _deployAt("QueueHarness.sol:QueueHarness", nonce);

        // ONE ordinary fill first, in the SAME direction, so rank 1 is left holding an unsettled
        // claim from an accrual it was not a payer in. Without this the boundary has nothing to
        // erase and the test would pass vacuously (PITFALLS 5.54).
        _swap(zeroForOne, (zeroForOne ? expT0 : expT1) / 400);

        Erasure memory e;
        e.nextId = hook.idAtRank(1);
        // The OUTGOING token: `zeroForOne` takes token1 out.
        e.headBal = _bal(hook.idAtRank(0), !zeroForOne, false);
        // The POT's token, which is the one whose claim is at risk: `zeroForOne` pays token0.
        e.rawBefore = _bal(e.nextId, zeroForOne, true);
        e.pendingBefore = _bal(e.nextId, zeroForOne, false) - e.rawBefore;
        e.owedBefore = _owed(zeroForOne);

        assertGt(e.headBal, 0, "the head is empty: this test proves nothing");
        assertGt(e.pendingBefore, 0, "rank 1 had nothing pending: this test proves nothing");

        // THE BOUNDARY. Ask the pool for exactly what the head is holding.
        _swapExactOut(zeroForOne, e.headBal, type(uint128).max);

        assertEq(
            _bal(hook.idAtRank(0), !zeroForOne, false),
            0,
            "the head was NOT exactly exhausted: the boundary was not reached"
        );

        e.rawGain = _bal(e.nextId, zeroForOne, true) - e.rawBefore;
        e.pendingAfter = _bal(e.nextId, zeroForOne, false) - _bal(e.nextId, zeroForOne, true);
        e.owedRose = _owed(zeroForOne) - e.owedBefore;

        emit log_named_uint("rank 1 pending premium BEFORE the boundary fill", e.pendingBefore);
        emit log_named_uint("rank 1 pending premium AFTER                   ", e.pendingAfter);
        emit log_named_uint("rank 1 raw ledger GAIN (what it was credited)  ", e.rawGain);
        emit log_named_uint("premiumOwed rose by (this fill's pot)          ", e.owedRose);
        emit log_named_uint("witness refErased0                            ", refErased0);
        emit log_named_uint("witness refErased1                            ", refErased1);

        // **THE INVERSION, IN THREE PARTS.**
        //
        // 1. The walk never reached rank 1, so nothing may have been CREDITED to it — the ledger is
        //    untouched. This is the half that was true before the fix as well, and it is what makes
        //    part 2 a statement about the MARK rather than about a settlement.
        assertEq(e.rawGain, 0, "rank 1's ledger moved on a fill that never reached it");

        // 2. Its mark did NOT advance, so the claim it had already earned is still there. It used
        //    to read `assertEq(e.pendingAfter, 0)` — an unmarked seat cannot be distinguished from
        //    an erased one by any conservation assertion in the project, which is why this pair of
        //    tests exists at all.
        assertGe(
            e.pendingAfter, e.pendingBefore, "rank 1's mark was advanced past an accrual it never settled: ERASURE"
        );
        // ...and it is strictly MORE, because rank 1 is not a payer on this fill either, so it also
        // takes a share of the pot the boundary fill withheld.
        assertGt(e.pendingAfter, e.pendingBefore, "rank 1 took no share of the boundary fill's own pot");

        // 3. Nothing was erased anywhere on the roster, by the WITNESS's own count — an independent
        //    model of the rule, which is what caught this in the first place.
        assertEq(refErased0, 0, "the witness counted a token0 erasure: a mark moved without a settle");
        assertEq(refErased1, 0, "the witness counted a token1 erasure: a mark moved without a settle");

        // **AND IT IS REAL MONEY, WHICH IS A DIFFERENT CLAIM FROM "THE MARK DID NOT MOVE"** (LAW 3,
        // second corollary). A `withdraw(id, 0, 0)` settles rank 1 without paying anything out; its
        // raw ledger must absorb the whole pending claim, to the accumulator's floor. Without this
        // the fix could have left a claim that no settlement can cash and every assertion above
        // would still be green.
        uint256 rawPreSettle = _bal(e.nextId, zeroForOne, true);
        _withdrawTracked(e.nextId, 0, 0);
        uint256 collected = _bal(e.nextId, zeroForOne, true) - rawPreSettle;
        emit log_named_uint("rank 1 actually COLLECTED                     ", collected);
        (uint256 lo, uint256 hi) = _refBound(e.nextId, zeroForOne);
        assertLe(collected, e.pendingAfter + hi, "rank 1 collected MORE than it was owed");
        assertGe(collected + lo, e.pendingAfter, "rank 1 could not cash the claim its mark preserved");
        assertGt(collected, e.pendingBefore, "the preserved claim was not actually payable");
    }

    /// @dev One seat, one token. `raw` selects the bare slot; otherwise the SETTLED value, which is
    ///      what `_syncBal` hands the allocator. **The two tokens are not interchangeable here and
    ///      conflating them is the whole hazard**: a `zeroForOne` fill drains token1 and pays a
    ///      token0 pot, so the balance that must be exactly exhausted is `a1` while the claim at
    ///      risk is `a0`. The first draft of this helper returned the same token for both.
    function _bal(uint256 id, bool tok0, bool raw) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = raw ? hook.rawSeat(id) : hook.seat(id);
        return tok0 ? a0 : a1;
    }

    function _owed(bool zeroForOne) internal view returns (uint256) {
        (uint256 o0, uint256 o1,,) = hook.premiums();
        return zeroForOne ? o0 : o1;
    }
}
