// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {IHookPredicate} from "../IHookPredicate.sol";

/// @notice Asserts a hook cannot return a swap delta.
/// @dev Zero external calls. Uniswap v4 encodes hook permissions in the low 14 bits of the hook
/// ADDRESS, and PoolManager enforces them, so this is provable from the address alone — no
/// bytecode, no state, no trust. No other contract class on Ethereum has this property; it is the
/// reason Assay's assertions are cheap and unfalsifiable rather than heuristic.
contract NoSwapDeltaPredicate is IHookPredicate {
    function check(address hook) external pure returns (bool) {
        uint160 a = uint160(hook);
        return (a & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) == 0 && (a & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) == 0;
    }

    function describe() external pure returns (string memory) {
        return "hook cannot return a swap delta (address bits 2,3 clear)";
    }
}

/// @notice Asserts a hook's permission bits are EXACTLY the expected set.
/// @dev Catches a hook that quietly holds authority it never advertised.
contract PermissionMatchPredicate is IHookPredicate {
    uint160 public immutable expectedFlags;

    constructor(uint160 expectedFlags_) {
        expectedFlags = expectedFlags_ & Hooks.ALL_HOOK_MASK;
    }

    function check(address hook) external view returns (bool) {
        return (uint160(hook) & Hooks.ALL_HOOK_MASK) == expectedFlags;
    }

    function describe() external pure returns (string memory) {
        return "hook permission bits exactly match the declared set";
    }
}

/// @notice Asserts the hook's deployed code has not been swapped out from under the bond.
/// @dev HONEST LIMIT: codehash pinning catches selfdestruct-and-redeploy (metamorphic contracts).
/// It does NOT catch a proxy upgrade, because the proxy's own codehash is unchanged. A contract
/// cannot read another contract's storage on-chain, so the EIP-1967 implementation slot is not
/// readable from a predicate — only off-chain via eth_getStorageAt. For proxies, pair this with a
/// predicate that calls `implementation()` if the proxy exposes one; if it exposes nothing, the
/// hook is simply not bondable against upgrades and the registry must say so.
contract CodehashPredicate is IHookPredicate {
    bytes32 public immutable pinned;

    constructor(address hook) {
        pinned = hook.codehash;
    }

    function check(address hook) external view returns (bool) {
        return hook.codehash == pinned;
    }

    function describe() external pure returns (string memory) {
        return "hook codehash unchanged since bonding (does NOT cover proxy upgrades)";
    }
}
