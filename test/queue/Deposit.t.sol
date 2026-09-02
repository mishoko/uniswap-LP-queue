// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueSeats} from "../../src/queue/QueueSeats.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Phase 2 — deposit, withdraw, the shared float, and the reinjection sweep.
///
/// THE HOOK IS NEVER PRE-FUNDED IN THIS FILE. Every token it holds arrived through `deposit`. If
/// the hook held a surplus, a float-accounting bug would quietly pay out of it and no assertion
/// here could see the difference.
contract DepositTest is QueueFixture {
    using StateLibrary for IPoolManager;
    /// @dev THE §E.4 RESIDUAL, MEASURED ON THIS FIXTURE (see `test_2_13_residualIsLinearNotCompounding`):
    ///      ~6.8 wei per swap per token, growing LINEARLY and converging. It exists because v4
    ///      computes a swap's amounts and a position's redeemable value with two differently-rounded
    ///      formulas, both in the pool's favour. It cannot be removed — v4 does not agree with
    ///      itself — so dust policy F1 makes face value an UPPER BOUND and spreads the gap over
    ///      whoever withdraws instead of dumping it on the last one.
    ///
    ///      MEASURED on the on-ratio fixture: ~0.15 wei per swap per token (17 wei after 120
    ///      swaps). An earlier figure of ~6.8 wei/swap was measured on a fixture whose deposits
    ///      were wildly off the pool's RAW ratio, so almost everything sat in float and churned.
    ///
    ///      This constant carries a large margin over the measurement. It is a BOUND DERIVED FROM
    ///      EVIDENCE, not a tolerance widened until the tests went green.
    uint256 constant RESIDUAL_PER_SWAP = 4;
    uint256 constant RESIDUAL_BASE = 64;

    function _bound(uint256 nSwaps) internal pure returns (uint256) {
        return RESIDUAL_PER_SWAP * nSwaps + RESIDUAL_BASE;
    }

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CARL = address(0xCAF1);

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        startPrice = Constants.SQRT_PRICE_1_4;
        dec0 = 18;
        dec1 = 6; // LAW 1: non-unit price AND asymmetric decimals
        _deployTokens();
        _deployHookUnfunded(0x4001, _roster(ALICE, BOB, CARL));
        _initPool();
    }

    /// @dev The founding roster is (ALICE, BOB, CARL) at ranks 0, 1, 2 — fixed at deployment, not
    ///      earned by depositing first. Funding a seat no longer creates one.
    function _three() internal returns (uint256 a, uint256 b, uint256 c) {
        (a, b, c) = (0, 1, 2);
        _addTo(ALICE, a, 40e18, 10e18);
        _addTo(BOB, b, 60e18, 15e18);
        _addTo(CARL, c, 900e18, 225e18);
    }

    /// @dev Token amounts that mint `L` of liquidity into the hook's current band at the current
    ///      price. Off-ratio deposits on a concentrated band dump almost everything into float,
    ///      which makes tests that need a position pull (2.18) or a sweep (2.9) vacuously pass or
    ///      fail for the wrong reason.
    function _amountsFor(uint128 L) internal view returns (uint256 a0, uint256 a1) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        (,, int24 lower, int24 upper) = hook.pool();
        a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(upper), L, true);
        a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(lower), sqrtP, L, true);
    }

    // ================================================== deposit credits ACTUAL, absorbs the rest

    /// @dev OWNER DECISION 2026-08-27: the unconsumed remainder is ABSORBED into the float and
    ///      credited to the seat, NOT refunded to `msg.sender` as PLAN §B.7 originally said.
    ///      So the assertion is not "the refund arrived" but "the hook kept the remainder, the seat
    ///      was credited for it, and INVARIANT F still balances".
    function test_2_1_depositCreditsActualAndAbsorbsTheRemainder() public {
        uint256 id = 0;
        _fund(ALICE, 40e18, 10e18);
        vm.prank(ALICE);
        hook.addToSeat(id, 40e18, 10e18);
        ref0[id] += 40e18;
        ref1[id] += 10e6;
        expT0 += 40e18;
        expT1 += 10e6;

        // Nothing is handed back.
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(ALICE), 0, "token0 was refunded");
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(ALICE), 0, "token1 was refunded");

        // The seat is credited the FULL deposit: position share + float share.
        (uint256 a0, uint256 a1) = hook.seat(id);
        assertEq(a0, 40e18, "seat not credited the full token0");
        assertEq(a1, 10e18, "seat not credited the full token1");

        // At least one leg must have left a remainder, or this test proves nothing about absorption.
        (uint256 f0, uint256 f1) = hook.floats();
        assertTrue(f0 != 0 || f1 != 0, "no remainder was produced: the fixture cannot see absorption");

        // Everything the hook holds outside the position IS the float — no stray tokens.
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(hook)), f0, "float0 not backed by real token0");
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(hook)), f1, "float1 not backed by real token1");

        _checkInvariantF("deposit", 2);
    }

    // ======================================================================= withdrawal orderings

    /// @dev All six orderings of three seats. NO ordering may leave anyone short. This is the
    ///      property a shared float has to earn: seats are paid first-come-first-served out of one
    ///      pot, so if the aggregate identity were wrong, SOME permutation would strand a seat.
    function test_2_2_allWithdrawalOrderings() public {
        uint8[3][6] memory orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        for (uint256 perm; perm < 6; perm++) {
            _runOrdering(orders[perm], uint160(0x5000 + perm));
        }
    }

    /// @dev A fresh hook and pool per permutation. (Re-running `setUp()` inside the loop redeploys
    ///      every v4 artifact six times and exceeds the block gas limit.)
    function _runOrdering(uint8[3] memory order, uint160 nonce) internal {
        _deployHookUnfunded(nonce, _roster(ALICE, BOB, CARL));
        _initPool();
        (uint256 i0, uint256 i1, uint256 i2) = _three();
        uint256[3] memory ids = [i0, i1, i2];
        address[3] memory who = [ALICE, BOB, CARL];

        // Trade first, so seats hold genuinely lopsided compositions rather than what they put in.
        _swap(true, 30e18);
        _swap(false, 4e18);
        _swap(true, 12e18);

        for (uint256 j; j < 3; j++) {
            uint256 id = ids[order[j]];
            address owner_ = who[order[j]];
            (uint256 a0, uint256 a1) = hook.seat(id);

            vm.prank(owner_);
            (uint256 p0, uint256 p1) = hook.withdraw(id, a0, a1);

            // F1 pays min(face, available): the shortfall must be DUST, never a real gap, and it
            // must hold for EVERY ordering — that is the property a shared float has to earn.
            assertApproxEqAbs(p0, a0, _bound(3), "seat left short of token0");
            assertApproxEqAbs(p1, a1, _bound(3), "seat left short of token1");
        }
    }

    /// @dev The one that matters: the LAST withdrawer is the seat that eats any accounting error.
    function test_2_3_lastWithdrawerIsNotShort() public {
        (uint256 i0, uint256 i1, uint256 i2) = _three();
        for (uint256 s; s < 40; s++) {
            _swap(s % 3 == 2, s % 3 == 2 ? 1e18 : 5e18);
        }

        uint256[3] memory ids = [i0, i1, i2];
        address[3] memory who = [ALICE, BOB, CARL];
        for (uint256 j; j < 3; j++) {
            (uint256 a0, uint256 a1) = hook.seat(ids[j]);
            vm.prank(who[j]);
            (uint256 p0, uint256 p1) = hook.withdraw(ids[j], a0, a1);
            if (j == 2) {
                assertApproxEqAbs(p0, a0, _bound(40), "THE LAST WITHDRAWER WAS SHORT of token0");
                assertApproxEqAbs(p1, a1, _bound(40), "THE LAST WITHDRAWER WAS SHORT of token1");
            }
        }
    }

    /// @dev Solvency: the queue can never pay out more than the position was actually worth.
    function test_2_4_solvencyAcrossManySwaps() public {
        (uint256 i0, uint256 i1, uint256 i2) = _three();
        (uint256 seeded0, uint256 seeded1) = (expT0, expT1);

        for (uint256 s; s < 60; s++) {
            _swap(s % 4 != 3, s % 4 == 3 ? 1e18 : 4e18);
        }

        uint256 paid0;
        uint256 paid1;
        uint256[3] memory ids = [i0, i1, i2];
        address[3] memory who = [ALICE, BOB, CARL];
        for (uint256 j; j < 3; j++) {
            (uint256 a0, uint256 a1) = hook.seat(ids[j]);
            vm.prank(who[j]);
            (uint256 p0, uint256 p1) = hook.withdraw(ids[j], a0, a1);
            paid0 += p0;
            paid1 += p1;
        }

        // Everyone is out; the hook must not be sitting on meaningful unowed value.
        (uint256 t0, uint256 t1) = hook.totals();
        assertLe(t0, _bound(60), "ledger token0 dust left unpaid exceeds the measured residual bound");
        assertLe(t1, _bound(60), "ledger token1 dust left unpaid exceeds the measured residual bound");
        assertGt(paid0 + paid1, 0, "nothing was paid out");
        assertLe(paid0, seeded0 + 1e24, "paid out more token0 than plausibly existed");
        assertLe(paid1, seeded1 + 1e12, "paid out more token1 than plausibly existed");
    }

    // ================================================================================ seat rules

    function test_2_5_withdrawToZeroKeepsTheSeat() public {
        (uint256 id,,) = _three();
        (uint256 a0, uint256 a1) = hook.seat(id);
        vm.prank(ALICE);
        hook.withdraw(id, a0, a1);

        assertEq(hook.seatCount(), 3, "the seat was destroyed");
        assertEq(hook.ownerOf(id), ALICE, "the seat lost its owner");
        // An empty seat is PURE RANK with no capital attached. Being able to hold, price and sell
        // one is what gives rank a price of its own — this is a deliberate design decision.
        (uint256 z0, uint256 z1) = hook.seat(id);
        assertLe(z0, _bound(0), "seat retained token0");
        assertLe(z1, _bound(0), "seat retained token1");
    }

    function test_2_6_cannotWithdrawFromAnotherSeat() public {
        (uint256 id,,) = _three();
        (uint256 a0, uint256 a1) = hook.seat(id);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, id, BOB));
        hook.withdraw(id, a0, a1);
    }

    function test_2_7_cannotWithdrawMoreThanTheSeatHolds() public {
        (uint256 id,,) = _three();
        (uint256 a0, uint256 a1) = hook.seat(id);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.OverEntitlement.selector, a0 + 1, a0));
        hook.withdraw(id, a0 + 1, a1);
    }

    /// @dev Topping up a seat that a cursor has already passed would make that cursor LEAD.
    function test_2_8_topUpBelowACursorPullsItBack() public {
        (uint256 i0,,) = _three();
        _swap(true, 200e18); // exhaust the head's token1 and advance cursor1
        (, uint256 c1Before) = hook.cursors();
        assertGt(c1Before, 0, "fixture drifted: cursor1 never advanced");

        _fund(ALICE, 0, 5e18);
        vm.prank(ALICE);
        hook.addToSeat(i0, 0, 5e18);

        (, uint256 c1After) = hook.cursors();
        assertEq(c1After, 0, "cursor1 was not pulled back and now LEADS a re-funded seat");
        _checkInvariantC("top-up");
    }

    /// @dev THE MIRROR of `test_2_8`, and it exists because mutation testing showed the cursor0
    ///      branch of the top-up pull-back was covered by NOTHING while the cursor1 branch was
    ///      covered. That is PITFALLS 5.37 recurring in a second function: whenever a rule appears
    ///      once per direction, BOTH copies need a test.
    function test_2_8b_topUpBelowCursor0PullsItBack() public {
        (uint256 i0,,) = _three();
        // Reverse flow drains the head's token0 and advances cursor0.
        for (uint256 i; i < 8; i++) {
            (uint256 c0Now,) = hook.cursors();
            if (c0Now > 0) break;
            _swap(false, 30e18);
        }
        (uint256 c0Before,) = hook.cursors();
        assertGt(c0Before, 0, "fixture drifted: cursor0 never advanced");

        _fund(ALICE, 5e18, 0);
        vm.prank(ALICE);
        hook.addToSeat(i0, 5e18, 0);

        (uint256 c0After,) = hook.cursors();
        assertEq(c0After, 0, "cursor0 was not pulled back and now LEADS a re-funded seat");
        _checkInvariantC("top-up token0");
    }

    /// @dev The `+1` in `_liquidityToCover` is a real correctness line, not defensive padding.
    ///      Both the sizing and v4's release round DOWN, so without it a withdrawal that has to
    ///      pull from the position comes back a wei or two short and F1 quietly pays less than
    ///      face. Mutation testing showed nothing detected its removal, because every other
    ///      assertion here carries a dust tolerance that swallowed it.
    ///
    ///      This asserts EXACT payment: with a healthy position and no prior float, a withdrawal
    ///      must pay its full face value to the wei.
    function test_2_18_withdrawalFromThePositionPaysExactFaceValue() public {
        // On-ratio for the 1:4 / 18/6 pool, so almost everything lands in the position and a
        // withdraw has to pull from it. `_three()` is off-ratio on a concentrated band and leaves
        // too much in the float for this assertion to mean anything.
        uint256 i0 = 0;
        (uint256 a0in, uint256 a1in) = _amountsFor(1e15);
        _addTo(ALICE, i0, a0in, a1in);
        (uint256 f0, uint256 f1) = hook.floats();
        assertLt(f0, 1e12, "fixture drifted: float0 is not small enough to force a position pull");
        assertLt(f1, 1e12, "fixture drifted: float1 is not small enough to force a position pull");

        // Ask for far more than the float holds, so the position must be tapped.
        (uint256 a0, uint256 a1) = hook.seat(i0);
        uint256 w0 = a0 / 2;
        uint256 w1 = a1 / 2;
        assertGt(w0, f0, "the float already covers the request: no position pull happens");

        vm.prank(ALICE);
        (uint256 p0, uint256 p1) = hook.withdraw(i0, w0, w1);

        assertEq(p0, w0, "withdrawal paid less token0 than face: the sizing truncated");
        assertEq(p1, w1, "withdrawal paid less token1 than face: the sizing truncated");
    }

    // =========================================================== sweepFloatIntoPosition (STEP 2b)

    /// @dev Without the sweep, POOL DEPTH DEGRADES MONOTONICALLY: every withdrawal of an imbalanced
    ///      leg leaves the other token stranded outside the position. This asserts the sweep both
    ///      shrinks the float and actually puts liquidity back.
    function test_2_9_sweepReinjectsFloatAndRestoresDepth() public {
        uint256 i0 = 0;
        (uint256 a0in, uint256 a1in) = _amountsFor(1e15);
        _addTo(ALICE, i0, a0in, a1in);
        _swap(true, a0in / 20);
        _swap(false, a1in / 20);

        // Withdraw one lopsided leg to manufacture a float.
        (uint256 a0,) = hook.seat(i0);
        vm.prank(ALICE);
        hook.withdraw(i0, a0 / 2, 0);

        (uint256 f0Before, uint256 f1Before) = hook.floats();
        assertTrue(f0Before > 0 || f1Before > 0, "no float was created: the mechanism did not engage");
        uint128 liqBefore = hook.positionLiquidity();

        uint128 added = hook.sweepFloatIntoPosition();

        assertGt(added, 0, "the sweep added no liquidity");
        assertEq(hook.positionLiquidity(), liqBefore + added, "position liquidity did not grow");
        (uint256 f0After, uint256 f1After) = hook.floats();
        assertTrue(f0After < f0Before || f1After < f1Before, "the sweep consumed no float");
        _checkInvariantF("after sweep", 8);
    }

    /// @dev The sweep credits NOBODY. It moves value from `floatX` into the position, both of which
    ///      are already owed to the same seats through INVARIANT F. If it moved any seat's ledger
    ///      it would be redistributing between seats, which is exactly what it must never do.
    function test_2_10_sweepCreditsNobody() public {
        (uint256 i0,,) = _three();
        _swap(true, 120e18);
        (uint256 a0,) = hook.seat(i0);
        vm.prank(ALICE);
        hook.withdraw(i0, a0 / 2, 0);

        uint256 n = hook.seatCount();
        uint256[] memory b0 = new uint256[](n);
        uint256[] memory b1 = new uint256[](n);
        for (uint256 i; i < n; i++) {
            (b0[i], b1[i]) = hook.seat(i);
        }

        hook.sweepFloatIntoPosition();

        for (uint256 i; i < n; i++) {
            (uint256 x0, uint256 x1) = hook.seat(i);
            assertEq(x0, b0[i], "the sweep moved a seat's token0 ledger");
            assertEq(x1, b1[i], "the sweep moved a seat's token1 ledger");
        }
    }

    /// @dev Permissionless by design — there is nothing to direct anywhere, so there is nothing to
    ///      gate. A stranger calling it must succeed and must gain nothing.
    function test_2_11_sweepIsPermissionlessAndPaysTheCallerNothing() public {
        (uint256 i0,,) = _three();
        _swap(true, 120e18);
        (uint256 a0,) = hook.seat(i0);
        vm.prank(ALICE);
        hook.withdraw(i0, a0 / 2, 0);

        address stranger = address(0xDEAD);
        vm.prank(stranger);
        hook.sweepFloatIntoPosition();

        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(stranger), 0, "the sweep paid the caller token0");
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(stranger), 0, "the sweep paid the caller token1");
    }

    // ============================================================================ INVARIANT C fuzz

    function testFuzz_2_12_cursorsStayValidUnderInterleaving(uint8[12] memory ops, uint16[12] memory sizes) public {
        _three();
        for (uint256 i; i < 12; i++) {
            uint256 op = ops[i] % 3;
            uint256 size = uint256(sizes[i]) + 1;
            if (op == 0) {
                (bool ok,) = address(this).call(abi.encodeCall(this.doSwap, (true, size * 1e14)));
                ok;
            } else if (op == 1) {
                (bool ok,) = address(this).call(abi.encodeCall(this.doSwap, (false, size * 1e13)));
                ok;
            } else {
                uint256 id = i % 3;
                address owner_ = id == 0 ? ALICE : (id == 1 ? BOB : CARL);
                (uint256 x0, uint256 x1) = hook.seat(id);
                uint256 h0 = MockERC20(Currency.unwrap(c0)).balanceOf(owner_);
                uint256 h1 = MockERC20(Currency.unwrap(c1)).balanceOf(owner_);
                vm.prank(owner_);
                (bool ok,) =
                    address(hook).call(abi.encodeCall(hook.withdraw, (id, x0 / (size % 7 + 1), x1 / (size % 5 + 1))));
                // ANY withdrawal that PAYS demotes the seat to the tail, so the witness's own order
                // has to follow — otherwise `_checkOrder` fails on every such withdrawal and tells
                // us nothing about cursors, which is what this fuzz is for.
                //
                // **THE TRIGGER IS WHAT THE HOLDER RECEIVED, MEASURED ON THEIR OWN ERC20 BALANCE.**
                // It used to be `seatLiquidity(id) != lBefore`, mirroring the old rule that only a
                // withdrawal burning into contributed depth cost a rank. That rule is gone: a payout
                // the FLOAT covers burns nothing, so it reported "no demotion" while the entire
                // balance walked out of the seat (`test_8_15`). Reading the holder's balance is also
                // the only faithful witness available here — the seat's own `a0`/`a1` move for a
                // second reason during `withdraw` (the premium is settled into them first), so a
                // seat-side delta would not be `p0`/`p1`.
                if (ok) {
                    uint256 got0 = MockERC20(Currency.unwrap(c0)).balanceOf(owner_) - h0;
                    uint256 got1 = MockERC20(Currency.unwrap(c1)).balanceOf(owner_) - h1;
                    if (got0 != 0 || got1 != 0) _refDemote(id);
                }
            }
            _checkInvariantC("fuzz");
        }
    }

    /// @dev Deposit must never charge more than the depositor supplied. If it did, the excess would
    ///      come out of float owed to OTHER seats — a silent cross-seat theft.
    ///
    ///      `_liquidityForAmounts` shaves one unit off the computed liquidity because the sizing
    ///      rounds DOWN while `modifyLiquidity`'s charge for ADDING rounds UP, so the round trip can
    ///      ask for one wei more than went in. This fuzz is what makes that line provable rather
    ///      than decorative — it was previously untested.
    function testFuzz_2_19_depositNeverChargesMoreThanSupplied(uint96 raw0, uint96 raw1) public {
        _addTo(ALICE, 0, 1000e18, 250e18); // establish the pool on-ratio

        uint256 a0 = bound(uint256(raw0), 1, 1e24);
        uint256 a1 = bound(uint256(raw1), 1, 1e24);

        uint256 f0Before = _hookBal(c0);
        uint256 f1Before = _hookBal(c1);
        (uint256 fl0Before, uint256 fl1Before) = hook.floats();

        _fund(BOB, a0, a1);
        vm.prank(BOB);
        hook.addToSeat(1, a0, a1);

        // Every token the hook holds outside the position is float, and float only ever grows by
        // what was NOT consumed. If the charge exceeded the supply, one of these goes negative.
        (uint256 fl0After, uint256 fl1After) = hook.floats();
        assertLe(fl0After - fl0Before, a0, "deposit credited more token0 float than was supplied");
        assertLe(fl1After - fl1Before, a1, "deposit credited more token1 float than was supplied");
        assertEq(_hookBal(c0), fl0After, "hook token0 balance diverged from float0");
        assertEq(_hookBal(c1), fl1After, "hook token1 balance diverged from float1");
        f0Before;
        f1Before;
    }

    /// @dev A front-runner must not be able to bind a freshly deployed hook to a pool of their
    ///      choosing. Without the constructor commitment this is a FREE, UNRECOVERABLE DoS: the
    ///      binding is permanent and there is no admin to undo it.
    function test_2_20_cannotBindTheHookToAForeignPool() public {
        address a = address(FLAGS ^ (uint160(0x4099) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(_roster(ALICE, BOB, CARL)), a);
        QueueHarness fresh = QueueHarness(a);

        // An attacker tries to bind it to the same pair on a different fee tier.
        PoolKey memory hostile =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: SPACING, hooks: IHooks(address(fresh))});
        vm.prank(address(0xBAD));
        // LAW 2 — THE REASON, NOT MERELY "IT REVERTED". This assertion used to be a bare
        // `vm.expectRevert()`, which passes for an out-of-gas, for a hook that is not there, and
        // for `AlreadyBound` — i.e. for every reason except the one it claims to prove. v4 bubbles
        // a hook's own error inside `WrappedError(target, selector, reason, details)`, so the
        // reason has to be unwrapped to be asserted. Corrected in Phase 7.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(QueueHook.WrongPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(hostile, startPrice);

        // The intended pool still binds.
        PoolKey memory intended =
            PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(fresh))});
        poolManager.initialize(intended, startPrice);
    }

    /// @dev And a second pool cannot re-bind an already-bound hook.
    ///
    ///      **THIS TEST WAS PROVING THE WRONG THING UNTIL PHASE 7.** It re-initialized the
    ///      IDENTICAL key, which `PoolManager` refuses from its own state with
    ///      `PoolAlreadyInitialized` before the hook is ever called — so it passed whether or not
    ///      `_afterInitialize` had an `AlreadyBound` guard at all, and a mutation deleting that
    ///      guard would have survived it. The re-bind that the HOOK has to refuse is a DIFFERENT
    ///      pool naming the same hook, and a fresh fee tier is the cheapest one.
    function test_2_21_cannotRebindAnAlreadyBoundHook() public {
        PoolKey memory second =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(QueueHook.AlreadyBound.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(second, startPrice);
    }
}
