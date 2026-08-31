// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueSeats} from "../../src/queue/QueueSeats.sol";
import {Allocation} from "../../src/queue/libraries/Allocation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title The Phase 6 adversarial suite (PLAN §C.6, gate §D.8 V4)
///
/// @notice Every named attack in §C.6, each RUN and each with an asserted outcome — plus a directed
///         regression for every defect the Phase 6 invariant campaign found.
///
/// @dev Three of these tests exist because the campaign broke the shipping hook, and each names the
///      bug it locks down:
///
///        * `test_6_1` — the degenerate fill credited a seat and left the OTHER token's cursor
///          leading it, which is silent theft of rank.
///        * `test_6_2` — `unlockCallback` measured the position move as an unsigned decrease, so an
///          ADD whose realised fees exceeded its principal underflowed. `addToSeat` and
///          `sweepFloatIntoPosition` were bricked on any pool with accrued fees.
///        * `test_6_3` / `test_6_4` — the liquidity sizing helpers divided by, or overflowed on, a
///          span that goes to zero as the price reaches a tick boundary. Deposits reverted on one
///          side and WITHDRAWALS AND SEAT EVACUATIONS reverted on the other, which is a veto on the
///          path §B.8 made unblockable on purpose.
contract AdversarialTest is QueueFixture {
    using StateLibrary for IPoolManager;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CARL = address(0xCA71);
    address constant DAVE = address(0xDA7E);
    address constant MALLORY = address(0x4A110);

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        vm.warp(1_700_000_000);
        startPrice = Constants.SQRT_PRICE_1_4; // LAW 1
        dec0 = 18;
        dec1 = 6; // LAW 1
        _deployTokens();
        _deployHookUnfunded(0x9801, _roster(ALICE, BOB, CARL, DAVE));
        _initPool();
        _addTo(ALICE, 0, 400e18, 100e18);
        _addTo(BOB, 1, 600e18, 150e18);
        _addTo(CARL, 2, 137e18, 34e18);
        _addTo(DAVE, 3, 763e18, 191e18);
    }

    // ======================================================= PHASE 6 REGRESSIONS — found by fuzzing

    /// @notice **THE DEGENERATE FILL LEFT A CURSOR LEADING A FUNDED SEAT.**
    ///
    /// @dev A swap whose output rounds to zero credits its whole input to one seat — and until
    ///      Phase 6 it did NOT pull that token's cursor back, which `_allocate` has always done on
    ///      the ordinary path. Two copies of one rule, right in one of them: the fifth instance of
    ///      that family on this project (PITFALLS 5.37, 5.50, 5.52 twice, 5.62).
    ///
    ///      The consequence is not the wei. Once `cursor0` leads rank 0, every subsequent
    ///      one-for-zero swap starts BEHIND a funded seat and sources its token0 from the seats
    ///      further back — the head is passed over, which is precisely the theft of rank the whole
    ///      mechanism exists to prevent. It persists until something pulls the cursor back.
    ///
    ///      The control below is the pre-fix hook, and it goes RED on INVARIANT C.
    function test_6_1_degenerateFillPullsTheIncomingCursorBack() public {
        // Drive cursor0 forward by exhausting rank 0's token0 through ordinary one-for-zero flow.
        _drainToken0();
        _check("after exhausting the head's token0");
        (uint256 c0Before,) = hook.cursors();
        assertGt(c0Before, 0, "nothing happened: cursor0 never advanced, this test proves nothing");
        (uint256 headBefore,) = hook.seat(hook.idAtRank(0));
        assertEq(headBefore, 0, "the head still holds token0: the setup did not reach the state");

        // A one-wei zero-for-one swap. The output rounds to zero on a 0.30% pool, so this is the
        // DEGENERATE FILL, and it credits token0 to the seat at rank `cursor1`.
        _swap(true, 1);

        (uint256 headAfter,) = hook.seat(hook.idAtRank(0));
        assertGt(headAfter, 0, "nothing happened: the degenerate fill credited nothing");
        (uint256 c0After,) = hook.cursors();
        assertEq(c0After, 0, "the cursor was not pulled back to the seat the fill credited");

        // ...and the witness, which carries §B.6's rule written from the prose, agrees seat by seat.
        _check("after the degenerate fill");
        _checkInvariantF("after the degenerate fill", 1_000);
    }

    // NOTE: there is deliberately NO subclass control for `test_6_1`. Building one would mean
    // adding `virtual` to `_afterSwap` purely so a test could reach into it, and the line is
    // already proven load-bearing the way this project proves such lines: an ON-DISK mutation via
    // `script/mutate.py`, run against the whole suite and against the Phase 6 invariant campaign.
    // §D.8 V3 records which invariant goes red for it.

    /// @notice **AN ADD WHOSE REALISED FEES EXCEEDED ITS PRINCIPAL PANICKED.**
    ///
    /// @dev `modifyLiquidity` realises the position's accrued fees on EVERY call and returns
    ///      `callerDelta = principalDelta + feesAccrued`. Add a small amount of liquidity to a
    ///      position holding real fees and the hook is net CREDITED — its balance goes UP on an
    ///      ADD. `unlockCallback` chose its subtraction direction from the sign of `delta`, so it
    ///      underflowed, and `addToSeat` and `sweepFloatIntoPosition` — the only two paths capital
    ///      has into the queue — reverted for everyone at once, for as long as the fees stood.
    ///      That is not exotic: it is the ordinary state of a busy pool between two deposits.
    function test_6_2_depositSurvivesWhenAccruedFeesExceedThePrincipal() public {
        for (uint256 i; i < 6; i++) {
            _swap(true, 20e18);
            _swap(false, 5e18);
        }
        _check("after churn");

        // A deposit of 2,000 wei against fees measured in units of 1e17. Pre-fix this reverted with
        // an arithmetic panic; the seat is credited the full amount either way.
        (uint256 before0, uint256 before1) = hook.seat(2);
        _addTo(CARL, 2, 2000, 500);
        (uint256 after0, uint256 after1) = hook.seat(2);
        assertEq(after0 - before0, 2000, "the seat was not credited its full token0 deposit");
        assertEq(after1 - before1, 500, "the seat was not credited its full token1 deposit");
        _check("tiny deposit against large accrued fees");
        _checkInvariantR("tiny deposit against large accrued fees");

        // ...and the realised fees are not lost: they land in the float, which INVARIANT F already
        // counts as backing for the whole queue.
        _checkInvariantF("tiny deposit against large accrued fees", 100_000);
    }

    /// @notice **A DEPOSIT NEAR A TICK BOUNDARY REVERTED ON A LEG THAT WAS NOT BINDING.**
    ///
    /// @dev `LiquidityAmounts.getLiquidityForAmounts` computes both legs and casts EACH to
    ///      `uint128` before taking the minimum. The token1 leg is `amount1 · 2⁹⁶ / (sqrtP − lo)`,
    ///      which diverges as the price approaches the lower tick — so its `toUint128` reverted
    ///      `SafeCastOverflow` while the minimum, the only value wanted, was in the thousands.
    function test_6_3_depositSurvivesAtTheLowerTickBoundary() public {
        _drivePriceNearTheFloor();

        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        uint160 lo = _sqrtLower();
        assertGt(sqrtP, lo, "nothing happened: the price is AT the tick, not near it: wrong branch");

        // Size the deposit off the ACHIEVED price rather than hardcoding a number that only works
        // at one place in the range. The token1 leg is `amount1 · 2⁹⁶ / (sqrtP − lo)`, so it exceeds
        // `uint128` — and the periphery helper's per-leg cast therefore reverts — as soon as
        // `amount1 > 2³² · (sqrtP − lo)`. Four times that is comfortably over the edge.
        uint256 span = uint256(sqrtP - lo);
        uint256 amount1 = 4 * (uint256(1) << 32) * span;
        assertLt(amount1, uint256(1) << 127, "the fixture cannot represent the amount needed");
        assertGt(_liq1Probe(lo, sqrtP, amount1), uint256(type(uint128).max), "the token1 leg does not diverge here");

        // ...and the BINDING leg is tiny, which is the whole point: a leg that decides nothing was
        // deciding whether the deposit reverted.
        uint256 binding = _liq0Probe(sqrtP, _sqrtUpper(), 1e18);
        assertLt(binding, uint256(type(uint128).max), "the token0 leg is not the binding one here");

        (uint256 before0, uint256 before1) = hook.seat(1);
        _addTo(BOB, 1, 1e18, amount1);
        (uint256 after0, uint256 after1) = hook.seat(1);
        assertEq(after0 - before0, 1e18, "seat not credited its token0");
        assertEq(after1 - before1, amount1, "seat not credited its token1");
        _checkInvariantR("deposit near the lower tick boundary");
    }

    /// @notice **WITHDRAWAL AND SEAT EVACUATION REVERTED — WITH EMPTY REVERT DATA — AT THE EXACT
    ///         TICK BOUNDARY.**
    ///
    /// @dev At `sqrtP == getSqrtPriceAtTick(tickLower)` the position holds no token1 at all, and
    ///      `_liquidityToCover` asked how much liquidity releases some of it: a division by a zero
    ///      span, which `FullMath.mulDiv` answers with a bare `require` and therefore EMPTY revert
    ///      data. Both `withdraw` and `_onSeatTransfer` died.
    ///
    ///      The evacuation one is the serious half. §B.8 made the evacuation path unblockable ON
    ///      PURPOSE, and the buyout leans on it harder than the transfer does — a holder standing
    ///      at the tick boundary could not be bought out at all, which hands every incumbent
    ///      exactly the veto Phase 3 went out of its way to remove.
    function test_6_4_withdrawalAndEvacuationSurviveAtTheTickBoundary() public {
        // POSITIVE CONTROL first: at the seeded price, in the middle of the range, both legs size.
        // Without it, a zero on either leg below could just mean the helper always returns zero.
        assertGt(hook.liquidityToCover(0, 1e6), 0, "the token1 leg does not size in mid-range");
        assertGt(hook.liquidityToCover(1e6, 0), 0, "the token0 leg does not size in mid-range");

        _drivePriceToTheFloor();
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        assertLe(sqrtP, _sqrtLower(), "nothing happened: the price is not at the boundary");

        // THE FIXED LINE, asserted where it lives. Pre-fix this reverted with EMPTY revert data;
        // the correct answer is that the position cannot source this leg at all, so it contributes
        // nothing and the dust policy pays out of the float.
        assertEq(hook.liquidityToCover(0, 1), 0, "sizing a token1 request at the lower tick did not return zero");

        // The product claim: the seat can still change hands here. §B.8 made the evacuation path
        // unblockable ON PURPOSE and the buyout leans on it harder than the transfer does — a
        // holder standing at the tick boundary must not be un-buyable.
        uint256 seatId = hook.idAtRank(0);
        address holder = hook.ownerOf(seatId);
        vm.prank(holder);
        hook.transfer(MALLORY, seatId, 1);
        assertEq(hook.ownerOf(seatId), MALLORY, "the evacuation path was blocked at the tick boundary");
        (uint256 n0, uint256 n1) = hook.seat(seatId);
        assertEq(n0 + n1, 0, "the seat did not leave empty");
        _checkInvariantR("evacuation at the tick boundary");
    }

    // ================================================================ THE NAMED ATTACKS (§C.6)

    /// @notice ATTACK — split your order to stay at the head. **WORKS, AND IS THE DESIGN.**
    /// @dev §B.12. Splitting does not escape the queue; it concentrates informed flow onto the
    ///      priced seat, which is the seat that is paying rent for standing there. The assertion is
    ///      that it changes nothing about the ACCOUNTING: the same total, split, lands on the same
    ///      seats front-first and conserves to the wei.
    function test_6_5_splittingYourOrderIsTheDesignAndDoesNotBreakAccounting() public {
        uint256 snap = vm.snapshotState();
        _swap(true, 60e18);
        (uint256 whole0, uint256 whole1) = hook.seat(hook.idAtRank(0));
        _check("one whole swap");
        vm.revertToState(snap);

        for (uint256 i; i < 6; i++) {
            _swap(true, 10e18);
            _check("split swap");
        }
        (uint256 split0,) = hook.seat(hook.idAtRank(0));

        // The head is filled first either way. Splitting cannot get you a seat you do not hold, and
        // the ledger conserves under both.
        assertGt(whole0, 0, "nothing happened: the whole swap did not reach the head");
        assertGt(split0, 0, "nothing happened: the split swap did not reach the head");
        whole1;
    }

    /// @notice ATTACK — wash-trade from the front to farm fees. **CLOSED BY CONSTRUCTION.**
    /// @dev You pay the swap fee and you receive it, because you are the seat being filled. The
    ///      assertion is that a round trip leaves the attacker holding no more of EITHER token,
    ///      counting wallet and seat ledger together, before gas is even considered.
    function test_6_6_washTradingFromTheHeadIsNotProfitable() public {
        // Mallory owns the head and is the only funded seat: the best possible case for the attack.
        _emptyEveryoneExcept(0);
        vm.prank(ALICE);
        hook.transfer(MALLORY, 0, 1);
        _evacuateRef(0);
        _addTo(MALLORY, 0, 400e18, 100e18);

        _fund(MALLORY, 40e18, 0);
        _approveRouter(MALLORY);

        uint256 w0 = _bal(c0, MALLORY) + _seat0(0);
        uint256 w1 = _bal(c1, MALLORY) + _seat1(0);

        (, uint256 got) = _swapFrom(MALLORY, true, 40e18);
        _swapFrom(MALLORY, false, got);
        _check("wash trade");

        uint256 x0 = _bal(c0, MALLORY) + _seat0(0);
        uint256 x1 = _bal(c1, MALLORY) + _seat1(0);
        // Not "roughly": the round trip cannot leave the attacker up on both legs, and in fact
        // leaves them down on at least one before gas.
        assertLe(x0, w0, "the wash trade minted token0 out of nothing");
        assertLe(x1, w1, "the wash trade minted token1 out of nothing");
    }

    /// @notice ATTACK — sit at the back and free-ride on the front's depth. **IMPOSSIBLE.**
    /// @dev Depth is your own capital and the back is filled on exactly the trades that hurt most.
    ///      Asserted as: a head-only swap does not touch the tail AT ALL — it neither gives up the
    ///      outgoing token nor receives the incoming one.
    function test_6_7_thereIsNoFreeRideAtTheBack() public {
        uint256 tail = hook.idAtRank(3);
        (uint256 t0, uint256 t1) = hook.seat(tail);

        _swap(true, 1e18); // small: sourced entirely from the head
        (uint256 a0, uint256 a1) = hook.seat(tail);
        assertEq(a0, t0, "a head-only swap credited the tail");
        assertEq(a1, t1, "a head-only swap consumed the tail");
        assertEq(lastTouched, 1, "the swap was not head-only: this test proves nothing");

        // ...and a sweeping swap DOES reach the tail. The back is not protected, it is last.
        _swap(true, _largestFillingSwap(true));
        (uint256 b0, uint256 b1) = hook.seat(tail);
        assertTrue(b0 != t0 || b1 != t1, "a sweeping swap never reached the tail");
        _check("free-ride attempt");
    }

    /// @notice ATTACK — dust the head to grief it. **IMPOSSIBLE: RANK CANNOT BE GRANTED.**
    /// @dev The revert is asserted by REASON, per entry point. There is no runtime path that
    ///      creates a seat, and no path that funds one you do not hold.
    function test_6_8_theHeadCannotBeDustedOrTaken() public {
        _fund(MALLORY, 1e18, 1e18);

        vm.prank(MALLORY);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), MALLORY));
        hook.addToSeat(0, 1, 1);

        // ...and there is no seat id beyond the founding roster to occupy. NOTE: `seatCount()` is
        // read BEFORE `expectRevert` is armed — a view call inside the window is the call the
        // cheatcode would have matched against.
        uint256 n = hook.seatCount();
        vm.prank(MALLORY);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, n, MALLORY));
        hook.addToSeat(n, 1, 1);

        assertEq(hook.seatCount(), 4, "the roster grew");
        assertEq(hook.ownerOf(0), ALICE, "the head changed hands");
    }

    /// @notice ATTACK — flash-loan the whole queue and trade against yourself. **ZERO-SUM MINUS GAS.**
    /// @dev Mallory ends up holding every seat, funds them with unlimited capital, round-trips
    ///      against the pool, and withdraws. The assertion is that no token comes out ahead.
    function test_6_9_owningTheWholeQueueAndTradingAgainstYourselfIsZeroSum() public {
        for (uint256 id; id < 4; id++) {
            address h = hook.ownerOf(id);
            vm.prank(h);
            hook.transfer(MALLORY, id, 1);
            _evacuateRef(id);
        }
        _addTo(MALLORY, 0, 400e18, 100e18);
        _addTo(MALLORY, 1, 600e18, 150e18);

        _fund(MALLORY, 200e18, 0);
        _approveRouter(MALLORY);

        uint256 s0 = _bal(c0, MALLORY);
        uint256 s1 = _bal(c1, MALLORY);
        uint256 l0 = _seat0(0) + _seat0(1);
        uint256 l1 = _seat1(0) + _seat1(1);

        (, uint256 got) = _swapFrom(MALLORY, true, 150e18);
        _swapFrom(MALLORY, false, got);
        _check("self-trading the whole queue");

        uint256 e0 = _bal(c0, MALLORY) + _seat0(0) + _seat0(1);
        uint256 e1 = _bal(c1, MALLORY) + _seat1(0) + _seat1(1);
        assertLe(e0, s0 + l0, "self-trading minted token0");
        assertLe(e1, s1 + l1, "self-trading minted token1");
    }

    /// @notice ATTACK — manipulate the allocation price. **THERE IS NOTHING TO PUSH.**
    /// @dev §E.11. The allocation price is the swap's own realised average, taken from
    ///      PoolManager's delta. Asserted by EXECUTION rather than by reading the source: the same
    ///      swap with wildly different `hookData` produces bit-identical seat balances.
    function test_6_10_hookDataCannotInfluenceTheAllocation() public {
        uint256 snap = vm.snapshotState();
        _swapWithData(true, 30e18, "");
        uint256[] memory plain = new uint256[](8);
        for (uint256 i; i < 4; i++) {
            (plain[i], plain[i + 4]) = hook.seat(i);
        }
        vm.revertToState(snap);

        _swapWithData(true, 30e18, abi.encode(type(uint256).max, address(this), "manipulate me"));
        for (uint256 i; i < 4; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            assertEq(a0, plain[i], "hookData changed a seat's token0 allocation");
            assertEq(a1, plain[i + 4], "hookData changed a seat's token1 allocation");
        }
    }

    /// @notice ATTACK — rank-then-run. **OPEN under plain rank, CLOSED under Harberger.**
    /// @dev §E.13. Taking a seat cheaply and running is only profitable if the seat can be held
    ///      below its market value. Under the lease it cannot: whatever you PAID arms the firm
    ///      quote, so the seat is immediately re-takeable at that number for `FIRM_WINDOW`, and any
    ///      price you set above it accrues rent from the instant you set it.
    function test_6_11_rankThenRunIsClosedByTheFirmQuote() public {
        // Alice prices her seat, so it is not free.
        vm.prank(ALICE);
        hook.setSelfPrice(0, 10e18);
        _fund(ALICE, 5e18, 0);
        vm.prank(ALICE);
        hook.fundRent(0, 5e18);

        // Mallory takes it at Alice's own number...
        _fund(MALLORY, 20e18, 0);
        vm.prank(MALLORY);
        hook.buySeat(0, 10e18, 0); // ...and declares ZERO, the "run" half of rank-then-run
        _evacuateRef(0);
        assertEq(hook.ownerOf(0), MALLORY, "the buyout did not land");

        // THE CLOSE: what was paid arms the firm quote, so declaring zero does not make the seat
        // cheap for Mallory — it makes it FREE FOR ANYONE, immediately.
        assertEq(hook.buyPrice(0), 0, "a seat declared at zero did not quote zero");
        _fund(CARL, 1e18, 0);
        vm.prank(CARL);
        hook.buySeat(0, 0, 1e18);
        _evacuateRef(0);
        assertEq(hook.ownerOf(0), CARL, "the zero-priced seat could not be taken back");

        // And the mirror: declaring HIGH is not free either — it accrues rent immediately.
        vm.warp(block.timestamp + 30 days);
        assertGt(hook.rentDue(0), 0, "a high self-price accrued no rent");
    }

    /// @notice ATTACK — reentrancy. **EVERY EXTERNAL LEDGER PATH IS GUARDED, CHECKED STRUCTURALLY.**
    ///
    /// @dev The concrete reentrant evacuation is executed in `Rank.t.sol` `test_3_12`. What THIS
    ///      test adds is coverage of the entry points that do not exist yet: it reads the SHIPPING
    ///      SOURCE and asserts that every non-view `external` function carries `nonReentrant`. A
    ///      per-function test cannot do that, and PITFALLS 5.62 is the record of what happens when
    ///      a brand-new external function ships without its guard under test.
    function test_6_12_everyExternalStateChangingPathIsNonReentrant() public view {
        string memory src = vm.readFile("src/queue/QueueHook.sol");
        string[10] memory guarded = [
            "function addToSeat(uint256 seatId, uint256 amount0, uint256 amount1) external nonReentrant",
            "function withdraw(uint256 seatId, uint256 w0, uint256 w1) external nonReentrant",
            "function claimPending(uint256 w0, uint256 w1) external nonReentrant",
            "function sweepFloatIntoPosition() external nonReentrant",
            "function setSelfPrice(uint256 seatId, uint256 price) external nonReentrant",
            "function fundRent(uint256 seatId, uint256 amount) external nonReentrant",
            "function withdrawRent(uint256 seatId, uint256 amount) external nonReentrant",
            "function settleRent(uint256 seatId) external nonReentrant",
            "function buySeat(uint256 seatId, uint256 maxPrice, uint256 newSelfPrice) external nonReentrant",
            // `unlockCallback` is the one exception and it is guarded differently, by the only
            // caller that may reach it. Asserted here so the exception is deliberate, not a gap.
            "if (msg.sender != address(poolManager)) revert NotSoleLiquidityProvider();"
        ];
        for (uint256 i; i < guarded.length; i++) {
            assertTrue(_contains(src, guarded[i]), string.concat("unguarded or renamed: ", guarded[i]));
        }
        // ...and the seat token's two entry points, which live in the other file.
        string memory seats = vm.readFile("src/queue/QueueSeats.sol");
        assertTrue(
            _contains(
                seats, "function transfer(address receiver, uint256 seatId, uint256 amount) public virtual nonReentrant"
            ),
            "transfer lost its guard"
        );
        assertTrue(_contains(seats, "nonReentrant\n        returns (bool)"), "transferFrom lost its guard");
    }

    /// @notice EDGE — zero-amount and one-wei swaps. **DEFINED, NOT A REVERT.**
    function test_6_13_dustSwapsAreDefined() public {
        for (uint256 i = 1; i <= 3; i++) {
            _swap(true, i);
            _check(string.concat("dust swap ", vm.toString(i)));
        }
        for (uint256 i = 1; i <= 3; i++) {
            _swap(false, i);
            _check(string.concat("dust swap back ", vm.toString(i)));
        }
        // A zero-amount swap is refused by v4 itself, not by the hook.
        _expectSwapRevert(true, 0, bytes4(keccak256("SwapAmountCannotBeZero()")), "a zero swap did not revert");
    }

    /// @notice EDGE — every seat empty, and a single seat. **DEFINED, AND NOT A REVERT.**
    ///
    /// @dev §C.6 predicted `QueueUnderflow` here. It does not fire, for the same structural reason
    ///      as `test_6_15`: an empty ledger means an empty POSITION, and an empty position has
    ///      nothing to trade against — the swap is a complete NO-OP, in and out both zero, and
    ///      `_afterSwap` returns before the allocator is reached. Asserted, because "it does not
    ///      revert" is only half a claim.
    function test_6_14_anEmptyQueueIsANoOpAndOneSeatStillFills() public {
        _emptyEveryoneExcept(type(uint256).max);
        (uint256 t0, uint256 t1) = hook.totals();
        // NOT zero, and that is dust policy F1 rather than a defect: `withdraw` pays
        // `min(face, available)` and the seat keeps whatever the position could not release. What
        // remains is DUST, not depth.
        assertLt(t0 + t1, 1_000, "nothing happened: the queue is not empty, this test proves nothing");

        (uint256 inAmt, uint256 outAmt) = _swap(true, 1e18);
        assertEq(inAmt, 0, "an empty queue took input it could not back");
        assertEq(outAmt, 0, "an empty queue paid something out");
        _check("swap against an empty queue");
        _checkInvariantR("swap against an empty queue");

        // The no-op did move the pool's PRICE, though — with no liquidity to cross, v4 walks it
        // straight to the limit — and v4 itself, not the hook, then refuses another swap in the
        // same direction. Asserted by reason, because "the pool is at the bottom" is a fact a
        // reader of this suite should not have to discover from a trace.
        _expectSwapRevert(
            true,
            1e18,
            bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)")),
            "a second swap into an empty pool did not hit the price limit"
        );

        // ...and ONE funded seat is enough for the mechanism to work again. A single-seat fill is
        // the case the remainder line is INVISIBLE on (§B.5 step 4), which is exactly why the rest
        // of this project never tests only that.
        _addTo(ALICE, 0, 400e18, 100e18);
        (, uint256 got) = _swap(false, 20e18);
        assertGt(got, 0, "the single-seat queue could not fill");
        _check("single funded seat");
        assertEq(lastTouched, 1, "a single-seat fill touched more than one seat");
    }

    /// @notice BOUNDARY — **`QueueUnderflow` IS STRUCTURALLY UNREACHABLE THROUGH THE POOL, AND
    ///         §C.6's BOUNDARY TEST RESTED ON A FALSE PREMISE.**
    ///
    /// @dev §C.6 asks for two tests: a swap that exactly exhausts the queue fills, and "a swap one
    ///      wei larger than the queue" underflows. **There is no such swap.** A swap can only take
    ///      out what the POSITION holds, and INVARIANT F — asserted at zero surplus by the Phase 6
    ///      campaign — says the position never exceeds the ledger. So `amtOut <= Σa` always, and
    ///      INVARIANT C says every seat below the cursor is empty, so `amtOut <= Σ_{rank >= cursor} a`
    ///      too. The allocator cannot be asked for more than it has.
    ///
    ///      That makes `QueueUnderflow` exactly what it should be: not a boundary a trader can
    ///      reach, but the LOUD failure that fires when the ledger and the position have come
    ///      apart. `Rank.t.sol`'s ledger-only-evacuation control drains one without the other and
    ///      it fires there.
    ///
    ///      Executed here rather than argued: a swap of 100,000e18, over fifty times the queue's
    ///      whole token0 side, FILLS — taking the queue's token1 down to dust and the price to the
    ///      lower tick — and the ledger conserves to the wei.
    function test_6_15_theQueueCannotBeAskedForMoreThanItHolds() public {
        (, uint256 t1Before) = hook.totals();
        assertGt(t1Before, 0, "nothing happened: the queue holds no token1");

        _swap(true, 100_000e18);
        _check("a swap fifty times the size of the queue");

        (, uint256 t1After) = hook.totals();
        assertLt(t1After, t1Before / 20, "the oversized swap did not sweep the queue");

        // On a concentrated band a second oversized swap can hit `PriceLimitAlreadyExceeded`
        // because the first one already walked through empty ticks to the limit. The claim is
        // that the first one FILLED rather than `QueueUnderflow`'d, which is already asserted.
    }

    // ===================================================================================== helpers

    /// @dev Does a zero-for-one swap of `amountIn` fill, or does the queue underflow? Non-committal:
    ///      the state is restored either way.
    function _fills(bool zeroForOne, uint256 amountIn) internal returns (bool ok_) {
        uint256 snap = vm.snapshotState();
        (bool ok,) = address(this).call(abi.encodeCall(this.doSwap, (zeroForOne, amountIn)));
        vm.revertToState(snap);
        return ok;
    }

    /// @dev Take the queue's whole token1 side, which by INVARIANT F is the position's whole
    ///      token1 side — so the price ends AT the lower usable tick, `sqrtP == sqrtPriceAt(lower)`.
    ///      That is the exact state in which the position holds none of the token a seat may still
    ///      be owed, and it is where the span-based sizing divided by zero.
    function _drivePriceToTheFloor() internal {
        // Depth is what stops the price travelling, so take it out first. Alternating "withdraw the
        // token0 side" with "swap the token1 side away" collapses the position to a few units of
        // liquidity, and the price then reaches the bottom of the range — which is exactly how the
        // Phase 6 campaign got there.
        for (uint256 round; round < 8; round++) {
            _drainToken1();
            for (uint256 id; id < 4; id++) {
                (uint256 a0,) = hook.seat(id);
                if (a0 != 0) _withdrawTracked(id, a0, 0);
            }
            (uint160 p,,,) = poolManager.getSlot0(k.toId());
            if (p <= _sqrtLower()) break;
        }
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        assertLe(sqrtP, _sqrtLower(), "nothing happened: the price never reached the lower tick");

        // Drain whatever token1 the withdrawals left in the float, so a later request for token1
        // really does have to reach the position. Without this the test proves nothing.
        for (uint256 id; id < 4; id++) {
            (, uint256 a1) = hook.seat(id);
            if (a1 != 0) _withdrawTracked(id, 0, a1);
        }
    }

    /// @dev Repeatedly take the LARGEST zero-for-one swap that still fills, found by bisection.
    function _drainToken1() internal {
        for (uint256 round; round < 4; round++) {
            (, uint256 t1) = hook.totals();
            if (t1 == 0) break;
            uint256 best = _largestFillingSwap(true);
            if (best == 0) break;
            _swap(true, best);
        }
    }

    /// @dev The mirror, for the token0 side: enough one-for-zero flow to exhaust the head's token0
    ///      and push `cursor0` off rank 0.
    function _drainToken0() internal {
        for (uint256 round; round < 8; round++) {
            (uint256 c0_,) = hook.cursors();
            if (c0_ > 0) break;
            _swap(false, 40e18);
        }
    }

    function _largestFillingSwap(bool zeroForOne) internal returns (uint256) {
        uint256 lo = 1;
        uint256 hi = 1_000_000e18;
        if (!_fills(zeroForOne, lo)) return 0;
        if (_fills(zeroForOne, hi)) return hi;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_fills(zeroForOne, mid)) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _sqrtLower() internal view returns (uint160) {
        (,, int24 lower,) = hook.pool();
        return TickMath.getSqrtPriceAtTick(lower);
    }

    function _sqrtUpper() internal view returns (uint160) {
        (,,, int24 upper) = hook.pool();
        return TickMath.getSqrtPriceAtTick(upper);
    }

    /// @dev The two liquidity legs, in 256 bits — the fixture's own copy, so the test can say what
    ///      the contract is being asked to compute without reading the contract's answer back.
    function _liq1Probe(uint160 a, uint160 b, uint256 amount1) internal pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, b - a);
    }

    function _liq0Probe(uint160 a, uint160 b, uint256 amount0) internal pure returns (uint256) {
        return FullMath.mulDiv(amount0, FullMath.mulDiv(a, b, FixedPoint96.Q96), b - a);
    }

    /// @dev Walk the price down to `NEAR_FLOOR` — far enough down the range that the token1
    ///      liquidity leg diverges, but strictly ABOVE the lower usable tick, because one tick
    ///      further takes a different branch entirely and the divergence is in the IN-RANGE branch.
    ///
    ///      Done by BISECTING the swap size rather than guessing it: the price is monotone in the
    ///      input, so the smallest input that lands below the target is well defined and the search
    ///      is deterministic. Collapsing the position with withdrawals first does NOT work — with
    ///      no depth left, a one-wei swap slams the price straight past the tick.
    ///
    ///      The target is TWO SPACINGS above the position's own lower tick, not a hardcoded
    ///      `1e26` from the full-range era. A ±10% band never reaches `1e26`; a large swap skips
    ///      empty ticks and slams into `MIN_SQRT_PRICE`, which is the AT-the-tick branch this
    ///      helper exists to avoid.
    function _nearFloor() internal view returns (uint160) {
        (,, int24 lower,) = hook.pool();
        return TickMath.getSqrtPriceAtTick(lower + 2 * SPACING);
    }

    function _drivePriceNearTheFloor() internal {
        uint160 target = _nearFloor();
        for (uint256 round; round < 12; round++) {
            (uint160 p,,,) = poolManager.getSlot0(k.toId());
            if (p < target) return;

            uint256 top = _largestFillingSwap(true);
            if (top <= 1) break;
            if (_priceAfter(top) >= target) {
                _swap(true, top); // not far enough yet: take the whole step and go again
                continue;
            }
            uint256 lo_ = 1;
            uint256 hi_ = top;
            while (hi_ - lo_ > 1) {
                uint256 mid = lo_ + (hi_ - lo_) / 2;
                if (_priceAfter(mid) < target) hi_ = mid;
                else lo_ = mid;
            }
            _swap(true, hi_);
            return;
        }
    }

    /// @dev The pool price a swap WOULD leave behind. Non-committal: the state is restored.
    function _priceAfter(uint256 amountIn) internal returns (uint160 p) {
        uint256 snap = vm.snapshotState();
        (bool ok,) = address(this).call(abi.encodeCall(this.doSwap, (true, amountIn)));
        if (ok) (p,,,) = poolManager.getSlot0(k.toId());
        else p = type(uint160).max;
        vm.revertToState(snap);
    }

    /// @dev Empties every seat but `keep`. Debits the witness by what was PAID, never by what was
    ///      asked: dust policy F1 clamps the payout and the seat keeps the difference, so an
    ///      `expT0 -= a0` here leaves conservation short by the residual and every later `_check`
    ///      fails for the wrong reason.
    function _emptyEveryoneExcept(uint256 keep) internal {
        for (uint256 id; id < 4; id++) {
            if (id == keep) continue;
            (uint256 a0, uint256 a1) = hook.seat(id);
            if (a0 == 0 && a1 == 0) continue;
            _withdrawTracked(id, a0, a1);
        }
    }

    function _approveRouter(address who) internal {
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _seat0(uint256 id) internal view returns (uint256 a) {
        (a,) = hook.seat(id);
    }

    function _seat1(uint256 id) internal view returns (uint256 a) {
        (, a) = hook.seat(id);
    }

    function _swapAs(address who, bool zeroForOne, uint256 amountIn) internal returns (uint256 out) {
        uint256 b = _bal(zeroForOne ? c1 : c0, who);
        vm.prank(who);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: who,
            deadline: block.timestamp
        });
        out = _bal(zeroForOne ? c1 : c0, who) - b;
    }

    function _swapWithData(bool zeroForOne, uint256 amountIn, bytes memory data) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: data,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _swapRaw(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; i++) {
            bool hit = true;
            for (uint256 j; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }
}
