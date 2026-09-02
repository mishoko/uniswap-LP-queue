// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Allocation} from "../../src/queue/libraries/Allocation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Each mode changes EXACTLY ONE line of the parent's `_allocate`. The body is otherwise a
///      literal copy, so a control that goes red isolates that line and nothing else.
contract MutantQueueHook is QueueHarness {
    uint8 public constant PRO_RATA = 1;
    uint8 public constant OFF_BY_ONE = 2;
    uint8 public constant FLOOR_ONLY = 3;
    uint8 public constant NO_CURSOR_PULLBACK = 4;
    /// @dev N6 — the price curve, ignored. Every seat a swap reaches is credited the swap's
    ///      AVERAGE price, which is what this hook did before marginal pricing landed.
    uint8 public constant AVERAGE_PRICE = 5;

    /// @dev **NOT a constructor argument, and not `immutable`, for two reasons that both bit.**
    ///
    ///      One: appending it took the constructor to twelve parameters and Solidity's ABI decoder
    ///      ran out of stack decoding them (`headStart is 1 slot too deep`), with no file or line
    ///      attached.
    ///
    ///      Two, and the one that matters: an extra argument forced this file to write out the
    ///      constructor's shape a SECOND time instead of calling `_ctorArgs`. The note below used
    ///      to explain why that was unavoidable and record that it had already broken once, when
    ///      `bandHalfWidth` was added. It broke again, identically, when the premium was added.
    ///      Two failures from one duplicated list is this project's own rule about a fact living in
    ///      two places, applied to itself — so the list is gone and this deploys through the single
    ///      shared builder like every other suite.
    ///
    ///      Zero is the unset sentinel and `_allocate` refuses to run on it, so a control whose mode
    ///      was never set fails LOUDLY rather than quietly behaving like production and passing.
    uint8 public mode;

    error ModeUnset();
    error ModeAlreadySet();

    constructor(
        IPoolManager pm,
        Currency c0_,
        Currency c1_,
        uint24 f,
        int24 sp,
        int24 bhw,
        address[] memory roster,
        uint256 rb,
        uint256 rp,
        uint256 fw,
        uint256 pb
    ) QueueHarness(pm, c0_, c1_, f, sp, bhw, roster, rb, rp, fw, pb) {}

    function setMode(uint8 m) external {
        if (mode != 0) revert ModeAlreadySet();
        if (m == 0) revert ModeUnset();
        mode = m;
    }

    /// @dev The loops below walk RANKS and resolve each one to a seat exactly as production does.
    ///      These controls never foreclose, so rank and seat id are the same number throughout — but
    ///      a control is only worth anything if it differs from production in ONE place, and leaving
    ///      the indirection out would be a second difference waiting to matter.
    function _allocate(bool outIsOne, uint256 amtIn, uint256 amtOut) internal override {
        // A control that silently ran production's allocator would be a green test proving nothing.
        if (mode == 0) revert ModeUnset();
        uint256 n = q.length;
        uint256 start = outIsOne ? cursor1 : cursor0;

        // N2 — the cursor starts one seat too far in. Silent theft of rank.
        if (mode == OFF_BY_ONE && start == 0) start = 1;

        // N1 — pro-rata: what every concentrated AMM does today, and the thing QUEUE exists not to do.
        if (mode == PRO_RATA) {
            uint256 total;
            for (uint256 i; i < n; i++) {
                total += outIsOne ? q[idAtRank(i)].a1 : q[idAtRank(i)].a0;
            }
            uint256 rem = amtOut;
            uint256 asg;
            for (uint256 i; i < n; i++) {
                uint256 bal = outIsOne ? q[idAtRank(i)].a1 : q[idAtRank(i)].a0;
                if (bal == 0) continue;
                bool last = i == n - 1;
                uint256 take = last ? rem : FullMath.mulDiv(amtOut, bal, total);
                uint256 give = last ? amtIn - asg : FullMath.mulDiv(amtIn, bal, total);
                rem -= take;
                asg += give;
                _apply(idAtRank(i), outIsOne, take, give);
            }
            return;
        }

        uint256 remaining = amtOut;
        uint256 assigned;
        uint256 lastIdx = type(uint256).max; // also the "nothing was touched" sentinel
        // The PRICE CURVE, built exactly as production builds it. A control that priced at the
        // swap average while production prices by segment would differ from production in TWO
        // places, and would then die of the difference it was not testing — which is precisely
        // what happened when marginal pricing landed, and is what LAW 2 exists to catch.
        Curve memory cv;
        for (uint256 i = start; i < n && remaining > 0; i++) {
            uint256 bal = outIsOne ? q[idAtRank(i)].a1 : q[idAtRank(i)].a0;
            if (bal == 0) continue;
            uint256 take = bal < remaining ? bal : remaining;
            uint256 give = _mutGive(cv, outIsOne, amtIn, amtOut, remaining, bal, assigned);
            remaining -= take;
            assigned += give;
            _apply(idAtRank(i), outIsOne, take, give);
            lastIdx = i;
        }
        bool any = lastIdx != type(uint256).max;
        if (remaining != 0) revert Allocation.QueueUnderflow(remaining);

        if (any) {
            uint256 lastId = idAtRank(lastIdx);
            uint256 adv = (outIsOne ? q[lastId].a1 : q[lastId].a0) == 0 ? lastIdx + 1 : lastIdx;
            if (outIsOne) {
                cursor1 = adv;
                // N4 — the pull-back, deleted. cursorY leads and skips a funded seat.
                if (mode != NO_CURSOR_PULLBACK && start < cursor0) cursor0 = start;
            } else {
                cursor0 = adv;
                if (mode != NO_CURSOR_PULLBACK && start < cursor1) cursor1 = start;
            }
        }
    }

    /// @dev One seat's credit. Split out only because `_allocate` is at the stack limit without
    ///      `via_ir`; the logic is production's, with N3 as the single deviation.
    function _mutGive(
        Curve memory cv,
        bool outIsOne,
        uint256 amtIn,
        uint256 amtOut,
        uint256 remaining,
        uint256 bal,
        uint256 assigned
    ) private view returns (uint256) {
        uint256 take = bal < remaining ? bal : remaining;
        if (remaining - take == 0) {
            // N3 — the remainder line, deleted. The last seat gets a floored share like every
            // other, so the parts no longer sum to the whole.
            return mode == FLOOR_ONLY ? FullMath.mulDiv(amtIn, take, amtOut) : amtIn - assigned;
        }
        // N6 — never build the curve, so every seat falls through to the swap average.
        if (cv.total == 0 && mode != AVERAGE_PRICE) _initCurve(cv, outIsOne, amtOut);
        if (cv.total == 0) return FullMath.mulDiv(amtIn, take, amtOut);
        uint256 g = FullMath.mulDiv(amtIn, _segmentIn(cv, outIsOne, amtOut - remaining + bal), cv.total);
        if (g < assigned) g = assigned;
        if (g > amtIn) g = amtIn;
        return g - assigned;
    }

    /// @dev The mutants override `_allocate` wholesale, so they also take on production's duty to
    ///      keep `standing0`/`standing1` in step with the balances. Skipping it would make every
    ///      control differ from production in TWO places — the mutation, and a broken denominator —
    ///      and a control that dies of the difference it is not testing proves nothing (LAW 2).
    function _apply(uint256 i, bool outIsOne, uint256 take, uint256 give) private {
        if (outIsOne) {
            q[i].a1 -= _u128(take);
            q[i].a0 = _u128(uint256(q[i].a0) + give);
            standing1 -= take;
            standing0 += give;
        } else {
            q[i].a0 -= _u128(take);
            q[i].a1 = _u128(uint256(q[i].a1) + give);
            standing0 -= take;
            standing1 += give;
        }
    }
}

/// @dev N5 — the sole-LP guard, removed.
contract UnguardedQueueHook is QueueHarness {
    constructor(
        IPoolManager pm,
        Currency c0_,
        Currency c1_,
        uint24 f,
        int24 sp,
        int24 bhw,
        address[] memory roster,
        uint256 rb,
        uint256 rp,
        uint256 fw,
        uint256 pb
    ) QueueHarness(pm, c0_, c1_, f, sp, bhw, roster, rb, rp, fw, pb) {}

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return BaseHook.beforeAddLiquidity.selector; // guard gone
    }
}

/// @dev A genuine outside liquidity provider, to exercise N5.
contract ExternalLP is IUnlockCallback {
    IPoolManager public immutable poolManager;
    PoolKey internal key;
    int24 internal tl;
    int24 internal tu;
    bytes32 internal salt;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    function add(PoolKey calldata k, int24 lower, int24 upper, uint128 liq) external {
        addWithSalt(k, lower, upper, liq, bytes32(0));
    }

    /// @dev Same ticks, different salt — Uniswap keys positions by (owner, ticks, salt).
    ///      The overlap guard is tick-based; a salt must not be a free lane.
    function addWithSalt(PoolKey calldata k, int24 lower, int24 upper, uint128 liq, bytes32 salt_) public {
        key = k;
        tl = lower;
        tu = upper;
        salt = salt_;
        poolManager.unlock(abi.encode(int256(uint256(liq))));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm");
        int256 d = abi.decode(data, (int256));
        (BalanceDelta cd,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: d, salt: salt}), ""
        );
        _resolve(key.currency0, cd.amount0());
        _resolve(key.currency1, cd.amount1());
        return "";
    }

    function _resolve(Currency c, int128 amt) internal {
        if (amt < 0) {
            poolManager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(poolManager), uint128(-amt));
            poolManager.settle();
        } else if (amt > 0) {
            poolManager.take(c, address(this), uint128(amt));
        }
    }
}

/// @dev A swap with an explicit sqrtPriceLimit, so a test can rest just outside the band
///      instead of slamming to MIN/MAX through empty ticks.
contract LimitSwapper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    function swapTo(PoolKey calldata k, bool zfo, uint256 amountIn, uint160 limit) external {
        poolManager.unlock(abi.encode(k, zfo, amountIn, limit));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm");
        (PoolKey memory k, bool zfo, uint256 amountIn, uint160 limit) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));
        BalanceDelta d = poolManager.swap(
            k, SwapParams({zeroForOne: zfo, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        _resolve(k.currency0, d.amount0());
        _resolve(k.currency1, d.amount1());
        return "";
    }

    function _resolve(Currency c, int128 amt) internal {
        if (amt < 0) {
            poolManager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(poolManager), uint128(-amt));
            poolManager.settle();
        } else if (amt > 0) {
            poolManager.take(c, address(this), uint128(amt));
        }
    }
}

/// @notice The five mandatory negative controls (PLAN §D.3).
///
/// LAW 2 — a control that reverts for an UNRELATED reason proves nothing, so every one of these
/// asserts the specific failing assertion, not merely that something went red.
contract ControlsTest is QueueFixture {
    uint8 constant PRO_RATA = 1;
    uint8 constant OFF_BY_ONE = 2;
    uint8 constant FLOOR_ONLY = 3;
    uint8 constant NO_CURSOR_PULLBACK = 4;
    uint8 constant AVERAGE_PRICE = 5;

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
    }

    function _bps() internal pure returns (uint256[] memory bps) {
        bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
    }

    function _deployMutant(uint8 mode, uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("Controls.t.sol:MutantQueueHook", _ctorArgs(_syntheticRoster(3)), a);
        MutantQueueHook(a).setMode(mode);
        hook = QueueHarness(a);
        _fundHook(a);
    }

    // ------------------------------------------------------------------------- the shared scenario

    /// @dev External so the controls can capture the revert. Identical body for every mode, so the
    ///      controls run against identical state and only the mutated line differs.
    function harness(uint8 mode, uint160 nonce) external {
        _deployMutant(mode, nonce);
        _open(_bps());
        uint256 s0 = expT0;
        uint256 s1 = expT1;

        // SWAP 1 — head-only. A single-seat fill has NO remainder to drop, which is exactly why N3
        // must survive here and die at swap 2.
        _swap(true, s0 / 500);
        _checkR("swap1");

        // SWAP 2 — sweeping. Three seats, three floored shares, the remainder line load-bearing.
        _swap(true, (s0 * 16) / 100);
        _checkR("swap2");

        // SWAP 3/4 — out, then back, then out again: the sequence that exposes a LEADING cursor.
        _swap(false, s1 / 50);
        _checkR("swap3");
        _swap(true, s0 / 200);
        _checkR("swap4");
    }

    /// @dev `require`-based twin of `_check`, so the failure surfaces as a plain string a control
    ///      can compare EXACTLY. Same three claims, same order.
    function _checkR(string memory tag) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        require(t0 == expT0, string.concat(tag, ": token0 conservation"));
        require(t1 == expT1, string.concat(tag, ": token1 conservation"));
        for (uint256 i; i < ref0.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            require(a0 == ref0[i], string.concat(tag, ": seat a0"));
            require(a1 == ref1[i], string.concat(tag, ": seat a1"));
        }
        // THE CURSORS ARE RANKS. `seat()` is indexed by SEAT ID. Reading `seat(i)` here was right
        // only while the two were the same number, and the mutant `_allocate` twenty lines above
        // carries the comment saying exactly that about ITSELF — the indirection was put in there
        // and left out here, which is this project's most repeated defect shape (PITFALLS 5.37,
        // 5.50, 5.52 twice, 5.105) landing inside the instrument rather than the mechanism.
        // `QueueFixture._checkInvariantC` already resolves rank -> id; this is its twin and now
        // agrees with it. Latent today because these controls never foreclose; it would have gone
        // green against a leading cursor the moment anything permuted `order`.
        (uint256 k0, uint256 k1) = hook.cursors();
        for (uint256 i; i < k0; i++) {
            (uint256 a0,) = hook.seat(hook.idAtRank(i));
            require(a0 == 0, string.concat(tag, ": INVARIANT C cursor0 leads"));
        }
        for (uint256 i; i < k1; i++) {
            (, uint256 a1) = hook.seat(hook.idAtRank(i));
            require(a1 == 0, string.concat(tag, ": INVARIANT C cursor1 leads"));
        }
    }

    function _expectRed(uint8 mode, uint160 nonce, string memory what, string memory wantReason) internal {
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.harness, (mode, nonce)));
        assertFalse(ok, what);
        string memory got = _reason(_unwrap(err));
        emit log_named_string("   control reverted with", got);
        assertEq(got, wantReason, "control went red for the WRONG reason");
    }

    function _reason(bytes memory err) internal pure returns (string memory) {
        if (err.length < 68) return "<non-string revert>";
        assembly {
            err := add(err, 0x04)
        }
        return abi.decode(err, (string));
    }

    // ---------------------------------------------------------------------------- the five controls

    function test_N1_proRataGoesRed() public {
        // Dies on seat 0's token0 leg: pro-rata credits the incoming token to all three seats, so the
        // FIRST composition check in `_checkR` that diverges is seat 0's a0.
        _expectRed(PRO_RATA, 0x3001, "PRO-RATA passed the front-first assertions", "swap1: seat a0");
    }

    function test_N2_offByOneCursorGoesRed() public {
        _expectRed(OFF_BY_ONE, 0x3002, "a cursor starting at seat 1 passed", "swap1: seat a0");
    }

    /// @dev THE SHARPEST RESULT IN THE PROJECT: this control must SURVIVE swap 1 and die at swap 2.
    ///      A single-seat fill takes the whole of `amtOut`, so its floored share is a fraction of
    ///      exactly one and loses nothing. If your control dies at swap 1, your fixture is filling
    ///      one seat and you are not testing the remainder line at all.
    function test_N3_flooredSharesGoesRed_atSwap2NotSwap1() public {
        _expectRed(
            FLOOR_ONLY, 0x3003, "dropping the rounding remainder passed conservation", "swap2: token0 conservation"
        );
    }

    function test_N4_missingCursorPullbackGoesRed() public {
        // It dies at SWAP 3, one swap EARLIER than expected, and on INVARIANT C rather than on
        // composition. That is the better outcome and it is worth understanding: swap 3 is the
        // reverse leg, so it credits token1 to seats from index 0 upward. Without the pull-back,
        // cursor1 is still parked where swap 2 left it and now LEADS funded seats. The invariant
        // states exactly that, so it fires before the composition drift becomes visible at swap 4.
        _expectRed(
            NO_CURSOR_PULLBACK,
            0x3004,
            "a LEADING cursor passed an out-back-out sequence",
            "swap3: INVARIANT C cursor1 leads"
        );
    }

    /// @dev **N4b — THE SAME MUTANT, POINTED AT INVARIANT W, WHICH IS THE PROPERTY PITFALLS 5.164
    ///      ASKED TO HAVE WRITTEN DOWN.**
    ///
    ///      5.164's hazard is real: `_syncSeat` credits a seat and updates NO cursor, so a credit
    ///      could in principle land outside every reachable window. Its recorded *reason* for that
    ///      being safe is stale — it argued the seat is "weighted zero in the accrual", which held
    ///      only while the premium was weighted by BALANCE. `_claims` weights by `s.liquidity`
    ///      today (`QueueHook.sol:1356`) and a drained seat still carries weight. The conclusion
    ///      survives for a different reason: **at least one cursor is always 0**, so every fill
    ///      walks from rank 0 in one direction and re-syncs everything below the other cursor.
    ///      `QueueFixture._checkInvariantW` carries the induction.
    ///
    ///      **THIS TEST EXISTS BECAUSE AN INVARIANT NOBODY HAS SEEN FAIL IS NOT AN INVARIANT
    ///      (LAW 5).** It asserts the NEGATION against the mutant — both cursors strictly positive
    ///      — so it is a claim that can be wrong rather than a restatement of the code. If a future
    ///      change makes the pull-back unnecessary this test goes red and that is the correct
    ///      outcome: it means W is no longer maintained by the line C's control is aimed at, and
    ///      the two need separate controls (5.167 — re-arm, never relax).
    ///
    ///      It is NOT claimed that W detects anything C does not. Against this mutant C fires
    ///      first, at the same swap. W's job is to be the tripwire for a change C would survive —
    ///      a two-ended book or a reversed walk, where both cursors are non-zero by design and a
    ///      premium credit can strand while C still holds locally.
    function test_N4b_missingPullbackAlsoBreaksInvariantW() public {
        _deployMutant(NO_CURSOR_PULLBACK, 0x3005);
        _open(_bps());

        // Swaps 1 and 2 are both zeroForOne. They advance cursor1 only, and cursor0 has not yet had
        // anything to be pulled back FROM, so the mutant is still indistinguishable here. Asserting
        // it keeps this test honest about WHERE the divergence is.
        _swap(true, expT0 / 500);
        _checkInvariantW("N4b swap1");
        _swap(true, (expT0 * 16) / 100);
        _checkInvariantW("N4b swap2");

        (uint256 before0, uint256 before1) = hook.cursors();
        assertEq(before0, 0, "N4b: cursor0 should still be parked at the front before the reverse leg");
        assertGt(before1, 0, "N4b: nothing happened -- cursor1 never advanced, so this test proves nothing");

        // SWAP 3 — the reverse leg. Production pulls cursor1 back to `start` (which is cursor0 == 0)
        // and the book stays front-anchored. The mutant leaves cursor1 parked, raises cursor0, and
        // now BOTH cursors lead: there is no direction left that walks from rank 0.
        _swap(false, expT1 / 5);
        (uint256 k0, uint256 k1) = hook.cursors();
        assertGt(k0, 0, "N4b: cursor0 did not advance -- the reverse leg filled nothing");
        assertGt(k1, 0, "N4b: INVARIANT W did NOT break -- the pull-back is no longer what maintains it");
    }

    /// @dev The positive half of N4b. Same scenario, same swaps, production `_allocate`. Without
    ///      this, N4b's `assertGt` pair would look like a property of the SCENARIO rather than of
    ///      the mutated line.
    function test_N4b_positive_productionKeepsAWalkAtTheFront() public {
        _deployHook(0x3006, 3);
        _open(_bps());

        _swap(true, expT0 / 500);
        _checkInvariantW("N4b+ swap1");
        _swap(true, (expT0 * 16) / 100);
        _checkInvariantW("N4b+ swap2");

        _swap(false, expT1 / 5);
        (uint256 k0, uint256 k1) = hook.cursors();
        _checkInvariantW("N4b+ swap3");
        assertGt(k0, 0, "N4b+: cursor0 did not advance -- this is not the same scenario N4b runs");
        assertEq(k1, 0, "N4b+: production failed to pull cursor1 back to the front");
    }

    /// @dev **N6 — THE HEAD'S FREE LANE, RESTORED, AND THE SUITE MUST NOTICE.**
    ///
    ///      This is the control for the mechanism change itself. The mutant credits every seat a
    ///      swap reaches with the swap's AVERAGE price — exactly what this hook shipped before —
    ///      instead of the price segment each seat actually absorbed.
    ///
    ///      It matters that this is a CONTROL and not just a property test. Marginal pricing was
    ///      added to `_allocate` AND to the fixture's independent witness in the same session; if
    ///      the witness had been the only thing checking it, the two could have been changed to
    ///      agree with each other while both being wrong, and 199 green tests would have said
    ///      nothing at all. This asserts the suite can still tell the difference.
    ///
    ///      It dies at swap 2 on the seat ledger, not on conservation, and that is correct: average
    ///      pricing conserves perfectly — the parts still sum to the whole — it just hands the
    ///      wrong seat the money. A one-wei misallocation is invisible in the aggregate and only
    ///      shows up seat by seat, which is the whole reason the witness compares per seat
    ///      (PITFALLS 5.29).
    function test_N6_averagePricingGoesRed() public {
        _expectRed(
            AVERAGE_PRICE,
            0x3006,
            "pricing every seat at the swap average passed the seat-by-seat witness",
            "swap2: seat a0"
        );
    }

    /// @dev N5 — the guard that makes the hook the sole LP, i.e. the premise of every other number
    ///      in this project. §D.3 calls it "the one people skip".
    ///
    ///      NOTE A DIVERGENCE FROM PLAN §D.3, which predicted this fails "conservation". It does
    ///      NOT, and the reason is worth writing down: the fixture derives expected totals from
    ///      PoolManager's balance movements, which cover the WHOLE swap — and the hook credits the
    ///      queue that same whole swap. Both sides move together, so the LEDGER still ties out. What
    ///      actually breaks is SOLVENCY: the outside LP takes a pro-rata share of every fill, so the
    ///      hook's own position can no longer cover the ledger it is writing. That is LAW 3's second
    ///      corollary again — ledger conservation and position redeemability are different claims.
    function test_N5_externalLpBreaksSolvency() public {
        address a = address(FLAGS ^ (uint160(0x3005) << 144));
        deployCodeTo("Controls.t.sol:UnguardedQueueHook", _ctorArgs(_syntheticRoster(3)), a);
        hook = QueueHarness(a);
        _fundHook(a);
        _open(_bps());

        ExternalLP lp = new ExternalLP(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(lp), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(lp), 1e30);

        // Sanity: the guard really is gone. Under the real hook this call reverts.
        lp.add(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ);

        _swap(true, expT0 / 20);
        _check("N5 ledger still ties out"); // it does — that is the point of the note above

        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 g0, uint256 g1) = hook.redeemAll();
        assertTrue(
            t0 > g0 + 1e15 || t1 > g1 + 1e15,
            "an outside LP diluted the position but the hook stayed solvent: the guard is not load-bearing"
        );
    }

    /// @dev The positive half of N5: overlapping the band (here: full-range on a full-range
    ///      fixture) must revert, by name. Disjoint wings are a different test (`Wings.t.sol`).
    function test_N5_positive_guardRefusesTheExternalLp() public {
        address a = address(FLAGS ^ (uint160(0x3006) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(_syntheticRoster(3)), a);
        hook = QueueHarness(a);
        _fundHook(a);
        _open(_bps());

        ExternalLP lp = new ExternalLP(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(lp), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(lp), 1e30);

        (bool ok, bytes memory err) = address(lp)
            .call(
                abi.encodeCall(
                    ExternalLP.add, (k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ)
                )
            );
        assertFalse(ok, "an external LP was allowed to add liquidity");
        assertEq(bytes4(_unwrap(err)), QueueHook.OverlappingLiquidity.selector, "wrong refusal reason");
    }

    /// @dev The positive control. If the UNMUTATED hook cannot pass this harness, the four mutation
    ///      controls above prove nothing at all.
    function test_positiveControl_unmutatedPassesTheSameHarness() public {
        address a = address(FLAGS ^ (uint160(0x3007) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(_syntheticRoster(3)), a);
        hook = QueueHarness(a);
        _fundHook(a);
        _open(_bps());
        uint256 s0 = expT0;
        uint256 s1 = expT1;
        _swap(true, s0 / 500);
        _checkR("swap1");
        _swap(true, (s0 * 16) / 100);
        _checkR("swap2");
        _swap(false, s1 / 50);
        _checkR("swap3");
        _swap(true, s0 / 200);
        _checkR("swap4");
    }
}
