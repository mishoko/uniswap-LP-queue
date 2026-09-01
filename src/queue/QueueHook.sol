// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Allocation} from "./libraries/Allocation.sol";
import {Rent} from "./libraries/Rent.sol";
import {QueueSeats} from "./QueueSeats.sol";

/// @title QUEUE — a priced, front-first fill queue for a Uniswap v4 pool
///
/// @notice The hook custodies ONE concentrated Uniswap position — a band around the start price —
///         and keeps an ordered list of seats that share it. Every swap's in-band fill is allocated
///         FRONT-FIRST rather than pro-rata: the head seat surrenders as much of the outgoing token
///         as it holds and is credited the incoming token at the swap's own realised average price.
///
///         Liquidity that does not overlap that band is ordinary Uniswap. Anyone may LP the wings
///         through PositionManager. Overlapping the band is refused: that is the free lane that
///         dilutes the position the queue is accounted against (N5).
///
///         Uniswap has never had a queue, so it has never had a price for one — which did not make
///         the ordering worthless. It made it unpriceable INSIDE the pool, and therefore captured
///         OUTSIDE it, at the sequencer. This contract is the pool taking it back.
///
///         **It is NOT price-time priority.** The roster is closed and rank goes to willingness to
///         pay rent, not to arrival. Rank is scarce ON PURPOSE — free rank is griefable rank and
///         unbounded rank has no price — and leased rather than owned, so a scarce roster cannot
///         become a cartel. Scarce, but never capturable. See `README.md`.
contract QueueHook is BaseHook, QueueSeats, IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint16;
    using ProtocolFeeLibrary for uint24;
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------------------- state (§B.3)

    /// @dev **ONE SLOT, TWO BALANCES (Phase 5b).** The pair was two `uint256`s, which cost the
    ///      allocator's hot loop two cold `SLOAD`s and two `SSTORE`s per seat walked. Packed, a
    ///      seat is one slot: the second read of the pair is warm and the second write is dirty.
    ///      **Measured: 12,254 -> 7,326 gas per seat walked**, on a complete swap transaction
    ///      through the real router.
    ///
    ///      `uint128` cannot bind on any state Uniswap itself can represent. v4 settles in
    ///      `BalanceDelta`, a pair of `int128`s, so no position it can account for holds more than
    ///      `2^127 - 1` of either token — and a seat's balance is a claim on that position. The
    ///      bound is nonetheless CHECKED rather than assumed: every narrowing in this contract goes
    ///      through `_u128`, which reverts. A silent wrap here would mint balance out of nothing.
    struct Seat {
        uint128 a0; // token0 this seat holds
        uint128 a1; // token1 this seat holds
    }

    /// @dev **INDEX IS SEAT ID, NOT RANK.** It was both up to Phase 3, because nothing could
    ///      permute the queue; Phase 4's foreclosure demotes a seat to the tail, so the two numbers
    ///      come apart and `order` below is what separates them. Everything keyed to a SEAT —
    ///      capital, holder, lease — is keyed by id and never moves. Only the ORDER moves.
    Seat[] internal q;

    /// @dev **RANK. THE ORDER IS THE PRODUCT, AND THIS ONE WORD IS THE WHOLE OF IT.**
    ///
    ///      Byte `r` (counting from the low end) holds the id of the seat at rank `r`; rank 0 is
    ///      the head. `MAX_SEATS == 32` is exactly why the entire order fits in one slot, which is
    ///      not a trick but the reason the bound is 32 — a demotion rewrites the queue's order in
    ///      ONE `SSTORE`, and the allocator reads the whole order in ONE `SLOAD` no matter how deep
    ///      it walks.
    ///
    ///      There is deliberately NO `rankOfId` mapping. A second copy of the order would be a
    ///      writer/reader pair that can disagree, and on this project a rule that lives in two
    ///      places has now been wrong FOUR times (PITFALLS 5.37, 5.50, 5.52 twice). `rankOfId`
    ///      scans this word instead: one `SLOAD` and at most 32 comparisons in memory.
    uint256 internal order;

    PoolKey internal key;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint128 internal liquidity;

    /// @notice Half-width of the custodied Uniswap position, in ticks. **A DEPLOYMENT PARAMETER.**
    ///
    ///         Uniswap's product is a RANGE around the current price. QUEUE once sat that range at
    ///         the full usable curve — $0 to infinity — which is not how anyone LPs on Uniswap, and
    ///         which is why a dollar of QUEUE liquidity quoted ~1/200th the depth of a ±1% v3
    ///         position. The hook still holds ONE position (not one NFT per seat). The seats share
    ///         that band. The queue is who gets filled first *inside the same price Uniswap already
    ///         uses*.
    ///
    ///         **THIS IS THE MECHANISM'S MAIN ECONOMIC DIAL AND IT BELONGS TO THE DEPLOYER, NOT TO
    ///         A CONSTANT A TEST HAPPENED TO USE.** Band width sets the position's depth at the
    ///         money; depth sets how large a swap must be to reach rank 2, and therefore how many
    ///         seats are ever filled at all. A stablecoin pair wants tens of ticks; a volatile pair
    ///         wants thousands. Shipping 960 for every pair forever was a leftover, not a decision:
    ///         it was chosen because `test_1_11` already ran the allocator over a ±10% band.
    ///
    ///         Immutable for the same reason τ is: a band somebody can move afterwards is a
    ///         privileged role over the depth everyone else's capital is standing in, and this
    ///         contract has no privileged role at all. 960 ticks ≈ +10.08% / −9.16% in price at v3
    ///         tick math. Snapped to the pool's spacing at `_afterInitialize`.
    int24 public immutable BAND_HALF_WIDTH;

    /// @dev INVARIANT C (§B.6): for each token X, every seat at index < cursorX holds aX == 0.
    ///      A cursor may LAG (the loop's `continue` handles an empty seat). It must never LEAD —
    ///      leading skips a funded seat, which is silent theft of rank.
    uint256 internal cursor0;
    uint256 internal cursor1;

    /// @dev Token held OUTSIDE the position but owed to the queue. Phase 2 (withdrawal) fills
    ///      these; they are declared here so INVARIANT F is asserted from Phase 1 onward and cannot
    ///      be silently broken when Phase 2 lands.
    ///
    ///      INVARIANT F:  sum(q[i].aX) + pendingTotalX == (X redeemable from the position) + floatX,
    ///                    to within the §E.4 rounding residual.
    uint256 internal float0;
    uint256 internal float1;

    /// @dev What a departing seat holder is still owed after their seat was evacuated, in the rare
    ///      case the position could not release the whole ledger amount on the spot.
    ///
    ///      THIS IS RESIDUAL-SCALE STATE, NOT A PARALLEL LEDGER, and the difference is the whole
    ///      reason the mechanism is safe — see `_onSeatTransfer`.
    mapping(address holder => uint256) internal pending0;
    mapping(address holder => uint256) internal pending1;
    /// @dev Aggregates, kept so INVARIANT F stays a two-read assertion rather than a sum over an
    ///      unbounded set of addresses. Written in exactly the two places the per-address maps are.
    uint256 internal pendingTotal0;
    uint256 internal pendingTotal1;

    bool internal bound;

    // ================================================================ HARBERGER (Phase 4, §B.10)

    /// @notice The always-for-sale lease on one seat.
    ///
    /// @dev Four numbers, and every one of them is set by the seat's own holder. There is no mark,
    ///      no oracle, no collateral and no liquidation anywhere in this struct or anything that
    ///      touches it — see `_settleSeat` for why foreclosure is a DEMOTION and not a seizure.
    struct Lease {
        /// @dev The holder's own assessment, in `currency0`. Rent is charged on it and the seat is
        ///      always for sale at it. Zero is a legal assessment and means "free to take".
        uint256 selfPrice;
        /// @dev **THE FIRM QUOTE.** The lowest price this seat has been ASKED at, or PAID for,
        ///      inside the last `FIRM_WINDOW`. See `buyPrice`.
        uint256 firmPrice;
        /// @dev Prepaid rent, in `currency0`, held OUTSIDE the position and outside the queue's
        ///      own `a0` ledger. See `fundRent`.
        uint256 escrow;
        uint64 firmUntil;
        uint64 lastSettled;
    }

    mapping(uint256 seatId => Lease) internal lease;

    /// @dev `Σ lease[id].escrow`. Kept so the currency0 balance identity is a three-read assertion
    ///      rather than a sum over the roster.
    uint256 internal escrowTotal;

    /// @dev Rent charged from a payer that had NO eligible recipient behind it — every seat behind
    ///      held `a0 == 0`. It is held, not lost, and is folded into the pot at the next settlement
    ///      that does have one (§B.10, criterion 4.3). PLAN §E.6 forbids `poolManager.donate()`.
    uint256 internal unallocatedRent0;

    /// @dev τ, in basis points per `RENT_PERIOD`. Immutable: a rent rate somebody can change is a
    ///      privileged role over everyone's money.
    uint256 public immutable RENT_BPS;
    uint256 public immutable RENT_PERIOD;

    /// @dev How long an ask stays FIRM. See `buyPrice` — this is what stops a holder from
    ///      reactively repricing out of a buyout they can see coming, which would defeat the only
    ///      property Harberger has.
    uint256 public immutable FIRM_WINDOW;

    /// @dev What the buyer just paid, handed to `_onSeatTransfer` so the firm quote can be armed at
    ///      it. TRANSIENT, so a plain `transfer` reads zero without anyone having to remember to
    ///      clear it, and so it cannot survive the transaction.
    ///
    ///      It is a side channel because the alternative is worse: `_moveSeat` is THE ONE FUNNEL
    ///      through which a seat changes hands (QueueSeats), and giving the buyout its own copy of
    ///      the evacuation is precisely the paired-path asymmetry that let anyone steal a seat in
    ///      Phase 3 (PITFALLS 5.52). One funnel, one transient word.
    uint256 internal transient paidForSeat;

    /// @dev What ONE tick of this pool can hold, from v4's own `tickSpacingToMaxLiquidityPerTick`
    ///      rather than a reimplementation of it. Inside the band the hook is the only LP
    ///      (overlapping adds revert), so the per-tick ceiling is the hook's ceiling, and
    ///      `_liquidityForAmounts` clamps to it instead of handing `modifyLiquidity` a number it
    ///      will reject.
    uint128 internal immutable MAX_LIQUIDITY_PER_TICK;

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

    /// @dev `slot0.sqrtPriceX96` as `beforeSwap` saw it. The clip in `_afterSwap` needs the start
    ///      of the traversed interval; after the swap the price has already moved. TRANSIENT for
    ///      the same reason as `pfSnapshotPlusOne`: it cannot survive the transaction.
    uint160 internal transient sqrtBefore;
    /// @dev The tick that went with `sqrtBefore`. The in-band fast path compares ticks, not
    ///      sqrt prices: `getSqrtPriceAtTick` on the common path was the gas.
    int24 internal transient tickBefore;

    // ------------------------------------------------------------------------------------- errors

    error NotSoleLiquidityProvider();
    /// @dev An outside LP tried to mint inside the queue's band. That is the N5 free lane: the
    ///      ledger would still tie out, and the position would no longer cover it. Disjoint
    ///      ranges — the wings — are ordinary Uniswap and are allowed.
    error OverlappingLiquidity(int24 addLower, int24 addUpper, int24 bandLower, int24 bandUpper);
    /// @dev `beforeSwap` did not run before `afterSwap`. Structurally unreachable (Hooks.sol skips
    ///      both symmetrically on a hook self-call); loud rather than silent if that ever changes.
    error ProtocolFeeSnapshotMissing();
    /// @dev The protocol fee exceeded the swap's own input. Structurally impossible — it would mean
    ///      the measurement window caught accrual that is not this swap's. Never clamped: a clamp
    ///      would silently under-credit the queue and strand value owed to nobody.
    error ProtocolFeeExceedsInput(uint256 pfDelta, uint256 amtIn);
    error DirectionMismatch();
    error OverEntitlement(uint256 want, uint256 have);
    error NothingDeposited();
    error PoolNotBound();
    error AlreadyBound();
    error WrongPool();
    /// @dev The band half-width is narrower than one tick spacing, or too wide to leave room for
    ///      a two-sided band inside the usable tick range.
    error BadBandWidth(int24 bandHalfWidth, int24 tickSpacing);
    /// @dev The starting price sat so close to a usable edge that a ±BAND_HALF_WIDTH band
    ///      could not be formed inside `[minUsable, maxUsable]`. Refused rather than silently
    ///      opening a full-range blob.
    error BandOutOfBounds(int24 lo, int24 hi, int24 minU, int24 maxU);
    /// @dev A hook with no seats has no queue; every swap would revert `QueueUnderflow` forever and
    ///      there is no path to add one.
    error EmptyRoster();
    error RosterTooLarge(uint256 requested, uint256 max);
    error ZeroHolder(uint256 seatId);
    /// @dev `modifyLiquidity` charged more than the caller supplied. Structurally prevented by
    ///      sizing one unit of liquidity BELOW the amounts on hand; loud rather than silent because
    ///      the alternative is quietly spending float that belongs to other seats.
    error DepositOversized(uint256 used, uint256 supplied);
    error NoSuchSeat(uint256 seatId);
    /// @dev The seat's price moved between the buyer signing and the buyer landing. Without this,
    ///      a holder watching the mempool reprices out of every buyout and the seat is never
    ///      actually for sale. `FIRM_WINDOW` is the structural half of the same defence.
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error CannotBuyOwnSeat(uint256 seatId);
    /// @dev See `Rent.MAX_SELF_PRICE` — a price that overflows the rent product is a settlement
    ///      that reverts, which is a seat that can never be foreclosed.
    error SelfPriceTooLarge(uint256 price, uint256 max);
    error BadRentParameters();
    /// @dev A seat balance would not fit in `uint128`. Unreachable through Uniswap: v4's own
    ///      deltas are `int128`, so a position it can settle never holds `2^127` of anything. Loud
    ///      rather than silent because the alternative to reverting is WRAPPING, which would erase
    ///      a seat's balance and hand the difference to nobody.
    error SeatBalanceOverflow(uint256 amount);
    /// @dev A liquidity REMOVAL debited the hook. Structurally impossible — a removal is owed both
    ///      the principal it releases and the fees it realises, and both legs of `callerDelta` are
    ///      therefore non-negative. Loud rather than silent: the alternative is treating a payment
    ///      as a receipt and crediting the float with money that left.
    error UnexpectedPositionDebit(int256 d0, int256 d1);
    /// @dev The seeding mint was CREDITED. Only reachable if the position already held accrued
    ///      fees, which a virgin position cannot.
    error UnexpectedPositionCredit(int256 d0, int256 d1);

    event SelfPriceSet(uint256 indexed seatId, uint256 price, uint256 firmPrice, uint64 firmUntil);
    event RentSettled(uint256 indexed seatId, uint256 charged, uint256 distributed, uint256 unallocated);
    /// @dev A DEMOTION, not a seizure: the seat keeps its holder and every wei of its capital, and
    ///      loses only its place in the order.
    event Foreclosed(uint256 indexed seatId, uint256 due, uint256 paid, uint256 newRank);
    event SeatBought(uint256 indexed seatId, address indexed from, address indexed to, uint256 price);
    event RentFunded(uint256 indexed seatId, address indexed payer, uint256 amount);
    event RentWithdrawn(uint256 indexed seatId, address indexed to, uint256 amount);

    /// @dev The pool this hook will serve is fixed AT DEPLOYMENT, not by whoever initializes
    ///      first. Without this, anyone could front-run the intended `poolManager.initialize` and
    ///      bind a freshly deployed hook to a junk pool — permanently, since there is no admin to
    ///      unbind it. A free, unrecoverable DoS. Committing the parameters here costs nothing: the
    ///      hook serves exactly one pool by design.
    ///
    ///      **THE FOUNDING ROSTER IS FIXED HERE TOO, AND THAT IS THE POINT OF PHASE 3.**
    ///
    ///      Until this constructor existed, a seat was created by the act of depositing: the first
    ///      caller got seat 0, the head of the queue, for one wei of each token. Rank granted by
    ///      arrival order is rank that is FREE TO OCCUPY, and a seat that is free to occupy has no
    ///      price — which makes the head dust-griefable and empties the mechanism of its content
    ///      (PLAN §B.8, §E.16; PITFALLS 5.8).
    ///
    ///      So seats are not created by any runtime path at all. The roster is minted once, here,
    ///      to named holders, and afterwards a seat can only change hands by transfer. There is no
    ///      `deposit()` that mints, no claim function, no admin that can appoint anyone: the
    ///      allocation is an immutable fact of the deployment, in the constructor arguments, on
    ///      chain, for anyone to read. That is what §B.8 means by "an explicit allocation event,
    ///      never a side effect of depositing".
    ///
    ///      **Say the limitation out loud rather than dressing it up:** whoever deploys chooses the
    ///      founding holders, exactly as an exchange's founding memberships were granted and then
    ///      traded. Phase 4 replaces the endowment with a continuously priced, always-for-sale
    ///      Harberger lease, and it is what turns "who got a seat" from a deployment decision into
    ///      a market outcome. Until then, the honest claim is the narrow one: rank cannot be
    ///      obtained by dusting, by being early, or at any price the incumbent has not accepted.
    ///
    ///      **τ, `RENT_PERIOD` and `FIRM_WINDOW` are fixed here too, and they are GOVERNANCE
    ///      PARAMETERS, not discovered constants.** They are immutable because a rent rate somebody
    ///      can change afterwards is a privileged role over everyone's money, and this contract has
    ///      no privileged role at all. §B.10 is blunt about the risk: τ is load-bearing, and on this
    ///      project a load-bearing parameter is where a pitch dies. Do not defend a value — the
    ///      suite runs the mechanism at several and makes the SIGN of the seat price the finding.
    constructor(
        IPoolManager pm,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        int24 bandHalfWidth,
        address[] memory foundingRoster,
        uint256 rentBps,
        uint256 rentPeriod,
        uint256 firmWindow
    ) BaseHook(pm) {
        expected0 = currency0;
        expected1 = currency1;
        expectedFee = fee;
        expectedSpacing = tickSpacing;
        MAX_LIQUIDITY_PER_TICK = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing);

        // τ above one whole period is expressed by SHORTENING the period, not by inflating τ; the
        // cap is what keeps `Rent.owed` exact in plain arithmetic. A zero period divides by zero and
        // a zero firm window turns the always-for-sale guarantee off entirely.
        // The upper bounds are what make every `uint64` timestamp cast below provably safe, and
        // what keeps `MAX_BPS * rentPeriod` small enough that `Rent.owed` stays exact in plain
        // arithmetic. They are not taste: an unbounded `firmWindow` makes a seat unbuyable forever
        // at a stale price, and an unbounded `rentPeriod` makes rent unpayably slow.
        if (
            rentBps > Rent.MAX_BPS || rentPeriod == 0 || rentPeriod > 3650 days || firmWindow == 0
                || firmWindow > 365 days
        ) revert BadRentParameters();

        // The band must be at least one spacing wide (a zero-width position holds nothing and
        // `_bandAround` would have to widen it silently) and must fit inside the usable tick range
        // with room for the ±half on BOTH sides, or `_afterInitialize` reverts at deploy time on
        // some starting prices and not others. Refused here, once, where it can be read — rather
        // than discovered by a pool that will not initialise.
        if (bandHalfWidth < tickSpacing || bandHalfWidth > TickMath.MAX_TICK / 2) {
            revert BadBandWidth(bandHalfWidth, tickSpacing);
        }
        BAND_HALF_WIDTH = bandHalfWidth;
        RENT_BPS = rentBps;
        RENT_PERIOD = rentPeriod;
        FIRM_WINDOW = firmWindow;

        uint256 n = foundingRoster.length;
        if (n == 0) revert EmptyRoster();
        if (n > MAX_SEATS) revert RosterTooLarge(n, MAX_SEATS);
        uint256 ord;
        for (uint256 i; i < n; i++) {
            address holder = foundingRoster[i];
            // A seat minted to `address(0)` would be a rank slot nobody can ever hold or sell, in a
            // roster whose scarcity is the product. `_moveSeat` refuses the same thing.
            if (holder == address(0)) revert ZeroHolder(i);
            q.push(Seat({a0: 0, a1: 0}));
            _mintSeat(holder, i);
            // The founding order is the identity permutation: seat i starts at rank i. Every seat
            // starts UNPRICED, which under Harberger means free to take — see `buyPrice`.
            ord |= i << (8 * i);
        }
        order = ord;
    }

    function seatCount() public view returns (uint256) {
        return q.length;
    }

    /// @dev THE ONLY NARROWING IN THIS CONTRACT. Every write to a packed seat balance goes through
    ///      it, so the rule lives in one place and one mutation can reach all of them — this
    ///      project has been bitten four times by a rule kept in two places (PITFALLS 5.37, 5.50,
    ///      5.52 twice, 5.62).
    ///
    ///      It is used even where the narrowing is provably safe (`bal - take` cannot exceed a
    ///      value that was already `uint128`). A conditional discipline is one a reviewer has to
    ///      re-derive at every call site; an unconditional one costs ~20 gas and cannot be got
    ///      wrong.
    ///      `virtual` for ONE reason, the same one `_allocate` carries: the mandatory negative
    ///      control (`WrappingQueueHook`) replaces the check with a bare truncating cast, so the
    ///      suite can show the check is load-bearing rather than decorative. Nothing in production
    ///      overrides it.
    function _u128(uint256 x) internal pure virtual returns (uint128) {
        if (x > type(uint128).max) revert SeatBalanceOverflow(x);
        // casting to 'uint128' is safe: the line directly above is the check, and it reverts.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    // ------------------------------------------------------------------------- rank ⇄ seat id

    /// @notice Which seat currently sits at `rank`. Rank 0 is the head.
    function idAtRank(uint256 rank) public view returns (uint256) {
        if (rank >= q.length) revert NoSuchSeat(rank);
        return _idAt(order, rank);
    }

    /// @dev Byte `rank` of the packed order word. The mask is what makes this a read rather than a
    ///      narrowing cast, so there is nothing for the linter or a reviewer to have to trust.
    function _idAt(uint256 ord, uint256 rank) internal pure returns (uint256) {
        return (ord >> (8 * rank)) & 0xff;
    }

    /// @notice Where seat `seatId` currently sits. Reverts for an id that does not exist.
    /// @dev A SCAN, not a stored mapping, on purpose — see `order`. One `SLOAD`, ≤ 32 memory
    ///      comparisons, and structurally incapable of disagreeing with the order it reads.
    function rankOfId(uint256 seatId) public view returns (uint256) {
        uint256 n = q.length;
        if (seatId >= n) revert NoSuchSeat(seatId);
        uint256 ord = order;
        for (uint256 r; r < n; r++) {
            if (_idAt(ord, r) == seatId) return r;
        }
        // Unreachable: `order` is a permutation of `0..n-1` and every write below preserves that.
        revert NoSuchSeat(seatId);
    }

    /// @notice Move a seat to the back of the queue, preserving the order of everything else.
    ///
    /// @dev **THIS IS THE WHOLE OF FORECLOSURE'S ENFORCEMENT**, and it is one `SSTORE`: the bytes
    ///      above `r` slide down one place and the demoted id is written at the tail.
    ///
    ///      The cursor adjustment is EXACT, not merely conservative. Ranks `r+1..n-1` each move
    ///      down one, so a cursor standing at `c > r` is describing the same seats at `c-1`; a
    ///      cursor at `c <= r` describes seats that did not move. INVARIANT C survives either way,
    ///      and the demoted seat lands at the LAST rank, which no cursor can lead.
    ///      There is deliberately NO "already at the tail" early return. It was there, and mutation
    ///      testing showed nothing could detect its removal — because the general path is EXACTLY
    ///      equivalent when `r == n-1`: `shifted` is empty, `low` is everything below, and the id is
    ///      written back where it already was. An unnecessary line is indistinguishable from an
    ///      untested one (PITFALLS 5.49), so it is gone. The only residue is that a cursor standing
    ///      at `n` is decremented to `n-1`, which is a LAG, and a lagging cursor costs gas rather
    ///      than money.
    function _demoteToTail(uint256 seatId) internal returns (uint256 newRank) {
        uint256 n = q.length;
        uint256 r = rankOfId(seatId);
        uint256 ord = order;
        uint256 low = ord & ((uint256(1) << (8 * r)) - 1);
        // Bytes `r+1..n-1` come down to `r..n-2`; byte `n-1` is left clear for the demoted id,
        // because `order` never holds anything at or above byte `n`.
        uint256 shifted = (ord >> (8 * (r + 1))) << (8 * r);
        order = low | shifted | (seatId << (8 * (n - 1)));

        if (cursor0 > r) cursor0 -= 1;
        if (cursor1 > r) cursor1 -= 1;
        newRank = n - 1;
    }

    // -------------------------------------------------------------------------- permissions (§B.2)

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true; // bind the one pool this hook serves
        p.beforeAddLiquidity = true; // refuse overlap; wings are ordinary Uniswap
        p.beforeSwap = true; // open the protocol-fee measurement window + snapshot sqrtP
        p.afterSwap = true; // allocate the in-band fill
    }

    // ------------------------------------------------------------------------------------ callbacks

    /// @notice Bind the single pool this hook serves.
    /// @dev Capturing the key here rather than through a setter is deliberate. A permissionless
    ///      `initialize(PoolKey)` would let anyone point the hook at a pool of their choosing; a
    ///      guarded one would be a privileged role, which is forbidden. `afterInitialize` can only
    ///      ever be called by PoolManager, and only for a pool whose key already names THIS hook,
    ///      so the binding is authenticated by construction. The second pool is refused.
    function _afterInitialize(address, PoolKey calldata k, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        if (bound) revert AlreadyBound();
        if (
            Currency.unwrap(k.currency0) != Currency.unwrap(expected0)
                || Currency.unwrap(k.currency1) != Currency.unwrap(expected1) || k.fee != expectedFee
                || k.tickSpacing != expectedSpacing
        ) revert WrongPool();
        bound = true;
        key = k;
        (tickLower, tickUpper) = _bandAround(sqrtPriceX96, k.tickSpacing);
        return BaseHook.afterInitialize.selector;
    }

    /// @dev Snap a ±BAND_HALF_WIDTH band around the pool's starting price, to spacing, inside
    ///      the usable tick range. This is the Uniswap v3 range the hook will custody. The
    ///      queue does not see it — the allocator sees only realised swap deltas — but the
    ///      *inventory* does, and that is the whole of the depth question.
    function _bandAround(uint160 sqrtPriceX96, int24 spacing) internal view returns (int24 lo, int24 hi) {
        int24 minU = TickMath.minUsableTick(spacing);
        int24 maxU = TickMath.maxUsableTick(spacing);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 half = _floorToSpacing(BAND_HALF_WIDTH, spacing);
        if (half < spacing) half = spacing;
        lo = _floorToSpacing(tick - half, spacing);
        hi = _floorToSpacing(tick + half, spacing);
        if (hi <= lo) hi = lo + spacing;
        if (lo < minU) lo = minU;
        if (hi > maxU) hi = maxU;
        // A start price so close to a usable edge that the band collapses is not a pool we
        // can LP. Fail loud rather than silently falling back to the full-range blob this
        // function exists to stop shipping.
        if (hi <= lo || lo < minU || hi > maxU) revert BandOutOfBounds(lo, hi, minU, maxU);
    }

    /// @dev Uniswap spacing is a floor, including on the negative side: -61 / 60 must be -2,
    ///      not -1. Solidity division truncates toward zero.
    function _floorToSpacing(int24 t, int24 spacing) internal pure returns (int24) {
        int24 c = t / spacing;
        if (t < 0 && t % spacing != 0) c -= 1;
        return c * spacing;
    }

    /// @dev Overlap is the free lane (N5): an outside LP at the SAME ticks dilutes the position
    ///      the queue is accounted against, the ledger still ties, and solvency dies. Disjoint
    ///      ranges are ordinary Uniswap — PositionManager, any router, no seat required — and
    ///      they are the subordinated tail of a crossing swap. Adjacent at a boundary is
    ///      disjoint: Uniswap ranges are [lower, upper).
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view virtual override returns (bytes4) {
        if (sender == address(this)) return BaseHook.beforeAddLiquidity.selector;
        if (params.tickUpper <= tickLower || params.tickLower >= tickUpper) {
            return BaseHook.beforeAddLiquidity.selector;
        }
        revert OverlappingLiquidity(params.tickLower, params.tickUpper, tickLower, tickUpper);
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
        (sqrtBefore, tickBefore,,) = poolManager.getSlot0(k.toId());
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Allocate the swap front-first.
    function _afterSwap(address, PoolKey calldata k, SwapParams calldata params, BalanceDelta d, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Step 1 — the swapper's delta is the WHOLE pool, wings included. The queue is owed the
        // negation of that delta clipped to its band; `_queueShare` does the clip. Nothing here
        // is the hook's opinion of price; the numbers come from PoolManager and SwapMath.
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
        // Step 2b — the queue is owed only what filled AGAINST ITS BAND. Wings are ordinary
        // Uniswap: they keep the leftover. When the swap stayed in the band this is the
        // identity (the whole delta, net of this swap's protocol fee). M70 deletes this line
        // and credits the wing fill too, which is the N5 insolvency on a disjoint range.
        (amtIn, amtOut) = _queueShare(k, params, amtIn, amtOut, pfDelta);

        // Step 2c — THE DEGENERATE FILL. The pool took input but paid nothing out, so no seat gives
        // anything up and front-first ordering has no meaning. The input is still owed to the
        // queue: dropping it would leave the ledger UNDER-counting the position, stranding value
        // owed to nobody — the same pathology as the protocol-fee under-credit.
        //
        // It goes to the seat the fill WOULD have started at, which is what front-first means when
        // there is only one claimant. Spamming it is not an attack: the gas costs orders of
        // magnitude more than the wei moved, and it favours the head, which is already the
        // mechanism's stated preference.
        //
        // **AND IT MUST PULL THE INCOMING TOKEN'S CURSOR BACK, FOR THE SAME REASON `_allocate`
        // DOES.** This path CREDITS token X to a seat at `rank`, and if `cursorX` already stands
        // beyond `rank` it now LEADS a funded seat — which the next X-outgoing swap silently skips.
        // The line was here in `_allocate` and missing here: the fifth instance on this project of
        // one rule living in two places and being right in only one of them (PITFALLS 5.73). Found
        // by the Phase 6 invariant campaign, reproduced by `test_6_1`.
        if (amtOut == 0) {
            if (amtIn != 0 && q.length != 0) {
                uint256 start = outIsOne ? cursor1 : cursor0;
                uint256 rank = start < q.length ? start : 0;
                uint256 idx = _idAt(order, rank);
                Seat storage sd = q[idx];
                if (outIsOne) {
                    sd.a0 = _u128(uint256(sd.a0) + amtIn);
                    if (rank < cursor0) cursor0 = rank;
                } else {
                    sd.a1 = _u128(uint256(sd.a1) + amtIn);
                    if (rank < cursor1) cursor1 = rank;
                }
            }
            return (BaseHook.afterSwap.selector, 0);
        }

        _allocate(outIsOne, amtIn, amtOut);
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @dev Cap the observed swap to the fill that happened inside `[tickLower, tickUpper)`.
    ///
    ///      Price is monotonic in a swap, so a swap that starts AND ends inside the band cannot
    ///      have touched a disjoint wing. That is the common path and it is the identity: net
    ///      out this swap's protocol fee and return the delta unchanged.
    ///
    ///      A swap that leaves or enters the band is reconstructed with one `computeSwapStep`
    ///      over the overlap of the traversed interval and the band. L is constant across one
    ///      position, so one step is the whole in-band fill. The result is a CAP: if the replay
    ///      is within 1 wei of the observed delta we keep the observed numbers. That 1 wei is
    ///      SwapMath vs Pool.swap rounding on a sole-LP exit through empty ticks (invariant I1).
    ///      A real wing fill is many orders larger.
    function _queueShare(PoolKey calldata k, SwapParams calldata params, uint256 amtIn, uint256 amtOut, uint256 pfDelta)
        internal
        view
        returns (uint256 inNet, uint256 outAmt)
    {
        (uint160 sqrtAfter, int24 tickAfter, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(k.toId());
        // In-range: tick in [tickLower, tickUpper). Price is monotonic in a swap, so a
        // swap that starts AND ends inside the band cannot have touched a disjoint wing.
        if (_tickInBand(tickBefore) && _tickInBand(tickAfter)) {
            if (pfDelta > amtIn) revert ProtocolFeeExceedsInput(pfDelta, amtIn);
            return (amtIn - pfDelta, amtOut);
        }

        (uint256 bandGross, uint256 bandOut, uint256 pfBand) = _bandStep(params, sqrtAfter, protocolFee, lpFee);

        // A wei of underestimate vs Pool.swap is SwapMath rounding, not a wing fill.
        // Clipping it desyncs the ledger from the ghost that tracks PoolManager's delta
        // (invariant I1). A real wing fill is many orders larger; N5 was 1e15.
        //
        // **THE `1` IS NOT A PROVEN BOUND AND THIS COMMENT NO LONGER CLAIMS IT IS.** `_bandStep`
        // does ONE `computeSwapStep`; `Pool.swap` does one per tick-bitmap WORD (its
        // `nextInitializedTickWithinOneWord` stops at a word edge even when nothing in it is
        // initialised) plus one per initialised tick, and each extra step re-ceils `amountIn`,
        // re-ceils `feeAmount` and re-floors `amountOut`. Over a 1920-tick band that is up to 2
        // steps at `tickSpacing == 60` (~2 wei) and up to 8 at spacing 1 (~14-16 wei). So at the
        // project's own spacing the true bound is 2, not 1.
        //
        // It is left at 1 DELIBERATELY, because being too tight fails SAFE: the tolerance simply
        // does not fire, the band numbers are taken instead, and those are the smaller pair
        // (`bandGross <= amtIn`, `bandOut >= amtOut`). The queue is then under-credited and
        // over-debited — over-collateralised — and the residual wei land in the float. Widening
        // the number to make the identity path fire more often would be loosening a tolerance to
        // buy a green, which is the one response to a finding this project does not allow.
        // The residual leak is logged rather than papered over.
        //
        // **THE ZERO-BAND CASE IS DELIBERATE, AND A `bandGross != 0` GUARD HERE IS A BUG.**
        // Reviewed and REJECTED, with the negative result recorded because it looks obviously
        // right: when a swap never touches the band, `_bandStep` returns `(0, 0, 0)` and
        // `0 + 1 >= amtIn` is TRUE for `amtIn == 1`. A 1-wei input on a 0.30% pool is consumed
        // entirely as fee (`mulDiv(1, 997000, 1e6) == 0`), giving delta `(-1, 0)` — the shape
        // Step 2 already records as measured — so the head is credited a wei the BAND did not
        // earn. Adding `bandGross != 0` to drop it makes `invariant_I1_ledgerEqualsTheGhost` go
        // RED, and the invariant is right: with no wings there is nowhere else the wei can have
        // gone. v4 cannot even attribute it (`feeGrowthGlobal` does not update at `L == 0`), so
        // it sits in PoolManager owed to nobody, and Step 2c's degenerate-fill policy exists
        // precisely to stop the ledger UNDER-counting the position in that case.
        //
        // The residual exposure is real but narrower than it first looks: it needs a pool that
        // HAS wings, a swap that lands entirely in one, and `amtIn == 1`. It is bounded at one
        // wei per transaction — ledger drift, not an economic exploit — and closing it needs the
        // hook to measure what its OWN position received rather than to infer it from the band
        // replay. That is a real change, not a clause. Logged rather than papered over.
        if (bandGross + 1 >= amtIn && bandOut + 1 >= amtOut) {
            if (pfDelta > amtIn) revert ProtocolFeeExceedsInput(pfDelta, amtIn);
            return (amtIn - pfDelta, amtOut);
        }

        if (pfBand > bandGross) revert ProtocolFeeExceedsInput(pfBand, bandGross);
        return (bandGross - pfBand, bandOut);
    }

    function _tickInBand(int24 t) internal view returns (bool) {
        return t >= tickLower && t < tickUpper;
    }

    function _bandStep(SwapParams calldata params, uint160 end, uint24 protocolFee, uint24 lpFee)
        internal
        view
        returns (uint256 gross, uint256 outAmt, uint256 pfBand)
    {
        // Copy calldata onto the stack NOW, while the frame is still shallow. Reading
        // `params.amountSpecified` at the `computeSwapStep` call is what blows the frame
        // (via_ir is off on this project).
        int256 remaining = params.amountSpecified;
        bool zfo = params.zeroForOne;
        // The SAME anchor the price curve is built from. See `_bandEntry`.
        (uint160 fromP, uint160 edge) = _bandEntry(zfo);
        uint160 toP = zfo ? (end > edge ? end : edge) : (end < edge ? end : edge);
        if (zfo ? fromP <= toP : fromP >= toP) return (0, 0, 0);
        if (liquidity == 0) return (0, 0, 0);

        uint16 pf = zfo ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        uint24 swapFee = pf == 0 ? lpFee : pf.calculateSwapFee(lpFee);
        uint256 feeAmt;
        (gross, outAmt, feeAmt) = _oneStep(fromP, toP, remaining, swapFee);
        if (pf != 0) {
            pfBand = (uint24(pf) == swapFee) ? feeAmt : gross * uint256(pf) / ProtocolFeeLibrary.PIPS_DENOMINATOR;
        }
    }

    function _oneStep(uint160 fromP, uint160 toP, int256 remaining, uint24 swapFee)
        internal
        view
        returns (uint256 gross, uint256 outAmt, uint256 feeAmt)
    {
        uint256 stepIn;
        (, stepIn, outAmt, feeAmt) = SwapMath.computeSwapStep(fromP, toP, liquidity, remaining, swapFee);
        gross = stepIn + feeAmt;
    }

    /// @dev One swap's price curve, carried as a MEMORY STRUCT rather than four stack slots.
    ///      `via_ir` is off on this project and `_allocate` is already the deepest frame in the
    ///      contract; this is the difference between compiling and "stack too deep".
    ///      `total == 0` means "no curve" and selects average pricing — see `Allocation.step`.
    struct Curve {
        uint160 entry; // where the swap entered the band: where the price walk starts
        uint160 edge; // the band edge it is walking toward; the walk is clamped here
        uint128 liq; // the band's liquidity, constant across one position
        uint256 room; // outgoing token the band can still pay before it reaches `edge`
        uint256 total; // the curve at the FULL `amtOut`; doubles as the initialised flag
    }

    /// @notice THE PRICE CURVE. Input the band absorbs while paying out its first `outAmt` of the
    ///         outgoing token, measured from `sqrtStart`. This is what makes a seat's fill price
    ///         depend on WHERE IN THE SWAP it sat.
    ///
    /// @dev Non-decreasing in `outAmt`, and TOTAL — it never reverts and never leaves the band.
    ///      Both properties are load-bearing:
    ///
    ///      * non-decreasing is what makes every `Allocation.step` share non-negative. It holds
    ///        because moving further through a swap can only move the price further in one
    ///        direction, and `getAmountXDelta` over a widening span can only grow;
    ///      * total, because this runs inside `afterSwap`. A revert here is not a failed
    ///        computation, it is a REVERTED SWAP — the hook would brick the pool for everyone on
    ///        an arithmetic edge that has nothing to do with the swapper. v4's
    ///        `getNextSqrtPriceFrom...` helpers revert when the amount would exhaust the position,
    ///        so the capacity to the band edge is measured FIRST and the walk is clamped there.
    ///
    ///      `outAmt` cannot legitimately exceed that capacity — `_queueShare` has already clipped
    ///      the swap to this band, and no other liquidity may exist inside it (`_beforeAddLiquidity`
    ///      forbids an overlapping add, and the band never moves). The clamp covers the one wei the
    ///      identity path is allowed to carry, and any future path that widens the input.
    ///
    ///      Rounding is DOWN on every leg. The result is a weight, not a payment: it is only ever
    ///      used as a ratio against `wTotal` computed the same way, and the wei that rounding
    ///      leaves over is handed to the last filled seat by the remainder line.
    function _segmentIn(Curve memory cv, bool outIsOne, uint256 outAmt) internal pure returns (uint256) {
        (uint160 sqrtStart, uint160 edge, uint128 liq) = (cv.entry, cv.edge, cv.liq);
        if (liq == 0 || outAmt == 0) return 0;

        uint160 next;
        // `cv.room` — how much of the outgoing token the band can pay before the price reaches
        // `edge` — is a property of the SWAP, not of the seat, so it is measured once in
        // `_initCurve`. It has to be measured at all because v4's `getNextSqrtPriceFrom...` helpers
        // REVERT rather than saturate once the amount would exhaust the position, and this runs
        // inside `afterSwap` where a revert is a bricked pool rather than a failed sum.
        if (outAmt >= cv.room) {
            next = edge;
        } else {
            next = outIsOne
                ? SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(sqrtStart, liq, outAmt, false)
                : SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(sqrtStart, liq, outAmt, false);
            // Rounding inside those helpers can step a wei past the edge; the walk must not leave
            // the band, or the span handed to `getAmountXDelta` below stops being the band's.
            if (outIsOne ? next < edge : next > edge) next = edge;
        }

        return outIsOne
            ? SqrtPriceMath.getAmount0Delta(next, sqrtStart, liq, false)
            : SqrtPriceMath.getAmount1Delta(sqrtStart, next, liq, false);
    }

    /// @dev Where the swap ENTERED the band, which is where the price curve starts. A swap that
    ///      began outside the band did not trade against the queue until it arrived at the edge,
    ///      so pricing its first seat from `sqrtBefore` would credit the head a price move that
    ///      happened in someone else's wing. Same clamp `_bandStep` uses, kept in one place.
    /// @dev Where a swap MEETS the band, and the edge it is walking toward.
    ///
    ///      **ONE DEFINITION, USED BY BOTH `_bandStep` AND `_initCurve`, AND IT MUST STAY THAT
    ///      WAY.** The two had this expression written out separately for exactly one commit, which
    ///      is the shape of PITFALLS 5.37 / 5.50 / 5.52 — a rule kept in two places has been wrong
    ///      in one of them four times on this project. Here the divergence would be SILENT: the
    ///      in-band fill would be replayed from one anchor and PRICED from another, every seat
    ///      would be credited a segment of a swap that did not happen, and conservation would still
    ///      tie out to the wei because `wTotal` normalises the total away.
    ///
    ///      `outIsOne` IS `zeroForOne`: token0 in means token1 out. Taken from the swap params by
    ///      `_afterSwap`, never inferred from the sign of a delta (a dust swap reads backwards).
    function _bandEntry(bool zeroForOne) internal view returns (uint160 entry, uint160 edge) {
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);
        uint160 start = sqrtBefore;
        return zeroForOne ? (start < hi ? start : hi, lo) : (start > lo ? start : lo, hi);
    }

    function _initCurve(Curve memory cv, bool outIsOne, uint256 amtOut) internal view {
        (cv.entry, cv.edge) = _bandEntry(outIsOne);
        cv.liq = liquidity;
        // A swap that met the band exactly at the edge it is walking toward has no span to price
        // against. `total` stays 0, which `Allocation.step` reads as "no curve": the average.
        if (cv.liq == 0 || (outIsOne ? cv.entry <= cv.edge : cv.entry >= cv.edge)) return;
        cv.room = outIsOne
            ? SqrtPriceMath.getAmount1Delta(cv.edge, cv.entry, cv.liq, false)
            : SqrtPriceMath.getAmount0Delta(cv.entry, cv.edge, cv.liq, false);
        // **A ZERO `room` MUST FALL BACK TO THE AVERAGE, NOT BE PRICED.** `_segmentIn` answers
        // `outAmt >= room` by clamping to the edge, so with `room == 0` it returns the SAME value
        // for every argument — a constant curve. `wCum` would then equal `wTotal` at the first
        // seat, and that seat would be handed the entire input while every seat behind it got
        // nothing. Believed unreachable (a span too thin to hold one wei of the outgoing token can
        // only have produced `amtOut <= 1`, which the remainder line absorbs before the curve is
        // ever consulted), so it is written as a guard rather than a test: this is the third of
        // §3b's honest answers, not the first.
        if (cv.room == 0) return;
        cv.total = _segmentIn(cv, outIsOne, amtOut);
    }

    // ------------------------------------------------------------------------------- the allocator

    /// @dev `virtual` for ONE reason: the mandatory negative controls (§D.3 N1-N4) subclass this
    ///      and change exactly one line each. Nothing in production overrides it.
    function _allocate(bool outIsOne, uint256 amtIn, uint256 amtOut) internal virtual {
        uint256 n = q.length;
        uint256 start = outIsOne ? cursor1 : cursor0;

        Allocation.State memory st = Allocation.init(amtIn, amtOut);
        uint256 next = start;

        // THE CURSORS ARE RANKS AND THE LOOP WALKS RANKS. `order` is read ONCE, into memory, so a
        // queue that has been permuted by foreclosure costs the allocator one `SLOAD` and a shift
        // per seat — not a storage read per seat, and not a re-read if the order changes under it,
        // which it cannot: nothing inside this loop can demote anything.
        uint256 ord = order;

        // Drive the arithmetic DIRECTLY OVER STORAGE, from the cursor, stopping the moment the swap
        // is sourced. This is the point of having cursors at all: a head-only swap must touch one
        // seat, not the whole roster. (An earlier draft of this function loaded every seat into a
        // memory array first, which read the entire queue on every swap and silently threw the
        // cursor optimisation away.)
        // THE PRICE CURVE, INITIALISED LAZILY AND DELIBERATELY SO. A swap the head absorbs on its
        // own hits `Allocation.step`'s remainder line on the first seat and never consults the
        // curve, so it must not pay to build one. `wTotal == 0` until something actually needs it,
        // and `wTotal == 0` is also the honest average-price fallback when there is no curve to
        // read — the two meanings coincide, which is why the flag and the value are the same word.
        Curve memory cv;

        for (uint256 i = start; i < n && st.remaining > 0; i++) {
            Seat storage seat_ = q[_idAt(ord, i)];
            uint256 bal = outIsOne ? seat_.a1 : seat_.a0;
            if (bal == 0) continue;

            // Build the curve at the LAST possible moment: only once a seat has been found that
            // will NOT, on its own, finish the swap. `bal < st.remaining` is exactly that test, and
            // it is why a head-only swap pays nothing at all for marginal pricing.
            uint256 wCum;
            if (bal < st.remaining) {
                if (cv.total == 0) _initCurve(cv, outIsOne, amtOut);
                // `amtOut - st.remaining` is the outgoing token sourced BEFORE this seat; adding
                // `bal` gives the cumulative position of this seat's segment end. Derived rather
                // than tracked in its own local, again for the stack.
                if (cv.total != 0) wCum = _segmentIn(cv, outIsOne, amtOut - st.remaining + bal);
            }

            (uint256 take, uint256 give) = Allocation.step(st, bal, wCum, cv.total);

            if (outIsOne) {
                seat_.a1 = _u128(bal - take);
                seat_.a0 = _u128(uint256(seat_.a0) + give);
            } else {
                seat_.a0 = _u128(bal - take);
                seat_.a1 = _u128(uint256(seat_.a1) + give);
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

    /// @notice Fund a seat you hold. **This is the only way capital enters the queue, and it
    ///         creates nothing** — the roster was fixed at deployment.
    ///
    /// @dev **IT SETTLES EVERY SEAT AHEAD FIRST, AND THAT IS A SECURITY MEASURE, NOT TIDINESS.**
    ///
    ///      Rent is handed to the seats BEHIND the payer, pro-rata by their `currency0` balance
    ///      READ AT SETTLEMENT. Funding a seat is the only way a holder can raise that balance at
    ///      will, so without this line the sequence
    ///
    ///          addToSeat(myTailSeat, huge, 0) → settleRent(everyoneAhead) → withdraw(myTailSeat)
    ///
    ///      captures rent that accrued over a period the depositor was not there for, in ONE
    ///      transaction, and `huge` can be a flash loan — so the share goes to ~100% and the cost is
    ///      gas. Settling the payers first drains the pot BEFORE the new balance can weigh on it,
    ///      which leaves only rent that accrues afterwards, i.e. exactly the rent the depositor is
    ///      there for.
    ///
    ///      A per-block cooldown would also close it and is the wrong instrument: PLAN §B.12 counts
    ///      "waiting one block boundary" as a PROVEN evasion — 200 ms on Unichain — and QUEUE passes
    ///      that table precisely because it has no per-block reference anywhere. Do not add one.
    ///
    ///      Cost is bounded by the number of PRICED seats ahead (an unpriced one costs a single
    ///      `SLOAD`), and every settle it performs also drains the payer's own escrow, so the
    ///      expensive configuration cannot be maintained for free by an attacker: they would be
    ///      paying rent to the very depositor they are trying to grief.
    function addToSeat(uint256 seatId, uint256 amount0, uint256 amount1) external nonReentrant {
        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        _settleAhead(rankOfId(seatId));
        _fundSeat(seatId, amount0, amount1);
    }

    function _fundSeat(uint256 seatId, uint256 amount0, uint256 amount1) internal {
        if (!bound) revert PoolNotBound();
        if (amount0 == 0 && amount1 == 0) revert NothingDeposited();

        if (amount0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        int256 d0;
        int256 d1;
        uint128 dl = _liquidityForAmounts(amount0, amount1);
        if (dl != 0) {
            (d0, d1) = _modifyPosition(int256(uint256(dl)));
            liquidity += dl;
            // Cannot happen: `_liquidityForAmounts` sizes on the leg it can afford. If it ever
            // does, the excess would be silently taken from float owed to OTHER seats.
            // Only a DEBIT can overspend; a credit is the position handing back realised fees.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (d0 < 0 && uint256(-d0) > amount0) revert DepositOversized(uint256(-d0), amount0);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (d1 < 0 && uint256(-d1) > amount1) revert DepositOversized(uint256(-d1), amount1);
        }

        // OWNER DECISION 2026-08-27 — ABSORB, do not refund. PLAN §B.7 originally said "refund any
        // unconsumed remainder to msg.sender". Under a float that is the worse answer: absorbing it
        // costs no transfer and it SHRINKS the float that `sweepFloatIntoPosition` has to work
        // against. The depositor keeps the full value either way — as ledger credit rather than
        // returned tokens — so INVARIANT F still holds exactly:
        //     consumed goes into the position, remainder goes into floatX, seat is credited both.
        //
        // `dX` is what the POSITION did to the hook's balance, and it is signed: normally negative
        // (the position was paid), positive when the fees it realised on the way in exceeded the
        // principal. Both belong in the float — realised fees are the queue's own money, already
        // on the right-hand side of INVARIANT F before they were realised.
        // casting to 'uint256' is safe because the guards above prove `-dX <= amountX`
        // forge-lint: disable-next-line(unsafe-typecast)
        float0 = uint256(int256(float0 + amount0) + d0);
        // forge-lint: disable-next-line(unsafe-typecast)
        float1 = uint256(int256(float1 + amount1) + d1);

        Seat storage s = q[seatId];
        s.a0 = _u128(uint256(s.a0) + amount0);
        s.a1 = _u128(uint256(s.a1) + amount1);

        // TOPPING UP A SEAT BELOW A CURSOR WOULD MAKE THAT CURSOR LEAD. Opening a seat at the tail
        // cannot, but `addToSeat` on an exhausted seat re-funds it in place, and a cursor that has
        // already advanced past it would then skip a funded seat — silent theft of rank.
        //
        // THE COMPARISON IS AGAINST THE SEAT'S RANK, NOT ITS ID. They were the same number until
        // foreclosure existed; comparing a cursor to an id after a demotion pulls the wrong cursor
        // back, or fails to pull one back at all. Read after `_settleAhead`, which may have moved
        // this seat's rank by demoting something in front of it.
        uint256 rank = rankOfId(seatId);
        if (rank < cursor0) cursor0 = rank;
        if (rank < cursor1) cursor1 = rank;
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
    function withdraw(uint256 seatId, uint256 w0, uint256 w1) external nonReentrant returns (uint256 p0, uint256 p1) {
        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        Seat storage s = q[seatId];
        if (w0 > s.a0) revert OverEntitlement(w0, s.a0);
        if (w1 > s.a1) revert OverEntitlement(w1, s.a1);

        (p0, p1) = _payOut(w0, w1);

        s.a0 -= _u128(p0);
        s.a1 -= _u128(p1);

        // Cursors are deliberately NOT touched. A withdrawal only ever REDUCES a seat, so it cannot
        // make a cursor lead; leaving them costs a little gas and can never lose money.
        // Withdrawing to zero does NOT destroy the seat: an empty seat is pure rank with no capital,
        // and being able to hold, price and sell one is what gives rank a price of its own.

        _send(msg.sender, p0, p1);
    }

    /// @notice Collect whatever a seat evacuation could not pay on the spot.
    /// @dev Residual-scale in practice; see `_onSeatTransfer`. It exists because the alternative to
    ///      a claim is silently rounding a departing holder's last few wei away.
    function claimPending(uint256 w0, uint256 w1) external nonReentrant returns (uint256 p0, uint256 p1) {
        uint256 h0 = pending0[msg.sender];
        uint256 h1 = pending1[msg.sender];
        if (w0 > h0) revert OverEntitlement(w0, h0);
        if (w1 > h1) revert OverEntitlement(w1, h1);

        (p0, p1) = _payOut(w0, w1);

        // Decrement, never `= h0 - p0`. A cached read written back whole is a stale-write, and the
        // only thing standing between it and a reentrant double-claim would be the guard alone.
        pending0[msg.sender] -= p0;
        pending1[msg.sender] -= p1;
        pendingTotal0 -= p0;
        pendingTotal1 -= p1;

        _send(msg.sender, p0, p1);
    }

    /// @dev Turn a ledger entitlement into tokens sitting in the float, ready to send. Shared by
    ///      `withdraw`, `claimPending` and the seat evacuation so there is exactly one place where
    ///      the position is opened up and exactly one place the dust policy is applied.
    ///
    ///      Returns what will actually be paid, which is `min(requested, available)` — the caller
    ///      must debit the ledger by the RETURNED amount, never by the requested one.
    function _payOut(uint256 w0, uint256 w1) internal returns (uint256, uint256) {
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
        // ~0.15 wei per swap, unfarmable but real. Paying face exactly makes the LAST withdrawer's
        // call revert; F1 spreads the residual over whoever withdraws instead of dumping it on them.
        (w0, w1) = _applyDustPolicy(w0, w1);

        float0 -= w0;
        float1 -= w1;
        return (w0, w1);
    }

    function _send(address to, uint256 a0, uint256 a1) internal {
        if (a0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransfer(to, a0);
        if (a1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(to, a1);
    }

    /// @notice Rank moves; capital does not. On every change of holder the seat is emptied and its
    ///         capital is returned to the holder who is leaving.
    ///
    /// @dev **THIS IS A DELIBERATE DEPARTURE FROM PLAN §B.8 AND IT CLOSES A FREE DoS.**
    ///
    ///      §B.8 specified evacuation as a pure ledger move: `q[id].(a0,a1)` into the sender's
    ///      `pendingWithdraw`, position untouched. That is unsound, and not marginally. The
    ///      allocator sources every swap's output FROM THE SEATS, while the swap's size is set by
    ///      the POSITION. A ledger-only evacuation drops `sum(q[i].aX)` and leaves the position at
    ///      full depth, so the pool goes on quoting liquidity the queue can no longer source and
    ///      `_allocate` reverts `QueueUnderflow`.
    ///
    ///      That is not a corner: `transfer(self, id, 1)` is legal, costs gas only, and a tail
    ///      holder sitting on most of one token can use it to make every swap above the surviving
    ///      balance revert, for as long as they feel like it, and undo it whenever they want. A
    ///      free, repeatable denial of the pool's whole purpose, handed to any one seat holder.
    ///      (`test_3_11_negativeControl_ledgerOnlyEvacuationBricksTheSwapPath` executes it.)
    ///
    ///      The fix is to make the capital actually LEAVE. Paying it out burns the matching
    ///      liquidity, so the position falls in step with the ledger and the queue can still source
    ///      every swap the pool will quote. `sum(q[i].aX) + pendingTotalX == redeemable X + floatX`
    ///      is preserved exactly, and INVARIANT F never has to admit a second, unrankable pool of
    ///      capital that the allocator cannot see.
    ///
    ///      **Why not simply refuse to transfer a funded seat?** Because Phase 4 needs this path to
    ///      be unblockable. A Harberger buyout must be able to take the seat at the incumbent's own
    ///      self-assessed price at any time; if a funded seat could not move, every incumbent would
    ///      hold a permanent veto over their own buyout by keeping a wei in the seat.
    ///
    ///      **Why can this not be blocked?** The only external calls are `modifyLiquidity` on
    ///      PoolManager and `transfer` on the pool's own currencies. A plain ERC-20 hands the
    ///      recipient no control, so a departing holder cannot refuse payment to stop a buyout, and
    ///      the dust policy clamps rather than reverting when the position is short.
    ///
    ///      **PHASE 4 ADDS THE LEASE, AND IT IS RESET HERE — IN THE ONE FUNNEL, NOT PER CALLER.**
    ///      Three rules, each with exactly one reason:
    ///
    ///        * **Rent settles first.** The departing holder pays for the time they held it, at the
    ///          price they themselves set, and not one second more.
    ///        * **The escrow is REFUNDED, never inherited.** It is a prepaid meter, not part of the
    ///          asset. Letting it travel with the seat would mean a holder who prepaid a year of
    ///          rent and priced the seat at its bare value has silently under-priced by the whole
    ///          escrow, and Harberger punishes under-pricing by taking the thing.
    ///        * **The self-price is cleared and the seat is FIRM at what was just paid for it.**
    ///          A new holder has made no assessment, so they owe no rent until they make one; and
    ///          arming the firm quote here is what stops the dodge in `buyPrice`'s note — handing
    ///          the seat to your own second address to get a clean slate leaves it firm at zero,
    ///          i.e. free for anyone to take.
    function _onSeatTransfer(uint256 seatId, address from) internal virtual override {
        Lease storage l = lease[seatId];
        uint256 paid = paidForSeat;

        // An unpriced, unfunded seat with no live firm quote is ALREADY in the state a transfer
        // would leave it in, and was already free to take — writing the same values back would put
        // three cold `SSTORE`s on the pure-rank path, which is the cheapest and most-used path there
        // is. `buyPrice` reads zero on both sides of the branch, so skipping changes nothing a buyer
        // can see.
        //
        // **THE PREDICATE IS READ BEFORE THE SETTLEMENT, AND THAT ORDER IS LOAD-BEARING.** Settling
        // can FORECLOSE this very seat, and foreclosure zeroes `selfPrice` — so a guard evaluated
        // afterwards looks at a lease that has just been wiped, skips the arming, and hands back the
        // dodge the arming exists to stop: hold a priced seat with an empty meter, transfer it to
        // your own second address (which forecloses it on the way through), and reprice with no firm
        // quote against you. Found by executing that sequence, not by reading the code.
        //
        // Reading early is safe because `_settleSeat` on an UNPRICED seat is a no-op, so in the only
        // case the predicate is false, before and after are the same state.
        bool live = l.selfPrice != 0 || l.escrow != 0 || paid != 0 || l.firmUntil > block.timestamp;

        _settleSeat(seatId);

        uint256 esc = l.escrow;
        if (live) {
            if (esc != 0) {
                l.escrow = 0;
                escrowTotal -= esc;
            }
            l.selfPrice = 0;
            l.firmPrice = paid;
            // casting to 'uint64' is safe: a uint64 holds unix seconds for ~5.8e11 years, and
            // FIRM_WINDOW is bounded at 365 days by the constructor.
            // forge-lint: disable-next-line(unsafe-typecast)
            l.firmUntil = uint64(block.timestamp + FIRM_WINDOW);
            l.lastSettled = uint64(block.timestamp);
        }

        Seat storage s = q[seatId];
        uint256 a0 = s.a0;
        uint256 a1 = s.a1;
        // Pure rank and no prepaid rent: nothing to move, no external call, no liquidity touched.
        // This is the common case and the one the buyout leans on.
        if (a0 == 0 && a1 == 0 && esc == 0) return;

        (uint256 p0, uint256 p1) = _payOut(a0, a1);

        // The seat leaves EMPTY whatever happened above. Anything the position could not release on
        // the spot — residual-scale, by the §E.4 bound — is retained as a claim on the DEPARTING
        // holder rather than travelling with the rank to somebody who never owned it.
        s.a0 = 0;
        s.a1 = 0;
        if (p0 != a0) {
            pending0[from] += a0 - p0;
            pendingTotal0 += a0 - p0;
        }
        if (p1 != a1) {
            pending1[from] += a1 - p1;
            pendingTotal1 += a1 - p1;
        }

        // Cursors are NOT touched, for the same reason `withdraw` does not touch them: emptying a
        // seat can only make a cursor LAG, never lead, and a lagging cursor costs gas rather than
        // money. INVARIANT C ("every seat below cursorX holds zero of X") survives trivially — the
        // seat now holds zero of both.

        // The escrow rides out on the same transfer. It is currency0 the hook already holds
        // OUTSIDE the position and outside `float0`, so unlike `p0` it needs nothing released and
        // is never clamped.
        _send(from, p0 + esc, p1);
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
    function sweepFloatIntoPosition() external nonReentrant returns (uint128 added) {
        if (!bound) revert PoolNotBound();
        added = _liquidityForAmounts(float0, float1);
        if (added == 0) return 0;

        (int256 d0, int256 d1) = _modifyPosition(int256(uint256(added)));
        liquidity += added;
        // Same signed measurement as `_fundSeat`: a sweep can be net CREDITED when the position's
        // realised fees exceed the principal it takes in, and the credit belongs to the float.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (d0 < 0 && uint256(-d0) > float0) revert DepositOversized(uint256(-d0), float0);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (d1 < 0 && uint256(-d1) > float1) revert DepositOversized(uint256(-d1), float1);
        // forge-lint: disable-next-line(unsafe-typecast)
        float0 = uint256(int256(float0) + d0);
        // forge-lint: disable-next-line(unsafe-typecast)
        float1 = uint256(int256(float1) + d1);
    }

    // ---------------------------------------------------------------- why there is no `recenter()`
    //
    // A `recenter()` was written, DELETED, REBUILT, and left OUT AGAIN. Both attempts are recorded
    // because the second one is the more useful failure.
    //
    // v1 centred a new band on spot behind a single `getLiquidity()` guard. Three defects, one root
    // cause — the band and the wings compete for the at-the-money ticks, and "overlap is forbidden"
    // means the queue can never take them back:
    //   * the guard read liquidity ACTIVE AT THE CURRENT TICK while the destination is a RANGE, so a
    //     wing inside the new band but not spanning spot was invisible and got swallowed — N5,
    //     reopened by the hook itself, with no overlapping add ever submitted here;
    //   * the guard was nonetheless CORRECT, which is worse: any wing covering spot blocked it, and
    //     price leaving the band IS price entering a wing, so one wei stranded the whole roster;
    //   * centring on spot puts the band IN RANGE, which needs both tokens, while a band the price
    //     has left holds exactly one — so the re-mint deployed ~nothing and the pool stopped quoting.
    //
    // v2 fixes all three (destination emptiness checked as a RANGE via a tick-bitmap walk plus the
    // liquidity active at the near edge; a ONE-SIDED mint one spacing clear of spot, which is fully
    // fundable from the token actually held; and a half-width margin so the band cannot be ratcheted).
    // Its eight tests pass. **THE INVARIANT CAMPAIGN DOES NOT.** Bisecting the handler's selector set
    // localises it: `swap`+`recenter` alone is green, and adding either path that DEPLOYS FLOAT INTO
    // THE POSITION (`addToSeat`, `sweepFloatIntoPosition`) turns it red, with ledger-vs-ghost gaps and
    // per-token shortfalls of ~10% — orders of magnitude past rounding. The defect was not located.
    //
    // It is therefore NOT SHIPPED, and eight green unit tests are not a reason to ship it. The work,
    // the evidence and the leads are preserved in `docs/wip/recenter-v2/`.
    //
    // WHAT THE ABSENCE BUYS, and it is not nothing: `(tickLower, tickUpper)` is written exactly once,
    // in `_afterInitialize`, and never again. That is what upgrades `_beforeAddLiquidity`'s add-time
    // disjointness test from a snapshot of a moving target into a COMPLETE guard — no legal wing can
    // ever become overlapping, because the band cannot move onto it.
    //
    // THE HONEST CONSEQUENCE, which belongs in the pitch rather than hidden: this is a FIXED-RANGE
    // position. If the price leaves the band it goes one-sided and stops earning, and unlike an
    // ordinary v4 LP the holders CANNOT burn and re-mint around the price — the only exit is to
    // withdraw and redeploy into a new pool. QUEUE is a fixed-term instrument, not a perpetual venue,
    // and `BAND_HALF_WIDTH` is a deployment parameter precisely so the term can be chosen: expected
    // in-band life scales as w^2 while depth scales as 1/w, so doubling the band quadruples the life
    // and only halves the depth.

    // ================================================== HARBERGER — the always-for-sale lease

    /// @notice What it costs to take seat `seatId` from its holder, right now.
    ///
    /// @dev **THE FIRM QUOTE, AND IT IS THE DIFFERENCE BETWEEN A MECHANISM AND A SLOGAN.**
    ///
    ///      "Always for sale at your own price" is worth nothing if the holder can raise the price
    ///      the instant they see a buyer. They can see one: a buyout is an ordinary transaction in
    ///      an ordinary mempool, and repricing costs only rent for the seconds the raise is in
    ///      effect — with τ = 10%/yr that is 4 parts in 10⁷ of the price per block. Effectively
    ///      free. Left alone, EVERY buyout is vetoable and Harberger delivers nothing but a tax.
    ///
    ///      So an ask is FIRM: the seat stays available at the lowest price it has been asked at,
    ///      or paid for, within `FIRM_WINDOW`. A raise takes effect immediately for RENT and only
    ///      after the window for the SALE, which makes the reactive raise useless — the buyer still
    ///      gets it at the old number — while a raise made in the ordinary course costs nothing.
    ///
    ///      The three dodges this survives, each self-destructive rather than merely refused:
    ///        * raise to block a pending buyout → the old price is still firm, the buyer lands;
    ///        * drop to zero and re-raise in one transaction → the window minimum is now ZERO and
    ///          the seat is free to anyone for `FIRM_WINDOW`;
    ///        * hand the seat to your own second address for a clean slate → `_onSeatTransfer`
    ///          arms the window at what was paid, which for a plain transfer is zero.
    ///
    ///      A seat that has never been priced quotes zero and is free to take. That is not a hole,
    ///      it is the bootstrap: the founding roster starts unpriced, so the deployer's endowment is
    ///      worth a head start of one transaction and nothing else.
    function buyPrice(uint256 seatId) public view virtual returns (uint256) {
        Lease storage l = lease[seatId];
        uint256 p = l.selfPrice;
        if (block.timestamp < l.firmUntil) {
            uint256 f = l.firmPrice;
            if (f < p) return f;
        }
        return p;
    }

    /// @notice Set your own assessment of your seat. Rent is charged on it; the seat is for sale at
    ///         it. Zero is legal and means "free to take".
    function setSelfPrice(uint256 seatId, uint256 price) external nonReentrant {
        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        _setPrice(seatId, price);
    }

    /// @dev The one place a self-price is written. `buySeat` reaches it too, so the firm-quote rule
    ///      cannot exist in one path and be forgotten in the other.
    function _setPrice(uint256 seatId, uint256 newPrice) internal {
        if (newPrice > Rent.MAX_SELF_PRICE) revert SelfPriceTooLarge(newPrice, Rent.MAX_SELF_PRICE);

        // Charge what is owed at the OLD price before the new one applies. Without this the raise
        // is retroactive and the drop is amnesty — the two errors do not cancel, they are both
        // theft, in opposite directions.
        _settleSeat(seatId);

        Lease storage l = lease[seatId];
        uint256 old = l.selfPrice;

        if (block.timestamp < l.firmUntil) {
            // Already inside a window: the quote is the RUNNING MINIMUM over it. This is the line
            // that makes "drop to zero, then raise" self-destructive rather than clever.
            if (newPrice < l.firmPrice) l.firmPrice = newPrice;
            // casting to 'uint64' is safe: a uint64 holds unix seconds for ~5.8e11 years, and
            // FIRM_WINDOW is bounded at 365 days by the constructor.
            // forge-lint: disable-next-line(unsafe-typecast)
            l.firmUntil = uint64(block.timestamp + FIRM_WINDOW);
        } else if (old != 0) {
            // A price was in effect and is now changing: it stays honoured for the window.
            l.firmPrice = old < newPrice ? old : newPrice;
            // casting to 'uint64' is safe: a uint64 holds unix seconds for ~5.8e11 years, and
            // FIRM_WINDOW is bounded at 365 days by the constructor.
            // forge-lint: disable-next-line(unsafe-typecast)
            l.firmUntil = uint64(block.timestamp + FIRM_WINDOW);
        }
        // else: no window is open and there was no price to honour — the seat was free to take up
        // to this instant, so there is nothing a firm quote could protect a buyer against.

        l.selfPrice = newPrice;
        l.lastSettled = uint64(block.timestamp);
        emit SelfPriceSet(seatId, newPrice, l.firmPrice, l.firmUntil);
    }

    /// @notice Prepay rent on a seat, in `currency0`.
    ///
    /// @dev **THIS IS A METER, NOT COLLATERAL, AND THE DISTINCTION IS THE WHOLE OF §B.10's WARNING.**
    ///      Nothing marks it, nothing values it against anything, no third party is paid to seize
    ///      it, and running it dry costs a place in the queue rather than the seat or its capital.
    ///      A prior candidate in this repo (`TENANT`) died for needing the other thing.
    ///
    ///      **It also corrects PLAN §B.10, which said rent is "deducted from the seat's own `a0`".
    ///      Built literally, that is broken, and not at the margin.** Front-first allocation
    ///      deliberately drives a seat to single-token composition, and INVARIANT C states the
    ///      consequence outright: every seat below `cursor0` holds `a0 == 0`. So under any sustained
    ///      run of one-for-zero flow the FRONT seats hold exactly zero of the rent currency — and
    ///      would be foreclosed, one after another, for no reason but the direction the market
    ///      happened to trade. Rank would be set by flow instead of by price, which is the one thing
    ///      QUEUE claims it is not. The second argument is shorter: an EMPTY seat is pure rank,
    ///      Phase 3 exists to make that holdable and sellable, and an `a0`-funded rent makes it
    ///      unholdable at any price above zero.
    ///
    ///      Anyone may fund any seat. Restricting it to the holder would add a way to fail and buy
    ///      nothing: a gift of rent is a gift.
    function fundRent(uint256 seatId, uint256 amount) external nonReentrant {
        if (!bound) revert PoolNotBound();
        if (seatId >= q.length) revert NoSuchSeat(seatId);
        if (amount == 0) revert NothingDeposited();

        IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount);
        lease[seatId].escrow += amount;
        escrowTotal += amount;
        emit RentFunded(seatId, msg.sender, amount);
    }

    /// @notice Take back prepaid rent you have not spent. Settles first, so it cannot outrun a bill
    ///         that has already accrued.
    function withdrawRent(uint256 seatId, uint256 amount) external nonReentrant {
        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        _settleSeat(seatId);

        Lease storage l = lease[seatId];
        if (amount > l.escrow) revert OverEntitlement(amount, l.escrow);
        l.escrow -= amount;
        escrowTotal -= amount;

        // Escrow is currency0 the hook holds outright — outside the position, outside `float0`, and
        // therefore never clamped by the dust policy and never able to spend another seat's money.
        _send(msg.sender, amount, 0);
        emit RentWithdrawn(seatId, msg.sender, amount);
    }

    /// @notice Charge a seat the rent it owes and hand it to the seats behind. Permissionless.
    ///
    /// @dev **PERMISSIONLESS, AND IT IS NOT A KEEPER.** It takes no argument but a seat id, pays the
    ///      caller nothing, and moves money only where the lease already says it goes — the same
    ///      shape as `sweepFloatIntoPosition`. Two parties want to call it without being asked: the
    ///      seats behind, who are paid by it, and anyone who wants the seat, because settling a
    ///      delinquent holder is what demotes them out of the way. No off-chain component is
    ///      required for the mechanism to bind, because settlement is also FORCED at every point
    ///      the lease is touched — repricing, funding, withdrawing, selling, or being bought.
    function settleRent(uint256 seatId) external nonReentrant {
        if (seatId >= q.length) revert NoSuchSeat(seatId);
        _settleSeat(seatId);
    }

    /// @notice Take a seat from its holder at the price they set. Rank only — the seat arrives EMPTY.
    ///
    /// @param maxPrice  the most the buyer will pay. **Not optional slippage.** See `buyPrice`.
    /// @param newSelfPrice the buyer's own assessment, applied in the same transaction so the seat
    ///        is never left unpriced — and therefore free — for even one block.
    function buySeat(uint256 seatId, uint256 maxPrice, uint256 newSelfPrice) external nonReentrant {
        if (!bound) revert PoolNotBound();
        if (seatId >= q.length) revert NoSuchSeat(seatId);

        // Settle BEFORE reading the price: a holder who cannot pay is demoted first, and the buyer
        // then pays whatever the seat is actually worth after that, not before it.
        _settleSeat(seatId);

        address holder = seatHolder[seatId];
        // Buying your own seat would evacuate your own capital and pay yourself your own price — a
        // no-op with side effects. Refused so the buyout means one thing.
        if (holder == msg.sender) revert CannotBuyOwnSeat(seatId);

        uint256 price = buyPrice(seatId);
        if (price > maxPrice) revert PriceAboveMax(price, maxPrice);

        if (price != 0) {
            IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), price);
            // Credited, not transferred on. A direct `transfer` to the seller lets a seller who is a
            // contract refuse payment — and refusing payment would BLOCK THEIR OWN BUYOUT, which
            // hands every incumbent the permanent veto Phase 3 went out of its way to remove.
            // `pending0` is already the claim path for exactly this, and the identity holds:
            // `Σa0 + pendingTotal0` and `redeemable0 + float0` both rise by `price`.
            pending0[holder] += price;
            pendingTotal0 += price;
            float0 += price;
        }

        // Hand the price to `_onSeatTransfer` so the seat leaves FIRM at what was paid for it, then
        // move it through the same single funnel every other change of holder uses.
        paidForSeat = price;
        _moveSeat(msg.sender, holder, msg.sender, seatId, 1);
        paidForSeat = 0;

        _setPrice(seatId, newSelfPrice);
        emit SeatBought(seatId, holder, msg.sender, price);
    }

    // ------------------------------------------------------------------------- rent settlement

    /// @notice Charge one seat the rent accrued since it was last settled, and demote it if it
    ///         cannot pay.
    ///
    /// @dev **FORECLOSURE IS A DEMOTION.** The seat keeps its holder and every wei of its capital;
    ///      it loses its place in the order and its price. There is nothing to liquidate, nobody is
    ///      paid a bounty to trigger it, and the loss is bounded by the escrow that was prepaid for
    ///      exactly this.
    ///
    ///      An unpriced seat is skipped WITHOUT writing `lastSettled`, which is safe because
    ///      `_setPrice` refreshes it whenever a price comes into existence — so the stale timestamp
    ///      can never be charged against.
    function _settleSeat(uint256 seatId) internal virtual {
        Lease storage l = lease[seatId];
        uint256 price = l.selfPrice;
        if (price == 0) return;

        uint256 elapsed = block.timestamp - l.lastSettled;
        if (elapsed == 0) return;

        uint256 due = Rent.owed(price, elapsed, RENT_BPS, RENT_PERIOD);
        uint256 esc = l.escrow;
        bool short_ = due > esc;
        uint256 charged = short_ ? esc : due;

        l.escrow = esc - charged;
        l.lastSettled = uint64(block.timestamp);

        // Distribute at the rank the rent was OWED from, which is why this runs before the demotion.
        _distributeRent(seatId, charged);

        if (short_) {
            l.selfPrice = 0;
            emit Foreclosed(seatId, due, charged, _demoteToTail(seatId));
        }
    }

    /// @notice Hand `amount` to the seats BEHIND `payerId`, pro-rata by their `currency0` balance.
    ///
    /// @dev BEHIND, not ahead. Rent is what the front pays the back for standing aside, so paying it
    ///      forward inverts the mechanism's entire economics while conserving every wei — the exact
    ///      shape of the bug that killed `HardcapHook`, and the reason §D.6 demands a negative
    ///      control for it specifically.
    ///
    ///      Same-token pro-rata only. Weighting by anything that mixes `a0` and `a1` into one
    ///      "value" needs a price, and QUEUE is not allowed to have one (§E.11).
    ///
    ///      **The sum is EXACT**, because the last funded recipient absorbs `amount - assigned`
    ///      through the same `Allocation.step` remainder line the allocator uses. What no recipient
    ///      can absorb — because every seat behind is empty of `currency0` — is HELD in
    ///      `unallocatedRent0` and folded into the next pot, so the identity that holds over any
    ///      settlement is
    ///
    ///          Σ credited + unallocatedAfter == charged + unallocatedBefore
    ///
    ///      to the wei. Asserting a BOUND on the leftover instead would be blind to every defect
    ///      that moves it the same way the fix does (PITFALLS 5.53).
    function _distributeRent(uint256 payerId, uint256 amount) internal virtual {
        uint256 held = unallocatedRent0;
        uint256 pot = amount + held;
        if (pot == 0) return;

        uint256 n = q.length;
        uint256 ord = order;
        uint256 r = rankOfId(payerId);

        uint256 w;
        for (uint256 i = r + 1; i < n; i++) {
            w += q[_idAt(ord, i)].a0;
        }

        if (w == 0) {
            // Nobody behind holds any currency0. The money has LEFT the payer's escrow, so it must
            // be accounted somewhere or the balance identity breaks and a wei is stranded.
            escrowTotal -= amount;
            unallocatedRent0 = pot;
            emit RentSettled(payerId, amount, 0, pot);
            return;
        }

        Allocation.State memory st = Allocation.init(pot, w);
        for (uint256 i = r + 1; i < n && st.remaining > 0; i++) {
            uint256 id = _idAt(ord, i);
            uint256 bal = q[id].a0;
            if (bal == 0) continue;
            // `(0, 0)` — rent is split pro-rata by balance and has no price curve. See `Rent`.
            (, uint256 give) = Allocation.step(st, bal, 0, 0);
            lease[id].escrow += give;
        }

        // Rent lands in the recipients' ESCROW, not their `a0`. It is currency0 the hook already
        // holds outside the position, so this is a move inside one pot: `float0`, the position and
        // INVARIANT F are all untouched by a settlement, and the tail's rent income is exactly the
        // thing that pays the tail's own rent bill.
        escrowTotal = escrowTotal - amount + pot;
        unallocatedRent0 = 0;
        emit RentSettled(payerId, amount, pot, 0);
    }

    /// @dev Settle every seat in front of `rank`. See `addToSeat` for why this exists.
    ///
    ///      It re-reads `order` each step because a settlement can DEMOTE the seat it just charged,
    ///      which slides everything behind it — including the target — down one place. The loop
    ///      terminates because each pass either advances `i` or decreases `rank`, and it stops when
    ///      they meet.
    function _settleAhead(uint256 rank) internal {
        uint256 i;
        while (i < rank) {
            uint256 before = order;
            _settleSeat(_idAt(before, i));
            if (order == before) i++;
            else rank--;
        }
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
    /// @dev **THIS DOES NOT CALL `LiquidityAmounts.getLiquidityForAmounts`, AND THE REASON IS A
    ///      DENIAL OF SERVICE IN THAT HELPER RATHER THAN A PREFERENCE.**
    ///
    ///      In range, the helper computes BOTH legs and casts EACH to `uint128` before taking the
    ///      minimum. The token1 leg is `amount1 · 2⁹⁶ / (sqrtP − sqrtLower)`, so as the price
    ///      approaches the position's lower tick that leg diverges — and its `toUint128` reverts
    ///      `SafeCastOverflow` even when the MINIMUM, the only value the caller wanted, is tiny.
    ///      A leg that is not binding decides the outcome. The same holds mirrored at the upper
    ///      tick. Reached by the Phase 6 campaign: at `sqrtP` a factor of six above `sqrtLower`,
    ///      depositing 393e18 of token1 reverted while the binding leg was 1,033 (PITFALLS 5.76).
    ///
    ///      Consequence if left alone: `addToSeat` and `sweepFloatIntoPosition` — the only paths
    ///      capital has INTO the queue and back into the position — revert for every depositor at
    ///      once, for as long as the price sits near a boundary. So the minimum is taken in 256
    ///      bits, before any narrowing, and the result is CLAMPED to what the pool can actually
    ///      accept instead of being handed over to revert.
    ///
    ///      Clamping is safe precisely because of the deposit policy already in force: whatever the
    ///      position does not take becomes `float`, the depositor is credited the full amount
    ///      either way, and `sweepFloatIntoPosition` puts the rest to work when the price moves
    ///      back. A deposit that cannot be fully deployed is not a deposit that should fail.
    function _liquidityForAmounts(uint256 amount0, uint256 amount1) internal view returns (uint128) {
        if (amount0 == 0 && amount1 == 0) return 0;
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 l;
        if (sqrtP <= lo) {
            l = _liq0(lo, hi, amount0); // wholly below the range: the position is all token0
        } else if (sqrtP < hi) {
            uint256 a = _liq0(sqrtP, hi, amount0);
            uint256 b = _liq1(lo, sqrtP, amount1);
            l = a < b ? a : b;
        } else {
            l = _liq1(lo, hi, amount1); // wholly above the range: the position is all token1
        }

        uint256 cap = MAX_LIQUIDITY_PER_TICK - liquidity;
        return uint128(l < cap ? l : cap);
    }

    /// @dev `amount0 · (sqrtA·sqrtB / 2⁹⁶) / (sqrtB − sqrtA)`, in 256 bits. Identical arithmetic to
    ///      `LiquidityAmounts.getLiquidityForAmount0` with the narrowing cast removed; see above.
    function _liq0(uint160 a, uint160 b, uint256 amount0) internal pure returns (uint256) {
        return FullMath.mulDiv(amount0, FullMath.mulDiv(a, b, FixedPoint96.Q96), b - a);
    }

    /// @dev `amount1 · 2⁹⁶ / (sqrtB − sqrtA)`, in 256 bits. See `_liq0`.
    function _liq1(uint160 a, uint160 b, uint256 amount1) internal pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, b - a);
    }

    /// @dev How much liquidity must be REMOVED to release at least `need0`/`need1`.
    ///      THE LOAD-BEARING LINE is the MAX: size on the leg that BINDS. Sizing on the min leg
    ///      under-delivers and the withdrawal comes up short.
    function _liquidityToCover(uint256 need0, uint256 need1) internal view returns (uint128) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);
        // **THE PRICE IS CLAMPED INTO THE RANGE, AND "FULL RANGE" DOES NOT MAKE THAT UNNECESSARY.**
        // `minUsableTick(60)` is -887220 while `MIN_TICK` is -887272, so the pool's price can leave
        // this position's range at either end, and a Phase 6 campaign drove it to `MIN_SQRT_PRICE`.
        // Outside the range the two single-sided formulas below are being asked for a price the
        // position does not span: `getLiquidityForAmount1(lo, sqrtP < lo, ...)` divides by a
        // near-zero span and returns a liquidity so large the clamp burns the WHOLE position, while
        // `getLiquidityForAmount0` sizes on a span the position does not have and under-delivers,
        // which the dust policy then absorbs as a short payout. Neither loses a wei — both are the
        // wrong amount of work. `LiquidityAmounts.getLiquidityForAmounts` handles the same case by
        // branching; the single-sided helpers do not, so the clamp belongs here.
        uint160 p = sqrtP < lo ? lo : (sqrtP > hi ? hi : sqrtP);
        // 256 bits, then clamped — never `toUint128` on an intermediate. See `_liquidityForAmounts`:
        // near a tick boundary one leg diverges, and here it is the MAXIMUM that is wanted, so the
        // helper's cast would turn a withdrawal that should burn the whole position into a revert.
        //
        // **A ZERO SPAN IS NOT AN ERROR, IT IS THE ANSWER "NONE".** At `p == lo` the position holds
        // no token1 at all, and asking how much liquidity releases `need1` of it divides by zero —
        // `FullMath.mulDiv` fails a bare `require`, so the call reverts with EMPTY revert data and
        // `withdraw` and the SEAT EVACUATION both die. That is a veto on the evacuation path, which
        // §B.8 removed on purpose: a holder standing at the tick boundary could not be bought out.
        // Reached by the Phase 6 campaign at `sqrtP == getSqrtPriceAtTick(tickLower)` exactly
        // (PITFALLS 5.77). The honest answer is that this leg cannot be sourced from the position,
        // so it contributes NOTHING to the maximum and the dust policy pays what the float holds.
        uint256 l0 = (need0 == 0 || p == hi) ? 0 : _liq0(p, hi, need0);
        uint256 l1 = (need1 == 0 || p == lo) ? 0 : _liq1(lo, p, need1);
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
    ///      from the hook's own balance change — never the caller's requested amounts, and not
    ///      `callerDelta` either, because a fee-on-transfer currency delivers less than the delta
    ///      says and the float must be credited what ARRIVED.
    ///
    ///      **That measurement has a precondition: nothing else may move the hook's balances inside
    ///      the unlock.** `take` calls `IERC20.transfer`, so a pool currency can seize control right
    ///      there; a reentrant withdrawal on a float-covered leg needs no second `unlock` and would
    ///      execute in full. The `nonReentrant` guard on every external ledger path is what makes
    ///      the precondition hold. See `QueueSeats.nonReentrant`.
    /// @return d0 the hook's own `currency0` balance change: NEGATIVE when it paid, POSITIVE when
    ///         the position's realised fees exceeded what it owed. See `_moved`.
    /// @return d1 the same for `currency1`.
    function _modifyPosition(int256 delta) internal returns (int256 d0, int256 d1) {
        bytes memory res = poolManager.unlock(abi.encode(delta));
        (d0, d1) = abi.decode(res, (int256, int256));
    }

    /// @dev **THE CALLER MUST GUARANTEE `liq != 0`, AND THE ONLY PRODUCTION CALLER DOES** —
    ///      `_payOut` reaches this behind `if (dl != 0)`, and `_liquidityToCover` returns 0 when
    ///      nothing needs releasing. A zero poke would revert `CannotUpdateEmptyPosition` inside v4.
    ///
    ///      A `if (liq == 0) return (0, 0);` guard used to sit here. It was added for `recenter()`,
    ///      which could burn an already-empty position; with `recenter()` deleted the branch became
    ///      unreachable from production, and the mutation campaign said so — **M74 SURVIVED with
    ///      zero failing tests**, because nothing in the project could reach it any more. Per §3b
    ///      the three honest answers to a survivor are write the test, DELETE THE LINE, or write
    ///      down why it cannot be tested. Nothing depends on it, so it is deleted (PITFALLS 5.49's
    ///      shape). The zero case now belongs where it actually arises — the TEST-ONLY
    ///      `QueueHarness.redeemAll()`, which may be called on a fully-withdrawn position.
    function _burnPosition(uint128 liq) internal returns (uint256 g0, uint256 g1) {
        liquidity -= liq;
        (int256 d0, int256 d1) = _modifyPosition(-int256(uint256(liq)));
        // A removal is owed both the principal it releases and the fees it realises, so neither leg
        // can be negative. Asserted rather than assumed — this is the one direction where the sign
        // IS predictable, and saying so out loud is what keeps `_moved`'s note honest.
        if (d0 < 0 || d1 < 0) revert UnexpectedPositionDebit(d0, d1);
        // casting to 'uint256' is safe because the branch above proves both are >= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        (g0, g1) = (uint256(d0), uint256(d1));
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
        (int256 d0, int256 d1) = _modifyPosition(int256(uint256(liq)));
        // A virgin position has no accrued fees to net against, so seeding is a pure payment.
        if (d0 > 0 || d1 > 0) revert UnexpectedPositionCredit(d0, d1);
        // casting to 'uint256' is safe because the branch above proves both are <= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        (m0, m1) = (uint256(-d0), uint256(-d1));
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

        return abi.encode(_moved(b0Before, _balance(key.currency0)), _moved(b1Before, _balance(key.currency1)));
    }

    /// @dev **THE MEASUREMENT IS SIGNED, AND THE SIGN IS NOT PREDICTED BY THE SIGN OF `delta`.**
    ///
    ///      An earlier version chose the subtraction direction from `delta > 0`, on the reasoning
    ///      that adding liquidity pays and removing it receives. That is false, and not at the
    ///      margin: `modifyLiquidity` realises the position's accrued fees on EVERY call and
    ///      returns `callerDelta = principalDelta + feesAccrued`. Whenever the accrued fees exceed
    ///      the principal being added — the ordinary state of a busy pool between two deposits —
    ///      an ADD is net CREDITED and the hook's balance goes UP. The unsigned form underflowed,
    ///      and `addToSeat` and `sweepFloatIntoPosition` reverted with an arithmetic panic for as
    ///      long as that held: a free, unrecoverable denial of service on the only path capital has
    ///      into the queue. Found by the Phase 6 campaign, reproduced by `test_6_2` (PITFALLS 5.74).
    function _moved(uint256 before, uint256 nowBal) internal pure returns (int256) {
        // casting to 'int256' is safe: both operands are ERC20 balances, and the difference of two
        // uint256 balances taken in the larger-minus-smaller direction cannot exceed 2^255-1 for
        // any token this hook can settle — v4's own deltas are int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return nowBal >= before ? int256(nowBal - before) : -int256(before - nowBal);
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

    /// @notice The one pool this hook serves, and the range it custodies liquidity over.
    ///
    /// @dev **WITHOUT THIS, THE POOL A DEPLOYED HOOK SERVES IS NOT READABLE ON CHAIN AT ALL.** `key`
    ///      is written once by `_afterInitialize` and this contract emits no event of its own, so
    ///      an integrator — a viewer, a router, an analytics job, another contract — had to scan
    ///      `PoolManager`'s `Initialize` logs and match on the hook address to learn even which
    ///      currencies it holds. Anything wanting the token decimals in order to display a balance
    ///      simply could not. A hook that cannot say what it is attached to is not integrable, and
    ///      every value here is already public: the key is in PoolManager's own event and the ticks
    ///      are the concentrated band `_afterInitialize` snapped around the starting price.
    ///
    ///      `isBound` is RETURNED rather than left to be inferred from a zero key, because
    ///      `Currency.wrap(address(0))` is native ETH and therefore a legal `currency0` — a caller
    ///      checking `key.currency0 != address(0)` would read an unbound hook as an ETH pool.
    ///
    ///      Pure disclosure: `view`, no branch, and nothing here can be reached before
    ///      `_afterInitialize` has fixed it or changed after.
    function pool() external view returns (PoolKey memory poolKey, bool isBound, int24 lower, int24 upper) {
        return (key, bound, tickLower, tickUpper);
    }

    function positionLiquidity() external view returns (uint128) {
        return liquidity;
    }

    function floats() external view returns (uint256, uint256) {
        return (float0, float1);
    }

    function pendingOf(address holder) external view returns (uint256, uint256) {
        return (pending0[holder], pending1[holder]);
    }

    function pendingTotals() external view returns (uint256, uint256) {
        return (pendingTotal0, pendingTotal1);
    }

    function leaseOf(uint256 seatId)
        external
        view
        returns (uint256 selfPrice, uint256 escrow, uint256 firmPrice, uint64 firmUntil, uint64 lastSettled)
    {
        Lease storage l = lease[seatId];
        return (l.selfPrice, l.escrow, l.firmPrice, l.firmUntil, l.lastSettled);
    }

    /// @notice Rent this seat has accrued but not yet paid. Uncapped by the escrow on purpose: the
    ///         difference between this and `escrow` is what foreclosure is about.
    function rentDue(uint256 seatId) external view returns (uint256) {
        Lease storage l = lease[seatId];
        if (l.selfPrice == 0) return 0;
        return Rent.owed(l.selfPrice, block.timestamp - l.lastSettled, RENT_BPS, RENT_PERIOD);
    }

    function rentTotals() external view returns (uint256 escrowed, uint256 unallocated) {
        return (escrowTotal, unallocatedRent0);
    }

    /// @notice The queue's order, head first. `orderWord()` is the raw slot behind it.
    function ranking() external view returns (uint256[] memory ids) {
        uint256 n = q.length;
        uint256 ord = order;
        ids = new uint256[](n);
        for (uint256 r; r < n; r++) {
            ids[r] = _idAt(ord, r);
        }
    }

    function orderWord() external view returns (uint256) {
        return order;
    }
}
