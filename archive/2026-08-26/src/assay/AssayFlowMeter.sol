// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AssayBaseHook} from "./AssayBaseHook.sol";
import {PoolLedger} from "./PoolLedger.sol";

/// @title AssayFlowMeter
/// @notice Caps how much a hook can extract from a pool across a whole block, not just within one
/// transaction.
///
/// `DeltaBudgetPredicate` bounds a single transaction, and a single-transaction bound is trivially
/// defeated by repetition: a hook leaking 0.1% per swap is inside any sane per-transaction budget
/// and still empties the pool over a few hundred swaps in the same block. That is the shape of a
/// slow drain, and a per-transaction check is structurally blind to it.
///
/// The meter is stateful, so unlike a runtime invariant it cannot be a `view` predicate. It is a
/// separate mixin for exactly that reason: `AssayHook`'s invariants stay view-only and therefore
/// incapable of moving value, and everything that must write lives here, visibly.
///
/// The metered quantity is read from POOLMANAGER'S ledger, never from the hook's own accounting —
/// the hook does not own the number it is being measured against.
///
/// HONEST LIMIT: this binds a hook that chose to bind itself. A deliberately malicious author simply
/// would not inherit it. Assay's guarantee is against DEFECTS in hooks that opted in; what makes
/// opting in credible to a third party is `HookBond` (capital at risk) and the registry (the choice
/// is public and machine-readable). None of the three is sufficient alone.
abstract contract AssayFlowMeter is AssayBaseHook {
    IPoolManager private immutable _flowPoolManager;
    Currency private immutable _flowCurrency;
    /// @dev 0 disables metering.
    uint256 private immutable _perBlockLimit;

    uint48 private _meterBlock;
    uint208 private _flowThisBlock;

    error FlowLimitExceeded(uint256 attempted, uint256 limit);
    /// @dev The running total is stored as uint208 to pack with the block number. A limit above that
    /// would let the stored total truncate on write and silently reset the meter mid-block.
    error FlowLimitTooLarge();

    event FlowMetered(uint48 indexed blockNumber, uint256 added, uint256 totalThisBlock);

    /// @dev `override` without `virtual`: a subclass cannot re-override these and switch metering
    /// off. Wired into `AssayBaseHook`'s sealed callbacks, so inheriting this mixin is sufficient —
    /// there is no modifier for an integrator to forget.
    function _assayEnter() internal view override returns (uint256) {
        return PoolLedger.debt(_flowPoolManager, address(this), _flowCurrency);
    }

    function _assayExit(uint256 mark) internal override {
        _meterSince(mark);
    }

    /// @dev Extends `AssayBaseHook` rather than sitting beside it. As siblings both overriding
    /// `_assayEnter`/`_assayExit` they formed a diamond that every integrator would have had to
    /// disambiguate by hand — inviting them to resolve it by disabling metering. A chain cannot be
    /// mis-resolved, and a metered hook now needs exactly one base and one constructor.
    constructor(IPoolManager poolManager_, address[] memory invariants_, Currency currency_, uint256 perBlockLimit_)
        AssayBaseHook(poolManager_, invariants_)
    {
        if (perBlockLimit_ > type(uint208).max) revert FlowLimitTooLarge();
        _flowPoolManager = poolManager_;
        _flowCurrency = currency_;
        _perBlockLimit = perBlockLimit_;
    }

    function flowLimitPerBlock() public view returns (uint256) {
        return _perBlockLimit;
    }

    function flowThisBlock() public view returns (uint256) {
        return uint48(block.number) == _meterBlock ? _flowThisBlock : 0;
    }

    /// Metering is wired through `AssayBaseHook`'s sealed callbacks via `_assayEnter` /
    /// `_assayExit`. There is deliberately no opt-in modifier: one existed, and combined with the
    /// sealed callbacks it would have metered twice.
    ///
    /// Measuring the entry-to-exit INCREASE rather than absolute debt is required for correctness,
    /// not a refinement. Under the `afterSwapReturnDelta` pattern a hook's `take()` debt is netted
    /// back to zero by the delta it returns, so a cross-callback running total would score the
    /// second extraction of a transaction as zero. Under other settlement patterns debt accumulates
    /// and the same total would count one extraction many times. The difference is correct for
    /// both, because it assumes nothing about how the hook settles.
    function _meterSince(uint256 mark) internal {
        uint256 limit = _perBlockLimit;
        if (limit == 0) return;

        uint256 debt = PoolLedger.debt(_flowPoolManager, address(this), _flowCurrency);
        if (debt <= mark) return; // this callback extracted nothing new
        uint256 added = debt - mark;

        uint48 nowBlock = uint48(block.number);
        uint256 total = (_meterBlock == nowBlock ? uint256(_flowThisBlock) : 0) + added;
        if (total > limit) revert FlowLimitExceeded(total, limit);

        _meterBlock = nowBlock;
        _flowThisBlock = uint208(total);
        emit FlowMetered(nowBlock, added, total);
    }
}
