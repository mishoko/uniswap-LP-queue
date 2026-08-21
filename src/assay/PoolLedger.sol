// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Reads an account's live flash-accounting position from PoolManager's own ledger.
///
/// v4 keeps every account's delta in TRANSIENT storage at `keccak256(abi.encode(account, currency))`
/// (v4-core `CurrencyDelta._computeSlot`) and exposes transient storage through `exttload`, which is
/// `external view`. Mid-transaction, from outside, this is exactly how much an account is into the
/// pool for — a number the account does not own and therefore cannot misreport.
///
/// Single source of truth for every Assay component that measures extraction, so a predicate and a
/// meter can never disagree about what "extraction" means.
library PoolLedger {
    /// @dev Sign convention: negative = the account owes PoolManager, i.e. it has taken value out
    /// and not yet paid for it. Positive = PoolManager owes the account.
    function delta(IPoolManager poolManager, address account, Currency currency) internal view returns (int256) {
        return int256(uint256(poolManager.exttload(slot(account, currency))));
    }

    /// @notice Outstanding debt: value removed and not yet paid for. Zero if the account is square
    /// or in credit.
    function debt(IPoolManager poolManager, address account, Currency currency) internal view returns (uint256) {
        int256 d = delta(poolManager, account, currency);
        return d >= 0 ? 0 : uint256(-d);
    }

    function slot(address account, Currency currency) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, currency));
    }
}
