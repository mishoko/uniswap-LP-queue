// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Pure take/cap arithmetic for Hardcap. Isolated so the cap invariant can be
/// fuzzed without a PoolManager. Settlement and vault writes stay in the hook.
library HardcapMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
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
}
