// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IHookPredicate} from "../IHookPredicate.sol";

/// @notice Asserts the pool's spot price stays inside a declared tick band.
///
/// Extends Assay from "how much can leave" to "where can the price go" — a second, independent
/// failure class. Enforced inside a callback it is a circuit breaker: a swap that would push a
/// stable pair outside its band cannot complete, so an oracle reading this pool cannot be walked to
/// an arbitrary price within one transaction, whatever the attacker's capital.
///
/// Present-state and one staticcall, so it satisfies the same scope rule as everything else: the
/// band is an absolute range fixed at deployment, not a comparison against remembered history.
/// A moving reference would be stateful and belongs in a metered mixin, not a predicate.
///
/// HONEST LIMIT: this is only meaningful for pairs with a defensible fixed band — stablecoins,
/// liquid-staking derivatives, correlated assets. On a volatile pair a band wide enough to avoid
/// false trips is too wide to prevent anything, and declaring one there is theatre.
contract TickBandPredicate is IHookPredicate {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;
    int24 public immutable minTick;
    int24 public immutable maxTick;

    error InvalidBand();

    constructor(IPoolManager poolManager_, PoolId poolId_, int24 minTick_, int24 maxTick_) {
        if (minTick_ >= maxTick_) revert InvalidBand();
        poolManager = poolManager_;
        poolId = poolId_;
        minTick = minTick_;
        maxTick = maxTick_;
    }

    function check(address) external view returns (bool) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return tick >= minTick && tick <= maxTick;
    }

    function describe() external pure returns (string memory) {
        return "pool spot price stays inside the declared tick band";
    }
}
