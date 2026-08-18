// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {HardcapLP} from "./utils/HardcapLP.sol";
import {HardcapHook} from "../src/HardcapHook.sol";
import {HardcapMath} from "../src/libraries/HardcapMath.sol";

/// @dev Spike only. Proves SwapMath args + whether ToB surplus is real.
/// Not the product suite.
contract HardcapToBSpikeTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint128 internal constant LIQUIDITY = 1_000e18;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    HardcapHook hook;
    HardcapLP lp;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address hookAddr = address(flags ^ (uint160(0xB0B0) << 144));
        bytes memory args = abi.encode(
            poolManager,
            currency0,
            currency1,
            FEE,
            TICK_SPACING,
            uint16(0),
            HardcapMath.DEFAULT_MAX_TAKE_BPS,
            HardcapMath.DEFAULT_OFFSET
        );
        deployCodeTo("HardcapHook.sol:HardcapHook", args, hookAddr);
        hook = HardcapHook(hookAddr);
        poolKey = hook.boundPoolKey();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(LIQUIDITY)), salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);
    }

    function test_spike_computeSwapStep_argsAndFee() public view {
        (uint160 openSqrt, int24 openTick,,) = poolManager.getSlot0(poolKey.toId());
        uint128 openL = poolManager.getLiquidity(poolKey.toId());

        uint160 boundDown = TickMath.getSqrtPriceAtTick(openTick - TICK_SPACING);
        uint160 boundUp = TickMath.getSqrtPriceAtTick(openTick + TICK_SPACING);
        assertTrue(boundDown < openSqrt, "zfo target must be below current");
        assertTrue(boundUp > openSqrt, "ofz target must be above current");

        int256 amount = -int256(1e16);
        (uint160 next0, uint256 in0, uint256 out0,) = SwapMath.computeSwapStep(openSqrt, boundDown, openL, amount, FEE);
        (,, uint256 outFee0,) = SwapMath.computeSwapStep(openSqrt, boundDown, openL, amount, 0);

        assertTrue(next0 > boundDown, "1e16 at 1000e18 L must not hit +/-60 tick bound");
        assertGt(outFee0, out0, "fee=0 quotes more output than fee=3000; omit-fee under-claws exact-in");
        assertGt(in0, 0);
        assertGt(out0, 0);

        (uint160 nextUp,,,) = SwapMath.computeSwapStep(openSqrt, boundUp, openL, amount, FEE);
        assertTrue(nextUp < boundUp, "same size oneForZero must not hit +60");
        assertTrue(nextUp > openSqrt, "oneForZero target>current infers direction");
    }

    function test_spike_sameDirWorse_oppositeDirBetter() public {
        (uint160 openSqrt, int24 openTick,,) = poolManager.getSlot0(poolKey.toId());
        uint128 openL = poolManager.getLiquidity(poolKey.toId());
        uint160 boundDown = TickMath.getSqrtPriceAtTick(openTick - TICK_SPACING);

        uint256 size = 1e16;
        _swap(true, size);

        BalanceDelta sameDir = _swap(true, size);
        uint256 sameDirOut = uint256(uint128(sameDir.amount1()));
        (,, uint256 targetSameDir,) = SwapMath.computeSwapStep(openSqrt, boundDown, openL, -int256(size), FEE);
        assertLt(sameDirOut, targetSameDir, "same-dir cannot beat open; named clawsExcess test is a lie");

        vm.roll(block.number + 1);
        (uint160 open2, int24 tick2,,) = poolManager.getSlot0(poolKey.toId());
        uint160 boundUp2 = TickMath.getSqrtPriceAtTick(tick2 + TICK_SPACING);
        _swap(true, size);
        BalanceDelta backrun = _swap(false, size);
        uint256 backrunOut = uint256(uint128(-backrun.amount0()));
        (,, uint256 targetBack,) = SwapMath.computeSwapStep(open2, boundUp2, openL, -int256(size), FEE);
        assertGt(backrunOut, targetBack, "backrun beats open; this is the only real surplus");
    }

    function test_spike_tickCrossThreshold() public {
        (, int24 t0,,) = poolManager.getSlot0(poolKey.toId());
        _swap(true, 1);
        (, int24 tWei,,) = poolManager.getSlot0(poolKey.toId());
        assertEq(t0, 0, "start at tick 0 (exact 1:1 = lower bound)");
        assertEq(tWei, -1, "ANY zeroForOne from exact tick bound decrements tick");
    }

    function test_spike_backrunStaysInTick_fromMidTick() public {
        // Re-init is not possible; use a fresh pool at mid-tick.
        HardcapHook mid = _deployMid();
        PoolKey memory key = mid.boundPoolKey();
        uint160 midPrice =
            uint160((uint256(TickMath.getSqrtPriceAtTick(0)) + uint256(TickMath.getSqrtPriceAtTick(1))) / 2);
        poolManager.initialize(key, midPrice);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(LIQUIDITY)), salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);

        (, int24 tOpen,,) = poolManager.getSlot0(key.toId());
        _swapKey(key, true, 1e15);
        (, int24 tAfterDump,,) = poolManager.getSlot0(key.toId());
        _swapKey(key, false, 1e15);
        (, int24 tAfterBack,,) = poolManager.getSlot0(key.toId());

        assertEq(tOpen, 0, "mid-tick starts in tick 0");
        assertEq(tAfterDump, tOpen, "1e15 dump stays in tick");
        assertEq(tAfterBack, tAfterDump, "1e15 backrun stays in tick; claw is reachable");
    }

    function test_spike_backrunTickFromPriceOne() public {
        (, int24 t0,,) = poolManager.getSlot0(poolKey.toId());
        _swap(true, 1e16);
        (, int24 tDump,,) = poolManager.getSlot0(poolKey.toId());
        _swap(false, 1e16);
        (, int24 tBack,,) = poolManager.getSlot0(poolKey.toId());
        assertTrue(tDump != t0, "dump from 1:1 crosses");
        assertTrue(tBack != tDump, "1e16 backrun recrosses to 0; claw size must be smaller than the dump");
    }

    function _deployMid() internal returns (HardcapHook deployed) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address hookAddr = address(flags ^ (uint160(0xB1B1) << 144));
        bytes memory args = abi.encode(
            poolManager,
            currency0,
            currency1,
            FEE,
            TICK_SPACING,
            uint16(0),
            HardcapMath.DEFAULT_MAX_TAKE_BPS,
            HardcapMath.DEFAULT_OFFSET
        );
        deployCodeTo("HardcapHook.sol:HardcapHook", args, hookAddr);
        deployed = HardcapHook(hookAddr);
    }

    function _swapKey(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }
}
