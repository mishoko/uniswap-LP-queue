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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
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
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

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

    /// @dev PHASE 2, PROVISIONAL. Seats are granted by arrival order, which PLAN §B.8 and PITFALLS
    ///      5.8 both record as NOT SHIPPABLE: rank must be BOUGHT or Harberger-held, never granted,
    ///      or the head is dust-griefable. Phase 3 replaces this mapping with the ERC-6909 rank
    ///      token. It carries a named test (`test_KNOWN_HOLE_rankIsGrantedByArrivalOrder`).
    mapping(uint256 seatId => address) internal seatOwner;

    bool internal bound;

    /// @dev The pool this hook was deployed to serve, fixed at construction. See the constructor.
    Currency internal immutable expected0;
    Currency internal immutable expected1;
    uint24 internal immutable expectedFee;
    int24 internal immutable expectedSpacing;

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
    error NotSeatOwner(uint256 seatId, address caller);
    error OverEntitlement(uint256 want, uint256 have);
    error NothingDeposited();
    error PoolNotBound();
    error AlreadyBound();
    error WrongPool();
    /// @dev `modifyLiquidity` charged more than the caller supplied. Structurally prevented by
    ///      sizing one unit of liquidity BELOW the amounts on hand; loud rather than silent because
    ///      the alternative is quietly spending float that belongs to other seats.
    error DepositOversized(uint256 used, uint256 supplied);

    /// @dev The pool this hook will serve is fixed AT DEPLOYMENT, not by whoever initializes
    ///      first. Without this, anyone could front-run the intended `poolManager.initialize` and
    ///      bind a freshly deployed hook to a junk pool — permanently, since there is no admin to
    ///      unbind it. A free, unrecoverable DoS. Committing the parameters here costs nothing: the
    ///      hook serves exactly one pool by design.
    constructor(IPoolManager pm, Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing) BaseHook(pm) {
        expected0 = currency0;
        expected1 = currency1;
        expectedFee = fee;
        expectedSpacing = tickSpacing;
    }

    // -------------------------------------------------------------------------- permissions (§B.2)

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true; // bind the one pool this hook serves
        p.beforeAddLiquidity = true; // refuse every external LP — the hook is the sole LP
        p.beforeSwap = true; // open the protocol-fee measurement window
        p.afterSwap = true; // allocate the fill
    }

    // ------------------------------------------------------------------------------------ callbacks

    /// @notice Bind the single pool this hook serves.
    /// @dev Capturing the key here rather than through a setter is deliberate. A permissionless
    ///      `initialize(PoolKey)` would let anyone point the hook at a pool of their choosing; a
    ///      guarded one would be a privileged role, which is forbidden. `afterInitialize` can only
    ///      ever be called by PoolManager, and only for a pool whose key already names THIS hook,
    ///      so the binding is authenticated by construction. The second pool is refused.
    function _afterInitialize(address, PoolKey calldata k, uint160, int24) internal override returns (bytes4) {
        if (bound) revert AlreadyBound();
        if (
            Currency.unwrap(k.currency0) != Currency.unwrap(expected0)
                || Currency.unwrap(k.currency1) != Currency.unwrap(expected1) || k.fee != expectedFee
                || k.tickSpacing != expectedSpacing
        ) revert WrongPool();
        bound = true;
        key = k;
        tickLower = TickMath.minUsableTick(k.tickSpacing);
        tickUpper = TickMath.maxUsableTick(k.tickSpacing);
        return BaseHook.afterInitialize.selector;
    }

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

    // ============================================================== DEPOSIT / WITHDRAW (Phase 2)

    /// @notice Open a new seat at the TAIL of the queue and fund it.
    /// @dev Seats append at the tail and change no cursor, so opening one can never disturb
    ///      INVARIANT C for the seats already in front.
    function deposit(uint256 amount0, uint256 amount1) external returns (uint256 seatId) {
        seatId = q.length;
        q.push(Seat({a0: 0, a1: 0}));
        seatOwner[seatId] = msg.sender;
        _fundSeat(seatId, amount0, amount1);
    }

    /// @notice Add capital to a seat you already own.
    function addToSeat(uint256 seatId, uint256 amount0, uint256 amount1) external {
        if (seatOwner[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        _fundSeat(seatId, amount0, amount1);
    }

    function _fundSeat(uint256 seatId, uint256 amount0, uint256 amount1) internal {
        if (!bound) revert PoolNotBound();
        if (amount0 == 0 && amount1 == 0) revert NothingDeposited();

        if (amount0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        uint256 used0;
        uint256 used1;
        uint128 dl = _liquidityForAmounts(amount0, amount1);
        if (dl != 0) {
            (used0, used1) = _modifyPosition(int256(uint256(dl)));
            liquidity += dl;
            // Cannot happen: `_liquidityForAmounts` sizes one unit BELOW what is on hand. If it
            // ever does, the excess would be silently taken from float owed to OTHER seats.
            if (used0 > amount0) revert DepositOversized(used0, amount0);
            if (used1 > amount1) revert DepositOversized(used1, amount1);
        }

        // OWNER DECISION 2026-08-27 — ABSORB, do not refund. PLAN §B.7 originally said "refund any
        // unconsumed remainder to msg.sender". Under a float that is the worse answer: absorbing it
        // costs no transfer and it SHRINKS the float that `sweepFloatIntoPosition` has to work
        // against. The depositor keeps the full value either way — as ledger credit rather than
        // returned tokens — so INVARIANT F still holds exactly:
        //     consumed goes into the position, remainder goes into floatX, seat is credited both.
        float0 += amount0 - used0;
        float1 += amount1 - used1;

        Seat storage s = q[seatId];
        s.a0 += amount0;
        s.a1 += amount1;

        // TOPPING UP A SEAT BELOW A CURSOR WOULD MAKE THAT CURSOR LEAD. Opening a seat at the tail
        // cannot, but `addToSeat` on an exhausted seat re-funds it in place, and a cursor that has
        // already advanced past it would then skip a funded seat — silent theft of rank.
        if (seatId < cursor0) cursor0 = seatId;
        if (seatId < cursor1) cursor1 = seatId;
    }

    /// @notice Withdraw from a seat you own, paying from the shared float and topping the float up
    ///         from the position only when it cannot cover the request.
    ///
    /// @dev THE MECHANISM, and why it needs a float at all. A v4 position releases the two tokens in
    ///      a ratio fixed by price and range. Front-first allocation deliberately drives seats to
    ///      single-token composition, so a seat's LEDGER composition is generally NOT payable by any
    ///      proportional removal. Measured: a 100%-converted seat could withdraw NOTHING via
    ///      `modifyLiquidity(-D)`.
    ///
    ///      The resolution is to size the removal on the leg that BINDS, pay the seat its exact
    ///      ledger amounts, and retain the surplus as float shared by the whole queue. INVARIANT F
    ///      is what makes paying first-come-first-served out of a shared pot safe.
    ///
    ///      **`withdraw` MUST NEVER CALL `poolManager.swap`.** Rebalancing by swapping would put the
    ///      allocator inside its own withdrawal and skim an unaccounted protocol fee. `_burnPosition`
    ///      only ever calls `modifyLiquidity`.
    function withdraw(uint256 seatId, uint256 w0, uint256 w1) external returns (uint256 p0, uint256 p1) {
        if (seatOwner[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        Seat storage s = q[seatId];
        if (w0 > s.a0) revert OverEntitlement(w0, s.a0);
        if (w1 > s.a1) revert OverEntitlement(w1, s.a1);

        uint256 d0 = w0 > float0 ? w0 - float0 : 0;
        uint256 d1 = w1 > float1 ? w1 - float1 : 0;
        if (d0 != 0 || d1 != 0) {
            uint128 dl = _liquidityToCover(d0, d1);
            if (dl != 0) {
                (uint256 g0, uint256 g1) = _burnPosition(dl); // decrements `liquidity` (PITFALLS 5.23)
                float0 += g0;
                float1 += g1;
            }
        }

        // DUST POLICY F1 (PLAN §B.7): pay `min(face, available)`. Face value is an UPPER BOUND, not
        // a promise. v4 computes a swap's amounts and a position's redeemable value with two
        // differently-rounded formulas, so the queue's face value redeems for a few wei LESS —
        // ~0.26 wei per swap, unfarmable but real. Paying face exactly makes the LAST withdrawer's
        // call revert; F1 spreads the residual over whoever withdraws instead of dumping it on them.
        (w0, w1) = _applyDustPolicy(w0, w1);

        s.a0 -= w0;
        s.a1 -= w1;
        float0 -= w0;
        float1 -= w1;

        // Cursors are deliberately NOT touched. A withdrawal only ever REDUCES a seat, so it cannot
        // make a cursor lead; leaving them costs a little gas and can never lose money.
        // Withdrawing to zero does NOT destroy the seat: an empty seat is pure rank with no capital,
        // and being able to hold, price and sell one is what gives rank a price of its own.

        if (w0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransfer(msg.sender, w0);
        if (w1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(msg.sender, w1);
        (p0, p1) = (w0, w1);
    }

    /// @dev DUST POLICY F1, isolated behind a seam so the mandatory negative control can replace it
    ///      with face-value payment and prove the policy is doing something. Without a control, a
    ///      few hundred wei of shortfall after a few hundred swaps is invisible.
    function _applyDustPolicy(uint256 w0, uint256 w1) internal view virtual returns (uint256, uint256) {
        if (w0 > float0) w0 = float0;
        if (w1 > float1) w1 = float1;
        return (w0, w1);
    }

    /// @notice Push idle float back into the position. Permissionless, credits nobody.
    ///
    /// @dev REQUIRED, not an optimisation. Seats withdraw imbalanced legs, so every withdrawal
    ///      leaves surplus of the other token sitting outside the position. Without this,
    ///      **pool depth degrades monotonically** as the queue is used.
    ///
    ///      It credits NOBODY on purpose: the float is already credited to seats through
    ///      INVARIANT F, so moving it from `floatX` into the position changes no seat's ledger. That
    ///      is exactly why it is safe to let anyone call it — there is nothing to direct anywhere.
    function sweepFloatIntoPosition() external returns (uint128 added) {
        if (!bound) revert PoolNotBound();
        added = _liquidityForAmounts(float0, float1);
        if (added == 0) return 0;

        (uint256 u0, uint256 u1) = _modifyPosition(int256(uint256(added)));
        liquidity += added;
        if (u0 > float0) revert DepositOversized(u0, float0);
        if (u1 > float1) revert DepositOversized(u1, float1);
        float0 -= u0;
        float1 -= u1;
    }

    // ---------------------------------------------------------------------------- liquidity sizing

    /// @dev How much liquidity `(amount0, amount1)` can buy — the MIN leg, because we must not need
    ///      more of either token than we hold.
    ///
    ///      An earlier version shaved one unit off the result as insurance against the round trip
    ///      asking for more than went in. IT IS NOT NEEDED and it is gone: `getLiquidityFor*` floors
    ///      and `modifyLiquidity`'s charge ceils, so the round trip is `ceil(floor(x*k)/k) <= x` for
    ///      integer x. 5,000 fuzz runs with the shave removed found no counterexample
    ///      (`testFuzz_2_19_depositNeverChargesMoreThanSupplied`), and `DepositOversized` is the loud
    ///      backstop if that reasoning is ever wrong. Mutation testing flagged the shave as a line
    ///      nothing could detect the removal of — which is what an unnecessary line looks like.
    function _liquidityForAmounts(uint256 amount0, uint256 amount1) internal view returns (uint128) {
        if (amount0 == 0 && amount1 == 0) return 0;
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount0, amount1
        );
        return l;
    }

    /// @dev How much liquidity must be REMOVED to release at least `need0`/`need1`.
    ///      THE LOAD-BEARING LINE is the MAX: size on the leg that BINDS. Sizing on the min leg
    ///      under-delivers and the withdrawal comes up short.
    function _liquidityToCover(uint256 need0, uint256 need1) internal view returns (uint128) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 l0 = need0 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount0(sqrtP, hi, need0);
        uint128 l1 = need1 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount1(lo, sqrtP, need1);
        uint256 d = l0 > l1 ? l0 : l1;
        // Both the sizing and the release round DOWN. One extra unit covers both truncations; the
        // surplus becomes float rather than a shortfall.
        if (d != 0) d += 1;
        if (d > liquidity) d = liquidity;
        // casting to 'uint128' is safe because d is clamped to `liquidity`, itself a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(d);
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

    /// @dev The single path to `modifyLiquidity`. Returns the ACTUAL token magnitudes moved, read
    ///      from the hook's own balance change — never the caller's requested amounts.
    function _modifyPosition(int256 delta) internal returns (uint256 m0, uint256 m1) {
        bytes memory res = poolManager.unlock(abi.encode(delta));
        (m0, m1) = abi.decode(res, (uint256, uint256));
    }

    function _burnPosition(uint128 liq) internal returns (uint256 g0, uint256 g1) {
        liquidity -= liq;
        return _modifyPosition(-int256(uint256(liq)));
    }

    /// @dev TEST-HARNESS SEAM ONLY (`test/queue/QueueHarness.sol`). Production binds the pool in
    ///      `_afterInitialize` and moves liquidity through `deposit`/`withdraw`.
    function _mintPosition(PoolKey memory k, int24 tl, int24 tu, uint128 liq)
        internal
        returns (uint256 m0, uint256 m1)
    {
        key = k;
        tickLower = tl;
        tickUpper = tu;
        liquidity = liq;
        return _modifyPosition(int256(uint256(liq)));
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

    function positionLiquidity() external view returns (uint128) {
        return liquidity;
    }

    function ownerOf(uint256 seatId) external view returns (address) {
        return seatOwner[seatId];
    }

    function floats() external view returns (uint256, uint256) {
        return (float0, float1);
    }
}
