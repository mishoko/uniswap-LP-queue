// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {HardcapLP} from "./utils/HardcapLP.sol";
import {Vm} from "forge-std/Vm.sol";

import {HardcapHook} from "../src/HardcapHook.sol";
import {HardcapMath} from "../src/libraries/HardcapMath.sol";

address constant HEVM = address(uint160(uint256(keccak256("hevm cheat code"))));

/// @dev Stateful fuzz of vault conservation. Ghosts are updated only on successful calls.
contract HardcapHandler {
    HardcapHook public hook;
    HardcapLP public lp;
    PoolKey public poolKey;
    IPoolManager public poolManager;
    address public swapRouter;
    int24 public tickLower;
    int24 public tickUpper;

    uint256 public ghostTaken0;
    uint256 public ghostTaken1;
    uint256 public ghostClaimed0;
    uint256 public ghostClaimed1;

    constructor(
        HardcapHook hook_,
        HardcapLP lp_,
        PoolKey memory key_,
        IPoolManager manager_,
        address swapRouter_,
        int24 tickLower_,
        int24 tickUpper_
    ) {
        hook = hook_;
        lp = lp_;
        poolKey = key_;
        poolManager = manager_;
        swapRouter = swapRouter_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
    }

    function swapExactIn(bool zeroForOne, uint256 amountIn) external {
        amountIn = bound(amountIn, 1e15, 5e18);
        uint256 v0 = hook.vaultAccrued(poolKey.currency0);
        uint256 v1 = hook.vaultAccrued(poolKey.currency1);
        try this._swap(zeroForOne, amountIn) {
            uint256 n0 = hook.vaultAccrued(poolKey.currency0);
            uint256 n1 = hook.vaultAccrued(poolKey.currency1);
            if (n0 > v0) ghostTaken0 += n0 - v0;
            if (n1 > v1) ghostTaken1 += n1 - v1;
        } catch {}
    }

    function add(uint256 liq, uint256 saltSeed) external {
        liq = bound(liq, 1e16, 20e18);
        bytes32 salt = bytes32(bound(saltSeed, 1, 8));
        try lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liq), salt: salt
            }),
            Constants.ZERO_BYTES
        ) {} catch {}
    }

    function remove(uint256 liq, uint256 saltSeed) external {
        liq = bound(liq, 1e16, 20e18);
        bytes32 salt = bytes32(bound(saltSeed, 1, 8));
        try lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(liq), salt: salt
            }),
            Constants.ZERO_BYTES
        ) {} catch {}
    }

    function claim(uint256 saltSeed) external {
        bytes32 salt = bytes32(bound(saltSeed, 0, 8));
        uint256 v0 = hook.vaultAccrued(poolKey.currency0);
        uint256 v1 = hook.vaultAccrued(poolKey.currency1);
        try lp.claim(hook, tickLower, tickUpper, salt) {
            ghostClaimed0 += v0 - hook.vaultAccrued(poolKey.currency0);
            ghostClaimed1 += v1 - hook.vaultAccrued(poolKey.currency1);
        } catch {}
    }

    function roll() external {
        Vm(HEVM).roll(block.number + 1);
    }

    function _swap(bool zeroForOne, uint256 amountIn) external {
        require(msg.sender == address(this));
        (bool ok,) = swapRouter.call(
            abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,bool,(address,address,uint24,int24,address),bytes,address,uint256)",
                amountIn,
                0,
                zeroForOne,
                poolKey,
                Constants.ZERO_BYTES,
                address(this),
                block.timestamp
            )
        );
        require(ok);
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (x % (max - min + 1));
    }
}

contract HardcapInvariantTest is BaseTest {
    HardcapHook hook;
    HardcapLP lp;
    HardcapHandler handler;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

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
            ) ^ (0xC0DE << 144)
        );
        deployCodeTo(
            "HardcapHook.sol:HardcapHook",
            abi.encode(
                poolManager,
                currency0,
                currency1,
                uint24(3000),
                int24(60),
                HardcapMath.DEFAULT_EXTRA_FEE_BPS,
                HardcapMath.DEFAULT_MAX_TAKE_BPS,
                HardcapMath.DEFAULT_OFFSET
            ),
            flags
        );
        hook = HardcapHook(flags);
        poolKey = hook.boundPoolKey();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 lo = TickMath.minUsableTick(60);
        int24 hi = TickMath.maxUsableTick(60);
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 1_000e18, salt: 0}),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);

        handler = new HardcapHandler(hook, lp, poolKey, poolManager, address(swapRouter), lo, hi);
        MockERC20(Currency.unwrap(currency0)).transfer(address(handler), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(handler), 1_000_000e18);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        // Handler swaps from itself; it must hold and approve the router.
        vm.prank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        vm.prank(address(handler));
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.prank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        vm.prank(address(handler));
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = HardcapHandler.swapExactIn.selector;
        selectors[1] = HardcapHandler.add.selector;
        selectors[2] = HardcapHandler.remove.selector;
        selectors[3] = HardcapHandler.claim.selector;
        selectors[4] = HardcapHandler.roll.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_vaultCoveredByHookBalance() public view {
        assertLe(hook.vaultAccrued(currency0), currency0.balanceOf(address(hook)));
        assertLe(hook.vaultAccrued(currency1), currency1.balanceOf(address(hook)));
    }

    function invariant_takenEqualsClaimedPlusVault() public view {
        assertEq(handler.ghostTaken0(), handler.ghostClaimed0() + hook.vaultAccrued(currency0));
        assertEq(handler.ghostTaken1(), handler.ghostClaimed1() + hook.vaultAccrued(currency1));
    }

    function invariant_noOwnerDrainSurface() public {
        (bool ok,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("rescueTokens(address,uint256)", address(0), 1));
        assertFalse(ok);
    }
}
