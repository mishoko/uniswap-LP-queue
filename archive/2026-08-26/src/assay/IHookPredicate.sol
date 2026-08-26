// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Result of evaluating a predicate against a hook.
/// @dev INCONCLUSIVE is load-bearing. A predicate that reverts, runs out of gas, tries to mutate
/// state, or returns malformed data MUST NOT read as VIOLATED (free slashing of honest hooks) and
/// MUST NOT read as HOLDS (unslashable dishonest hooks). See docs/SPIKE-predicate-sandbox.md.
enum Verdict {
    HOLDS,
    VIOLATED,
    INCONCLUSIVE
}

/// @notice A falsifiable, present-state assertion about a Uniswap v4 hook.
/// @dev Scope is fixed and deliberately narrow (spike, Trap 5): one staticcall, public state only,
/// no privileged input, no historical state, no dependence on msg.sender. Properties like "this
/// swap was unfairly priced" or "the hook stole from a user in block N" are NOT expressible here
/// and must not be claimed anywhere in this repo.
interface IHookPredicate {
    /// @notice True if the asserted property holds for `hook` in present state.
    /// @dev MUST be view. MUST return exactly 32 bytes containing 0 or 1.
    function check(address hook) external view returns (bool);

    /// @notice Human-readable assertion, for the registry. MUST NOT be relied on by the bond.
    function describe() external view returns (string memory);
}
