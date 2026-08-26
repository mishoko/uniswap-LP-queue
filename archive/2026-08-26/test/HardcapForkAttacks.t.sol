// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {HardcapLP} from "./utils/HardcapLP.sol";
import {HardcapHook} from "../src/HardcapHook.sol";

/// @notice Attack-shaped replays. These do not require a mainnet fork; they reconstruct the
/// Cork / JIT / donate-redirect *pattern* against a local PoolManager. A live fork is optional later.
contract HardcapForkAttacksTest is BaseTest {
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

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

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x8888 << 144)
        );
        bytes memory args = abi.encode(poolManager, currency0, currency1, FEE, TICK_SPACING, 5, 15, 1);
        deployCodeTo("HardcapHook.sol:HardcapHook", args, flags);
        hook = HardcapHook(flags);

        poolKey = hook.boundPoolKey();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1_000e18, salt: 0}),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);
    }

    /// @dev Cork class: call the hook as if you were PoolManager, with attacker-chosen hookData.
    function test_cork_directCallbackAndHookDataCannotMintVault() public {
        uint256 vaultBefore = hook.vaultAccrued(currency0) + hook.vaultAccrued(currency1);

        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), poolKey, sp, BalanceDeltaLibrary.ZERO_DELTA, hex"dead");

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(HardcapHook.HookDataNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hex"dead",
            receiver: address(this),
            deadline: block.timestamp
        });

        assertEq(hook.vaultAccrued(currency0) + hook.vaultAccrued(currency1), vaultBefore);
    }

    /// @dev Address-keyed JIT lock is bypassable. Salt-keyed lock is not.
    function test_jit_secondSaltDoesNotUnlockFirstPosition() public {
        bytes32 a = bytes32(uint256(1));
        bytes32 b = bytes32(uint256(2));
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e18, salt: a}),
            Constants.ZERO_BYTES
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -1e18, salt: a}),
            Constants.ZERO_BYTES
        );

        // Opening salt B does not age salt A.
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e18, salt: b}),
            Constants.ZERO_BYTES
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -1e18, salt: a}),
            Constants.ZERO_BYTES
        );
    }

    /// @dev Extra tokens sent to the hook are not vault inventory. Claim pays accounting, not balanceOf.
    function test_donationToHookDoesNotInflateClaim() public {
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 accrued1 = hook.vaultAccrued(currency1);
        MockERC20(Currency.unwrap(currency1)).transfer(address(hook), 50e18);

        uint256 balBefore = currency1.balanceOf(address(this));
        lp.claim(hook, tickLower, tickUpper, bytes32(0));
        uint256 received = currency1.balanceOf(address(this)) - balBefore;

        assertEq(received, accrued1);
        assertEq(currency1.balanceOf(address(hook)), 50e18);
    }
}
