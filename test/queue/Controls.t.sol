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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Each mode changes EXACTLY ONE line of the parent's `_allocate`. The body is otherwise a
///      literal copy, so a control that goes red isolates that line and nothing else.
contract MutantQueueHook is QueueHarness {
    uint8 public constant PRO_RATA = 1;
    uint8 public constant OFF_BY_ONE = 2;
    uint8 public constant FLOOR_ONLY = 3;
    uint8 public constant NO_CURSOR_PULLBACK = 4;

    uint8 public immutable mode;

    constructor(IPoolManager pm, Currency c0_, Currency c1_, uint24 f, int24 sp, uint8 m)
        QueueHarness(pm, c0_, c1_, f, sp)
    {
        mode = m;
    }

    function _allocate(bool outIsOne, uint256 amtIn, uint256 amtOut) internal override {
        uint256 n = q.length;
        uint256 start = outIsOne ? cursor1 : cursor0;

        // N2 — the cursor starts one seat too far in. Silent theft of rank.
        if (mode == OFF_BY_ONE && start == 0) start = 1;

        // N1 — pro-rata: what every concentrated AMM does today, and the thing QUEUE exists not to do.
        if (mode == PRO_RATA) {
            uint256 total;
            for (uint256 i; i < n; i++) {
                total += outIsOne ? q[i].a1 : q[i].a0;
            }
            uint256 rem = amtOut;
            uint256 asg;
            for (uint256 i; i < n; i++) {
                uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
                if (bal == 0) continue;
                bool last = i == n - 1;
                uint256 take = last ? rem : FullMath.mulDiv(amtOut, bal, total);
                uint256 give = last ? amtIn - asg : FullMath.mulDiv(amtIn, bal, total);
                rem -= take;
                asg += give;
                _apply(i, outIsOne, take, give);
            }
            return;
        }

        uint256 remaining = amtOut;
        uint256 assigned;
        uint256 lastIdx;
        bool any;
        for (uint256 i = start; i < n && remaining > 0; i++) {
            uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
            if (bal == 0) continue;
            uint256 take = bal < remaining ? bal : remaining;
            remaining -= take;
            // N3 — the remainder line, deleted. Every share floored.
            uint256 give =
                (remaining == 0 && mode != FLOOR_ONLY) ? amtIn - assigned : FullMath.mulDiv(amtIn, take, amtOut);
            assigned += give;
            _apply(i, outIsOne, take, give);
            lastIdx = i;
            any = true;
        }
        if (remaining != 0) revert Allocation.QueueUnderflow(remaining);

        if (any) {
            uint256 adv = (outIsOne ? q[lastIdx].a1 : q[lastIdx].a0) == 0 ? lastIdx + 1 : lastIdx;
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

    function _apply(uint256 i, bool outIsOne, uint256 take, uint256 give) private {
        if (outIsOne) {
            q[i].a1 -= take;
            q[i].a0 += give;
        } else {
            q[i].a0 -= take;
            q[i].a1 += give;
        }
    }
}

/// @dev N5 — the sole-LP guard, removed.
contract UnguardedQueueHook is QueueHarness {
    constructor(IPoolManager pm, Currency c0_, Currency c1_, uint24 f, int24 sp) QueueHarness(pm, c0_, c1_, f, sp) {}

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

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    function add(PoolKey calldata k, int24 lower, int24 upper, uint128 liq) external {
        key = k;
        tl = lower;
        tu = upper;
        poolManager.unlock(abi.encode(int256(uint256(liq))));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm");
        int256 d = abi.decode(data, (int256));
        (BalanceDelta cd,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: d, salt: bytes32(0)}), ""
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

/// @notice The five mandatory negative controls (PLAN §D.3).
///
/// LAW 2 — a control that reverts for an UNRELATED reason proves nothing, so every one of these
/// asserts the specific failing assertion, not merely that something went red.
contract ControlsTest is QueueFixture {
    uint8 constant PRO_RATA = 1;
    uint8 constant OFF_BY_ONE = 2;
    uint8 constant FLOOR_ONLY = 3;
    uint8 constant NO_CURSOR_PULLBACK = 4;

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
        deployCodeTo("Controls.t.sol:MutantQueueHook", abi.encode(poolManager, c0, c1, FEE, SPACING, mode), a);
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
        (uint256 k0, uint256 k1) = hook.cursors();
        for (uint256 i; i < k0; i++) {
            (uint256 a0,) = hook.seat(i);
            require(a0 == 0, string.concat(tag, ": INVARIANT C cursor0 leads"));
        }
        for (uint256 i; i < k1; i++) {
            (, uint256 a1) = hook.seat(i);
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
        deployCodeTo("Controls.t.sol:UnguardedQueueHook", abi.encode(poolManager, c0, c1, FEE, SPACING), a);
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

    /// @dev The positive half of N5: with the guard IN PLACE the same call must revert, by name.
    function test_N5_positive_guardRefusesTheExternalLp() public {
        address a = address(FLAGS ^ (uint160(0x3006) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", abi.encode(poolManager, c0, c1, FEE, SPACING), a);
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
        assertEq(bytes4(_unwrap(err)), QueueHook.NotSoleLiquidityProvider.selector, "wrong refusal reason");
    }

    /// @dev The positive control. If the UNMUTATED hook cannot pass this harness, the four mutation
    ///      controls above prove nothing at all.
    function test_positiveControl_unmutatedPassesTheSameHarness() public {
        address a = address(FLAGS ^ (uint160(0x3007) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", abi.encode(poolManager, c0, c1, FEE, SPACING), a);
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
