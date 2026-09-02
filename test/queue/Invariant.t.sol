// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHandler} from "./handlers/QueueHandler.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title The Phase 6 invariant campaign (PLAN §C.6, gate §D.8)
///
/// @notice I1-I8 asserted over randomised interleavings of every state-changing entry point the
///         shipping hook has, against the real v4 stack.
///
/// @dev **§D.8 V1 — `targetContract(address(handler))` IS CALLED, AND `targetSelector` WITH IT.**
///      `targetSelector` alone leaves the fuzz target set as EVERY contract deployed in `setUp` —
///      including `PoolManager` and both ERC20s — which makes the campaign a random walk over
///      Uniswap rather than over QUEUE. Both are set here: the contract, so the target set is
///      exactly one address; the selectors, so the action set is exactly the twelve listed below
///      and a future public helper on the handler cannot silently join the fuzz surface.
///
/// @dev **§D.8 V5 — `fail_on_revert = false`, AND WHAT REPLACES IT.**
///      The handler is expected to hit legitimate reverts: authorisation on a seat you do not own,
///      over-withdrawal, `QueueUnderflow` when the queue cannot source a swap, buying your own
///      seat. `true` would abort the campaign on the first of them and every sequence would be a
///      prefix. But `false` alone is the standing way an invariant suite passes on luck — it hides
///      a handler whose calls ALL revert.
///
///      So the setting is `false` and the handler classifies every revert against an explicit
///      allow-list of outcomes the mechanism is entitled to produce; anything else increments
///      `unexpectedReverts`, which **I7 asserts is zero**. That is strictly stronger than
///      `fail_on_revert = true`, which only says "something reverted". `test_6_0_campaignWasNotVacuous`
///      then asserts the campaign actually LANDED calls on each path, because a suite that proves
///      invariants about a hook nothing ever touched is worth nothing (PITFALLS 5.54).
contract InvariantTest is QueueFixture {
    QueueHandler internal handler;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CARL = address(0xCA71);
    address constant DAVE = address(0xDA7E);

    /// @dev **THE SOLVENCY BOUND, AND PHASE 6 SIZED IT — AND RESHAPED IT — FROM MEASUREMENT.**
    ///
    ///      The claim QUEUE makes is NOT that a seat redeems its face value. Face value is an upper
    ///      bound and dust policy F1 pays `min(face, available)`; the claim is that the difference
    ///      is a rounding residual, and the residual is v4's own — it computes a swap's amounts and
    ///      a position's redeemable value with two differently-rounded formulas, both in the pool's
    ///      favour (§E.4).
    ///
    ///      §E.4 measured ~0.15 wei per swap AT THE SEEDED PRICE. **That figure does not
    ///      generalise, and this campaign is what showed it.** The truncation scales with how far
    ///      the price has been driven from where the liquidity sits, so a pool whose depth has been
    ///      withdrawn into the float and whose price is then pushed to the tick floor loses ~1e9
    ///      wei on a single swap instead of 0.15.
    ///
    ///      **AND THE OBVIOUS DENOMINATOR IS THE WRONG ONE.** Bounding the shortfall against the
    ///      CURRENT ledger fails, and it fails for a reason worth stating rather than tuning away:
    ///      the residual accumulates while the ledger is drained by withdrawals, so the last wei on
    ///      the books is eventually smaller than the residual it has to absorb. The campaign
    ///      reached exactly that — `owed = 5,337,018,741`, `backing = 0`, a 100% shortfall of five
    ///      gwei. Nothing was stolen and nothing broke; the queue had simply been emptied down past
    ///      its own rounding dust. So the residual is bounded against what has ever ENTERED the
    ///      queue, which is the quantity it is actually proportional to, and the README now says
    ///      that the LAST holders to withdraw bear it (PITFALLS 5.78).
    ///
    ///      **Measured over the campaign, both directions, after every action:**
    ///
    ///          worst SURPLUS      0 wei, both tokens, exactly
    ///          worst SHORTFALL    ~9.8e12 wei on token0 against ~1e23 wei of lifetime inflow
    ///                             ~260 wei on token1
    ///
    ///      The two directions are two different claims and get two different assertions. A SURPLUS
    ///      is not a residual — nothing credits the position without crediting the ledger, so a
    ///      surplus is precisely what a hook that UNDER-CREDITS a swap produces, and it is asserted
    ///      at ZERO rather than bounded.
    uint256 constant K = 100_000;
    /// @dev Parts per billion of everything that has ever entered the queue. Measured worst case
    ///      over the campaign: under 1 (9.8e12 wei against ~1e23 of lifetime inflow). Bounded at
    ///      1,000 ppb — one part per million — which is stable rather than barely-passing.
    uint256 constant SHORTFALL_PPB = 1_000;

    /// @dev **THE CAMPAIGN HAS NEVER RUN AT φ > 0, AND THAT IS A COVERAGE HOLE RATHER THAN A
    ///      CHOICE.** `QueueFixture._premiumBps()` returns 0, this file never overrode it, and the
    ///      premium landed in Phase 7 — so every invariant here has only ever been checked against a
    ///      contract with the priority premium switched off. On this project the campaign has found
    ///      a real defect every time it was pointed somewhere new, and it has never been pointed
    ///      here. It now runs at the SHIPPING φ, which is also the only configuration that exercises
    ///      `_settlePremium`, the payer exclusion, and the premium's half of `_syncSeat`.
    function _premiumBps() internal view virtual override returns (uint256) {
        return 8_500; // QueueDeployBase.PREMIUM_BPS
    }

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        // Rent is denominated in SECONDS. Starting at Foundry's default of 1 would make
        // `block.timestamp - lastSettled` meaningless.
        vm.warp(1_700_000_000);
        startPrice = Constants.SQRT_PRICE_1_4; // LAW 1: never 1:1
        dec0 = 18;
        dec1 = 6; // LAW 1: asymmetric decimals
        _deployTokens();
        _deployHookUnfunded(0x9601, _roster(ALICE, BOB, CARL, DAVE));
        _initPool();

        // Seed the roster so the allocator has something to allocate from the first call. Without
        // it every early swap is a `QueueUnderflow` and the campaign spends its depth budget
        // proving that an empty queue is empty.
        _addTo(ALICE, 0, 400e18, 100e18);
        _addTo(BOB, 1, 600e18, 150e18);
        _addTo(CARL, 2, 137e18, 34e18);
        _addTo(DAVE, 3, 763e18, 191e18);

        address[] memory actors = new address[](4);
        (actors[0], actors[1], actors[2], actors[3]) = (ALICE, BOB, CARL, DAVE);
        handler = new QueueHandler(hook, poolManager, swapRouter, permit2, k, actors);

        // The seeding above went through the fixture, not the handler, so the handler's ghost
        // ledger has to start where the queue actually is. Read once, at setUp, from the deposits
        // the fixture made — not from `hook.totals()`.
        handler.seedGhost(400e18 + 600e18 + 137e18 + 763e18, 100e18 + 150e18 + 34e18 + 191e18);

        targetContract(address(handler));

        bytes4[] memory sels = new bytes4[](12);
        sels[0] = QueueHandler.addToSeat.selector;
        sels[1] = QueueHandler.withdraw.selector;
        sels[2] = QueueHandler.swap.selector;
        sels[3] = QueueHandler.transferSeat.selector;
        sels[4] = QueueHandler.buySeat.selector;
        sels[5] = QueueHandler.setSelfPrice.selector;
        sels[6] = QueueHandler.fundRent.selector;
        sels[7] = QueueHandler.withdrawRent.selector;
        sels[8] = QueueHandler.settleRent.selector;
        sels[9] = QueueHandler.claimPending.selector;
        sels[10] = QueueHandler.sweepFloat.selector;
        sels[11] = QueueHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));

        // `unauthorised` is deliberately OUTSIDE the fuzz selector set: it is driven by
        // `test_6_9_authorisationHoldsUnderTheCampaign` so its outcome is asserted directly rather
        // than only through a counter.
    }

    // ==================================================================================== I1 - I8

    /// @notice I1 — the ledger is exactly what went in minus what came out.
    ///
    /// @dev The witness is the handler's ghost, built from its own inputs and from token flows
    ///      measured across the hook's boundary. `assertEq`, not a bound: a bound in the right
    ///      direction is not a correctness assertion (PITFALLS 5.53).
    function invariant_I1_ledgerEqualsTheGhost() public view {
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 w0, uint256 w1) = hook.pendingTotals();
        // **`premiumOwed` IS ON THE LEDGER SIDE, AND ITS ABSENCE HERE WAS A COVERAGE HOLE RATHER
        // THAN A BUG IN THE HOOK.** A premium is withheld from a fill and credited to a seat only
        // when that seat is next touched, so between those two moments the wei have entered the
        // queue — the ghost counts them — while no seat's RAW balance claims them. `totals()` is
        // deliberately the raw slot sum. `QueueFixture._checkInvariantF` was amended for exactly
        // this in Phase 7; this file's copy of the same identity was not, and nothing noticed
        // because the campaign had never been run at φ > 0. One rule, two places, right in one:
        // the sixth instance on this project (PITFALLS 5.37, 5.50, 5.52 twice, 5.73, 5.125).
        //
        // The residue is real but tiny — each claim is a FLOORED share, so sub-wei remainders stay
        // in `premiumOwed` for good. Measured on the first φ > 0 campaign: 3 wei on a 7.4e20 ledger.
        (uint256 q0, uint256 q1,,) = hook.premiums();
        assertEq(t0 + w0 + q0, handler.gIn0() - handler.gOut0(), "I1: token0 ledger != ghost");
        assertEq(t1 + w1 + q1, handler.gIn1() - handler.gOut1(), "I1: token1 ledger != ghost");
    }

    /// @notice I2 — SOLVENCY. Everything the queue is owed is backed by the position plus the float.
    ///
    /// @dev INVARIANT F. This is the LEDGER-vs-BACKING claim; the REDEEMABILITY claim is a
    ///      different one and is asserted separately in `afterInvariant`, by really burning the
    ///      position (LAW 3, second corollary).
    function invariant_I2_solvency() public view {
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 w0, uint256 w1) = hook.pendingTotals();
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 p0, uint256 p1) = _positionValue();
        // Same omission as I1, same reason, and here it presented as the position being
        // OVER-BACKED by exactly the unsettled premium — which reads like a solvency defect and is
        // the instrument. PITFALLS 5.75: a broken measurement that looks like a broken mechanism
        // has cost this project more time than any real bug.
        (uint256 q0, uint256 q1,,) = hook.premiums();
        _solvent("I2 token0", t0 + w0 + q0, p0 + f0, handler.gIn0());
        _solvent("I2 token1", t1 + w1 + q1, p1 + f1, handler.gIn1());
    }

    /// @dev The witness is the handler's ghost, built from its own inputs and from token flows
    ///      measured across the hook's boundary. The two directions are DIFFERENT CLAIMS and get two
    ///      different assertions. `inflow` is everything that has ever entered the queue in this
    ///      token, which is what the residual is proportional to.
    ///
    ///      **The excess branch is EXACT equality, and that is a real claim rather than an oversight.**
    ///      Every shipped path moves value one way: deposits and swaps credit the ledger exactly, and
    ///      v4 rounds for the pool, so the hook can only ever end up SHORT. A burn/re-mint cycle would
    ///      round both ways — which is why the (unshipped) `recenter()` broke this, by 393 wei on an
    ///      `owed` of 4.0e21. If a band move is ever shipped, this assertion needs the same bound on
    ///      both signs, and `docs/wip/recenter-v2/` records why.
    function _solvent(string memory tag, uint256 owed, uint256 backing, uint256 inflow) internal pure {
        if (backing >= owed) {
            require(backing == owed, string.concat(tag, ": the position is OVER-backed"));
            return;
        }
        uint256 short_ = owed - backing;
        require(
            short_ <= K || short_ * 1e9 <= inflow * SHORTFALL_PPB,
            string.concat(
                tag,
                ": shortfall exceeds the stated residual bound: short=",
                vm.toString(short_),
                " inflow=",
                vm.toString(inflow),
                " ppb=",
                vm.toString(inflow == 0 ? 0 : (short_ * 1e9) / inflow)
            )
        );
    }

    /// @notice I3 — INVARIANT C: no cursor LEADS a funded seat.
    /// @dev A lagging cursor costs gas. A leading cursor skips a funded seat, which is silent theft
    ///      of rank. Reuses the fixture's assertion rather than writing a third copy of the rule.
    function invariant_I3_cursorsNeverLead() public view {
        (uint256 k0, uint256 k1) = hook.cursors();
        for (uint256 r; r < k0; r++) {
            (uint256 a0,) = hook.seat(hook.idAtRank(r));
            assertEq(a0, 0, "I3: cursor0 leads a funded seat");
        }
        for (uint256 r; r < k1; r++) {
            (, uint256 a1) = hook.seat(hook.idAtRank(r));
            assertEq(a1, 0, "I3: cursor1 leads a funded seat");
        }
    }

    /// @notice I4 — FRONT-FIRST. No swap ever filled a seat while a funded seat stood ahead of it.
    /// @dev Checked per swap by the handler, because it is a property of a TRANSITION and not of a
    ///      state. The counter is what survives `fail_on_revert = false`.
    function invariant_I4_frontFirst() public view {
        assertEq(handler.frontFirstViolations(), 0, "I4: a swap filled behind a funded seat");
    }

    /// @notice I5 — every seat id has ERC-6909 supply exactly one, and a real holder.
    /// @dev Structural in `QueueSeats` (balanceOf is a view over `seatHolder`), asserted anyway:
    ///      the claim the product makes is about supply, and a claim nothing checks is a claim
    ///      nothing protects.
    function invariant_I5_seatSupplyIsOne() public view {
        uint256 n = hook.seatCount();
        for (uint256 id; id < n; id++) {
            address owner = hook.ownerOf(id);
            assertTrue(owner != address(0), "I5: a seat lost its holder");
            uint256 supply;
            uint256 a = handler.actorCount();
            for (uint256 i; i < a; i++) {
                supply += hook.balanceOf(handler.actors(i), id);
            }
            assertEq(supply, 1, "I5: seat supply is not exactly one");
        }
    }

    /// @notice I6 — the packed `order` word is a PERMUTATION of `0..n-1`, and `rankOfId` inverts
    ///         `idAtRank` at every rank.
    ///
    /// @dev **THIS IS THE LIVE FORM OF §C.6's I6.** The plan names `seatIndex`/`indexSeat`, a pair
    ///      of mappings Phase 4 replaced with one packed word and a scanning `rankOfId` — precisely
    ///      so there is no second copy of the order to disagree with the first. The property that
    ///      survives the change is the one asserted here.
    function invariant_I6_orderIsAPermutation() public view {
        uint256 n = hook.seatCount();
        bool[] memory seen = new bool[](n);
        for (uint256 r; r < n; r++) {
            uint256 id = hook.idAtRank(r);
            assertLt(id, n, "I6: order holds an id outside the roster");
            assertFalse(seen[id], "I6: order holds a duplicate id");
            seen[id] = true;
            assertEq(hook.rankOfId(id), r, "I6: rankOfId is not the inverse of idAtRank");
        }
    }

    /// @notice I7 — no legal sequence bricks the hook, and nothing reverts for a reason the
    ///         mechanism is not entitled to produce.
    /// @dev See the contract header for why this replaces `fail_on_revert = true`.
    function invariant_I7_noUnexpectedReverts() public view {
        assertEq(
            handler.unexpectedReverts(),
            0,
            string.concat(
                "I7: unexpected revert in ",
                string(abi.encodePacked(handler.firstUnexpectedTag())),
                " selector ",
                vm.toString(handler.firstUnexpectedSelector())
            )
        );
    }

    /// @notice I8a — rent settlement conserves the rent pot exactly.
    /// @dev `escrowTotal + unallocatedRent0` is unchanged by any settlement: the money moves from
    ///      the payer's meter to the meters behind, or is HELD when there is nobody behind to pay.
    function invariant_I8a_settlementConservesRent() public view {
        assertEq(handler.rentConservationViolations(), 0, "I8a: a settlement created or destroyed rent");
    }

    /// @notice I8b — the aggregate equals the sum of its members.
    /// @dev PITFALLS 5.63: an aggregate is a SECOND WRITER of the fact its members hold, and a
    ///      settlement that credits without charging leaves the currency0 balance identity
    ///      perfectly happy while the seats collectively own more than the hook holds.
    function invariant_I8b_escrowTotalEqualsTheSeats() public view {
        (uint256 esc,) = hook.rentTotals();
        assertEq(_sumEscrows(), esc, "I8b: escrowTotal disagrees with the seats");
    }

    /// @notice I8c — INVARIANT R: every wei of currency0 the hook holds is spoken for, and the
    ///         three pots do not overlap.
    function invariant_I8c_currencyIsFullyAccounted() public view {
        _checkInvariantR("I8c");
    }

    /// @notice I8e — rent only ever flows BACKWARD.
    /// @dev Conservation cannot see this: paying the seats AHEAD conserves every single wei while
    ///      inverting the mechanism's entire economics. It is the shape of the bug that killed
    ///      HardcapHook.
    function invariant_I8e_rentFlowsBackward() public view {
        assertEq(handler.rentDirectionViolations(), 0, "I8e: rent was paid to a seat AHEAD of the payer");
    }

    // ============================================================================== after each run

    /// @notice The REDEEMABILITY half of solvency, asserted by really burning the position.
    ///
    /// @dev LAW 3, second corollary: conservation of the LEDGER (I1) and redeemability of the
    ///      POSITION are two different claims and need two different assertions. `invariant_I2` is
    ///      the first; this is the second, and it is the one the hook cannot fool by agreeing with
    ///      itself. It is destructive, so it runs inside a state snapshot and is reverted — and it
    ///      lives here, which Foundry calls ONCE per run, rather than in an invariant function,
    ///      which is called after every single call.
    ///
    ///      **NOTHING CUMULATIVE MAY BE ASSERTED HERE.** A coverage floor ("at least one swap
    ///      landed") looks like it belongs in `afterInvariant`, and it does not: the shrinker
    ///      answers it by shrinking the sequence to ONE CALL, which trivially has no swaps in it,
    ///      so the assertion reports a failure that is an artefact of shrinking. Coverage is
    ///      asserted instead by `test_6_0`, a DETERMINISTIC campaign the shrinker never touches.
    function afterInvariant() public {
        uint256 snap = vm.snapshotState();

        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 w0, uint256 w1) = hook.pendingTotals();
        (uint256 f0, uint256 f1) = hook.floats();
        uint256 g0;
        uint256 g1;
        // The campaign can legitimately empty the position outright — withdrawals and evacuations
        // pull tokens out through the float, and a queue whose seats have all been drained holds
        // what is left as float with zero liquidity. `modifyLiquidity` on an empty position reverts
        // `CannotUpdateEmptyPosition`, so there is nothing to burn and the float alone must cover
        // the ledger, which is exactly what the assertions below then demand.
        if (hook.positionLiquidity() != 0) (g0, g1) = hook.redeemAll();

        // Face value is an UPPER BOUND, not a promise (dust policy F1). Same two-sided bound as I2,
        // but measured by REALLY BURNING the position rather than by valuing it — which is the one
        // instrument the hook cannot be wrong about, and the one §E.4's residual is defined against.
        // The premium terms belong on the ledger side here for the same reason as in I1 and I2 —
        // this is the REDEEMABILITY half of the same identity (LAW 3, second corollary), so it has
        // the same shape. It is a THIRD copy of INVARIANT F in this file alone, which is why the
        // Phase 7 amendment could be missing from all three and go unnoticed at φ = 0.
        (uint256 q0, uint256 q1,,) = hook.premiums();
        _solvent("I2b token0", t0 + w0 + q0, g0 + f0, handler.gIn0());
        _solvent("I2b token1", t1 + w1 + q1, g1 + f1, handler.gIn1());

        vm.revertToState(snap);
    }

    // ============================================================ the campaign is not vacuous (6.0)

    /// @notice A DETERMINISTIC campaign that reaches every path, with every invariant asserted after
    ///         every single call.
    ///
    /// @dev PITFALLS 5.54 — before believing a path is covered, check that it was ENTERED. Every
    ///      invariant above holds trivially on a hook nobody ever touched, so something has to
    ///      prove the campaign does work. Three things rule out the obvious places to put that
    ///      proof:
    ///
    ///        * a separate `test_` reading the handler's counters cannot see the fuzz campaign at
    ///          all — Foundry gives every test its own `setUp()`, so it would read a handler that
    ///          had never been called and pass on zero;
    ///        * `afterInvariant` can see them, but the SHRINKER answers any cumulative assertion
    ///          there by shrinking to a one-call sequence, which has no coverage by construction;
    ///        * the per-selector table Foundry prints is not an assertion and nothing regresses on it.
    ///
    ///      So coverage is proven by driving the same handler through a fixed pseudo-random
    ///      sequence with a hardcoded seed. It is deterministic, so it cannot be flaky and the
    ///      shrinker never touches it; it asserts I1-I8 after EVERY call rather than at the end of a
    ///      run, which is strictly more often than the fuzz campaign does; and it ends by asserting
    ///      that each path was actually reached, including the rare ones the fuzz campaign only
    ///      sometimes hits — a buyout, a foreclosure, an evacuation carrying capital.
    function test_6_0_scriptedCampaignReachesEveryPathAndHoldsEveryInvariant() public {
        uint256 seed = 0x5EA7C0FFEE;
        for (uint256 i; i < 500; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _dispatch(seed);
            _assertEveryInvariant();
        }

        // ---- the paths the fuzz campaign only sometimes reaches, asserted here every time
        assertGt(handler.calls("swap"), 0, "no swap ever landed");
        assertGt(handler.swapsThatFilled(), 0, "no swap ever moved a seat: I4 would be vacuous");
        assertGt(handler.calls("addToSeat"), 0, "no deposit ever landed");
        assertGt(handler.calls("withdraw"), 0, "no withdrawal ever landed");
        assertGt(handler.calls("claimPending"), 0, "no pending claim ever landed");
        assertGt(handler.calls("settleRent"), 0, "settlement never ran: I8a/I8e would be vacuous");
        assertGt(handler.calls("fundRent"), 0, "no meter was ever funded");
        assertGt(handler.calls("withdrawRent"), 0, "no meter was ever drained");
        assertGt(handler.calls("setSelfPrice"), 0, "no seat was ever priced: rent never accrued");
        assertGt(handler.calls("sweepFloat"), 0, "the float was never swept back in");
        assertGt(handler.calls("transferSeat"), 0, "no seat was ever transferred");
        assertGt(handler.buyouts(), 0, "no seat was ever BOUGHT: the lease is untested here");
        assertGt(handler.evacuationsWithCapital(), 0, "no evacuation ever moved capital");
        assertEq(handler.orderPermuted(), 1, "no foreclosure ever demoted a seat");
        assertGt(handler.calls("warp"), 0, "time never advanced: every rent bill was zero");
        emit log_named_uint("worst shortfall token0, ppb", handler.worstShortPpb0());
        emit log_named_uint("worst shortfall token1, ppb", handler.worstShortPpb1());
        emit log_named_uint("worst surplus token0, wei", handler.worstOver0());
        emit log_named_uint("worst surplus token1, wei", handler.worstOver1());
        emit log_named_uint("worst shortfall token0, wei", handler.worstShortAbs0());
        emit log_named_uint("worst shortfall token1, wei", handler.worstShortAbs1());
    }

    /// @dev One step of the scripted campaign. The weights are deliberately uneven: `warp` and
    ///      `swap` are the two actions everything else depends on, and a uniform draw over twelve
    ///      actions leaves the interesting states too shallow to reach.
    function _dispatch(uint256 seed) internal {
        uint256 a = seed >> 8;
        uint256 b = seed >> 72;
        uint256 c = seed >> 136;
        uint256 pick = seed % 100;

        if (pick < 20) {
            handler.swap(a, (seed >> 200) & 1 == 1, b);
        } else if (pick < 34) {
            handler.warp(a);
        } else if (pick < 44) {
            handler.addToSeat(a, b, c);
        } else if (pick < 54) {
            handler.withdraw(a, b, c, (seed >> 201) & 1 == 1);
        } else if (pick < 62) {
            handler.setSelfPrice(a, b);
        } else if (pick < 70) {
            handler.fundRent(a, b, c);
        } else if (pick < 76) {
            handler.settleRent(a, b);
        } else if (pick < 82) {
            handler.withdrawRent(a, b, (seed >> 202) & 1 == 1);
        } else if (pick < 88) {
            handler.buySeat(a, b, c, (seed >> 203) & 1 == 1);
        } else if (pick < 92) {
            handler.transferSeat(a, b, (seed >> 204) & 1 == 1);
        } else if (pick < 96) {
            handler.claimPending(a, b, c);
        } else {
            handler.sweepFloat(a);
        }
    }

    /// @dev Every invariant in this file, in one call. Named separately so the scripted campaign
    ///      and the fuzz campaign assert exactly the same set and cannot drift apart.
    function _assertEveryInvariant() internal view {
        invariant_I1_ledgerEqualsTheGhost();
        invariant_I2_solvency();
        invariant_I3_cursorsNeverLead();
        invariant_I4_frontFirst();
        invariant_I5_seatSupplyIsOne();
        invariant_I6_orderIsAPermutation();
        invariant_I7_noUnexpectedReverts();
        invariant_I8a_settlementConservesRent();
        invariant_I8b_escrowTotalEqualsTheSeats();
        invariant_I8c_currencyIsFullyAccounted();
        invariant_I8e_rentFlowsBackward();
    }

    /// @notice §D.8 V3's authorisation lens, driven directly so the outcome is ASSERTED rather than
    ///         only counted. Every one of these must revert with `NotSeatOwner`.
    /// @dev PITFALLS 5.62: two brand-new external functions shipped with no ownership check under
    ///      test and BOTH survived a 99/99 green suite. Every external function's authorisation
    ///      gets exercised, per entry point, not once for the family.
    function test_6_9_authorisationHoldsUnderTheCampaign() public {
        for (uint256 id; id < hook.seatCount(); id++) {
            for (uint256 which; which < 5; which++) {
                uint256 before = handler.unexpectedReverts();
                handler.unauthorised(id, id + 1, which);
                assertEq(
                    handler.unexpectedReverts(),
                    before,
                    string.concat("a non-holder succeeded on entry point ", vm.toString(which))
                );
            }
        }
        assertGt(handler.calls("unauthorised"), 0, "nothing was actually attempted");
    }
}
