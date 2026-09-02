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
    ///
    ///      **PHASE 7 ADDS THE PREMIUM MARKS, AND PHASE 8 UNPACKED THEM. THAT COST WAS PAID
    ///      DELIBERATELY AND THE REASON IS NOT GAS.** `snap0`/`snap1` are the seat's marks against
    ///      the premium accumulators (see `premGrowth0`). They are read and written ONLY on the
    ///      settle path, so keeping them out of the balance word leaves the hot read of `(a0, a1)`
    ///      exactly as cheap as it was.
    ///
    ///      They used to be two `uint128`s sharing ONE slot, and that packing was bought with an
    ///      overflow argument — "an accrual is only taken when the standing inventory is at least
    ///      the size of the pot, so a growth increment can never exceed `2^64`". **The argument was
    ///      true and the condition it rested on was the defect.** Requiring `standing >= pot` is an
    ///      ARITHMETIC constraint wearing an economic hat, and on the 18/6 pool `QueueDeployBase`
    ///      actually ships it is false on essentially every swap in one direction — so the premium
    ///      was HELD, permanently, and `0 wei` of it ever reached the roster. See `premGrowth0` and
    ///      `test/queue/PremiumDecimals.t.sol`.
    ///
    ///      A feature that does not execute on the pool the deploy script builds is worse than a
    ///      feature that costs a slot. Unpacked, X128, no overflow condition, no hold except the
    ///      economic one.
    ///      **PHASE 8 ADDS `liquidity`, AND IT IS THE PREMIUM'S WEIGHT.** It is the Uniswap
    ///      liquidity this seat actually MINTED — the `dl` `_fundSeat` put into the position, less
    ///      whatever a withdrawal burned back out. It is deliberately NOT the seat's current
    ///      inventory: front-first allocation drives a seat to single-token composition, so
    ///      inventory is a quantity that vanishes precisely when the seat has just been jumped,
    ///      which is the moment it is owed most. Contributed liquidity survives conversion.
    struct Seat {
        uint128 a0; // token0 this seat holds
        uint128 a1; // token1 this seat holds
        uint256 snap0; // mark against `premGrowth0`, X128
        uint256 snap1; // mark against `premGrowth1`, X128
        uint128 liquidity; // Uniswap liquidity this seat contributed and has not withdrawn
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

    /// @notice **THE PROMOTION WITNESS.** Which rank a demotion vacated, and in which block.
    ///
    /// @dev A demotion at rank `r` slides ranks `r+1..n-1` up one place, so it PROMOTES every seat
    ///      behind it — without their consent, inside somebody else's transaction, and carrying the
    ///      price they set for the worse rank. `buyPrice` had no idea, and `_setPrice` is
    ///      holder-only, so the promoted seat was takeable on the spot at a stale number:
    ///      **executed at a 10x discount in `Evacuation.t.sol::test_8_7`** (PITFALLS 5.123b).
    ///
    ///      Two numbers instead of a per-seat flag, because marking the promoted seats would be an
    ///      O(n) write on every foreclosure and every demoting withdrawal — up to 31 `SSTORE`s on a
    ///      path that has to stay cheap. These are ONE slot, written once per demotion, and they
    ///      say exactly what a promoted seat needs to know: `rank >= lastDemotionRank` is "this seat
    ///      moved up in that demotion", and `block.number == lastDemotionBlock` is "it happened in
    ///      the block being executed right now". See `_buySeat` for the rule they carry.
    uint64 internal lastDemotionBlock;
    uint8 internal lastDemotionRank;

    // ========================================================== THE PRIORITY PREMIUM (Phase 7, §B.13)

    /// @notice φ — the share of the LP fee a filled seat hands to the book, in basis points.
    ///
    /// @dev **THIS IS THE PRICE OF QUEUE POSITION, AND IT IS THE REASON THE REST OF THE BOOK IS
    ///      WORTH FUNDING AT ALL.** Everything else in this contract decides WHO fills first. This
    ///      decides what being first COSTS.
    ///
    ///      Measured, per rank, over 30 price paths on the shipped ±10% band (benign flow, static
    ///      rank, φ = 0 — i.e. the mechanism as it stood before this parameter existed):
    ///
    ///          rank      fee %/yr    inventory     net %/yr    turnover %/yr
    ///             0      +1240.1%      -328.3%      +911.8%        +411,877%
    ///             1        +66.9%       -54.8%       +12.0%         +22,186%
    ///             7         +5.7%       -26.2%       -20.5%          +1,903%
    ///            31         +0.1%        -0.0%        +0.1%             +34%
    ///
    ///      **The head does not out-earn the book on PRICE — `Allocation`'s marginal pricing
    ///      already makes it fill at the stalest end of every move. It out-earns on VOLUME**: four
    ///      orders of magnitude more turnover than the tail. That single measurement rules out both
    ///      of the instruments this project reached for first. A price tweak cannot touch a
    ///      quantity difference, and a Harberger rent on an assessed value cannot either: at
    ///      τ = 10%/yr the coupon is ~6%/yr against a rank-1-to-31 inventory drag of 20–160%/yr.
    ///      Only a share of FEE FLOW is denominated in the same thing the advantage is.
    ///
    ///      So a filled seat keeps `(10000 - φ)/10000` of the fee it earned; the rest is paid to the
    ///      seats still standing in the line it jumped. **φ = 0 reduces exactly to the pre-Phase-7
    ///      contract** — no accrual, no settle, no gas — which is what makes every claim below
    ///      falsifiable against a real baseline rather than against a rewrite.
    ///
    ///      Immutable, for the same reason τ and the band are: a number somebody can move afterwards
    ///      is a privileged role over the split everyone else's capital is standing in.
    uint256 public immutable PREMIUM_BPS;

    /// @dev `pot * 2^128 / standing`, accumulated. `premGrowth0` is token0 premium per unit of
    ///      token1 STANDING; `premGrowth1` is the mirror.
    ///
    ///      **THE WEIGHT IS THE OPPOSITE TOKEN, AND THAT IS THE WHOLE ECONOMIC CONTENT.** A
    ///      `zeroForOne` swap takes token1 OUT of the front of the book and pays token0 in. The
    ///      seats that were jumped are precisely the ones still holding token1. So the token0
    ///      premium is paid out in proportion to the token1 a seat is standing in line with — you
    ///      are paid, in the token the swapper brought, for the token you did not get to sell.
    ///
    ///      A seat that was just drained to `a1 == 0` holds no weight and receives nothing from the
    ///      pot it generated. The payer does not pay itself.
    ///
    ///      ─────────────────────────────────────────────────────────────────────────────────────
    ///      **X128 IN 256 BITS SINCE PHASE 8, AND THE PREVIOUS ANSWER — X64 IN 128 BITS — WAS A
    ///      REAL DEFECT RATHER THAN A TIGHT FIT.**
    ///
    ///      **The diagnosis.** This number is *incoming-token wei per **OUTGOING-token** wei
    ///      standing*. The numerator and the denominator are DIFFERENT TOKENS, so the natural
    ///      magnitude of the ratio moves by `10^(dec_in - dec_out)`. On an 18/6 pair that is `1e12`
    ///      in one direction and `1e-12` in the other — **twenty-four orders of magnitude apart on
    ///      the same pool, in the same block.** A fixed-point scale `Q` must therefore be LARGE
    ///      enough that the small-ratio direction does not floor to zero, and SMALL enough that the
    ///      large-ratio direction does not overflow the accumulator. **No single `Q` in 128 bits can
    ///      satisfy both**, which is why this could not be fixed by tuning the constant.
    ///
    ///      **What that cost.** The old code bought its packing with `if (w < total) hold`, i.e. it
    ///      refused to accrue unless the standing inventory was at least the size of the pot. That
    ///      is an ARITHMETIC bound (keep `mulDiv(pot, 2^64, w)` under `2^64`) welded to an ECONOMIC
    ///      question (is there anybody to pay?). On the 18/6 pool `QueueDeployBase` ships, the
    ///      token0 pot of a one-token swap is `2.55e15` while `standing1` is `2.0e9`, so the
    ///      condition failed every time, the pot was held, and held pots ADD — measured over eight
    ///      swaps on a real pool: **0 of 4 accruals moved the accumulator, 100% stranded, `0 wei`
    ///      of token0 premium ever reached the roster.** The 18/18 control, identical in every other
    ///      respect, stranded 0%. The feature did not exist on the pool we deploy.
    ///
    ///      **Why 128 and not 64 or 96.** Same reason Uniswap's own `feeGrowthGlobal0X128` is 128:
    ///      it is the scale at which the smallest interesting numerator still registers against the
    ///      largest plausible denominator. At X64 a `1`-wei pot against a `2.5e19` book increments
    ///      by `mulDiv(1, 2^64, 2.5e19) == 0` and the wei is stranded; at X128 the same accrual
    ///      increments by `~1.4e19`. There is no upper cost to pay for it any more, because the
    ///      accumulator is now 256 bits and is allowed to wrap.
    ///
    ///      **The only guard left is the economic one.** `_accruePremium` holds when `w == 0` —
    ///      nobody is standing, so there is no one to pay — and otherwise pays the WHOLE pot. There
    ///      is no arithmetic condition, which is the entire point of the widening.
    uint256 internal premGrowth0;
    uint256 internal premGrowth1;

    /// @dev `Σ q[i].a0` and `Σ q[i].a1` across the whole roster — the accumulators' denominators.
    ///      Maintained incrementally at the SIX sites that write a seat balance rather than summed
    ///      on demand, because a swap must not pay O(n) to learn who is standing behind it.
    ///      `totals()` is the independent witness that the increments have not drifted.
    uint256 internal standing0;
    uint256 internal standing1;

    /// @dev `Σ q[i].liquidity` — the premium accumulators' denominator since Phase 8, and the whole
    ///      of why the premium is now decimals-independent.
    ///
    ///      **WHY THE WEIGHT IS LIQUIDITY AND NOT INVENTORY, IN ONE PARAGRAPH.** `premGrowth0` is
    ///      *token0 premium per unit of weight*. When the weight was `standing1`, the numerator and
    ///      the denominator were DIFFERENT TOKENS, so the ratio's natural magnitude moved by
    ///      `10^(dec_in - dec_out)` — `1e12` one way and `1e-12` the other on an 18/6 pair. Every
    ///      rule expressed as a comparison between them ("hold unless there is more standing than
    ///      pot") was therefore a units error, and on the pool `QueueDeployBase` ships it stranded
    ///      **100% of the token0 premium, 0 wei reaching the roster** over eight swaps.
    ///
    ///      Liquidity is ONE unit shared by both directions, so the comparison stops being a units
    ///      error. It is also dust-resistant: a seat drained to its last wei still carries the depth
    ///      it contributed, where under inventory weighting it carried `1` and took the entire pot
    ///      (`test_7_14`).
    ///
    ///      Maintained incrementally at the two sites that mint or burn a seat's liquidity, for the
    ///      same reason `standing0/1` are: a swap must not pay O(n) to learn its own denominator.
    uint256 internal standingL;

    /// @dev Liquidity in the position that NO seat contributed — everything
    ///      `sweepFloatIntoPosition` has minted out of the shared float. It is tracked rather than
    ///      ignored so `standingL + liquidityUnattributed == liquidity` is an EXACT identity a test
    ///      can assert, instead of an inequality with a hand-waved residual.
    ///
    ///      **IT IS CREDITED TO NOBODY, AND THAT IS A DECISION WITH A REASON.** The float is
    ///      capital that seats were ALREADY credited for through INVARIANT F and that nobody has
    ///      re-committed as depth; `liquidityContributed` measures what a seat committed. Paying
    ///      premium on it would also make `sweepFloatIntoPosition` — a permissionless function —
    ///      a THIRD writer of `liquidityContributed` and an O(n) full-roster write, which is a gas
    ///      griefing surface on a function anyone may call. Unattributed liquidity does not dilute
    ///      anyone: the pot is divided by `standingL`, so contributors simply split it among
    ///      themselves. The number is kept here so that apportioning it later is a decision rather
    ///      than an archaeology exercise.
    uint256 internal liquidityUnattributed;

    /// @dev Liquidity BURNED that neither a seat's own contribution nor the unattributed pot could
    ///      account for — the exact residual in INVARIANT L, tracked rather than tolerated.
    ///
    ///      It arises because a round trip does not close in liquidity: `_liquidityForAmounts`
    ///      sizes a deposit DOWN while `_liquidityToCover` sizes the matching withdrawal UP, so
    ///      taking out exactly what you put in can burn one unit more than was recorded against you.
    ///      §E.4 scale — one unit per round trip, not per swap. Naming it is what lets the invariant
    ///      be asserted as an equality: `standingL + unattributed == liquidity + shortfall`. A test
    ///      that asserted a BOUND here instead would be blind to every defect that moved the
    ///      residual the same way the rounding does (PITFALLS 5.53).
    uint256 internal liquidityShortfall;

    /// @dev Premium accrued into an accumulator and not yet settled into any seat. It is money the
    ///      position is already holding, so INVARIANT F counts it on the LEDGER side — without
    ///      these two terms the identity reads short by exactly the unsettled premium and every
    ///      conservation test goes red for a reason that is not a bug.
    uint256 internal premiumOwed0;
    uint256 internal premiumOwed1;

    /// @dev Premium accrued when NOBODY was standing (`standing == 0` — the swap emptied the book
    ///      of the outgoing token). There is no weight to divide by and no one to pay, so it is
    ///      HELD and folded into the next accrual that does have a recipient. Identical in shape
    ///      and purpose to `unallocatedRent0`, and held for the same reason: the wei has left the
    ///      allocation, so it must be somewhere or the identity breaks.
    uint256 internal premiumHeld0;
    uint256 internal premiumHeld1;

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
        /// @dev **THE RANK THIS SEAT WAS PRICED AT.** Stamped wherever a self-price is written, and
        ///      nowhere else — so it costs no extra `SSTORE` (it shares the slot `lastSettled` is
        ///      already written in) and it cannot drift from the price it describes.
        ///
        ///      `rankOfId(id) < rankAtPrice` is the whole of "this holder is standing somewhere
        ///      better than the place they priced, and did not ask to be". It reads ZERO for a seat
        ///      that has never been priced, which is rank 0 — the best rank there is — so an
        ///      unpriced seat is never stale and is takeable exactly as before. That is the
        ///      bootstrap, not a hole (see `buyPrice`).
        uint8 rankAtPrice;
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

    /// @dev What the INCOMING holder is putting back into the seat, inside `buySeatAndFund`.
    ///      TRANSIENT, for exactly the reason `paidForSeat` is: a plain `transfer` reads zero
    ///      without anyone having to remember to clear it, so the one funnel serves both paths and
    ///      neither has its own copy of the rule (PITFALLS 5.52).
    ///
    ///      **THIS IS THE BUYOUT'S HALF OF "RANK IS BACKED BY DEPTH".** A change of holder empties
    ///      the seat, so it always REMOVES the outgoing holder's contributed depth; the rank
    ///      survives only if the incoming holder puts at least as much back in the same call. See
    ///      `_settleRankOnTransfer`.
    uint256 internal transient fundOnTransfer0;
    uint256 internal transient fundOnTransfer1;

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
    /// @dev Rule A of PITFALLS 5.123(b): a seat whose rank improved in THIS block cannot be taken
    ///      at the price its holder set for the worse rank. See `_buySeat`.
    error SeatWasJustPromoted(uint256 seatId, uint256 rank, uint256 rankAtPrice);
    /// @dev The buyer named the worst rank they would accept and the seat is behind it. See
    ///      `buySeatAndFund`.
    error RankBelowMinimum(uint256 seatId, uint256 rank, uint256 maxRank);
    /// @dev See `Rent.MAX_SELF_PRICE` — a price that overflows the rent product is a settlement
    ///      that reverts, which is a seat that can never be foreclosed.
    error SelfPriceTooLarge(uint256 price, uint256 max);
    error BadRentParameters();
    /// @dev φ is a share of the LP fee. Above 10,000 bps there is no fee left to share.
    error BadPremium(uint256 premiumBps);
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
        uint256 firmWindow,
        uint256 premiumBps
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
        // φ is a share of the LP fee, so 10,000 bps is the whole of it and there is nothing above
        // that to give. A φ over 100% would credit a filled seat LESS than the marginal price it
        // absorbed — the seat would pay to be filled, which is not a price for rank, it is a
        // penalty for trading, and it makes the head's optimal play "hold no inventory".
        if (premiumBps > 10_000) revert BadPremium(premiumBps);
        PREMIUM_BPS = premiumBps;

        BAND_HALF_WIDTH = bandHalfWidth;
        RENT_BPS = rentBps;
        RENT_PERIOD = rentPeriod;
        FIRM_WINDOW = firmWindow;

        _mintRoster(foundingRoster);
    }

    /// @dev Split out of the constructor for the STACK, not for tidiness. Phase 7's `premiumBps`
    ///      took the parameter list to eleven, and Solidity decodes constructor arguments in the
    ///      same frame the body runs in — one more live slot and the ABI decoder's `headStart` goes
    ///      too deep to reach. A separate frame costs nothing at deploy time and keeps this
    ///      contract building without `via_ir`, which every gas number in the project is measured
    ///      under.
    function _mintRoster(address[] memory foundingRoster) private {
        uint256 n = foundingRoster.length;
        if (n == 0) revert EmptyRoster();
        if (n > MAX_SEATS) revert RosterTooLarge(n, MAX_SEATS);
        uint256 ord;
        for (uint256 i; i < n; i++) {
            address holder = foundingRoster[i];
            // A seat minted to `address(0)` would be a rank slot nobody can ever hold or sell, in a
            // roster whose scarcity is the product. `_moveSeat` refuses the same thing.
            if (holder == address(0)) revert ZeroHolder(i);
            // Both marks start at zero, which is exactly where the accumulators start, so a founding
            // seat has no retroactive claim and needs no initialising write.
            q.push(Seat({a0: 0, a1: 0, snap0: 0, snap1: 0, liquidity: 0}));
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

        // Publish the promotion. Ranks `r+1..n-1` just moved up one place each, and the seats now
        // standing at `r..n-2` are exactly the ones that did — see `lastDemotionBlock`. One slot,
        // one `SSTORE`, no walk. `r` fits a `uint8` because `MAX_SEATS` is 32 and `order` is one
        // byte per rank; `block.number` fits a `uint64` for longer than any chain will run.
        // forge-lint: disable-next-line(unsafe-typecast)
        lastDemotionBlock = uint64(block.number);
        // forge-lint: disable-next-line(unsafe-typecast)
        lastDemotionRank = uint8(r);

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
                // Settle first, for the same reason `_allocate` does: this is one of the six sites
                // that writes a seat balance, and the premium accumulator's weight is that balance.
                // No premium is CHARGED here — `amtOut == 0`, so no seat gave anything up and there
                // is no queue position to have jumped. Crediting the whole input is what front-first
                // means when there is only one claimant.
                (uint256 has0, uint256 has1) = _syncSeat(sd);
                if (outIsOne) {
                    sd.a0 = _u128(has0 + amtIn);
                    standing0 += amtIn;
                    if (rank < cursor0) cursor0 = rank;
                } else {
                    sd.a1 = _u128(has1 + amtIn);
                    standing1 += amtIn;
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

    // --------------------------------------------------------------------- the premium (Phase 7)

    /// @dev The accumulators' fixed-point scale. See `premGrowth0` for why 128 and not 64 or 96 —
    ///      X64 in a `uint128` made the premium INERT on an 18/6 pool, which is the pair we ship.
    ///      `internal` rather than `private` so the mandatory negative controls in `Premium.t.sol`
    ///      can READ it instead of hardcoding a copy. One of them carried `1 << 64` as a literal and
    ///      had to be found by the compiler when this changed; a control that has drifted from
    ///      production in a second place dies of the difference it was not testing (PITFALLS 5.105).
    uint256 internal constant PREMIUM_Q = 1 << 128;

    /// @notice What this swap hands to the seats it jumped.
    ///
    /// @dev `amtIn` is the position's receipt NET of the protocol skim, and its fee component is
    ///      `amtIn * lpFee / 1e6` — that is the definition of a v4 LP fee, not an estimate: the
    ///      swapper paid `principal / (1 - f)` and the difference is `amtIn * f`. The premium is φ
    ///      of that.
    ///
    ///      `expectedFee` rather than slot0's live `lpFee`: the pool's fee is CHECKED against this
    ///      immutable when the hook binds (`_afterInitialize`), so on a bound pool the two are the
    ///      same number, and reading the immutable keeps a dynamic-fee pool from being able to move
    ///      the price of rank after the fact. A hook that let the fee tier redefine φ would have a
    ///      privileged role wearing a different hat.
    ///
    ///      Rounds DOWN, so the premium can never exceed the fee it is a share of, and `amtIn - pot`
    ///      can never underflow.
    function _premiumOn(uint256 amtIn) internal view returns (uint256) {
        uint256 phi = PREMIUM_BPS;
        if (phi == 0) return 0;
        return FullMath.mulDiv(amtIn, uint256(expectedFee) * phi, 1e6 * 10_000);
    }

    /// @notice Book `pot` of the incoming token to the seats standing in the outgoing one.
    ///
    /// @dev **CALLED AFTER THE FILL, NEVER BEFORE, AND THE ORDER IS THE MECHANISM.** By the time
    ///      this runs the drained seats hold zero of the outgoing token, so they carry no weight and
    ///      collect nothing from the pot they just generated. Accruing first would hand the head
    ///      back its own payment in proportion to inventory it was about to lose.
    ///
    /// @param inIsZero true when the queue received token0 (a `zeroForOne` swap), so the pot is
    ///                 token0 and the weight is token1 standing.
    /// @dev `virtual` for ONE reason, the same one `_allocate` and `_u128` carry: the mandatory
    ///      negative controls in `Premium.t.sol` subclass this and change exactly one line each.
    ///      Nothing in production overrides it.
    function _accruePremium(bool inIsZero, uint256 pot, uint256 excludedL) internal virtual {
        if (inIsZero) {
            uint256 total = pot + premiumHeld0;
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            premiumOwed0 += pot;

            // **THE WHOLE POT, EVERY TIME THERE IS ANYBODY TO PAY. THERE IS NO ARITHMETIC
            // CONDITION HERE ANY MORE, AND ITS ABSENCE IS THE FIX.**
            //
            // This guard has been wrong twice, in two different ways, and both had the same root:
            // an arithmetic bound was wearing an economic hat.
            //
            //   1. `if (w < total) { hold everything }` — bounded `mulDiv(pot, 2^64, w)` so a
            //      `uint128` could not wrap. Held pots ADD into the next `total`, so every hold made
            //      the next release strictly harder: monotone in the wrong direction. And on the
            //      18/6 pool we actually ship, `w` is a 6-decimal quantity and `total` an
            //      18-decimal one, so it failed on essentially every swap — `0 wei` of token0
            //      premium reached the roster over eight swaps, against 0% stranded on the 18/18
            //      control (`test/queue/PremiumDecimals.t.sol`).
            //   2. `give = min(total, w)` — released incrementally, which cured the ratchet and NOT
            //      the decimals: on the same pool it paid out `w = 2.0e9` of a `2.55e15` pot per
            //      accrual, i.e. 0.00008%. Permanently inert became asymptotically inert.
            //
            // With a 256-bit X128 accumulator there is nothing left to bound, so the question
            // reduces to the only one that was ever economic: **is there anybody standing to pay?**
            //
            // `inc == 0` is kept as a floor rather than an overflow guard. At X128 it needs
            // `w > total * 2^128`, which a book of `uint128`-bounded balances cannot reach; it
            // survives because the alternative to holding an unpayable wei is DESTROYING it —
            // `premiumOwed0` would go on counting money no seat could ever claim (PITFALLS 5.124).
            //
            // **`mulDiv` CANNOT REVERT HERE.** `total` is a claim on tokens the position is already
            // holding, and v4 bounds those to `uint128`, so `total < 2^128`; `w >= 1` on this
            // branch. Hence `inc = total * 2^128 / w <= total * 2^128 < 2^256`, strictly.
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            if (inc == 0) {
                premiumHeld0 = total;
                return;
            }
            premiumHeld0 = 0;
            // **WRAPPING IS DELIBERATE, AND HERE IS WHY IT IS SAFE — the half of Uniswap's pattern
            // that gets copied without being checked.** Only DIFFERENCES of this accumulator are
            // ever read (`_claims` computes `premGrowth0 - s.snap0`, also unchecked). Modular
            // arithmetic makes that difference the true growth **provided no seat's mark is more
            // than one full `2^256` cycle stale**, and a seat is re-marked by `_syncSeat` on every
            // one of the six sites that touch its balance. A checked `+=` would revert instead of
            // wrapping, and a revert here is inside `_afterSwap` — it would brick the pool rather
            // than lose a rounding wei. Wrapping is the strictly safer failure.
            unchecked {
                premGrowth0 += inc;
            }
        } else {
            // THE MIRROR. Kept line-for-line identical to the branch above, in the same order, so a
            // reader can diff them by eye — that is the only defence a duplicated rule has, and this
            // project has been wrong in exactly one of two copies five times (PITFALLS 5.125).
            uint256 total = pot + premiumHeld1;
            if (total == 0) return;
            uint256 w = standingL - excludedL;
            premiumOwed1 += pot;
            uint256 inc = w == 0 ? 0 : FullMath.mulDiv(total, PREMIUM_Q, w);
            if (inc == 0) {
                premiumHeld1 = total;
                return;
            }
            premiumHeld1 = 0;
            unchecked {
                premGrowth1 += inc;
            }
        }
    }

    /// @notice Settle a seat's accrued premium into its own ledger, and report the result.
    ///
    /// @dev **THIS MUST RUN BEFORE EVERY WRITE TO `a0`/`a1`, AND THAT IS NOT A CONVENTION — IT IS
    ///      WHAT MAKES THE ACCUMULATOR CORRECT.** A seat's weight IS its balance. The accumulator
    ///      is only valid over an interval in which that weight did not move, so the claim has to
    ///      be cashed at the old weight before the new one lands. There are exactly six sites in
    ///      this contract that write a seat balance (`_allocate`, the degenerate fill, `_fundSeat`,
    ///      `withdraw`, the evacuation in `_onSeatTransfer`, and this function) and every one of
    ///      them enters through here first. `test_7_5` asserts that count against the source so a
    ///      seventh writer cannot be added silently.
    ///
    ///      The credit lands in the OPPOSITE token to the weight, which is why a settle can move
    ///      both balances and both `standing` totals at once.
    ///
    ///      `premiumOwed` cannot underflow: every claim is a floored `mulDiv` of a share of the pot,
    ///      so the settled total is bounded above by what was accrued. The residue — sub-wei per
    ///      settlement, by the §E.4 bound — stays in `premiumOwed` and is counted by INVARIANT F on
    ///      the ledger side, so it is accounted rather than lost.
    /// @dev `_syncSeat` narrowed to the one number the allocator's hot loop wants, so that loop
    ///      keeps EXACTLY the local count it had before the premium existed. `_allocate` compiles
    ///      without `via_ir` only just — two extra stack slots is the difference between building
    ///      and not — and a separate frame is free, where a second local is not. The other four
    ///      settle sites are not on a hot path and use the two-value form directly.
    function _syncBal(Seat storage s, bool outIsOne) internal returns (uint256) {
        (uint256 a0, uint256 a1) = _syncSeat(s);
        return outIsOne ? a1 : a0;
    }

    /// @dev `virtual` for the negative controls only. Nothing in production overrides it.
    function _syncSeat(Seat storage s) internal virtual returns (uint256 a0, uint256 a1) {
        (uint256 owed0, uint256 owed1) = _claims(s);
        a0 = s.a0;
        a1 = s.a1;

        if (owed0 != 0) {
            a0 += owed0;
            s.a0 = _u128(a0);
            standing0 += owed0;
            premiumOwed0 -= owed0;
        }
        if (owed1 != 0) {
            a1 += owed1;
            s.a1 = _u128(a1);
            standing1 += owed1;
            premiumOwed1 -= owed1;
        }
        // Marked unconditionally, including when the claim floored to zero. Leaving a mark behind
        // because its claim rounded away would let the same growth interval be claimed again later
        // against a larger balance.
        s.snap0 = premGrowth0;
        s.snap1 = premGrowth1;
    }

    /// @notice What a seat has accrued and not yet had credited.
    ///
    /// @dev **THE CLAIM FORMULA LIVES HERE AND NOWHERE ELSE.** Two callers need it — `_syncSeat`,
    ///      which cashes it, and `seat()`, which must report it — and on this project a rule kept in
    ///      two places has been wrong four times (PITFALLS 5.37, 5.50, 5.52 twice). A `view` that
    ///      disagreed with the settlement would be the worst version of it: every integrator and the
    ///      demo read `seat()`, so the disagreement would be invisible until somebody's withdrawal
    ///      returned a different number than their screen.
    ///
    ///      **BOTH CLAIMS ARE WEIGHTED BY THE BALANCES AS THEY STOOD DURING THE ACCRUAL, AND
    ///      NEITHER SEES THE OTHER.** A settlement credits the token OPPOSITE its weight, so
    ///      computing token0's claim first and then weighting token1's by the already-credited `a0`
    ///      pays a seat for inventory it did not hold while the premium was being earned — it
    ///      compounds one settlement into the other and breaks the conservation the pot is divided
    ///      under. Both weights are read before either credit is formed.
    function _claims(Seat storage s) internal view returns (uint256 owed0, uint256 owed1) {
        // **ONE WEIGHT, BOTH DIRECTIONS.** It used to be `a1` for the token0 claim and `a0` for
        // the token1 claim — the seat's inventory in the token it was standing with. That is what
        // made the accumulators' scale depend on the pair's decimals, and it is what let a seat
        // drained to one wei collect an entire pot. Contributed liquidity is the same unit in both
        // directions and does not move when inventory converts.
        //
        // The old two-weight form needed a paragraph explaining that both had to be READ before
        // either credit was formed, because a settlement credits the token opposite its weight and
        // would otherwise compound one into the other. That hazard is gone: `liquidity` is not
        // touched by a settlement at all.
        uint256 wl = s.liquidity;
        if (wl == 0) return (0, 0);
        // **THE SUBTRACTIONS ARE `unchecked` AND THE WRAP IS THE POINT, NOT AN OVERSIGHT.**
        //
        // `premGrowth0/1` are 256-bit accumulators that only ever increase, and `_accruePremium`
        // adds to them `unchecked` so that reaching `2^256` wraps instead of reverting inside
        // `_afterSwap`. Modular arithmetic then makes `premGrowth - snap` the TRUE growth over the
        // interval, because `(a + d) - a == d` in `uint256` for any `d < 2^256` — the wrap cancels.
        //
        // **The condition this rests on, stated rather than assumed:** it is exact provided no
        // seat's mark is more than one full `2^256` cycle stale. `_syncSeat` re-marks a seat at
        // every one of the six sites that write its balance, and a seat that is never touched is
        // one nobody is filling, depositing to, or withdrawing from. Cumulative growth of `2^256`
        // between two touches of the same seat is not reachable by any flow this pool can carry —
        // it is the same assumption Uniswap's `feeGrowthGlobal0X128` makes, and it is the half of
        // that pattern people copy without checking, so it is written down here.
        //
        // A CHECKED subtraction would be the unsafe choice: on a wrap it reverts, and `_claims` is
        // reached from `_allocate`, so that revert is a bricked pool rather than a lost wei.
        unchecked {
            uint256 d0 = premGrowth0 - s.snap0;
            if (d0 != 0) owed0 = FullMath.mulDiv(wl, d0, PREMIUM_Q);
            uint256 d1 = premGrowth1 - s.snap1;
            if (d1 != 0) owed1 = FullMath.mulDiv(wl, d1, PREMIUM_Q);
        }
    }

    // ------------------------------------------------------------------------------- the allocator

    /// @dev `virtual` for ONE reason: the mandatory negative controls (§D.3 N1-N4) subclass this
    ///      and change exactly one line each. Nothing in production overrides it.
    function _allocate(bool outIsOne, uint256 amtIn, uint256 amtOut) internal virtual {
        uint256 n = q.length;
        uint256 start = outIsOne ? cursor1 : cursor0;

        // THE PREMIUM COMES OFF THE TOP, AND THAT IS WHY CONSERVATION SURVIVES IT UNTOUCHED.
        // `Allocation.step`'s remainder line closes the split to the wei against whatever total it
        // is handed, so handing it `amtIn - pot` makes `Σ give == amtIn - pot` exactly, with the
        // marginal price curve unchanged — every `give` is the same proportion of a smaller whole.
        // No rounding is introduced anywhere: `pot` is floored, and the wei it represents are
        // accounted in `premiumOwed` until a seat settles them.
        // `pot` is deliberately NOT given a local: `st.amtIn` already holds `amtIn - pot`, so the
        // premium is recoverable as `amtIn - st.amtIn` wherever it is needed below. One fewer stack
        // slot, and one fewer place the same number can be written down differently.
        Allocation.State memory st = Allocation.init(amtIn - _premiumOn(amtIn), amtOut);
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

        // **`i` IS HOISTED OUT OF THE LOOP DELIBERATELY, AND IT COSTS NOTHING.** The premium
        // needs the last rank this fill ACTUALLY TOUCHED, and `next` is a cursor rather than a
        // rank: it equals `lastTouched + 1` when the final seat was exactly exhausted, and
        // `lastTouched` when it was partially filled. Handing the cursor to `_settlePremium`
        // therefore excluded — and, per that function's own docblock, FORFEIT — the claim of a seat
        // the walk never visited, on every earlier accrual as well as this one. Measured at
        // 7.17e19 wei erased in both directions (`test_W6`/`test_W7`).
        //
        // On exit `i` is one past the last rank examined, in every path that reaches the code
        // below: the loop cannot leave with `st.remaining != 0` (the revert underneath sees to
        // that), and the last rank examined is always one that FILLED, because a `continue`d seat
        // leaves `remaining` untouched. `_allocate` is unreachable with `amtOut == 0` — the
        // degenerate fill in `_afterSwap` returns before it — so the body runs at least once and
        // `i > start` is guaranteed. This buys the exact quantity a new local would have, and
        // `_allocate` is at the stack limit without `via_ir`.
        uint256 i = start;
        for (; i < n && st.remaining > 0; i++) {
            Seat storage seat_ = q[_idAt(ord, i)];

            // **SETTLE BEFORE THE EMPTY TEST, NOT AFTER IT.** A settlement credits the token
            // OPPOSITE the weight, so settling a seat can raise the very balance this loop is about
            // to drain: a seat sitting at `a1 == 0` with an unsettled token1 premium is NOT empty,
            // it is unsettled. Testing first and `continue`-ing past it would skip a funded seat,
            // which is the silent theft of rank INVARIANT C exists to prevent — reached by
            // `test_7_4`, which fails against the cheaper ordering.
            uint256 bal = _syncBal(seat_, outIsOne);
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
        //
        // **IT REWINDS TO `start`, NOT TO RANK 0, AND THE DISTINCTION IS REAL BUT DOES NOT BITE.**
        // The seats BELOW `start` were already empty of the outgoing token when this fill began
        // (that is what `start == cursorX` means), and this fill credited them nothing, so pulling
        // back further would only cost the next swap a walk over seats it would skip anyway.
        // Measured by the economics workstream: `startshare` at rank 1 is 90.8-99.5%, i.e. a fill
        // begins at the head almost always, so `start` IS 0 in the overwhelming majority of swaps
        // and the two rules coincide. Recorded because reading the line invites the question, not
        // because there is anything to change.
        // **THE TOTALS ARE THE FILL'S OWN TOTALS, NOT A RUNNING SUM, AND THAT IS A PROOF RATHER
        // THAN AN OPTIMISATION.** Past the underflow check directly above, the walk sourced exactly
        // `amtOut` of the outgoing token (that is what `st.remaining == 0` means) and handed out
        // exactly `st.amtIn == amtIn - pot` of the incoming one (that is what the remainder line
        // guarantees). So the aggregate movement is known in closed form, two accumulator locals
        // disappear — `_allocate` is at the stack limit without `via_ir` — and `standing` cannot
        // drift from the balances by mis-summing a loop that has already been proven exact.
        // `test_7_1` asserts these against `totals()`, which sums the roster the other way.
        if (outIsOne) {
            cursor1 = next;
            if (start < cursor0) cursor0 = start;
            standing1 -= amtOut;
            standing0 += st.amtIn;
        } else {
            cursor0 = next;
            if (start < cursor1) cursor1 = start;
            standing0 -= amtOut;
            standing1 += st.amtIn;
        }

        // **LAST, AFTER THE TOTALS.** The pot is divided among the seats still standing in the
        // outgoing token once this fill is done, so the seats it just drained carry no weight and
        // collect none of it. `outIsOne` means token1 left and token0 arrived, so the pot is
        // token0 — `inIsZero == outIsOne`.
        // **THE PREMIUM IS SETTLED IN ONE CALL AND NOT INLINE, FOR A STACK REASON THAT IS WORTH
        // WRITING DOWN.** `_allocate` compiles without `via_ir` only just — the file has said so
        // since Phase 7 — and the payer set needed two more locals (the excluded weight and a
        // bitmap of ranks). It did not fit: the first attempt was `Stack too deep`. Passing the
        // range instead and letting the callee re-derive both keeps this function at exactly the
        // locals it had before the premium was excluded from its own payers.
        _settlePremium(ord, start, i, outIsOne, amtIn - st.amtIn);
    }

    /// @notice Accrue the fill's premium to everyone EXCEPT the seats that fill just paid.
    ///
    /// @dev **"THE PAYER DOES NOT PAY ITSELF" — RESTORED ON A WEIGHT THAT SURVIVES CONVERSION.**
    ///
    ///      The premium is skimmed off `amtIn` BEFORE it is split, so the seats that pay it are
    ///      exactly the seats the fill credited. Under the old inventory weighting they were
    ///      excluded for free, because a drained seat's weight was its now-zero inventory. A weight
    ///      that survives conversion cannot do that by itself — that is the price of fixing the
    ///      decimals — so the exclusion is made explicit here. It is done in TWO places at once and
    ///      they must agree: the payers' weight is removed from the denominator, AND their marks
    ///      are moved past the accrual. Doing only the second would leave their share accrued to
    ///      nobody and stranded in `premiumOwed` — PITFALLS 5.124 in a new costume.
    ///
    ///      **O(k), NOT O(n).** `k` is the seats the fill reached, which is ONE for the head-only
    ///      swap that dominates. Every slot written here was already written earlier in the same
    ///      call by `_syncSeat`, so it is a dirty-slot `SSTORE` at 100 gas rather than 2,900, and
    ///      only the accumulator that actually moved is re-marked.
    ///
    ///      **WHY THE RANGE IS `[start, next]` INCLUSIVE, AND WHAT THAT COSTS.** Against the
    ///      pro-rata benchmark, displacement is `D_i = S·w_i/W − t_i`. A fully-drained seat has
    ///      `D_i = w_i(S/W − 1) ≤ 0` — it sold MORE than pro-rata, so it is a beneficiary of the
    ///      ordering and is owed nothing. A partially-filled seat CAN have `D_k > 0` (`w = (1,100)`,
    ///      `S = 1.5` gives `D_2 = +0.985`), so excluding it forfeits a real claim. It is excluded
    ///      anyway, because including it is what let the last-wei holder take an ENTIRE pot: as
    ///      `S → W` every other seat is drained, so the boundary seat is the only one left
    ///      unexcluded and its share is 100%. Measured before this line existed: `standing1` fell
    ///      to 1 wei on seat 7 and it claimed the whole 2.667e17 pot having paid an eighth of it
    ///      (`test_7_14`).
    ///
    ///      **THIS COMMENT USED TO SAY THE EXCLUDED CLAIM WAS "DEFERRED TO THE NEXT ACCRUAL, NEVER
    ///      DESTROYED", AND THAT SENTENCE DESCRIBED 0–2% OF THE MONEY WHILE BEING USED TO JUSTIFY
    ///      THE OTHER 98–100%.** Deferral is real only on `_accruePremium`'s HOLD branch, the one
    ///      that fires when the remaining weight is zero. In the ordinary case the accrual
    ///      DISTRIBUTES the whole pot immediately to the seats that were not excluded, and the
    ///      mark-advance below then moves the excluded seats past it — so what an excluded seat
    ///      loses is not deferred back to it, it is **FORFEIT, and transferred to the seats still
    ///      standing.** Measured share of all withheld wei still held at path end under the shipped
    ///      rule: **BENIGN 0.00%, NORMAL 0.09%, TOXIC 1.96%.**
    ///
    ///      The exclusion is kept anyway, and the honest reason is the one above rather than the
    ///      one that was written here: including a fully-drained seat is what lets the payer pay
    ///      ITSELF, and `test_7_14` measured the concentration that produces — a seat holding one
    ///      wei taking an entire pot it had paid an eighth of. A forfeit that is bounded by one
    ///      fill's own premium beats an extraction that scales with the whole pot. That is a real
    ///      trade-off with a real cost on one side, and it is stated rather than defined away
    ///      (AGENTS §2: write down what you PROVED, not what the guard is for).
    ///
    ///      `next` is a cursor, so it equals the last paid rank when that seat was partially filled
    ///      and one PAST it when the seat was exactly exhausted. In the second case this excludes
    ///      one seat the fill did not reach — and, per the paragraph above, excluding it FORFEITS
    ///      its claim on this pot rather than deferring it. **A separate defect is suspected on
    ///      exactly that boundary** — a seat the walk never visited, and therefore never
    ///      `_syncSeat`'d, having its mark jumped forward and losing its claim on every EARLIER
    ///      accrual too. It is traced but not yet executed; it is deliberately NOT patched here
    ///      ahead of the directed test, because a speculative fix to a premium boundary is how
    ///      PITFALLS 5.124 and 5.127 were introduced in the first place.
    ///
    ///      There is exactly one other site that credits a seat from a swap: the degenerate fill in
    ///      `_afterSwap`. It needs no equivalent because it withholds no premium and never reaches
    ///      `_accruePremium`. Checked in the source, not assumed — that is the shape which has been
    ///      wrong here five times.
    function _settlePremium(uint256 ord, uint256 start, uint256 touchedEnd, bool outIsOne, uint256 pot)
        internal
        virtual
    {
        uint256 last = touchedEnd - 1;

        uint256 lTouched;
        for (uint256 i = start; i <= last; i++) {
            lTouched += q[_idAt(ord, i)].liquidity;
        }

        // **THE WHOLE-BOOK FILL, WHICH IS THE CASE THAT BRICKED THE POOL.** Excluding the payers
        // leaves `w == standingL - lTouched == 0` exactly when the fill reached every seat that is
        // standing. `_accruePremium` then takes its HOLD branch, and a held pot is money the
        // position is holding that `standing0`/`standing1` does not count. Hold enough of it and
        // the ledger is short of what the position can pay, so the next fill in the other direction
        // cannot be sourced and reverts `QueueUnderflow` — from inside `_afterSwap`, which is a
        // BRICKED POOL rather than a lost wei. Measured in the terminal state: the position held
        // 4.9567e16 wei of token0 against 2.573e17 of liquidity it could not trade.
        //
        // The remedy is to drop the exclusion, not to widen a gate. **"The payer does not pay
        // itself" has no meaning on a fill that swept the whole book** — there is no seat that did
        // not pay, so there is no seat the rule is protecting. Distributing over the full
        // `standingL` returns every wei to the roster in proportion to contributed liquidity.
        //
        // **AND THE MARKS MUST NOT MOVE ON THIS BRANCH.** The two halves of the exclusion have to
        // agree: removing the weight without moving the marks strands the money one way
        // (`test_M7d`), moving the marks without removing the weight strands it the other. Here
        // NEITHER happens — full denominator, and every touched seat keeps the mark `_syncSeat`
        // already left at the pre-accrual growth, so it collects the share the accrual just gave
        // it. That is self-consistent, and it is the only pairing that conserves.
        //
        // **IT CANNOT BE GAMED INTO `test_7_14`.** That extraction needed exactly ONE unexcluded
        // seat, so that its share of the denominator was 100%; this branch fires only at ZERO
        // unexcluded seats. The two conditions are disjoint, and between them the exclusion still
        // stands.
        //
        // `standingL == 0` still holds the pot, and correctly so: there is genuinely nobody to pay.
        // No seat can be short in that state either, because no seat is funded.
        bool sweptBook = standingL == lTouched;
        _accruePremium(outIsOne, pot, sweptBook ? 0 : lTouched);
        if (sweptBook) return;

        // AFTER the accrual, so the mark lands on the growth this fill produced.
        uint256 g = outIsOne ? premGrowth0 : premGrowth1;
        for (uint256 i = start; i <= last; i++) {
            Seat storage seat_ = q[_idAt(ord, i)];
            if (outIsOne) {
                seat_.snap0 = g;
            } else {
                seat_.snap1 = g;
            }
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
        // **WRITER 1 OF EXACTLY TWO.** `liquidityContributed` is paired with the liquidity actually
        // MINTED, never with the tokens supplied — a single-token in-range deposit mints ZERO
        // (`_liquidityForAmounts` takes the min of the two legs and `_liq0(..., 0) == 0`), so it
        // contributes no depth, attracts no flow, and must therefore earn no premium. Weighting by
        // what was supplied instead of by what was minted is exactly the free ride this closes.
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
        // SETTLE BEFORE THE DEPOSIT LANDS. Same rule as `_allocate`, and here it also closes the
        // deposit-side version of the attack `_settleAhead` closes for rent: without it a depositor
        // would weigh a flash-loaned balance against premium that accrued over a period they were
        // not standing for. Settling first cashes the seat's claim at the weight it actually held.
        // Since Phase 8 the weight is `liquidity`, so this must run BEFORE `dl` is added or the
        // seat is paid for depth it had not yet provided.
        (uint256 has0, uint256 has1) = _syncSeat(s);
        s.a0 = _u128(has0 + amount0);
        s.a1 = _u128(has1 + amount1);
        standing0 += amount0;
        standing1 += amount1;
        if (dl != 0) {
            s.liquidity += dl;
            standingL += dl;
        }

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
        // SETTLE BEFORE THE ENTITLEMENT IS READ, not merely before the write. The seat's accrued
        // premium is part of what it owns, so a check against the unsettled balance would refuse a
        // withdrawal the holder is entitled to make — the premium would be visible only after some
        // unrelated transaction happened to touch the seat.
        (uint256 has0, uint256 has1) = _syncSeat(s);
        if (w0 > has0) revert OverEntitlement(w0, has0);
        if (w1 > has1) revert OverEntitlement(w1, has1);

        uint128 burned;
        (p0, p1, burned) = _payOut(w0, w1);
        bool tookDepthOut = _chargeBurn(s, burned);

        s.a0 = _u128(has0 - p0);
        s.a1 = _u128(has1 - p1);
        standing0 -= p0;
        standing1 -= p1;

        // Cursors are deliberately NOT touched HERE. A withdrawal only ever REDUCES a seat, so it
        // cannot make a cursor lead; leaving them costs a little gas and can never lose money. The
        // demotion below does its own cursor adjustment, which is exact — see `_demoteToTail`.
        // Withdrawing to zero does NOT destroy the seat: an empty seat is pure rank with no capital,
        // and being able to hold, price and sell one is what gives rank a price of its own.

        // **A WITHDRAWAL COSTS THE HOLDER THEIR PLACE IN THE QUEUE.**
        //
        // Without this line the product's central claim is not enforced by anything. QUEUE sells
        // SUBORDINATION: the front seat is filled first, so it absorbs adverse selection first, and
        // the seats behind it are protected by the inventory standing in front of them. An instant,
        // rank-preserving withdrawal lets the holder who is PAID to bear that risk delete it at a
        // moment of their choosing and keep the rank anyway —
        //
        //     withdraw(head) -> adverse swap -> addToSeat(head)
        //
        // — in ONE transaction, hands the fill to the seats behind, and returns to the front. It
        // was measured, not imagined: on an eight-seat book a 5.8% adverse move cost the head 267
        // bps of its seat value if it stood still and ZERO if it evacuated, while the seats behind
        // it gave up 10.7% more inventory. `test/queue/Evacuation.t.sol` is the whole experiment,
        // two live pools differing only in the evacuation.
        //
        // **HARBERGER DOES NOT PRICE THIS, AND BELIEVING IT DID WAS THE ACTUAL DEFECT.**
        // PITFALLS 5.9 recorded rank-then-run as CLOSED by Phase 4 on the strength of `test_4_7` —
        // which warps THIRTY DAYS in every arm. Rent is a time integral (`Rent.owed(price, elapsed,
        // ...)`, and `_settleSeat` returns on `elapsed == 0`), so the bill for an abandonment is
        // proportional to how long you are away, and this one is away for no time at all. Priced at
        // 100e18, the same window costs 8.219e17 wei over thirty days and EXACTLY ZERO atomically
        // (`test_8_5`). The lease could not see the attack because the attack has no duration.
        //
        // Rank is the thing the mechanism can take back, so rank is what it charges.
        //
        // **A WITHDRAWAL THAT PAID NOTHING CHANGES NOTHING.** The guard is on what was actually
        // PAID, never on what was asked. Two reasons, and neither is a threshold: `_payOut` clamps
        // to the float under dust policy F1, so a holder whose request is clamped to zero would
        // otherwise pay the full penalty for receiving nothing; and `withdraw(id, 0, 0)` would
        // become a way to demote yourself by accident. It opens no door — a withdrawal that moves
        // no capital dodges no fill.
        //
        // **WHAT COSTS A RANK IS TAKING DEPTH OUT, NOT TAKING MONEY OUT.**
        //
        // The first version of this line demoted on any withdrawal that PAID something. That closes
        // the attack, and it also punishes the holder the mechanism is supposed to be paying: the
        // front seat is where the flow is, so realising accrued premium means calling `withdraw`,
        // and a blanket rule would cost them the seat for collecting the coupon they are owed.
        //
        // `liquidityContributed` gives the principled line with no constant in it. A withdrawal
        // that burns into the seat's own contributed liquidity is the holder LEAVING — that is the
        // evacuation, and it is the only thing the attack can be built from, because dodging a fill
        // REQUIRES the capital to be out of the pool. A withdrawal the float covers, or one that
        // burns only liquidity backing earnings the seat never contributed, moves no depth and
        // costs no rank.
        //
        // The old guard survives inside `_chargeBurn`: `burned == 0` returns false, so a withdrawal
        // that moved nothing — including one the dust policy clamped to zero — still changes
        // nothing.
        //
        // **ORDERING.** Last, after every ledger write and before the external `_send`. Nothing
        // above it reads a rank, so the position is free; putting it before the transfer keeps the
        // state final ahead of the only external call. `_demoteToTail` adjusts both cursors itself
        // and the adjustment is exact in both directions — a seat below a cursor holds zero of that
        // token by INVARIANT C, so the seats that shift down past it were zero too, and a seat at
        // or above the cursor moves nothing the cursor describes.
        if (tookDepthOut) _demoteToTail(seatId);

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

        // A pending claim belongs to an ADDRESS, not a seat, so the burn has no seat to charge and
        // falls to `liquidityUnattributed` by construction.
        uint128 burned;
        (p0, p1, burned) = _payOut(w0, w1);
        if (burned != 0) {
            uint256 fromPot = burned > liquidityUnattributed ? liquidityUnattributed : burned;
            liquidityUnattributed -= fromPot;
            if (burned != fromPot) liquidityShortfall += burned - fromPot;
        }

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
    /// @dev Returns the liquidity it BURNED alongside what it paid, because `liquidityContributed`
    ///      has to be paired with the liquidity actually destroyed and this is the only place that
    ///      knows it. `claimPending` discards it — a pending claim belongs to an ADDRESS, not to a
    ///      seat, so there is no seat to debit and the burn falls to `liquidityUnattributed`.
    function _payOut(uint256 w0, uint256 w1) internal returns (uint256, uint256, uint128 burned) {
        uint256 d0 = w0 > float0 ? w0 - float0 : 0;
        uint256 d1 = w1 > float1 ? w1 - float1 : 0;
        if (d0 != 0 || d1 != 0) {
            uint128 dl = _liquidityToCover(d0, d1);
            if (dl != 0) {
                (uint256 g0, uint256 g1) = _burnPosition(dl); // decrements `liquidity` (PITFALLS 5.23)
                float0 += g0;
                float1 += g1;
                burned = dl;
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
        return (w0, w1, burned);
    }

    /// @notice **WRITER 2 OF EXACTLY TWO.** Charge burned liquidity against a seat's contribution.
    ///
    /// @dev Capped at what the seat actually contributed, and the cap is the whole of DECISION 2's
    ///      rule: what is burned BEYOND a seat's own contribution is liquidity that was backing
    ///      accrued EARNINGS rather than principal, so it belongs to the shared pool and is charged
    ///      to `liquidityUnattributed`. That is also floored, because the position can be short of
    ///      both — a seat withdrawing earnings after its contribution is exhausted burns liquidity
    ///      that neither pot recorded. `_checkLiquidityIdentity` measures that residual rather than
    ///      assuming it away.
    ///
    /// @return reduced whether the SEAT's own contribution fell. That, not "was anything paid", is
    ///         what costs a holder their place in the queue.
    function _chargeBurn(Seat storage s, uint128 burned) internal returns (bool reduced) {
        if (burned == 0) return false;
        uint128 fromSeat = burned > s.liquidity ? s.liquidity : burned;
        if (fromSeat != 0) {
            s.liquidity -= fromSeat;
            standingL -= fromSeat;
            reduced = true;
        }
        uint256 rest = burned - fromSeat;
        if (rest != 0) {
            uint256 fromPot = rest > liquidityUnattributed ? liquidityUnattributed : rest;
            liquidityUnattributed -= fromPot;
            if (rest != fromPot) liquidityShortfall += rest - fromPot;
        }
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
        // **THE DEPTH THE OUTGOING HOLDER WAS STANDING WITH.** Read before anything is emptied,
        // because it is the number the rank is measured against in `_settleRankOnTransfer`. It is
        // read HERE rather than inside the evacuation block below because a seat can hold
        // contributed depth while both its balances read zero — `_liquidityToCover` can burn less
        // than the seat contributed — and the early return below would then skip the rule.
        uint128 had = s.liquidity;
        // Settle before the evacuation reads the balances: the accrued premium belongs to the
        // DEPARTING holder, who was the one standing in line while it was earned. Reading the
        // unsettled balance would leave it behind for whoever the seat is handed to — and on the
        // buyout path that is a transfer from the seller to the buyer that nobody agreed to.
        (uint256 a0, uint256 a1) = _syncSeat(s);
        // Pure rank and no prepaid rent: nothing to move, no external call, no position to touch.
        // This is the common case and the one the buyout leans on.
        if (a0 == 0 && a1 == 0 && esc == 0) {
            // **THE SAME MIRROR AS THE ONE BELOW, IN THE SIBLING BRANCH — AND ASKING WHETHER A RULE
            // HAS A SECOND HOME IS THE WHOLE OF THE §5 ASYMMETRY LENS.** A seat can hold contributed
            // depth with BOTH balances at zero: `_payOut` only burns when the float cannot cover the
            // request, so a withdrawal the float covered empties the ledger and leaves every unit of
            // `s.liquidity` standing in the position (`test_8_15`). Reaching this branch in that
            // state and returning would hand the departing holder's depth — and with it their share
            // of the premium's denominator — to whoever the seat goes to, which is the exact thing
            // the block below refuses to do. Nothing is burned here, so the WHOLE of it is orphaned.
            //
            // `had == 0` on the pure-rank path, so this costs that path nothing: no branch taken, no
            // `SSTORE`, and the early return is still the cheap one it was put here to be.
            if (had != 0) {
                s.liquidity = 0;
                standingL -= had;
                liquidityUnattributed += had;
            }
            _settleRankOnTransfer(seatId, had);
            return;
        }

        (uint256 p0, uint256 p1, uint128 burnedOnExit) = _payOut(a0, a1);
        // The seat leaves EMPTY, so its whole recorded contribution leaves with it — the buyer
        // receives rank, never depth. Charging only `burnedOnExit` would leave the departing
        // holder's `liquidityContributed` on a seat that now holds nothing, and the new holder
        // would collect premium weighted by depth somebody else provided and took away.
        {
            if (had != 0) {
                s.liquidity = 0;
                standingL -= had;
            }
            uint256 rest = burnedOnExit > had ? burnedOnExit - had : 0;
            if (rest != 0) {
                uint256 fromPot = rest > liquidityUnattributed ? liquidityUnattributed : rest;
                liquidityUnattributed -= fromPot;
                if (rest != fromPot) liquidityShortfall += rest - fromPot;
            }
            // **THE MIRROR, AND ITS ABSENCE BROKE INVARIANT L BY 20% OF THE POSITION ON AN ORDINARY
            // BUYOUT, IN BAND.** The branch above handles `burnedOnExit > had` — the payout burned
            // MORE depth than this seat contributed. The other direction is not symmetric bookkeeping
            // for its own sake: when `_payOut` burns LESS than the seat contributed, because the
            // FLOAT covered the payout, `had - burnedOnExit` of depth is still sitting in the v4
            // position while the line above has already removed all of `had` from `standingL` and
            // zeroed the seat. Without this, that depth is recorded by NOTHING —
            // `liquidityShortfall` is fed only from `rest`, so the instrument built to measure this
            // residue cannot see it.
            //
            // Reached by the most ordinary sequence there is: a `zeroForOne` swap drains the head of
            // token1 (that is INVARIANT C working as designed), the holder prices the seat, and
            // `buySeat` credits the price into `float0` BEFORE `_payOut` runs — so nothing burns at
            // all. Measured: `positionLiquidity` unchanged at 2.0000e20 while `standingL` fell
            // 2.0000e20 -> 1.6000e20. **At maturity it is not a corner case, it is the DEFAULT shape
            // of every buyout**, because out of range a seat holds only one token.
            //
            // NO TOKEN IS LOST — INVARIANT F and R both hold throughout, which is exactly why
            // conservation could not see it (5.92: conservation cannot see WHO got the money). What
            // it corrupts is `standingL`, THE PREMIUM'S DENOMINATOR: drive it down this way and
            // `_accruePremium`'s `w == 0` branch holds every pot forever, so the premium switches
            // itself off while the fee flow it is a share of continues.
            //
            // **`withdraw`'s `_chargeBurn` — WRITER 2 OF THE SAME FIELD — already gets this right**
            // (it debits only `min(burned, s.liquidity)`), so the two writers of
            // `liquidityContributed` disagreed. That is the §5 asymmetry lens and the
            // one-rule-two-places family for the seventh time (5.37, 5.50, 5.52 twice, 5.73, 5.125,
            // 5.132). Proven in a subclass first — production `_onSeatTransfer` unchanged plus this
            // single line, after which L, F and R all close and `unattributed == seatL` to the wei.
            if (had > burnedOnExit) liquidityUnattributed += had - burnedOnExit;
        }

        // The seat leaves EMPTY whatever happened above. Anything the position could not release on
        // the spot — residual-scale, by the §E.4 bound — is retained as a claim on the DEPARTING
        // holder rather than travelling with the rank to somebody who never owned it.
        s.a0 = 0;
        s.a1 = 0;
        standing0 -= a0;
        standing1 -= a1;
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

        // BEFORE the outgoing transfer, so every ledger write and the rank are final ahead of the
        // one external call this function makes to a party that is not `msg.sender` — the same
        // ordering rule `withdraw` states for its own demotion.
        _settleRankOnTransfer(seatId, had);

        // The escrow rides out on the same transfer. It is currency0 the hook already holds
        // OUTSIDE the position and outside `float0`, so unlike `p0` it needs nothing released and
        // is never clamped.
        _send(from, p0 + esc, p1);
    }

    /// @notice **RANK IS BACKED BY DEPTH — THE SECOND WRITER OF THE RULE `withdraw` ALREADY HAS.**
    ///
    /// @dev `withdraw` demotes when a payout reduces the seat's own contributed liquidity, because
    ///      taking depth out is the holder LEAVING and leaving is what the evacuation attack is
    ///      built from (PITFALLS 5.122). `_onSeatTransfer` takes ALL of a seat's depth out on every
    ///      change of holder and, until this function existed, cost no rank at all — so a holder
    ///      with a second address had the identical attack with `transfer` in place of `withdraw`,
    ///      and it was FREE on the unpriced seats the founding roster starts in (PITFALLS 5.123a,
    ///      `test_8_6`). One rule, two writers, enforced in one place at each of them.
    ///
    ///      **WHY THE EXEMPTION IS "PUT THE DEPTH BACK" AND NOT "YOU PAID FOR IT".** The obvious
    ///      remedy is to keep the rank when the change of holder is a settled buyout at the posted
    ///      price, on the theory that a gift is an evacuation and a purchase is a market. It does
    ///      not survive contact: the price is SELF-SET and the buyout is open to anybody, so the
    ///      holder buys their own seat with their own second address and the payment is a wash
    ///      between two addresses one person controls. Executed in `test_8_11` — the full +267 bps
    ///      edge, the rank kept, zero rent, and the only residue a firm quote at a number the
    ///      attacker chose. So the test cannot be who paid; it has to be whether the depth the rank
    ///      is priority OVER is still standing when the call ends.
    ///
    ///      The buyer therefore funds INSIDE the buyout (`buySeatAndFund`) or accepts the tail.
    ///      That is also the honest shape of the trade: today a buyer pays for a rank that arrives
    ///      EMPTY and must fund it in a second transaction, exposed in between.
    ///
    ///      **WHAT IT COSTS, STATED PLAINLY.** A buyer can be griefed: the incumbent front-runs
    ///      with a real `addToSeat`, raising the depth the buyer must match, and the buyer pays the
    ///      price and lands at the tail. It cannot be flash-loaned — repaying the loan needs a
    ///      `withdraw`, which demotes and undoes the deposit — and it gains the incumbent NOTHING,
    ///      because the buyout still lands and they lose the seat and the rank either way. There is
    ///      deliberately no "revert if I do not keep the rank" flag: that would hand every incumbent
    ///      a veto over their own buyout, which is the one thing `_onSeatTransfer` exists to refuse.
    ///
    ///      An EMPTY seat — pure rank, no contributed depth — is untouched by this rule and moves
    ///      exactly as it did before. That is the market Phase 4 built, and it still works.
    function _settleRankOnTransfer(uint256 seatId, uint128 had) private {
        uint256 f0 = fundOnTransfer0;
        uint256 f1 = fundOnTransfer1;
        if (f0 != 0 || f1 != 0) _fundSeat(seatId, f0, f1);
        // The comparison is against what the seat CONTRIBUTED, never against what it held: a seat
        // whose balances were converted by fills still stood with its depth, and a seat that
        // contributed nothing (a single-token in-range deposit mints zero) removed nothing.
        if (had != 0 && q[seatId].liquidity < had) _demoteToTail(seatId);
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
        // **THIS DEPTH IS CREDITED TO NOBODY — see `liquidityUnattributed` for the reason.** It is
        // recorded rather than ignored so INVARIANT L stays an EXACT identity instead of an
        // inequality with a hand-waved residual.
        liquidityUnattributed += added;
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

        // **RULE B OF PITFALLS 5.123(b), AND RULE A IS WORTHLESS WITHOUT IT.** A holder whose rank
        // IMPROVED since they last priced is repricing an asset the mechanism swapped under them:
        // they posted a number for rank 1 and are now standing at rank 0, by somebody else's
        // foreclosure, without being asked. The firm quote exists to stop a holder repricing out of
        // a buyout THEY CAN SEE COMING AT THE PRICE THEY POSTED — it was never meant to hold a
        // holder to a price for a position they did not choose. Arming it here would leave them
        // takeable at the stale number for a whole `FIRM_WINDOW` however fast they reacted, so
        // Rule A's one block of grace would buy them exactly nothing.
        //
        // **IT ONLY DECLINES TO ARM A NEW WINDOW; IT NEVER CLEARS ONE THAT IS OPEN.** The
        // running-minimum branch below still binds, so "drop to zero, then raise" stays
        // self-destructive and a promotion cannot be used to escape a window the holder brought on
        // themselves. That is why the predicate is read on the `else if` and not before the branch.
        bool promoted = rankOfId(seatId) < l.rankAtPrice;

        if (block.timestamp < l.firmUntil) {
            // Already inside a window: the quote is the RUNNING MINIMUM over it. This is the line
            // that makes "drop to zero, then raise" self-destructive rather than clever.
            if (newPrice < l.firmPrice) l.firmPrice = newPrice;
            // casting to 'uint64' is safe: a uint64 holds unix seconds for ~5.8e11 years, and
            // FIRM_WINDOW is bounded at 365 days by the constructor.
            // forge-lint: disable-next-line(unsafe-typecast)
            l.firmUntil = uint64(block.timestamp + FIRM_WINDOW);
        } else if (old != 0 && !promoted) {
            // A price was in effect and is now changing: it stays honoured for the window.
            l.firmPrice = old < newPrice ? old : newPrice;
            // casting to 'uint64' is safe: a uint64 holds unix seconds for ~5.8e11 years, and
            // FIRM_WINDOW is bounded at 365 days by the constructor.
            // forge-lint: disable-next-line(unsafe-typecast)
            l.firmUntil = uint64(block.timestamp + FIRM_WINDOW);
        }
        // else: no window is open and either there was no price to honour — the seat was free to
        // take up to this instant, so there is nothing a firm quote could protect a buyer against —
        // or the holder is repricing a rank they did not choose, which is Rule B above.

        l.selfPrice = newPrice;
        l.lastSettled = uint64(block.timestamp);
        // **THE STAMP, AND IT GOES HERE BECAUSE THIS IS THE ONE PLACE A SELF-PRICE IS WRITTEN.**
        // It shares the slot `lastSettled` is already being written in, so it is free, and a price
        // can never exist without the rank it was set at. `rankOfId` returns at most `MAX_SEATS-1`.
        // forge-lint: disable-next-line(unsafe-typecast)
        l.rankAtPrice = uint8(rankOfId(seatId));
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
        _buySeat(seatId, maxPrice, newSelfPrice, 0, 0, type(uint256).max);
    }

    /// @notice Take a seat AND put the depth back in the same call, which is what keeps its rank.
    ///
    /// @param amount0 / amount1 the buyer's own deposit, funded exactly as `addToSeat` funds one.
    ///
    /// @dev **THIS IS THE ONLY WAY TO BUY A RANK OFF A FUNDED SEAT.** A change of holder evacuates
    ///      the seat (§B.8 — it must, or the allocator quotes depth the queue cannot source), so it
    ///      always removes the outgoing holder's contributed liquidity. `_settleRankOnTransfer`
    ///      demotes on that removal unless the incoming holder replaces it here, in the same call.
    ///      Read that function for why the test is depth and not payment.
    ///
    ///      A buyer who wants only the rank of an EMPTY seat, or who is content with the tail,
    ///      calls `buySeat` and passes nothing. `buySeat(id, max, price)` is exactly
    ///      `buySeatAndFund(id, max, price, 0, 0)` — one body, so the two cannot drift apart.
    ///
    ///      **HOW MUCH IS ENOUGH IS THE POOL'S ARITHMETIC, NOT A NUMBER THIS CONTRACT INVENTS.**
    ///      What must be matched is `seatLiquidity(seatId)`, and what a given `(amount0, amount1)`
    ///      mints is `_liquidityForAmounts` at the live price — the min of the two legs. A buyer
    ///      who supplies one token only mints ZERO and lands at the tail.
    /// @param maxRank the worst rank the buyer will accept, checked AFTER every settlement this
    ///        call performs. **`buySeat` names a SEAT ID and pays for a RANK, and it had no rank
    ///        guard at all — only `maxPrice`.** Since a withdrawal that takes depth out demotes
    ///        (PITFALLS 5.122), an incumbent who sees a buyout coming can front-run it with
    ///        `withdraw(all)`: the seat lands at the tail, the buyer pays the rank-0 price for rank
    ///        `n-1`, and the seller keeps both the price and their capital. Pass `type(uint256).max`
    ///        to accept any rank, which is what the three-argument `buySeat` does.
    ///
    ///        **THIS IS A VETO, AND IT IS PRICED RATHER THAN FREE — SAY SO RATHER THAN DENYING
    ///        IT.** An incumbent CAN make a rank-guarded buyout revert, by demoting themselves
    ///        first. What that costs them is their entire place in the queue, permanently, and it
    ///        cannot be repeated on the same seat: a seat already at the tail has nothing left to
    ///        sacrifice, and it is still buyable by anyone passing `type(uint256).max`. So the
    ///        property that survives is **you can always be bought out of your SEAT; you can only
    ///        defend your RANK by giving it up.** That is a different animal from the veto §B.8
    ///        forbids, which was free, unilateral and repeatable ("keep one wei in the seat").
    ///        The same guard is deliberately NOT offered against the DEPTH a funded buyer must
    ///        match, because there the incumbent keeps the seat funded and forfeits nothing — see
    ///        `_settleRankOnTransfer`.
    function buySeatAndFund(
        uint256 seatId,
        uint256 maxPrice,
        uint256 newSelfPrice,
        uint256 amount0,
        uint256 amount1,
        uint256 maxRank
    ) external nonReentrant {
        _buySeat(seatId, maxPrice, newSelfPrice, amount0, amount1, maxRank);
    }

    function _buySeat(
        uint256 seatId,
        uint256 maxPrice,
        uint256 newSelfPrice,
        uint256 amount0,
        uint256 amount1,
        uint256 maxRank
    ) private {
        if (!bound) revert PoolNotBound();
        if (seatId >= q.length) revert NoSuchSeat(seatId);

        // Settle BEFORE reading the price: a holder who cannot pay is demoted first, and the buyer
        // then pays whatever the seat is actually worth after that, not before it.
        _settleSeat(seatId);

        // **THE SAME RULE `addToSeat` CARRIES, AT THE SECOND ENTRY POINT CAPITAL HAS INTO A SEAT.**
        // Rent is handed to the seats BEHIND a payer, pro-rata by the `currency0` balance read at
        // settlement, so a deposit that lands before those payers are settled captures rent that
        // accrued over a period the depositor was not there for — and the deposit can be borrowed.
        // `addToSeat` settles everyone ahead first for exactly this reason; a funding buyout that
        // did not would be that hole with a new front door. Only when there is a deposit: a plain
        // buyout adds no balance and can capture nothing.
        if (amount0 != 0 || amount1 != 0) _settleAhead(rankOfId(seatId));

        // **RULE A OF PITFALLS 5.123(b): A SEAT PROMOTED IN THIS BLOCK IS NOT FOR SALE IN IT.**
        //
        // `_demoteToTail` writes `order` and the two cursors and NO lease. Nothing arms a firm
        // quote on a PROMOTION, and `_setPrice` is holder-only — so a holder slid into rank 0 by
        // somebody else's foreclosure could not reprice inside that somebody's transaction, and was
        // takeable on the spot at the number they had posted for rank 1. Executed at a **10x
        // discount** in `test_8_7`. Worse, they could not protect themselves in the NEXT block
        // either: a raise leaves the seat firm at the OLD price for a whole `FIRM_WINDOW`, which is
        // why Rule B in `_setPrice` is not optional decoration on top of this.
        //
        // **READ AFTER BOTH SETTLEMENTS, AND THAT IS LOAD-BEARING.** `_settleSeat` above and
        // `_settleAhead` on the line above can each FORECLOSE a seat and promote this one — inside
        // this very call. A guard read before them would be answered by the attacker simply passing
        // a deposit, so that `_settleAhead` performs the promotion after the check had already run.
        //
        // **WHAT IT COSTS, NAMED RATHER THAN LEFT TO BE FOUND.** For one block after any demotion,
        // the seats that demotion promoted are not for sale. A holder can manufacture that block:
        // park a second seat AHEAD of your own, let its meter run dry, and foreclose it with the
        // permissionless `settleRent` in the same transaction as a buyout you want to dodge. It is
        // not free — it costs the sacrificial seat its rank, permanently, to dodge ONE buyout, and
        // it needs a fresh sacrifice every time — but it is a real evasion and it is bounded rather
        // than absent. It is accepted because the thing it replaces is a free, instant taking at a
        // 10x discount.
        uint256 rankNow = rankOfId(seatId);
        uint256 pricedAt = lease[seatId].rankAtPrice;
        if (block.number == lastDemotionBlock && rankNow >= lastDemotionRank && rankNow < pricedAt) {
            revert SeatWasJustPromoted(seatId, rankNow, pricedAt);
        }
        // ...and the buyer's own guard on what they are paying for. See `buySeatAndFund`.
        if (rankNow > maxRank) revert RankBelowMinimum(seatId, rankNow, maxRank);

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

        // Hand the price and the buyer's deposit to `_onSeatTransfer` so the seat leaves FIRM at
        // what was paid for it and lands with the depth its rank is priority over, then move it
        // through the same single funnel every other change of holder uses.
        paidForSeat = price;
        fundOnTransfer0 = amount0;
        fundOnTransfer1 = amount1;
        _moveSeat(msg.sender, holder, msg.sender, seatId, 1);
        paidForSeat = 0;
        fundOnTransfer0 = 0;
        fundOnTransfer1 = 0;

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

        // **WEIGHTED BY CONTRIBUTED DEPTH, NOT BY `a0`, AND THAT IS A CORRECTNESS FIX.**
        //
        // Rent used to be split pro-rata by each recipient's `currency0` BALANCE. That is the one
        // quantity front-first allocation is designed to destroy: above the band every seat has
        // been converted out of currency0, so the weights collapse to dust and **a seat holding ONE
        // WEI of currency0 took the ENTIRE pot** — measured, as an identity rather than a bound, by
        // `test_M9b`. Below the band the identical code paid out perfectly, because there every
        // seat is 100% currency0; a single-direction test reports whichever half it happens to pick.
        //
        // `fundRent`'s own docblock already argues against `a0` for the rent SOURCE. Nobody had
        // applied the same argument to the SINK. `liquidity` is the depth the seat contributed and
        // has not withdrawn — it survives conversion, which is exactly why the premium was moved
        // onto it in Phase 8 (PITFALLS 5.124/5.126).
        //
        // A `w == 1` special case was considered and REJECTED: it patches the symptom, no
        // principled threshold exists, and an attacker simply sits one wei above it.
        //
        // **UNITS: the split is now (liquidity ratio) x tokens, a cross-dimension divide.** That is
        // the 5.124 bug class, so it is tested at 18/6 decimals in BOTH directions rather than at
        // the 18/18 fixture that hid the identical error in `_accruePremium` (LAW 1 as amended).
        // The shape is precedented, not novel: `_accruePremium` already divides a token pot by a
        // liquidity weight.
        //
        // **CORRELATED FAILURE, stated because it is a real cost of this fix:** rent and premium
        // are now weighted by the same kind of quantity, so one wrong `standingL`-shaped number
        // corrupts BOTH streams at once, where before an error in one was visible against the
        // other. `invariant_I9` is the guard that makes that acceptable, and it had to land first.
        uint256 w;
        for (uint256 i = r + 1; i < n; i++) {
            w += q[_idAt(ord, i)].liquidity;
        }

        if (w == 0) {
            // Nobody behind CONTRIBUTED ANY DEPTH — every seat behind the payer has withdrawn its
            // liquidity, which is the honest reading of "there is nobody to pay". (It used to mean
            // "nobody behind holds currency0", which above the band was true of a fully funded
            // roster.) The money has LEFT the payer's escrow, so it must be accounted somewhere or
            // the balance identity breaks and a wei is stranded.
            escrowTotal -= amount;
            unallocatedRent0 = pot;
            emit RentSettled(payerId, amount, 0, pot);
            return;
        }

        Allocation.State memory st = Allocation.init(pot, w);
        for (uint256 i = r + 1; i < n && st.remaining > 0; i++) {
            uint256 id = _idAt(ord, i);
            uint256 bal = q[id].liquidity;
            if (bal == 0) continue;
            // `(0, 0)` — rent is split pro-rata by contributed depth and has no price curve. The
            // weight loop above and this one must read the SAME field: a numerator and denominator
            // that disagree is precisely the 5.124 defect, and this rule lives in two places.
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

    /// @notice What seat `i` owns, **including premium it has accrued but not yet been credited**.
    ///
    /// @dev It reports the SETTLED value on purpose, and that is a correctness requirement rather
    ///      than a courtesy. `withdraw` settles before it checks entitlement, so a holder may take
    ///      out the accrued premium; a view that reported the raw slot would show them less than
    ///      they can actually withdraw, and every integrator reading it would price a seat below
    ///      what it is worth. `test_7_5` caught exactly that — the demo's seller was paid 4.03e18
    ///      more than this view had promised.
    ///
    ///      The companion identity is NOT `Σ seat(i) == totals()`: `totals()` is the RAW ledger sum,
    ///      which is the quantity conservation is stated over, and the difference between the two is
    ///      the unsettled premium reported by `premiums()`. See INVARIANT F.
    function seat(uint256 i) external view returns (uint256, uint256) {
        Seat storage s = q[i];
        (uint256 owed0, uint256 owed1) = _claims(s);
        return (uint256(s.a0) + owed0, uint256(s.a1) + owed1);
    }

    /// @notice The depth this seat contributed and has not withdrawn — the premium's weight.
    function seatLiquidity(uint256 i) external view returns (uint128) {
        return q[i].liquidity;
    }

    /// @notice `Σ seatLiquidity`, and the liquidity in the position no seat contributed.
    /// @dev `contributed + unattributed == positionLiquidity()` is INVARIANT L.
    function liquidityTotals() external view returns (uint256 contributed, uint256 unattributed, uint256 shortfall) {
        return (standingL, liquidityUnattributed, liquidityShortfall);
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

    /// @notice Premium accrued but not yet settled into a seat (`owed`), and accrued with nobody
    ///         standing to receive it (`held`, folded into the next accrual).
    /// @dev INVARIANT F counts `owed` on the LEDGER side: the tokens are already inside the
    ///      position, they are simply not yet attributed to a seat. `held` is a subset of `owed`.
    function premiums() external view returns (uint256 owed0, uint256 owed1, uint256 held0, uint256 held1) {
        return (premiumOwed0, premiumOwed1, premiumHeld0, premiumHeld1);
    }

    /// @notice The accumulators' denominators — `Σ a0` and `Σ a1` as maintained incrementally.
    /// @dev Deliberately SEPARATE from `totals()`, which sums the roster. Two numbers that must
    ///      agree, computed two different ways, is exactly the writer/reader pair this project
    ///      keeps getting wrong — so here it is on purpose, as an assertion target rather than as a
    ///      second source of truth. Nothing in production reads `totals()`; `test_7_1` reads both.
    function standings() external view returns (uint256, uint256) {
        return (standing0, standing1);
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
