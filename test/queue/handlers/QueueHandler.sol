// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {QueueHarness} from "../QueueHarness.sol";
import {QueueHook} from "../../../src/queue/QueueHook.sol";
import {QueueSeats} from "../../../src/queue/QueueSeats.sol";
import {Allocation} from "../../../src/queue/libraries/Allocation.sol";
import {Rent} from "../../../src/queue/libraries/Rent.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title QueueHandler — the bounded actor for PLAN §C.6's invariant campaign
///
/// @notice Every state-changing entry point the shipping hook exposes, driven with `bound()`ed
///         inputs by a fixed set of actors, against the REAL v4 stack.
///
/// @dev **WHY THE CHECKS IN HERE ARE GHOST COUNTERS AND NOT ASSERTIONS.**
///
///      The campaign runs `fail_on_revert = false` (see `Invariant.t.sol` for the §D.8 V5
///      justification). Under that setting Foundry SWALLOWS any revert a handler call produces —
///      and a failed `assertEq` inside a handler is a revert. So an assertion written here would
///      be silently discarded exactly when it fired, and the suite would go green on a real
///      defect. Every per-call check therefore INCREMENTS A COUNTER, and `Invariant.t.sol` asserts
///      the counter is zero. That is the only form that survives `fail_on_revert = false`.
///
///      **WHY EVERY CALL IS `try`/`catch`ED AND THE REASON IS CLASSIFIED.**
///
///      `fail_on_revert = false` also hides the opposite failure: a handler whose calls all revert
///      for an unforeseen reason produces a green campaign that exercised nothing. Rather than
///      choose between the two settings, this handler catches every revert and checks the selector
///      against an EXPLICIT allow-list of outcomes the mechanism is entitled to produce
///      (authorisation, over-withdrawal, an empty queue, buying your own seat). Anything else
///      increments `unexpectedReverts`, which invariant I7 asserts is zero. That is stricter than
///      `fail_on_revert = true` — which would only tell us that something reverted — because it
///      names WHICH reverts are legitimate, and `callSummary()` reports how often each action
///      actually landed so a vacuous campaign is visible rather than green.
contract QueueHandler is CommonBase, StdCheats, StdUtils {
    using StateLibrary for IPoolManager;

    QueueHarness public immutable hook;
    IPoolManager public immutable poolManager;
    IUniswapV4Router04 public immutable swapRouter;
    IPermit2 public immutable permit2;
    Currency internal immutable c0;
    Currency internal immutable c1;
    PoolKey internal key;

    address[] public actors;

    // ---------------------------------------------------------------------------- the ghost ledger
    //
    // I1's witness. Built from HANDLER INPUTS and from token flows measured across the hook's
    // boundary — never from `hook.totals()`, which is the thing under test.
    //
    // The one place a contract read feeds a ghost is the escrow refund bundled into a seat
    // evacuation (`_onSeatTransfer` sends `p0 + esc` in one transfer, so the currency0 leg of a
    // transfer cannot be decomposed from outside). It is measured as the drop in
    // `escrowTotal + unallocatedRent0`, which rent settlement leaves invariant — and that quantity
    // is itself asserted independently by I8a/I8b/I8c. The currency1 leg has no rent in it at all
    // and is therefore fully independent.
    uint256 public gIn0;
    uint256 public gOut0;
    uint256 public gIn1;
    uint256 public gOut1;

    // ------------------------------------------------------------------------------ ghost counters
    /// @dev A revert whose selector is not in `_isExpected`. I7.
    uint256 public unexpectedReverts;
    bytes4 public firstUnexpectedSelector;
    /// @dev Which action produced it. Without this the selector alone names no call site.
    bytes32 public firstUnexpectedTag;
    /// @dev A swap that filled a seat while leaving a funded seat AHEAD of it unexhausted. I4.
    uint256 public frontFirstViolations;
    /// @dev A `settleRent` that changed `escrowTotal + unallocatedRent0`. I8a.
    uint256 public rentConservationViolations;
    /// @dev A `settleRent` that credited a seat AHEAD of the payer. I8e — the HardcapHook shape.
    uint256 public rentDirectionViolations;

    // ------------------------------------------------------------------------- coverage bookkeeping
    mapping(bytes32 action => uint256) public calls;
    mapping(bytes32 action => uint256) public reverts;
    /// @dev How many swaps actually moved a seat. A campaign where this is zero proved nothing
    ///      about the allocator, however green it is.
    uint256 public swapsThatFilled;
    uint256 public orderPermuted;
    uint256 public buyouts;
    uint256 public evacuationsWithCapital;

    // ------------------------------------------------------------------ the measured residual (I2)
    /// @dev The worst SHORTFALL of backing against the ledger seen at any point in this run, in
    ///      parts per billion of the ledger. **The bound in `Invariant.t.sol` is DERIVED from this
    ///      number rather than picked** — the same discipline as `test_5_3b`, which derives the
    ///      supportable roster depth from the gas measurement so the constant and the document
    ///      cannot drift apart.
    /// @dev In parts per billion of LIFETIME INFLOW, not of the current ledger. The ledger is
    ///      drained by withdrawals while the residual accumulates, so the current ledger is the one
    ///      denominator this ratio must not use.
    uint256 public worstShortPpb0;
    uint256 public worstShortPpb1;
    /// @dev The worst shortfall in absolute wei. A RELATIVE bound alone is useless at the bottom of
    ///      the range: a 1-wei shortfall against a 1-wei ledger is 100% and means nothing. Both are
    ///      recorded so the bound can be "absolute floor OR relative", sized from both numbers.
    uint256 public worstShortAbs0;
    uint256 public worstShortAbs1;
    /// @dev The worst SURPLUS, absolutely. This one is not a residual: nothing in the mechanism
    ///      credits the position without crediting the ledger, so a surplus is a defect.
    uint256 public worstOver0;
    uint256 public worstOver1;

    constructor(
        QueueHarness _hook,
        IPoolManager _pm,
        IUniswapV4Router04 _router,
        IPermit2 _permit2,
        PoolKey memory _key,
        address[] memory _actors
    ) {
        hook = _hook;
        poolManager = _pm;
        swapRouter = _router;
        permit2 = _permit2;
        key = _key;
        c0 = _key.currency0;
        c1 = _key.currency1;
        for (uint256 i; i < _actors.length; i++) {
            actors.push(_actors[i]);
            _approveAll(_actors[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice Tell the ghost where the queue already is.
    /// @dev The founding roster is funded by the FIXTURE, before the handler exists, so the ghost
    ///      has to be told what those deposits were. It takes the fixture's own deposit amounts —
    ///      never `hook.totals()`, which would make I1 assert the hook against itself. Callable
    ///      once, before the campaign starts.
    function seedGhost(uint256 a0, uint256 a1) external {
        require(gIn0 == 0 && gIn1 == 0, "ghost already seeded");
        gIn0 = a0;
        gIn1 = a1;
    }

    // ============================================================================ the bounded actions

    /// @dev Fund a seat. The prank is the seat's ACTUAL holder, so this action exercises the funding
    ///      arithmetic rather than the authorisation check — `unauthorised()` covers that separately.
    function addToSeat(uint256 seatSeed, uint256 a0, uint256 a1) external {
        uint256 id = _seat(seatSeed);
        address who = hook.ownerOf(id);
        a0 = bound(a0, 0, 4_000e18);
        a1 = bound(a1, 0, 1_000e18);
        if (a0 == 0 && a1 == 0) a0 = 1e18; // `NothingDeposited` is covered by an Adversarial test
        _mintTo(who, a0, a1);

        vm.prank(who);
        try hook.addToSeat(id, a0, a1) {
            gIn0 += a0;
            gIn1 += a1;
            calls["addToSeat"]++;
            _noteSolvency();
            _noteForeclosures();
        } catch (bytes memory err) {
            _bad("addToSeat", err);
        }
    }

    /// @dev Withdraw. Bounded to what the seat actually holds most of the time, and deliberately
    ///      allowed past it some of the time so `OverEntitlement` is a REACHED path rather than an
    ///      assumed one.
    function withdraw(uint256 seatSeed, uint256 w0, uint256 w1, bool overshoot) external {
        uint256 id = _seat(seatSeed);
        address who = hook.ownerOf(id);
        (uint256 s0, uint256 s1) = hook.seat(id);
        w0 = overshoot ? bound(w0, s0 + 1, s0 + 1e18 + 1) : bound(w0, 0, s0);
        w1 = bound(w1, 0, s1);

        uint256 b0 = _bal(c0, who);
        uint256 b1 = _bal(c1, who);
        vm.prank(who);
        try hook.withdraw(id, w0, w1) {
            gOut0 += _bal(c0, who) - b0;
            gOut1 += _bal(c1, who) - b1;
            calls["withdraw"]++;
            _noteSolvency();
        } catch (bytes memory err) {
            _bad("withdraw", err);
        }
    }

    /// @dev A real swap through the real router. `amountIn` is scaled off what the queue can
    ///      actually source, so the campaign spends its budget on FILLS rather than on a wall of
    ///      `QueueUnderflow`s — while still crossing the boundary often enough to exercise it.
    function swap(uint256 actorSeed, bool zeroForOne, uint256 amountIn) external {
        address who = _actor(actorSeed);
        (uint256 t0, uint256 t1) = hook.totals();
        uint256 capacity = zeroForOne ? t1 : t0;
        // The pool is initialised at 1:4, so sourcing `x` of the outgoing token costs roughly `4x`
        // of token0 or `x/4` of token1. The upper bound overshoots on purpose.
        uint256 hi = zeroForOne ? capacity * 6 + 1 : capacity / 2 + 1;
        amountIn = bound(amountIn, 1, hi);
        _mintTo(who, zeroForOne ? amountIn : 0, zeroForOne ? 0 : amountIn);

        uint256[] memory before = _outgoingByRank(zeroForOne);
        uint256 p0 = _bal(c0, address(poolManager));
        uint256 p1 = _bal(c1, address(poolManager));
        uint256 pf = poolManager.protocolFeesAccrued(zeroForOne ? c0 : c1);

        vm.prank(who);
        try swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: who,
            deadline: block.timestamp
        }) {
            calls["swap"]++;
            _noteSolvency();
            uint256 pfDelta = poolManager.protocolFeesAccrued(zeroForOne ? c0 : c1) - pf;
            if (zeroForOne) {
                gIn0 += _bal(c0, address(poolManager)) - p0 - pfDelta;
                gOut1 += p1 - _bal(c1, address(poolManager));
            } else {
                gIn1 += _bal(c1, address(poolManager)) - p1 - pfDelta;
                gOut0 += p0 - _bal(c0, address(poolManager));
            }
            _checkFrontFirst(zeroForOne, before);
        } catch (bytes memory err) {
            _bad("swap", err);
        }
    }

    /// @dev A plain ERC-6909 seat transfer between two actors. This is the SECOND trigger for the
    ///      evacuation drain (PITFALLS 5.56) and the path `transferFrom` forgot in Phase 3.
    function transferSeat(uint256 seatSeed, uint256 toSeed, bool viaTransferFrom) external {
        uint256 id = _seat(seatSeed);
        address from = hook.ownerOf(id);
        address to = _actor(toSeed);
        if (to == from) to = actors[(toSeed + 1) % actors.length];
        if (to == from) return; // single-actor roster: nothing to transfer to

        (uint256 s0, uint256 s1) = hook.seat(id);
        uint256 rentBefore = _rentPot();
        uint256 b0 = _bal(c0, from);
        uint256 b1 = _bal(c1, from);

        if (viaTransferFrom) {
            vm.prank(from);
            hook.approve(address(this), id, 1);
            // The handler itself is the spender here, which is the ONLY way the allowance branch
            // of `transferFrom` is entered at all — `msg.sender == sender` short-circuits past it.
            try hook.transferFrom(from, to, id, 1) {
                _afterEvacuation("transferSeat", from, b0, b1, rentBefore, s0, s1);
            } catch (bytes memory err) {
                _bad("transferSeat", err);
            }
        } else {
            vm.prank(from);
            try hook.transfer(to, id, 1) {
                _afterEvacuation("transferSeat", from, b0, b1, rentBefore, s0, s1);
            } catch (bytes memory err) {
                _bad("transferSeat", err);
            }
        }
    }

    /// @dev Take a seat at the price its holder set. The buyer is any actor that is not the holder.
    function buySeat(uint256 seatSeed, uint256 buyerSeed, uint256 newPrice, bool tightMax) external {
        uint256 id = _seat(seatSeed);
        address from = hook.ownerOf(id);
        address buyer = _actor(buyerSeed);
        if (buyer == from) buyer = actors[(buyerSeed + 1) % actors.length];
        if (buyer == from) return;

        // Settlement inside `buySeat` runs BEFORE the price is read, so the quote can move under
        // us. `tightMax` deliberately passes the pre-settlement quote as the cap, which is how a
        // real buyer would behave and is the only way `PriceAboveMax` is ever reached.
        uint256 maxPrice = tightMax ? hook.buyPrice(id) : type(uint256).max;
        newPrice = bound(newPrice, 0, 5_000e18);
        _mintTo(buyer, 6_000e18, 0);

        (uint256 s0, uint256 s1) = hook.seat(id);
        uint256 rentBefore = _rentPot();
        uint256 b0 = _bal(c0, from);
        uint256 b1 = _bal(c1, from);
        uint256 buyerBefore = _bal(c0, buyer);

        vm.prank(buyer);
        try hook.buySeat(id, maxPrice, newPrice) {
            buyouts++;
            // **THE PRICE IS MEASURED, NOT ASSUMED.** `buySeat` settles BEFORE it reads the quote,
            // and settlement can foreclose the seat on the way in — which zeroes `selfPrice` and
            // therefore the price actually charged. The pre-call quote would be wrong in exactly
            // that case. The buyer's only currency0 outflow inside this call is the price, so the
            // buyer's balance delta IS the price, measured across the hook's boundary like every
            // other ghost term.
            uint256 paid = buyerBefore - _bal(c0, buyer);
            _afterEvacuationWithPrice("buySeat", from, b0, b1, rentBefore, s0, s1, paid);
        } catch (bytes memory err) {
            _bad("buySeat", err);
        }
    }

    function setSelfPrice(uint256 seatSeed, uint256 price) external {
        uint256 id = _seat(seatSeed);
        address who = hook.ownerOf(id);
        price = bound(price, 0, 5_000e18);
        vm.prank(who);
        try hook.setSelfPrice(id, price) {
            calls["setSelfPrice"]++;
            _noteSolvency();
            _noteForeclosures();
        } catch (bytes memory err) {
            _bad("setSelfPrice", err);
        }
    }

    /// @dev Anyone may fund any seat's meter — a gift of rent is a gift.
    function fundRent(uint256 seatSeed, uint256 payerSeed, uint256 amount) external {
        uint256 id = _seat(seatSeed);
        address payer = _actor(payerSeed);
        amount = bound(amount, 1, 200e18);
        _mintTo(payer, amount, 0);
        vm.prank(payer);
        try hook.fundRent(id, amount) {
            calls["fundRent"]++;
            _noteSolvency();
        } catch (bytes memory err) {
            _bad("fundRent", err);
        }
    }

    function withdrawRent(uint256 seatSeed, uint256 amount, bool overshoot) external {
        uint256 id = _seat(seatSeed);
        address who = hook.ownerOf(id);
        (, uint256 esc,,,) = hook.leaseOf(id);
        amount = overshoot ? bound(amount, esc + 1, esc + 1e18 + 1) : bound(amount, 0, esc);
        vm.prank(who);
        try hook.withdrawRent(id, amount) {
            calls["withdrawRent"]++;
            _noteSolvency();
            _noteForeclosures();
        } catch (bytes memory err) {
            _bad("withdrawRent", err);
        }
    }

    /// @dev The permissionless poke. It pays the caller nothing, so anyone may be the caller.
    function settleRent(uint256 seatSeed, uint256 callerSeed) external {
        uint256 id = _seat(seatSeed);
        uint256 rankBefore = hook.rankOfId(id);
        uint256 potBefore = _rentPot();
        uint256[] memory escBefore = _escrowById();

        vm.prank(_actor(callerSeed));
        try hook.settleRent(id) {
            calls["settleRent"]++;
            _noteSolvency();
            // I8a — rent settlement moves money INSIDE the rent pot and may not change its size.
            if (_rentPot() != potBefore) rentConservationViolations++;
            // I8e — and it may only ever move BACKWARD. A settlement that credits a seat ahead of
            // the payer conserves every wei while inverting the mechanism's entire economics; that
            // is the shape of the bug that killed HardcapHook, and no conservation test can see it.
            _checkRentDirection(rankBefore, escBefore);
            _noteForeclosures();
        } catch (bytes memory err) {
            _bad("settleRent", err);
        }
    }

    function claimPending(uint256 actorSeed, uint256 w0, uint256 w1) external {
        address who = _actor(actorSeed);
        (uint256 h0, uint256 h1) = hook.pendingOf(who);
        w0 = bound(w0, 0, h0);
        w1 = bound(w1, 0, h1);
        uint256 b0 = _bal(c0, who);
        uint256 b1 = _bal(c1, who);
        vm.prank(who);
        try hook.claimPending(w0, w1) {
            gOut0 += _bal(c0, who) - b0;
            gOut1 += _bal(c1, who) - b1;
            calls["claimPending"]++;
            _noteSolvency();
        } catch (bytes memory err) {
            _bad("claimPending", err);
        }
    }

    /// @dev Permissionless DMM rebalance. Ledger does not change. Legal reverts: still in range,
    ///      or the destination ticks already have a wing.
    function recenter(uint256 callerSeed) external {
        vm.prank(_actor(callerSeed));
        try hook.recenter() {
            calls["recenter"]++;
            _noteSolvency();
        } catch (bytes memory err) {
            _bad("recenter", err);
        }
    }

    /// @dev Permissionless and credits nobody. It moves float into the position, so it changes no
    ///      seat's ledger and no ghost.
    function sweepFloat(uint256 callerSeed) external {
        vm.prank(_actor(callerSeed));
        try hook.sweepFloatIntoPosition() {
            calls["sweepFloat"]++;
            _noteSolvency();
        } catch (bytes memory err) {
            _bad("sweepFloat", err);
        }
    }

    /// @dev Rent is denominated in SECONDS. Without this the campaign never accrues a bill, never
    ///      forecloses anything, and I8 holds vacuously at zero (PITFALLS 5.54 — before believing a
    ///      path is covered, check that it was ENTERED).
    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 120 days));
        calls["warp"]++;
    }

    /// @dev The authorisation surface, driven by a NON-holder on purpose. Every one of these MUST
    ///      revert; a success is recorded as an unexpected outcome (I7), which is how the campaign
    ///      catches an access-control mutation rather than merely failing to notice it.
    function unauthorised(uint256 seatSeed, uint256 callerSeed, uint256 which) external {
        uint256 id = _seat(seatSeed);
        address holder = hook.ownerOf(id);
        address caller = _actor(callerSeed);
        if (caller == holder) caller = actors[(callerSeed + 1) % actors.length];
        if (caller == holder) return;
        which = bound(which, 0, 4);
        calls["unauthorised"]++;

        if (which == 0) {
            vm.prank(caller);
            try hook.withdraw(id, 1, 0) {
                unexpectedReverts++;
            } catch {}
        } else if (which == 1) {
            vm.prank(caller);
            try hook.setSelfPrice(id, 1) {
                unexpectedReverts++;
            } catch {}
        } else if (which == 2) {
            vm.prank(caller);
            try hook.withdrawRent(id, 1) {
                unexpectedReverts++;
            } catch {}
        } else if (which == 3) {
            vm.prank(caller);
            try hook.addToSeat(id, 1, 0) {
                unexpectedReverts++;
            } catch {}
        } else {
            vm.prank(caller);
            try hook.transfer(caller, id, 1) {
                unexpectedReverts++;
            } catch {}
        }
    }

    // ================================================================================ ghost helpers

    /// @dev I4 — front-first. If rank `j` gave up any of the outgoing token, every rank `i < j`
    ///      that HELD any of it must now hold none. Stated on the contract's own per-rank balances
    ///      across the swap, so it is a property of what happened rather than of what was intended.
    function _checkFrontFirst(bool zeroForOne, uint256[] memory before) internal {
        uint256[] memory after_ = _outgoingByRank(zeroForOne);
        uint256 n = before.length < after_.length ? before.length : after_.length;

        uint256 deepest;
        bool touched;
        for (uint256 r; r < n; r++) {
            if (after_[r] < before[r]) {
                deepest = r;
                touched = true;
            }
        }
        if (!touched) return;
        swapsThatFilled++;

        for (uint256 r; r < deepest; r++) {
            if (before[r] != 0 && after_[r] != 0) frontFirstViolations++;
        }
    }

    /// @dev I8e — rent may only be handed BACKWARD. Compared by RANK read before the settlement,
    ///      because the settlement itself can demote the payer and slide everyone behind it.
    function _checkRentDirection(uint256 payerRank, uint256[] memory escBefore) internal {
        uint256[] memory ranking = hook.ranking();
        for (uint256 r; r < payerRank && r < ranking.length; r++) {
            (, uint256 esc,,,) = hook.leaseOf(ranking[r]);
            // `ranking` may have been permuted by a demotion, so compare BY SEAT ID.
            if (esc > escBefore[ranking[r]]) rentDirectionViolations++;
        }
    }

    /// @dev Indexed by SEAT ID. Ranks move under a demotion; ids never do.
    function _escrowById() internal view returns (uint256[] memory out) {
        uint256 n = hook.seatCount();
        out = new uint256[](n);
        for (uint256 id; id < n; id++) {
            (, uint256 esc,,,) = hook.leaseOf(id);
            out[id] = esc;
        }
    }

    function _outgoingByRank(bool zeroForOne) internal view returns (uint256[] memory out) {
        uint256 n = hook.seatCount();
        out = new uint256[](n);
        for (uint256 r; r < n; r++) {
            (uint256 a0, uint256 a1) = hook.seat(hook.idAtRank(r));
            out[r] = zeroForOne ? a1 : a0;
        }
    }

    function _rentPot() internal view returns (uint256) {
        (uint256 esc, uint256 unalloc) = hook.rentTotals();
        return esc + unalloc;
    }

    /// @dev A seat evacuation pays `p0 + esc` in ONE currency0 transfer, so the ledger half is
    ///      recovered by subtracting the escrow refund — measured as the drop in the rent pot,
    ///      which settlement itself leaves invariant.
    function _afterEvacuation(
        bytes32 tag,
        address from,
        uint256 b0,
        uint256 b1,
        uint256 rentBefore,
        uint256 s0,
        uint256 s1
    ) internal {
        _afterEvacuationWithPrice(tag, from, b0, b1, rentBefore, s0, s1, 0);
    }

    function _afterEvacuationWithPrice(
        bytes32 tag,
        address from,
        uint256 b0,
        uint256 b1,
        uint256 rentBefore,
        uint256 s0,
        uint256 s1,
        uint256 price
    ) internal {
        calls[tag]++;
        if (s0 != 0 || s1 != 0) evacuationsWithCapital++;
        _noteSolvency();
        uint256 rentAfter = _rentPot();
        uint256 refund = rentBefore > rentAfter ? rentBefore - rentAfter : 0;
        uint256 got0 = _bal(c0, from) - b0;
        gOut0 += got0 > refund ? got0 - refund : 0;
        gOut1 += _bal(c1, from) - b1;
        gIn0 += price;
    }

    /// @dev Coverage signal, not an assertion. The founding order is the identity permutation, so
    ///      any deviation means a foreclosure demoted something — i.e. the campaign REACHED the
    ///      path. PITFALLS 5.54: before believing a path is covered, check that it was entered.
    function _noteForeclosures() internal {
        if (hook.orderWord() != _identityOrder()) orderPermuted = 1;
    }

    function _identityOrder() internal view returns (uint256 w) {
        uint256 n = hook.seatCount();
        for (uint256 r; r < n; r++) {
            w |= r << (r * 8);
        }
    }

    /// @dev Record how far the queue's backing is from its face value, after every action that
    ///      could move either. Recorded rather than asserted — an assertion here would be swallowed
    ///      by `fail_on_revert = false`.
    function _noteSolvency() internal {
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 w0, uint256 w1) = hook.pendingTotals();
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 p0, uint256 p1) = _positionValue();
        _note0(t0 + w0, p0 + f0);
        _note1(t1 + w1, p1 + f1);
    }

    function _note0(uint256 owed, uint256 backing) internal {
        if (backing >= owed) {
            if (backing - owed > worstOver0) worstOver0 = backing - owed;
            return;
        }
        uint256 sh = owed - backing;
        if (sh > worstShortAbs0) worstShortAbs0 = sh;
        // Only meaningful above the absolute floor — see `worstShortAbs0`.
        if (sh > ABS_FLOOR && gIn0 != 0) {
            uint256 r = FullMath.mulDiv(sh, 1e9, gIn0);
            if (r > worstShortPpb0) worstShortPpb0 = r;
        }
    }

    function _note1(uint256 owed, uint256 backing) internal {
        if (backing >= owed) {
            if (backing - owed > worstOver1) worstOver1 = backing - owed;
            return;
        }
        uint256 sh = owed - backing;
        if (sh > worstShortAbs1) worstShortAbs1 = sh;
        if (sh > ABS_FLOOR && gIn1 != 0) {
            uint256 r = FullMath.mulDiv(sh, 1e9, gIn1);
            if (r > worstShortPpb1) worstShortPpb1 = r;
        }
    }

    /// @dev Must match `InvariantTest.K`. Below it a shortfall is dust and the ratio is noise.
    uint256 internal constant ABS_FLOOR = 100_000;

    /// @dev What the position would release, PRINCIPAL plus uncollected LP fees, with the price
    ///      CLAMPED into the position's range — `minUsableTick` is strictly inside `MIN_TICK`, so a
    ///      "full-range" position's range really can be left (PITFALLS 5.75).
    function _positionValue() internal view returns (uint256 a0, uint256 a1) {
        uint128 L = hook.positionLiquidity();
        if (L == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        (,, int24 lower, int24 upper) = hook.pool();
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        uint160 p = sqrtP < lo ? lo : (sqrtP > hi ? hi : sqrtP);
        a0 = SqrtPriceMath.getAmount0Delta(p, hi, L, false);
        a1 = SqrtPriceMath.getAmount1Delta(lo, p, L, false);
        (, uint256 il0, uint256 il1) = poolManager.getPositionInfo(key.toId(), address(hook), lower, upper, bytes32(0));
        (uint256 i0, uint256 i1) = poolManager.getFeeGrowthInside(key.toId(), lower, upper);
        unchecked {
            a0 += FullMath.mulDiv(i0 - il0, L, 1 << 128);
            a1 += FullMath.mulDiv(i1 - il1, L, 1 << 128);
        }
    }

    // ============================================================================ revert classifier

    function _bad(bytes32 tag, bytes memory err) internal {
        reverts[tag]++;
        bytes4 sel = bytes4(_unwrap(err));
        if (!_isExpected(sel)) {
            if (unexpectedReverts == 0) {
                firstUnexpectedSelector = sel;
                firstUnexpectedTag = tag;
            }
            unexpectedReverts++;
        }
    }

    /// @dev **THE ALLOW-LIST IS THE POINT.** Each entry is an outcome the mechanism is entitled to
    ///      produce against a bounded actor. Nothing else may revert. Widening this list to make a
    ///      campaign go green is the same sin as widening a tolerance to catch a mutation.
    function _isExpected(bytes4 sel) internal pure returns (bool) {
        return
        // The queue cannot source the swap. A legal outcome and a designed one.
        sel == Allocation.QueueUnderflow.selector
            // Authorisation and seat-shape rules.
            || sel == QueueSeats.NotSeatOwner.selector || sel == QueueSeats.InsufficientPermission.selector
            || sel == QueueSeats.SeatIsIndivisible.selector || sel == QueueSeats.SeatCannotBeBurned.selector
            // Ledger and lease rules.
            || sel == QueueHook.OverEntitlement.selector || sel == QueueHook.NothingDeposited.selector
            || sel == QueueHook.NoSuchSeat.selector || sel == QueueHook.PriceAboveMax.selector
            || sel == QueueHook.CannotBuyOwnSeat.selector || sel == QueueHook.SelfPriceTooLarge.selector
            // v4's own refusals on a degenerate swap: a zero specified amount, and a swap large enough
            // to walk the price out of the usable tick range. Both are the ROUTER refusing, not the
            // hook, and neither is reachable through any hook-controlled input.
            || sel == bytes4(keccak256("SwapAmountCannotBeZero()"))
            || sel == bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"))
            || sel == bytes4(keccak256("InvalidSqrtPrice(uint160)"))
            || sel == bytes4(keccak256("InvalidSqrtPriceLimit(uint160,uint160)"))
            || sel == QueueHook.BandStillInRange.selector || sel == QueueHook.DestinationOccupied.selector
            || sel == QueueHook.OverlappingLiquidity.selector || sel == QueueHook.BandOutOfBounds.selector;
    }

    /// @dev v4 wraps a hook revert in `WrappedError(address,bytes4,bytes,bytes)`; peel to the real
    ///      payload so the classifier sees the mechanism's own selector (LAW 2).
    function _unwrap(bytes memory err) internal pure returns (bytes memory) {
        while (err.length > 4 && bytes4(err) == bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"))) {
            bytes memory body = new bytes(err.length - 4);
            for (uint256 i; i < body.length; i++) {
                body[i] = err[i + 4];
            }
            (,, bytes memory inner,) = abi.decode(body, (address, bytes4, bytes, bytes));
            err = inner;
        }
        return err;
    }

    // =================================================================================== plumbing

    function _seat(uint256 seed) internal view returns (uint256) {
        return bound(seed, 0, hook.seatCount() - 1);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _mintTo(address who, uint256 a0, uint256 a1) internal {
        if (a0 != 0) MockERC20(Currency.unwrap(c0)).mint(who, a0);
        if (a1 != 0) MockERC20(Currency.unwrap(c1)).mint(who, a1);
    }

    function _approveAll(address who) internal {
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(i == 0 ? c0 : c1));
            vm.startPrank(who);
            t.approve(address(hook), type(uint256).max);
            t.approve(address(permit2), type(uint256).max);
            t.approve(address(swapRouter), type(uint256).max);
            permit2.approve(address(t), address(swapRouter), type(uint160).max, type(uint48).max);
            permit2.approve(address(t), address(poolManager), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }
}
