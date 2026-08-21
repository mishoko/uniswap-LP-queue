// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {HardcapLP} from "../utils/HardcapLP.sol";
import {AssayHook} from "../../src/assay/AssayHook.sol";
import {AssayBaseHook} from "../../src/assay/AssayBaseHook.sol";
import {AssayFlowMeter} from "../../src/assay/AssayFlowMeter.sol";
import {DeltaBudgetPredicate} from "../../src/assay/predicates/DeltaBudgetPredicate.sol";
import {AssaySuite} from "../../src/assay/testing/AssaySuite.sol";
import {AssayHandler, IAssaySwapRouter, IAssayLiquidityRouter} from "../../src/assay/testing/AssayHandler.sol";

/// @dev A fee-taking hook wearing the full kit: a per-transaction ledger budget it cannot exceed and
/// a per-block flow limit it cannot outrun.
contract GuardedFeeHook is AssayFlowMeter {
    using CurrencySettler for Currency;

    uint256 public constant FEE_BPS = 100;

    constructor(IPoolManager pm, Currency metered_, uint256 perBlockLimit, address[] memory invs)
        AssayFlowMeter(pm, invs, metered_, perBlockLimit)
    {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Note what is absent: no assertion call, no metering call, no modifier. Both are wired
    /// into the sealed callbacks of `AssayBaseHook` and run regardless.
    function _assayAfterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        (Currency unspecified, int128 amount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        uint256 notional = amount >= 0 ? uint256(uint128(amount)) : uint256(uint128(-amount));
        uint256 take = (notional * FEE_BPS) / 10_000;
        if (take == 0) return (this.afterSwap.selector, int128(0));
        unspecified.take(poolManager, address(this), take, false);
        return (this.afterSwap.selector, int128(uint128(take)));
    }
}

/// @dev Concrete instantiation of the drop-in campaign. This is what a hook author writes: a setUp
/// and two getters.
contract AssaySuiteDemoTest is BaseTest, AssaySuite {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    GuardedFeeHook hook;
    AssayHandler handler;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        address[] memory invs = new address[](1);
        invs[0] = address(new DeltaBudgetPredicate(poolManager, currency1, 1e16));

        address h = address(FLAGS ^ (uint160(0x5017) << 144));
        deployCodeTo(
            "AssaySuiteDemo.t.sol:GuardedFeeHook", abi.encode(poolManager, currency1, uint256(1.5e16), invs), h
        );
        hook = GuardedFeeHook(h);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: hook});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 5_000e18, salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);

        handler = new AssayHandler(
            poolManager,
            IAssaySwapRouter(address(swapRouter)),
            IAssayLiquidityRouter(address(lp)),
            key,
            tickLower,
            tickUpper
        );

        deal(Currency.unwrap(currency0), address(handler), 1e24);
        deal(Currency.unwrap(currency1), address(handler), 1e24);
        vm.startPrank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);
        vm.stopPrank();

        // One warm-up swap so the campaign starts from a live pool. Foundry evaluates invariants
        // once immediately after setUp, before any handler call, so without this the anti-vacuity
        // invariant fires on an empty run -- which is exactly what it is for.
        handler.swap(true, 1e15);

        // Constrain the fuzz target set to the handler. Without this the default target set is every
        // contract deployed in setUp, including the MockERC20s, and the campaign spends its budget
        // calling burn() on things.
        targetContract(address(handler));
    }

    function assayedHook() internal view override returns (AssayHook) {
        return AssayHook(address(hook));
    }

    function assayHandler() internal view override returns (AssayHandler) {
        return handler;
    }

    function meteredHook() internal view override returns (address) {
        return address(hook);
    }

    /// @dev Reports how much of the campaign actually landed. A suite whose operations all revert
    /// satisfies every invariant while testing nothing, so the coverage numbers are part of the
    /// result, not diagnostics.
    function test_campaignCoverage() public {
        // Sized so the per-block flow limit is genuinely reached partway through: an earlier
        // version used swaps small enough that no guard ever fired, which meant the campaign only
        // ever explored the happy path while claiming otherwise.
        for (uint256 i = 0; i < 40; ++i) {
            handler.swap(i % 2 == 0, 1e16 * (i + 1));
            if (i == 20) vm.roll(block.number + 1);
        }
        emit log_named_uint("flow this block", hook.flowThisBlock());
        emit log_named_uint("flow limit", hook.flowLimitPerBlock());
        emit log_named_uint("hook balance c1", currency1.balanceOf(address(hook)));
        emit log_named_uint("swaps landed", handler.swaps());
        emit log_named_uint("swaps refused", handler.reverts());
        assertGt(handler.swaps(), 20, "most traffic must actually execute");
        assertGt(handler.reverts(), 0, "and the guards must actually refuse some of it");
    }
}
