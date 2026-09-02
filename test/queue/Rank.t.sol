// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueSeats} from "../../src/queue/QueueSeats.sol";
import {Allocation} from "../../src/queue/libraries/Allocation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// =========================================================================== the negative controls

/// @dev CONTROL 3.8 — **the canonical form of this bug.** `transfer` evacuates and `transferFrom`
///      is left as a plain holder move, because the happy-path test only ever calls `transfer`.
///      Production makes this hard by funnelling both through one private `_moveSeat`; the control
///      exists to prove the SUITE can see the defect, which structural safety does not establish.
contract ForgetfulTransferFromHook is QueueHarness {
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

    function transferFrom(address sender, address receiver, uint256 seatId, uint256) public override returns (bool) {
        if (seatHolder[seatId] != sender) revert NotSeatOwner(seatId, sender);
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            allowance[sender][msg.sender][seatId] -= 1;
        }
        seatHolder[seatId] = receiver; // the evacuation, forgotten
        return true;
    }
}

/// @dev CONTROL 3.9 — rank granted by depositing, which is exactly what Phase 2 shipped and Phase 3
///      deleted. One wei of each token buys a brand new seat.
contract MintingDepositHook is QueueHarness {
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

    function deposit(uint256 amount0, uint256 amount1) external returns (uint256 seatId) {
        seatId = q.length;
        q.push(Seat({a0: 0, a1: 0, snap0: 0, snap1: 0, liquidity: 0}));
        // The new seat joins the order at the TAIL. Phase 4 made rank an explicit permutation, so a
        // variant that grows the roster has to say where the new rank goes — this control is about
        // rank being MINTABLE, not about the order word being maintainable, so it maintains it.
        order |= seatId << (8 * seatId);
        _mintSeat(msg.sender, seatId);
        _fundSeat(seatId, amount0, amount1);
    }
}

/// @dev CONTROL 3.11 — **PLAN §B.8's evacuation, implemented literally.** The seat's ledger moves to
///      `pendingWithdraw` and the position is left untouched. Exactly one thing differs from
///      production: the capital is not actually paid out.
contract LedgerOnlyEvacuationHook is QueueHarness {
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
        Seat storage s = q[seatId];
        pending0[from] += s.a0;
        pending1[from] += s.a1;
        pendingTotal0 += s.a0;
        pendingTotal1 += s.a1;
        standing0 -= s.a0;
        standing1 -= s.a1;
        s.a0 = 0;
        s.a1 = 0;
    }
}

/// @dev CONTROL 3.12 — the reentrancy guard removed from `transfer`, and nothing else.
contract UnguardedTransferHook is QueueHarness {
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

    function transfer(address receiver, uint256 seatId, uint256 amount) public override returns (bool) {
        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        _moveSeat(msg.sender, msg.sender, receiver, seatId, amount);
        return true;
    }
}

// ================================================================================ the attack rig

/// @dev A pool currency that hands control to an attacker exactly once, on a transfer. This is not
///      an exotic token: `poolManager.take` -> `IERC20.transfer(hook, amount)` is on the ordinary
///      withdrawal path, and any currency can do this. The point of the control is that the hook
///      must survive a currency that does.
contract ReenteringToken is MockERC20 {
    address public trigger;
    bool public armed;

    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    function arm(address who) external {
        trigger = who;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool ok) {
        ok = super.transfer(to, amount);
        if (armed) {
            armed = false;
            SeatReentrancyAttacker(trigger).onTokenMoved();
        }
    }
}

/// @notice Holds a seat, then tries to be paid twice for it: once through the evacuation that a
///         seat transfer performs, and once through a `withdraw` reentered from inside it.
contract SeatReentrancyAttacker {
    QueueHarness public immutable hook;
    uint256 public immutable seatId;
    bool public reentryRefused;

    constructor(QueueHarness h, uint256 id) {
        hook = h;
        seatId = id;
    }

    function approveAll(MockERC20 t0, MockERC20 t1) external {
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
    }

    function fund(uint256 a0, uint256 a1) external {
        hook.addToSeat(seatId, a0, a1);
    }

    /// @dev Sell the seat. The evacuation inside it opens the position, which moves a token, which
    ///      calls `onTokenMoved` below while the seat's ledger is still standing at full value.
    function sellSeat(address to) external {
        hook.transfer(to, seatId, 1);
    }

    /// @dev **The reentrant claim is on the OTHER token, and that is the whole trick.**
    ///
    ///      PoolManager is unlocked at this instant, so any path that needs its own `unlock` — a
    ///      withdrawal the float cannot cover — dies on `AlreadyUnlocked` and the hook looks safe.
    ///      The leg the float ALREADY covers needs no unlock at all. It pays straight out of the
    ///      float while the seat's ledger is still standing at full value, and the outer
    ///      evacuation then pays the same entitlement again from its stale cache of it.
    function onTokenMoved() external {
        (, uint256 a1) = hook.seat(seatId);
        if (a1 == 0) return;
        // The outcome cannot be reported out of this frame. v4's `CurrencyLibrary.transfer`
        // replaces ANY revert raised inside `take` with its own `ERC20TransferFailed`, and a flag
        // written here dies with the transaction if the outer call later reverts. So the control
        // asserts the difference that IS observable: whether the outer transfer completes.
        try hook.withdraw(seatId, 0, a1) {}
        catch {
            reentryRefused = true;
        }
    }
}

// =========================================================================================== suite

/// @notice Phase 3 — the ERC-6909 rank token: one id per seat, supply one, and a transfer that
///         moves RANK without moving capital.
///
/// The founding roster is fixed at deployment. Nothing in this file can create a seat, and that is
/// the property under test: while rank was granted by arrival order, one wei of each token bought
/// the head of the queue (PITFALLS 5.8).
contract RankTest is QueueFixture {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CARL = address(0xCAF1);
    address constant DAVE = address(0xDA4E);

    /// @dev The §E.4 residual bound, same derivation as `Deposit.t.sol`: linear in swaps, never
    ///      compounding, with margin. Not a tolerance widened until the tests went green.
    function _bound(uint256 nSwaps) internal pure returns (uint256) {
        return 4 * nSwaps + 64;
    }

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        startPrice = Constants.SQRT_PRICE_1_4;
        dec0 = 18;
        dec1 = 6; // LAW 1: non-unit price AND asymmetric decimals
        _deployTokens();
        _deployHookUnfunded(0x9001, _roster(ALICE, BOB, CARL));
        _initPool();
    }

    function _three() internal {
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 60e18, 15e18);
        _addTo(CARL, 2, 900e18, 225e18);
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    // ================================================== 3.1 — supply is exactly one, structurally

    /// @dev Supply cannot be anything but one: ownership is a single `address` slot per id, so
    ///      there is no storage in which "two" could be written. The test walks every id through
    ///      every operation anyway — a structural argument is a reason to believe the code, not
    ///      evidence that the tests would notice if it stopped being true.
    function test_3_1_seatSupplyIsAlwaysExactlyOne() public {
        _three();
        address[3] memory holders = [ALICE, BOB, CARL];

        for (uint256 i; i < 3; i++) {
            _assertSupplyOne(i, holders[i], "after funding");
        }

        // ...through a transfer,
        vm.prank(ALICE);
        hook.transfer(DAVE, 0, 1);
        _assertSupplyOne(0, DAVE, "after transfer");

        // ...through an approved transferFrom,
        vm.prank(BOB);
        hook.approve(address(this), 1, 1);
        hook.transferFrom(BOB, DAVE, 1, 1);
        _assertSupplyOne(1, DAVE, "after transferFrom");

        // ...through a swap that moves every seat's composition,
        _swap(true, 200e18);
        for (uint256 i; i < 3; i++) {
            _assertSupplyOne(i, hook.ownerOf(i), "after a swap");
        }

        // ...and through a withdrawal that empties one.
        (uint256 a0, uint256 a1) = hook.seat(2);
        vm.prank(CARL);
        hook.withdraw(2, a0, a1);
        _assertSupplyOne(2, CARL, "after withdrawal to zero");

        // An id that was never minted has no holder and no supply, at any address.
        assertEq(hook.ownerOf(3), address(0), "an unminted id has a holder");
        assertEq(hook.balanceOf(DAVE, 3), 0, "an unminted id has supply");
        assertEq(hook.balanceOf(address(0), 3), 0, "address(0) holds an unminted id");
    }

    function _assertSupplyOne(uint256 id, address holder, string memory tag) internal view {
        assertEq(hook.balanceOf(holder, id), 1, string.concat(tag, ": holder does not hold exactly 1"));
        assertEq(hook.ownerOf(id), holder, string.concat(tag, ": ownerOf disagrees with balanceOf"));
        // Nobody else holds any of it. `address(0)` included — a burned seat would be a rank slot
        // nobody can ever occupy.
        address[4] memory others = [ALICE, BOB, CARL, DAVE];
        uint256 total;
        for (uint256 j; j < 4; j++) {
            total += hook.balanceOf(others[j], id);
        }
        assertEq(total, 1, string.concat(tag, ": supply is not exactly 1 across all holders"));
        assertEq(hook.balanceOf(address(0), id), 0, string.concat(tag, ": address(0) holds the seat"));
    }

    // ================================================ 3.2 — a transfer moves rank, never capital

    function test_3_2_transferMovesRankNotCapital() public {
        _three();
        _swap(true, 120e18); // lopsided compositions, so this is not a trivial equal-legs case
        _check("pre-transfer");

        (uint256 a0, uint256 a1) = hook.seat(0);
        assertTrue(a0 != 0 || a1 != 0, "fixture drifted: the seat under test is empty");

        uint256 b0 = _bal(c0, ALICE);
        uint256 b1 = _bal(c1, ALICE);

        vm.prank(ALICE);
        hook.transfer(DAVE, 0, 1);
        _evacuateRef(0);
        // **THE WITNESS MIRRORS THE DEMOTION.** A transfer that takes a seat's contributed depth
        // out costs it its place in the queue, exactly as a withdrawal does — `_evacuateRef` only
        // re-bases the balances, so the order model is stepped here.
        _refDemote(0);

        // The SEAT moved.
        assertEq(hook.ownerOf(0), DAVE, "the seat did not change hands");

        // **THE RANK DID NOT MOVE WITH IT — IT WAS SPENT.** `_onSeatTransfer` empties the seat, so
        // every wei of the outgoing holder's contributed depth leaves the pool; that is the same
        // act `withdraw` is demoted for, and until PITFALLS 5.123(a) was closed it cost nothing at
        // all. A holder with a second address had the whole evacuation attack without ever calling
        // `withdraw`. What DAVE receives is a seat at the tail, which he must fund to be filled.
        assertEq(hook.rankOfId(0), 2, "A FUNDED TRANSFER KEPT ITS RANK: the evacuation door is open");
        assertEq(hook.idAtRank(0), 1, "seat 1 was not promoted into the vacated front");

        // Capital did not: DAVE's seat is empty and ALICE was made whole, to the wei less whatever
        // the position could not release on the spot — which is retained as a pending claim rather
        // than travelling to DAVE.
        (uint256 n0, uint256 n1) = hook.seat(0);
        assertEq(n0, 0, "capital travelled with the rank (token0)");
        assertEq(n1, 0, "capital travelled with the rank (token1)");

        (uint256 w0, uint256 w1) = hook.pendingOf(ALICE);
        assertEq(_bal(c0, ALICE) - b0 + w0, a0, "seller was not made whole in token0");
        assertEq(_bal(c1, ALICE) - b1 + w1, a1, "seller was not made whole in token1");
        assertLe(w0, _bound(1), "pending token0 is not residual-scale");
        assertLe(w1, _bound(1), "pending token1 is not residual-scale");

        // Whatever was retained is fully recoverable.
        if (w0 != 0 || w1 != 0) {
            vm.prank(ALICE);
            hook.claimPending(w0, w1);
        }

        _check("post-transfer");
        _checkInvariantF("post-transfer", _bound(1));
    }

    // ============================== 3.3 — the same, through transferFrom AND through an operator

    function test_3_3_transferFromAlsoMovesRankNotCapital() public {
        _three();
        _swap(true, 120e18);

        // --- allowance path
        (uint256 a0, uint256 a1) = hook.seat(0);
        uint256 b0 = _bal(c0, ALICE);
        uint256 b1 = _bal(c1, ALICE);

        vm.prank(ALICE);
        hook.approve(address(this), 0, 1);
        hook.transferFrom(ALICE, DAVE, 0, 1);
        _evacuateRef(0);
        _refDemote(0); // a funded transfer costs the rank, on THIS path too

        assertEq(hook.ownerOf(0), DAVE, "allowance path: the seat did not change hands");
        assertEq(hook.rankOfId(0), 2, "allowance path: A FUNDED TRANSFER KEPT ITS RANK");
        (uint256 n0, uint256 n1) = hook.seat(0);
        assertEq(n0 + n1, 0, "allowance path: capital travelled with the rank");
        (uint256 w0, uint256 w1) = hook.pendingOf(ALICE);
        assertEq(_bal(c0, ALICE) - b0 + w0, a0, "allowance path: seller short in token0");
        assertEq(_bal(c1, ALICE) - b1 + w1, a1, "allowance path: seller short in token1");
        assertEq(hook.allowance(ALICE, address(this), 0), 0, "the allowance was not spent");

        // --- operator path
        (a0, a1) = hook.seat(1);
        b0 = _bal(c0, BOB);
        b1 = _bal(c1, BOB);

        vm.prank(BOB);
        hook.setOperator(address(this), true);
        hook.transferFrom(BOB, DAVE, 1, 1);
        _evacuateRef(1);
        // **MUTATE EVERY COPY OF A RULE SEPARATELY, PER ENTRY POINT** (AGENTS §3b). The order is
        // [1,2,0] after the allowance path above, so demoting seat 1 leaves [2,0,1].
        _refDemote(1);

        assertEq(hook.ownerOf(1), DAVE, "operator path: the seat did not change hands");
        assertEq(hook.rankOfId(1), 2, "operator path: A FUNDED TRANSFER KEPT ITS RANK");
        assertEq(hook.idAtRank(0), 2, "operator path: seat 2 was not promoted into the front");
        (n0, n1) = hook.seat(1);
        assertEq(n0 + n1, 0, "operator path: capital travelled with the rank");
        (uint256 v0, uint256 v1) = hook.pendingOf(BOB);
        assertEq(_bal(c0, BOB) - b0 + v0, a0, "operator path: seller short in token0");
        assertEq(_bal(c1, BOB) - b1 + v1, a1, "operator path: seller short in token1");

        _check("post-transferFrom");
        _checkInvariantF("post-transferFrom", _bound(1));
    }

    /// @dev Without an allowance or an operator flag, a third party cannot move the seat. Asserting
    ///      the SPECIFIC reason (LAW 2): a generic revert here would also fire if the seat simply
    ///      did not exist.
    function test_3_3b_transferFromWithoutPermissionIsRefused() public {
        _three();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.InsufficientPermission.selector, uint256(0), BOB));
        hook.transferFrom(ALICE, BOB, 0, 1);
    }

    /// @dev **MUTATION SURVIVOR, 2026-08-27.** Removing the ownership check from `transfer` was
    ///      caught by NOTHING: `transferFrom` had `test_3_3b` and `transfer` had no equivalent at
    ///      all. Third instance of the paired-rule asymmetry on this project (PITFALLS 5.37, 5.50)
    ///      — and the first one that was a straight theft rather than a lost wei.
    function test_3_2b_aStrangerCannotTransferSomeoneElsesSeat() public {
        _three();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), BOB));
        hook.transfer(BOB, 0, 1);

        assertEq(hook.ownerOf(0), ALICE, "a stranger moved the rank");
        (uint256 a0, uint256 a1) = hook.seat(0);
        assertEq(a0, 40e18, "a refused transfer evacuated token0");
        assertEq(a1, 10e18, "a refused transfer evacuated token1");
    }

    /// @dev **MUTATION SURVIVOR, 2026-08-27.** `test_3_3b` proves an unapproved THIRD PARTY is
    ///      refused, and that is not the same claim: naming YOURSELF as `sender` skips the
    ///      allowance branch entirely, so without the holder check anyone could take any seat for
    ///      free — and be paid its capital on the way out.
    function test_3_3c_transferFromCannotMoveASeatItsSenderDoesNotHold() public {
        _three();

        // BOB names himself, so no allowance is consulted at all. He still does not hold seat 0.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), BOB));
        hook.transferFrom(BOB, BOB, 0, 1);

        // And the same through an operator, who is authorised for BOB and for nothing else.
        vm.prank(BOB);
        hook.setOperator(DAVE, true);
        vm.prank(DAVE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), BOB));
        hook.transferFrom(BOB, DAVE, 0, 1);

        assertEq(hook.ownerOf(0), ALICE, "the seat was taken from its holder");
        (uint256 a0,) = hook.seat(0);
        assertEq(a0, 40e18, "the seat was evacuated to somebody who never held it");
    }

    // ================================================ 3.4 — fills follow the new holder, at once

    /// @dev The seat arrives empty, so the new holder must fund it before it can be filled — that
    ///      is what "rank moves, capital does not" MEANS. What must be immediate is that the fill
    ///      then lands at the transferred INDEX, on the very next swap, for the new holder.
    /// @dev **THE OPERATIVE CLAIM IS THAT THE VALUE LANDS UNDER THE NEW HOLDER, AND IT SURVIVED
    ///      THE PITFALLS 5.123(a) REMEDY UNCHANGED. WHERE IT LANDS DID NOT.** A funded transfer now
    ///      takes the seat's contributed depth out of the pool and is demoted for it, so the seat
    ///      DAVE receives sits at the tail and the head-only fill goes to the seat promoted into
    ///      rank 0. Both halves are asserted, because "the new holder gets the fill" and "the new
    ///      holder gets the FRONT" are two different claims and only the first one is true.
    function test_3_4_fillsFollowTheNewHolderImmediately() public {
        _three();

        vm.prank(ALICE);
        hook.transfer(DAVE, 0, 1);
        _evacuateRef(0);
        _refDemote(0);
        assertEq(hook.ownerOf(0), DAVE, "the seat did not change hands");
        assertEq(hook.rankOfId(0), 2, "the funded transfer kept its rank");

        // DAVE funds the seat where it now stands. `addToSeat` pulls both cursors back to its RANK
        // (PITFALLS 5.50), so the next fill starts no later than there.
        _addTo(DAVE, 0, 40e18, 10e18);

        // A small swap lands entirely inside whoever is at the FRONT, and that is no longer DAVE.
        uint256[] memory before = _snapshot(true);
        _swap(true, 1e18);
        _check("fill after transfer");
        assertEq(lastTouched, 1, "the fill was not head-only");
        (, uint256 promoted1) = hook.seat(hook.idAtRank(0));
        assertTrue(promoted1 != before[0], "the promoted seat was not the one filled");
        (, uint256 daveHeld1) = hook.seat(0);
        assertEq(daveHeld1, 10e18, "the tail seat was filled while a seat stood in front of it");

        // ...and when the seats in front leave, DAVE's seat is promoted back to the front and the
        // fill lands under DAVE. The seats ahead are emptied through the ORDINARY withdrawal path,
        // which demotes each of them in turn — [1,2,0] -> [2,0,1] -> [0,1,2].
        for (uint256 r; r < 2; r++) {
            uint256 id = hook.idAtRank(0);
            (uint256 f0, uint256 f1) = hook.seat(id);
            _withdrawTracked(id, f0, f1);
        }
        assertEq(hook.idAtRank(0), 0, "the promotions did not bring the new holder's seat back");

        _swap(true, 1e18);
        _check("fill after the promotions");
        (uint256 h0, uint256 h1) = hook.seat(0);
        assertGt(h0, 40e18, "the new holder's seat was never credited the incoming token");
        assertLt(h1, 10e18, "the new holder's seat gave up none of the outgoing token");

        // And it landed under DAVE's seat, not ALICE's — ALICE holds no seat at all now.
        assertEq(hook.balanceOf(ALICE, 0), 0, "the old holder still holds the seat");
        _withdrawTracked(0, h0, h1); // the new holder can take it, which is the operative claim
    }

    // ============================================= 3.5 — a seat cannot be created by any runtime path

    function test_3_5_seatCannotBeMintedByDepositing() public {
        _three();
        assertEq(hook.seatCount(), 3, "the roster is not the one that was deployed");

        // There is no `deposit()` on the shipping contract at all: the Phase 2 entry point that
        // created a seat as a side effect was deleted, not guarded.
        _fund(DAVE, 1e18, 1e18);
        vm.prank(DAVE);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("deposit(uint256,uint256)", uint256(1), uint256(1)));
        assertFalse(ok, "the shipping contract still exposes deposit()");
        assertEq(hook.seatCount(), 3, "the roster grew");

        // Nor can capital be pushed into a seat somebody else holds, or into one that does not
        // exist — funding is not a claim on rank.
        vm.prank(DAVE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), DAVE));
        hook.addToSeat(0, 1e18, 1e18);

        vm.prank(DAVE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(3), DAVE));
        hook.addToSeat(3, 1e18, 1e18);
        assertEq(hook.seatCount(), 3, "the roster grew");
    }

    // ================================================================= 3.6 — the roster is bounded

    function test_3_6_seatCountNeverExceedsMax() public {
        uint256 max = hook.MAX_SEATS();
        assertEq(max, 32, "MAX_SEATS moved without the gas table moving with it");

        // Exactly MAX_SEATS deploys.
        address a = address(FLAGS ^ (uint160(0x9101) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(_syntheticRoster(max)), a);
        assertEq(QueueHarness(a).seatCount(), max, "a full roster did not deploy");

        // One more does not, and it says so by name. (`new QueueHarness(...)` cannot be used here:
        // `BaseHook` validates the deployment address in ITS constructor, which runs first, so an
        // ordinary `new` dies on the hook-flags check and would never reach the roster at all.)
        _expectDeployRevert(
            _syntheticRoster(max + 1),
            0x9102,
            abi.encodeWithSelector(QueueHook.RosterTooLarge.selector, max + 1, max),
            "an over-sized roster deployed"
        );

        // Neither does an empty one — a hook with no seats can never source a swap and has no path
        // to gain one.
        _expectDeployRevert(
            new address[](0), 0x9103, abi.encodeWithSelector(QueueHook.EmptyRoster.selector), "an empty roster deployed"
        );

        // Nor one that would mint a seat to nobody.
        address[] memory withZero = new address[](2);
        withZero[0] = ALICE;
        _expectDeployRevert(
            withZero,
            0x9104,
            abi.encodeWithSelector(QueueHook.ZeroHolder.selector, uint256(1)),
            "a roster with a zero holder deployed"
        );
    }

    /// @dev Run the constructor at a VALID hook address and assert its exact revert data (LAW 2).
    ///      `deployCodeTo` swallows the reason into a fixed string, so the etch-and-call is done by
    ///      hand here.
    function _expectDeployRevert(address[] memory roster, uint160 nonce, bytes memory wantErr, string memory what)
        internal
    {
        address at = address(FLAGS ^ (nonce << 144));
        vm.etch(at, abi.encodePacked(vm.getCode("QueueHarness.sol:QueueHarness"), _ctorArgs(roster)));
        (bool ok, bytes memory err) = at.call("");
        assertFalse(ok, what);
        assertEq(err, wantErr, string.concat(what, ": reverted for the WRONG reason"));
    }

    // ============================================== 3.7 — an empty seat is transferable, keeps rank

    /// @dev An empty seat is PURE RANK. Being able to hold, price and sell one with no capital
    ///      attached is the whole object the project exists to create.
    function test_3_7_emptySeatIsTransferableAndKeepsRank() public {
        _three();
        // EMPTY THE SEAT WITHOUT WITHDRAWING. A withdrawal that pays now costs the seat its place
        // in the queue, so reaching "empty" that way would move the rank before the transfer under
        // test ever ran — and this test is about what a TRANSFER does to a rank, not about what a
        // withdrawal does. `buySeat` on a never-priced seat evacuates it and leaves the rank alone,
        // which is exactly the state the test wants and is reached through production.
        vm.prank(BOB);
        hook.buySeat(0, 0, 0);
        _evacuateRef(0);
        // Emptying it cost it its rank — that is the 5.123(a) remedy, not the property under test.
        // The seat is now at the TAIL and holds nothing, which is the pure-rank state this test is
        // about; where that rank sits is irrelevant to the claim, so the claim is stated as rank
        // INVARIANCE across the transfer rather than as "rank 0".
        _refDemote(0);
        vm.prank(BOB);
        hook.transfer(ALICE, 0, 1); // hand the now-empty seat on, so ALICE holds pure rank

        (uint256 z0, uint256 z1) = hook.seat(0);
        assertLe(z0 + z1, _bound(0), "the seat was not emptied");
        uint256 rankBefore = hook.rankOfId(0);
        assertEq(hook.ownerOf(0), ALICE, "the empty seat did not transfer to ALICE");

        uint256 payBefore = _bal(c0, ALICE) + _bal(c1, ALICE);
        vm.prank(ALICE);
        hook.transfer(DAVE, 0, 1);

        assertEq(hook.ownerOf(0), DAVE, "empty seat did not transfer");
        assertEq(_bal(c0, ALICE) + _bal(c1, ALICE), payBefore, "an empty transfer moved tokens");
        assertEq(hook.seatCount(), 3, "the roster changed size on a transfer");
        // **THE CLAIM.** A seat with no contributed depth takes none out when it changes hands, so
        // it is not demoted. This is what keeps the Phase 4 rank market alive after 5.123(a): pure
        // rank still trades freely, and only DEPTH leaving costs a place in the queue.
        assertEq(hook.rankOfId(0), rankBefore, "THE TRANSFER OF AN EMPTY SEAT MOVED THE RANK");

        // ...and the rank it kept is a real place in line, not a number in a view: funded, it is
        // still BEHIND the seats it was behind, so a head-only fill does not touch it.
        _addTo(DAVE, 0, 40e18, 10e18);
        assertEq(hook.rankOfId(0), rankBefore, "funding the transferred seat moved its rank");
        uint256[] memory before = _snapshot(true);
        _swap(true, 1e18);
        _check("empty seat kept its rank");
        assertEq(lastTouched, 1, "the fill was not head-only: this arm proves nothing");
        (, uint256 promoted1) = hook.seat(hook.idAtRank(0));
        assertTrue(promoted1 != before[hook.idAtRank(0)], "nothing was filled at all: this arm proves nothing");
        (, uint256 h1) = hook.seat(0);
        assertEq(h1, 10e18, "a seat at the tail was filled while seats stood in front of it");
    }

    // ============================================================ a seat cannot be burned or split

    function test_3_7b_aSeatCannotBeBurnedOrSplit() public {
        _three();

        // Sending it to nobody would take a rank slot out of a bounded roster permanently, and
        // there is no admin to repair it.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.SeatCannotBeBurned.selector, uint256(0)));
        hook.transfer(address(0), 0, 1);

        // A zero-amount transfer is refused rather than silently accepted: on this contract a
        // transfer EVACUATES, so an integrator who believes it moved nothing would be wrong.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.SeatIsIndivisible.selector, uint256(0), uint256(0)));
        hook.transfer(BOB, 0, 0);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.SeatIsIndivisible.selector, uint256(0), uint256(2)));
        hook.transfer(BOB, 0, 2);

        // And the seat is untouched by any of that.
        assertEq(hook.ownerOf(0), ALICE, "a refused transfer moved the seat");
        (uint256 a0,) = hook.seat(0);
        assertEq(a0, 40e18, "a refused transfer evacuated the seat");
    }

    // ============================================================ CONTROL 3.8 — forgotten override

    function test_3_8_negativeControl_transferFromNotOverridden() public {
        // Production: capital does NOT travel.
        _three();
        _swap(true, 120e18);
        (uint256 a0, uint256 a1) = hook.seat(0);
        assertTrue(a0 != 0 || a1 != 0, "fixture drifted: nothing to escape");
        vm.prank(ALICE);
        hook.approve(address(this), 0, 1);
        hook.transferFrom(ALICE, DAVE, 0, 1);
        (uint256 p0, uint256 p1) = hook.seat(0);
        assertEq(p0 + p1, 0, "POSITIVE CONTROL FAILED: production leaked capital through transferFrom");

        // The variant: identical scenario, `transferFrom` left as a plain holder move.
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.forgetfulScenario, ()));
        assertFalse(ok, "the forgotten-override variant passed the capital-escape assertion");
        assertEq(
            _reasonOf(err),
            "capital escaped with the rank through transferFrom",
            "control went red for the WRONG reason"
        );
    }

    /// @dev External so the control can capture the revert and assert its exact reason (LAW 2).
    function forgetfulScenario() external {
        address a = address(FLAGS ^ (uint160(0x9201) << 144));
        deployCodeTo("Rank.t.sol:ForgetfulTransferFromHook", _ctorArgs(_roster(ALICE, BOB, CARL)), a);
        hook = QueueHarness(a);
        _initPool();
        _three();
        _swap(true, 120e18);

        vm.prank(ALICE);
        hook.approve(address(this), 0, 1);
        hook.transferFrom(ALICE, DAVE, 0, 1);

        (uint256 n0, uint256 n1) = hook.seat(0);
        require(n0 == 0 && n1 == 0, "capital escaped with the rank through transferFrom");
    }

    // ========================================================== CONTROL 3.9 — rank by depositing

    function test_3_9_negativeControl_depositMintsASeat() public {
        address a = address(FLAGS ^ (uint160(0x9301) << 144));
        deployCodeTo("Rank.t.sol:MintingDepositHook", _ctorArgs(_roster(ALICE, BOB, CARL)), a);
        hook = QueueHarness(a);
        _initPool();
        _three();

        // On the variant, one wei of each token buys a seat — and the assertion that Phase 3's
        // roster is fixed goes red on exactly that.
        _fund(DAVE, 1, 1);
        vm.prank(DAVE);
        (bool ok, bytes memory ret) =
            address(hook).call(abi.encodeWithSignature("deposit(uint256,uint256)", uint256(1), uint256(1)));
        assertTrue(ok, "the minting variant did not mint");
        uint256 newSeat = abi.decode(ret, (uint256));

        assertEq(hook.seatCount(), 4, "the roster did not grow on the variant");
        assertEq(hook.ownerOf(newSeat), DAVE, "the variant did not grant rank to the depositor");
        // Two wei bought a place in the queue. That is the hole Phase 3 closed, executed.
    }

    // ============================================ CONTROL 3.11 — §B.8's evacuation, and its free DoS

    /// @dev **THE PLAN'S OWN DESIGN, EXECUTED.** §B.8 specified a ledger-only evacuation. It drops
    ///      `sum(q[i].aX)` while leaving the position at full depth, so the pool goes on quoting
    ///      liquidity the queue can no longer source. One seat holder transfers a funded seat TO
    ///      THEMSELVES and every swap above the surviving balance reverts — free, repeatable, and
    ///      undoable at will.
    function test_3_11_negativeControl_ledgerOnlyEvacuationBricksTheSwapPath() public {
        // Production first: the same sequence must leave the pool swappable.
        _three();
        vm.prank(CARL);
        hook.transfer(CARL, 2, 1); // the tail holds 90% of the queue
        _evacuateRef(2);
        _swap(true, 200e18);
        _check("production survives a self-transfer");

        // The variant: identical sequence, ledger-only evacuation.
        address a = address(FLAGS ^ (uint160(0x9401) << 144));
        deployCodeTo("Rank.t.sol:LedgerOnlyEvacuationHook", _ctorArgs(_roster(ALICE, BOB, CARL)), a);
        hook = QueueHarness(a);
        _initPool();
        _three();

        (, uint256 tail1) = hook.seat(2);
        assertGt(tail1, 0, "fixture drifted: the tail must hold the token being bought");

        vm.prank(CARL);
        hook.transfer(CARL, 2, 1);

        // The position is untouched — the pool still quotes full depth...
        assertGt(hook.positionLiquidity(), 0, "the variant burned the position after all");
        // ...but the queue can no longer source it, and the swap dies inside the allocator.
        _expectSwapRevert(true, 200e18, Allocation.QueueUnderflow.selector, "the ledger-only DoS did not fire");
    }

    // ================================== CONTROL 3.12 — the reentrancy guard, and what it is holding

    /// @dev Executed, not argued — and reported as what it actually shows.
    ///
    ///      The attacker holds a seat, sells it, and is handed control by one of the pool's own
    ///      currencies in the middle of the evacuation, while the seat's ledger still stands at
    ///      full value. PoolManager's lock does not stop them: the reentrant claim is on the leg
    ///      the FLOAT already covers, so it needs no second `unlock`.
    ///
    ///      PRODUCTION refuses it explicitly and pays the seller exactly the seat.
    ///
    ///      THE UNGUARDED VARIANT lets it land, and the transfer then dies inside `_burnPosition`:
    ///      `unlockCallback` measures what the position released by differencing the hook's own
    ///      token balances across the unlock, the reentrant payout moved one of them, and the
    ///      measurement comes back saying a REMOVAL debited the hook — which cannot happen, since a
    ///      removal is owed both the principal it releases and the fees it realises.
    ///
    ///      **UPDATED IN PHASE 6, AND THE UPDATE IS THE INTERESTING PART.** Until Phase 6 this
    ///      control asserted an arithmetic PANIC, because the measurement was unsigned and simply
    ///      underflowed — and the comment here said so: the revert was the accident, not the
    ///      defence. Phase 6 found that the same unsigned subtraction underflowed on the ORDINARY
    ///      deposit path too, whenever the position's accrued fees exceeded the principal being
    ///      added, and replaced it with a signed measurement plus a named guard. So the corruption
    ///      now trips `UnexpectedPositionDebit` instead of a panic.
    ///
    ///      What is still NOT claimed: the guard catches only the direction that makes the measured
    ///      change negative. A reentrant payout that leaves it positive-but-wrong is still silently
    ///      absorbed by the float, which is every other seat's money — and the `nonReentrant` guard
    ///      is the only thing that makes the measurement meaningful at all. No value-extracting
    ///      sequence was found without it, and none is claimed. The name of this test says what it
    ///      shows: a corrupted measurement, not a theft.
    function test_3_12_negativeControl_reentrantEvacuationCorruptsTheUnlockMeasurement() public {
        // --- production: the reentry is refused, and the seller is paid exactly the seat
        (SeatReentrancyAttacker atkA, uint256 owedA) = _reentrancyRig("QueueHarness.sol:QueueHarness", 0x9501, true);
        vm.prank(address(atkA));
        atkA.sellSeat(DAVE);
        assertTrue(atkA.reentryRefused(), "production did not refuse the reentrant withdrawal");

        (, uint256 pendA) = hook.pendingOf(address(atkA));
        assertEq(_bal(c1, address(atkA)) + pendA, owedA, "production paid the seller something other than the seat");
        (uint256 n0, uint256 n1) = hook.seat(0);
        assertEq(n0 + n1, 0, "production left capital in the transferred seat");
        assertEq(hook.ownerOf(0), DAVE, "production did not move the rank");

        // --- the same rig with the guard removed from `transfer`, and NOT armed. The variant is
        // otherwise healthy: without a reentering currency the transfer completes normally. Without
        // this, a revert below would prove only that the variant is broken.
        (SeatReentrancyAttacker atkB, uint256 owedB) = _reentrancyRig("Rank.t.sol:UnguardedTransferHook", 0x9601, false);
        vm.prank(address(atkB));
        atkB.sellSeat(DAVE);
        assertEq(hook.ownerOf(0), DAVE, "the unguarded variant cannot transfer at all: nothing to compare");
        (, uint256 pendB) = hook.pendingOf(address(atkB));
        assertEq(_bal(c1, address(atkB)) + pendB, owedB, "unarmed variant paid something other than the seat");

        // --- and armed. The reentrant withdrawal executes — it needs no second `unlock` — and the
        // transfer then dies inside `unlockCallback`, which differenced a balance that payout moved.
        (SeatReentrancyAttacker atkC,) = _reentrancyRig("Rank.t.sol:UnguardedTransferHook", 0x9602, true);
        (bool ok, bytes memory err) = address(atkC).call(abi.encodeCall(SeatReentrancyAttacker.sellSeat, (DAVE)));
        assertFalse(ok, "the unguarded variant completed a transfer with a reentrant payout inside it");
        assertEq(
            bytes4(err),
            QueueHook.UnexpectedPositionDebit.selector,
            "the unguarded variant went red for the WRONG reason"
        );
        // ...and it says WHICH LEG was corrupted, rather than only that arithmetic failed. Here it
        // is currency1: the reentrant claim was paid on the leg the float already covered, so the
        // hook's currency1 balance FELL across an unlock that should only ever have raised it.
        assertGt(_argWord(err, 0), 0, "expected the currency0 leg to be a normal release");
        assertLt(_argWord(err, 1), 0, "the named guard fired without a negative measurement");
        assertFalse(atkC.reentryRefused(), "the unguarded variant refused the reentry after all");

        // Nothing was stolen here — the whole transfer rolled back. Nothing was MEASURED correctly
        // either, and the direction that happens to underflow is the lucky one.
        assertEq(hook.ownerOf(0), address(atkC), "the reverted transfer moved the rank anyway");
    }

    /// @dev Argument `i` of a custom error's ABI payload, read as a signed word.
    function _argWord(bytes memory err, uint256 i) internal pure returns (int256 w) {
        uint256 off = 0x24 + i * 0x20;
        assembly {
            w := mload(add(err, off))
        }
    }

    /// @dev Builds a pool whose token0 hands control to an attacker once, seats the attacker at the
    ///      head, and returns what its seat is worth in token1.
    ///
    ///      The second seat is funded far off the pool's raw ratio ON PURPOSE, so most of its token1
    ///      lands in the shared float (PITFALLS 5.44). That float is what makes the reentrant token1
    ///      withdrawal payable without a second `unlock` — which is the only reason the window is
    ///      reachable at all.
    function _reentrancyRig(string memory artifact, uint160 nonce, bool arm)
        internal
        returns (SeatReentrancyAttacker atk, uint256 seatValue)
    {
        // A fresh pool per rig: token0 must be the reentering one, so both tokens are redeployed
        // until the sort order puts it first.
        ReenteringToken evil;
        MockERC20 plain;
        for (uint256 salt; salt < 64; salt++) {
            evil = new ReenteringToken("Evil", "EVIL", 18);
            plain = new MockERC20("Plain", "PLN", 6);
            if (address(evil) < address(plain)) break;
        }
        require(address(evil) < address(plain), "could not order the reentering token first");
        (c0, c1) = (Currency.wrap(address(evil)), Currency.wrap(address(plain)));

        address hookAddr = address(FLAGS ^ (nonce << 144));
        // The attacker's address must be known before the roster is fixed, and the roster must be
        // fixed before the hook exists. Precompute it: `deployCodeTo` etches rather than creating,
        // so it does not move this contract's nonce in between.
        address atkAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address[] memory roster = new address[](2);
        roster[0] = atkAddr;
        roster[1] = BOB;
        deployCodeTo(artifact, _ctorArgs(roster), hookAddr);
        hook = QueueHarness(hookAddr);
        atk = new SeatReentrancyAttacker(hook, 0);
        require(address(atk) == atkAddr, "attacker address prediction failed");

        _initPool();
        // This control was written against a full-range blob: almost all of BOB's token1
        // has to land in the float so the reentrant withdrawal needs no second unlock.
        // The shipping band would dump the attacker on-ratio into a tight range and the
        // signed measurement no longer goes negative. The product is the band; this is
        // the old fixture, restored only here.
        hook.forceRange(TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));

        evil.mint(address(atk), 40e18);
        plain.mint(address(atk), 10e18);
        evil.mint(BOB, 4e18);
        plain.mint(BOB, 500e18);
        atk.approveAll(MockERC20(address(evil)), plain);
        vm.startPrank(BOB);
        evil.approve(address(hook), type(uint256).max);
        plain.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.prank(address(atk));
        atk.fund(40e18, 10e18);
        vm.prank(BOB);
        hook.addToSeat(1, 4e18, 500e18);

        (, uint256 f1) = hook.floats();
        require(f1 > 100e18, "rig drifted: the float cannot cover the reentrant leg");

        (, seatValue) = hook.seat(0);
        if (arm) evil.arm(address(atk));
    }

    function _reasonOf(bytes memory err) internal pure returns (string memory) {
        bytes memory inner = _unwrap(err);
        if (inner.length < 68) return "<non-string revert>";
        assembly {
            inner := add(inner, 0x04)
        }
        return abi.decode(inner, (string));
    }

    // ============================ the clamped paths: what the position could not release on the spot

    /// @dev Run the queue long enough that its face value exceeds what the position can release
    ///      (the §E.4 residual), then drain it. Every seat must be debited EXACTLY what it was
    ///      paid — no more.
    ///
    ///      **MUTATION SURVIVOR, 2026-08-27.** `withdraw` debiting the REQUEST rather than the
    ///      PAYMENT survived the whole suite: the existing residual tests assert the leftover is
    ///      SMALL, and debiting too much makes it smaller. A bound in the right direction is not a
    ///      correctness assertion.
    function test_3_13_aClampedWithdrawalDebitsOnlyWhatWasPaid() public {
        _three();
        for (uint256 i; i < 40; i++) {
            _swap(i % 4 != 3, i % 4 == 3 ? 1e18 : 4e18);
        }

        address[3] memory who = [ALICE, BOB, CARL];
        bool sawAClamp;
        for (uint256 j; j < 3; j++) {
            (uint256 b0, uint256 b1) = hook.seat(j);
            vm.prank(who[j]);
            (uint256 p0, uint256 p1) = hook.withdraw(j, b0, b1);
            (uint256 a0, uint256 a1) = hook.seat(j);

            assertEq(a0, b0 - p0, "seat token0 was debited something other than what it was paid");
            assertEq(a1, b1 - p1, "seat token1 was debited something other than what it was paid");
            if (p0 < b0 || p1 < b1) sawAClamp = true;
        }
        assertTrue(sawAClamp, "nothing was ever clamped: this test proves nothing");
    }

    /// @dev The evacuation's clamped path, and the only reason `pendingWithdraw` exists at all.
    ///
    ///      **MUTATION SURVIVOR, 2026-08-27.** Every `pending` line survived the suite, because no
    ///      test had ever produced a non-zero pending balance — the whole path was dead code under
    ///      test while being asserted about in `test_3_2`.
    function test_3_14_anUnpayableEvacuationRetainsTheResidualAsPending() public {
        _three();
        for (uint256 i; i < 40; i++) {
            _swap(i % 4 != 3, i % 4 == 3 ? 1e18 : 4e18);
        }

        // Drain the two seats in front, so the position can no longer cover the third in full.
        (uint256 x0, uint256 x1) = hook.seat(0);
        vm.prank(ALICE);
        hook.withdraw(0, x0, x1);
        (x0, x1) = hook.seat(1);
        vm.prank(BOB);
        hook.withdraw(1, x0, x1);

        (uint256 b0, uint256 b1) = hook.seat(2);
        uint256 had0 = _bal(c0, CARL);
        uint256 had1 = _bal(c1, CARL);

        vm.prank(CARL);
        hook.transfer(DAVE, 2, 1);

        // The seat is empty regardless, and the rank moved.
        (uint256 n0, uint256 n1) = hook.seat(2);
        assertEq(n0 + n1, 0, "an unpayable evacuation left capital in the seat");
        assertEq(hook.ownerOf(2), DAVE, "the rank did not move");

        uint256 paid0 = _bal(c0, CARL) - had0;
        uint256 paid1 = _bal(c1, CARL) - had1;
        (uint256 w0, uint256 w1) = hook.pendingOf(CARL);

        // Nothing is lost and nothing is created: paid + retained == what the seat held.
        assertEq(paid0 + w0, b0, "token0: seller was not made whole");
        assertEq(paid1 + w1, b1, "token1: seller was not made whole");
        assertTrue(w0 != 0 || w1 != 0, "nothing was ever retained: this test proves nothing");

        // The retained claim is the SELLER's, never the buyer's.
        (uint256 d0, uint256 d1) = hook.pendingOf(DAVE);
        assertEq(d0 + d1, 0, "the buyer was credited the seller's residual");

        // And the aggregate that INVARIANT F reads agrees with the per-address books.
        (uint256 t0, uint256 t1) = hook.pendingTotals();
        assertEq(t0, w0, "pendingTotal0 disagrees with the only holder of pending token0");
        assertEq(t1, w1, "pendingTotal1 disagrees with the only holder of pending token1");

        // INVARIANT F, asserted in the ONLY state where its new term does any work:
        //     sum(q[i].aX) + pendingTotalX == redeemable X + floatX.
        // Everywhere else `pendingTotalX` is zero and the term could be deleted unnoticed.
        _checkInvariantF("with an outstanding pending claim", _bound(41));
    }

    /// @dev A retained claim is money, so it must be recoverable, guarded, and debited exactly.
    function test_3_15_pendingIsClaimableAndGuarded() public {
        _three();
        for (uint256 i; i < 40; i++) {
            _swap(i % 4 != 3, i % 4 == 3 ? 1e18 : 4e18);
        }
        (uint256 x0, uint256 x1) = hook.seat(0);
        vm.prank(ALICE);
        hook.withdraw(0, x0, x1);
        (x0, x1) = hook.seat(1);
        vm.prank(BOB);
        hook.withdraw(1, x0, x1);
        vm.prank(CARL);
        hook.transfer(DAVE, 2, 1);

        (uint256 w0, uint256 w1) = hook.pendingOf(CARL);
        assertTrue(w0 != 0 || w1 != 0, "nothing was retained: this test proves nothing");

        // Nobody may claim more than they are owed, and nobody else may claim it at all.
        vm.prank(CARL);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.OverEntitlement.selector, w0 + 1, w0));
        hook.claimPending(w0 + 1, w1);

        vm.prank(DAVE);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.OverEntitlement.selector, w0, uint256(0)));
        hook.claimPending(w0, 0);

        // The new holder funds the seat, which refills the float the claim will be paid from.
        _addTo(DAVE, 2, 900e18, 225e18);

        uint256 had0 = _bal(c0, CARL);
        uint256 had1 = _bal(c1, CARL);
        vm.prank(CARL);
        (uint256 p0, uint256 p1) = hook.claimPending(w0, w1);

        assertEq(_bal(c0, CARL) - had0, p0, "claimPending did not send what it reported (token0)");
        assertEq(_bal(c1, CARL) - had1, p1, "claimPending did not send what it reported (token1)");
        assertEq(p0, w0, "the whole token0 claim should have been payable once the float refilled");
        assertEq(p1, w1, "the whole token1 claim should have been payable once the float refilled");

        (uint256 r0, uint256 r1) = hook.pendingOf(CARL);
        assertEq(r0, w0 - p0, "pending token0 was debited something other than what was paid");
        assertEq(r1, w1 - p1, "pending token1 was debited something other than what was paid");
        (uint256 t0, uint256 t1) = hook.pendingTotals();
        assertEq(t0, r0, "pendingTotal0 drifted from the per-address book");
        assertEq(t1, r1, "pendingTotal1 drifted from the per-address book");

        _checkInvariantF("after the claim", _bound(41));
    }

    /// @dev Trading PURE RANK is the product's headline operation, and it must not open the
    ///      position at all. The STRUCTURAL half of that claim lives here; the COST half moved to
    ///      `Gas.t.sol` in Phase 5.
    ///
    ///      It moved because it was measured wrongly here. This suite builds its roster inside the
    ///      test body, which makes every subsequent `SSTORE` a 100-gas write to a slot the same
    ///      transaction already dirtied rather than the 2,900 or 20,000 a real one pays.
    ///      `vm.cool()` does not correct it — it resets the EIP-2929 access list, not the value
    ///      EIP-2200 meters a write against. `GasTest.test_5_2` builds the same state in `setUp()`
    ///      and measures 23,208 gas against a mutant's 29,603.
    function test_3_16_transferringAnEmptySeatDoesNotOpenThePosition() public {
        _three();
        (uint256 a0, uint256 a1) = hook.seat(0);
        vm.prank(ALICE);
        hook.withdraw(0, a0, a1);

        uint128 liqBefore = hook.positionLiquidity();
        (uint256 f0, uint256 f1) = hook.floats();

        (uint256 e0, uint256 e1) = hook.seat(0);
        assertTrue(e0 == 0 && e1 == 0, "the seat is not empty: this test proves nothing");

        vm.prank(ALICE);
        hook.transfer(DAVE, 0, 1);

        assertEq(hook.positionLiquidity(), liqBefore, "a pure-rank transfer moved the position");
        (uint256 g0, uint256 g1) = hook.floats();
        assertEq(g0, f0, "a pure-rank transfer moved float0");
        assertEq(g1, f1, "a pure-rank transfer moved float1");
        assertEq(hook.ownerOf(0), DAVE, "the rank did not move");
    }
}
