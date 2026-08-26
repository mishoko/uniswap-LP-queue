// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {HardcapLP} from "./utils/HardcapLP.sol";
import {HardcapHook} from "../src/HardcapHook.sol";
import {HardcapMath} from "../src/libraries/HardcapMath.sol";

/// @dev ToB-spot kill suite. extraFeeBps = 0. Envelope tax tests stay in Hardcap.t.sol.
contract HardcapToBTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint128 internal constant LIQUIDITY = 1_000e18;
    /// @dev Large enough to move the book; first-of-block so take is 0 either way.
    uint256 internal constant DUMP = 1e18;
    /// @dev Small enough to stay inside one tick after DUMP so the claw is not skipped.
    uint256 internal constant CLAW = 1e15;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    HardcapHook hook;
    HardcapLP lp;
    int24 tickLower;
    int24 tickUpper;
    bytes32 salt;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        hook = _deployToB(0xC0C0);
        poolKey = hook.boundPoolKey();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        salt = bytes32(0);

        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(LIQUIDITY)), salt: salt
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);
    }

    function test_tob_firstSwapInBlock_takeIsZero() public {
        _swap(true, DUMP);
        assertEq(hook.vaultAccrued(currency0), 0);
        assertEq(hook.vaultAccrued(currency1), 0);
        assertEq(hook.openBlock(), uint48(block.number));
    }

    /// @dev DoD name kept. Same-dir is worse than open; surplus is 0. Not a claw.
    function test_tob_secondSwapSameDir_inRange_clawsExcess() public {
        _swap(true, CLAW);
        uint256 before = hook.vaultAccrued(currency1) + hook.vaultAccrued(currency0);
        _swap(true, CLAW);
        assertEq(hook.vaultAccrued(currency1) + hook.vaultAccrued(currency0), before, "same-dir cannot beat open");
    }

    function test_tob_backrunOppositeDir_inRange_clawsExcess() public {
        _swap(true, DUMP);
        assertEq(hook.vaultAccrued(currency0) + hook.vaultAccrued(currency1), 0, "first swap vanilla");

        (, int24 tickBefore,,) = poolManager.getSlot0(poolKey.toId());
        BalanceDelta back = _swap(false, CLAW);
        (, int24 tickAfter,,) = poolManager.getSlot0(poolKey.toId());
        assertEq(tickAfter, tickBefore, "claw size must not tick-cross");

        uint256 take = hook.vaultAccrued(currency0);
        assertGt(take, 0, "backrun beats open oneForZero quote");
        uint256 userOut = uint256(uint128(back.amount0()));
        uint256 notional = userOut + take;
        assertLe(take, HardcapMath.capOf(notional, HardcapMath.DEFAULT_MAX_TAKE_BPS));
        assertLt(take, notional, "user still receives output");
    }

    /// @dev Size-matched sandwich: dump then equal opposite. Backrun recrosses; take stays 0.
    /// This is the MEV the slogan points at. We do not claw it.
    function test_tob_sizeMatchedSandwich_takeIsZero() public {
        _swap(true, DUMP);
        assertEq(hook.vaultAccrued(currency0) + hook.vaultAccrued(currency1), 0);
        _swap(false, DUMP);
        assertEq(hook.vaultAccrued(currency0), 0, "size-matched backrun recrosses; not clawed");
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_tob_tickCross_takeIsZero() public {
        _swap(true, DUMP);
        (, int24 tickBefore,,) = poolManager.getSlot0(poolKey.toId());
        _swap(false, DUMP);
        (, int24 tickAfter,,) = poolManager.getSlot0(poolKey.toId());
        assertTrue(tickAfter != tickBefore, "second swap must cross a tick");
        assertEq(hook.vaultAccrued(currency0), 0, "tick-cross sandwiches are not clawed");
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_tob_liquidityChangedSinceOpen_takeIsZero() public {
        _swap(true, DUMP);
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(10e18)),
                salt: bytes32(uint256(7))
            }),
            Constants.ZERO_BYTES
        );
        assertTrue(poolManager.getLiquidity(poolKey.toId()) != hook.openLiquidity());
        _swap(false, CLAW);
        assertEq(hook.vaultAccrued(currency0), 0);
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_tob_bothDirections() public {
        _swap(true, DUMP);
        _swap(false, CLAW);
        assertGt(hook.vaultAccrued(currency0), 0, "oneForZero backrun claws token0");

        vm.roll(block.number + 1);
        uint256 before1 = hook.vaultAccrued(currency1);
        _swap(false, DUMP);
        _swap(true, CLAW);
        assertGt(hook.vaultAccrued(currency1), before1, "zeroForOne backrun claws token1");
    }

    function test_tob_largeExcess_clampedUserSwapSucceeds() public {
        _swap(true, 20e18);
        BalanceDelta back = _swap(false, CLAW);
        uint256 take = hook.vaultAccrued(currency0);
        uint256 userOut = uint256(uint128(back.amount0()));
        uint256 notional = userOut + take;
        uint256 cap = HardcapMath.capOf(notional, HardcapMath.DEFAULT_MAX_TAKE_BPS);
        assertEq(take, cap, "large leftover is clamped, not reverted");
        assertGt(userOut, 0, "user swap succeeded");
        assertLt(take, notional);
    }

    function test_tob_exactOut_backrunClawsUnspecifiedInput() public {
        _swap(true, DUMP);
        uint256 amountOut = CLAW;
        BalanceDelta back = swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: 1e18,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        uint256 take = hook.vaultAccrued(currency1);
        assertGt(take, 0, "exact-out backrun claws extra input");
        uint256 actualIn = uint256(uint128(-back.amount1()));
        assertLe(take, HardcapMath.capOf(actualIn, HardcapMath.DEFAULT_MAX_TAKE_BPS));
    }

    function test_tob_newBlockResetsFirstSwap() public {
        _swap(true, DUMP);
        _swap(false, CLAW);
        assertGt(hook.vaultAccrued(currency0), 0);
        vm.roll(block.number + 1);
        uint256 before = hook.vaultAccrued(currency0) + hook.vaultAccrued(currency1);
        _swap(true, DUMP);
        assertEq(hook.vaultAccrued(currency0) + hook.vaultAccrued(currency1), before, "new block first swap is vanilla");
    }

    function _deployToB(uint160 ns) internal returns (HardcapHook deployed) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address hookAddr = address(flags ^ (ns << 144));
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
