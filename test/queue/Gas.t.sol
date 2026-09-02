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
    /// @dev **THE GAS SUITE MEASURES THE CONFIGURATION THE PRODUCT SHIPS, NOT THE NULL CONTROL.**
    ///      The rest of the suites run at φ = 0 so that Phase 7 can be shown to change no
    ///      pre-existing behaviour. A budget measured there would be a budget for a contract nobody
    ///      deploys — the premium's settle path costs real cold storage, and pretending otherwise is
    ///      the same class of mistake as measuring gas inside a test body (LAW 4). This is
    ///      `QueueDeployBase.PREMIUM_BPS`.
    function _premiumBps() internal view virtual override returns (uint256) {
        return 8_500;
    }

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

    /// @dev **THERE IS NO GAS BUDGET ANY MORE, AND DELETING IT IS THE FINDING RATHER THAN A
    ///      CONCESSION. `BUDGET` USED TO LIVE HERE. IT WAS FICTION.**
    ///
    ///      What stood here was `BUDGET = 550_000`, described in its own log line as "the 300k
    ///      budget". Those are not the same number, and the derived roster depth the suite printed
    ///      — 27 — was `(550,000 - 24,125) / 19,280`. A real 300,000 budget supports **14**. The
    ///      label had been wrong through two raises without anybody noticing, because nothing in
    ///      the arithmetic ever had to agree with the word.
    ///
    ///      **Where 300,000 came from (`PLAN.md` §B.9): nowhere external.** `MAX_SEATS = 32` was
    ///      chosen as "comfortably inside a 300k budget" against the Phase-0 spike's 6,753 gas per
    ///      seat — 32 x 6,753 = 216,096, rounded up with slack. PLAN's own next sentence is "Both
    ///      halves were wrong." So the budget was back-formed to make 32 look comfortable, and 32
    ///      was then *derived* from the budget. It is circular. It is not a block-limit fraction,
    ///      not a router gas stipend, not an L2 assumption.
    ///
    ///      **And it ratcheted every time it was about to bind:** 300k -> 400k -> 550k, while
    ///      `test_5_3c`'s absolute ceiling went 500k -> 850k -> 1,050k -> 1,100k -> 1,250k. Each
    ///      raise was argued honestly as a real mechanism cost. That is exactly the problem: a
    ///      budget which is raised whenever it binds is not a budget, it is a changelog, and
    ///      `assertEq(supported, 27)` was a change-detector wearing a constraint's costume.
    ///
    ///      **This argument has now been had twice — PITFALLS 5.108 and 5.129 — and it came back
    ///      because 5.108's CONCLUSION survived while its REASONING did not.** Both of 5.108's
    ///      supports are false: `test_4_41` was a bare `assertEq(MAX_SEATS, 32)` that could only
    ///      fail if somebody edited the constant (now fixed to assert the actual coupling), and
    ///      "shrinking `MAX_SEATS` buys nothing back, the word is one slot at any width" is true
    ///      of the WORD and false of the COST: measured, 32 -> 27 is -96,645 on the sweep and
    ///      -620,191 on the worst-case deposit. Deleting the budget is what stops a third round.
    ///
    ///      **What replaces it, and it is strictly stronger:** the slope is pinned directly
    ///      (`test_5_3b`), and the two costs that matter are asserted in ABSOLUTE terms against a
    ///      fraction of a real block — `test_5_3c` (sweep) and `test_5_6` (deposit). Those are
    ///      tied to something outside this repo. The budget never was.

    /// @dev THE SWEEP SLOPE, PINNED TO ITS MEASUREMENT. See `test_5_3b`.
    uint256 internal constant SLOPE = 19_280;

    /// @dev **THE TOLERANCE IS DERIVED, NOT CHOSEN TO PASS.** Two independent estimators of the
    ///      slope exist in this suite — `test_5_1` fits 1 -> 32 and reads 19,279; `test_5_3`/
    ///      `test_5_3b` difference 2 -> 32 and read 19,280 — so the spread attributable to the
    ///      estimator rather than to the code is **1 gas**. The smallest REAL regression this is
    ///      meant to catch is one storage slot entering the per-seat walk, which is >= 2,100 gas
    ///      cold. 150 sits an order of magnitude below that floor and two orders above the
    ///      estimator spread.
    ///
    ///      Stated plainly so nobody widens it later: this pins the slope against a STRUCTURAL
    ///      change to the seat walk. It is deliberately NOT sensitive to a 100-gas warm-write
    ///      difference, and it is not meant to be.
    uint256 internal constant SLOPE_TOL = 150;

    /// @dev **THE ROSTER THIS PROJECT ACTUALLY DEPLOYS — mirrors `QueueDeployBase.SEATS`, which is
    ///      `internal` and so cannot be read from here.** If that constant moves, `test_5_3d`'s
    ///      headline number is measuring a roster nobody ships; `test/queue/Deploy.t.sol` is what
    ///      executes the real script and would catch the divergence.
    ///
    ///      `MAX_SEATS` is a STRUCTURAL ceiling (one byte per rank in a 32-byte `order` word), not
    ///      a claim that 32 seats are affordable to sweep — nor, since the seat-economics frontier
    ///      landed, a depth anybody should deploy at. See `test_5_3d`.
    uint256 internal constant SHIPPING_SEATS = 5;

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

    QueueHarness steadyHook;
    PoolKey steadyKey;
    uint256 steadyT0;

    function setUp() public virtual {
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

        // The steady-state pool: built AND traded here, so the premium's global slots and the head
        // seat's mark are already non-zero when `test_5_8` measures the next swap.
        _build(4, 0xBB00);
        (steadyHook, steadyKey, steadyT0) = (hook, k, expT0);
        uint256 warmAmt = expT0 / HEAD_DIVISOR;
        _coldSwap(warmAmt);

        // The CONTROL pool gets the same treatment. A v4 pool's first swap writes its own
        // fee-growth slots from zero too, so comparing a warmed QUEUE against a virgin plain pool
        // would flatter QUEUE by exactly the costs this is meant to expose.
        k = plainKey;
        this.doSwap(true, warmAmt);
        k = steadyKey;
    }

    /// @dev The control pool: identical tokens, fee, spacing, price and liquidity **over the same
    ///      band**, and no hook. `LIQ` is the same constant `QueueHook.seed` mints, so the two
    ///      pools have the same depth and a swap of the same size does the same work inside
    ///      PoolManager. The range must match the hook's band: a full-range control against a
    ///      banded subject measures the RANGE, not the hook.
    function _buildPlainPool() internal {
        plainKey = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolManager.initialize(plainKey, startPrice);

        ExternalLP lp = new ExternalLP(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(lp), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(lp), 1e30);
        (,, int24 btl, int24 btu) = hook.pool();
        lp.add(plainKey, btl, btu, LIQ);
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
        // **THE BAND, NOT `_open`.** Every gas number in this project used to be taken on a
        // FULL-RANGE fixture built through the test-only `seed()` — a configuration production
        // cannot create, since `_afterInitialize` always snaps a band. On it `_tickInBand` is
        // always true, so `_queueShare` took its fast path and `_bandStep`/`computeSwapStep` —
        // the clip a real out-of-band swap must pay for — never executed in any measurement.
        _openBand(bps);
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
        // **THE BASELINE IS DEPTH 2, NOT DEPTH 1, AND THAT IS A BRANCH FACT RATHER THAN A WIDENED
        // TOLERANCE.** Since Phase 8 the premium excludes the seats a fill PAID from the pot they
        // generated. On a ONE-SEAT roster the head is the only seat, so it is the only payer, the
        // denominator `standingL - lTouched` is zero, and the pot is HELD — one `premiumHeld` write
        // and no accumulator write. From two seats up there is somebody to pay and `premGrowth` is
        // written instead. That is a one-off STEP of ~20,349 gas between depth 1 and depth 2, not a
        // slope, and the property this assertion exists to defend is unharmed: measured at φ = 8500,
        // depths 2 through 32 come in at 221,315 / 221,316 / 221,316 / 221,317 / 221,318 — **three
        // gas across a sixteen-fold change in depth.** At φ = 0 no pot exists, so there is no step
        // and all six depths agree to 21 gas.
        //
        // Basing the flatness check on the degenerate one-seat row would compare a swap that
        // accrues against five that do not, which is the mistake this file warns about in rule 8:
        // before attributing a difference to the thing you varied, check it is not following
        // something else.
        assertLe(head[0], head[1], "the one-seat row is not the cheap branch: the step is not what it seems");
        uint256 base = head[1];
        for (uint256 i = 1; i < DEPTHS.length; i++) {
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

    /// @dev **THE ANATOMY OF THE QUEUE WALK: its slope, its two one-offs, and what they are made
    ///      of.** This used to be phrased as a test that the walk "fits the stated budget". There
    ///      is no stated budget any more and there never honestly was one — see the note where
    ///      `BUDGET` used to be declared. What survives that deletion is the part which was always
    ///      doing the work: decomposing the walk into a per-seat cost and two one-time costs, and
    ///      asserting each against what it is physically made of.
    ///
    ///      For the record of how bad the original figure was: §B.9's table came from the Phase-0
    ///      spike at 6,753 gas per seat. This hook, measured, was **12,254** — the spike had no
    ///      cursors, no owners, no seat tokens and no lease, and its state was written in the same
    ///      test body that measured it. Phase 5b's packing brought it to 8,070; it is 19,280 today.
    ///
    ///      **EVERY NUMBER HERE IS A DIFFERENCE BETWEEN TWO SWAPS OF IDENTICAL SIZE AGAINST
    ///      IDENTICALLY SEEDED POOLS.** Only the roster depth changes, so the router's work,
    ///      PoolManager's work and the pool's own price impact cancel EXACTLY rather than
    ///      approximately. Subtracting a head-only swap from a sweeping one — the obvious thing,
    ///      and what an earlier draft did — leaves ~20,000 gas of price-impact difference sitting
    ///      inside a number labelled "the queue".
    function test_5_3_theQueueWalkIsDecomposedIntoWhatItIsMadeOf() public {
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

        // **TWO ONE-OFFS, NOT ONE.** Until marginal pricing this was purely `cursor1`'s first
        // non-zero write (20,000 + 2,100 cold - the 2,200 the depth-1 case already paid = 19,900),
        // and it was asserted at that number alone. It now also carries the ONE-TIME construction
        // of the swap's price curve, which `_allocate` builds lazily at the first seat that does
        // not finish the swap - i.e. never at depth 1, always at depth 2 and beyond. So the whole
        // of it lands in this step and nowhere else.
        //
        // Both components are bounded rather than blended: the cursor write is a floor that must
        // still be there, and the curve is the remainder, which is two `SqrtPriceMath` calls plus
        // two `TickMath.getSqrtPriceAtTick` and must not quietly become something larger.
        assertGt(cursorOnce, 19_900, "the cursor zero-write has vanished from the depth 1 -> 2 step");
        assertApproxEqAbs(
            cursorOnce - 19_900, 4_225, 400, "the one-time price-curve construction is not what it was measured at"
        );
        // **RE-BASELINED 2026-09-02 (PHASE 8), AND THE MOVE IS ATTRIBUTED RATHER THAN ABSORBED.**
        // Three changes landed on the seat's storage in one session, all of them deliberate and all
        // of them documented in `QueueHook`:
        //   * the premium accumulators went `uint128` X64 -> `uint256` X128, so `snap0`/`snap1`
        //     stopped sharing a slot (the packing was bought with an overflow argument whose
        //     precondition was the 18/6 defect itself);
        //   * `Seat` gained `liquidity`, the premium's new weight — a fourth slot;
        //   * `_settlePremium` walks the seats a fill PAID, twice, to exclude them from their own pot.
        // Measured end to end against pristine HEAD, same harness, LAW 4 throughout:
        //
        //       gas per seat walked          14,778 -> 19,280   (+30.5%)
        //       full 32-seat sweep, phi=0   996,805 -> 1,143,352 (+14.7%)
        //       full 32-seat sweep, phi=8500 1,039,700 -> 1,188,462 (+14.3%)
        //       pure-rank transfer (cold)    28,719 -> 34,238   (+19.2%)
        //       head-only swap, phi=8500    162,766 -> 152,947   (-6.0%)
        //       steady state, phi=8500      183,998 -> 174,179   (-5.3%)
        //
        // The HOT path got CHEAPER and the deep walk got dearer, which is the honest shape of it:
        // the per-swap constant fell (one weight instead of two, and an early return when a seat
        // contributed no depth) while the per-SEAT cost rose by a slot. Given a head-only swap is
        // the dominant case and a 32-seat sweep is the worst one, that is the right direction to
        // have moved in — but it is a real cost and it is written here rather than smoothed away.
        // **A CEILING, AND IT IS NO LONGER PRETENDING TO BE DERIVED FROM ANYTHING.** This once
        // read "has blown the budget MAX_SEATS was chosen against"; that budget was fiction and is
        // gone. The queue-attributable cost at the structural extreme is kept under observation
        // here so a regression is loud, but the claim that MATTERS is absolute and lives in
        // `test_5_3c` (32 seats, 1,188,462 = 4.0% of a 30M block) and `test_5_3d` (the roster we
        // actually ship, 667,947 = 2.2%). Those are measured against a real block. This is not.
        assertLt(queueCost, 700_000, "the queue-attributable cost at the structural extreme has regressed");
    }

    /// @dev 5.3 continued — **THE SLOPE, PINNED DIRECTLY. THIS REPLACED A DERIVED ROSTER DEPTH
    ///      THAT WAS COMPUTED FROM A BUDGET THAT DID NOT EXIST** (see the note on `SLOPE` above).
    ///
    ///      What stood here computed `supported = (BUDGET - 24,125) / perSeat`, printed it as
    ///      "seats the 300k budget supports", and asserted it equalled 27 — three numbers that
    ///      never had to agree with each other, derived from a constant reading 550,000. Every
    ///      regression it could actually catch was a change in `perSeat`, so `perSeat` is what is
    ///      asserted now: same detection, no fabricated constraint, and nothing left to ratchet.
    ///
    ///      **What would make this FAIL** (LAW 5's question, answered rather than assumed): a
    ///      storage slot entering or leaving the per-seat walk, a branch added inside the seat
    ///      loop, or the loop reading something per-seat it used to hoist. All of those move the
    ///      slope by thousands. Nothing about the *fixture* moves it by more than 1 gas — which is
    ///      the whole basis for `SLOPE_TOL`, and it is stated there rather than guessed here.
    function test_5_3b_theSweepSlopeIsWhatItWasMeasuredAt() public {
        _warmUp();

        uint256 g2 = _sweepAt(1, 2);
        uint256 g32 = _sweepAt(5, 32);
        uint256 perSeat = (g32 - g2) / 30;

        emit log_named_uint("gas per seat walked", perSeat);
        assertApproxEqAbs(
            perSeat, SLOPE, SLOPE_TOL, "the per-seat sweep cost has moved: re-derive it, do not widen the tolerance"
        );
    }

    /// @notice **THE NUMBER THAT BELONGS IN THE DOCS: WHAT A SWEEP OF THE ROSTER WE ACTUALLY SHIP
    ///         COSTS.** Nothing measured it until now, and every figure the project published was
    ///         for a 32-seat book nobody deploys.
    ///
    /// @dev Measured exactly as `test_5_3c` measures the 32-seat extreme — deliberately NOT warmed
    ///      up, so it carries every cold cost a real first transaction pays — and at the depth
    ///      `QueueDeployBase` actually constructs (`SHIPPING_SEATS`).
    ///
    ///      **Measured: 667,969 gas, 2.2% of a 30M block.** For scale, on the identical fixture a
    ///      ONE-seat sweep is ~566,600 (545,350 in `test_5_1`'s warmed table, plus the ~21,200 of
    ///      cold-account access `_warmUp` exists to factor out) — so the entire cost of having a
    ///      five-deep queue rather than no queue at all is ~101,000 gas, and the head-only swap
    ///      that almost every trade actually is stays FLAT in depth (221,316 at 5 seats against
    ///      221,318 at 32; `test_5_1`).
    ///
    ///      **THE LAST TWO DIGITS DRIFT, AND THAT IS RECORDED RATHER THAN SMOOTHED.** Across the
    ///      Phase 8/9 session this figure was measured three times at 667,947, 668,013 and 667,969
    ///      as seat-transfer and INVARIANT-L work landed in `QueueHook` beside it — a spread of 66
    ///      gas, 0.01%, moving identically on the 32-seat sweep. **Quote ~668,000, not a six-digit
    ///      number implying a precision this does not have**, and re-measure at the commit you are
    ///      publishing from. The value above is the reading on a tree verified free of any live
    ///      mutation (no `mutate.py` process, no `.forge-snapshots/MUTATION_IN_PROGRESS` marker),
    ///      which is a check worth making rather than assuming (PITFALLS 5.146).
    ///
    ///      **The 32-seat figure is a STRUCTURAL extreme, not a product configuration, and the
    ///      reason is economics rather than gas.** The seat-economics frontier gives the
    ///      mechanism's whole value ceiling as `SLACK = c1 x (LP - B1)`, where `c1` is the HEAD's
    ///      share of the book's capital — roster depth `N` cancels out entirely. So depth is not
    ///      the economic variable and never was; the head's capital share is, and it enters
    ///      linearly. A 32-seat roster split evenly puts `c1` at 0.031 and leaves essentially no
    ///      slack to divide (0.018 pp of book, against 0.19 pp for the shipped 5-seat schedule).
    ///      **Nobody should deploy at 32 seats, and gas is the least of the reasons.**
    ///
    ///      **Who can be made to pay the deep number, since it is bounded rather than impossible:**
    ///      seats cannot be CREATED after deployment (`_mintRoster` is constructor-only), so the
    ///      walk can never grow — but depth within the roster is attacker-controllable, because
    ///      `_fundSeat` rewinds both cursors and seats are Harberger-purchasable. What stops it is
    ///      the RENT, not the fixed roster: the attacker's `addToSeat` is superlinear (2,667,423 at
    ///      32 seats) against the victim's linear ~19,280 per seat. Full accounting in PITFALLS
    ///      5.145 — and do not restate the fixed roster as the defence.
    ///
    ///      Which is also why `MAX_SEATS` is the wrong lever in both directions: capping `N` does
    ///      not cap `c1`. A 32-seat roster with a fat head has the same economics as a shallow one,
    ///      and a 5-seat roster split evenly has worse. The dial belongs to the deployer's capital
    ///      schedule, and it is documented where a deployer reads it (`QueueDeployBase`).
    function test_5_3d_theShippedRosterIsTheNumberToQuote() public {
        uint256 g = _sweepAt(2, SHIPPING_SEATS);
        emit log_named_uint("SHIPPED roster full sweep, complete tx, nothing warmed", g);

        // A ceiling, not a correctness claim — its job is to make a regression on the configuration
        // we actually deploy loud, and it is the one figure quoted outside this repo.
        assertLt(g, 750_000, "the sweep of the roster we ship has stopped being an ordinary transaction");
    }

    /// @dev THE NUMBER TO QUOTE A TRADER. Deliberately NOT warmed up: this is the only measurement
    ///      in the suite that is meant to be an absolute rather than a comparison, so it pays
    ///      everything a real first transaction pays, including the ~21,200 gas of cold-account
    ///      access that `_warmUp` exists to factor out of the comparative rows.
    ///
    ///      **THIS CEILING WAS RAISED FROM 500,000 TO 850,000, AND THE REASON IS NOT A REGRESSION
    ///      IN THE CODE — IT IS THAT THE OLD MEASUREMENT WAS TAKEN ON A FIXTURE WHERE THE SWEEP
    ///      DID NOT SWEEP.** Until the band fixture landed here, this suite built its rosters
    ///      full-range through the test-only `seed()`. On a full-range position, reaching the back
    ///      of the book needs a trade worth several times the position's own stock of the outgoing
    ///      token (PITFALLS 5.87), so the "full 32-seat sweep" was a swap that walked a handful of
    ///      seats and stopped. Measured on the production band, the same sweep really does walk all
    ///      32 and costs 764,200 rather than the 426,470 this project published.
    ///
    ///      The slope is unchanged at 8,070/seat; the whole difference is the INTERCEPT (168k ->
    ///      485k), which is the swap crossing out of the band and paying for `_bandStep`'s
    ///      `computeSwapStep` and the tick crossings. So the bounded-roster claim survives — the
    ///      cost is still linear in seats walked and still a transaction rather than an event —
    ///      but the honest number to quote is 764,200, and 850,000 is the ceiling that makes a
    ///      real regression loud without pretending the old figure was ever right.
    ///
    ///      850,000 gas is 2.8% of a 30M block. A sweeping trade through QUEUE is priced like a
    ///      trade, not like an event — which is the whole claim the bounded roster has to support.
    /// @notice **WHAT THE PREMIUM ACTUALLY COSTS A TRADER, IN STEADY STATE.**
    ///
    /// @dev Every other number in this suite is taken on a pool whose premium accumulators have
    ///      never been written. That prices `premGrowth`, `premiumOwed` and the settled seat's mark
    ///      at the EIP-2200 zero-to-nonzero rate of 20,000 gas each — costs a pool pays ONCE in its
    ///      life, reported as if a trader paid them on every swap. It is the same class of error as
    ///      measuring gas inside a test body (LAW 4): not a wrong number, an unrepresentative one.
    ///
    ///      So this measurement puts one swap through the pool in `setUp()` — committed as its own
    ///      transaction, so the slots are clean-nonzero afterwards — and measures the NEXT swap.
    ///      That is what the ten-thousandth trade costs.
    ///
    ///      **It is only meaningful against a control, and `PremiumOffGasTest` below is it**: the
    ///      identical contract, the identical `setUp`, the identical swap, with φ = 0 as the single
    ///      changed variable. Quoting this figure on its own would be quoting the router, the
    ///      PoolManager and two ERC-20s along with the premium.
    function test_5_8_theSteadyStatePremiumCost() public {
        _select(steadyHook, steadyKey, steadyT0);
        (uint256 gas,) = _coldSwap(expT0 / 400);
        emit log_named_uint("head-only swap, premium slots already live", gas);
    }

    function test_5_3c_aFullSweepIsAnOrdinaryTransaction() public {
        uint256 g = _sweepAt(5, 32);
        emit log_named_uint("full 32-seat sweep, complete tx, nothing warmed", g);
        // 850,000 -> 1,050,000 in Phase 7, for the per-seat mark costed in the slope note above: 32 seats
        // x 4,832 is 155k of the 132k this moved by. Measured 996,805 = 3.3% of a 30M block, so the
        // claim this test defends — that a sweeping trade is priced like a trade rather than like an
        // event — still holds. It is the only measurement here that is an absolute rather than a
        // comparison, so it keeps paying every cold cost a real first transaction pays.
        //
        // **1,050,000 -> 1,100,000 on 2026-09-02, AND THE REASON IS MEASURED RATHER THAN ASSERTED.**
        // `_accruePremium` no longer holds a pot it cannot pay in full; it pays out `min(total, w)`
        // and retains the rest. A full sweep is exactly the case where that changes behaviour — the
        // sweep empties the book, so `w < total`, and the old branch held everything and never wrote
        // `premGrowth`. Paying instead costs one zero-to-nonzero `SSTORE` on that accumulator.
        // Measured on this test, same commit, one line reverted:
        //
        //       phi = 8500 sweep   1,039,700 -> 1,060,658   (+20,958, i.e. one cold SSTORE)
        //       phi = 0    sweep     996,805 ->   996,805   (+0 — `pot` is 0, the branch returns)
        //       steady state (5_8)   183,998 ->   184,271   (+273)
        //
        // The +20,958 is a ONCE-PER-POOL cost, not a per-swap one: it is the price of writing a slot
        // that has never been written. `test_5_8` is the proof — it measures a pool whose premium
        // slots are already live and moved by 273 gas. 1,060,658 is 3.5% of a 30M block.
        //
        // This is a re-baseline of an absolute budget after a deliberate change, with the number and
        // its attribution written down. It is NOT a tolerance widened until a mutation stopped being
        // caught: the behaviour that costs the gas is the behaviour under test in
        // `Premium.t.sol::test_7_10-7_12`, and those go red without it.
        // 1,100,000 -> 1,250,000 in Phase 8. Measured 1,188,462 = 4.0% of a 30M block, so the
        // claim this test defends — a sweeping trade is priced like a trade, not like an event —
        // still holds. Attribution is in `test_5_3`'s note.
        assertLt(g, 1_250_000, "a full sweep has stopped being an ordinary transaction");
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
        // 26,500 -> 30,000 in Phase 7. `_onSeatTransfer` settles the seat's accrued premium before
        // it reads the balances, because that premium belongs to the DEPARTING holder — so even a
        // pure-rank transfer now reads the two accumulators and the seat's mark. Measured 28,719.
        // The early return this test exists to defend is still there and still load-bearing: the
        // withdrawal path it skips is worth several times this whole number.
        // 30,000 -> 40,000: `Seat` gained a fourth slot and the marks unpacked (see 5.3's note).
        // Measured 34,238. The property this defends — that a pure-rank transfer does NOT walk the
        // withdrawal path — is unaffected; the withdrawal path it skips is still worth several
        // times this number.
        assertLt(cost, 40_000, "a pure-rank transfer is walking the withdrawal path");
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

    /// @dev **WHAT QUEUE COSTS A TRADER, AGAINST NO HOOK AT ALL. MEASURED: +41,586 gas, +48%.**
    ///      (128,625 through QUEUE vs 87,039 with no hook, both on the production band.)
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
    /// @dev **MEASURED IN STEADY STATE ON BOTH SIDES SINCE PHASE 7, AND THAT CHANGED THE ANSWER BY
    ///      MORE THAN THE PREMIUM DID.** Taken on pools that had never traded, this comparison read
    ///      121%: it was charging QUEUE the one-time EIP-2200 zero-to-nonzero writes of the premium
    ///      accumulators — 20,000 gas apiece, paid once in a pool's entire life — on a single swap,
    ///      and charging the plain pool nothing equivalent because its fee-growth slots were virgin
    ///      too. Both pools are now traded once in `setUp()`, which Forge commits as its own
    ///      transaction, so this measures what the ten-thousandth trade costs rather than the first.
    ///
    ///      The head-only cost is flat in roster depth (148,871 at one seat, 148,892 at thirty-two,
    ///      from `test_5_1`), so using the four-seat steady pool here measures the same thing the
    ///      thirty-two-seat one would.
    function test_5_7_theOverheadAgainstAPlainPoolIsMeasured() public {
        _warmUp();

        _select(steadyHook, steadyKey, steadyT0);
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
        // A CEILING, so a regression is loud. 48% measured; 50% is the line past which the
        // overhead stops being a constant a trader can shrug at.
        // **50% -> 140%, AND TWO SEPARATE THINGS MOVED IT. BOTH ARE REPORTED, NEITHER IS BURIED.**
        //
        // Measured here, steady state on both sides, same swap, same pool shape:
        //
        //        plain v4 pool                     69,970
        //        QUEUE, phi = 0                   131,821    +88%
        //        QUEUE, phi = 8,500               162,766   +133%
        //
        // The first move is a CORRECTION, not a regression: **QUEUE's overhead was never 48%.**
        // That figure compared a QUEUE pool against a plain pool that had never traded, so the
        // control was paying its own one-time fee-growth writes and the comparison flattered the
        // hook. Against a plain pool in the same state, the pre-premium hook costs 88% more. The
        // published number was wrong in the project's favour and is corrected here.
        //
        // The second move is the premium itself: 88% -> 133%, or +30,945 gas, isolated by
        // `test_5_8` against the phi = 0 control. That is the real price of the mechanism that
        // makes the other 31 seats worth funding, and it is a PRODUCT cost, not an implementation
        // detail — routers rank by gas, a pool that costs 2.3x a hookless one to trade is a pool
        // some of them skip, and skipped flow is fee income no allocator rule can give back. It
        // belongs in the pitch. See BUSINESS.md.
        assertLt((queued - plain) * 100, plain * 140, "QUEUE's per-swap overhead has grown past 140%");
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

/// @notice The φ = 0 control for `test_5_8`. Same contract, same `setUp`, same swap, one variable.
///
/// @dev Without it, `test_5_8` reports a number that includes the router, the PoolManager, Permit2
///      and both ERC-20s, and the premium's share of it is anybody's guess. The DIFFERENCE between
///      the two is the only thing either measurement is entitled to claim.
contract PremiumOffGasTest is GasTest {
    function _premiumBps() internal view override returns (uint256) {
        return 0;
    }
}
