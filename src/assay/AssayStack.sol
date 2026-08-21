// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {AssayBaseHook} from "./AssayBaseHook.sol";
import {IAssaySubHook} from "./IAssaySubHook.sol";

/// @title AssayStack
/// @notice Runs several untrusted hooks on ONE pool, each inside a bounded extraction budget.
///
/// Uniswap v4 allows exactly one hook address per pool. Today that means a pool picks one behaviour
/// and forgoes every other, and any attempt to compose means trusting a second body of code with the
/// full authority of the first. The reason composition is dangerous is that hook authority is
/// unbounded — which is precisely what the rest of Assay fixes. Once extraction is bounded at the
/// ledger, hosting a stranger's hook stops being reckless.
///
/// The containment model:
///
/// 1. **Guests never touch PoolManager.** A sub-hook observes and RETURNS a requested amount. It
///    holds no authority to take, settle, or reenter, so its request is just a number to be clamped.
/// 2. **Per-guest budget.** Each sub-hook's request is clamped to its own declared bps of the swap's
///    unspecified notional, and the total is clamped again to the stack's own ceiling. A guest that
///    asks for everything receives its budget.
/// 3. **Fail-open for the guest, fail-closed for the pool.** A sub-hook that reverts or exhausts its
///    gas stipend is SKIPPED and logged. The inversion is deliberate: one broken guest must not brick
///    a pool that other people's liquidity is sitting in. The pool's own invariants still fail closed.
/// 4. **Gas stipend per guest**, so a guest cannot consume the swap's gas.
/// 5. **Immutable guest list, no admin.** Nobody can add a sub-hook to a live pool, so a bounded set
///    of guests audited once stays the bounded set forever.
/// 6. **The stack is itself an `AssayBaseHook`**, so the whole arrangement sits inside one declared,
///    ledger-enforced budget regardless of how its guests behave.
///
/// Guests are paid into an internal ledger and withdraw separately. Paying them during the callback
/// would hand every guest a token transfer inside the swap — a reentrancy surface, and a
/// transfer-failing guest could revert the swap it was supposed to be contained by.
contract AssayStack is AssayBaseHook {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;
    /// @dev Per-guest gas. Enough for real logic, far too little to starve the swap.
    uint256 public constant SUB_HOOK_GAS = 150_000;
    uint256 public constant MAX_SUB_HOOKS = 4;

    address private immutable _sub0;
    address private immutable _sub1;
    address private immutable _sub2;
    address private immutable _sub3;
    uint16 private immutable _bps0;
    uint16 private immutable _bps1;
    uint16 private immutable _bps2;
    uint16 private immutable _bps3;
    uint256 private immutable _subCount;
    /// @dev Ceiling on everything the guests can take between them, whatever their individual
    /// budgets sum to.
    uint16 public immutable stackMaxBps;

    mapping(address subHook => mapping(Currency => uint256)) public accrued;

    /// @dev Set while dispatching. A guest cannot call PoolManager, but it can call a contract that
    /// does, so a nested swap on this pool would re-enter this callback. Dispatch is skipped rather
    /// than reverted: refusing the nested swap outright would let any guest brick the pool by
    /// arranging one.
    bool private transient _dispatching;

    error TooManySubHooks();
    error BudgetExceedsStackMax();
    error NothingAccrued();
    error WithdrawWhileDispatching();

    event SubHookPaid(address indexed subHook, Currency currency, uint256 requested, uint256 granted);
    /// @dev Only the leading selector-sized word of the failure is emitted. A guest can return
    /// megabytes of revert data, and copying it would charge the swapper for the guest's tantrum.
    event SubHookSkipped(address indexed subHook, bytes32 reason);
    event DispatchSkippedForReentrancy();
    event SubHookWithdrew(address indexed subHook, Currency currency, uint256 amount);

    constructor(
        IPoolManager poolManager_,
        address[] memory subHooks,
        uint16[] memory budgetsBps,
        uint16 stackMaxBps_,
        address[] memory invariants_
    ) AssayBaseHook(poolManager_, invariants_) {
        if (subHooks.length > MAX_SUB_HOOKS || subHooks.length != budgetsBps.length) {
            revert TooManySubHooks();
        }
        if (stackMaxBps_ > BPS) revert BudgetExceedsStackMax();
        for (uint256 i = 0; i < budgetsBps.length; ++i) {
            if (budgetsBps[i] > stackMaxBps_) revert BudgetExceedsStackMax();
        }

        _subCount = subHooks.length;
        _sub0 = subHooks.length > 0 ? subHooks[0] : address(0);
        _sub1 = subHooks.length > 1 ? subHooks[1] : address(0);
        _sub2 = subHooks.length > 2 ? subHooks[2] : address(0);
        _sub3 = subHooks.length > 3 ? subHooks[3] : address(0);
        _bps0 = budgetsBps.length > 0 ? budgetsBps[0] : 0;
        _bps1 = budgetsBps.length > 1 ? budgetsBps[1] : 0;
        _bps2 = budgetsBps.length > 2 ? budgetsBps[2] : 0;
        _bps3 = budgetsBps.length > 3 ? budgetsBps[3] : 0;
        stackMaxBps = stackMaxBps_;
    }

    /// @dev afterSwap plus its delta bit, and nothing else. The stack claims exactly the authority
    /// it needs to host guests and no more, which is itself checkable from the deployed address.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function subHooks() public view returns (address[] memory out, uint16[] memory budgets) {
        out = new address[](_subCount);
        budgets = new uint16[](_subCount);
        if (_subCount > 0) (out[0], budgets[0]) = (_sub0, _bps0);
        if (_subCount > 1) (out[1], budgets[1]) = (_sub1, _bps1);
        if (_subCount > 2) (out[2], budgets[2]) = (_sub2, _bps2);
        if (_subCount > 3) (out[3], budgets[3]) = (_sub3, _bps3);
    }

    /// @notice A guest collects what the stack granted it. Separate from the swap on purpose.
    function withdraw(Currency currency) external {
        // Guests are called with `call`, so one could reenter here mid-swap. Nothing is currently
        // stealable that way -- a guest's grant is credited only after its own call returns, and it
        // can only withdraw its own balance -- but moving tokens while the stack is mid-dispatch and
        // has not yet taken from PoolManager is not a state worth reasoning about every time this
        // contract changes.
        if (_dispatching) revert WithdrawWhileDispatching();
        uint256 amount = accrued[msg.sender][currency];
        if (amount == 0) revert NothingAccrued();
        accrued[msg.sender][currency] = 0;
        currency.transfer(msg.sender, amount);
        emit SubHookWithdrew(msg.sender, currency, amount);
    }

    function _assayAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (_subCount == 0) return (this.afterSwap.selector, int128(0));
        if (_dispatching) {
            emit DispatchSkippedForReentrancy();
            return (this.afterSwap.selector, int128(0));
        }

        (Currency unspecified, uint256 notional) = _unspecified(key, params, delta);
        if (notional == 0) return (this.afterSwap.selector, int128(0));

        _dispatching = true;
        uint256 total;
        uint256 ceiling = FullMath.mulDiv(notional, stackMaxBps, BPS);

        // Encoded once, outside the loop: identical for every guest, and threading the four
        // callback arguments through the loop overflows the stack.
        bytes memory callData = abi.encodeCall(IAssaySubHook.assayAfterSwap, (sender, key, params, delta));

        (address[] memory hooks, uint16[] memory budgets) = subHooks();
        for (uint256 i = 0; i < hooks.length; ++i) {
            uint256 room = ceiling - total;
            if (room == 0) break;
            uint256 granted = _dispatchOne(hooks[i], budgets[i], notional, room, unspecified, callData);
            if (granted > 0) {
                accrued[hooks[i]][unspecified] += granted;
                total += granted;
            }
        }
        _dispatching = false;

        if (total > 0) {
            unspecified.take(poolManager, address(this), total, false);
        }
        return (this.afterSwap.selector, total.toInt128());
    }

    function _dispatchOne(
        address subHook,
        uint16 budgetBps,
        uint256 notional,
        uint256 room,
        Currency currency,
        bytes memory callData
    ) private returns (uint256 granted) {
        // Bounded returndata copy, for the same reason PredicateSandbox uses one: Solidity's
        // `(bool, bytes memory)` form copies EVERYTHING the callee returns, so a guest returning a
        // few hundred KB would charge the swapper for the memory expansion on every single swap.
        // Never let untrusted code choose how much memory the caller allocates.
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            ok := call(SUB_HOOK_GAS, subHook, 0, add(callData, 0x20), mload(callData), 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (!ok || size != 32) {
            // A broken guest is skipped, never fatal. Its failure is logged so a pool's users can
            // see which guest misbehaves without it costing them their swap.
            emit SubHookSkipped(subHook, bytes32(word));
            return 0;
        }

        uint256 requested = word;
        uint256 budget = FullMath.mulDiv(notional, budgetBps, BPS);
        granted = requested < budget ? requested : budget;
        if (granted > room) granted = room;
        emit SubHookPaid(subHook, currency, requested, granted);
    }

    function _unspecified(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        pure
        returns (Currency currency, uint256 notional)
    {
        int128 amount;
        (currency, amount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        notional = amount >= 0 ? uint256(uint128(amount)) : uint256(uint128(-amount));
    }
}
