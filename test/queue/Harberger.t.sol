// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueSeats} from "../../src/queue/QueueSeats.sol";
import {Rent} from "../../src/queue/libraries/Rent.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Allocation} from "../../src/queue/libraries/Allocation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {stdError} from "forge-std/StdError.sol";

// =========================================================================== the negative controls
//
// Each one is production with exactly ONE rule changed, run through the IDENTICAL fixture. A
// control that fails for an unrelated reason proves nothing (LAW 2), so every one of them below is
// paired with the production run of the same scenario in the same test.

/// @dev CONTROL 4.9a — settlement that CREDITS the recipients without DEBITING the payer. Every
///      seat's ledger still looks plausible; what breaks is that the hook is now promising more
///      currency0 than it holds.
contract SettleWithoutChargingHook is QueueHarness {
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

    function _settleSeat(uint256 seatId) internal override {
        Lease storage l = lease[seatId];
        uint256 price = l.selfPrice;
        if (price == 0) return;
        uint256 elapsed = block.timestamp - l.lastSettled;
        if (elapsed == 0) return;
        uint256 due = Rent.owed(price, elapsed, RENT_BPS, RENT_PERIOD);
        uint256 esc = l.escrow;
        uint256 charged = due > esc ? esc : due;
        // THE MUTATION, and it is one line: `l.escrow = esc - charged;` is gone.
        l.lastSettled = uint64(block.timestamp);
        _distributeRent(seatId, charged);
    }
}

/// @dev CONTROL 4.9b — rent paid to the seats AHEAD. Production's loop runs `r+1 .. n-1`; this one
///      runs `0 .. r-1`, and nothing else differs. **It conserves every single wei**, which is
///      exactly why a conservation test cannot see it: the money is all still there, pointing the
///      wrong way. This is the shape of the bug that killed `HardcapHook`.
contract RentPaidAheadHook is QueueHarness {
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

    function _distributeRent(uint256 payerId, uint256 amount) internal override {
        uint256 held = unallocatedRent0;
        uint256 pot = amount + held;
        if (pot == 0) return;
        uint256 r = rankOfId(payerId);

        uint256 w;
        for (uint256 i; i < r; i++) {
            w += q[idAtRank(i)].a0;
        }
        if (w == 0) {
            escrowTotal -= amount;
            unallocatedRent0 = pot;
            return;
        }
        Allocation.State memory st = Allocation.init(pot, w);
        for (uint256 i; i < r && st.remaining > 0; i++) {
            uint256 id = idAtRank(i);
            uint256 bal = q[id].a0;
            if (bal == 0) continue;
            (, uint256 give) = Allocation.step(st, bal, 0, 0); // rent is pro-rata, never priced
            lease[id].escrow += give;
        }
        escrowTotal = escrowTotal - amount + pot;
        unallocatedRent0 = 0;
    }
}

/// @dev CONTROL 4.11 — the firm quote removed, and NOTHING else. A holder watching the mempool can
///      then reprice out of any buyout for the cost of a few seconds of rent.
contract NoFirmQuoteHook is QueueHarness {
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

    function buyPrice(uint256 seatId) public view override returns (uint256) {
        return lease[seatId].selfPrice;
    }
}

/// @dev CONTROL 4.13 — **PLAN §B.10's SPECIFIED PAYMENT SOURCE, IMPLEMENTED LITERALLY.** "Payment
///      source | Deducted from the seat's own `a0`." Everything else is production.
contract RentFromSeatCapitalHook is QueueHarness {
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

    function _settleSeat(uint256 seatId) internal override {
        Lease storage l = lease[seatId];
        uint256 price = l.selfPrice;
        if (price == 0) return;
        uint256 elapsed = block.timestamp - l.lastSettled;
        if (elapsed == 0) return;
        uint256 due = Rent.owed(price, elapsed, RENT_BPS, RENT_PERIOD);
        // THE SPEC: the seat's own currency0, not a prepaid meter.
        uint256 have = q[seatId].a0;
        bool short_ = due > have;
        uint256 charged = short_ ? have : due;
        q[seatId].a0 = _u128(have - charged);
        standing0 -= charged;
        l.lastSettled = uint64(block.timestamp);
        if (short_) {
            l.selfPrice = 0;
            _demoteToTail(seatId);
        }
    }
}

/// @dev CONTROL 4.14 — `addToSeat` without the `_settleAhead` line. It ADDS an entry point rather
///      than overriding one, so the rest of the contract under test is still exactly production.
contract NoSettleAheadHook is QueueHarness {
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

    function addToSeatNoSettle(uint256 seatId, uint256 amount0, uint256 amount1) external nonReentrant {
        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        _fundSeat(seatId, amount0, amount1);
    }
}

// ================================================================================ the attack rig

/// @dev A pool currency that hands control to an attacker exactly once, on a transfer. Not exotic:
///      `poolManager.take` -> `IERC20.transfer(hook, amount)` sits on the ordinary payout path, and
///      a buyout runs that path while the seat is mid-flight between two holders.
contract ReenteringCurrency is MockERC20 {
    address public trigger;
    bool public armed;

    constructor(string memory n, string memory sy, uint8 d) MockERC20(n, sy, d) {}

    function arm(address who) external {
        trigger = who;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool ok) {
        ok = super.transfer(to, amount);
        if (armed) {
            armed = false;
            BuyoutReentrancyAttacker(trigger).onTokenMoved();
        }
    }
}

/// @notice Holds the seat being bought, and tries to be paid for it twice — once through the
///         evacuation the buyout performs, and once through a call reentered from inside it.
contract BuyoutReentrancyAttacker {
    QueueHarness public immutable hook;
    uint256 public immutable seatId;
    bool public withdrawRefused;
    bool public resaleRefused;
    bool public reenteredAtAll;

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

    function price(uint256 p) external {
        hook.setSelfPrice(seatId, p);
    }

    /// @dev Called from inside the buyout's own payout.
    function onTokenMoved() external {
        reenteredAtAll = true;
        // (1) be paid the seat's capital a second time
        (uint256 a0, uint256 a1) = hook.seat(seatId);
        try hook.withdraw(seatId, a0, a1) {
            withdrawRefused = false;
        } catch {
            withdrawRefused = true;
        }
        // (2) sell the same seat again, to a second buyer, before the first one has it
        try hook.transfer(address(0xDEAD1), seatId, 1) {
            resaleRefused = false;
        } catch {
            resaleRefused = true;
        }
    }
}

// =========================================================================================== suite

/// @notice Phase 4 — the Harberger lease: a self-assessed price, continuous rent to the seats
///         behind, and a seat that is always for sale at its holder's own number.
///
/// This is what turns "who holds a seat" from a deployment decision into a market outcome. Three
/// separate holes close here and all three were open in the submittable Phase 3 state: the founding
/// roster was an endowment (PITFALLS 5.8), the tail had no compensation channel at all (5.19), and
/// rank-then-run was free (5.9).
contract HarbergerTest is QueueFixture {
    address constant ALICE = address(0xA11CE); // seat 0
    address constant BOB = address(0xB0B); // seat 1
    address constant CARL = address(0xCAF1); // seat 2
    address constant DAVE = address(0xDA4E); // seat 3
    address constant EVE = address(0xE5E); // the buyer
    address constant FRANK = address(0xF4A3); // a second buyer, for the boundary arms

    /// @dev The §E.4 residual bound, same derivation as the other suites: linear in swaps, never
    ///      compounding, with margin. Not a tolerance widened until the tests went green.
    function _tol(uint256 nSwaps) internal pure returns (uint256) {
        return 4 * nSwaps + 64;
    }

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        // Rent is denominated in SECONDS, so the fixture must start at a plausible wall-clock time
        // rather than at Foundry's default of 1 — otherwise `block.timestamp - lastSettled` is
        // dominated by the epoch and every elapsed-time assertion is measuring the wrong thing.
        vm.warp(1_700_000_000);
        startPrice = Constants.SQRT_PRICE_1_4;
        dec0 = 18;
        dec1 = 6; // LAW 1: non-unit price AND asymmetric decimals
        _deployTokens();
        _deployHookUnfunded(0x9101, _roster(ALICE, BOB, CARL, DAVE));
        _initPool();
    }

    /// @dev Four funded seats. The balances are deliberately not round multiples of each other, so
    ///      a pro-rata split has a real remainder to lose.
    function _four() internal {
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 60e18, 15e18);
        _addTo(CARL, 2, 137e18, 34e18);
        _addTo(DAVE, 3, 763e18, 191e18);
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _price(uint256 seatId) internal view returns (uint256 p) {
        (p,,,,) = hook.leaseOf(seatId);
    }

    function _escrow(uint256 seatId) internal view returns (uint256 e) {
        (, e,,,) = hook.leaseOf(seatId);
    }

    /// @dev Give `who` currency0 and let them prepay rent on their own seat.
    function _prepay(address who, uint256 seatId, uint256 amount) internal {
        _fund(who, amount, 0);
        vm.prank(who);
        hook.fundRent(seatId, amount);
    }

    function _setPrice(address who, uint256 seatId, uint256 p) internal {
        vm.prank(who);
        hook.setSelfPrice(seatId, p);
    }

    // ==================================================== 4.1 — rent accrues linearly in TIME

    /// @dev Against HAND-COMPUTED numbers, not against a re-implementation of the formula. At
    ///      τ = 10% per 365 days, a seat assessed at 100e18 owes exactly 10e18 in a year, 2e18 in a
    ///      fifth of one, and 1e18 in a tenth. Those three literals are the assertion; if the
    ///      contract and a fixture-side copy of the formula were both wrong, this still goes red.
    function test_4_1_rentAccruesLinearlyInTime() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);

        uint256 t0 = block.timestamp;

        vm.warp(t0 + 3_153_600); // 36.5 days == a tenth of a year
        assertEq(hook.rentDue(0), 1e18, "a tenth of a year is not a tenth of the rent");

        vm.warp(t0 + 6_307_200); // a fifth
        assertEq(hook.rentDue(0), 2e18, "rent is not linear in elapsed time");

        vm.warp(t0 + 31_536_000); // a whole year
        assertEq(hook.rentDue(0), 10e18, "a year at 10% is not 10% of the self-price");

        // ...and settling charges exactly that, from the meter and from nowhere else.
        uint256 escBefore = _escrow(0);
        (uint256 seatA0Before,) = hook.seat(0);
        hook.settleRent(0);
        assertEq(escBefore - _escrow(0), 10e18, "settlement charged something other than the rent due");
        (uint256 seatA0After,) = hook.seat(0);
        assertEq(seatA0After, seatA0Before, "rent came out of the seat's CAPITAL, not the meter");
        assertEq(hook.rentDue(0), 0, "the clock did not reset");

        _checkInvariantR("4.1");
        _checkInvariantF("4.1", _tol(0));
    }

    // ================================================== 4.2 — the split sums EXACTLY to the charge

    /// @dev **THE IDENTITY, NOT A BOUND** (PITFALLS 5.53): `Σ credited + unallocatedAfter` equals
    ///      `charged + unallocatedBefore` to the wei. The test also proves the remainder line is
    ///      LOAD-BEARING here rather than vacuous — a naive floored split of this pot is short, and
    ///      the test asserts by how much before asserting the real split is not.
    function test_4_2_rentSumsExactlyToWhatWasCharged() public {
        _four();
        // A price and an interval chosen so the charge is a prime-ish number of wei rather than
        // something that divides the weights evenly.
        _setPrice(ALICE, 0, 77_777_777_777_777_777);
        _prepay(ALICE, 0, 5e18);
        vm.warp(block.timestamp + 1_234_567);

        uint256 due = hook.rentDue(0);
        assertTrue(due != 0, "nothing accrued: this test proves nothing");

        uint256[4] memory escBefore;
        for (uint256 i; i < 4; i++) {
            escBefore[i] = _escrow(i);
        }
        (, uint256 unallocBefore) = hook.rentTotals();

        // What a FLOORED split would have handed out, computed independently here. If this equals
        // the pot, the fixture is not exercising the remainder line and the test is worthless.
        uint256 w;
        for (uint256 i = 1; i < 4; i++) {
            (uint256 a0,) = hook.seat(i);
            w += a0;
        }
        uint256 naive;
        for (uint256 i = 1; i < 4; i++) {
            (uint256 a0,) = hook.seat(i);
            naive += FullMath.mulDiv(due, a0, w);
        }
        assertLt(naive, due, "the weights divide evenly: the remainder line is not under test here");

        hook.settleRent(0);

        uint256 charged = escBefore[0] - _escrow(0);
        assertEq(charged, due, "the payer was not charged what it owed");

        uint256 credited;
        for (uint256 i = 1; i < 4; i++) {
            credited += _escrow(i) - escBefore[i];
        }
        (, uint256 unallocAfter) = hook.rentTotals();

        assertEq(credited + unallocAfter, charged + unallocBefore, "rent split does not sum to the charge");
        assertEq(unallocAfter, 0, "there were eligible recipients and the pot was still withheld");
        assertEq(credited, charged, "a wei went missing between the payer and the seats behind");
        assertGt(credited, naive, "the remainder was floored away");

        _checkInvariantR("4.2");
    }

    /// @dev The same identity as pure arithmetic, with no pool at all.
    function testFuzz_4_2_distributionSumsExactly(uint96[6] memory ws, uint96 amount) public pure {
        uint256[] memory weights = new uint256[](6);
        uint256 total;
        for (uint256 i; i < 6; i++) {
            weights[i] = ws[i];
            total += ws[i];
        }
        uint256[] memory credits = Rent.distribute(weights, amount);
        uint256 sum;
        for (uint256 i; i < 6; i++) {
            sum += credits[i];
            if (weights[i] == 0) assertEq(credits[i], 0, "a weightless seat was credited");
        }
        assertEq(sum, total == 0 ? 0 : uint256(amount), "the split did not sum to the amount");
    }

    // ============================================ 4.3 — rent with no recipient is HELD, never lost

    function test_4_3_rentWithNoRecipientIsNotLost() public {
        // Only the head holds currency0. Every seat behind it is empty of the rent currency, so
        // there is nobody the pro-rata rule can name.
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 0, 15e18);
        _addTo(CARL, 2, 0, 34e18);
        _addTo(DAVE, 3, 0, 191e18);

        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 3_153_600);

        uint256 due = hook.rentDue(0);
        uint256 escBefore = _escrow(0);
        hook.settleRent(0);

        (uint256 escrowed, uint256 held) = hook.rentTotals();
        assertEq(escBefore - _escrow(0), due, "the payer was not charged");
        assertTrue(held != 0, "nothing was withheld: this test proves nothing");
        assertEq(held, due, "the undistributable rent is not the amount charged");
        assertEq(escrowed, escBefore - due, "the withheld rent is being double-counted as escrow");
        _checkInvariantR("4.3 held");

        // Now give the tail some currency0 and settle again. The held pot is folded in and paid out
        // together with the new charge — the identity spans both settlements.
        _addTo(DAVE, 3, 500e18, 0);
        vm.warp(block.timestamp + 3_153_600);

        uint256 due2 = hook.rentDue(0);
        uint256 daveBefore = _escrow(3);
        hook.settleRent(0);

        (, uint256 heldAfter) = hook.rentTotals();
        assertEq(heldAfter, 0, "the held pot was not released to an eligible recipient");
        assertEq(_escrow(3) - daveBefore, held + due2, "the released pot did not reach the seat behind");
        _checkInvariantR("4.3 released");
    }

    // ================================================ 4.4 — a buyout transfers RANK and only rank

    function test_4_4_buyoutTransfersRankOnly() public {
        _four();
        _setPrice(ALICE, 0, 50e18);
        _prepay(ALICE, 0, 5e18);
        // One-for-zero, sized to fill seat 0 PARTIALLY: it must end holding both tokens, or the
        // "capital did not travel" assertions below hold vacuously on an empty leg.
        _swap(false, 5e18);
        _check("pre-buyout");

        (uint256 a0, uint256 a1) = hook.seat(0);
        assertTrue(a0 != 0 && a1 != 0, "the seat is empty: this test proves nothing");

        uint256 aliceC0 = _bal(c0, ALICE);
        uint256 aliceC1 = _bal(c1, ALICE);

        _fund(EVE, 50e18, 0);
        vm.prank(EVE);
        hook.buySeat(0, 50e18, 80e18);

        // The SEAT moved.
        assertEq(hook.ownerOf(0), EVE, "the seat did not change hands");

        // **THE RANK DID NOT — A PLAIN BUYOUT BUYS AN EMPTY SEAT AT THE TAIL.** The buyout empties
        // the seat, so ALICE's contributed depth leaves the pool, and rank is backed by depth
        // (PITFALLS 5.123a). A buyer who wants the RANK has to replace the depth in the same call:
        // `test_4_4b`. This is not a tax on buyers — it is the only rule that survives a SYBIL
        // buyout, where the "payment" is a wash between two addresses one person controls
        // (`Evacuation.t.sol::test_8_11`).
        assertEq(hook.rankOfId(0), 3, "A PLAIN BUYOUT OF A FUNDED SEAT KEPT ITS RANK");
        assertEq(hook.idAtRank(0), 1, "seat 1 was not promoted into the vacated front");

        // Capital did not travel either: the seat arrives EMPTY and the seller was paid.
        (uint256 n0, uint256 n1) = hook.seat(0);
        assertEq(n0, 0, "capital travelled with the rank (token0)");
        assertEq(n1, 0, "capital travelled with the rank (token1)");
        _evacuateRef(0);
        _refDemote(0);

        uint256 gotC0 = _bal(c0, ALICE) - aliceC0;
        uint256 gotC1 = _bal(c1, ALICE) - aliceC1;
        // The escrow rides out with her; the price arrives as a claim.
        assertApproxEqAbs(gotC0, a0 + 5e18, _tol(1), "the seller was not paid her capital and meter");
        assertApproxEqAbs(gotC1, a1, _tol(1), "the seller was not paid her token1");
        assertEq(_escrow(0), 0, "the prepaid meter was inherited instead of refunded");

        (uint256 p0,) = hook.pendingOf(ALICE);
        assertEq(p0, 50e18, "the sale price is not claimable by the seller");
        vm.prank(ALICE);
        hook.claimPending(50e18, 0);
        assertApproxEqAbs(_bal(c0, ALICE) - aliceC0, a0 + 5e18 + 50e18, _tol(1), "the price was not recoverable");

        // The buyer's own assessment is in force immediately — the seat is never left unpriced.
        assertEq(_price(0), 80e18, "the buyer's self-price did not apply");

        _check("post-buyout");
        _checkInvariantF("4.4", _tol(2));
        _checkInvariantR("4.4");
    }

    // ================================ 4.5 — under-pricing is punished, over-pricing is paid for

    /// @notice **A BUYOUT THAT REPLACES THE DEPTH KEEPS THE RANK.** This is the exemption that
    ///         keeps Phase 4 alive after PITFALLS 5.123(a), and it is stated directly rather than
    ///         left to be inferred from `test_4_4`'s negative.
    ///
    /// @dev Without an exemption of some kind the rank market dies: the only reason to post a
    ///      self-price above zero is to avoid being bought out, so if every buyout delivered the
    ///      tail then nobody would buy, nobody would price, no rent would accrue, and the lease
    ///      would be decoration. The exemption CANNOT be "you paid for it" — the price is self-set
    ///      and the buyout is open to anybody, so a holder buys their own seat with their own
    ///      second address and the payment is a wash (`Evacuation.t.sol::test_8_11`, the full
    ///      +267 bps edge with the rank kept). It has to be the thing rank is priority OVER: the
    ///      depth. The buyer replaces it, in the same call, or takes the tail.
    function test_4_4b_aBuyoutThatReplacesTheDepthKEEPSTheRank() public {
        _four();
        _setPrice(ALICE, 0, 50e18);
        _swap(false, 5e18); // partial fill, so the seat is not a trivial equal-legs case
        _check("pre-buyout");

        uint128 sellerDepth = hook.seatLiquidity(0);
        assertGt(sellerDepth, 0, "the seller contributed no depth: this test proves nothing");

        // **THE BUYER MUST OVERSHOOT, AND THAT IS A REAL COST OF THIS DESIGN, NOT A TEST DETAIL.**
        // What has to be matched is `seatLiquidity(0)`, and what a deposit MINTS is
        // `_liquidityForAmounts` at the LIVE price — so the seller's original amounts do not buy
        // back the seller's depth once the price has moved. Depositing exactly ALICE's 40e18/10e18
        // here lands at the tail. There is no view that hands a buyer the exact number; they size
        // it from the pool's own arithmetic and round up.
        _fund(EVE, 130e18, 30e18);
        _buyAndFundTracked(EVE, 0, 50e18, 80e18, 80e18, 20e18);

        assertEq(hook.ownerOf(0), EVE, "the seat did not change hands");
        assertEq(hook.rankOfId(0), 0, "THE FUNDED BUYOUT LOST THE RANK IT PAID FOR");
        assertEq(hook.idAtRank(0), 0, "the funded buyout reordered the queue");
        assertGe(hook.seatLiquidity(0), sellerDepth, "the buyer did not match the depth: arm is vacuous");

        // ...and the rank is real: the very next fill starts at EVE's seat.
        (uint256 before1,) = hook.seat(1);
        _swap(true, 5e18);
        (uint256 after1,) = hook.seat(1);
        assertEq(after1, before1, "the fill did not start at the seat EVE just bought and funded");

        _check("post-funded-buyout");
        _checkInvariantF("4.4b", _tol(2));
        _checkInvariantR("4.4b");
        _checkInvariantL("4.4b");
    }

    /// @notice **AND THE BOUNDARY: SHORT OF THE DEPTH IS THE TAIL.** A buyer who puts back LESS
    ///         than the seller took out is demoted exactly as an unfunded buyer is.
    ///
    /// @dev The threshold is not a constant somebody chose — it is the seller's own contributed
    ///      liquidity, so it is linear in what left, as PITFALLS 5.123 requires. Second arm: a
    ///      single-token deposit in range mints ZERO liquidity (`_liquidityForAmounts` takes the
    ///      min of the two legs), so it contributes no depth and buys no rank however large it is.
    ///      That is the same rule that closed the premium's free ride in PITFALLS 5.128, reused
    ///      rather than restated.
    function test_4_4c_aBuyoutThatUnderfundsTakesTheTail() public {
        _four();
        uint128 sellerDepth = hook.seatLiquidity(0);
        assertGt(sellerDepth, 0, "the seller contributed no depth: this test proves nothing");

        // ---- ARM 1: a real deposit, but smaller than what left.
        _fund(EVE, 4e18, 1e18);
        _buyAndFundTracked(EVE, 0, 0, 0, 4e18, 1e18);
        assertGt(hook.seatLiquidity(0), 0, "the underfunded buyout minted nothing: arm 1 is vacuous");
        assertLt(hook.seatLiquidity(0), sellerDepth, "the buyer matched the depth: arm 1 is vacuous");
        assertEq(hook.rankOfId(0), 3, "AN UNDERFUNDED BUYOUT KEPT THE RANK");
        _check("post-underfunded-buyout");

        // ---- ARM 2: a large SINGLE-TOKEN deposit, which mints no depth at all.
        uint256 id = hook.idAtRank(0);
        uint128 depth2 = hook.seatLiquidity(id);
        assertGt(depth2, 0, "the next seat contributed no depth: arm 2 is vacuous");
        _fund(FRANK, 500e18, 0);
        _buyAndFundTracked(FRANK, id, 0, 0, 500e18, 0);
        assertEq(hook.seatLiquidity(id), 0, "a single-token in-range deposit minted depth");
        assertEq(hook.rankOfId(id), 3, "A DEPOSIT THAT MINTED NO DEPTH BOUGHT A RANK");
        _check("post-single-token-buyout");
        _checkInvariantF("4.4c", _tol(2));
        _checkInvariantL("4.4c");
    }

    /// @dev `buySeatAndFund`, with the witness kept in step. Mirrors `_withdrawTracked`'s division
    ///      of labour: this keeps the ORDER model honest so `_checkOrder` and the cursor
    ///      assertions stay meaningful, while WHEN a demotion should happen is asserted directly
    ///      by the tests above and by `Evacuation.t.sol`.
    function _buyAndFundTracked(
        address buyer,
        uint256 seatId,
        uint256 maxPrice,
        uint256 newPrice,
        uint256 a0,
        uint256 a1
    ) internal {
        uint128 lBefore = hook.seatLiquidity(seatId);
        vm.prank(buyer);
        hook.buySeatAndFund(seatId, maxPrice, newPrice, a0, a1, type(uint256).max);

        // The seat was emptied and then credited the buyer's FULL deposit — what the position
        // consumed plus what became float — so the witness is re-based rather than adjusted.
        expT0 = expT0 - ref0[seatId] + a0;
        expT1 = expT1 - ref1[seatId] + a1;
        ref0[seatId] = a0;
        ref1[seatId] = a1;

        // Order matters and it is the contract's order: `_fundSeat` pulls the cursors back to the
        // seat's rank FIRST, and only then can the demotion move it.
        uint256 rank;
        for (uint256 i; i < refOrder.length; i++) {
            if (refOrder[i] == seatId) rank = i;
        }
        if (rank < refC0) refC0 = rank;
        if (rank < refC1) refC1 = rank;
        if (hook.seatLiquidity(seatId) < lBefore) _refDemote(seatId);
    }

    function test_4_5a_underpricedSeatIsBoughtOut() public {
        _four();
        // ALICE values the head at one token. Somebody else values it at more than that.
        _setPrice(ALICE, 0, 1e18);
        _prepay(ALICE, 0, 1e18);

        // EVE takes it AND puts the depth back in the same call, which is what keeps the rank she
        // is paying for. Buying without funding would hand her an empty seat at the tail — see
        // `test_4_4` for that arm, and `_settleRankOnTransfer` for why the rule is depth and not
        // payment.
        _fund(EVE, 201e18, 50e18);
        _buyAndFundTracked(EVE, 0, 1e18, 500e18, 200e18, 50e18);

        assertEq(hook.ownerOf(0), EVE, "the under-priced seat was not taken");
        assertEq(hook.rankOfId(0), 0, "the funded buyout did not keep the rank it paid for");

        // And the head is worth having: the very next fill starts there and nowhere else.
        (uint256 before1,) = hook.seat(1);
        _swap(true, 50e18);
        (uint256 after1,) = hook.seat(1);
        assertEq(after1, before1, "the fill did not start at the head EVE just bought");
        _check("4.5a");
    }

    function test_4_5b_overpricedSeatPaysForIt() public {
        _four();
        // 1000e18 for a fifth of a year at 10% is exactly 20e18 of rent.
        _setPrice(ALICE, 0, 1000e18);
        _prepay(ALICE, 0, 50e18);
        vm.warp(block.timestamp + 6_307_200);

        uint256 escBefore = _escrow(0);
        uint256 tailBefore = _escrow(1) + _escrow(2) + _escrow(3);
        hook.settleRent(0);

        assertEq(escBefore - _escrow(0), 20e18, "the over-priced holder did not pay for the assessment");
        assertEq(_escrow(1) + _escrow(2) + _escrow(3) - tailBefore, 20e18, "the tail was not compensated");
        // Nobody can take it at that price, which is the whole point of setting it: the holder buys
        // security with rent, and the tail is paid for standing aside.
        assertEq(hook.buyPrice(0), 1000e18, "the assessment is not the ask");
        _checkInvariantR("4.5b");
    }

    // ============================== 4.6 — foreclosure is a DEMOTION, and it leaves cursors correct

    function test_4_6_foreclosureMovesSeatToTailAndFixesCursors() public {
        _four();
        // Move the cursors off zero first, so a demotion has something to get wrong.
        // Big enough to drain the head of token0 outright, which is what moves cursor0 off zero.
        _swap(false, 15e18);
        _check("pre-foreclosure");
        (uint256 k0Before,) = hook.cursors();
        assertTrue(k0Before != 0, "cursor0 never moved: this test proves nothing");

        _setPrice(ALICE, 0, 1000e18);
        _prepay(ALICE, 0, 1e18); // one token of meter against 100e18/yr of rent
        (uint256 capA0, uint256 capA1) = hook.seat(0);

        vm.warp(block.timestamp + 31_536_000);
        assertGt(hook.rentDue(0), _escrow(0), "the meter still covers the bill: no foreclosure to test");

        hook.settleRent(0);
        _refDemote(0);

        // A demotion, not a seizure.
        assertEq(hook.ownerOf(0), ALICE, "foreclosure took the seat away from its holder");
        (uint256 nowA0, uint256 nowA1) = hook.seat(0);
        assertEq(nowA0, capA0, "foreclosure confiscated the seat's token0");
        assertEq(nowA1, capA1, "foreclosure confiscated the seat's token1");
        assertEq(_escrow(0), 0, "the meter was not drained to pay what it could");
        assertEq(_price(0), 0, "the self-price survived foreclosure");

        // ...to the TAIL, with everything else in order.
        assertEq(hook.rankOfId(0), 3, "the foreclosed seat is not at the back");
        assertEq(hook.idAtRank(0), 1, "the queue did not close up behind the demoted seat");
        assertEq(hook.idAtRank(1), 2, "the queue did not close up behind the demoted seat");
        assertEq(hook.idAtRank(2), 3, "the queue did not close up behind the demoted seat");

        _checkInvariantC("post-foreclosure");
        _checkInvariantR("4.6");
        _checkInvariantF("4.6", _tol(1));

        // And the queue is still a queue: the next fill follows the NEW order.
        _swap(true, 120e18);
        _check("post-foreclosure fill");
    }

    /// @dev The property the whole id/rank split exists for: the allocator walks RANKS. Before
    ///      Phase 4 the two numbers were the same and nothing could tell them apart.
    function test_4_16_allocatorFollowsRankNotSeatId() public {
        _four();
        _setPrice(ALICE, 0, 1000e18);
        _prepay(ALICE, 0, 1e18);
        vm.warp(block.timestamp + 31_536_000);
        hook.settleRent(0);
        _refDemote(0);
        assertEq(hook.idAtRank(0), 1, "seat 1 is not the new head");

        // Seat 0 still holds its capital and is now LAST. A fill must not touch it while seat 1 —
        // the new head — still has token1 to give.
        (uint256 s0Before,) = hook.seat(0);
        (uint256 s1Before,) = hook.seat(1);
        _swap(true, 40e18);

        (uint256 s0After,) = hook.seat(0);
        (uint256 s1After,) = hook.seat(1);
        assertEq(s0After, s0Before, "the demoted seat was filled as though it were still the head");
        assertGt(s1After, s1Before, "the new head was not filled first");
        _check("4.16");
    }

    // ======================================= 4.7 — RANK-THEN-RUN, the phase's headline result

    /// @notice **THE HEADLINE.** Under plain transferable rank, holding the front costs NOTHING, so
    ///         the front seat is a free option: fund it while flow looks benign, empty it before an
    ///         event, refund it afterwards, and keep the rank throughout. Harberger removes the free
    ///         half. You cannot leave your slot — you can only lower your assessment and pay rent on
    ///         it, and lowering it far enough to stop paying is how you lose the seat.
    ///
    /// @dev Both variants run side by side in ONE test, on the same fixture, because the claim is
    ///      comparative. "Plain rank" is not a different contract: it is THIS contract with the seat
    ///      left unpriced, which is exactly what Phase 3 shipped.
    function test_4_7_rankThenRunClosedUnderHarbergerOpenUnderPlainRank() public {
        _four();

        // ---- ARM 1: PLAIN RANK. No self-price, therefore no rent. The abandonment sequence.
        (uint256 a0, uint256 a1) = hook.seat(0);
        // Mint and approve up front: the measurement below is of ALICE's own money, and the
        // fixture's funding helper mints, which would read as a refund she never received.
        _fund(ALICE, a0, a1);
        uint256 spentBefore = _bal(c0, ALICE);

        vm.prank(ALICE);
        hook.withdraw(0, a0, a1); // run: the capital leaves before the event
        vm.warp(block.timestamp + 30 days);
        vm.prank(ALICE);
        hook.addToSeat(0, a0, a1); // ...and comes back after it

        // **THIS ARM WAS REWRITTEN 2026-09-02, AND WHAT IT USED TO ASSERT WAS THE BUG.**
        //
        // It read `assertEq(hook.rankOfId(0), 0, "the abandonment cost the holder their place")` —
        // i.e. it asserted, as the correct behaviour, that a holder can take their capital out of
        // the front of the queue, sit out whatever they were afraid of, put it back, and still be
        // standing at the front. That is `test/queue/Evacuation.t.sol`'s attack, written down as an
        // expectation. `withdraw` now demotes, so the abandonment costs the RANK.
        //
        // **AND THE MONEY STILL COSTS NOTHING, WHICH IS THE POINT OF KEEPING THIS ARM.** The two
        // assertions below are unchanged and still pass: no rent, no residual beyond §E.4. That is
        // exactly why rank had to be the charge — see arm 2's note.
        assertEq(hook.ownerOf(0), ALICE, "the abandonment took the seat, not just the place");
        assertEq(hook.rankOfId(0), 3, "THE ABANDONMENT KEPT THE RANK: the evacuation attack is open");
        assertEq(hook.idAtRank(0), 1, "seat 1 was not promoted into the vacated front");
        assertApproxEqAbs(_bal(c0, ALICE), spentBefore, _tol(2), "plain rank: abandonment was not free");
        assertEq(hook.rentDue(0), 0, "plain rank: an unpriced seat somehow owes rent");

        // ---- ARM 2: HARBERGER, PRICED. The same sequence now has a meter running through it.
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        uint256 escStart = _escrow(0);

        (a0, a1) = hook.seat(0);
        vm.prank(ALICE);
        hook.withdraw(0, a0, a1);
        vm.warp(block.timestamp + 30 days);
        hook.settleRent(0);

        // **WHAT THIS ARM DOES AND DOES NOT PROVE — READ THIS BEFORE CITING IT.** The bill below is
        // proportional to `elapsed`, and `elapsed` here is thirty days because of the warp three
        // lines up. Rent is a time integral (`Rent.owed`, and `_settleSeat` returns on
        // `elapsed == 0`), so this arm says NOTHING about an abandonment that lasts no time at all:
        // the same seat at the same price, evacuated and refilled in ONE transaction, is charged
        // exactly zero (`test/queue/Evacuation.t.sol::test_8_5`). Harberger prices a holder who is
        // absent for a while; it cannot see one who is absent for no time. Reading this arm as
        // closing the whole class is what PITFALLS 5.9 did, and it was wrong — see 5.87.

        uint256 rentPaid = escStart - _escrow(0);
        // 100e18 at 10%/yr for 30 days, exactly.
        assertEq(
            rentPaid,
            (uint256(100e18) * 1000 * 30 days) / (10_000 * uint256(365 days)),
            "the abandonment window was free"
        );
        assertTrue(rentPaid != 0, "no rent accrued: this test proves nothing");
        assertEq(hook.ownerOf(0), ALICE, "she paid and still lost the seat");

        // ---- ARM 3: HARBERGER, UNPRICED. The only way to dodge arm 2's bill is to stop asserting
        // the seat is worth anything — and an unpriced seat is free for anyone to take.
        _setPrice(ALICE, 0, 0);
        vm.warp(block.timestamp + FIRM_WINDOW + 1);
        assertEq(hook.buyPrice(0), 0, "an unpriced seat is not free to take");
        vm.prank(EVE);
        hook.buySeat(0, 0, 10e18);
        assertEq(hook.ownerOf(0), EVE, "the rent dodger kept the front seat anyway");

        // The result, stated once: under plain rank the sequence costs 0 and keeps the rank; under
        // Harberger it costs rent, or it costs the rank.
    }

    // ================================================ 4.8 — no oracle, no collateral, no liquidation

    /// @dev A review assertion, executed rather than promised. It reads the shipping source, strips
    ///      the comments (which DO discuss oracles and liquidation, at length, in order to say the
    ///      code has none) and searches what is left. §B.10's warning is that a Harberger design
    ///      drifts into a margin engine; a prior candidate here died of exactly that.
    function test_4_8_noOracleNoCollateralNoLiquidation() public view {
        string[4] memory files = [
            "src/queue/QueueHook.sol",
            "src/queue/QueueSeats.sol",
            "src/queue/libraries/Rent.sol",
            "src/queue/libraries/Allocation.sol"
        ];
        string[8] memory banned =
            ["oracle", "collateral", "liquidat", "healthfactor", "latestanswer", "chainlink", "twap", "donate"];

        bool sawCode;
        for (uint256 f; f < files.length; f++) {
            bytes memory src = bytes(vm.readFile(files[f]));
            bytes memory code = _lower(_stripComments(src));
            assertLt(code.length, src.length, "nothing was stripped: this test proves nothing");
            for (uint256 b; b < banned.length; b++) {
                assertFalse(
                    _contains(code, bytes(banned[b])),
                    string.concat(files[f], " contains forbidden machinery: ", banned[b])
                );
            }
            if (_contains(code, bytes("selfprice"))) sawCode = true;
        }
        // Positive control: the stripper left real code behind, so the absences above mean something.
        assertTrue(sawCode, "the comment stripper removed the code as well: this test proves nothing");
    }

    // ========================================================== 4.9 — the two mandatory controls

    /// @dev CONTROL: settle that credits without charging. It conserves nothing, and INVARIANT R is
    ///      the assertion that sees it — the hook is suddenly promising more currency0 than it holds.
    ///      Production runs the identical scenario first, so the control cannot pass for an
    ///      unrelated reason.
    function test_4_9a_negativeControl_settleWithoutCharging() public {
        // Production.
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 30 days);
        hook.settleRent(0);
        _checkInvariantR("4.9a production");
        (uint256 escrowed,) = hook.rentTotals();
        assertEq(escrowed, 20e18, "production moved rent OUT of the escrow pot");

        // The variant, identical sequence.
        _mutantRig("Harberger.t.sol:SettleWithoutChargingHook", 0x9111);
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 30 days);
        uint256 due = hook.rentDue(0);
        assertTrue(due != 0, "nothing accrued on the variant: this test proves nothing");
        hook.settleRent(0);

        (uint256 esc,) = hook.rentTotals();
        // **THE AGGREGATE STAYS RIGHT.** `escrowTotal` is debited by the distribution either way, so
        // the currency0 balance identity is perfectly happy and sees nothing. What breaks is the
        // aggregate against the SUM it claims to be — which is the line INVARIANT R only has because
        // a rule kept in two places has been wrong four times on this project.
        assertEq(esc, 20e18, "the aggregate moved: this is not the defect under test");
        assertEq(_sumEscrows() - esc, due, "the variant did not over-credit: the mutation did not take");

        // And the consequence, executed rather than described: the seats now collectively own more
        // prepaid rent than exists, so somebody's withdrawal cannot be paid.
        vm.prank(ALICE);
        hook.withdrawRent(0, 20e18); // the payer takes back a meter it never spent
        uint256 bobHas = _escrow(1);
        assertTrue(bobHas != 0, "seat 1 was credited nothing: this test proves nothing");
        vm.prank(BOB);
        vm.expectRevert(stdError.arithmeticError);
        hook.withdrawRent(1, bobHas);
    }

    /// @dev CONTROL: rent paid to the seats AHEAD. **It conserves every wei** — `escrowTotal` is
    ///      identical and INVARIANT R is perfectly happy — which is precisely why the assertion has
    ///      to name the DIRECTION rather than the total.
    function test_4_9b_negativeControl_rentPaidToSeatsAhead() public {
        // Production: seat 2 pays, and the money moves BACKWARD to seat 3.
        _four();
        _setPrice(CARL, 2, 100e18);
        _prepay(CARL, 2, 20e18);
        vm.warp(block.timestamp + 30 days);
        uint256 aheadBefore = _escrow(0) + _escrow(1);
        uint256 behindBefore = _escrow(3);
        uint256 due = hook.rentDue(2);
        hook.settleRent(2);
        assertEq(_escrow(3) - behindBefore, due, "production did not pay the seat behind");
        assertEq(_escrow(0) + _escrow(1), aheadBefore, "production paid a seat ahead");

        // The variant, identical sequence.
        _mutantRig("Harberger.t.sol:RentPaidAheadHook", 0x9112);
        _four();
        _setPrice(CARL, 2, 100e18);
        _prepay(CARL, 2, 20e18);
        vm.warp(block.timestamp + 30 days);
        aheadBefore = _escrow(0) + _escrow(1);
        behindBefore = _escrow(3);
        due = hook.rentDue(2);
        assertTrue(due != 0, "nothing accrued on the variant: this test proves nothing");
        hook.settleRent(2);

        assertEq(_escrow(0) + _escrow(1) - aheadBefore, due, "the inversion did not take");
        assertEq(_escrow(3), behindBefore, "the seat behind was paid on the inverted variant");
        // ...and the thing that makes this dangerous: nothing else notices.
        _checkInvariantR("4.9b variant conserves anyway");
    }

    // ================================================== 4.10 — a reentrant currency during a buyout

    /// @dev The buyout runs the payout path, which calls `IERC20.transfer` on a pool currency and
    ///      hands it control mid-flight. PoolManager's own lock does not close that window
    ///      (PITFALLS 5.55). `nonReentrant` does.
    function test_4_10_reentrantCurrencyDuringBuyout() public {
        (BuyoutReentrancyAttacker atk, uint256 seatC0, uint256 seatC1) = _buyoutRig(0x9113);

        uint256 atkC0 = _bal(c0, address(atk));
        uint256 atkC1 = _bal(c1, address(atk));

        _fund(EVE, 30e18, 0);
        vm.prank(EVE);
        hook.buySeat(0, 30e18, 5e18);

        assertTrue(atk.reenteredAtAll(), "the currency never got control: this test proves nothing");
        assertTrue(atk.withdrawRefused(), "a reentrant withdrawal was allowed during a buyout");
        assertTrue(atk.resaleRefused(), "the seat was sold twice out of one buyout");

        // The seat moved exactly once, and arrived empty.
        assertEq(hook.ownerOf(0), EVE, "the buyout did not complete");
        (uint256 n0, uint256 n1) = hook.seat(0);
        assertEq(n0, 0, "the seat did not arrive empty");
        assertEq(n1, 0, "the seat did not arrive empty");

        // The seller was paid its capital ONCE. Not twice.
        uint256 got0 = _bal(c0, address(atk)) - atkC0;
        uint256 got1 = _bal(c1, address(atk)) - atkC1;
        assertApproxEqAbs(got0, seatC0, _tol(1), "the seller was paid token0 more than once");
        assertApproxEqAbs(got1, seatC1, _tol(1), "the seller was paid token1 more than once");
        (uint256 p0,) = hook.pendingOf(address(atk));
        assertEq(p0, 30e18, "the sale price is not exactly once claimable");
        _checkInvariantR("4.10");
    }

    // ============================== 4.11 — the firm quote, and the reactive raise it defeats

    /// @dev **WITHOUT THIS, HARBERGER DELIVERS NOTHING BUT A TAX.** A holder watching the mempool
    ///      raises the price out from under any buyer, for the cost of a few seconds of rent. The
    ///      control is production with `buyPrice` reduced to `selfPrice`, and nothing else.
    function test_4_11_firmQuoteDefeatsTheReactiveRaise() public {
        // Production: ALICE asks 10e18, sees EVE coming, and raises to 1000e18 first.
        _four();
        _setPrice(ALICE, 0, 10e18);
        _prepay(ALICE, 0, 5e18);
        _setPrice(ALICE, 0, 1000e18); // the front-run

        assertEq(_price(0), 1000e18, "the raise did not take effect for RENT");
        assertEq(hook.buyPrice(0), 10e18, "the raise took effect for the SALE as well");

        _fund(EVE, 10e18, 0);
        vm.prank(EVE);
        hook.buySeat(0, 10e18, 20e18); // lands anyway, at the old number
        assertEq(hook.ownerOf(0), EVE, "the reactive raise vetoed the buyout");

        // The variant: the same front-run, with the firm quote removed.
        _mutantRig("Harberger.t.sol:NoFirmQuoteHook", 0x9114);
        _four();
        _setPrice(ALICE, 0, 10e18);
        _prepay(ALICE, 0, 5e18);
        _setPrice(ALICE, 0, 1000e18);
        assertEq(hook.buyPrice(0), 1000e18, "the mutation did not take");

        _fund(EVE, 10e18, 0);
        vm.prank(EVE);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.PriceAboveMax.selector, uint256(1000e18), uint256(10e18)));
        hook.buySeat(0, 10e18, 20e18);
        assertEq(hook.ownerOf(0), ALICE, "the variant somehow still sold the seat");
    }

    /// @dev The two remaining ways out of a firm quote, and why neither is worth taking: both leave
    ///      the seat quoted at ZERO for the whole window.
    function test_4_12_theOtherTwoDodgesAreSelfDestructive() public {
        _four();
        _setPrice(ALICE, 0, 10e18);
        _prepay(ALICE, 0, 5e18);
        vm.warp(block.timestamp + FIRM_WINDOW + 1); // let the arming settle, so 10e18 is the live ask
        assertEq(hook.buyPrice(0), 10e18, "the ask is not live: this test proves nothing");

        // DODGE A — drop to zero and re-raise, atomically. The window keeps the MINIMUM.
        vm.startPrank(ALICE);
        hook.setSelfPrice(0, 0);
        hook.setSelfPrice(0, 1000e18);
        vm.stopPrank();
        assertEq(_price(0), 1000e18, "the raise did not take");
        assertEq(hook.buyPrice(0), 0, "dropping to zero did not make the seat free");

        _fund(EVE, 1, 0);
        vm.prank(EVE);
        hook.buySeat(0, 0, 50e18);
        assertEq(hook.ownerOf(0), EVE, "the atomic re-raise dodge worked");

        // DODGE B — hand the seat to your own second address for a clean slate.
        address eve2 = address(0xE5E2);
        vm.warp(block.timestamp + FIRM_WINDOW + 1);
        assertEq(hook.buyPrice(0), 50e18, "the new holder's ask is not live");
        vm.prank(EVE);
        hook.transfer(eve2, 0, 1);
        vm.prank(eve2);
        hook.setSelfPrice(0, 9999e18);
        assertEq(hook.buyPrice(0), 0, "a self-transfer bought a clean slate");

        _fund(CARL, 1, 0);
        vm.prank(CARL);
        hook.buySeat(0, 0, 1e18);
        assertEq(hook.ownerOf(0), CARL, "the self-transfer dodge worked");
    }

    // ================ 4.13 — the §B.10 correction: rent cannot come out of the seat's own capital

    /// @notice **PLAN §B.10 SAID "deducted from the seat's own `a0`". BUILT LITERALLY, IT IS BROKEN.**
    ///
    /// @dev Front-first allocation drives seats to single-token composition on purpose — INVARIANT C
    ///      states it outright: every seat below `cursor0` holds `a0 == 0`. So after any run of
    ///      one-for-zero flow the FRONT seats hold exactly zero of the rent currency, and the spec
    ///      forecloses them for it. Rank would then be set by which way the market traded, which is
    ///      the one thing QUEUE claims it is not.
    ///
    ///      Both variants, same scenario, same numbers.
    function test_4_13_rentIsNotPayableFromTheSeatsOwnCapital() public {
        // Production: drive the head to zero currency0 and then charge it rent.
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        _swap(false, 15e18); // one-for-zero: the queue PAYS OUT currency0, front first

        (uint256 headA0,) = hook.seat(0);
        (uint256 k0,) = hook.cursors();
        assertEq(headA0, 0, "the head still holds currency0: this test proves nothing");
        assertTrue(k0 != 0, "the cursor never advanced: this test proves nothing");

        vm.warp(block.timestamp + 30 days);
        hook.settleRent(0);
        assertEq(hook.rankOfId(0), 0, "production demoted the head for holding the wrong token");
        assertEq(_price(0), 100e18, "production foreclosed a seat that had paid in full");
        assertGt(_escrow(0), 0, "the meter is empty: this test proves nothing");

        // The spec, run identically.
        _mutantRig("Harberger.t.sol:RentFromSeatCapitalHook", 0x9115);
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        _swap(false, 15e18);

        (headA0,) = hook.seat(0);
        assertEq(headA0, 0, "the variant's head still holds currency0: this test proves nothing");

        vm.warp(block.timestamp + 30 days);
        hook.settleRent(0);
        assertEq(hook.rankOfId(0), 3, "the spec did NOT demote the head: the finding does not reproduce");
        assertEq(_price(0), 0, "the spec did not foreclose");
        assertEq(_escrow(0), 20e18, "the spec spent the meter it was not supposed to have");
        // Twenty tokens of prepaid rent sitting untouched, and the seat demoted anyway — because the
        // market happened to trade one way.
    }

    /// @dev The second, shorter argument for the same correction: an EMPTY seat is pure rank, which
    ///      Phase 3 exists to make holdable and sellable. Under the spec it cannot be priced at all.
    function test_4_13b_pureRankIsHoldableAtAPrice() public {
        _four();
        // EMPTY THE SEAT WITHOUT WITHDRAWING. A withdrawal that pays now demotes the seat to the
        // tail, and this test is about FORECLOSURE — whether a paid-up EMPTY seat keeps its place —
        // not about what a withdrawal costs. Reaching the empty state through the buyout keeps the
        // seat at rank 0, which is what makes the assertion below non-vacuous. (Emptying it by
        // withdrawing would leave it at rank 3 before the settle even ran, and "it kept its rank"
        // would then be a statement about a seat that had already lost it.)
        vm.prank(BOB);
        hook.buySeat(0, 0, 0); // never-priced seat: free, evacuates ALICE — and costs the rank
        vm.prank(BOB);
        hook.transfer(ALICE, 0, 1); // hand the empty rank back to ALICE: EMPTY, so no demotion
        // Emptying the seat cost it its place (PITFALLS 5.123a), leaving it at the TAIL — where
        // "it kept its rank" is vacuous, because demoting the tail is a no-op (`test_8_8c`). So a
        // seat in FRONT of it is taken out through the ordinary withdrawal path, which promotes
        // this one off the tail and makes the assertion below mean something again.
        (uint256 w0, uint256 w1) = hook.seat(1);
        vm.prank(BOB);
        hook.withdraw(1, w0, w1);
        (uint256 e0, uint256 e1) = hook.seat(0);
        assertTrue(e0 == 0 && e1 == 0, "the seat is not empty: this test proves nothing");
        assertEq(hook.rankOfId(0), 2, "the setup did not leave the empty seat off the tail");
        assertLt(hook.rankOfId(0), 3, "the empty seat is at the tail: the assertion below is vacuous");

        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 30 days);
        hook.settleRent(0);
        assertEq(hook.rankOfId(0), 2, "production could not hold pure rank at a price");
        assertEq(_price(0), 100e18, "production foreclosed a paid-up empty seat");

        // The variant's rig is a FRESH, unfunded pool, so seat 0 is already empty and at rank 0 —
        // the withdrawal below moves nothing and therefore costs no rank, which is what leaves the
        // demotion assertion at the end of this arm meaningful.
        _mutantRig("Harberger.t.sol:RentFromSeatCapitalHook", 0x9116);
        (uint256 a0, uint256 a1) = hook.seat(0);
        vm.prank(ALICE);
        hook.withdraw(0, a0, a1);
        assertEq(hook.rankOfId(0), 0, "the variant's seat did not start at the front");
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 1);
        hook.settleRent(0);
        assertEq(_price(0), 0, "the spec did not foreclose an empty seat one second after pricing it");
        assertEq(hook.rankOfId(0), 3, "the spec did not demote it");
    }

    // ============================ 4.14 — a flash loan cannot capture rent it was not there for

    /// @dev The distribution weights read `a0` AT SETTLEMENT, and funding a seat is the only way a
    ///      holder can raise that number at will. `addToSeat` therefore settles every seat ahead
    ///      FIRST. Without that line the tail can deposit, poke, and withdraw in one transaction —
    ///      with borrowed money, so the share goes to almost everything.
    function test_4_14_flashLoanCannotCaptureAccruedRent() public {
        // Production.
        uint256 honest = _rentGrabAttempt(true);
        // The variant: `addToSeat` with the `_settleAhead` line removed.
        _mutantRig("Harberger.t.sol:NoSettleAheadHook", 0x9117);
        uint256 stolen = _rentGrabAttempt(false);

        emit log_named_uint("   seat 1's rent, honest weight ", honest);
        emit log_named_uint("   seat 1's rent, flash-loan grab", stolen);
        assertTrue(honest != 0, "the grabber earned nothing at all: this test proves nothing");
        assertGt(stolen, honest * 10, "the grab did not pay off: the control is not demonstrating the hole");

        // The honest number is exactly the pro-rata share at the balance BOB actually held through
        // the accrual: recipients 1/2/3 hold 60/137/763, and BOB is not the one absorbing the
        // remainder, so his share is the plain floored fraction.
        assertEq(honest, _expectedHonestShare(), "production did not pay the honest share");
    }

    /// @notice **AND THE SAME RULE AT THE SECOND ENTRY POINT CAPITAL HAS INTO A SEAT.**
    ///         `buySeatAndFund` is a deposit path, so it settles the seats ahead of it exactly as
    ///         `addToSeat` does — or it is `test_4_14`'s hole with a new front door.
    ///
    /// @dev **THIS IS THE ONE-RULE-TWO-PLACES FAMILY** (PITFALLS 5.37, 5.50, 5.52 twice, 5.73,
    ///      5.125, 5.132), asserted at the new place the same day the new place was written rather
    ///      than found by a campaign six weeks later. Removing `_settleAhead` from `_buySeat` turns
    ///      the buyer's deposit — which can be borrowed — into a claim on a pot that accrued while
    ///      they were not standing there.
    function test_4_14b_aFundedBuyoutCannotCaptureRentItWasNotThereFor() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 30 days);

        uint256 meterBefore = _escrow(0);
        assertGt(hook.rentDue(0), 0, "no rent accrued: this test proves nothing");

        // EVE takes the SMALL tail-ward seat with a borrowed-scale deposit. A seat that already
        // dominates the weights has nothing to gain, so the small one is what makes this bite.
        _fund(EVE, 100_000e18, 0);
        _buyAndFundTracked(EVE, 1, 0, 0, 100_000e18, 0);

        // The buyout drained the payer's meter BEFORE the deposit could weigh on it.
        assertLt(_escrow(0), meterBefore, "the funded buyout did not settle the seats ahead of it");

        uint256 before = _escrow(1);
        hook.settleRent(0);
        uint256 gained = _escrow(1) - before;
        emit log_named_uint("rent captured by the funded buyout", gained);
        emit log_named_uint("the honest share for that seat    ", _expectedHonestShare());
        assertLt(gained, _expectedHonestShare(), "THE FUNDED BUYOUT CAPTURED RENT IT WAS NOT THERE FOR");
    }

    /// @dev Runs the identical sequence on whichever hook is mounted. `settleAhead` picks the
    ///      production entry point or the control's one-line-lighter copy.
    function _rentGrabAttempt(bool settleAhead) internal returns (uint256 gained) {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 30 days);

        // The grabber is seat 1, which holds 60e18 of the 960e18 behind the payer — 6.25% of the
        // pot honestly. A seat that already dominates the weights has nothing to gain from a loan,
        // so choosing the SMALL tail seat is what makes the control demonstrate anything at all.
        uint256 before = _escrow(1);
        _fund(BOB, 100_000e18, 0);
        vm.startPrank(BOB);
        if (settleAhead) hook.addToSeat(1, 100_000e18, 0);
        else NoSettleAheadHook(payable(address(hook))).addToSeatNoSettle(1, 100_000e18, 0);
        hook.settleRent(0);
        vm.stopPrank();
        gained = _escrow(1) - before;
    }

    function _expectedHonestShare() internal pure returns (uint256) {
        uint256 due = (uint256(100e18) * 1000 * 30 days) / (10_000 * uint256(365 days));
        return FullMath.mulDiv(due, 60e18, uint256(60e18) + 137e18 + 763e18);
    }

    // ============================================ 4.15 — τ is a governance choice, not a constant

    /// @dev §B.10: do not defend a value of τ. Show the mechanism at several, and let the reader see
    ///      that rent is exactly linear in it — so the choice is a policy dial with a stated
    ///      trade-off (turnover pressure against the cost of holding rank), not a discovered number.
    function test_4_15_tauIsAGovernanceDialAndTheSuiteSaysSo() public {
        uint256[4] memory taus = [uint256(100), 500, 1000, 5000]; // 1%, 5%, 10%, 50% per year
        uint256 base;
        for (uint256 i; i < taus.length; i++) {
            address a = address(FLAGS ^ (uint160(0x9200 + i) << 144));
            deployCodeTo(
                "QueueHarness.sol:QueueHarness",
                _ctorArgs(_roster(ALICE, BOB, CARL, DAVE), taus[i], RENT_PERIOD, FIRM_WINDOW),
                a
            );
            hook = QueueHarness(a);
            _initPool();

            _setPrice(ALICE, 0, 1000e18);
            vm.warp(block.timestamp + 365 days);
            uint256 due = hook.rentDue(0);
            emit log_named_uint(string.concat("   tau=", vm.toString(taus[i]), "bps, one year on 1000e18"), due);

            assertEq(due, (1000e18 * taus[i]) / 10_000, "rent is not exactly tau x price x time");
            if (i == 0) base = due;
            else assertEq(due * 100, base * taus[i], "rent is not linear in tau");
        }
    }

    // ============================================================ the parameter bounds themselves

    function test_4_17_rentParametersAreValidatedAtDeployment() public {
        address[] memory r = _roster(ALICE);
        _expectCtorRevert(r, Rent.MAX_BPS + 1, RENT_PERIOD, FIRM_WINDOW, "tau above one whole period");
        _expectCtorRevert(r, RENT_BPS, 0, FIRM_WINDOW, "a zero rent period");
        _expectCtorRevert(r, RENT_BPS, 3651 days, FIRM_WINDOW, "an unpayably long rent period");
        _expectCtorRevert(r, RENT_BPS, RENT_PERIOD, 0, "a firm window of zero, which disables always-for-sale");
        _expectCtorRevert(r, RENT_BPS, RENT_PERIOD, 366 days, "a firm window that outlives any useful ask");
    }

    function test_4_18_selfPriceIsBounded() public {
        _four();
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                QueueHook.SelfPriceTooLarge.selector, uint256(type(uint128).max) + 1, uint256(type(uint128).max)
            )
        );
        hook.setSelfPrice(0, uint256(type(uint128).max) + 1);
        // The bound is not cosmetic: an unbounded price makes `Rent.owed` overflow, and a settlement
        // that reverts is a seat that can never be foreclosed OR bought — and `_settleAhead` would
        // carry that revert into every deposit behind it.
        vm.prank(ALICE);
        hook.setSelfPrice(0, type(uint128).max);
        vm.warp(block.timestamp + 3650 days);
        hook.settleRent(0); // must not revert
        assertEq(_price(0), 0, "an unfunded maximum price was not foreclosed");
    }

    // ==================================================================================== helpers

    /// @dev Mount a control variant on a fresh pool, funded exactly as production was.
    function _mutantRig(string memory artifact, uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo(artifact, _ctorArgs(_roster(ALICE, BOB, CARL, DAVE)), a);
        hook = QueueHarness(a);
        _initPool();
    }

    /// @dev `BaseHook` validates the deployment address in ITS constructor, which runs first, so a
    ///      plain `new` never reaches the rent-parameter check. Etch the code and call the
    ///      constructor at a valid hook address instead.
    function _expectCtorRevert(address[] memory roster, uint256 bps, uint256 period, uint256 window, string memory what)
        internal
    {
        address a = address(FLAGS ^ (uint160(0x9300) << 144));
        bytes memory initcode =
            abi.encodePacked(vm.getCode("QueueHarness.sol:QueueHarness"), _ctorArgs(roster, bps, period, window));
        vm.etch(a, initcode);
        (bool ok, bytes memory err) = a.call("");
        assertFalse(ok, string.concat("deployment accepted ", what));
        assertEq(
            bytes4(err), QueueHook.BadRentParameters.selector, string.concat(what, ": reverted for the WRONG reason")
        );
    }

    function _buyoutRig(uint160 nonce) internal returns (BuyoutReentrancyAttacker atk, uint256 seatC0, uint256 seatC1) {
        ReenteringCurrency evil;
        MockERC20 plain;
        for (uint256 salt; salt < 64; salt++) {
            evil = new ReenteringCurrency("Evil", "EVIL", 18);
            plain = new MockERC20("Plain", "PLN", 6);
            if (address(evil) < address(plain)) break;
        }
        require(address(evil) < address(plain), "could not order the reentering currency first");
        (c0, c1) = (Currency.wrap(address(evil)), Currency.wrap(address(plain)));

        address hookAddr = address(FLAGS ^ (nonce << 144));
        address atkAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address[] memory roster = new address[](2);
        (roster[0], roster[1]) = (atkAddr, BOB);
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(roster), hookAddr);
        hook = QueueHarness(hookAddr);
        atk = new BuyoutReentrancyAttacker(hook, 0);
        require(address(atk) == atkAddr, "attacker address prediction failed");
        _initPool();

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
        // The seat is priced so there is something to buy it AT.
        vm.prank(address(atk));
        atk.price(30e18);

        (seatC0, seatC1) = hook.seat(0);
        evil.arm(address(atk));
    }

    // ---- source inspection, for 4.8

    function _stripComments(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length);
        uint256 n;
        uint256 i;
        while (i < b.length) {
            uint256 j = i;
            while (j < b.length && b[j] != 0x0a) j++;
            uint256 s = i;
            while (s < j && (b[s] == 0x20 || b[s] == 0x09)) s++;
            bool comment = s < j && b[s] == 0x2a; // a continuation line of a block comment
            if (!comment) comment = s + 1 < j && b[s] == 0x2f && (b[s + 1] == 0x2f || b[s + 1] == 0x2a);
            if (!comment) {
                for (uint256 t = i; t < j; t++) {
                    out[n++] = b[t];
                }
                out[n++] = 0x0a;
            }
            i = j + 1;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _lower(bytes memory b) internal pure returns (bytes memory) {
        for (uint256 i; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5a) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return b;
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || hay.length < needle.length) return false;
        for (uint256 i; i + needle.length <= hay.length; i++) {
            uint256 j;
            while (j < needle.length && hay[i + j] == needle[j]) j++;
            if (j == needle.length) return true;
        }
        return false;
    }
    // =========================================================================================
    // The tests below exist because a MUTATION SURVIVED. Each one is named for the defect it was
    // written to catch, and every one of them was RED before the line it covers was put back.
    // =========================================================================================

    // ---- authorisation. Both of these were completely untested, and both are outright theft.

    function test_4_19_onlyTheHolderMayDrainTheMeter() public {
        _four();
        _prepay(ALICE, 0, 20e18);
        vm.prank(EVE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), EVE));
        hook.withdrawRent(0, 20e18);
        assertEq(_escrow(0), 20e18, "a stranger drained the meter");
    }

    function test_4_20_onlyTheHolderMaySetTheSelfPrice() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        // Left open, this is not griefing but theft: set a rival's price to zero and buy the seat.
        vm.prank(EVE);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), EVE));
        hook.setSelfPrice(0, 0);
        assertEq(hook.buyPrice(0), 100e18, "a stranger repriced someone else's seat");
    }

    function test_4_21_youCannotBuyYourOwnSeat() public {
        _four();
        _setPrice(ALICE, 0, 10e18);
        _fund(ALICE, 10e18, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.CannotBuyOwnSeat.selector, uint256(0)));
        hook.buySeat(0, 10e18, 20e18);
    }

    // ---- settlement ordering. Every one of these was a way to escape a bill that had accrued.

    /// @dev Rent must be charged at the price that was IN EFFECT. Settling after the change makes a
    ///      raise retroactive and a cut an amnesty; they do not cancel, they are two thefts.
    function test_4_22_repricingChargesTheOldPriceFirst() public {
        _four();
        _setPrice(ALICE, 0, 1e18);
        _prepay(ALICE, 0, 200e18);
        vm.warp(block.timestamp + 365 days);

        uint256 escBefore = _escrow(0);
        _setPrice(ALICE, 0, 1000e18); // a thousand-fold raise, after a year at one token
        assertEq(escBefore - _escrow(0), 0.1e18, "the year was not charged at the price it was held at");

        // ...and the new price applies from here, not before it.
        vm.warp(block.timestamp + 365 days);
        assertEq(hook.rentDue(0), 100e18, "the new price did not take effect going forward");
    }

    function test_4_23_drainingTheMeterCannotOutrunTheBill() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 365 days); // 10e18 owed

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.OverEntitlement.selector, uint256(20e18), uint256(10e18)));
        hook.withdrawRent(0, 20e18);

        vm.prank(ALICE);
        hook.withdrawRent(0, 10e18);
        assertEq(_escrow(0), 0, "the meter did not settle before it was drained");
        assertEq(_escrow(1) + _escrow(2) + _escrow(3), 10e18, "the tail was not paid what accrued");
    }

    function test_4_24_sellingASeatSettlesTheSellersRentFirst() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 365 days); // 10e18 owed

        uint256 tailBefore = _escrow(1) + _escrow(2) + _escrow(3);
        uint256 aliceBefore = _bal(c0, ALICE);
        (uint256 a0,) = hook.seat(0);
        vm.prank(ALICE);
        hook.transfer(DAVE, 0, 1);
        _evacuateRef(0);

        assertEq(_escrow(1) + _escrow(2) + _escrow(3) - tailBefore, 10e18, "the seller left without paying");
        // She is refunded the UNSPENT half of the meter, not the whole of it.
        assertApproxEqAbs(_bal(c0, ALICE) - aliceBefore, a0 + 10e18, _tol(1), "the seller was refunded rent she owed");
        _checkInvariantR("4.24");
    }

    function test_4_25_aBuyoutSettlesTheSellersRentFirst() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 365 days);

        uint256 tailBefore = _escrow(1) + _escrow(2) + _escrow(3);
        _fund(EVE, 100e18, 0);
        vm.prank(EVE);
        hook.buySeat(0, 100e18, 200e18);
        _evacuateRef(0);
        assertEq(_escrow(1) + _escrow(2) + _escrow(3) - tailBefore, 10e18, "the buyout wrote off the seller's bill");
        _checkInvariantR("4.25");
    }

    // ---- the firm quote, in the cases the first three tests did not reach

    /// @dev Inside an open window the quote is the RUNNING MINIMUM. Without that, briefly offering a
    ///      low price and then raising leaves the seat quoted at the earlier, higher number — the
    ///      holder gets to un-offer something they actually offered.
    function test_4_26_theFirmQuoteIsTheMinimumOverTheWindow() public {
        _four();
        _setPrice(ALICE, 0, 100e18); // the first assessment: nothing to honour yet
        _setPrice(ALICE, 0, 200e18); // opens a window, firm at 100e18
        assertEq(hook.buyPrice(0), 100e18, "the window did not open at the old price");

        _setPrice(ALICE, 0, 5e18); // briefly offered at five
        _setPrice(ALICE, 0, 1000e18); // ...and immediately withdrawn
        assertEq(hook.buyPrice(0), 5e18, "the holder un-offered a price they had already made");

        _fund(EVE, 5e18, 0);
        vm.prank(EVE);
        hook.buySeat(0, 5e18, 50e18);
        assertEq(hook.ownerOf(0), EVE, "the briefly-offered price was not honoured");
    }

    /// @dev A buyer is firm at WHAT THEY PAID, not at zero. Arming the window at zero would leave
    ///      every fresh buyer free to snipe for a whole window.
    function test_4_27_aBuyerIsFirmAtWhatTheyPaid() public {
        _four();
        _setPrice(ALICE, 0, 50e18);
        _fund(EVE, 50e18, 0);
        vm.prank(EVE);
        hook.buySeat(0, 50e18, 500e18);
        _evacuateRef(0);

        assertEq(_price(0), 500e18, "the buyer's assessment did not apply");
        assertEq(hook.buyPrice(0), 50e18, "the buyer is not firm at what they paid");
        vm.warp(block.timestamp + FIRM_WINDOW + 1);
        assertEq(hook.buyPrice(0), 500e18, "the window never expires");
    }

    /// @dev A new holder has made no assessment, so they owe nothing until they make one — and they
    ///      must not silently inherit a bill somebody else set.
    function test_4_28_aNewHolderDoesNotInheritTheSelfPrice() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.prank(ALICE);
        hook.transfer(DAVE, 0, 1);
        _evacuateRef(0);

        assertEq(_price(0), 0, "the new holder inherited an assessment they never made");
        vm.warp(block.timestamp + 365 days);
        assertEq(hook.rentDue(0), 0, "the new holder inherited a rent bill");
        assertEq(_escrow(0), 0, "the meter travelled with the seat instead of being refunded");
    }

    // ---- the foreclosure boundary and the held pot

    /// @dev A meter that covers the bill EXACTLY is not in arrears. Off by one in this comparison
    ///      forecloses a holder who paid in full, and it is invisible at any other balance.
    function test_4_29_aMeterThatExactlyCoversTheBillDoesNotForeclose() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 10e18); // exactly one year at 10%
        vm.warp(block.timestamp + 365 days);
        assertEq(hook.rentDue(0), _escrow(0), "the meter is not exactly level: this test proves nothing");

        hook.settleRent(0);
        assertEq(_price(0), 100e18, "a holder who paid in full was foreclosed");
        assertEq(hook.rankOfId(0), 0, "a holder who paid in full was demoted");
        assertEq(_escrow(0), 0, "the meter is not empty");

        // One second later there is nothing left to pay with, and now it does foreclose.
        vm.warp(block.timestamp + 1);
        hook.settleRent(0);
        _refDemote(0);
        assertEq(_price(0), 0, "an empty meter was not foreclosed");
        _checkInvariantC("4.29");
    }

    /// @dev Two settlements in a row with nobody eligible. The pot must ACCUMULATE, not be replaced.
    function test_4_30_theHeldPotAccumulatesAcrossSettlements() public {
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 0, 15e18);
        _addTo(CARL, 2, 0, 34e18);
        _addTo(DAVE, 3, 0, 191e18);
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);

        vm.warp(block.timestamp + 365 days);
        hook.settleRent(0);
        (, uint256 held1) = hook.rentTotals();
        assertEq(held1, 10e18, "the first charge was not held");

        vm.warp(block.timestamp + 365 days);
        hook.settleRent(0);
        (, uint256 held2) = hook.rentTotals();
        assertEq(held2, 20e18, "the held pot replaced the earlier one instead of accumulating");
        _checkInvariantR("4.30");
    }

    /// @dev An UNPRICED seat is not a payer, so settling it must do nothing at all — including not
    ///      pushing a held pot out from its rank, which would pay the wrong set of seats.
    function test_4_31_settlingAnUnpricedSeatIsANoOp() public {
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 0, 15e18);
        _addTo(CARL, 2, 0, 34e18);
        _addTo(DAVE, 3, 500e18, 191e18);
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);

        // Build a held pot: seat 3 is behind everything, so a charge from seat 3 has no recipient.
        _setPrice(DAVE, 3, 100e18);
        _prepay(DAVE, 3, 20e18);
        vm.warp(block.timestamp + 365 days);
        hook.settleRent(3);
        (, uint256 held) = hook.rentTotals();
        assertEq(held, 10e18, "no pot was held: this test proves nothing");

        // Seat 1 is unpriced. Settling it must not move the pot.
        uint256 daveBefore = _escrow(3);
        hook.settleRent(1);
        (, uint256 stillHeld) = hook.rentTotals();
        assertEq(stillHeld, held, "settling an unpriced seat paid out the held pot");
        assertEq(_escrow(3), daveBefore, "settling an unpriced seat moved money");
    }

    // ---- the order word, at a NON-ZERO seat id and a NON-ZERO rank
    //
    // Every foreclosure test above demotes SEAT 0 FROM RANK 0 — and `0 << anything` is `0`, so a
    // demotion that writes the id back at the WRONG offset is invisible there. Mutation testing
    // found that; these do not repeat the mistake.

    function test_4_32_demotingAMiddleSeatRewritesTheOrderCorrectly() public {
        _four();
        _setPrice(CARL, 2, 1000e18); // seat 2, at rank 2
        _prepay(CARL, 2, 1e18);
        vm.warp(block.timestamp + 365 days);

        uint256 tailBefore = _escrow(3);
        hook.settleRent(2);
        _refDemote(2);

        assertEq(hook.rankOfId(2), 3, "the demoted seat is not at the back");
        assertEq(hook.idAtRank(0), 0, "rank 0 was disturbed");
        assertEq(hook.idAtRank(1), 1, "rank 1 was disturbed");
        assertEq(hook.idAtRank(2), 3, "the queue did not close up");
        // ...and the rent it managed to pay went to the seat that was behind it AT THE TIME, which
        // is why the distribution runs before the demotion and not after.
        assertEq(_escrow(3) - tailBefore, 1e18, "the foreclosed seat's last payment went nowhere");
        _checkInvariantC("4.32");
        _swap(true, 120e18);
        _check("4.32 fill after a middle demotion");
    }

    /// @dev Demoting the seat that is ALREADY last must leave the order exactly as it was — at a
    ///      full roster, where the byte arithmetic runs against the top of the word.
    function test_4_33_demotingTheTailOfAFullRosterIsInert() public {
        _deployHookUnfunded(0x9401, _syntheticRoster(32));
        _initPool();
        address last = address(uint160(0x5EA700 + 31));
        _fund(last, 10e18, 0);
        vm.startPrank(last);
        hook.setSelfPrice(31, 1000e18);
        vm.stopPrank();
        _prepay(last, 31, 1e18);

        uint256 before = hook.orderWord();
        vm.warp(block.timestamp + 365 days);
        hook.settleRent(31);

        assertEq(hook.orderWord(), before, "demoting the last seat permuted the queue");
        assertEq(hook.rankOfId(31), 31, "the last seat moved");
        assertEq(hook.rankOfId(0), 0, "the head moved");
    }

    /// @dev cursor1's copy of the demotion adjustment. It exists once per direction, and this
    ///      project has shipped a direction-asymmetric rule FOUR times (PITFALLS 5.37, 5.50, 5.52).
    function test_4_34_demotionPullsCursor1Back() public {
        _four();
        _swap(true, 200e18); // zero-for-one: the queue pays out token1, front first
        (, uint256 k1) = hook.cursors();
        assertTrue(k1 != 0, "cursor1 never advanced: this test proves nothing");
        _check("4.34 pre");

        _setPrice(ALICE, 0, 1000e18);
        _prepay(ALICE, 0, 1e18);
        vm.warp(block.timestamp + 365 days);
        hook.settleRent(0);
        _refDemote(0);

        (, uint256 k1After) = hook.cursors();
        assertEq(k1After, k1 - 1, "cursor1 was not pulled back by the demotion");
        _checkInvariantC("4.34");
        _swap(true, 40e18);
        _check("4.34 fill");
    }

    /// @dev The cursor pull-back on FUNDING compares a RANK to a rank. Comparing the seat's ID
    ///      instead is invisible until a demotion has made the two different numbers — and then it
    ///      leaves a cursor LEADING a funded seat, which is silent theft of rank.
    function test_4_35_fundingPullsTheCursorBackByRankNotByIdCursor0() public {
        _four();
        _swap(false, 120e18); // one-for-zero: drains currency0 front-first
        (uint256 k0,) = hook.cursors();
        assertGe(k0, 3, "not enough of the queue was consumed: this test proves nothing");

        _setPrice(BOB, 1, 1000e18); // seat 1, at rank 1
        _prepay(BOB, 1, 1e18);
        vm.warp(block.timestamp + 365 days);
        hook.settleRent(1);
        _refDemote(1);
        assertEq(hook.idAtRank(1), 2, "seat 2 is not at rank 1: this test proves nothing");

        (uint256 k0After,) = hook.cursors();
        assertEq(k0After, k0 - 1, "cursor0 was not pulled back by the demotion");
        assertGt(k0After, 1, "the cursor is not ahead of rank 1: this test proves nothing");

        // Seat 2 now sits at rank 1, BELOW the cursor. Funding it must pull the cursor back to 1.
        _addTo(CARL, 2, 100e18, 0);
        (uint256 k0Final,) = hook.cursors();
        assertEq(k0Final, 1, "the cursor was pulled back by seat ID rather than by rank");
        _checkInvariantC("4.35");
        _swap(false, 20e18);
        _check("4.35 fill");
    }

    function test_4_36_fundingPullsTheCursorBackByRankNotByIdCursor1() public {
        _four();
        _swap(true, 400e18); // zero-for-one: drains currency1 front-first
        (, uint256 k1) = hook.cursors();
        assertGe(k1, 3, "not enough of the queue was consumed: this test proves nothing");

        _setPrice(BOB, 1, 1000e18);
        _prepay(BOB, 1, 1e18);
        vm.warp(block.timestamp + 365 days);
        hook.settleRent(1);
        _refDemote(1);
        assertEq(hook.idAtRank(1), 2, "seat 2 is not at rank 1: this test proves nothing");

        (, uint256 k1After) = hook.cursors();
        assertGt(k1After, 1, "the cursor is not ahead of rank 1: this test proves nothing");

        _addTo(CARL, 2, 0, 100e18);
        (, uint256 k1Final) = hook.cursors();
        assertEq(k1Final, 1, "cursor1 was pulled back by seat ID rather than by rank");
        _checkInvariantC("4.36");
        _swap(true, 40e18);
        _check("4.36 fill");
    }

    /// @dev The degenerate fill (`amtOut == 0`) resolves its seat through the order word too. It is
    ///      the one place in `afterSwap` outside the allocator loop that indexes the queue.
    function test_4_37_theDegenerateFillFollowsRankAfterADemotion() public {
        _four();
        _setPrice(ALICE, 0, 1000e18);
        _prepay(ALICE, 0, 1e18);
        vm.warp(block.timestamp + 365 days);
        hook.settleRent(0);
        _refDemote(0);
        assertEq(hook.idAtRank(0), 1, "seat 1 is not the head: this test proves nothing");

        // A swap so small the pool pays nothing out: the whole input is credited to the seat the
        // fill WOULD have started at, which is a RANK.
        (uint256 s0Before,) = hook.seat(0);
        (uint256 s1Before,) = hook.seat(1);
        _swap(true, 2);
        (uint256 s0After,) = hook.seat(0);
        (uint256 s1After,) = hook.seat(1);
        assertTrue(s1After != s1Before || s0After != s0Before, "no degenerate fill happened: this test proves nothing");
        assertEq(s0After, s0Before, "the degenerate fill credited the demoted seat");
        _check("4.37");
    }

    /// @dev `_settleAhead` walks RANKS while the settlements it performs can PERMUTE them. If it
    ///      does not compensate, a demotion makes it skip the seat that slid into the vacated rank.
    function test_4_38_settleAheadSurvivesADemotionMidLoop() public {
        _four();
        // Two foreclosable seats in front of the one being funded.
        _setPrice(ALICE, 0, 1000e18);
        _prepay(ALICE, 0, 1e18);
        _setPrice(BOB, 1, 1000e18);
        _prepay(BOB, 1, 2e18);
        vm.warp(block.timestamp + 365 days);

        _addTo(DAVE, 3, 10e18, 0); // settles ranks 0..2 on the way in
        _refDemote(0);
        _refDemote(1);

        assertEq(_price(0), 0, "seat 0 was not settled by the deposit");
        assertEq(_price(1), 0, "seat 1 was skipped when the loop lost its place");
        assertEq(_escrow(1), 0, "seat 1's meter was not drained");
        // Seat 0's meter is NOT zero, and that is correct: it was drained by its own foreclosure and
        // then credited again out of seat 1's, because the demotion had already put it BEHIND seat 1
        // by the time seat 1 paid.
        assertGt(_escrow(0), 0, "the demoted seat did not share in the rent of the seat it fell behind");
        // Both meters, 3e18 in total, are still in the system and are now held by whoever was
        // behind each payer AT THE MOMENT IT PAID — which for seat 1 includes seat 0, demoted past
        // it half a loop earlier. Nothing left, nothing was created.
        (uint256 escrowed, uint256 held) = hook.rentTotals();
        assertEq(escrowed + held, 3e18, "a meter went missing across two foreclosures in one loop");
        assertEq(_sumEscrows() + held, 3e18, "the aggregate disagrees with the seats");
        _checkInvariantC("4.38");
        _checkInvariantR("4.38");
    }

    /// @dev The `Foreclosed` event reports where the seat LANDED, and that field was covered by
    ///      nothing at all — an event nobody asserts on is an event that can be wrong forever.
    ///      It is the only thing an observer of this contract sees when a queue reorders.
    function test_4_39_theForeclosureEventReportsWhereTheSeatLanded() public {
        _four();
        _setPrice(CARL, 2, 1000e18);
        _prepay(CARL, 2, 1e18);
        vm.warp(block.timestamp + 365 days);

        vm.expectEmit(true, false, false, true, address(hook));
        emit QueueHook.Foreclosed(2, 100e18, 1e18, 3);
        hook.settleRent(2);
        _refDemote(2);
        _checkInvariantC("4.39");
    }

    /// @dev A buyout reads the ask AFTER settling, so a delinquent seat is foreclosed and demoted
    ///      first and the buyer pays what the seat is worth THEN. Settling only inside the transfer
    ///      instead — which still happens — leaves the buyer paying a head-of-queue price for a seat
    ///      that lands at the tail in the same transaction.
    function test_4_40_buyingADelinquentSeatSettlesItBeforePricingIt() public {
        _four();
        _setPrice(ALICE, 0, 100e18);
        // No meter at all: the bill is unpayable the moment anybody looks.
        vm.warp(block.timestamp + 365 days);
        assertGt(hook.rentDue(0), _escrow(0), "the seat is not delinquent: this test proves nothing");

        _fund(EVE, 100e18, 0);
        uint256 eveBefore = _bal(c0, EVE);
        vm.prank(EVE);
        hook.buySeat(0, 100e18, 10e18);
        _evacuateRef(0);
        _refDemote(0);

        assertEq(_bal(c0, EVE), eveBefore, "the buyer paid a head price for a seat that was already forfeit");
        assertEq(hook.ownerOf(0), EVE, "the buyout did not complete");
        assertEq(hook.rankOfId(0), 3, "the delinquent seat was not demoted before it was sold");
        _checkInvariantC("4.40");
        _checkInvariantR("4.40");
    }

    // ================================================ edges, couplings and the costs of the design

    /// @dev `order` packs one seat id per BYTE, so the roster bound and the word are the same fact.
    ///      Raising `MAX_SEATS` past 32 would silently truncate the queue's order rather than fail,
    ///      which is why the coupling is asserted here rather than left in a comment.
    ///
    /// @dev **THIS TEST WAS A TAUTOLOGY UNTIL 2026-09-02, AND IT WAS CITED IN THREE PLACES AS THE
    ///      EVIDENCE FOR A STRUCTURAL CLAIM IT DID NOT TEST.** It read, in its entirety,
    ///      `assertEq(hook.MAX_SEATS(), 32)`. Ask LAW 5's question — what would have to be true for
    ///      it to read FAIL? Only "somebody edited the constant". It asserted nothing whatsoever
    ///      about the `order` word, yet `Gas.t.sol` and `QueueSeats` both leaned on it for the
    ///      proposition that 32 is structural rather than a gas choice. A pin wearing a proof's
    ///      costume, and it is exactly why the `MAX_SEATS` argument recurred twice
    ///      (PITFALLS 5.108, 5.129, 5.144).
    ///
    ///      It now asserts the coupling itself, DERIVED from the word's width rather than restated
    ///      as a literal, in three parts:
    ///
    ///        * the bound FITS the word — `MAX_SEATS x 8 <= 256`;
    ///        * the bound USES ALL of it — one more rank would not fit. Together these two make 32
    ///          a consequence of `uint256 order` rather than a number somebody chose, and they
    ///          re-derive if the word is ever widened;
    ///        * a FULL roster actually round-trips through it — every rank readable, every byte
    ///          the id it should be. Truncation is the failure mode being guarded against, and
    ///          only executing it can catch that.
    ///
    ///      **What makes this FAIL now:** lowering `MAX_SEATS` (the second assertion), raising it
    ///      (the first), or any change that makes the order word mis-address a full roster (the
    ///      third). That last one is the one no arithmetic assertion can reach.
    function test_4_41_theRosterBoundAndTheOrderWordAreTheSameFact() public {
        uint256 max = hook.MAX_SEATS();

        // One byte per rank, and `order` is one 256-bit word.
        assertLe(max * 8, 256, "MAX_SEATS no longer fits the 32 bytes of the order word");
        assertGt((max + 1) * 8, 256, "the order word has a whole byte the roster bound does not use");

        // And the full roster really does address through it. `_syntheticRoster` mints `max` seats
        // in the identity permutation, which is what `_mintRoster` writes.
        _deployHookUnfunded(0x9441, _syntheticRoster(max));
        _initPool();
        assertEq(hook.seatCount(), max, "the bound and the roster the constructor accepted disagree");

        uint256 w = hook.orderWord();
        for (uint256 i; i < max; i++) {
            assertEq(hook.rankOfId(i), i, "a seat in a FULL roster is not at the rank it was minted to");
            assertEq((w >> (8 * i)) & 0xff, i, "the order word's byte for this rank is not the seat it holds");
        }
    }

    /// @dev A roster of one. The only seat has nobody behind it, so its rent can never be paid to
    ///      anyone and must accumulate rather than vanish; and demoting it is a no-op.
    function test_4_42_aRosterOfOne() public {
        _deployHookUnfunded(0x9402, _roster(ALICE));
        _initPool();
        _addTo(ALICE, 0, 40e18, 10e18);
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 5e18);

        vm.warp(block.timestamp + 365 days);
        hook.settleRent(0); // 10e18 due, 5e18 in the meter: foreclosed
        (uint256 escrowed, uint256 held) = hook.rentTotals();
        assertEq(held, 5e18, "the sole seat's rent went nowhere");
        assertEq(escrowed, 0, "the meter was not drained");
        assertEq(hook.rankOfId(0), 0, "demoting the only seat moved it");
        assertEq(hook.orderWord(), 0, "the order word was corrupted by a one-seat demotion");
        _checkInvariantC("4.42");
        _checkInvariantR("4.42");
        _swap(true, 20e18);
        _check("4.42 still fills");
    }

    /// @dev **A DISCLOSED PROPERTY, NOT A BUG.** Rent is `currency0` and is weighted by `currency0`,
    ///      because weighting a two-token basket needs a price and QUEUE is not allowed to have one
    ///      (§E.11). A tail that holds only `currency1` is therefore not an eligible recipient, and
    ///      the rent waits in `unallocatedRent0` until one appears.
    function test_4_43_aCurrency1OnlyTailIsNotPaidRent() public {
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 0, 15e18);
        _addTo(CARL, 2, 0, 34e18);
        _addTo(DAVE, 3, 0, 191e18);
        _setPrice(ALICE, 0, 100e18);
        _prepay(ALICE, 0, 20e18);
        vm.warp(block.timestamp + 365 days);
        hook.settleRent(0);

        assertEq(_escrow(1) + _escrow(2) + _escrow(3), 0, "a currency1-only tail was paid currency0 rent");
        (, uint256 held) = hook.rentTotals();
        assertEq(held, 10e18, "the rent was neither paid nor held");
        _checkInvariantR("4.43");
    }

    /// @dev **THE WORST-CASE DEPOSIT MEASUREMENT MOVED TO `Gas.t.sol` IN PHASE 5.** It was a pure
    ///      gas assertion built from state this suite's own test body had written, which prices
    ///      every `SSTORE` at 100 gas instead of 2,900 or 20,000 — so the 2,337,576 it reported was
    ///      never a real cost, and the 3,500,000 ceiling guarding it was guarding nothing.
    ///      `vm.cool()` does not fix that: it resets the EIP-2929 access list, not the value
    ///      EIP-2200 meters a write against.
    ///
    ///      `GasTest.test_5_6` builds the identical configuration in `setUp()` and measures
    ///      2,610,805, and it carries the same `_checkInvariantR` assertion this one did.
}
