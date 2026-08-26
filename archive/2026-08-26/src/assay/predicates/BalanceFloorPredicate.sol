// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHookPredicate} from "../IHookPredicate.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Asserts a hook's balance of `token` never falls below `floor`.
/// @dev The archetypal RUNTIME invariant: one SLOAD-free immutable read plus one staticcall, cheap
/// enough to run on every swap. Enforced inside the callback, it makes a drain unexecutable rather
/// than merely refundable — the class of bug that post-hoc bonding cannot help with, because by the
/// time a challenger can prove insolvency the tokens are gone.
contract BalanceFloorPredicate is IHookPredicate {
    address public immutable token;
    uint256 public immutable floor;

    constructor(address token_, uint256 floor_) {
        token = token_;
        floor = floor_;
    }

    function check(address hook) external view returns (bool) {
        return IERC20Minimal(token).balanceOf(hook) >= floor;
    }

    function describe() external pure returns (string memory) {
        return "hook token balance never falls below its declared floor";
    }
}
