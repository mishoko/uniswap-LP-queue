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
import {AssayFlowMeter} from "../../src/assay/AssayFlowMeter.sol";
import {AssayBaseHook} from "../../src/assay/AssayBaseHook.sol";
import {DeltaBudgetPredicate} from "../../src/assay/predicates/DeltaBudgetPredicate.sol";

/// @dev A slow drain: 1% per swap. Comfortably inside any sane per-transaction budget, and it
/// empties the pool over enough swaps. This is the shape a per-transaction bound cannot see.
contract DrippingHook is AssayFlowMeter {
    using CurrencySettler for Currency;

    uint256 public constant SIPHON_BPS = 100;

    constructor(IPoolManager pm, Currency metered_, uint256 perBlockLimit)
        AssayFlowMeter(pm, new address[](0), metered_, perBlockLimit)
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
        uint256 siphon = (notional * SIPHON_BPS) / 10_000;
        if (siphon == 0) return (this.afterSwap.selector, 0);

        unspecified.take(poolManager, address(this), siphon, false);
        return (this.afterSwap.selector, int128(uint128(siphon)));
    }
}

contract FlowMeterTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint256 constant SWAP_IN = 1e16;

    Currency currency0;
    Currency currency1;
    HardcapLP lp;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);
        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);
    }

    function _deploy(uint160 nonce, uint256 perBlockLimit) internal returns (address h, PoolKey memory key) {
        h = address(FLAGS ^ (nonce << 144));
        deployCodeTo("FlowMeter.t.sol:DrippingHook", abi.encode(poolManager, currency1, perBlockLimit), h);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: DrippingHook(h)
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1_000e18,
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);
    }

    function _swap(PoolKey memory key) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    /// @dev Each drip is tiny, so a generous per-transaction budget never fires. The drain still
    /// happens; it just takes more than one transaction. Motivates the meter.
    function test_perTxBudgetIsBlindToRepetition() public {
        (address h, PoolKey memory key) = _deploy(0x1A1A, 0);
        DeltaBudgetPredicate generous = new DeltaBudgetPredicate(poolManager, currency1, 1e15);

        for (uint256 i = 0; i < 20; ++i) {
            _swap(key);
        }
        assertGt(currency1.balanceOf(h), 1e15, "extracted more than the per-tx budget, one drip at a time");
        assertTrue(generous.check(h), "and the per-tx predicate is satisfied at every point");
    }

    function test_meterStopsTheDrainWithinABlock() public {
        (address h, PoolKey memory key) = _deploy(0x2B2B, 3.5e14);

        _swap(key);
        uint256 perSwap = DrippingHook(h).flowThisBlock();
        assertGt(perSwap, 0, "first drip metered");

        _swap(key);
        _swap(key);
        assertApproxEqRel(DrippingHook(h).flowThisBlock(), perSwap * 3, 0.05e18, "meter accumulates across txs");

        vm.expectRevert();
        _swap(key);

        assertApproxEqRel(DrippingHook(h).flowThisBlock(), perSwap * 3, 0.05e18, "blocked swap added nothing");
    }

    function test_meterResetsNextBlock() public {
        (address h, PoolKey memory key) = _deploy(0x3C3C, 3.5e14);
        _swap(key);
        _swap(key);
        _swap(key);
        vm.expectRevert();
        _swap(key);

        vm.roll(block.number + 1);
        assertEq(DrippingHook(h).flowThisBlock(), 0, "a new block is a fresh allowance");
        _swap(key);
        assertGt(DrippingHook(h).flowThisBlock(), 0);
    }

    function test_zeroLimitDisablesMetering() public {
        (address h, PoolKey memory key) = _deploy(0x4D4D, 0);
        for (uint256 i = 0; i < 10; ++i) {
            _swap(key);
        }
        assertEq(DrippingHook(h).flowThisBlock(), 0, "not metered");
        assertGt(currency1.balanceOf(h), 0);
    }

    function test_gasCostOfMetering() public {
        (, PoolKey memory bareKey) = _deploy(0x5E5E, 0);
        (, PoolKey memory meteredKey) = _deploy(0x6F6F, type(uint208).max);

        _swap(bareKey);
        _swap(meteredKey);

        uint256 g0 = gasleft();
        _swap(bareKey);
        uint256 bare = g0 - gasleft();
        g0 = gasleft();
        _swap(meteredKey);
        uint256 meteredGas = g0 - gasleft();

        emit log_named_uint("swap, unmetered          ", bare);
        emit log_named_uint("swap, flow-metered       ", meteredGas);
        emit log_named_uint("cost of metering         ", meteredGas - bare);
        assertLt(meteredGas - bare, 30_000, "metering writes storage, but must stay affordable");
    }
}
