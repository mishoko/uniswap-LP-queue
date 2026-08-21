// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHookPredicate} from "../IHookPredicate.sol";

/// @notice Optional interface a hook implements to make its own accounting falsifiable.
interface IAssayAccounting {
    /// @notice Amount of `token` the hook says it owes to others (unpaid accrued balance).
    function assayAccrued(address token) external view returns (uint256);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Asserts the hook actually holds what it says it owes.
/// @dev One staticcall each side, present state only. This is the archetypal Assay predicate: the
/// hook publishes a liability, the chain publishes the asset, and anyone can compare them.
/// A hook that under-reports its liability makes this trivially true — solvency is a floor, not a
/// fairness claim, and is never presented as one.
contract SolvencyPredicate is IHookPredicate {
    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    function check(address hook) external view returns (bool) {
        return IERC20Minimal(token).balanceOf(hook) >= IAssayAccounting(hook).assayAccrued(token);
    }

    function describe() external pure returns (string memory) {
        return "hook token balance >= its own declared accrued liability";
    }
}
