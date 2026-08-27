// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Allocation} from "./libraries/Allocation.sol";

/// @title QUEUE — price-time priority for a Uniswap v4 pool
///
/// @notice The hook custodies the pool's entire liquidity as ONE position and keeps an ordered list
///         of seats. Every swap's aggregate entitlement is allocated FRONT-FIRST rather than
///         pro-rata: the head seat surrenders as much of the outgoing token as it holds and is
///         credited the incoming token at the swap's own realised average price.
///
///         Uniswap has never had a queue, so it has never had a price for one.
contract QueueHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;

    // --------------------------------------------------------------------------------- state (§B.3)

    struct Seat {
        uint256 a0; // token0 this seat holds
        uint256 a1; // token1 this seat holds
    }

    /// @dev index == rank. q[0] is the head. THE ORDER IS THE PRODUCT.
    Seat[] internal q;

    PoolKey internal key;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint128 internal liquidity;

    /// @dev INVARIANT C (§B.6): for each token X, every seat at index < cursorX holds aX == 0.
    ///      A cursor may LAG (the loop's `continue` handles an empty seat). It must never LEAD —
    ///      leading skips a funded seat, which is silent theft of rank.
    uint256 internal cursor0;
    uint256 internal cursor1;

    /// @dev Token held OUTSIDE the position but owed to the queue. Phase 2 (withdrawal) fills
    ///      these; they are declared here so INVARIANT F is asserted from Phase 1 onward and cannot
    ///      be silently broken when Phase 2 lands.
    ///
    ///      INVARIANT F:  sum(q[i].aX) == (X redeemable from the position) + floatX,
    ///                    to within the §E.4 rounding residual.
    uint256 internal float0;
    uint256 internal float1;

    // ------------------------------------------------------------- protocol-fee snapshot (§E.5, P2)

    /// @dev Snapshot of `poolManager.protocolFeesAccrued(inputCurrency)` taken in `beforeSwap`,
    ///      stored as `value + 1` so that zero unambiguously means "not set".
    ///
    ///      TRANSIENT ON PURPOSE. See `_afterSwap` for why the window — not the counter — is the
    ///      thing that makes this correct.
    uint256 internal transient pfSnapshotPlusOne;

    // ------------------------------------------------------------------------------------- errors

    error NotSoleLiquidityProvider();
    /// @dev `beforeSwap` did not run before `afterSwap`. Structurally unreachable (Hooks.sol skips
    ///      both symmetrically on a hook self-call); loud rather than silent if that ever changes.
    error ProtocolFeeSnapshotMissing();
    /// @dev The protocol fee exceeded the swap's own input. Structurally impossible — it would mean
    ///      the measurement window caught accrual that is not this swap's. Never clamped: a clamp
    ///      would silently under-credit the queue and strand value owed to nobody.
    error ProtocolFeeExceedsInput(uint256 pfDelta, uint256 amtIn);
    error DirectionMismatch();

    constructor(IPoolManager pm) BaseHook(pm) {}

    // -------------------------------------------------------------------------- permissions (§B.2)

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true; // refuse every external LP — the hook is the sole LP
        p.beforeSwap = true; // open the protocol-fee measurement window
        p.afterSwap = true; // allocate the fill
    }

    // ------------------------------------------------------------------------------------ callbacks

    /// @dev The premise of every other number in this project: nobody but the hook may add
    ///      liquidity. Without it an external LP dilutes the position the queue is accounted
    ///      against, and conservation breaks immediately.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        virtual
        override
        returns (bytes4)
    {
        if (sender != address(this)) revert NotSoleLiquidityProvider();
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Opens the protocol-fee measurement window.
    ///
    /// @dev THIS IS THE WHOLE PROTOCOL-FEE FIX (§E.5 remedy P2), and it is worth stating why it is
    ///      one SLOAD rather than an arithmetic derivation.
    ///
    ///      `protocolFeesAccrued` is `mapping(Currency => uint256)` — GLOBAL PER CURRENCY, with no
    ///      PoolId in it (`ProtocolFees.sol:21`). An earlier design diffed it ACROSS TRANSACTIONS
    ///      and was therefore corrupted by every other v4 pool sharing either token: ordinary
    ///      foreign volume silently under-credited the queue, and a foreign accrual larger than the
    ///      next swap's input underflowed `amtIn -= pfDelta` and bricked the pool permanently.
    ///
    ///      The counter was never the problem. THE MEASUREMENT WINDOW WAS. Between this callback
    ///      and `afterSwap`, `PoolManager.swap` executes exactly one `Pool.swap` on exactly one
    ///      pool and calls `_updateProtocolFees(inputCurrency, amountToProtocol)`
    ///      (`PoolManager.sol::_swap`). That window contains no external call, so no other pool can
    ///      accrue inside it and `collectProtocolFees` cannot run inside it. The difference is
    ///      therefore EXACTLY this swap's protocol fee, on this pool, to the wei.
    ///
    ///      Because it is read rather than derived, none of the arithmetic hazards apply: no
    ///      per-step rounding across tick crossings, no `lpFee == 0` whole-`feeAmount` special case,
    ///      no exact-output rounding direction. And because the snapshot is TRANSIENT it cannot
    ///      survive the transaction, so a stale or never-initialised snapshot is impossible by
    ///      construction rather than by convention.
    function _beforeSwap(address, PoolKey calldata k, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Currency inputCurrency = params.zeroForOne ? k.currency0 : k.currency1;
        pfSnapshotPlusOne = poolManager.protocolFeesAccrued(inputCurrency) + 1;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Allocate the swap front-first.
    function _afterSwap(address, PoolKey calldata k, SwapParams calldata params, BalanceDelta d, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Step 1 — the sole LP's entitlement is exactly the NEGATION of the swapper's delta. Nothing
        // here is the hook's opinion; the numbers come from PoolManager.
        int256 e0 = -int256(d.amount0());
        int256 e1 = -int256(d.amount1());

        uint256 snap = pfSnapshotPlusOne;
        if (snap == 0) revert ProtocolFeeSnapshotMissing();

        if (e0 == 0 && e1 == 0) return (BaseHook.afterSwap.selector, 0);

        // Step 2 — name the direction. Take it from `params`, which is what PoolManager itself
        // uses to decide the input currency — NOT from the sign of the delta. A dust swap whose
        // output rounds to zero leaves `e1 == 0`, and a sign test then reads the direction
        // backwards. (Measured: swaps of 1-3 wei on a 0.30% pool do exactly this.)
        bool outIsOne = params.zeroForOne;

        // What must still hold, whatever the magnitudes: the pool GAINS the input token and PAYS
        // the output token. Zero is allowed on either leg; a sign flip is not.
        if (outIsOne ? (e0 < 0 || e1 > 0) : (e1 < 0 || e0 > 0)) revert DirectionMismatch();

        // Casting to `uint256` is safe because the sign check directly above proves the input leg
        // is >= 0 and the output leg is <= 0, and both originate as `int128` so negation cannot
        // overflow int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amtOut = outIsOne ? uint256(-e1) : uint256(-e0);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amtIn = outIsOne ? uint256(e0) : uint256(e1);

        // Step 2b — net out THIS SWAP'S protocol fee. `amtIn` as the delta reports it is what the
        // SWAPPER PAID; the position only received it net of the protocol skim. Crediting the
        // ledger from the pre-skim side while backing it with the post-skim position is exactly the
        // §E.5 silent insolvency.
        Currency inputCurrency = params.zeroForOne ? k.currency0 : k.currency1;
        uint256 pfDelta = poolManager.protocolFeesAccrued(inputCurrency) - (snap - 1);
        if (pfDelta > amtIn) revert ProtocolFeeExceedsInput(pfDelta, amtIn);
        amtIn -= pfDelta;

        // Step 2c — THE DEGENERATE FILL. The pool took input but paid nothing out, so no seat gives
        // anything up and front-first ordering has no meaning. The input is still owed to the
        // queue: dropping it would leave the ledger UNDER-counting the position, stranding value
        // owed to nobody — the same pathology as the protocol-fee under-credit.
        //
        // It goes to the seat the fill WOULD have started at, which is what front-first means when
        // there is only one claimant. Spamming it is not an attack: the gas costs orders of
        // magnitude more than the wei moved, and it favours the head, which is already the
        // mechanism's stated preference.
        if (amtOut == 0) {
            if (amtIn != 0 && q.length != 0) {
                uint256 start = outIsOne ? cursor1 : cursor0;
                uint256 idx = start < q.length ? start : 0;
                if (outIsOne) q[idx].a0 += amtIn;
                else q[idx].a1 += amtIn;
            }
            return (BaseHook.afterSwap.selector, 0);
        }

        _allocate(outIsOne, amtIn, amtOut);
        return (BaseHook.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------------------- the allocator

    /// @dev `virtual` for ONE reason: the mandatory negative controls (§D.3 N1-N4) subclass this
    ///      and change exactly one line each. Nothing in production overrides it.
    function _allocate(bool outIsOne, uint256 amtIn, uint256 amtOut) internal virtual {
        uint256 n = q.length;
        uint256 start = outIsOne ? cursor1 : cursor0;

        Allocation.State memory st = Allocation.init(amtIn, amtOut);
        uint256 next = start;

        // Drive the arithmetic DIRECTLY OVER STORAGE, from the cursor, stopping the moment the swap
        // is sourced. This is the point of having cursors at all: a head-only swap must touch one
        // seat, not the whole roster. (An earlier draft of this function loaded every seat into a
        // memory array first, which read the entire queue on every swap and silently threw the
        // cursor optimisation away.)
        for (uint256 i = start; i < n && st.remaining > 0; i++) {
            Seat storage seat_ = q[i];
            uint256 bal = outIsOne ? seat_.a1 : seat_.a0;
            if (bal == 0) continue;

            (uint256 take, uint256 give) = Allocation.step(st, bal);

            if (outIsOne) {
                seat_.a1 = bal - take;
                seat_.a0 += give;
            } else {
                seat_.a0 = bal - take;
                seat_.a1 += give;
            }

            // INVARIANT C: advance past this seat only if it was fully consumed. A lagging cursor
            // costs gas; a leading cursor skips a funded seat, which is silent theft of rank.
            next = take == bal ? i + 1 : i;
        }

        if (st.remaining != 0) revert Allocation.QueueUnderflow(st.remaining);

        // The OUTGOING token's cursor advances. The INCOMING token's cursor must be pulled BACK to
        // `start`: this fill just credited token Y to seats from `start` upward, so if cursorY now
        // leads it would skip a funded seat on the next Y-outgoing swap. That is the line people
        // forget, and it loses money rather than gas.
        if (outIsOne) {
            cursor1 = next;
            if (start < cursor0) cursor0 = start;
        } else {
            cursor0 = next;
            if (start < cursor1) cursor1 = start;
        }
    }

    // ------------------------------------------------------------------- position mint / burn

    // NOTE: Phase 1 deliberately exposes NO external way to move liquidity.
    //
    // An earlier draft had a permissionless `seed()` and a permissionless `redeemAll()` on this
    // contract. Both were real holes, not merely untidy scaffolding:
    //   * `seed()` funds the position from THE HOOK'S OWN BALANCE, so the first caller of a
    //     pre-funded deployment would have claimed the entire queue for free.
    //   * `redeemAll()` burns the WHOLE position and can be called by anyone — pure griefing, and
    //     catastrophic the moment real depositors exist.
    // They now live in `test/queue/QueueHarness.sol`, which is test-only code. Phase 2 adds the
    // real `deposit()` / `withdraw()` in their place, per-seat and paying the caller.

    function _mintPosition(PoolKey memory k, int24 tl, int24 tu, uint128 liq)
        internal
        returns (uint256 m0, uint256 m1)
    {
        key = k;
        tickLower = tl;
        tickUpper = tu;
        liquidity = liq;
        bytes memory res = poolManager.unlock(abi.encode(int256(uint256(liq))));
        (m0, m1) = abi.decode(res, (uint256, uint256));
    }

    function _burnPosition(uint128 liq) internal returns (uint256 g0, uint256 g1) {
        liquidity -= liq;
        bytes memory res = poolManager.unlock(abi.encode(-int256(uint256(liq))));
        (g0, g1) = abi.decode(res, (uint256, uint256));
    }

    function _pushSeat(uint256 a0, uint256 a1) internal {
        q.push(Seat({a0: a0, a1: a1}));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotSoleLiquidityProvider();
        int256 delta = abi.decode(data, (int256));

        uint256 b0Before = _balance(key.currency0);
        uint256 b1Before = _balance(key.currency1);

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: bytes32(0)
            }),
            ""
        );

        _resolve(key.currency0, callerDelta.amount0());
        _resolve(key.currency1, callerDelta.amount1());

        uint256 m0 = delta > 0 ? b0Before - _balance(key.currency0) : _balance(key.currency0) - b0Before;
        uint256 m1 = delta > 0 ? b1Before - _balance(key.currency1) : _balance(key.currency1) - b1Before;
        return abi.encode(m0, m1);
    }

    /// @dev Settlement goes through v4's own `CurrencySettler`, which uses `SafeERC20` and handles
    ///      native currency and non-compliant tokens (the ones that return nothing from
    ///      `transfer`). A hand-rolled `IERC20Minimal.transfer` here ignores the return value: a
    ///      token that fails by returning `false` would be treated as paid.
    function _resolve(Currency c, int128 amt) internal {
        if (amt < 0) {
            // Widen to int256 BEFORE negating: `-type(int128).min` does not fit in int128.
            // casting to 'uint256' is safe because the branch proves amt < 0, so -int256(amt) > 0
            // forge-lint: disable-next-line(unsafe-typecast)
            c.settle(poolManager, address(this), uint256(-int256(amt)), false);
        } else if (amt > 0) {
            // casting to 'uint256' is safe because the branch proves amt > 0
            // forge-lint: disable-next-line(unsafe-typecast)
            c.take(poolManager, address(this), uint256(int256(amt)), false);
        }
    }

    function _balance(Currency c) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this));
    }

    // --------------------------------------------------------------------------------------- views

    function seatCount() external view returns (uint256) {
        return q.length;
    }

    function seat(uint256 i) external view returns (uint256, uint256) {
        return (q[i].a0, q[i].a1);
    }

    function totals() external view returns (uint256 t0, uint256 t1) {
        for (uint256 i; i < q.length; i++) {
            t0 += q[i].a0;
            t1 += q[i].a1;
        }
    }

    function cursors() external view returns (uint256, uint256) {
        return (cursor0, cursor1);
    }

    function floats() external view returns (uint256, uint256) {
        return (float0, float1);
    }
}
