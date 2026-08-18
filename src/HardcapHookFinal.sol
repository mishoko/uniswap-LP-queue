// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HardcapHook} from "./HardcapHook.sol";

/// @notice Production deploy target. Same logic as `HardcapHook`.
/// Solidity has no `final` on functions; `_creditVault` is non-virtual and is the cap rail.
/// Inherit `HardcapHook` only if you will call `super` and not skip that rail. Re-mine flags.
contract HardcapHookFinal is HardcapHook {
    constructor(
        IPoolManager poolManager_,
        Currency currency0_,
        Currency currency1_,
        uint24 fee_,
        int24 tickSpacing_,
        uint16 extraFeeBps_,
        uint16 maxTakeBps_,
        uint48 offset_
    ) HardcapHook(poolManager_, currency0_, currency1_, fee_, tickSpacing_, extraFeeBps_, maxTakeBps_, offset_) {}
}
