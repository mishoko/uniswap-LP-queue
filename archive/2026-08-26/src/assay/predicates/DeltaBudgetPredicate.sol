// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IHookPredicate} from "../IHookPredicate.sol";
import {PoolLedger} from "../PoolLedger.sol";

/// @notice Asserts a hook has not pulled more than `maxDebt` of `currency` out of the PoolManager
/// in the current transaction.
///
/// This is the strongest assertion a Uniswap v4 hook can make about itself, and it does not exist
/// outside v4. PoolManager keeps every account's live flash-accounting delta in TRANSIENT storage at
/// `keccak256(abi.encode(account, currency))` and exposes it through `exttload`, which is
/// `external view`. So mid-callback, from outside, anyone can read exactly how much the hook is
/// currently into the pool for.
///
/// Why this matters more than balance or solvency predicates: it reads POOLMANAGER'S ledger, not the
/// hook's self-reported accounting. A hook that under-reports its liabilities makes a solvency
/// assertion vacuously true. It cannot make this one true, because it does not own the number.
///
/// Consequently Assay does not try to enumerate bug classes. It bounds the damage at the ledger: any
/// defect — authorization, arithmetic, reentrancy, a lying oracle — whose *effect* is the hook
/// extracting value beyond its declared budget becomes unexecutable, whatever its cause.
///
/// SIGN CONVENTION (v4): negative delta = the account owes PoolManager, i.e. it has taken value out
/// and not yet paid for it. Positive = PoolManager owes the account. We bound the negative side.
///
/// TIMING: evaluate this at the END of a callback, before the hook's returned delta is applied by
/// PoolManager. At that instant the outstanding debt is precisely what the hook has physically
/// removed during this transaction.
contract DeltaBudgetPredicate is IHookPredicate {
    IPoolManager public immutable poolManager;
    Currency public immutable currency;
    uint256 public immutable maxDebt;

    constructor(IPoolManager poolManager_, Currency currency_, uint256 maxDebt_) {
        poolManager = poolManager_;
        currency = currency_;
        maxDebt = maxDebt_;
    }

    function deltaSlot(address account) public view returns (bytes32) {
        return PoolLedger.slot(account, currency);
    }

    function check(address hook) external view returns (bool) {
        return PoolLedger.debt(poolManager, hook, currency) <= maxDebt;
    }

    function describe() external pure returns (string memory) {
        return "hook's outstanding debt to PoolManager stays within its declared budget";
    }
}
