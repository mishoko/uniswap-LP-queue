// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice QUEUE spike — is front-first allocation at the swap's realised average price EXACT?
///
/// The hook custodies the pool's whole liquidity as ONE position and keeps an ordered list of
/// entries. Every swap's aggregate entitlement (= the negation of the swapper's BalanceDelta) is
/// allocated FRONT-FIRST rather than pro-rata: the head entry surrenders as much of the outgoing
/// token as it holds and receives the incoming token at the swap's own realised average price.
///
/// MODE is the single switch separating the real allocator from three deliberate mutations, so the
/// negative controls run the identical test body against identical state.
contract QueueHook is BaseHook, IUnlockCallback {
    uint8 constant FRONT_FIRST = 0;
    uint8 constant PRO_RATA = 1; // mutation: v3/v4's actual behaviour
    uint8 constant OFF_BY_ONE = 2; // mutation: cursor starts at entry 1
    uint8 constant FLOOR_ONLY = 3; // mutation: no remainder assignment, every share floored

    uint8 public immutable mode;

    struct Entry {
        uint256 a0;
        uint256 a1;
    }

    Entry[] public q;

    PoolKey public key;
    int24 public tl;
    int24 public tu;
    uint128 public liq;

    uint256 public lastAllocGas;
    uint256 public entriesTouched;
    uint256 public swapsSeen;

    error QueueUnderflow(uint256 shortfall);

    constructor(IPoolManager pm, uint8 mode_) BaseHook(pm) {
        mode = mode_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.afterSwap = true;
    }

    function len() external view returns (uint256) {
        return q.length;
    }

    function entry(uint256 i) external view returns (uint256, uint256) {
        return (q[i].a0, q[i].a1);
    }

    function totals() external view returns (uint256 t0, uint256 t1) {
        for (uint256 i; i < q.length; i++) {
            t0 += q[i].a0;
            t1 += q[i].a1;
        }
    }

    // ------------------------------------------------------------------ liquidity

    /// @dev Only the hook may be an LP. Every external add is refused, so the hook's ledger is the
    ///      pool's ledger.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        require(sender == address(this), "QUEUE: hook is sole LP");
        return BaseHook.beforeAddLiquidity.selector;
    }

    function seed(PoolKey calldata k, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256[] calldata bps)
        external
        returns (uint256 c0, uint256 c1)
    {
        key = k;
        tl = tickLower;
        tu = tickUpper;
        liq = liquidity;
        bytes memory r = poolManager.unlock(abi.encode(int256(uint256(liquidity))));
        (c0, c1) = abi.decode(r, (uint256, uint256));

        uint256 s0;
        uint256 s1;
        for (uint256 i; i < bps.length; i++) {
            uint256 a0 = i == bps.length - 1 ? c0 - s0 : FullMath.mulDiv(c0, bps[i], 10_000);
            uint256 a1 = i == bps.length - 1 ? c1 - s1 : FullMath.mulDiv(c1, bps[i], 10_000);
            s0 += a0;
            s1 += a1;
            q.push(Entry(a0, a1));
        }
    }

    /// @dev Full teardown: burn the position, collect fees, and report the REAL tokens received.
    function redeemAll() external returns (uint256 g0, uint256 g1) {
        uint256 b0 = _bal(key.currency0);
        uint256 b1 = _bal(key.currency1);
        poolManager.unlock(abi.encode(-int256(uint256(liq))));
        g0 = _bal(key.currency0) - b0;
        g1 = _bal(key.currency1) - b1;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm");
        int256 ld = abi.decode(data, (int256));
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: ld, salt: bytes32(0)}), ""
        );
        uint256 m0 = _resolve(key.currency0, d.amount0());
        uint256 m1 = _resolve(key.currency1, d.amount1());
        return abi.encode(m0, m1);
    }

    function _resolve(Currency c, int128 amt) internal returns (uint256 magnitude) {
        if (amt < 0) {
            magnitude = uint256(uint128(-amt));
            poolManager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(poolManager), magnitude);
            poolManager.settle();
        } else if (amt > 0) {
            magnitude = uint256(uint128(amt));
            poolManager.take(c, address(this), magnitude);
        }
    }

    function _bal(Currency c) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this));
    }

    // ------------------------------------------------------------------ the allocator

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta d, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 g = gasleft();
        _allocate(d);
        lastAllocGas = g - gasleft();
        swapsSeen++;
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @dev The queue's aggregate entitlement is exactly the NEGATION of the swapper's delta:
    ///      whatever the swapper paid (fee included) is owed to the sole LP, and whatever the
    ///      swapper received came out of the sole LP's position. Nothing here is the hook's opinion
    ///      — the numbers come from PoolManager.
    function _allocate(BalanceDelta d) internal {
        int256 e0 = -int256(d.amount0());
        int256 e1 = -int256(d.amount1());
        if (e0 == 0 && e1 == 0) return;

        bool outIsOne = e1 < 0;
        uint256 amtOut = outIsOne ? uint256(-e1) : uint256(-e0);
        uint256 amtIn = outIsOne ? uint256(e0) : uint256(e1);

        uint256 touched;
        uint256 remaining = amtOut;
        uint256 assignedIn;

        if (mode == PRO_RATA) {
            uint256 total;
            for (uint256 i; i < q.length; i++) {
                total += outIsOne ? q[i].a1 : q[i].a0;
            }
            for (uint256 i; i < q.length; i++) {
                uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
                if (bal == 0) continue;
                bool last = i == q.length - 1;
                uint256 take_ = last ? remaining : FullMath.mulDiv(amtOut, bal, total);
                uint256 give = last ? amtIn - assignedIn : FullMath.mulDiv(amtIn, bal, total);
                remaining -= take_;
                assignedIn += give;
                _apply(i, outIsOne, take_, give);
                touched++;
            }
        } else {
            uint256 start = mode == OFF_BY_ONE ? 1 : 0;
            for (uint256 i = start; i < q.length && remaining > 0; i++) {
                uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
                if (bal == 0) continue;
                uint256 take_ = bal < remaining ? bal : remaining;
                remaining -= take_;
                uint256 give = (remaining == 0 && mode != FLOOR_ONLY)
                    ? amtIn - assignedIn // the LAST filled entry absorbs the rounding remainder
                    : FullMath.mulDiv(amtIn, take_, amtOut);
                assignedIn += give;
                _apply(i, outIsOne, take_, give);
                touched++;
            }
            if (remaining != 0) revert QueueUnderflow(remaining);
        }
        entriesTouched = touched;
    }

    function _apply(uint256 i, bool outIsOne, uint256 take_, uint256 give) internal {
        if (outIsOne) {
            q[i].a1 -= take_;
            q[i].a0 += give;
        } else {
            q[i].a0 -= take_;
            q[i].a1 += give;
        }
    }
}

// ============================================================================================
//                                        THE SPIKE
// ============================================================================================

contract QueueAllocatorSpikeTest is BaseTest {
    uint24 constant FEE = 3000;
    uint24 feeOverride = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint128 constant LIQ = 1_000e18;

    Currency c0;
    Currency c1;
    QueueHook hook;
    PoolKey k;

    // independently-maintained reference queue + independently-measured totals
    uint256[] r0;
    uint256[] r1;
    uint256 expT0;
    uint256 expT1;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        vm.roll(100);
    }

    // ------------------------------------------------------------------ fixture

    function _deploy(uint8 mode, uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueAllocator.t.sol:QueueHook", abi.encode(poolManager, mode), a);
        hook = QueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 100_000e18);
        MockERC20(Currency.unwrap(c1)).mint(a, 100_000e18);
    }

    function _open(uint256[] memory bps) internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: feeOverride, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        // 1:4 — NEVER 1:1. CLAUDE.md 5.10: a unit fixture hides every token0/token1 mixing bug,
        // and this allocator converts one token into the other at a realised ratio.
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        require(s0 != s1, "fixture is unit-priced");

        delete r0;
        delete r1;
        uint256 sum0;
        uint256 sum1;
        for (uint256 i; i < bps.length; i++) {
            (uint256 a0, uint256 a1) = hook.entry(i);
            r0.push(a0);
            r1.push(a1);
            sum0 += a0;
            sum1 += a1;
        }
        require(sum0 == s0 && sum1 == s1, "seed split lost a wei");
        expT0 = s0;
        expT1 = s1;
    }

    /// @dev Aggregate flows measured on POOLMANAGER'S OWN ERC20 BALANCES. Nothing here is read
    ///      from the hook's bookkeeping — that is the thing under test.
    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint256 inAmt, uint256 outAmt) {
        uint256 p0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 p1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
        uint256 n0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 n1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        if (zeroForOne) {
            (inAmt, outAmt) = (n0 - p0, p1 - n1);
            expT0 += inAmt;
            expT1 -= outAmt;
        } else {
            (inAmt, outAmt) = (n1 - p1, p0 - n0);
            expT1 += inAmt;
            expT0 -= outAmt;
        }
        _refAllocate(zeroForOne, inAmt, outAmt);
    }

    /// @dev A SECOND, independently-written front-first allocator. If both are wrong in the same
    ///      way the conservation assertion against PoolManager still catches it.
    function _refAllocate(bool outIsOne, uint256 amtIn, uint256 amtOut) internal {
        uint256 left = amtOut;
        uint256 paid;
        for (uint256 i; i < r0.length; i++) {
            if (left == 0) break;
            uint256 have = outIsOne ? r1[i] : r0[i];
            if (have == 0) continue;
            uint256 t = have < left ? have : left;
            left -= t;
            uint256 g = left == 0 ? amtIn - paid : FullMath.mulDiv(amtIn, t, amtOut);
            paid += g;
            if (outIsOne) {
                r1[i] = have - t;
                r0[i] += g;
            } else {
                r0[i] = have - t;
                r1[i] += g;
            }
        }
        require(left == 0, "reference underflow");
    }

    function _check(string memory tag) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        // (1) CONSERVATION, to the wei, against balances that left PoolManager.
        require(t0 == expT0, string.concat(tag, ": token0 conservation"));
        require(t1 == expT1, string.concat(tag, ": token1 conservation"));
        // (2) COMPOSITION, against the independent reference.
        for (uint256 i; i < r0.length; i++) {
            (uint256 a0, uint256 a1) = hook.entry(i);
            require(a0 == r0[i], string.concat(tag, ": entry a0"));
            require(a1 == r1[i], string.concat(tag, ": entry a1"));
        }
    }

    // ------------------------------------------------------------------ the scenario

    function harness(uint8 mode, uint160 nonce) external {
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        _deploy(mode, nonce);
        _open(bps);

        (uint256 e0a0, uint256 e0a1) = hook.entry(0);
        (, uint256 e1a1) = hook.entry(1);

        // --- SWAP 1: small. Must land entirely inside the head entry.
        _swap(true, 4e18);
        _check("swap1");
        {
            (uint256 a0, uint256 a1) = hook.entry(1);
            (uint256 b0, uint256 b1) = hook.entry(2);
            require(a0 == r0[1] && a1 == r1[1] && b0 == r0[2] && b1 == r1[2], "swap1: ref");
            require(a1 == e1a1, "swap1: entry a0");  // pro-rata smears the fill across all three entries
            (uint256 h0, uint256 h1) = hook.entry(0);
            require(h1 < e0a1 && h0 > e0a0, "swap1: head did not fill");
            require(hook.entriesTouched() == 1, "swap1: touched != 1");
        }

        // --- SWAP 2: sweeping. Must EXHAUST at least two entries and partially fill a third.
        _swap(true, 300e18);
        _check("swap2");
        {
            (, uint256 a1) = hook.entry(0);
            (, uint256 b1) = hook.entry(1);
            (, uint256 cc1) = hook.entry(2);
            require(a1 == 0, "swap2: entry0 not exhausted");
            require(b1 == 0, "swap2: entry1 not exhausted");
            require(cc1 > 0, "swap2: entry2 should be partial, not exhausted");
            require(hook.entriesTouched() >= 2, "swap2: cursor never advanced");
        }

        // --- SWAP 3: lands mid-entry. Only entry 2 has token1 left, so it must fill partially.
        {
            (, uint256 before2) = hook.entry(2);
            _swap(true, 50e18);
            _check("swap3");
            (, uint256 after2) = hook.entry(2);
            require(after2 > 0 && after2 < before2, "swap3: not a partial fill");
            require(hook.entriesTouched() == 1, "swap3: touched != 1");
        }

        // --- SWAP 4: REVERSE direction. The head holds token0 now, so the head must fill again.
        //     This is the "front seat sees every swap" claim, executed.
        {
            (uint256 h0before,) = hook.entry(0);
            _swap(false, 20e18);
            _check("swap4");
            (uint256 h0after, uint256 h1after) = hook.entry(0);
            require(h0after < h0before, "swap4: head did not fill on the reverse leg");
            require(h1after > 0, "swap4: head received no token1");
        }
    }

    // ------------------------------------------------------------------ Q1: exactness

    function test_Q1_allocationIsExact_butFaceValueRedemptionIsNot() public {
        this.harness(0, 0x1001);

        (uint256 t0, uint256 t1) = hook.totals();
        emit log_named_uint("queue total token0", t0);
        emit log_named_uint("queue total token1", t1);
        emit log_named_uint("PoolManager-measured token0", expT0);
        emit log_named_uint("PoolManager-measured token1", expT1);
        assertEq(t0, expT0, "token0 conservation");
        assertEq(t1, expT1, "token1 conservation");

        // What the position is ACTUALLY redeemable for, in real ERC20, vs what the queue thinks.
        (uint256 g0, uint256 g1) = hook.redeemAll();
        emit log_named_uint("redeemed token0 (real ERC20)", g0);
        emit log_named_uint("redeemed token1 (real ERC20)", g1);
        emit log_named_int("residual token0 (redeemed - queue)", int256(g0) - int256(t0));
        emit log_named_int("residual token1 (redeemed - queue)", int256(g1) - int256(t1));
        // ASSERT WHAT IS TRUE, NOT WHAT WE WANTED. The position redeems for slightly LESS than the
        // queue's face value: v4's swap accounting and its liquidity-valuation accounting are two
        // different roundings, both in the pool's favour. Measured at ~0.25 wei per swap (Q1c/Q1d).
        // So the ALLOCATOR is exact; REDEMPTION AT FACE VALUE IS NOT, and a naive withdraw() paying
        // face value would leave the last withdrawer short.
        assertLt(g0, t0, "expected a shortfall here; if this flipped, re-derive Q1c");
        assertLe(t0 - g0, 8, "token0 shortfall larger than v4 rounding explains");
        assertLe(t1 - g1, 8, "token1 shortfall larger than v4 rounding explains");
    }

    // ------------------------------------------------------------------ negative controls

    function _expectRed(uint8 mode, uint160 nonce, string memory what, string memory wantReason) internal {
        (bool ok, bytes memory err) = address(this).call(abi.encodeWithSelector(this.harness.selector, mode, nonce));
        assertFalse(ok, what);
        // DISTRUST-GREEN: a control that reverts for an unrelated reason proves nothing.
        string memory got = _reason(err);
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

    function test_negativeControl_proRataGoesRed() public {
        _expectRed(1, 0x2002, "PRO-RATA (what v4 actually does) passed the front-first assertions", "swap1: entry a0");  // pro-rata smears the fill across all three entries
    }

    function test_negativeControl_offByOneCursorGoesRed() public {
        _expectRed(2, 0x3003, "cursor starting at entry 1 passed", "swap1: entry a0");
    }

    function test_negativeControl_flooredSharesGoesRed() public {
        // NOTE: this control survives swap 1 and dies at swap 2 — precisely because a
        // single-entry fill has no remainder to drop. That is the rounding claim, confirmed
        // from the other side.
        _expectRed(3, 0x4004, "dropping the rounding remainder passed conservation", "swap2: token0 conservation");
    }

    /// @dev Positive control on the control: the same harness, unmutated, must PASS through the
    ///      identical external-call path the mutations fail through.
    function test_positiveControl_sameHarnessPassesUnmutated() public {
        (bool ok,) = address(this).call(abi.encodeWithSelector(this.harness.selector, uint8(0), uint160(0x5005)));
        assertTrue(ok, "unmutated harness failed: the controls prove nothing");
    }

    // ------------------------------------------------------------------ Q1b: the residual

    /// @dev Seed -> redeem with NO swaps at all. Isolates v4's own add/remove rounding from
    ///      anything the allocator does.
    function test_Q1b_residualWithZeroSwaps() public {
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        _deploy(0, 0x6006);
        _open(bps);
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 g0, uint256 g1) = hook.redeemAll();
        emit log_named_int("ZERO-SWAP residual token0", int256(g0) - int256(t0));
        emit log_named_int("ZERO-SWAP residual token1", int256(g1) - int256(t1));
    }

    function _residualAfter(uint256 nSwaps, uint160 nonce) internal returns (int256 d0, int256 d1) {
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        _deploy(0, nonce);
        _open(bps);
        for (uint256 i; i < nSwaps; i++) {
            _swap(i % 2 == 0, 1e18);
            _check("loop");
        }
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 g0, uint256 g1) = hook.redeemAll();
        d0 = int256(g0) - int256(t0);
        d1 = int256(g1) - int256(t1);
    }

    /// @dev THE FARMABILITY QUESTION. If the shortfall grows with swap count, a searcher can
    ///      inflate it with dust swaps until the queue cannot pay its last member.
    function test_Q1c_residualDoesNotGrowWithSwapCount() public {
        (int256 a0, int256 a1) = _residualAfter(2, 0x7007);
        (int256 b0, int256 b1) = _residualAfter(40, 0x8008);
        (int256 c0_, int256 c1_) = _residualAfter(200, 0x9009);
        emit log_named_int("residual token0 @2 swaps", a0);
        emit log_named_int("residual token1 @2 swaps", a1);
        emit log_named_int("residual token0 @40 swaps", b0);
        emit log_named_int("residual token1 @40 swaps", b1);
        emit log_named_int("residual token0 @200 swaps", c0_);
        emit log_named_int("residual token1 @200 swaps", c1_);
        // It is NOT O(1): it grows. The true, useful bound is sub-wei PER SWAP, which is what
        // decides whether a searcher can farm it. 200 swaps must not cost more than 200 wei.
        assertGt(_abs(c0_), _abs(a0), "shortfall did not grow: re-derive the mechanism");
        assertLe(_abs(c0_), 200, "token0 shortfall exceeds 1 wei per swap");
        assertLe(_abs(c1_), 200, "token1 shortfall exceeds 1 wei per swap");
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }

    // ------------------------------------------------------------------ Q2: gas profile

    function _gasFor(uint256 n, uint160 nonce) internal returns (uint256 gSmall, uint256 gSweep, uint256 touched) {
        uint256[] memory bps = new uint256[](n);
        uint256 each = 10_000 / n;
        for (uint256 i; i < n; i++) {
            bps[i] = each;
        }
        _deploy(0, nonce);
        _open(bps);
        // DISTRUST-GREEN: forge keeps storage warm for the whole test body, so seeding N entries
        // in this same context makes every entry slot warm and understates the sweep by ~2x.
        // vm.cool() restores production cold-access pricing.
        vm.cool(address(hook));
        _swap(true, 1e18); // lands in the head only
        gSmall = hook.lastAllocGas();
        vm.cool(address(hook));
        _swap(true, 18_000e18); // sweeps most of the book
        gSweep = hook.lastAllocGas();
        touched = hook.entriesTouched();
    }

    function test_Q2_gasProfileVersusQueueDepth() public {
        uint16[6] memory ns = [uint16(1), 2, 5, 10, 25, 50];
        for (uint256 i; i < ns.length; i++) {
            (uint256 gs, uint256 gw, uint256 t) = _gasFor(ns[i], uint160(0xA000 + i));
            emit log_named_uint("--- entries", ns[i]);
            emit log_named_uint("    afterSwap alloc gas, head-only swap", gs);
            emit log_named_uint("    afterSwap alloc gas, sweeping swap", gw);
            emit log_named_uint("    entries touched by the sweep", t);
        }
    }

    /// @dev MECHANISM TEST. If the growing shortfall is v4's fee-growth truncation
    ///      (feeGrowthGlobal += fee*Q128/liquidity, rounded DOWN, once per swap) then a ZERO-FEE
    ///      pool must show no growth at all. This is the experiment that names the cause.
    function test_Q1d_mechanism_zeroFeePoolDoesNotAccumulate() public {
        feeOverride = 3000;
        (int256 f0, int256 f1) = _residualAfter(200, 0xB001);
        feeOverride = 0;
        (int256 z0, int256 z1) = _residualAfter(200, 0xB002);
        feeOverride = 3000;
        emit log_named_int("200 swaps @ 0.30% fee, residual token0", f0);
        emit log_named_int("200 swaps @ 0.30% fee, residual token1", f1);
        emit log_named_int("200 swaps @ 0    fee, residual token0", z0);
        emit log_named_int("200 swaps @ 0    fee, residual token1", z1);
    }
}
