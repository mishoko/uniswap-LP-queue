// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// RESEARCH ARTEFACT — attacks the claim "P1 in _afterSwap cannot block withdrawals".
// FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/protocol-fee forge test --match-contract WithdrawalPathProbe -vv

import {BaseTest} from "../../../archive/2026-08-26/test/utils/BaseTest.sol";
import {QueueHook} from "../../../archive/2026-08-26/test/spike/QueueAllocator.t.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract WithdrawalPathProbe is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint128 constant LIQ = 1_000e18;

    Currency c0;
    Currency c1;
    QueueHook hook;
    PoolKey k;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        vm.roll(100);
    }

    /// @dev Q2: after the spike's own 4-swap scenario, can each seat's LEDGER COMPOSITION be paid
    ///      out of the shared position by modifyLiquidity(-D) alone? A position releases tokens in
    ///      a ratio fixed by the current price and the tick range; a seat's ledger does not.
    function test_Q2_seatCompositionVersusWhatThePositionCanRelease() public {
        address a = address(FLAGS ^ (uint160(0x7777) << 144));
        deployCodeTo("QueueAllocator.t.sol:QueueHook", abi.encode(poolManager, uint8(0)), a);
        hook = QueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 100_000e18);
        MockERC20(Currency.unwrap(c1)).mint(a, 100_000e18);

        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);

        // the spike's exact scenario
        _swap(true, 4e18);
        _swap(true, 300e18);
        _swap(true, 50e18);
        _swap(false, 20e18);

        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(SPACING));
        uint160 hi = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(SPACING));

        // What the WHOLE position would release right now, and therefore its fixed ratio.
        (uint256 p0, uint256 p1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, LIQ);
        emit log_named_uint("position releases token0", p0);
        emit log_named_uint("position releases token1", p1);
        emit log("");

        for (uint256 i; i < 3; i++) {
            (uint256 a0, uint256 a1) = hook.entry(i);
            emit log_named_uint("seat", i);
            emit log_named_uint("   ledger a0", a0);
            emit log_named_uint("   ledger a1", a1);
            // The liquidity that would be needed to release a0, and separately a1.
            uint128 need0 = LiquidityAmounts.getLiquidityForAmount0(sqrtP, hi, a0);
            uint128 need1 = LiquidityAmounts.getLiquidityForAmount1(lo, sqrtP, a1);
            emit log_named_uint("   liquidity needed to release a0", need0);
            emit log_named_uint("   liquidity needed to release a1", need1);
            // Taking the smaller D (so neither leg overpays) - what does the seat ACTUALLY get?
            uint128 d = need0 < need1 ? need0 : need1;
            (uint256 g0, uint256 g1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, d);
            emit log_named_uint("   with D=min, actually releases token0", g0);
            emit log_named_uint("   with D=min, actually releases token1", g1);
            emit log_named_int("   SHORT token0 vs ledger", int256(g0) - int256(a0));
            emit log_named_int("   SHORT token1 vs ledger", int256(g1) - int256(a1));
            emit log("");
        }
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, k, "", address(this), block.timestamp);
    }
}
