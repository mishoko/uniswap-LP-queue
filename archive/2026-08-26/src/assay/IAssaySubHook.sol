// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice A guest hook hosted inside an `AssayStack`.
///
/// A sub-hook NEVER touches PoolManager. It observes the swap and RETURNS how much of the
/// unspecified currency it would like; the stack decides what it actually gets. That inversion is
/// the whole safety model: a guest that cannot call PoolManager cannot extract from it, cannot
/// settle deltas that are not its own, and cannot reenter the pool. Its request is a number, and
/// numbers are clampable.
interface IAssaySubHook {
    function assayAfterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        external
        returns (uint256 requested);
}
