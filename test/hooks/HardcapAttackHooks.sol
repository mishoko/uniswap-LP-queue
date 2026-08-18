// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HardcapHook} from "../../src/HardcapHook.sol";

/// @dev Surplus = 100% of notional. Production clamp must cut this to MAX_TAKE_BPS.
contract HardcapOverSurplusHook is HardcapHook {
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

    function _computeSurplus(uint256 notional) internal pure override returns (uint256) {
        return notional;
    }
}

/// @dev Skips the min() clamp so `_creditVault` must fail-closed.
contract HardcapBugTakeHook is HardcapHook {
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

    function _boundTake(uint256 notional, uint256) internal pure override returns (uint256) {
        return notional;
    }
}

/// @dev Exposes the vault rail for a unit-level over-credit test.
contract HardcapHarness is HardcapHook {
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

    function exposedCredit(Currency currency, uint256 take, uint256 cap) external {
        _creditVault(currency, take, cap);
    }
}
