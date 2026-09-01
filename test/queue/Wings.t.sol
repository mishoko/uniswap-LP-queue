// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {ExternalLP, LimitSwapper} from "./Controls.t.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @notice The Uniswap-native object: a paid queue on the concentrated band, ordinary Uniswap
///         LPs in the disjoint wings. Overlap is still the N5 free lane and is refused by name.
///
/// LAW 1: 1:4, 18/6. LAW 2: overlap reverts OverlappingLiquidity, not "some revert".
/// LAW 3: solvency against redeemAll of the HOOK's position, not against PoolManager's
/// whole-pool delta (that delta includes the wings).
contract WingsTest is QueueFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        dec0 = 18;
        dec1 = 6;
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
    }

    function _bps() internal pure returns (uint256[] memory bps) {
        bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
    }

    function _boot() internal {
        _deployHook(0x5706, 3);
        _openBand(_bps());
    }

    function _addWings(uint128 liq) internal returns (ExternalLP lp) {
        (,, int24 tl, int24 tu) = hook.pool();
        int24 minU = TickMath.minUsableTick(SPACING);
        int24 maxU = TickMath.maxUsableTick(SPACING);
        lp = new ExternalLP(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(lp), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(lp), 1e30);
        // Adjacent at the band edge is disjoint: Uniswap ranges are [lower, upper).
        if (tl > minU) lp.add(k, minU, tl, liq);
        if (tu < maxU) lp.add(k, tu, maxU, liq);
    }

    function _expectOverlap(int24 lower, int24 upper, string memory what) internal {
        ExternalLP lp = new ExternalLP(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(lp), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(lp), 1e30);
        (bool ok, bytes memory err) = address(lp).call(abi.encodeCall(ExternalLP.add, (k, lower, upper, LIQ)));
        assertFalse(ok, what);
        assertEq(bytes4(_unwrap(err)), QueueHook.OverlappingLiquidity.selector, string.concat(what, ": wrong reason"));
    }

    // --------------------------------------------------------------------- the guard

    /// @dev Same ticks as the band is overlap, even though the LP is "just Uniswap".
    function test_wing_sameRangeIsOverlap() public {
        _boot();
        (,, int24 tl, int24 tu) = hook.pool();
        _expectOverlap(tl, tu, "an LP at the queue's own ticks was allowed");
    }

    /// @dev Partial overlap from below.
    function test_wing_partialOverlapReverts() public {
        _boot();
        (,, int24 tl, int24 tu) = hook.pool();
        _expectOverlap(tl - SPACING, tu, "a partial overlap from below was allowed");
    }

    /// @dev Partial overlap from above. Mutate one direction only and this is what stays green.
    function test_wing_partialOverlapFromAboveReverts() public {
        _boot();
        (,, int24 tl, int24 tu) = hook.pool();
        _expectOverlap(tl, tu + SPACING, "a partial overlap from above was allowed");
    }

    /// @dev Uniswap keys positions by salt. The guard is the ticks; a salt is not a free lane.
    function test_wing_saltDoesNotBypassOverlap() public {
        _boot();
        (,, int24 tl, int24 tu) = hook.pool();
        ExternalLP lp = new ExternalLP(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(lp), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(lp), 1e30);
        (bool ok, bytes memory err) =
            address(lp).call(abi.encodeCall(ExternalLP.addWithSalt, (k, tl, tu, LIQ, bytes32(uint256(1)))));
        assertFalse(ok, "a salted position at the band ticks was allowed");
        assertEq(bytes4(_unwrap(err)), QueueHook.OverlappingLiquidity.selector, "salt bypass: wrong reason");
    }

    /// @dev Full-range still overlaps a concentrated band. M71 deletes the revert; this is
    ///      what goes red, and it is also what `test_N5_positive` covers on the full-range fixture.
    function test_wing_fullRangeOverlapsTheBand() public {
        _boot();
        _expectOverlap(TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), "full-range add was allowed");
    }

    /// @dev The product: disjoint wings mint. M71 is not this test — M71 still allows wings.
    function test_wing_disjointAddSucceeds() public {
        _boot();
        (,, int24 tl, int24 tu) = hook.pool();
        ExternalLP lp = _addWings(LIQ);
        assertTrue(address(lp).code.length != 0, "wing LP has no code");
        (uint128 lowerL,,) =
            poolManager.getPositionInfo(k.toId(), address(lp), TickMath.minUsableTick(SPACING), tl, bytes32(0));
        (uint128 upperL,,) =
            poolManager.getPositionInfo(k.toId(), address(lp), tu, TickMath.maxUsableTick(SPACING), bytes32(0));
        assertEq(lowerL, LIQ, "lower wing did not mint");
        assertEq(upperL, LIQ, "upper wing did not mint");
    }

    // --------------------------------------------------------------------- in-band vs crossing

    /// @dev A small swap stays inside the band: the queue identity still holds, and the wing's
    ///      principal does not move. This is Uniswap ticks doing the work; the clip is a no-op
    ///      on this path. Asserted so a future change that credits wings on an in-band swap is
    ///      visible here rather than only on a crossing.
    function test_wing_smallSwapDoesNotTouchWings() public {
        _boot();
        (,, int24 tl, int24 tu) = hook.pool();
        ExternalLP lp = _addWings(LIQ);
        (uint256 w0b, uint256 w1b) = _wingPrincipal(lp, TickMath.minUsableTick(SPACING), tl);
        (uint256 u0b, uint256 u1b) = _wingPrincipal(lp, tu, TickMath.maxUsableTick(SPACING));

        uint256 s0 = expT0;
        _swap(true, s0 / 500);
        _check("in-band with wings");

        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick >= tl && tick < tu, "the small swap left the band: this test proves nothing");

        (uint256 w0a, uint256 w1a) = _wingPrincipal(lp, TickMath.minUsableTick(SPACING), tl);
        (uint256 u0a, uint256 u1a) = _wingPrincipal(lp, tu, TickMath.maxUsableTick(SPACING));
        assertEq(w0a, w0b, "lower wing token0 moved on an in-band swap");
        assertEq(w1a, w1b, "lower wing token1 moved on an in-band swap");
        assertEq(u0a, u0b, "upper wing token0 moved on an in-band swap");
        assertEq(u1a, u1b, "upper wing token1 moved on an in-band swap");
    }

    /// @dev A crossing swap fills the band THEN the lower wing. The queue is credited only the
    ///      band. M70 deletes the clip and this is what goes red: the ledger is then larger than
    ///      the hook's position.
    function test_wing_crossingCreditsTheBandOnly() public {
        _boot();
        (,, int24 tl,) = hook.pool();
        _addWings(LIQ);

        uint256 s0 = expT0;
        assertTrue(s0 != 0, "nothing was seeded: this test proves nothing");

        // `_swap` attributes the WHOLE PoolManager delta to the queue. A crossing
        // fill includes the wings, so that would underflow `expT1` and poison the
        // witness. Measure the hook and the pool separately.
        (uint160 sqrtB,,,) = poolManager.getSlot0(k.toId());
        (uint256 inAmt, uint256 credited) = _swapObserved(true, s0 * 4);
        (uint160 sqrtA, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick < tl, "the swap never left the band: this test proves nothing");
        assertGt(credited, 0, "the queue was credited nothing of the band");
        assertLt(credited, inAmt, "the queue was credited the wing fill too");
        assertGt(inAmt - credited, 1e12, "the wing fill was dust: this test proves nothing");
        assertEq(credited, _replayBandIn(true, -int256(s0 * 4), sqrtB, sqrtA), "credited != independent band replay");

        _checkInvariantF("after crossing", 1e12);
        _assertSolvent();
    }

    /// @dev PositionManager is the Uniswap path. Same callback, different unlocker. Overlap
    ///      still reverts; a disjoint mint mints; a decrease unwinds.
    function test_wing_positionManagerMintAndBurn() public {
        _boot();
        (,, int24 tl,) = hook.pool();
        int24 minU = TickMath.minUsableTick(SPACING);
        uint256 id = _pmMint(minU, tl, LIQ);
        (uint128 L,,) = poolManager.getPositionInfo(k.toId(), address(positionManager), minU, tl, bytes32(id));
        assertGt(uint256(L), 0, "PositionManager did not mint the wing");

        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.pmMintOverlap, ()));
        assertFalse(ok, "PositionManager minted overlapping the band");
        assertEq(bytes4(_unwrap(err)), QueueHook.OverlappingLiquidity.selector, "PM overlap: wrong reason");

        _pmDecrease(id, uint128(L == 0 ? LIQ : L));
        (uint128 afterL,,) = poolManager.getPositionInfo(k.toId(), address(positionManager), minU, tl, bytes32(id));
        assertEq(uint256(afterL), 0, "PositionManager did not burn the wing");
    }

    function pmMintOverlap() external {
        (,, int24 tl, int24 tu) = hook.pool();
        _pmMint(tl, tu, LIQ);
    }

    // ------------------------------------------------------- the band half-width is a DEPLOY PARAM

    /// @dev `BAND_HALF_WIDTH` stopped being a contract constant and became a constructor argument,
    ///      because band width is the mechanism's main economic dial: it sets depth at the money,
    ///      and depth sets how large a swap must be to reach rank 2. A parameter nothing asserts is
    ///      a parameter that can be silently ignored, so this asserts the SNAPPED BAND, not the
    ///      stored number — the stored number agreeing with itself proves nothing.
    function test_band_halfWidthIsHonouredAndSnapped() public {
        int24 narrow = 180; // 3 spacings, deliberately not the fixture's 960
        address a = address(FLAGS ^ (uint160(0xBD01) << 144));
        deployCodeTo(
            "QueueHarness.sol:QueueHarness",
            abi.encode(
                poolManager, c0, c1, FEE, SPACING, narrow, _syntheticRoster(3), RENT_BPS, RENT_PERIOD, FIRM_WINDOW
            ),
            a
        );
        QueueHarness h = QueueHarness(a);
        assertEq(int256(h.BAND_HALF_WIDTH()), int256(narrow), "the constructor argument was not stored");

        PoolKey memory nk =
            PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(h))});
        poolManager.initialize(nk, startPrice);
        (,, int24 lo, int24 hi) = h.pool();

        // The band the hook ACTUALLY custodies is `narrow`, snapped to spacing on both sides.
        assertEq(int256(hi - lo), int256(2 * narrow), "the snapped band does not match the parameter");

        // And it is genuinely narrower than the fixture's default, which is the point of the
        // parameter existing at all. Without this the test would pass against a hook that ignored
        // the argument and snapped 960 anyway, if 960 happened to snap to the same width.
        _boot();
        (,, int24 dlo, int24 dhi) = hook.pool();
        assertGt(int256(dhi - dlo), int256(hi - lo), "the default band is not wider: this test proves nothing");
    }

    /// @dev A band narrower than one spacing cannot be snapped to anything but zero width, and a
    ///      zero-width position holds nothing. Refused at CONSTRUCTION, where it can be read,
    ///      rather than at `initialize` on some starting prices and not others. LAW 2: the exact
    ///      reason, and this one is NOT wrapped by v4 because it reverts in the constructor.
    function test_band_tooNarrowIsRefusedAtConstruction() public {
        address a = address(FLAGS ^ (uint160(0xBD02) << 144));
        bytes memory args = abi.encode(
            poolManager,
            c0,
            c1,
            FEE,
            SPACING,
            int24(SPACING - 1),
            _syntheticRoster(3),
            RENT_BPS,
            RENT_PERIOD,
            FIRM_WINDOW
        );
        vm.expectRevert(abi.encodeWithSelector(QueueHook.BadBandWidth.selector, int24(SPACING - 1), SPACING));
        deployCodeTo("QueueHarness.sol:QueueHarness", args, a);
    }

    // `recenter()` was rebuilt this session and left OUT again: eight targeted tests pass, the
    // INVARIANT CAMPAIGN does not, and the defect was not located. The implementation, its tests and
    // the bisection evidence are preserved in `docs/wip/recenter-v2/`. Eight green unit tests were
    // not a reason to ship it.
    /// @dev No wings, same concentrated band, a swap that stays in: the clip is the identity
    ///      against PoolManager. If `_queueShare` silently under-credits a sole-LP in-band
    ///      swap, this is the control that goes red.
    function test_wing_noWingsInBandIsIdentity() public {
        _boot();
        uint256 s0 = expT0;
        (uint256 inAmt,) = _swap(true, s0 / 500);
        _check("no wings, in band");
        assertEq(lastHookCreditedIn, inAmt, "in-band sole-LP fill was clipped");
    }

    /// @dev The other direction. A rule that lives once per direction has been wrong four times
    ///      on this project (PITFALLS 5.52).
    function test_wing_crossingOtherDirectionCreditsTheBandOnly() public {
        _boot();
        (,,, int24 tu) = hook.pool();
        _addWings(LIQ);
        uint256 s1 = expT1;
        (uint256 inAmt, uint256 credited) = _swapObserved(false, s1 * 4);
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick >= tu, "the reverse swap never left the band: this test proves nothing");
        assertGt(credited, 0, "the queue was credited nothing of the band");
        assertLt(credited, inAmt, "the queue was credited the upper-wing fill too");
        assertGt(inAmt - credited, 1e12, "the wing fill was dust: this test proves nothing");
        _checkInvariantF("reverse crossing", 1e12);
        _assertSolvent();
    }

    /// @dev Walk out of the band, then swap BACK in. The clip must reconstruct the in-band
    ///      slice from the near edge, not from the pre-swap (out-of-band) price.
    function test_wing_reentryCreditsTheBandOnly() public {
        _boot();
        (,, int24 tl,) = hook.pool();
        _addWings(LIQ);

        (uint256 out1,) = _swapObserved(true, expT0 * 4);
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick < tl, "never left the band: re-entry is unreachable");
        assertGt(out1, 0, "outbound crossing credited nothing");

        (uint256 inAmt, uint256 credited) = _swapObserved(false, expT1 * 4);
        (, tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick >= tl, "the reverse swap never re-entered the band");
        assertGt(credited, 0, "re-entry credited the queue nothing");
        // Started in the lower wing: ANY credit equal to the whole swap is wing theft,
        // whether we stop inside the band or walk out the top.
        assertLt(credited, inAmt, "re-entry credited the lower-wing fill to the queue");
        _checkInvariantF("re-entry", 1e12);
        _assertSolvent();
    }

    /// @dev Start in the lower wing, walk the WHOLE band, finish in the upper wing.
    ///      One computeSwapStep from lo to hi. If this is not entered, the test is void.
    function test_wing_fullTraverseCreditsOnlyTheBand() public {
        _boot();
        (,, int24 tl, int24 tu) = hook.pool();
        _addWings(LIQ);
        _swapObserved(true, expT0 * 4);
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick < tl, "never reached the lower wing");

        (uint160 sqrtB,,,) = poolManager.getSlot0(k.toId());
        uint256 want = expT1 * 20;
        (uint256 inAmt, uint256 credited) = _swapObserved(false, want);
        (uint160 sqrtA, int24 tickAfter,,) = poolManager.getSlot0(k.toId());
        assertTrue(tickAfter >= tu, "never crossed the whole band into the upper wing: this test proves nothing");
        assertGt(credited, 0, "full traverse credited nothing");
        assertLt(credited, inAmt, "full traverse credited a wing");
        assertEq(credited, _replayBandIn(false, -int256(want), sqrtB, sqrtA), "full traverse != band replay");
        _checkInvariantF("full traverse", 1e12);
        _assertSolvent();
    }

    /// @dev Already in a wing, same direction: the band is not traversed. Crediting anything
    ///      is invented fill.
    function test_wing_alreadyOutsideCreditsNothing() public {
        _boot();
        (,, int24 tl,) = hook.pool();
        _addWings(LIQ);
        _swapObserved(true, expT0 * 4);
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick < tl, "never left the band");

        (uint256 t0, uint256 t1) = hook.totals();
        this.doSwap(true, expT0);
        (uint256 n0, uint256 n1) = hook.totals();
        assertEq(n0, t0, "a swap that stayed in the lower wing credited token0 to the queue");
        assertEq(n1, t1, "a swap that stayed in the lower wing credited token1 to the queue");
        _checkInvariantF("already outside", 1e12);
        _assertSolvent();
    }

    /// @dev Protocol fee is whole-swap. The clip must net only the band's share or the
    ///      ledger and the position drift (LAW 3 / §E.5 on a disjoint range).
    function test_wing_crossingWithProtocolFeeIsSolvent() public {
        _boot();
        _addWings(LIQ);
        uint24 maxPf = uint24(1000) | (uint24(1000) << 12);
        _setProtocolFee(k, maxPf);

        (uint256 inAmt, uint256 credited) = _swapObserved(true, expT0 * 4);
        assertGt(poolManager.protocolFeesAccrued(c0), 0, "protocol fee did not accrue: this test proves nothing");
        assertGt(credited, 0, "queue credited nothing");
        assertLt(credited, inAmt, "queue took the wing fill (and maybe the wing's protocol fee)");
        _checkInvariantF("pf crossing", 1e12);
        _assertSolvent();
    }

    /// @dev Exact-out is a different remaining-sign in SwapMath. The clip was written against
    ///      exact-in. If it credits the wings, this is the control.
    function test_wing_exactOutCrossingCreditsTheBandOnly() public {
        _boot();
        (,, int24 tl,) = hook.pool();
        _addWings(LIQ);

        uint256 wantOut = expT1 * 2;
        assertTrue(wantOut != 0, "nothing was seeded");
        (uint256 inAmt, uint256 credited) = _swapExactOutObserved(true, wantOut);
        (, int24 tick,,) = poolManager.getSlot0(k.toId());
        assertTrue(tick < tl, "exact-out never left the band: this test proves nothing");
        assertGt(credited, 0, "exact-out credited the queue nothing");
        assertLt(credited, inAmt, "exact-out credited the wing fill to the queue");
        _checkInvariantF("exact-out crossing", 1e12);
        _assertSolvent();
    }

    /// @dev A swap that does NOT feed the fixture witness. Crossing fills include wing
    ///      inventory; LAW 3 for the queue is the hook's position, not PoolManager's
    ///      whole-pool delta.
    function _swapObserved(bool zeroForOne, uint256 amountIn) internal returns (uint256 inAmt, uint256 credited) {
        uint256 p0 = _pmBal(c0);
        uint256 p1 = _pmBal(c1);
        uint256 pf0 = poolManager.protocolFeesAccrued(c0);
        uint256 pf1 = poolManager.protocolFeesAccrued(c1);
        (uint256 t0, uint256 t1) = hook.totals();
        this.doSwap(zeroForOne, amountIn);
        return _observed(zeroForOne, p0, p1, pf0, pf1, t0, t1);
    }

    function _swapExactOutObserved(bool zeroForOne, uint256 amountOut)
        internal
        returns (uint256 inAmt, uint256 credited)
    {
        uint256 p0 = _pmBal(c0);
        uint256 p1 = _pmBal(c1);
        uint256 pf0 = poolManager.protocolFeesAccrued(c0);
        uint256 pf1 = poolManager.protocolFeesAccrued(c1);
        (uint256 t0, uint256 t1) = hook.totals();
        this.doSwapExactOut(zeroForOne, amountOut);
        return _observed(zeroForOne, p0, p1, pf0, pf1, t0, t1);
    }

    function doSwapExactOut(bool zeroForOne, uint256 amountOut) external {
        swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: type(uint256).max,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _observed(bool zeroForOne, uint256 p0, uint256 p1, uint256 pf0, uint256 pf1, uint256 t0, uint256 t1)
        private
        view
        returns (uint256 inAmt, uint256 credited)
    {
        uint256 n0 = _pmBal(c0);
        uint256 n1 = _pmBal(c1);
        uint256 pfDelta =
            zeroForOne ? poolManager.protocolFeesAccrued(c0) - pf0 : poolManager.protocolFeesAccrued(c1) - pf1;
        (uint256 nt0, uint256 nt1) = hook.totals();
        if (zeroForOne) {
            inAmt = n0 - p0 - pfDelta;
            credited = nt0 - t0;
        } else {
            inAmt = n1 - p1 - pfDelta;
            credited = nt1 - t1;
        }
    }

    /// @dev Independent copy of the hook's band step, written from SwapMath, not from src/.
    ///      Protocol fee is zero in the tests that call this. A mismatch is a clip bug, not a
    ///      "close enough" inequality.
    function _replayBandIn(bool zfo, int256 remaining, uint160 start, uint160 end) internal view returns (uint256) {
        (,, int24 tl, int24 tu) = hook.pool();
        uint160 lo = TickMath.getSqrtPriceAtTick(tl);
        uint160 hi = TickMath.getSqrtPriceAtTick(tu);
        uint160 fromP = zfo ? (start < hi ? start : hi) : (start > lo ? start : lo);
        uint160 toP = zfo ? (end > lo ? end : lo) : (end < hi ? end : hi);
        if (zfo ? fromP <= toP : fromP >= toP) return 0;
        return _stepIn(fromP, toP, remaining);
    }

    function _stepIn(uint160 fromP, uint160 toP, int256 remaining) private view returns (uint256) {
        uint128 L = hook.positionLiquidity();
        if (L == 0) return 0;
        (, uint256 stepIn,, uint256 feeAmt) = SwapMath.computeSwapStep(fromP, toP, L, remaining, FEE);
        return stepIn + feeAmt;
    }

    function _pmMint(int24 lower, int24 upper, uint128 liq) internal returns (uint256 tokenId) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] =
            abi.encode(k, lower, upper, uint256(liq), type(uint128).max, type(uint128).max, address(this), bytes(""));
        params[1] = abi.encode(c0, c1);
        params[2] = abi.encode(c0, address(this));
        params[3] = abi.encode(c1, address(this));
        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _pmDecrease(uint256 tokenId, uint128 liq) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liq), uint256(0), uint256(0), bytes(""));
        params[1] = abi.encode(c0, c1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _assertSolvent() internal {
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 g0, uint256 g1) = hook.redeemAll();
        assertLe(t0, g0 + f0 + 1e12, "token0 ledger exceeds position plus float");
        assertLe(t1, g1 + f1 + 1e12, "token1 ledger exceeds position plus float");
    }

    /// @dev Principal of an outside position, no fees. Used to detect a swap that moved a wing.
    function _wingPrincipal(ExternalLP lp, int24 lower, int24 upper) internal view returns (uint256 a0, uint256 a1) {
        (uint128 L,,) = poolManager.getPositionInfo(k.toId(), address(lp), lower, upper, bytes32(0));
        if (L == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        uint160 p = sqrtP < lo ? lo : (sqrtP > hi ? hi : sqrtP);
        a0 = SqrtPriceMath.getAmount0Delta(p, hi, L, false);
        a1 = SqrtPriceMath.getAmount1Delta(lo, p, L, false);
    }
}
