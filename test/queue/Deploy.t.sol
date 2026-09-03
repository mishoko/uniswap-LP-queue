// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {QueueDeployBase} from "../../script/QueueDeployBase.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice PHASE 7 — the DEPLOYMENT PATH ITSELF, under test.
///
/// **WHY THIS FILE EXISTS.** Everything QUEUE proves, it proves through a fixture that reaches the
/// pool via `QueueHarness.seed()` — a TEST-ONLY entry point — or through `_initPool` with a hook
/// placed at a chosen address by `deployCodeTo`. Neither is how the contract reaches a real chain.
/// The real path is: mine a CREATE2 salt for the permission bits → deploy through the canonical
/// deterministic proxy → `PoolManager.initialize` → `addToSeat`. Until this file, **not one line of
/// that path had ever executed**, and the first execution would have been a live broadcast with a
/// judge watching. On this project a path nobody has attacked is a path nobody has tested.
///
/// So the deploy sequence lives in `script/QueueDeployBase.sol` and is executed by two callers:
/// `script/DeployQueue.s.sol` broadcasts it, and this file runs the SAME functions and asserts what
/// each step did. The only thing that forks is who signs.
contract DeployTest is BaseTest, QueueDeployBase {
    using StateLibrary for IPoolManager;

    Deployment d;
    /// @dev **THE SWEEP HAS TO BE BIG, AND THAT IS THE MECHANISM, NOT A FIXTURE CONVENIENCE.**
    ///      The queue IS the pool's liquidity, so reaching rank 2 means taking rank 0's and rank
    ///      1's whole stock of the outgoing token out of the custodied band. On a constant-product
    ///      *full-range* curve, releasing 60% of a leg needs the price to move 6.25x; the shipping
    ///      band is ±10%, so a sweep this size is how the demo shows rank-2 at all. A first draft
    ///      used 400e18 and touched exactly one seat — not because the allocator was wrong, but
    ///      because the trade was small. That is exactly the claim the README makes about the back
    ///      seat ("reached only by trades large enough to sweep the front"), measured here rather
    ///      than asserted.
    uint256 constant SWEEP_IN = 2_500e18;

    address constant DEPLOYER = address(0xD3907E5);
    address constant TAKER = address(0x7A4E5);

    /// @dev The test's implementation of the identity seam: prank where the script broadcasts.
    function _as(uint256 who) internal override {
        vm.startPrank(actor[who]);
    }

    function _stopActing() internal override {
        vm.stopPrank();
    }

    /// @dev Local by default; `DeployForkTest` overrides this to run the identical five tests
    ///      against a fork of the chain QUEUE actually deploys to.
    function _selectChain() internal virtual {}

    /// @dev The script cannot move the clock, so the rent beat is behind a seam. A no-op there,
    ///      a warp here — and the assertions about rent live on this side, where time is ours.
    function _advanceTime(uint256 s) internal virtual {
        vm.warp(block.timestamp + s);
    }

    function setUp() public virtual {
        _selectChain();
        deployArtifactsAndLabel();
        if (block.timestamp < 1_800_000_000) vm.warp(1_800_000_000); // `lastSettled` is uint64 seconds
        actor[0] = DEPLOYER;
        actor[1] = TAKER;
        vm.deal(DEPLOYER, 10 ether);
        vm.deal(TAKER, 10 ether);
    }

    // ------------------------------------------------------------------------------- the constants

    /// @dev 7.1 — THE FLAG CONSTANT IS DERIVED FROM THE CONTRACT, NOT COPIED FROM A DOCUMENT.
    ///      `PLAN.md` §H.3 carried `0x0840` — the Phase-1 permission set — long after
    ///      `afterInitialize` and `beforeAddLiquidity` were added. Mining for a stale mask produces
    ///      an address `BaseHook`'s constructor rejects, so the failure would have been a revert at
    ///      deploy time with no diagnosis attached. This asserts the two can never drift again.
    function test_7_1_flagConstantMatchesTheHooksOwnPermissions() public {
        _deploy();
        Hooks.Permissions memory p = d.hook.getHookPermissions();
        uint160 fromContract = uint160(
            (p.beforeInitialize ? Hooks.BEFORE_INITIALIZE_FLAG : 0)
                | (p.afterInitialize ? Hooks.AFTER_INITIALIZE_FLAG : 0)
                | (p.beforeAddLiquidity ? Hooks.BEFORE_ADD_LIQUIDITY_FLAG : 0)
                | (p.afterAddLiquidity ? Hooks.AFTER_ADD_LIQUIDITY_FLAG : 0)
                | (p.beforeRemoveLiquidity ? Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG : 0)
                | (p.afterRemoveLiquidity ? Hooks.AFTER_REMOVE_LIQUIDITY_FLAG : 0)
                | (p.beforeSwap ? Hooks.BEFORE_SWAP_FLAG : 0) | (p.afterSwap ? Hooks.AFTER_SWAP_FLAG : 0)
                | (p.beforeDonate ? Hooks.BEFORE_DONATE_FLAG : 0) | (p.afterDonate ? Hooks.AFTER_DONATE_FLAG : 0)
                | (p.beforeSwapReturnDelta ? Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG : 0)
                | (p.afterSwapReturnDelta ? Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG : 0)
                | (p.afterAddLiquidityReturnDelta ? Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG : 0)
                | (p.afterRemoveLiquidityReturnDelta ? Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG : 0)
        );
        assertEq(FLAGS, fromContract, "FLAGS drifted from getHookPermissions()");
        assertEq(FLAGS, 0x18C0, "the shipping permission mask is 0x18C0, not PLAN H.3's 0x0840");
    }

    /// @dev 7.2 — LAW 1 APPLIES TO THE DEMO. The pool must not open at a unit price, and the two
    ///      seeded legs must differ, or every token0/token1 mixing bug in the demo is invisible.
    function test_7_2_demoPriceIsNotUnit() public pure {
        uint160 a = _sqrtPriceX96(18, 6);
        uint160 b = _sqrtPriceX96(6, 18);
        assertTrue(a != 1 << 96, "18/6 demo price is 1:1");
        assertTrue(b != 1 << 96, "6/18 demo price is 1:1");
        assertTrue(a < (1 << 96) && b > (1 << 96), "the raw price must move with the decimals");
    }

    // ------------------------------------------------------------------------------- the deployment

    /// @dev 7.3 — the mine and the CREATE2 deploy agree, and the address really carries the flags.
    function test_7_3_minedAddressCarriesThePermissionBits() public {
        _deploy();
        assertEq(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK, FLAGS, "deployed address lacks the flag bits");
        assertGt(address(d.hook).code.length, 0, "hook has no code");
        // The pool bound to exactly the key it was built for.
        assertEq(address(d.hook), address(d.key.hooks), "hook is not the key's hook");
    }

    /// @dev 7.4 — the hook binds ONE pool and refuses the second. This is the anti-front-run
    ///      property in `_afterInitialize`, exercised on the real deployment path rather than on a
    ///      hook that was `deployCodeTo`'d into place.
    function test_7_4_theHookBindsOnePoolAndRefusesASecond() public {
        _deploy();
        // THE IDENTICAL KEY NEVER REACHES THE HOOK: `PoolManager` answers `PoolAlreadyInitialized`
        // from its own state first. The second bind that the hook itself has to refuse is a
        // DIFFERENT pool naming the same hook — a fresh fee tier is the cheapest one — and that is
        // the attack `_afterInitialize`'s guard exists for: without it, anyone could re-point a
        // deployed hook at a pool of their choosing, permanently, since there is no admin to undo
        // it. Asserted on the real CREATE2 deployment rather than on a `deployCodeTo` stand-in.
        PoolKey memory second = PoolKey({
            currency0: d.key.currency0,
            currency1: d.key.currency1,
            fee: 500,
            tickSpacing: SPACING,
            hooks: IHooks(address(d.hook))
        });
        // LAW 2 — ASSERT THE REASON, NOT MERELY THAT IT REVERTED. v4 does not let a hook's own
        // error through untouched: `Hooks.callHook` bubbles it inside `WrappedError(target,
        // selector, reason, details)`. A bare `vm.expectRevert()` here passes for `WrongPool`, for
        // an out-of-gas, and for a hook that does not exist — which is the exact defect LAW 2 was
        // written for, and which `test_2_20` and `test_2_21` were quietly carrying until Phase 7.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(d.hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(QueueHook.AlreadyBound.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(second, d.sqrtPriceX96);
    }

    /// @dev 7.9 — THE SHIPPING POSITION IS A UNISWAP RANGE, NOT THE WHOLE CURVE.
    ///      `_afterInitialize` used to set `minUsableTick`/`maxUsableTick` — full-range, ~1/200th
    ///      the depth of a ±1% v3 LP per dollar. That is not how Uniswap works and it is not how
    ///      this hook ships. The 32 seats share ONE concentrated band around the starting price.
    ///      Seats are not NFTs and they do not pick their own ticks. M69 deletes the band and this
    ///      test is what goes red.
    function test_7_9_thePositionIsABandAroundTheStartPrice() public {
        _deploy();
        (,, int24 lower, int24 upper) = d.hook.pool();
        int24 minU = TickMath.minUsableTick(SPACING);
        int24 maxU = TickMath.maxUsableTick(SPACING);
        assertGt(lower, minU, "low tick is still the usable floor: the blob is full-range");
        assertLt(upper, maxU, "high tick is still the usable ceiling: the blob is full-range");
        assertGt(upper, lower, "the band has no width");

        (uint160 sqrtP, int24 startTick,,) = poolManager.getSlot0(d.key.toId());
        assertEq(sqrtP, d.sqrtPriceX96, "the pool did not open at the demo price");
        assertTrue(startTick >= lower && startTick < upper, "the starting price is not inside the band");
        // Width is 2 * BAND_HALF_WIDTH, snapped to spacing. Floor-on-negative can shift one
        // side by one spacing, so allow ±spacing rather than demanding exact 1920.
        int24 w = upper - lower;
        int24 want = int24(2) * d.hook.BAND_HALF_WIDTH();
        assertGe(w, want - SPACING, "band is narrower than BAND_HALF_WIDTH");
        assertLe(w, want + SPACING, "band is wider than BAND_HALF_WIDTH");
    }

    /// @dev 7.8 — **THE VIEWER DECODES `pool()` BY BYTE OFFSET, SO THE LAYOUT IS PINNED HERE.**
    ///      `frontend/index.html` has no ABI library: it slices `currency0` out of word 0,
    ///      `currency1` out of word 1 and `isBound` out of word 5. That is only correct while
    ///      `PoolKey` stays a STATIC struct and is therefore encoded INLINE rather than behind an
    ///      offset pointer. Add one dynamic member to `PoolKey` upstream and every field the page
    ///      reads shifts by a word, silently — it would render a plausible-looking wrong address.
    ///      `test_7_6` checks the SELECTOR; this checks the SHAPE behind it. Reasoning about
    ///      whether a struct is static is not evidence, so this asserts the actual returndata.
    function test_7_8_thePoolViewsLayoutIsWhatTheViewerAssumes() public {
        _deploy();
        (bool ok, bytes memory ret) = address(d.hook).staticcall(abi.encodeWithSelector(QueueHook.pool.selector));
        assertTrue(ok, "pool() reverted");
        assertEq(ret.length, 8 * 32, "pool() returndata is not 8 words: PoolKey is no longer inline");

        assertEq(address(uint160(uint256(_word(ret, 0)))), Currency.unwrap(d.key.currency0), "word 0 != currency0");
        assertEq(address(uint160(uint256(_word(ret, 1)))), Currency.unwrap(d.key.currency1), "word 1 != currency1");
        assertEq(uint256(_word(ret, 2)), uint256(FEE), "word 2 != fee");
        assertEq(uint256(_word(ret, 5)), 1, "word 5 != isBound");
        (,, int24 lower,) = d.hook.pool();
        assertEq(int256(uint256(_word(ret, 6))), int256(lower), "word 6 != tickLower");
    }

    function _word(bytes memory b, uint256 i) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(b, 0x20), mul(i, 0x20)))
        }
    }

    // ----------------------------------------------------------------------------------- the demo

    /// @dev 7.5 — **THE DEMO SEQUENCE, ASSERTED BEAT BY BEAT.** This is what the video shows and
    ///      what the README transcribes, and every claim it makes on camera is an assertion here.
    function test_7_5_theDemoDoesWhatTheReadmeSaysItDoes() public {
        _deploy();
        _fundActors(d, 5_000_000e18, 20_000_000e6);

        // ---- BEAT 1: five funded seats, in the founding order.
        _fundRoster();
        uint256[] memory ids = d.hook.ranking();
        assertEq(ids.length, SEATS, "roster size");
        for (uint256 r; r < SEATS; r++) {
            assertEq(ids[r], r, "founding order is the identity permutation");
            (uint256 a0, uint256 a1) = d.hook.seat(r);
            assertTrue(a0 != 0 && a1 != 0, "a founding seat was not funded");

            // **THE 5.181 GUARD, AND IT IS THE ASSERTION THAT WAS MISSING WHEN THE HOLE SHIPPED.**
            // A never-priced seat quotes ZERO and `buySeat(id, 0, 0)` funds nothing, so it is free
            // for any stranger to take — and taking the FRONT seat evacuates the sponsor's capital,
            // drops the pool's depth and promotes whoever was second into the first-loss position.
            // Funding a roster without pricing it is therefore not "incomplete setup", it is a live
            // vulnerability, and it survived six phases because nothing here asserted otherwise.
            assertGt(d.hook.buyPrice(r), 0, "A FOUNDING SEAT IS FREE TO TAKE: PITFALLS 5.181 is live");
            (, uint256 esc,,,) = d.hook.leaseOf(r);
            assertGt(esc, 0, "a priced seat has no rent escrow: it forecloses on the first settlement");
        }

        // ...and the assessments RISE with rank, which is the Phase 12 economics made visible: the
        // deep seats are the protected ones, so they carry the dearest assessment and pay the most
        // rent FORWARD to the seats absorbing the losses. A flat schedule would assert the opposite.
        for (uint256 r = 1; r < SEATS; r++) {
            assertGt(d.hook.buyPrice(r), d.hook.buyPrice(r - 1), "the seat schedule is not rising with rank");
        }

        // ---- BEAT 2: A SMALL SWAP FILLS THE HEAD AND NOBODY ELSE. The headline claim.
        uint256[] memory before1 = _seatLeg(false);
        _swap(d, 1, true, 1e18); // zeroForOne: the pool pays out currency1, so seats give up a1
        uint256[] memory after1 = _seatLeg(false);

        assertLt(after1[0], before1[0], "the head seat did not pay out: this test proves nothing");
        for (uint256 r = 1; r < SEATS; r++) {
            assertEq(after1[r], before1[r], "a seat behind the head moved on a head-only fill");
        }

        // ---- BEAT 3: A SWEEPING SWAP WALKS THE QUEUE, IN RANK ORDER.
        before1 = _seatLeg(false);
        _swap(d, 1, true, SWEEP_IN);
        _logSeats(d, "after the sweeping swap");
        after1 = _seatLeg(false);

        uint256 walked;
        for (uint256 r; r < SEATS; r++) {
            if (after1[r] != before1[r]) walked++;
        }
        assertGt(walked, 1, "the sweep touched at most one seat: it did not sweep");
        // Front-first means EXHAUSTION IS PREFIX-SHAPED: no seat may be touched while a seat ahead
        // of it still holds any of the outgoing token. That is the ordering claim, not "some seats
        // moved".
        for (uint256 r = 1; r < SEATS; r++) {
            if (after1[r] != before1[r]) {
                assertEq(after1[r - 1], 0, "a seat was filled while the seat ahead of it still held stock");
            }
        }

        // ---- BEAT 4: A TRANSFER MOVES RANK. THE CAPITAL GOES BACK TO THE SELLER.
        (uint256 t0, uint256 t1) = d.hook.seat(4);
        assertTrue(t0 != 0 || t1 != 0, "seat 4 is empty: the transfer beat would prove nothing");
        uint256 sellerBal0 = d.token0.balanceOf(actor[0]);
        uint256 sellerBal1 = d.token1.balanceOf(actor[0]);
        // **THE UNSPENT RENT METER RIDES OUT WITH THE SELLER, AND IT IS PART OF "MADE WHOLE".**
        // `_onSeatTransfer` sends `p0 + esc` — the seat's capital plus whatever prepaid rent it had
        // not yet burned. Before Phase 12 the founding roster was UNPRICED, so every seat's escrow
        // was zero and this term was invisible; pricing the roster at BEAT 1 (PITFALLS 5.181) makes
        // it real. Settle first so `escAtSale` is what the seat actually owns at the instant of
        // sale rather than a stale figure with rent still accrued against it.
        d.hook.settleRent(4);
        (, uint256 escAtSale,,,) = d.hook.leaseOf(4);
        assertGt(escAtSale, 0, "the seat carries no meter: the escrow term below is vacuous");
        _transferSeat(d, 0, actor[1], 4);

        assertEq(d.hook.ownerOf(4), actor[1], "rank did not change hands");
        (uint256 e0, uint256 e1) = d.hook.seat(4);
        assertEq(e0, 0, "the seat kept currency0 after changing hands");
        assertEq(e1, 0, "the seat kept currency1 after changing hands");
        (uint256 pend0, uint256 pend1) = d.hook.pendingOf(actor[0]);
        // Paid on the spot where the position could release it, claimable where it could not. The
        // sum is what the seat held; splitting it between the two is the §E.4 dust policy.
        assertEq(
            d.token0.balanceOf(actor[0]) - sellerBal0 + pend0,
            t0 + escAtSale,
            "seller was not made whole in currency0 (capital + the unspent meter)"
        );
        assertEq(d.token1.balanceOf(actor[0]) - sellerBal1 + pend1, t1, "seller was not made whole in currency1");
        // **A FUNDED TRANSFER NOW COSTS THE RANK** (PITFALLS 5.123a), and seat 4 is the TAIL, so
        // the demotion is a no-op here and this assertion cannot see it either way — stated rather
        // than left to read as evidence that the rank survived. `test_8_8c` is what proves
        // demoting the tail is a no-op; `Rank.t.sol::test_3_2` is what proves a funded transfer
        // off the tail is demoted.
        assertEq(d.hook.rankOfId(4), SEATS - 1, "the transferred seat did not end at the tail");

        // ---- BEAT 5: AN UNDER-PRICED SEAT IS TAKEN AT ITS OWN NUMBER.
        uint256 ask = 100e18;
        _setSelfPrice(d, 0, 0, ask);
        assertEq(d.hook.buyPrice(0), ask, "the posted price is not the ask");

        uint256 rankBefore = d.hook.rankOfId(0);
        uint128 depthBefore = d.hook.seatLiquidity(0);
        assertGt(depthBefore, 0, "the head contributed no depth: the funded-buyout beat proves nothing");
        (uint256 was0,) = d.hook.pendingOf(actor[0]);
        // The buyer pays the ask AND replaces the depth, in one call. Without the funding the
        // buyout would deliver an EMPTY seat at the TAIL, because a change of holder evacuates the
        // seat and rank is backed by depth (PITFALLS 5.123a, `Harberger.t.sol::test_4_4`).
        _buySeatAndFund(d, 1, 0, ask, 250e18, 2_000e18, 8_000e6, 0);

        assertEq(d.hook.ownerOf(0), actor[1], "the buyout did not move the seat");
        assertGe(d.hook.seatLiquidity(0), depthBefore, "the buyer did not replace the depth: the beat is vacuous");
        assertEq(d.hook.rankOfId(0), rankBefore, "the FUNDED buyout lost the rank it paid for");
        (uint256 now0,) = d.hook.pendingOf(actor[0]);
        assertGe(now0 - was0, ask, "the seller was not credited the price they posted");

        // **AND THE BUYER CANNOT PRICE THE SEAT OUT OF REACH THE MOMENT THEY HOLD IT.** The seat
        // stays firm at what was just paid for it, for `FIRM_WINDOW`, even though the buyer's own
        // assessment is 2.5x higher. Without this, "always for sale" would mean "for sale until
        // someone actually wants it": buy at 100, mark to 250 in the same block, and every rival is
        // locked out at a price you never had to pay rent on. The self-price is what RENT is
        // charged on immediately; the firm quote is what the seat can be TAKEN at.
        (uint256 selfPrice,,,,) = d.hook.leaseOf(0);
        assertEq(selfPrice, 250e18, "the buyer's own assessment was not recorded");
        assertEq(d.hook.buyPrice(0), ask, "the buyer marked the seat up inside the firm window");

        // ---- BEAT 6: RENT ACCRUES IN ELAPSED TIME AND IS PAID BY THE BACK TO THE FRONT.
        //
        // **THE DIRECTION WAS REVERSED IN PHASE 12 AND THIS BEAT IS WHERE THE BUSINESS MODEL SHOWS
        // UP ON CAMERA.** The front seat SUPPLIES subordination — it stands in front and absorbs
        // the adverse move first — and the seats behind it CONSUME that protection. So the back
        // pays the front, the same way round as every insurance market. It used to be the other way
        // because the Harberger layer was designed when being first was believed to be the prize;
        // Phases 7-8 disproved that and nobody revisited the rent (see `_distributeRent`).
        //
        // The PAYER is therefore a seat with somebody in front of it. Rank 0's rent has no
        // recipient at all and would land in the held pot, which is correct but demonstrates
        // nothing.
        uint256 payer = d.hook.ranking()[3];
        // Settle at the OLD price first, so the meter this beat measures starts from a known
        // figure. Since BEAT 1 prices the whole roster (PITFALLS 5.181), every seat arrives here
        // already metered and already owing — this used to be a fresh, unpriced seat.
        d.hook.settleRent(payer);
        _setSelfPriceAs(payer, 250e18);
        (uint256 escPotBefore,) = d.hook.rentTotals();
        _fundRent(d, _holderIndexOf(payer), payer, 50e18);
        (uint256 escBefore,) = d.hook.rentTotals();
        // A DELTA, not an absolute: the pot holds the whole roster's meters now.
        assertEq(escBefore - escPotBefore, 50e18, "escrow did not arrive");
        assertEq(d.hook.rentDue(payer), 0, "rent accrued before any time passed");

        _advanceTime(30 days);
        // Past the window, the buyer's own number is what anyone else must pay.
        assertEq(d.hook.buyPrice(0), 250e18, "the firm quote outlived its window");

        uint256 due = d.hook.rentDue(payer);
        // τ = 10% of 250e18 per 365 days, over 30 days.
        assertEq(due, (250e18 * RENT_BPS * 30 days) / (10_000 * RENT_PERIOD), "rent is not linear in time");
        assertGt(due, 0, "no rent accrued in 30 days: this beat proves nothing");

        // **THE BUSINESS MODEL, ASSERTED.** Rent is a transfer between two kinds of LP and nothing
        // else: it never touches the position, `float0` or the allocator, so the TOTAL escrow is
        // conserved to the wei while the payer's own escrow falls by exactly what it owed. An
        // earlier draft of this test asserted that `escrowTotal` FELL, which is what a rent that
        // leaked value would do — it passed against nothing and failed against the real contract.
        uint256[] memory escAheadBefore = _escrowAhead(payer);
        (, uint256 payerEscBefore,,,) = d.hook.leaseOf(payer);

        _settle(payer);

        (, uint256 payerEscAfter,,,) = d.hook.leaseOf(payer);
        (uint256 escTotalAfter, uint256 unallocated) = d.hook.rentTotals();
        assertEq(payerEscBefore - payerEscAfter, due, "the payer was not charged exactly what was owed");
        assertEq(escTotalAfter, escBefore, "rent left the escrow pot: it must move escrow to escrow");
        assertEq(unallocated, 0, "rent was stranded while eligible recipients existed");

        uint256[] memory escAheadAfter = _escrowAhead(payer);
        uint256 received;
        for (uint256 i; i < escAheadAfter.length; i++) {
            assertGe(escAheadAfter[i], escAheadBefore[i], "a seat ahead LOST escrow to a rent payment");
            received += escAheadAfter[i] - escAheadBefore[i];
        }
        assertEq(received, due, "the seats ahead did not receive exactly what the back paid");
        // ...and the FRONT seat is one of them, which is the whole point of the reversal: the seat
        // that eats the adverse move first is the one being paid for it.
        (, uint256 headEsc,,,) = d.hook.leaseOf(d.hook.ranking()[0]);
        assertGt(headEsc, 0, "the front seat was not paid for standing in front");

        // **AND THE LIMITATION IS VISIBLE HERE TOO, NOT HIDDEN (PITFALLS 5.19).** Eligibility is
        // CONTRIBUTED DEPTH. The seat emptied by BEAT 4's transfer contributed none, so it is paid
        // NOTHING even when it stands ahead of the payer. `BUSINESS.md` §9 says so; this asserts it.
        assertEq(d.hook.seatLiquidity(4), 0, "seat 4 was expected to contribute no depth");
        (, uint256 emptyEsc,,,) = d.hook.leaseOf(4);
        assertEq(emptyEsc, 0, "a seat contributing no depth was paid depth-weighted rent");

        assertEq(d.hook.ownerOf(0), actor[1], "settlement seized a seat: foreclosure must only demote");
    }

    // --------------------------------------------------------------------------------- the plumbing

    /// @dev Every escrow balance strictly AHEAD of `seatId`, indexed by rank. Rent moves forward
    ///      since Phase 12, so these are the recipients.
    function _escrowAhead(uint256 seatId) internal view returns (uint256[] memory out) {
        uint256[] memory ids = d.hook.ranking();
        uint256 r = d.hook.rankOfId(seatId);
        out = new uint256[](r);
        for (uint256 i; i < r; i++) {
            (, uint256 esc,,,) = d.hook.leaseOf(ids[i]);
            out[i] = esc;
        }
    }

    /// @dev Which demo actor holds `seatId`. The roster is `actor[0..4]` in founding order, but a
    ///      buyout has already moved one seat by BEAT 6, so this is read rather than assumed.
    function _holderIndexOf(uint256 seatId) internal view returns (uint256) {
        address who = d.hook.ownerOf(seatId);
        for (uint256 i; i < actor.length; i++) {
            if (actor[i] == who) return i;
        }
        revert("seat is held by nobody in the demo roster");
    }

    function _setSelfPriceAs(uint256 seatId, uint256 price) internal {
        vm.prank(d.hook.ownerOf(seatId));
        d.hook.setSelfPrice(seatId, price);
    }

    function _settle(uint256 seatId) internal {
        _as(0);
        d.hook.settleRent(seatId);
        _stopActing();
    }

    /// @dev The outgoing leg of every seat, INDEXED BY RANK rather than by seat id — the ordering
    ///      claim is about ranks, and after a foreclosure the two are different numbers.
    function _seatLeg(bool leg0) internal view returns (uint256[] memory out) {
        uint256[] memory ids = d.hook.ranking();
        out = new uint256[](ids.length);
        for (uint256 r; r < ids.length; r++) {
            (uint256 a0, uint256 a1) = d.hook.seat(ids[r]);
            out[r] = leg0 ? a0 : a1;
        }
    }

    function _deploy() internal {
        (d.poolManager, d.router) = (poolManager, swapRouter);
        (d.token0, d.token1) = _deployTokens();
        d.sqrtPriceX96 = _sqrtPriceX96(d.token0.decimals(), d.token1.decimals());

        address[] memory roster = new address[](SEATS);
        roster[0] = actor[0];
        roster[1] = actor[0];
        roster[2] = actor[0];
        roster[3] = actor[0];
        roster[4] = actor[0];

        (d.hook, d.salt) =
            _deployHook(d.poolManager, Currency.wrap(address(d.token0)), Currency.wrap(address(d.token1)), roster);
        d.key = _initPool(d);
    }

    /// @dev Descending capital down the queue, so a sweep visibly exhausts seats one after another
    ///      rather than all at once. Every wei arrives through `addToSeat`, the only path
    ///      production has.
    /// @dev **DELEGATES TO THE BASE, WHICH IS THE WHOLE POINT OF `Deploy.t.sol` EXISTING.** This
    ///      used to be a second copy of the broadcast script's funding loop — so the test could
    ///      pass while the script did something else, which is precisely what PITFALLS 5.81 says a
    ///      deploy test is for. One implementation, two callers, differing only in the identity
    ///      seam (`_as` / `_stopActing`).
    function _fundRoster() internal {
        _fundAndPriceRoster(d);
    }
}
