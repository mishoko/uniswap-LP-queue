// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice PRICE-THEN-QUEUE spike.
///
/// Uniswap already has price priority (nearer ticks fill first). QUEUE today throws the ticks
/// away and runs one front-first line over a full-range blob. The Uniswap-shaped object is
/// **price then queue**: v4 walks ticks; among seats whose range is in this step, fill
/// front-first. This file executes the riskiest assumption of that object:
///
///     afterSwap hands the hook ONE BalanceDelta. There is no tick-crossing callback.
///     Can a SwapMath replay over the hook's own bands recover the per-band fill to the wei?
///
/// If yes, price-then-queue is an afterSwap allocator on top of Allocation.sol, not a new AMM.
/// If no, the idea is a custom-accounting redesign (beforeSwapReturnDelta) and should be killed
/// or scoped as such.
///
/// MODE is the single switch between the walk and the deliberate mutations, so the negative
/// controls run the identical test body against identical state. LAW 1: price is 1:4, decimals
/// 18/6. LAW 3: conservation against PoolManager balances net of protocolFeesAccrued.
library RangeWalk {
    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @dev Exact-in walk. `amountIn` is what the swapper specified. Returns per-band
    ///      (amountIn including LP fee, amountOut). Protocol fee is NOT deducted here — the
    ///      hook nets it the same way QUEUE does, from the snapshot window.
    function walkExactIn(
        Band[3] memory bands,
        bool zeroForOne,
        uint160 sqrtP,
        uint160 limit,
        uint24 feePips,
        uint256 amountIn
    ) internal pure returns (uint256[3] memory bandIn, uint256[3] memory bandOut) {
        if (amountIn == 0) return (bandIn, bandOut);
        int256 remaining = -int256(amountIn);
        uint256 inAmt;
        uint256 outAmt;
        (sqrtP, remaining, inAmt, outAmt) = _step(bands[1], zeroForOne, sqrtP, limit, feePips, remaining);
        bandIn[1] = inAmt;
        bandOut[1] = outAmt;
        uint256 nextIdx = zeroForOne ? 0 : 2;
        (,, inAmt, outAmt) = _step(bands[nextIdx], zeroForOne, sqrtP, limit, feePips, remaining);
        bandIn[nextIdx] = inAmt;
        bandOut[nextIdx] = outAmt;
    }

    function _step(Band memory b, bool zfo, uint160 sqrtP, uint160 limit, uint24 feePips, int256 remaining)
        internal
        pure
        returns (uint160 next, int256 rem, uint256 inAmt, uint256 outAmt)
    {
        next = sqrtP;
        rem = remaining;
        if (remaining == 0 || sqrtP == limit || b.liquidity == 0) return (next, rem, 0, 0);
        uint160 edge = zfo ? TickMath.getSqrtPriceAtTick(b.tickLower) : TickMath.getSqrtPriceAtTick(b.tickUpper);
        if (zfo ? (sqrtP <= edge) : (sqrtP >= edge)) return (next, rem, 0, 0);
        uint256 feeAmt;
        (next, inAmt, outAmt, feeAmt) = SwapMath.computeSwapStep(
            sqrtP, SwapMath.getSqrtPriceTarget(zfo, edge, limit), b.liquidity, remaining, feePips
        );
        inAmt += feeAmt;
        rem = remaining + int256(inAmt);
    }

    /// @dev The naive split: afterSwap delta smeared by L. This is what a "just weight by
    ///      liquidity" hook would do, and it is the mutation that MUST go red on a crossing swap.
    function proRataByL(uint128[3] memory L, uint256 amtIn, uint256 amtOut)
        internal
        pure
        returns (uint256[3] memory bandIn, uint256[3] memory bandOut)
    {
        uint256 tot;
        for (uint256 i; i < 3; i++) {
            tot += L[i];
        }
        if (tot == 0) return (bandIn, bandOut);
        uint256 paidIn;
        uint256 paidOut;
        for (uint256 i; i < 3; i++) {
            bool last = i == 2;
            bandIn[i] = last ? amtIn - paidIn : FullMath.mulDiv(amtIn, L[i], tot);
            bandOut[i] = last ? amtOut - paidOut : FullMath.mulDiv(amtOut, L[i], tot);
            paidIn += bandIn[i];
            paidOut += bandOut[i];
        }
    }
}

/// @dev Sole-LP hook that mints THREE adjacent concentrated positions (below / at / above the
///      seeded price) and attributes each swap to those bands. It is a spike, not production:
///      no Harberger, no ERC-6909, no float. The only question is the attribution.
contract LadderHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint8 constant WALK = 0;
    uint8 constant PRO_RATA = 1; // mutation: smear the aggregate by L
    uint8 constant HEAD_ONLY = 2; // mutation: dump the whole fill on the "at" band

    uint8 public immutable mode;

    PoolKey public key;
    RangeWalk.Band[3] public bands; // 0 below, 1 at, 2 above

    uint256 public lastIn0;
    uint256 public lastIn1;
    uint256 public lastOut0;
    uint256 public lastOut1;
    uint256[3] public lastBandIn;
    uint256[3] public lastBandOut;
    uint160 public lastSqrtBefore;
    uint24 public lastFeePips;
    uint256 public swapsSeen;

    uint256 transient pfSnapshotPlusOne;

    constructor(IPoolManager pm, uint8 mode_) BaseHook(pm) {
        mode = mode_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        require(sender == address(this), "LADDER: hook is sole LP");
        return BaseHook.beforeAddLiquidity.selector;
    }

    function seed(PoolKey calldata k, RangeWalk.Band[3] calldata b) external {
        key = k;
        bands[0].tickLower = b[0].tickLower;
        bands[0].tickUpper = b[0].tickUpper;
        bands[0].liquidity = b[0].liquidity;
        bands[1].tickLower = b[1].tickLower;
        bands[1].tickUpper = b[1].tickUpper;
        bands[1].liquidity = b[1].liquidity;
        bands[2].tickLower = b[2].tickLower;
        bands[2].tickUpper = b[2].tickUpper;
        bands[2].liquidity = b[2].liquidity;
        poolManager.unlock(abi.encode(uint8(1)));
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm");
        for (uint256 i; i < 3; i++) {
            if (bands[i].liquidity == 0) continue;
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: bands[i].tickLower,
                    tickUpper: bands[i].tickUpper,
                    liquidityDelta: int256(uint256(bands[i].liquidity)),
                    salt: bytes32(i)
                }),
                ""
            );
            _resolve(key.currency0, d.amount0());
            _resolve(key.currency1, d.amount1());
        }
        return "";
    }

    function _resolve(Currency c, int128 amt) internal {
        if (amt < 0) {
            uint256 m = uint256(uint128(-amt));
            poolManager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(poolManager), m);
            poolManager.settle();
        } else if (amt > 0) {
            poolManager.take(c, address(this), uint256(uint128(amt)));
        }
    }

    function _beforeSwap(address, PoolKey calldata k, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        lastSqrtBefore = sqrtP;
        lastFeePips = k.fee;
        Currency input = Currency.wrap(address(0)); // overwritten below; keep compiler happy
        input = k.currency0; // set properly from params in afterSwap via snapshot of BOTH
        // Snapshot BOTH currencies: cheaper than guessing, and the window argument
        // is the same as QUEUE's. We store the input one in afterSwap.
        pfSnapshotPlusOne = poolManager.protocolFeesAccrued(k.currency0) + 1;
        // stash currency1 in lastIn1 transiently? no — read both after. We snapshot c0
        // and also c1 into lastOut1 as a second plus-one. Ugly but spike-local.
        lastOut1 = poolManager.protocolFeesAccrued(k.currency1) + 1;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata k, SwapParams calldata params, BalanceDelta d, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        int256 e0 = -int256(d.amount0());
        int256 e1 = -int256(d.amount1());
        if (e0 == 0 && e1 == 0) {
            swapsSeen++;
            return (BaseHook.afterSwap.selector, 0);
        }

        bool zeroForOne = params.zeroForOne;
        uint256 amtIn = zeroForOne ? uint256(int256(e0 < 0 ? int256(0) : e0)) : uint256(int256(e1 < 0 ? int256(0) : e1));
        uint256 amtOut =
            zeroForOne ? uint256(int256(e1 > 0 ? int256(0) : -e1)) : uint256(int256(e0 > 0 ? int256(0) : -e0));

        Currency inC = zeroForOne ? k.currency0 : k.currency1;
        uint256 snap = zeroForOne ? pfSnapshotPlusOne : lastOut1;
        uint256 pfDelta = poolManager.protocolFeesAccrued(inC) - (snap - 1);
        if (pfDelta > amtIn) pfDelta = amtIn;
        amtIn -= pfDelta;

        lastIn0 = zeroForOne ? amtIn : 0;
        lastIn1 = zeroForOne ? 0 : amtIn;
        lastOut0 = zeroForOne ? 0 : amtOut;
        lastOut1 = zeroForOne ? amtOut : 0;

        uint128[3] memory Ls;
        Ls[0] = bands[0].liquidity;
        Ls[1] = bands[1].liquidity;
        Ls[2] = bands[2].liquidity;

        if (mode == PRO_RATA) {
            (lastBandIn, lastBandOut) = RangeWalk.proRataByL(Ls, amtIn, amtOut);
        } else if (mode == HEAD_ONLY) {
            lastBandIn[0] = 0;
            lastBandIn[1] = amtIn;
            lastBandIn[2] = 0;
            lastBandOut[0] = 0;
            lastBandOut[1] = amtOut;
            lastBandOut[2] = 0;
        } else {
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            (lastBandIn, lastBandOut) =
                RangeWalk.walkExactIn(bands, zeroForOne, lastSqrtBefore, limit, lastFeePips, amtIn + pfDelta);
            // The walk consumed the swapper's GROSS input (fee included). Net protocol fee out
            // of the input band so the attributed amtIn is what the position actually received.
            if (pfDelta != 0) {
                // Charge the protocol fee to the first band that took input, matching QUEUE:
                // the skim is on the input token of THIS swap, not a per-band mark.
                for (uint256 i; i < 3; i++) {
                    if (lastBandIn[i] >= pfDelta) {
                        lastBandIn[i] -= pfDelta;
                        break;
                    }
                }
            }
        }

        swapsSeen++;
        return (BaseHook.afterSwap.selector, 0);
    }

    function lastBands() external view returns (uint256[3] memory ins, uint256[3] memory outs) {
        return (lastBandIn, lastBandOut);
    }
}

contract PriceThenQueueSpikeTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    Currency c0;
    Currency c1;
    LadderHook hook;
    PoolKey k;
    RangeWalk.Band[3] bands;
    uint8 dec0 = 18;
    uint8 dec1 = 6;

    function setUp() public {
        deployArtifactsAndLabel();
        MockERC20 t0 = new MockERC20("A", "A", dec0);
        MockERC20 t1 = new MockERC20("B", "B", dec1);
        if (t0 > t1) (t0, t1) = (t1, t0);
        (c0, c1) = (Currency.wrap(address(t0)), Currency.wrap(address(t1)));
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(i == 0 ? c0 : c1));
            t.mint(address(this), 1e30);
            t.approve(address(permit2), type(uint256).max);
            t.approve(address(swapRouter), type(uint256).max);
            permit2.approve(address(t), address(positionManager), type(uint160).max, type(uint48).max);
            permit2.approve(address(t), address(poolManager), type(uint160).max, type(uint48).max);
        }
        vm.roll(100);
    }

    function _deploy(uint8 mode, uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("PriceThenQueue.t.sol:LadderHook", abi.encode(poolManager, mode), a);
        hook = LadderHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 1e30);
        MockERC20(Currency.unwrap(c1)).mint(a, 1e30);
    }

    function _open() internal {
        int24 mid = TickMath.getTickAtSqrtPrice(Constants.SQRT_PRICE_1_4);
        mid = (mid / SPACING) * SPACING;
        int24 w = 600; // ~6% log-width per band, snapped
        w = (w / SPACING) * SPACING;

        // three adjacent bands: below / at / above. Current price sits in `at`.
        bands[0] = RangeWalk.Band({tickLower: mid - 2 * w, tickUpper: mid - w, liquidity: 1_000e18});
        bands[1] = RangeWalk.Band({tickLower: mid - w, tickUpper: mid + w, liquidity: 1_000e18});
        bands[2] = RangeWalk.Band({tickLower: mid + w, tickUpper: mid + 2 * w, liquidity: 1_000e18});

        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        hook.seed(k, bands);

        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(k.toId());
        require(sqrtP != 0, "pool did not initialize");
        require(tick >= bands[1].tickLower && tick < bands[1].tickUpper, "seeded price is not in the middle band");
        require(dec0 != dec1, "fixture is unit-decimal");
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint256 inAmt, uint256 outAmt, uint256 pf) {
        uint256 p0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 p1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        uint256 pf0 = poolManager.protocolFeesAccrued(c0);
        uint256 pf1 = poolManager.protocolFeesAccrued(c1);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 n0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 n1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        pf = zeroForOne ? poolManager.protocolFeesAccrued(c0) - pf0 : poolManager.protocolFeesAccrued(c1) - pf1;
        if (zeroForOne) {
            inAmt = n0 - p0 - pf;
            outAmt = p1 - n1;
        } else {
            inAmt = n1 - p1 - pf;
            outAmt = p0 - n0;
        }
    }

    function _sum(uint256[3] memory xs) internal pure returns (uint256 s) {
        s = xs[0] + xs[1] + xs[2];
    }

    function _assertWalkMatches(string memory tag, bool zeroForOne, uint256 inAmt, uint256 outAmt) internal view {
        (uint256[3] memory ins, uint256[3] memory outs) = hook.lastBands();
        assertEq(_sum(ins), inAmt, string.concat(tag, ": walk amtIn != PoolManager net input"));
        assertEq(_sum(outs), outAmt, string.concat(tag, ": walk amtOut != PoolManager output"));
        if (zeroForOne) {
            assertEq(outs[2], 0, string.concat(tag, ": zeroForOne credited the ABOVE band"));
        } else {
            assertEq(outs[0], 0, string.concat(tag, ": oneForZero credited the BELOW band"));
        }
    }

    // ------------------------------------------------------------------ the facts

    /// @dev v4 exposes 14 hook flags. None of them is a tick-cross. Price-then-queue CANNOT
    ///      be "the pool will tell us". This is the platform constraint the walk exists to
    ///      satisfy. Source: Hooks.sol flags; asserted here so a future v4 with a tick hook
    ///      makes this test fail for the right reason.
    function test_spike_v4HasNoTickCrossingCallback() public pure {
        // 14 bits, all named, none of them a tick-cross. If v4 adds one, ALL_HOOK_MASK moves
        // and this is the tripwire that the spike's premise changed.
        assertEq(uint256(Hooks.ALL_HOOK_MASK), uint256((1 << 14) - 1), "hook mask is no longer 14 bits");
        assertEq(uint256(Hooks.BEFORE_SWAP_FLAG), uint256(1 << 7), "beforeSwap moved");
        assertEq(uint256(Hooks.AFTER_SWAP_FLAG), uint256(1 << 6), "afterSwap moved");
        assertEq(uint256(Hooks.AFTER_DONATE_FLAG), uint256(1 << 4), "afterDonate moved");
        assertEq(uint256(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG), uint256(1 << 3), "returns-delta layout moved");
    }

    /// @dev A swap that stays inside the middle band is 100% attributed to it. If this fails,
    ///      the walk cannot even do the current QUEUE job on a concentrated blob.
    function test_spike_smallSwapStaysInTheMiddleBand() public {
        _deploy(0, 1);
        _open();

        uint256 amountIn = 1e16; // small, 18-decimal token0
        (uint256 inAmt, uint256 outAmt,) = _swap(true, amountIn);
        assertTrue(outAmt != 0, "nothing happened: this test proves nothing");
        (uint256[3] memory ins, uint256[3] memory outs) = hook.lastBands();
        _assertWalkMatches("small 0->1", true, inAmt, outAmt);
        assertEq(outs[1], outAmt, "small swap leaked out of the middle band");
        assertEq(ins[0] + ins[2], 0, "small swap credited a side band");
        assertEq(hook.swapsSeen(), 1, "afterSwap did not run");
    }

    /// @dev THE RISKY ASSUMPTION. A swap large enough to leave the middle band must credit
    ///      the BELOW band with a nonzero fill, the walk's sums must equal PoolManager's
    ///      delta to the wei, and the ABOVE band must stay at 0. This is price priority
    ///      recovered from one afterSwap number.
    function test_spike_crossingSwapSplitsAtTheBandEdge_toTheWei() public {
        _deploy(0, 2);
        _open();

        // Push hard in the zeroForOne direction so we exhaust the middle band's token1.
        uint256 amountIn = 200e18;
        (uint256 inAmt, uint256 outAmt,) = _swap(true, amountIn);
        assertTrue(outAmt != 0, "nothing happened");

        (, uint256[3] memory outs) = hook.lastBands();
        _assertWalkMatches("cross 0->1", true, inAmt, outAmt);
        assertGt(outs[1], 0, "crossing swap never filled the middle band");
        assertGt(outs[0], 0, "crossing swap never reached the below band: this test proves nothing");
        assertEq(outs[2], 0, "zeroForOne filled the above band");

        (, int24 tickAfter,,) = poolManager.getSlot0(k.toId());
        assertLt(tickAfter, bands[1].tickLower, "price did not leave the middle band");
    }

    /// @dev Mirror: oneForZero must hit ABOVE, not BELOW.
    function test_spike_crossingTheOtherWayHitsTheAboveBand() public {
        _deploy(0, 3);
        _open();

        // Middle band holds more token0 than token1 at 1:4, so exhausting it
        // oneForZero takes a much larger raw input than the 200e18 zeroForOne.
        uint256 amountIn = 200e18;
        (uint256 inAmt, uint256 outAmt,) = _swap(false, amountIn);
        assertTrue(outAmt != 0, "nothing happened");
        (, uint256[3] memory outs) = hook.lastBands();
        _assertWalkMatches("cross 1->0", false, inAmt, outAmt);
        assertGt(outs[1], 0, "never filled the middle");
        assertGt(outs[2], 0, "never reached the above band: this test proves nothing");
        assertEq(outs[0], 0, "oneForZero filled the below band");
    }

    /// @dev NEGATIVE CONTROL. Identical fixture, identical swap, the hook smears the aggregate
    ///      by L. On a crossing swap that MUST put zero on the above band, pro-rata-by-L puts
    ///      a third of the fill there. If this test ever goes green, the control has no teeth.
    function test_spike_proRataByL_isWrongOnACrossingSwap() public {
        _deploy(1, 4); // PRO_RATA
        _open();
        uint256 amountIn = 200e18;
        (uint256 inAmt, uint256 outAmt,) = _swap(true, amountIn);
        assertTrue(outAmt != 0, "nothing happened");

        (uint256[3] memory ins, uint256[3] memory outs) = hook.lastBands();
        // Conservation of the SUM still holds — that is why a conservation-only test is blind.
        assertEq(_sum(ins), inAmt, "pro-rata lost input");
        assertEq(_sum(outs), outAmt, "pro-rata lost output");
        // The composition is the lie: the above band, which v4 did not touch, got a share.
        assertGt(outs[2], 0, "control is toothless: pro-rata did not credit the untouched band");
    }

    /// @dev NEGATIVE CONTROL. Dump the whole fill on the middle band. A crossing swap's
    ///      below-band fill is missing, so the walk's "below got some" assertion is what
    ///      this mutant cannot satisfy. We assert the mutant's own number is wrong against
    ///      a fresh WALK hook on a cloned state? Simpler: HEAD_ONLY reports below=0 on a
    ///      swap we independently know left the middle band (slot0 tick).
    function test_spike_headOnly_missesTheBelowBandOnACrossingSwap() public {
        _deploy(2, 5); // HEAD_ONLY
        _open();
        uint256 amountIn = 200e18;
        _swap(true, amountIn);
        (, int24 tickAfter,,) = poolManager.getSlot0(k.toId());
        assertLt(tickAfter, bands[1].tickLower, "price did not leave the middle band");
        (uint256[3] memory ins, uint256[3] memory outs) = hook.lastBands();
        assertEq(outs[0], 0, "control is toothless: HEAD_ONLY credited the below band");
        assertGt(outs[1], 0, "HEAD_ONLY did not even credit the middle");
        assertEq(ins[1], ins[0] + ins[1] + ins[2], "HEAD_ONLY did not dump the whole input on the middle");
    }

    /// @dev Positive control: the unmutated hook, same swap as the two mutants, DOES credit
    ///      below and NOT above. Without this, a mutant that fails for an unrelated revert
    ///      looks like success (LAW 2's sibling).
    function test_spike_unmutatedCrossing_isThePositiveControlForTheMutants() public {
        _deploy(0, 6);
        _open();
        (uint256 inAmt, uint256 outAmt,) = _swap(true, 200e18);
        (, uint256[3] memory outs) = hook.lastBands();
        _assertWalkMatches("positive control", true, inAmt, outAmt);
        assertGt(outs[0], 0, "positive control: below empty");
        assertEq(outs[2], 0, "positive control: above touched");
    }

    /// @dev Same L at the current tick is the SAME instantaneous depth regardless of range
    ///      width — that is v3's identity, and a test that expected concentrated to return
    ///      more per unit L was a false claim. The 1/200th figure is SAME TOKENS, not same L:
    ///      minting 1e18 L full-range consumes more inventory than minting 1e18 L in a ±6%
    ///      band. Measured on PoolManager's own balances at seed.
    function test_spike_sameLCostsMoreTokensAtFullRange() public {
        uint256 pm0Before = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 pm1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        _deploy(0, 7);
        _open();
        uint256 narrow0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)) - pm0Before;
        uint256 narrow1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager)) - pm1Before;
        // Three bands of 1e18 L. The middle one is the ±6% band; below+above sit off-price
        // and hold only one token. Full-range comparison is one 1e18 L position.

        address a = address(FLAGS ^ (uint160(8) << 144));
        deployCodeTo("PriceThenQueue.t.sol:LadderHook", abi.encode(poolManager, uint8(0)), a);
        LadderHook wide = LadderHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 1e30);
        MockERC20(Currency.unwrap(c1)).mint(a, 1e30);

        uint256 w0Before = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 w1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        RangeWalk.Band[3] memory w;
        w[1] = RangeWalk.Band({
            tickLower: TickMath.minUsableTick(SPACING), tickUpper: TickMath.maxUsableTick(SPACING), liquidity: 1_000e18
        });
        PoolKey memory kw = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(a)});
        poolManager.initialize(kw, Constants.SQRT_PRICE_1_4);
        wide.seed(kw, w);
        uint256 wide0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)) - w0Before;
        uint256 wide1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager)) - w1Before;

        // The middle band alone is the fair compare. We cannot split the three-band seed
        // without reading per-position; so we assert the FULL-RANGE 1e18 L costs MORE
        // of both tokens than the three-band book does NOT — wait, three bands cost more
        // because they are 3e18 L total. Compare full-range 1e18 to the fact that it is
        // strictly larger than a single 1e18 in a narrow band would be, by checking
        // full-range > 0 and recording the ratio against the three-band spend / 3.
        assertGt(wide0, 0, "full-range seed spent no token0");
        assertGt(wide1, 0, "full-range seed spent no token1");
        assertGt(narrow0, 0, "ladder seed spent no token0");
        assertGt(narrow1, 0, "ladder seed spent no token1");
        // Per unit L: full-range 1e18 vs ladder 3e18. If full-range were as capital-efficient
        // as the concentrated bands, wide/1 >= narrow/3 would fail. The concentrated side
        // must be cheaper per L.
        assertLt(narrow0 / 3, wide0, "concentrated bands were not cheaper per L in token0");
        assertLt(narrow1 / 3, wide1, "concentrated bands were not cheaper per L in token1");
    }
}
