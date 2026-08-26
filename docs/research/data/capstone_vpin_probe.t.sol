// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";
import {VPINDynamicFeeHook} from "../src/VPINDynamicFeeHook.sol";

contract ProbeTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VPINDynamicFeeHook hook;
    uint256 constant BUCKET_SIZE = 1 ether;
    uint24 constant BASE_FEE = 3000;
    uint24 constant MAX_FEE = 10000;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        address hookAddress = address(uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("VPINDynamicFeeHook", abi.encode(manager, BUCKET_SIZE, BASE_FEE, MAX_FEE), hookAddress);
        hook = VPINDynamicFeeHook(hookAddress);
    }

    function _mkPool(uint160 sqrtPrice) internal returns (PoolKey memory k) {
        (k,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, sqrtPrice);
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60), tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 5000 ether, salt: bytes32(0)}), ZERO_BYTES);
    }

    /// Perfectly balanced round-trip flow: buy then immediately sell back. Zero net position,
    /// the least toxic flow that exists. A correct toxicity metric must read ~0.
    function _roundTrips(PoolKey memory k, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            uint256 b1 = currency1.balanceOfSelf();
            swapRouter.swap(k, SwapParams({zeroForOne: true, amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), settings, ZERO_BYTES);
            uint256 got1 = currency1.balanceOfSelf() - b1;
            swapRouter.swap(k, SwapParams({zeroForOne: false, amountSpecified: -int256(got1),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), settings, ZERO_BYTES);
        }
    }

    // ---- NEGATIVE CONTROL: same flow on a 1:1 pool must read ~0 ----
    function test_CONTROL_balancedRoundTrips_at_1to1() public {
        PoolKey memory k = _mkPool(SQRT_PRICE_1_1);
        _roundTrips(k, 20);
        uint256 v = hook.getVPIN(k);
        console.log("CONTROL 1:1  VPIN =", v);
        console.log("CONTROL 1:1  fee  =", hook.getPoolFeeEstimate(k));
        assertLt(v, 0.05e18, "control: balanced flow on 1:1 pool should read ~0");
    }

    // ---- PROBE: identical balanced flow on a 1:4 pool ----
    function test_PROBE_balancedRoundTrips_at_1to4() public {
        PoolKey memory k = _mkPool(SQRT_PRICE_1_4);
        _roundTrips(k, 20);
        uint256 v = hook.getVPIN(k);
        console.log("PROBE 1:4    VPIN =", v);
        console.log("PROBE 1:4    fee  =", hook.getPoolFeeEstimate(k));
        assertLt(v, 0.05e18, "EXPECT-FAIL-IF-BUGGY: same balanced flow, different price");
    }

    // ---- PROBE: does the directional adjustment apply to non-first-in-block swaps? ----
    function test_PROBE_directionalOnlyFirstSwapOfBlock() public {
        PoolKey memory k = _mkPool(SQRT_PRICE_1_1);
        // create tick movement in block N
        swapRouter.swap(k, SwapParams({zeroForOne: false, amountSpecified: -50 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), settings, ZERO_BYTES);
        vm.roll(block.number + 1);
        (, int24 t,,) = manager.getSlot0(k.toId());
        console.log("tick after momentum swap:");
        console.logInt(t);
        // swap 1 of block N+1: momentum-aligned, SHOULD be surcharged
        uint256 b0 = currency0.balanceOfSelf();
        swapRouter.swap(k, SwapParams({zeroForOne: false, amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), settings, ZERO_BYTES);
        uint256 out1 = currency0.balanceOfSelf() - b0;
        // swap 2 of the SAME block N+1: also momentum-aligned, should also be surcharged
        b0 = currency0.balanceOfSelf();
        swapRouter.swap(k, SwapParams({zeroForOne: false, amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), settings, ZERO_BYTES);
        uint256 out2 = currency0.balanceOfSelf() - b0;
        console.log("aligned swap #1 of block out:", out1);
        console.log("aligned swap #2 of block out:", out2);
        // if the surcharge applied to both, out2 <= out1 (modulo tiny price impact making out2 smaller anyway).
        // Print the delta so we can read whether swap #2 got a REFUND relative to #1.
        if (out2 > out1) { console.log("swap #2 got MORE out than #1 -> surcharge absent on #2"); }
        else { console.log("out1 - out2 =", out1 - out2); }
    }

    // ---- PROBE: gas cost of one large swap that rotates many buckets ----
    function test_PROBE_largeSwapBucketRotationGas() public {
        PoolKey memory k = _mkPool(SQRT_PRICE_1_1);
        // warm the buffer to full so _computeVPIN loops 50 every rotation
        for (uint256 i = 0; i < 60; i++) {
            swapRouter.swap(k, SwapParams({zeroForOne: i % 2 == 0, amountSpecified: -1 ether,
                sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
                settings, ZERO_BYTES);
        }
        console.log("filled buckets:", hook.getFilledBuckets(k));
        uint256 g = gasleft();
        swapRouter.swap(k, SwapParams({zeroForOne: true, amountSpecified: -200 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), settings, ZERO_BYTES);
        console.log("gas for one 200-ether swap (200 bucket rotations):", g - gasleft());
    }
}
