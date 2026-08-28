// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueSeats} from "../../src/queue/QueueSeats.sol";
import {ExternalLP} from "./Controls.t.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

/// @notice PHASE 5a — the gas profile of THIS hook, measured rather than inherited.
///
/// PLAN §B.9's table was measured against the Phase-0 reference spike, which had no cursors, no
/// owners, no seat tokens and no lease. Quoting it for the shipping hook would be quoting a
/// different contract, so everything here is re-measured end to end.
///
/// ─────────────────────────────────────────────────────────────────────────────────────────────
/// **LAW 4 IS NOT ENOUGH, AND THIS SUITE IS WHY (PITFALLS 5.66).**
///
/// `vm.cool()` resets the EIP-2929 ACCESS LIST — it makes the next `SLOAD` cost 2,100 again. It
/// does NOT reset the value an `SSTORE` is metered against. EIP-2200 prices a write by comparing
/// the new value to the slot's value AT THE START OF THE TRANSACTION, and a slot this test body
/// wrote is "dirty": writing it again costs **100 gas** instead of 2,900 or 20,000.
///
/// So a suite that deploys, seeds and then measures inside one test body is measuring a contract
/// whose entire storage is free to write. Measured, same swap, same `vm.cool()`:
///
///        seeded in the test body   172,263 gas
///        seeded in `setUp()`       252,966 gas      +47%
///
/// Every roster in this suite is therefore built in `setUp()`, which Forge commits as its own
/// transaction, and every test body swaps against each hook AT MOST ONCE.
/// ─────────────────────────────────────────────────────────────────────────────────────────────
///
/// **WHAT IS MEASURED.** The gas of a COMPLETE SWAP TRANSACTION through the real `V4SwapRouter`
/// against the real `PoolManager` — the number a trader actually pays. An isolated `afterSwap`
/// measurement would be smaller, more flattering, charged to nobody, and would need a harness hook
/// inside the production allocator to obtain. The hook's own marginal cost is recovered where it
/// matters — as the SLOPE, a difference between two of these transactions, which therefore carries
/// none of the router's or PoolManager's fixed cost.
///
/// **THE SWEEP SERIES HOLDS THE SWAP SIZE CONSTANT AND VARIES ONLY THE ROSTER DEPTH.** An earlier
/// draft varied both at once — bigger swaps to reach deeper seats — and a control roster with all
/// its capital in the head showed the pool's own work moving ~12,000 gas over that range. One
/// variable at a time, or the slope is measuring Uniswap rather than QUEUE.
contract GasTest is QueueFixture {
    /// @dev The depths §B.9 tabulated, capped at `MAX_SEATS`. 50 is no longer reachable: Phase 3
    ///      fixed the roster at construction and bounded it at 32, so 32 IS the worst case rather
    ///      than a point on the way to one.
    uint256[6] internal DEPTHS = [uint256(1), 2, 5, 10, 25, 32];

    /// @dev A swap large enough to sweep the whole book at any depth. It cannot under-fill: the
    ///      queue holds exactly the position, so the pool can never pay out more than the seats own.
    uint256 internal constant SWEEP_MULTIPLE = 40;

    /// @dev The head-only swap is the SAME ABSOLUTE SIZE at every depth — small enough to land
    ///      inside the head seat even when the head holds only 1/32 of the book. An earlier draft
    ///      scaled it by `1/(n·400)` so that it stayed head-only, which quietly made swap size a
    ///      second variable and produced a 21,000-gas "depth effect" at n = 1 that was really a
    ///      size effect. One variable at a time.
    uint256 internal constant HEAD_DIVISOR = 12_800;

    /// @dev PLAN §B.9's own figure, and the one `MAX_SEATS = 32` was chosen against. Restated here
    ///      as a constant so the two tests below cannot drift from the document or from each other.
    uint256 internal constant BUDGET = 300_000;

    // One roster per depth per shape, all seeded in `setUp()`.
    QueueHarness[6] internal headHooks;
    PoolKey[6] internal headKeys;
    uint256[6] internal headT0;

    QueueHarness[6] internal sweepHooks;
    PoolKey[6] internal sweepKeys;
    uint256[6] internal sweepT0;

    /// @dev A throwaway roster, swapped once at the top of a comparative test body and never
    ///      measured. See `_warmUp`.
    QueueHarness internal warmHook;
    PoolKey internal warmKey;
    uint256 internal warmT0;

    /// @dev A three-seat roster whose head has been emptied, for the pure-rank transfer cost.
    QueueHarness internal rankHook;
    PoolKey internal rankKey;

    /// @dev A full 32-seat roster, every seat funded AND priced AND metered, 30 days unsettled —
    ///      the worst configuration `addToSeat` can be made to walk.
    QueueHarness internal depositHook;
    PoolKey internal depositKey;

    /// @dev A pool on the SAME tokens, fee and spacing with NO HOOK AT ALL, seeded with the same
    ///      full-range liquidity. The baseline for what a swap costs without QUEUE.
    PoolKey internal plainKey;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CARL = address(0xCA71);

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        dec0 = 18;
        dec1 = 18;
        startPrice = Constants.SQRT_PRICE_1_4; // LAW 1 — never 1:1
        _deployTokens();

        _build(4, 0xB000);
        (warmHook, warmKey, warmT0) = (hook, k, expT0);

        for (uint256 i; i < DEPTHS.length; i++) {
            _build(DEPTHS[i], uint160(0xB100 + i * 0x10));
            (headHooks[i], headKeys[i], headT0[i]) = (hook, k, expT0);
            _build(DEPTHS[i], uint160(0xB800 + i * 0x10));
            (sweepHooks[i], sweepKeys[i], sweepT0[i]) = (hook, k, expT0);
        }

        _buildRankRoster();
        _buildDepositRoster();
        _buildPlainPool();
    }

    /// @dev The control pool: identical tokens, fee, spacing, price and full-range liquidity, and
    ///      no hook. `LIQ` is the same constant `QueueHook.seed` mints, so the two pools have the
    ///      same depth and a swap of the same size does the same work inside PoolManager.
    function _buildPlainPool() internal {
        plainKey = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolManager.initialize(plainKey, startPrice);

        ExternalLP lp = new ExternalLP(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(lp), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(lp), 1e30);
        lp.add(plainKey, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ);
    }

    /// @dev Three seats through the PRODUCTION deposit path, with the head then emptied so a
    ///      transfer of it moves rank and nothing else.
    function _buildRankRoster() internal {
        _deployHookUnfunded(0xB900, _roster(ALICE, BOB, CARL));
        _initPool();
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 60e18, 15e18);
        _addTo(CARL, 2, 900e18, 225e18);

        (uint256 a0, uint256 a1) = hook.seat(0);
        vm.prank(ALICE);
        hook.withdraw(0, a0, a1);

        (rankHook, rankKey) = (hook, k);
    }

    /// @dev The `addToSeat` worst case: a full roster, every seat ahead of the depositor priced,
    ///      metered and 30 days unsettled, so `_settleAhead` must charge all 31 of them and each
    ///      charge must be distributed over every funded seat behind it.
    function _buildDepositRoster() internal {
        _deployHookUnfunded(0xBA00, _syntheticRoster(32));
        _initPool();
        for (uint256 i; i < 32; i++) {
            address who = address(uint160(0x5EA700 + i));
            _addTo(who, i, 10e18, 3e18);
            _fund(who, 2e18, 0);
            vm.startPrank(who);
            hook.setSelfPrice(i, 100e18);
            hook.fundRent(i, 2e18);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 30 days);

        // Mint and approve the deposit itself here too: an approval written in the test body would
        // be a same-transaction write and would price the transfer's allowance read wrongly.
        _fund(address(uint160(0x5EA700 + 31)), 5e18, 1e18);

        (depositHook, depositKey) = (hook, k);
    }

    /// @dev An equal-split roster of `n` seats on its own pool.
    function _build(uint256 n, uint160 nonce) internal {
        _deployHook(nonce, n);
        uint256[] memory bps = new uint256[](n);
        for (uint256 i; i < n; i++) {
            bps[i] = 10_000 / n;
        }
        bps[n - 1] = 10_000 - (10_000 / n) * (n - 1);
        _open(bps);
    }

    /// @dev Point the fixture at one of the pre-built rosters. Writes only the TEST contract's own
    ///      storage, so it cannot perturb the measurement that follows.
    function _select(QueueHarness h, PoolKey memory key_, uint256 t0) internal {
        hook = h;
        k = key_;
        expT0 = t0;
    }

    /// @dev **THE FIRST SWAP IN A TEST BODY COSTS 21,200 GAS MORE THAN EVERY LATER ONE, AND IT IS
    ///      NOT A PROPERTY OF THE QUEUE.** `vm.cool` reaches the accounts it is given; the first
    ///      call also warms everything else the path crosses that this suite does not name — the
    ///      test contract itself, the router's internals, the addresses each of them touches.
    ///
    ///      Measured, and the reason this helper exists at all: an earlier draft read a 21,179-gas
    ///      excess on the depth-1 row as a real depth effect, and it survived two attempts to
    ///      explain it (swap size, then the cursor's first non-zero write). Running the identical
    ///      pair of measurements in BOTH ORDERS settled it — the excess followed the ORDER, not the
    ///      depth: first=depth1 146,110 / second=depth2 124,926, then first=depth2 146,129 /
    ///      second=depth1 124,907.
    ///
    ///      A comparative test therefore burns one swap on a roster it never measures. `test_5_3`
    ///      deliberately does NOT warm up, because an absolute figure quoted to a trader should
    ///      include what a real first transaction pays.
    function _warmUp() internal {
        _select(warmHook, warmKey, warmT0);
        this.doSwap(true, expT0 / 12_800);
    }

    /// @dev One cold measurement, on EVERY stateful account the swap path crosses.
    ///
    ///      `vm.cool` is per-account, and a swap touches six of them. Cooling only the hook and
    ///      PoolManager leaves the router, Permit2 and both ERC20s warm — which does not merely
    ///      flatter the number, it makes the FIRST measurement in a test body cost ~33,000 gas
    ///      more than every later one, because the first call is the one that pays for warming
    ///      them. An earlier draft of this suite read that artefact as a real depth effect.
    function _coldSwap(uint256 amountIn) internal returns (uint256 gas, uint256 touched) {
        uint256[] memory before = _snapshot(true);
        vm.cool(address(hook));
        vm.cool(address(poolManager));
        vm.cool(address(swapRouter));
        vm.cool(address(permit2));
        vm.cool(Currency.unwrap(c0));
        vm.cool(Currency.unwrap(c1));
        uint256 g = gasleft();
        this.doSwap(true, amountIn);
        gas = g - gasleft();
        touched = _countChanged(true, before);
    }

    // ─────────────────────────────────────────────────────────────────────────── 5.1 / G2 / G3

    /// @dev THE TABLE. Prints it, asserts the head-only cost is flat, and derives the sweep's
    ///      slope and intercept from the measurements rather than from a claim.
    function test_5_1_theGasTable() public {
        _warmUp();

        uint256[6] memory head;
        uint256[6] memory sweep;
        uint256[6] memory touched;

        for (uint256 i; i < DEPTHS.length; i++) {
            uint256 n = DEPTHS[i];

            _select(headHooks[i], headKeys[i], headT0[i]);
            uint256 ht;
            (head[i], ht) = _coldSwap(expT0 / HEAD_DIVISOR);
            assertEq(ht, 1, "fixture drifted: the head-only swap was not head-only");

            _select(sweepHooks[i], sweepKeys[i], sweepT0[i]);
            (sweep[i], touched[i]) = _coldSwap(expT0 * SWEEP_MULTIPLE);
            assertEq(touched[i], n, "the sweep did not reach the tail: this row proves nothing");

            emit log_named_uint("--- seats", n);
            emit log_named_uint("    head-only swap (complete tx, cold)", head[i]);
            emit log_named_uint("    full sweep     (complete tx, cold)", sweep[i]);
        }

        // ---- G2. The head-only cost must be FLAT in queue depth. That is the entire point of
        // having cursors, and a defect that threw the cursor away was once invisible to all 31
        // correctness tests. ±5% of the one-seat cost, per §D.7.
        uint256 base = head[0];
        for (uint256 i; i < DEPTHS.length; i++) {
            assertLe(head[i], base + base / 20, "head-only cost grows with queue depth: the cursor is not working");
            assertGe(head[i], base - base / 20, "head-only cost SHRANK with depth: the measurement is wrong");
        }

        // ---- G3. The sweep is linear in seats touched. The fit is taken over depths 2..32 and
        // the ONE-SEAT POINT IS DELIBERATELY EXCLUDED, for a reason that is measured below rather
        // than assumed: at depth 1 the single seat is only partially filled, so `cursor1` is
        // written 0 → 0. At every greater depth it is written 0 → nonzero, which is a 20,000-gas
        // zero-write plus its 2,100 cold surcharge. That step is a one-off, not a slope, and
        // including it in the fit would understate the slope and inflate the intercept.
        (uint256 slope, uint256 intercept) = _fit(touched, sweep, 1);
        emit log_named_uint("SWEEP SLOPE     (gas per seat walked)", slope);
        emit log_named_uint("SWEEP INTERCEPT (gas at zero seats walked)", intercept);

        for (uint256 i = 1; i < DEPTHS.length; i++) {
            uint256 predicted = intercept + slope * touched[i];
            uint256 err = sweep[i] > predicted ? sweep[i] - predicted : predicted - sweep[i];
            assertLt(err * 50, sweep[i], "the sweep is not linear in seats walked");
        }

        // ---- The one-seat step, stated as an identity rather than waved at. Going from a roster
        // of 1 to a roster of 2 costs one extra seat PLUS the first non-zero write of `cursor1`.
        uint256 step = sweep[1] - sweep[0];
        emit log_named_uint("ONE-OFF cursor1 zero-write (depth 1 -> 2, net of one seat)", step - slope);
        assertGt(step, slope, "the depth 1 -> 2 step is not larger than a seat: the cursor claim is wrong");
        assertApproxEqAbs(
            step - slope, 22_100, 3_000, "the depth 1 -> 2 excess is not a 20k zero-write plus a cold surcharge"
        );
    }

    // ───────────────────────────────────────────────────────────────────────────────── 5.3 / G4

    /// @dev **THE STATED BUDGET: 300,000 GAS OF QUEUE-ATTRIBUTABLE COST ON THE WORST SWAP THE
    ///      CONTRACT CAN PRODUCE**, and it is not a number invented here. PLAN §B.9 chose
    ///      `MAX_SEATS = 32` against exactly this figure — "round, comfortably inside a 300k
    ///      budget" — so re-measuring the hook against it is the only way to find out whether the
    ///      roster bound was ever justified.
    ///
    ///      **IT WAS NOT, ON THE NUMBERS §B.9 USED.** That table came from the Phase-0 spike at
    ///      6,753 gas per seat. This hook, measured, was **12,254** — the spike had no cursors, no
    ///      owners, no seat tokens and no lease, and its state was written in the same test body
    ///      that measured it. A full 32-seat sweep cost 412,028 gas of queue work: 37% over the
    ///      budget the roster bound was picked to fit. Phase 5b's packing brought it to 8,070 per
    ///      seat and 278,140 in total, which is inside the budget with ~7% to spare.
    ///
    ///      **EVERY NUMBER HERE IS A DIFFERENCE BETWEEN TWO SWAPS OF IDENTICAL SIZE AGAINST
    ///      IDENTICALLY SEEDED POOLS.** Only the roster depth changes, so the router's work,
    ///      PoolManager's work and the pool's own price impact cancel EXACTLY rather than
    ///      approximately. Subtracting a head-only swap from a sweeping one — the obvious thing,
    ///      and what an earlier draft did — leaves ~20,000 gas of price-impact difference sitting
    ///      inside a number labelled "the queue".
    function test_5_3_theQueueWalkFitsTheStatedBudget() public {
        _warmUp();

        uint256 g1 = _sweepAt(0, 1);
        uint256 g2 = _sweepAt(1, 2);
        uint256 g32 = _sweepAt(5, 32);

        // 30 seats separate depth 2 from depth 32, and nothing else does.
        uint256 perSeat = (g32 - g2) / 30;
        // What is left of the 1 -> 2 step once one seat is paid for: `cursor1`'s first non-zero
        // write. At depth 1 the single seat is only partially filled, so the cursor is written
        // 0 -> 0 (100 + 2,100 cold); at every greater depth it is written 0 -> nonzero
        // (20,000 + 2,100). The predicted difference is 19,900 and it is asserted, not assumed.
        uint256 cursorOnce = (g2 - g1) - perSeat;

        uint256 queueCost = perSeat * 32 + cursorOnce;
        emit log_named_uint("gas per seat walked", perSeat);
        emit log_named_uint("one-off cursor zero-write", cursorOnce);
        emit log_named_uint("QUEUE-ATTRIBUTABLE COST AT MAX_SEATS", queueCost);

        assertApproxEqAbs(cursorOnce, 19_900, 300, "the one-off is not a 20k zero-write plus its cold surcharge");
        assertLt(queueCost, BUDGET, "the queue walk has blown the 300k budget MAX_SEATS was chosen against");
    }

    /// @dev 5.3 continued — **THE ROSTER BOUND IS DERIVED FROM THE BUDGET, NOT ASSERTED BESIDE
    ///      IT.** `MAX_SEATS` is a constant in the source and 300,000 is a number in a document;
    ///      nothing but this test makes them agree. If a future change raises the per-seat cost,
    ///      this fails and names the depth the budget actually supports, rather than leaving
    ///      §B.9's justification quietly false the way Phase 0's did.
    function test_5_3b_maxSeatsIsWhatTheBudgetSupports() public {
        _warmUp();

        uint256 g2 = _sweepAt(1, 2);
        uint256 g32 = _sweepAt(5, 32);
        uint256 perSeat = (g32 - g2) / 30;

        uint256 supported = (BUDGET - 19_900) / perSeat;
        emit log_named_uint("seats the 300k budget supports", supported);
        assertGe(
            supported,
            QueueSeats(address(sweepHooks[5])).MAX_SEATS(),
            "MAX_SEATS is deeper than the stated budget pays for"
        );
    }

    /// @dev THE NUMBER TO QUOTE A TRADER. Deliberately NOT warmed up: this is the only measurement
    ///      in the suite that is meant to be an absolute rather than a comparison, so it pays
    ///      everything a real first transaction pays, including the ~21,200 gas of cold-account
    ///      access that `_warmUp` exists to factor out of the comparative rows.
    ///
    ///      500,000 gas is 1.7% of a 30M block. A sweeping trade through QUEUE is priced like a
    ///      trade, not like an event — which is the whole claim the bounded roster has to support.
    function test_5_3c_aFullSweepIsAnOrdinaryTransaction() public {
        uint256 g = _sweepAt(5, 32);
        emit log_named_uint("full 32-seat sweep, complete tx, nothing warmed", g);
        assertLt(g, 500_000, "a full sweep has stopped being an ordinary transaction");
    }

    /// @dev One sweep against the pre-built roster at index `i`, asserting it really did reach the
    ///      tail. A sweep that stopped early would make every difference above measure a shorter
    ///      walk than the one it is named after (rule 8).
    function _sweepAt(uint256 i, uint256 expectTouched) internal returns (uint256 gas) {
        _select(sweepHooks[i], sweepKeys[i], sweepT0[i]);
        uint256 touched;
        (gas, touched) = _coldSwap(expT0 * SWEEP_MULTIPLE);
        assertEq(touched, expectTouched, "the sweep did not touch the depth it was built for");
    }

    // ─────────────────────────────────────────────── the two measurements the other suites owned

    /// @dev **TRADING PURE RANK IS THE PRODUCT'S HEADLINE OPERATION, AND GAS IS THE ONLY
    ///      INSTRUMENT THAT CAN SEE IT GOING WRONG.** `_onSeatTransfer` returns early when the seat
    ///      is empty and unleased; without that line the transfer runs the whole withdrawal path —
    ///      `getSlot0`, the dust policy, `_payOut(0, 0)` — for nothing. Every correctness assertion
    ///      is identical either way, so the mutation that deletes it is invisible to all of them.
    ///      That is the same situation which once hid a whole-roster scan (PITFALLS 5.38).
    ///
    ///      **RE-MEASURED HONESTLY IN PHASE 5.** This test used to live in `Rank.t.sol` and built
    ///      its roster in its own body, which priced every `SSTORE` at 100 gas instead of 2,900 or
    ///      20,000. Its state is now built in `setUp()`. The number went DOWN rather than up —
    ///      24,969 to 23,208 — because Phase 5b's packing took a whole slot out of this path, and
    ///      that saving is larger than the correction to the write pricing.
    function test_5_2_tradingPureRankDoesNotOpenThePosition() public {
        _warmUp();
        hook = rankHook;
        k = rankKey;

        uint128 liqBefore = hook.positionLiquidity();
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 a0, uint256 a1) = hook.seat(0);
        assertTrue(a0 == 0 && a1 == 0, "the seat is not empty: this test proves nothing");

        vm.cool(address(hook));
        vm.prank(ALICE);
        uint256 g = gasleft();
        hook.transfer(address(0xDEAD), 0, 1);
        uint256 cost = g - gasleft();
        emit log_named_uint("pure-rank transfer (cold)", cost);

        assertEq(hook.positionLiquidity(), liqBefore, "a pure-rank transfer moved the position");
        (uint256 g0, uint256 g1) = hook.floats();
        assertEq(g0, f0, "a pure-rank transfer moved float0");
        assertEq(g1, f1, "a pure-rank transfer moved float1");

        // MEASURED 2026-08-28, cold storage AND cold writes: **23,208** with the early return,
        // **29,603** without it (the deleted line makes the transfer call `getSlot0` and run the
        // whole dust-policy path for nothing). The bound sits between the two — 14% above the real
        // number, 10% below the mutant — and is DERIVED from both measurements. It was NOT chosen
        // and then checked: the first bound written here was 37,000, which the mutant passed.
        assertLt(cost, 26_500, "a pure-rank transfer is walking the withdrawal path");
    }

    /// @dev **THE WORST-CASE DEPOSIT.** `addToSeat` settles every PRICED seat ahead of it, and each
    ///      of those settlements hands money to every funded seat behind it — O(priced ahead x
    ///      roster). That is the price of closing the flash-loan rent grab (PITFALLS 5.59), and the
    ///      point of measuring it at the worst configuration the contract can reach is that the
    ///      number is then stated rather than assumed.
    ///
    ///      The configuration is not free to an attacker: every settlement it forces also drains
    ///      the payer's own meter, so somebody trying to price a depositor out is paying rent to
    ///      the very seat they are griefing.
    ///
    ///      **RE-MEASURED HONESTLY IN PHASE 5.** This lived in `Harberger.t.sol` and reported
    ///      2,337,576 from state its own body had written. Built in `setUp()`, and with Phase 5b's
    ///      packing already applied, it is **2,610,805** — 12% higher than the number that was
    ///      being quoted, and the two corrections push in opposite directions: honest write pricing
    ///      costs this path more, packing gives some of it back.
    function test_5_6_theWorstCaseDepositCostIsMeasured() public {
        _warmUp();
        hook = depositHook;
        k = depositKey;

        address last = address(uint160(0x5EA700 + 31));
        vm.cool(address(hook));
        vm.prank(last);
        uint256 g = gasleft();
        hook.addToSeat(31, 5e18, 1e18);
        uint256 cost = g - gasleft();
        emit log_named_uint("worst-case addToSeat (32 seats, 31 priced ahead)", cost);

        // A CEILING ON A COST, not an assertion about correctness — its job is to make a
        // regression loud. It fits a 30M block eight times over.
        assertLt(cost, 3_000_000, "the worst-case deposit cost has regressed");
        _checkInvariantR("5.6");
    }

    /// @dev **WHAT QUEUE COSTS A TRADER, AGAINST NO HOOK AT ALL. MEASURED: +31,169 gas, +36%.**
    ///
    ///      Say that number, not a rounder one. It is tempting to claim the common case is free
    ///      because it is flat in queue depth, and it is not free — it is a THIRD MORE than the
    ///      same swap on a bare pool. What is true, and is the claim worth making, is that the
    ///      overhead is a constant a trader can price rather than something that grows with how
    ///      many seats the book has.
    ///
    ///      The comparison is against a pool with **no hook at all** on the same tokens, fee tier,
    ///      spacing, price and full-range liquidity, taking the identical swap — so the difference
    ///      is the hook and nothing else. Where it goes: two extra callbacks, two reads of
    ///      `protocolFeesAccrued`, and the allocator's own cold reads of the order word, both
    ///      cursors and one seat.
    ///
    ///      Front-first allocation only walks the queue when a swap is big enough to exhaust the
    ///      head seat, and most are not; `test_5_1` is what makes "flat in depth" a measurement
    ///      rather than a hope.
    function test_5_7_theOverheadAgainstAPlainPoolIsMeasured() public {
        _warmUp();

        _select(headHooks[5], headKeys[5], headT0[5]);
        uint256 amount = expT0 / HEAD_DIVISOR;
        (uint256 queued, uint256 touched) = _coldSwap(amount);
        assertEq(touched, 1, "the control swap was not head-only");

        k = plainKey;
        vm.cool(address(poolManager));
        vm.cool(address(swapRouter));
        vm.cool(address(permit2));
        vm.cool(Currency.unwrap(c0));
        vm.cool(Currency.unwrap(c1));
        uint256 g = gasleft();
        this.doSwap(true, amount);
        uint256 plain = g - gasleft();

        emit log_named_uint("head-only swap through QUEUE", queued);
        emit log_named_uint("same swap, same pool shape, NO HOOK", plain);
        emit log_named_uint("QUEUE overhead", queued - plain);

        assertGt(queued, plain, "QUEUE measured CHEAPER than no hook at all: the comparison is broken");
        // Stated as a ratio, because that is the form the claim is made in. A swap that lands in
        // the head must not cost half as much again as an ordinary one.
        // A CEILING, so a regression is loud. 36% measured; 50% is the line past which the
        // overhead stops being a constant a trader can shrug at.
        assertLt((queued - plain) * 100, plain * 50, "QUEUE's per-swap overhead has grown past 50%");
    }

    /// @dev Ordinary least squares for y = a + b·x over the points from `from` onward. Written out
    ///      rather than eyeballed, because "looks linear" is not a measurement.
    function _fit(uint256[6] memory x, uint256[6] memory y, uint256 from)
        internal
        pure
        returns (uint256 slope, uint256 intercept)
    {
        uint256 n = 6 - from;
        uint256 sx;
        uint256 sy;
        uint256 sxy;
        uint256 sxx;
        for (uint256 i = from; i < 6; i++) {
            sx += x[i];
            sy += y[i];
            sxy += x[i] * y[i];
            sxx += x[i] * x[i];
        }
        slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
        intercept = (sy - slope * sx) / n;
    }
}
