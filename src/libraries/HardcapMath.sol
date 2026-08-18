// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Pure take/cap/ToB quote arithmetic for Hardcap. Isolated so the cap
/// invariant can be fuzzed without a PoolManager. Settlement stays in the hook.
library HardcapMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev Tax-path default for envelope tests. Production deploy passes 0 (ToB-spot).
    uint16 internal constant DEFAULT_EXTRA_FEE_BPS = 5;
    uint16 internal constant DEFAULT_MAX_TAKE_BPS = 15;
    uint48 internal constant DEFAULT_OFFSET = 1;
    uint48 internal constant MIN_OFFSET = 1;

    error TakeExceedsCap(uint256 take, uint256 cap);
    error InvalidBps();

    function capOf(uint256 notional, uint256 maxTakeBps) internal pure returns (uint256) {
        if (maxTakeBps > BPS_DENOMINATOR) revert InvalidBps();
        return FullMath.mulDiv(notional, maxTakeBps, BPS_DENOMINATOR);
    }

    function surplusOf(uint256 notional, uint256 extraFeeBps) internal pure returns (uint256) {
        if (extraFeeBps > BPS_DENOMINATOR) revert InvalidBps();
        return FullMath.mulDiv(notional, extraFeeBps, BPS_DENOMINATOR);
    }

    /// @dev Clamp `surplus` to `cap`. Revert if the result still exceeds the cap
    /// (overflow / bad cast / a subclass that skipped the min).
    function boundTake(uint256 notional, uint256 surplus, uint256 maxTakeBps) internal pure returns (uint256 take) {
        uint256 cap = capOf(notional, maxTakeBps);
        take = surplus < cap ? surplus : cap;
        if (take > cap) revert TakeExceedsCap(take, cap);
    }

    /// @dev Open-tick boundary for one `computeSwapStep`. zeroForOne → lower, else upper.
    function openBoundaryTick(int24 openTick, int24 tickSpacing, bool zeroForOne) internal pure returns (int24) {
        if (zeroForOne) {
            int256 down = int256(openTick) - int256(tickSpacing);
            return down < TickMath.MIN_TICK ? TickMath.MIN_TICK : int24(down);
        }
        int256 up = int256(openTick) + int256(tickSpacing);
        return up > TickMath.MAX_TICK ? TickMath.MAX_TICK : int24(up);
    }

    /// @dev One step at (openSqrt, openL) toward the open tick's spaced boundary.
    /// `feePips` is PoolKey.fee (3000 = 0.30%). Pass 0 and exact-in targetOut inflates;
    /// surplus vs a real swap then under-claws. Include the LP fee.
    /// `amountRemaining` sign matches SwapParams: negative exact-in, positive exact-out.
    /// Direction is inferred by SwapMath: target < current ⇒ zeroForOne.
    function quoteOpenStep(
        uint160 openSqrtPriceX96,
        uint128 openLiquidity,
        int24 openTick,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount, bool wouldCross)
    {
        uint160 target = TickMath.getSqrtPriceAtTick(openBoundaryTick(openTick, tickSpacing, zeroForOne));
        (sqrtPriceNextX96, amountIn, amountOut, feeAmount) =
            SwapMath.computeSwapStep(openSqrtPriceX96, target, openLiquidity, amountRemaining, feePips);
        wouldCross = sqrtPriceNextX96 == target;
    }

    /// @dev Exact-in: unspecified is output. Exact-out: unspecified is input (amountIn + fee).
    function tobSurplus(bool exactIn, uint256 actualUnspecified, uint256 targetUnspecified)
        internal
        pure
        returns (uint256)
    {
        if (exactIn) {
            return actualUnspecified > targetUnspecified ? actualUnspecified - targetUnspecified : 0;
        }
        return targetUnspecified > actualUnspecified ? targetUnspecified - actualUnspecified : 0;
    }
}
