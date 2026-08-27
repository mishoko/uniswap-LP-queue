// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// RESEARCH ARTEFACT — settles PITFALLS §5.5/§5.6: can a seat withdraw its EXACT ledger
// composition WITHOUT poolManager.swap()?
//
//   FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/withdrawal \
//     forge test --match-path "docs/research/withdrawal/FloatWithdraw.t.sol" -vv
//
// The hook below is a COPY of archive/2026-08-26/test/spike/QueueAllocator.t.sol's QueueHook
// (the allocator is byte-for-byte the same, FRONT_FIRST only) plus:
//   - float0 / float1        : token held by the hook OUTSIDE the position
//   - withdraw()             : the float-based withdraw under test
//   - naiveWithdraw()        : PLAN §B.7 as literally specified — the BASELINE that must FAIL
//   - wmode                  : deliberate mutations for the negative controls

import {BaseTest} from "../../../archive/2026-08-26/test/utils/BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

contract FloatQueueHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;

    // withdraw modes. 0 = the real thing; 1..2 are MUTATIONS; 3 is the §B.7 F1 dust policy.
    uint8 constant W_OK = 0;
    uint8 constant W_FLOAT_OFF_BY_ONE = 1; // mutation: float debited by w-1
    uint8 constant W_WRONG_CURRENCY = 2; // mutation: the token1 leg is paid in currency0
    uint8 constant W_F1_SETTLE_ACTUAL = 3; // PLAN §B.7 (F1): pay min(face, available)
    uint8 constant W_MIN_LEG = 4; // mutation: size the removal on the SMALLER leg

    uint8 public immutable wmode;

    struct Entry {
        uint256 a0;
        uint256 a1;
    }

    Entry[] public q;

    PoolKey public key;
    int24 public tl;
    int24 public tu;
    uint128 public liq;

    // ---- THE NEW STATE. This is what PLAN §B.3 is missing. ----
    uint256 public float0; // token0 held by the hook outside the position, owed to the queue
    uint256 public float1; // token1 held by the hook outside the position, owed to the queue

    uint256 public paid0;
    uint256 public paid1;
    uint256 public lastWithdrawGas;
    uint256 public lastPulledLiquidity;

    // naiveWithdraw only: tokens the position released that the §B.7 ledger has NO HOME FOR.
    uint256 public naiveUnaccounted0;
    uint256 public naiveUnaccounted1;

    uint256 public lastAllocGas;
    uint256 public entriesTouched;

    error QueueUnderflow(uint256 shortfall);
    error OverEntitlement(uint256 want, uint256 have);
    error FloatShort(uint256 want, uint256 have);
    error NaiveReleasedNothing(uint256 want0, uint256 want1);

    constructor(IPoolManager pm, uint8 wmode_) BaseHook(pm) {
        wmode = wmode_;
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

    /// @dev Burn whatever is left of the position and report the REAL tokens received.
    function redeemAll() external returns (uint256 g0, uint256 g1) {
        if (liq == 0) return (0, 0);
        uint256 b0 = _bal(key.currency0);
        uint256 b1 = _bal(key.currency1);
        poolManager.unlock(abi.encode(-int256(uint256(liq))));
        liq = 0;
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

    // ------------------------------------------------------------------ THE FLOAT WITHDRAW

    /// @dev Size the removal on the leg that BINDS (the larger one, in liquidity units), pay the
    ///      seat its EXACT ledger amounts, retain the remainder as shared float. No swap. Ever.
    function withdraw(uint256 i, uint256 w0, uint256 w1) external returns (uint256 p0, uint256 p1) {
        uint256 gStart = gasleft();
        Entry storage e = q[i];
        if (w0 > e.a0) revert OverEntitlement(w0, e.a0);
        if (w1 > e.a1) revert OverEntitlement(w1, e.a1);

        uint256 d0 = w0 > float0 ? w0 - float0 : 0;
        uint256 d1 = w1 > float1 ? w1 - float1 : 0;
        lastPulledLiquidity = 0;
        if (d0 != 0 || d1 != 0) {
            uint128 dl = _liquidityToCover(d0, d1);
            if (dl != 0) {
                lastPulledLiquidity = dl;
                bytes memory r = poolManager.unlock(abi.encode(-int256(uint256(dl))));
                (uint256 g0, uint256 g1) = abi.decode(r, (uint256, uint256));
                liq -= dl;
                float0 += g0;
                float1 += g1;
            }
        }

        if (wmode == W_F1_SETTLE_ACTUAL) {
            if (w0 > float0) w0 = float0;
            if (w1 > float1) w1 = float1;
        } else {
            if (float0 < w0) revert FloatShort(w0, float0);
            if (float1 < w1) revert FloatShort(w1, float1);
        }

        e.a0 -= w0;
        e.a1 -= w1;

        if (wmode == W_FLOAT_OFF_BY_ONE) {
            float0 -= (w0 == 0 ? 0 : w0 - 1);
            float1 -= w1;
        } else {
            float0 -= w0;
            float1 -= w1;
        }

        if (wmode == W_WRONG_CURRENCY) {
            if (w0 + w1 != 0) IERC20Minimal(Currency.unwrap(key.currency0)).transfer(msg.sender, w0 + w1);
        } else {
            if (w0 != 0) IERC20Minimal(Currency.unwrap(key.currency0)).transfer(msg.sender, w0);
            if (w1 != 0) IERC20Minimal(Currency.unwrap(key.currency1)).transfer(msg.sender, w1);
        }

        paid0 += w0;
        paid1 += w1;
        (p0, p1) = (w0, w1);
        lastWithdrawGas = gStart - gasleft();
    }

    /// @dev PLAN §B.7 AS SPECIFIED: "compute liquidityDelta to release those amounts". No float
    ///      state exists, so neither leg may over-release — the delta is the MIN of the two legs.
    ///      This is the BASELINE. It must fail at a fully-converted seat.
    function naiveWithdraw(uint256 i, uint256 w0, uint256 w1) external returns (uint256 p0, uint256 p1) {
        Entry storage e = q[i];
        if (w0 > e.a0) revert OverEntitlement(w0, e.a0);
        if (w1 > e.a1) revert OverEntitlement(w1, e.a1);
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(tl);
        uint160 hi = TickMath.getSqrtPriceAtTick(tu);
        uint128 l0 = w0 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount0(sqrtP, hi, w0);
        uint128 l1 = w1 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount1(lo, sqrtP, w1);
        uint128 dl = l0 < l1 ? l0 : l1;
        if (dl == 0) revert NaiveReleasedNothing(w0, w1);
        bytes memory r = poolManager.unlock(abi.encode(-int256(uint256(dl))));
        (uint256 rel0, uint256 rel1) = abi.decode(r, (uint256, uint256));
        liq -= dl;
        // §B.7 has no float state, so anything released beyond the seat's face value is
        // UNACCOUNTED — it sits in the hook belonging to nobody. modifyLiquidity settles the
        // position's ENTIRE fee debt regardless of how small dl is, so this is not hypothetical.
        p0 = rel0 > w0 ? w0 : rel0;
        p1 = rel1 > w1 ? w1 : rel1;
        naiveUnaccounted0 += rel0 - p0;
        naiveUnaccounted1 += rel1 - p1;
        e.a0 -= p0;
        e.a1 -= p1;
        if (p0 != 0) IERC20Minimal(Currency.unwrap(key.currency0)).transfer(msg.sender, p0);
        if (p1 != 0) IERC20Minimal(Currency.unwrap(key.currency1)).transfer(msg.sender, p1);
        paid0 += p0;
        paid1 += p1;
    }

    function liquidityToCover(uint256 need0, uint256 need1) external view returns (uint128) {
        return _liquidityToCover(need0, need1);
    }

    function _liquidityToCover(uint256 need0, uint256 need1) internal view returns (uint128) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(tl);
        uint160 hi = TickMath.getSqrtPriceAtTick(tu);
        uint128 l0 = need0 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount0(sqrtP, hi, need0);
        uint128 l1 = need1 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount1(lo, sqrtP, need1);
        // THE LOAD-BEARING LINE: size on the leg that BINDS, i.e. the LARGER liquidity requirement.
        uint256 d = wmode == W_MIN_LEG ? (l0 < l1 ? l0 : l1) : (l0 > l1 ? l0 : l1);
        // getLiquidityForAmountX rounds DOWN, and modifyLiquidity's release rounds DOWN again.
        // One extra unit of liquidity covers both truncations; the surplus becomes float.
        if (d != 0) d += 1;
        if (d > liq) d = liq;
        return uint128(d);
    }

    // ------------------------------------------------------------------ the allocator (UNCHANGED)

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta d, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 g = gasleft();
        _allocate(d);
        lastAllocGas = g - gasleft();
        return (BaseHook.afterSwap.selector, 0);
    }

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

        for (uint256 i = 0; i < q.length && remaining > 0; i++) {
            uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
            if (bal == 0) continue;
            uint256 take_ = bal < remaining ? bal : remaining;
            remaining -= take_;
            uint256 give = remaining == 0 ? amtIn - assignedIn : FullMath.mulDiv(amtIn, take_, amtOut);
            assignedIn += give;
            if (outIsOne) {
                q[i].a1 -= take_;
                q[i].a0 += give;
            } else {
                q[i].a0 -= take_;
                q[i].a1 += give;
            }
            touched++;
        }
        if (remaining != 0) revert QueueUnderflow(remaining);
        entriesTouched = touched;
    }
}

// ============================================================================================
//                                        THE SPIKE
// ============================================================================================

contract FloatWithdrawTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint128 constant LIQ = 1_000e18;

    Currency c0;
    Currency c1;
    FloatQueueHook hook;
    PoolKey k;

    // Ledger conservation, measured on POOLMANAGER'S OWN ERC20 BALANCES (LAW 3).
    uint256 expT0;
    uint256 expT1;
    // The hook's real ERC20 balance right after seeding. float must be backed by real tokens
    // ABOVE this line — the hook's start-of-life mint must never be able to hide insolvency.
    uint256 hookBase0;
    uint256 hookBase1;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        vm.roll(100);
    }

    // ------------------------------------------------------------------ fixture

    function _deploy(uint8 wmode, uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("FloatWithdraw.t.sol:FloatQueueHook", abi.encode(poolManager, wmode), a);
        hook = FloatQueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 100_000e18);
        MockERC20(Currency.unwrap(c1)).mint(a, 100_000e18);
    }

    /// @dev The spike's exact fixture: 1:4 price, three seats 400/600/9000 bps, four swaps.
    function _scenario(uint8 wmode, uint160 nonce) internal {
        _deploy(wmode, nonce);
        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        require(s0 != s1, "fixture is unit-priced");
        expT0 = s0;
        expT1 = s1;
        hookBase0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(hook));
        hookBase1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(hook));

        _swap(true, 4e18);
        _swap(true, 300e18);
        _swap(true, 50e18);
        _swap(false, 20e18);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        uint256 p0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 p1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, k, "", address(this), block.timestamp);
        uint256 n0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 n1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        if (zeroForOne) {
            expT0 += (n0 - p0);
            expT1 -= (p1 - n1);
        } else {
            expT1 += (n1 - p1);
            expT0 -= (p0 - n0);
        }
    }

    // ------------------------------------------------------------------ shared assertions

    /// @dev LAW 3, AMENDED FORM. Never the raw balance.
    function _pmBacking(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(poolManager)) - poolManager.protocolFeesAccrued(c);
    }

    /// @dev The float must be backed, to the wei, by real ERC20 the hook actually took OUT of
    ///      PoolManager. Not by the hook's own opinion, and not by its start-of-life mint.
    function _assertFloatIsReal(string memory tag) internal view {
        uint256 h0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(hook)) - hookBase0;
        uint256 h1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(hook)) - hookBase1;
        assertEq(h0, hook.float0(), string.concat(tag, ": float0 not backed by real token0"));
        assertEq(h1, hook.float1(), string.concat(tag, ": float1 not backed by real token1"));
    }

    /// @dev LEDGER CONSERVATION: everything still owed + everything already paid out must equal
    ///      the running total measured on PoolManager's balances across every swap.
    function _assertLedgerConserved(string memory tag) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        assertEq(t0 + hook.paid0(), expT0, string.concat(tag, ": token0 ledger conservation"));
        assertEq(t1 + hook.paid1(), expT1, string.concat(tag, ": token1 ledger conservation"));
    }

    // ------------------------------------------------------------------ 1. REPRODUCTION

    function test_R1_reproduceTheMeasuredFailure() public {
        _scenario(0, 0x1101);
        (uint256 a0, uint256 a1) = hook.entry(1);
        emit log_named_uint("seat1 ledger a0", a0);
        emit log_named_uint("seat1 ledger a1", a1);
        assertEq(a0, 258877453809749247723, "seat1 a0 drifted from the recorded measurement");
        assertEq(a1, 0, "seat1 is not fully converted");

        // and it can withdraw NOTHING through PLAN §B.7 as specified.
        vm.expectRevert(abi.encodeWithSelector(FloatQueueHook.NaiveReleasedNothing.selector, a0, uint256(0)));
        hook.naiveWithdraw(1, a0, a1);
    }

    // ------------------------------------------------------------------ 2. AGGREGATE INVARIANT

    /// @dev THE LOAD-BEARING QUESTION. If the SUM of the seats' ledgers is not what the position
    ///      is actually redeemable for, the float hypothesis is dead on arrival.
    function test_A1_aggregateInvariant_ledgerSumEqualsRedeemable() public {
        _scenario(0, 0x1202);
        (uint256 t0, uint256 t1) = hook.totals();

        // The probe's "position releases" number is PRINCIPAL ONLY. Show that first.
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(SPACING));
        uint160 hi = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(SPACING));
        (uint256 pr0, uint256 pr1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, LIQ);
        emit log_named_uint("ledger sum a0                 ", t0);
        emit log_named_uint("position PRINCIPAL only  t0   ", pr0);
        emit log_named_int("  gap (ledger - principal) t0  ", int256(t0) - int256(pr0));
        emit log_named_uint("ledger sum a1                 ", t1);
        emit log_named_uint("position PRINCIPAL only  t1   ", pr1);
        emit log_named_int("  gap (ledger - principal) t1  ", int256(t1) - int256(pr1));
        // 0.30% LP fee on 354e18 token0 in and 20e18 token1 in.
        emit log_named_uint("LP fee earned on token0 in    ", uint256(354e18) * 3000 / 1_000_000);
        emit log_named_uint("LP fee earned on token1 in    ", uint256(20e18) * 3000 / 1_000_000);

        // Now the real question: REDEEMABLE = principal + fees owed, measured in real ERC20.
        (uint256 g0, uint256 g1) = hook.redeemAll();
        emit log_named_uint("REDEEMED token0 (real ERC20)  ", g0);
        emit log_named_uint("REDEEMED token1 (real ERC20)  ", g1);
        emit log_named_int("residual token0 (redeemed-ledg)", int256(g0) - int256(t0));
        emit log_named_int("residual token1 (redeemed-ledg)", int256(g1) - int256(t1));

        // The invariant, asserted: the aggregate is consistent to within v4's known rounding
        // residual (§E.4, ~0.26 wei/swap, always in the pool's favour).
        assertLe(g0, t0, "position redeemed MORE than the ledger claims: re-derive E.4");
        assertLe(g1, t1, "position redeemed MORE than the ledger claims: re-derive E.4");
        assertLe(t0 - g0, 8, "AGGREGATE INVARIANT BROKEN on token0 - float hypothesis is dead");
        assertLe(t1 - g1, 8, "AGGREGATE INVARIANT BROKEN on token1 - float hypothesis is dead");
    }

    // ------------------------------------------------------------------ 3/4. THE HARD CASE

    /// @dev The fully-converted seat (a1 == 0) redeems its EXACT ledger, both legs, first.
    function test_F1_hardCase_fullyConvertedSeatFirst() public {
        _scenario(0, 0x1303);
        (uint256 a0, uint256 a1) = hook.entry(1);
        assertEq(a1, 0, "fixture: seat1 must be fully converted");

        uint256 b0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 b1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        (uint256 p0, uint256 p1) = hook.withdraw(1, a0, a1);
        emit log_named_uint("seat1 paid token0             ", p0);
        emit log_named_uint("seat1 paid token1             ", p1);
        emit log_named_uint("liquidity pulled              ", hook.lastPulledLiquidity());
        emit log_named_uint("float0 retained after         ", hook.float0());
        emit log_named_uint("float1 retained after         ", hook.float1());

        assertEq(p0, a0, "seat1 did not receive its EXACT token0 entitlement");
        assertEq(p1, a1, "seat1 did not receive its EXACT token1 entitlement");
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(this)) - b0, a0, "token0 did not arrive");
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - b1, a1, "token1 did not arrive");
        (uint256 r0, uint256 r1) = hook.entry(1);
        assertEq(r0, 0, "seat1 ledger a0 not zeroed");
        assertEq(r1, 0, "seat1 ledger a1 not zeroed");
        assertGt(hook.float1(), 0, "no token1 float was created: the mechanism did not engage");
        _assertFloatIsReal("hardCase");
        _assertLedgerConserved("hardCase");
    }

    /// @dev EVERY seat withdraws its EXACT ledger, in a given order. Returns leftover ledger dust.
    function _drain(uint256[3] memory order, string memory tag) internal returns (uint256 dust0, uint256 dust1) {
        for (uint256 j; j < 3; j++) {
            uint256 i = order[j];
            (uint256 a0, uint256 a1) = hook.entry(i);
            uint256 b0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
            uint256 b1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
            (uint256 p0, uint256 p1) = hook.withdraw(i, a0, a1);
            emit log_named_uint("  withdrew seat", i);
            emit log_named_uint("     face a0  ", a0);
            emit log_named_uint("     paid a0  ", p0);
            emit log_named_uint("     face a1  ", a1);
            emit log_named_uint("     paid a1  ", p1);
            emit log_named_uint("     liq left ", hook.liq());
            emit log_named_uint("     float0   ", hook.float0());
            emit log_named_uint("     float1   ", hook.float1());
            assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(this)) - b0, p0, "token0 did not arrive");
            assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - b1, p1, "token1 did not arrive");
            _assertFloatIsReal(tag);
            _assertLedgerConserved(tag);
        }
        (dust0, dust1) = hook.totals();
    }

    /// @dev Runs a drain order under the F1 dust policy (§B.7 F1: pay min(face, available)).
    ///      Any seat that gets less than face value shows up as leftover ledger dust, which is
    ///      asserted to be at most v4's rounding residual — NOT hidden.
    function _drainOrder(uint256[3] memory order, uint160 nonce, string memory tag) internal {
        _scenario(3, nonce);
        (uint256 d0, uint256 d1) = _drain(order, tag);
        emit log_named_uint("LEFTOVER ledger dust token0   ", d0);
        emit log_named_uint("LEFTOVER ledger dust token1   ", d1);
        assertLe(d0, 8, string.concat(tag, ": leftover token0 exceeds v4 rounding residual"));
        assertLe(d1, 8, string.concat(tag, ": leftover token1 exceeds v4 rounding residual"));
        // Nothing is stranded: the float is spent, and the position is (near) empty.
        emit log_named_uint("float0 at end                 ", hook.float0());
        emit log_named_uint("float1 at end                 ", hook.float1());
        emit log_named_uint("liquidity at end              ", hook.liq());
        assertLe(hook.float0(), 8, string.concat(tag, ": float0 stranded"));
        assertLe(hook.float1(), 8, string.concat(tag, ": float1 stranded"));
        _assertFloatIsReal(tag);
        _assertLedgerConserved(tag);
    }

    function test_F2a_allSeats_convertedFIRST() public {
        _drainOrder([uint256(1), 0, 2], 0x1404, "order[1,0,2]");
    }

    function test_F2b_allSeats_convertedLAST() public {
        _drainOrder([uint256(0), 2, 1], 0x1505, "order[0,2,1]");
    }

    function test_F2c_allSeats_reverse() public {
        _drainOrder([uint256(2), 1, 0], 0x1606, "order[2,1,0]");
    }

    function test_F2d_allSeats_inOrder() public {
        _drainOrder([uint256(0), 1, 2], 0x1707, "order[0,1,2]");
    }

    /// @dev INTERLEAVED WITH SWAPS. The position shrinks between withdrawals and the price moves.
    ///      The allocator must keep working against the smaller position.
    function test_F3_interleavedWithSwaps() public {
        _scenario(3, 0x1808);

        // seat 1 (fully converted) out first
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        _assertFloatIsReal("interleave/w1");
        _assertLedgerConserved("interleave/w1");
        emit log_named_uint("after w(seat1): liq           ", hook.liq());
        emit log_named_uint("after w(seat1): float0        ", hook.float0());
        emit log_named_uint("after w(seat1): float1        ", hook.float1());

        // ... then swaps against the SHRUNKEN position, both directions
        _swap(true, 25e18);
        _assertLedgerConserved("interleave/s1");
        _swap(false, 10e18);
        _assertLedgerConserved("interleave/s2");
        emit log_named_uint("after 2 swaps: liq            ", hook.liq());

        // partial withdraw of seat 0 (half of each leg)
        (uint256 b0, uint256 b1) = hook.entry(0);
        hook.withdraw(0, b0 / 2, b1 / 2);
        _assertFloatIsReal("interleave/w0partial");
        _assertLedgerConserved("interleave/w0partial");
        (uint256 r0, uint256 r1) = hook.entry(0);
        assertEq(r0, b0 - b0 / 2, "partial withdraw debited the wrong token0 amount");
        assertEq(r1, b1 - b1 / 2, "partial withdraw debited the wrong token1 amount");

        _swap(true, 5e18);
        _assertLedgerConserved("interleave/s3");

        // drain the rest
        (uint256 d0, uint256 d1) = _drain([uint256(0), 2, 1], "interleave/drain");
        emit log_named_uint("LEFTOVER ledger dust token0   ", d0);
        emit log_named_uint("LEFTOVER ledger dust token1   ", d1);
        assertLe(d0, 16, "leftover token0 exceeds residual after 7 swaps");
        assertLe(d1, 16, "leftover token1 exceeds residual after 7 swaps");
    }

    // ------------------------------------------------------------------ 5. CONSERVATION (LAW 3)

    /// @dev LAW 3 AS AMENDED. Solvency measured against PoolManager balance MINUS
    ///      protocolFeesAccrued, PLUS the float the hook holds. Never the raw-balance form.
    function test_C1_conservation_amendedForm() public {
        _scenario(0, 0x1909);
        assertEq(poolManager.protocolFeesAccrued(c0), 0, "fixture ran at protocol fee 0");
        assertEq(poolManager.protocolFeesAccrued(c1), 0, "fixture ran at protocol fee 0");

        (uint256 t0, uint256 t1) = hook.totals();
        uint256 back0 = _pmBacking(c0) + hook.float0();
        uint256 back1 = _pmBacking(c1) + hook.float1();
        emit log_named_uint("PRE-WITHDRAW ledger t0        ", t0);
        emit log_named_uint("PRE-WITHDRAW backing t0       ", back0);
        assertGe(back0, t0, "INSOLVENT on token0 before any withdrawal");
        assertGe(back1, t1, "INSOLVENT on token1 before any withdrawal");

        // withdraw the hard seat, then re-measure. Backing must still cover the REMAINING ledger.
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        (t0, t1) = hook.totals();
        back0 = _pmBacking(c0) + hook.float0();
        back1 = _pmBacking(c1) + hook.float1();
        emit log_named_uint("POST-WITHDRAW ledger t0       ", t0);
        emit log_named_uint("POST-WITHDRAW backing t0      ", back0);
        emit log_named_int("  slack token0                ", int256(back0) - int256(t0));
        emit log_named_uint("POST-WITHDRAW ledger t1       ", t1);
        emit log_named_uint("POST-WITHDRAW backing t1      ", back1);
        emit log_named_int("  slack token1                ", int256(back1) - int256(t1));
        assertGe(back0, t0, "INSOLVENT on token0 after the float withdrawal");
        assertGe(back1, t1, "INSOLVENT on token1 after the float withdrawal");
        // and the slack is only v4 dust, not a systematic over-collateralisation
        assertLe(back0 - t0, 8, "backing exceeds the ledger by more than v4 dust: something leaked in");
        assertLe(back1 - t1, 8, "backing exceeds the ledger by more than v4 dust: something leaked in");
        _assertFloatIsReal("conservation");
        _assertLedgerConserved("conservation");
    }

    // ------------------------------------------------------------------ 6. NEGATIVE CONTROLS

    /// @dev NC-A: mutate the float debit by one wei. The float-vs-real-ERC20 reconciliation must
    ///      catch it with a SPECIFIC numeric failure.
    function test_NC_A_floatOffByOne_goesRed() public {
        _scenario(1, 0x2101); // W_FLOAT_OFF_BY_ONE
        (uint256 a0,) = hook.entry(1);
        hook.withdraw(1, a0, 0);
        uint256 real0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(hook)) - hookBase0;
        emit log_named_uint("hook REAL token0 above base   ", real0);
        emit log_named_uint("hook CLAIMED float0           ", hook.float0());
        assertEq(hook.float0() - real0, 1, "the mutation did not produce the expected 1-wei overstatement");
        // the suite's own assertion must go red
        vm.expectRevert();
        this.callAssertFloatIsReal();
    }

    function callAssertFloatIsReal() external view {
        _assertFloatIsReal("mutation");
    }

    /// @dev NC-B: pay the token1 leg out of currency0. Specific numeric failure on both legs.
    function test_NC_B_wrongCurrency_goesRed() public {
        _scenario(2, 0x2202); // W_WRONG_CURRENCY
        (uint256 a0, uint256 a1) = hook.entry(0); // seat 0 has BOTH legs nonzero
        assertGt(a0, 0);
        assertGt(a1, 0);
        uint256 b0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 b1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        hook.withdraw(0, a0, a1);
        uint256 got0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(this)) - b0;
        uint256 got1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - b1;
        emit log_named_uint("mutant paid token0            ", got0);
        emit log_named_uint("mutant paid token1            ", got1);
        assertEq(got0, a0 + a1, "mutation did not mix the currencies as intended");
        assertEq(got1, 0, "mutation still paid token1");
        vm.expectRevert();
        this.callAssertFloatIsReal();
    }

    /// @dev NC-C: THE BASELINE. PLAN §B.7 as specified still fails at the fully-converted seat.
    ///      This is what makes the float load-bearing.
    function test_NC_C_naiveWithdrawStillFails() public {
        _scenario(0, 0x2303);
        (uint256 a0, uint256 a1) = hook.entry(1);
        vm.expectRevert(abi.encodeWithSelector(FloatQueueHook.NaiveReleasedNothing.selector, a0, a1));
        hook.naiveWithdraw(1, a0, a1);

        // and on seats that DO have both legs it fails in a SECOND, independent way: the token1
        // leg is stranded, AND the release overshoots the face value with nowhere to put it.
        for (uint256 i = 0; i < 3; i++) {
            if (i == 1) continue;
            (uint256 f0, uint256 f1) = hook.entry(i);
            (uint256 p0, uint256 p1) = hook.naiveWithdraw(i, f0, f1);
            emit log_named_uint("naive seat", i);
            emit log_named_uint("   face a0          ", f0);
            emit log_named_uint("   paid a0          ", p0);
            emit log_named_uint("   face a1          ", f1);
            emit log_named_uint("   paid a1          ", p1);
            emit log_named_uint("   STRANDED token1  ", f1 - p1);
            emit log_named_uint("   UNACCOUNTED t0 so far", hook.naiveUnaccounted0());
            assertLt(p1, f1, "naive withdraw unexpectedly paid the full token1 leg");
        }
        // The first naive removal drags out the position's WHOLE fee debt (fees are settled in
        // full on every modifyLiquidity, not pro-rata to dl) - money §B.7 cannot book anywhere.
        emit log_named_uint("TOTAL UNACCOUNTED token0", hook.naiveUnaccounted0());
        emit log_named_uint("TOTAL UNACCOUNTED token1", hook.naiveUnaccounted1());
        assertGt(hook.naiveUnaccounted0(), 0, "expected unbooked token0 under the B.7 spec");
    }

    /// @dev NC-D: a withdrawer cannot take more than its entitlement.
    function test_NC_D_cannotExceedEntitlement() public {
        _scenario(0, 0x2404);
        (uint256 a0, uint256 a1) = hook.entry(1);
        vm.expectRevert(abi.encodeWithSelector(FloatQueueHook.OverEntitlement.selector, a0 + 1, a0));
        hook.withdraw(1, a0 + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(FloatQueueHook.OverEntitlement.selector, uint256(1), a1));
        hook.withdraw(1, 0, 1);

        // and after a legitimate full withdrawal it cannot come back for more
        hook.withdraw(1, a0, a1);
        vm.expectRevert(abi.encodeWithSelector(FloatQueueHook.OverEntitlement.selector, uint256(1), uint256(0)));
        hook.withdraw(1, 1, 0);

        // nor can a DIFFERENT seat drain the float that seat 1's withdrawal created.
        assertGt(hook.float1(), 0, "no float to attack");
        (uint256 b0, uint256 b1) = hook.entry(0);
        vm.expectRevert(abi.encodeWithSelector(FloatQueueHook.OverEntitlement.selector, b1 + 1, b1));
        hook.withdraw(0, b0, b1 + 1);
    }

    /// @dev NC-E: POSITIVE control on the controls — the unmutated hook passes the identical path.
    function test_NC_E_positiveControl() public {
        _scenario(0, 0x2505);
        (uint256 a0,) = hook.entry(1);
        hook.withdraw(1, a0, 0);
        this.callAssertFloatIsReal();
    }

    /// @dev NC-F: the EXACT-payout (non-F1) hook must REVERT rather than short-pay the last
    ///      withdrawer. This proves the residual is real and is not being silently swallowed.
    function test_NC_F_lastWithdrawerHitsTheResidual() public {
        _scenario(0, 0x2606); // W_OK: exact payout, no F1 truncation
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        (a0, a1) = hook.entry(0);
        hook.withdraw(0, a0, a1);
        (a0, a1) = hook.entry(2);
        emit log_named_uint("last seat face a0             ", a0);
        emit log_named_uint("last seat face a1             ", a1);
        emit log_named_uint("float0 available              ", hook.float0());
        emit log_named_uint("liq remaining                 ", hook.liq());
        (bool ok, bytes memory err) = address(hook).call(abi.encodeWithSelector(hook.withdraw.selector, 2, a0, a1));
        emit log_named_string("last withdrawal succeeded?", ok ? "YES" : "NO");
        if (!ok) {
            (uint256 want, uint256 have) = abi.decode(_strip(err), (uint256, uint256));
            emit log_named_uint("  FloatShort want             ", want);
            emit log_named_uint("  FloatShort have             ", have);
            emit log_named_uint("  SHORTFALL (wei)             ", want - have);
            assertEq(bytes4(err), FloatQueueHook.FloatShort.selector, "reverted for the WRONG reason");
            assertLe(want - have, 8, "shortfall is larger than v4 rounding explains");
        }
    }

    function _strip(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = err[i + 4];
        }
    }

    /// @dev NC-G: the LOAD-BEARING mutation. Size the removal on the SMALLER leg instead of the
    ///      larger one — i.e. exactly the §B.7 sizing — and the hard case must go RED with a
    ///      specific FloatShort, not with some unrelated error.
    function test_NC_G_minLegSizing_goesRed() public {
        _scenario(4, 0x2909); // W_MIN_LEG
        (uint256 a0, uint256 a1) = hook.entry(0); // both legs nonzero: min != max
        (bool ok, bytes memory err) = address(hook).call(abi.encodeWithSelector(hook.withdraw.selector, 0, a0, a1));
        assertFalse(ok, "min-leg sizing PASSED: the max-leg rule is not load-bearing");
        assertEq(bytes4(err), FloatQueueHook.FloatShort.selector, "went red for the WRONG reason");
        (uint256 want, uint256 have) = abi.decode(_strip(err), (uint256, uint256));
        emit log_named_uint("min-leg mutant: want          ", want);
        emit log_named_uint("min-leg mutant: have          ", have);
        emit log_named_uint("min-leg mutant: SHORT by      ", want - have);
        assertEq(want, a1, "the mutation should starve the token1 leg specifically");
        assertGt(want - have, 1e18, "shortfall is dust-sized: this is not the failure we claimed");
    }

    /// @dev THE HARD CONSTRAINT (PITFALLS §5.6), asserted mechanically rather than by reading:
    ///      the whole withdrawal path emits no PoolManager Swap event.
    function test_NC_H_withdrawEmitsNoSwapEvent() public {
        _scenario(3, 0x2A0A);
        vm.recordLogs();
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        (a0, a1) = hook.entry(2);
        hook.withdraw(2, a0, a1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == IPoolManager.Swap.selector) swaps++;
        }
        emit log_named_uint("PoolManager logs during withdrawals", logs.length);
        emit log_named_uint("Swap events emitted                ", swaps);
        assertGt(logs.length, 0, "recorded nothing: the check would pass vacuously");
        assertEq(swaps, 0, "withdraw() called poolManager.swap - PITFALLS 5.6 violated");
    }

    // ------------------------------------------------------------------ 8. GAS

    function test_G1_gasOfTheFloatWithdraw() public {
        _scenario(3, 0x2707);
        // the HARD case: fully-converted seat, cold storage.
        vm.cool(address(hook));
        vm.cool(address(poolManager));
        vm.cool(Currency.unwrap(c0));
        vm.cool(Currency.unwrap(c1));
        (uint256 a0, uint256 a1) = hook.entry(1);
        uint256 g = gasleft();
        hook.withdraw(1, a0, a1);
        uint256 total = g - gasleft();
        emit log_named_uint("HARD CASE withdraw gas (cold, incl. call overhead)", total);
        emit log_named_uint("  hook-internal measurement                       ", hook.lastWithdrawGas());

        // a seat paid ENTIRELY out of existing float (no modifyLiquidity at all)
        vm.cool(address(hook));
        vm.cool(address(poolManager));
        vm.cool(Currency.unwrap(c0));
        vm.cool(Currency.unwrap(c1));
        (, uint256 b1) = hook.entry(0);
        emit log_named_uint("float0 before seat0           ", hook.float0());
        emit log_named_uint("float1 before seat0           ", hook.float1());
        assertGt(hook.float1(), b1, "fixture: seat0's token1 leg must fit inside the float");
        g = gasleft();
        hook.withdraw(0, 0, b1); // entirely inside the float -> no modifyLiquidity at all
        total = g - gasleft();
        emit log_named_uint("FLOAT-ONLY withdraw gas (cold, incl. call overhead)", total);
        emit log_named_uint("  liquidity pulled (must be 0)                     ", hook.lastPulledLiquidity());
        assertEq(hook.lastPulledLiquidity(), 0, "this path was supposed to touch no liquidity");
    }

    // ------------------------------------------------------------------ ATTACKING THE DESIGN

    /// @dev ATTACK: withdraw ONLY the minority leg. The removal is sized on that leg, so the
    ///      position is torn down to fund it and the majority leg lands in the idle float.
    ///      This is the sharpest griefing vector the float creates. MEASURE the exchange rate:
    ///      how much pool depth is destroyed per unit of the attacker's OWN capital idled?
    function test_ATK_1_minorityLegWithdrawalDestroysDepth() public {
        _scenario(3, 0x3A0A);
        uint128 liqBefore = hook.liq();
        (uint256 a0, uint256 a1) = hook.entry(2); // the tail: 90% of the queue
        emit log_named_uint("attacker seat2 a0             ", a0);
        emit log_named_uint("attacker seat2 a1             ", a1);

        hook.withdraw(2, 0, a1); // take ONLY token1. Leave the whole token0 leg in the ledger.

        emit log_named_uint("liquidity before              ", liqBefore);
        emit log_named_uint("liquidity after               ", hook.liq());
        emit log_named_uint("depth destroyed (bps of pool) ", (liqBefore - hook.liq()) * 10_000 / liqBefore);
        emit log_named_uint("float0 now idle               ", hook.float0());
        emit log_named_uint("float1 now idle               ", hook.float1());
        (uint256 r0,) = hook.entry(2);
        emit log_named_uint("attacker's OWN a0 still in q  ", r0);
        emit log("  ^ the attackers own idled capital, earning no fees");

        // The grief is real but SELF-FUNDED and proportional: the liquidity torn out is bounded
        // by what the attacker's own seat is entitled to.
        assertGt(liqBefore - hook.liq(), liqBefore / 2, "expected a large teardown from the tail seat");
        _assertFloatIsReal("attack");
        _assertLedgerConserved("attack");

        // and swaps still work against the shrunken pool - no DoS.
        _swap(true, 1e18);
        _assertLedgerConserved("attack/swap");
        _swap(false, 1e18);
        _assertLedgerConserved("attack/swap2");
        emit log_named_uint("swaps after the grief         ", 2);
    }

    /// @dev ATTACK: a seat that has already withdrawn everything cannot pull the float out by
    ///      asking for zero-value withdrawals, and cannot make the hook pay itself.
    function test_ATK_2_emptySeatCannotTouchTheFloat() public {
        _scenario(3, 0x3B0B);
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        uint256 f0 = hook.float0();
        uint256 f1 = hook.float1();
        assertGt(f1, 0, "no float to attack");
        for (uint256 n; n < 5; n++) {
            hook.withdraw(1, 0, 0); // empty seat, repeatedly
        }
        assertEq(hook.float0(), f0, "an empty seat moved float0");
        assertEq(hook.float1(), f1, "an empty seat moved float1");
        assertEq(hook.liq(), 884814917170750529333, "an empty seat moved the position");
        _assertFloatIsReal("attack2");
        _assertLedgerConserved("attack2");
    }

    // ------------------------------------------------------------------ 9. DEPTH COST OF THE FLOAT

    function test_D1_floatCostsPoolDepth() public {
        _scenario(3, 0x2808);
        emit log_named_uint("liquidity before any withdrawal", hook.liq());
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        emit log_named_uint("liquidity after seat1 withdrew ", hook.liq());
        emit log_named_uint("float0 idle                    ", hook.float0());
        emit log_named_uint("float1 idle                    ", hook.float1());

        // How much of what left the position is IDLE rather than paid out?
        // seat1 took (a0, 0); everything else that came out is float.
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(SPACING));
        uint160 hi = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(SPACING));
        (uint256 rem0, uint256 rem1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, hook.liq());
        emit log_named_uint("position principal left t0     ", rem0);
        emit log_named_uint("position principal left t1     ", rem1);
        emit log_named_uint("float as %% of remaining t1 (bps)", rem1 == 0 ? 0 : hook.float1() * 10_000 / rem1);
    }
}

// ============================================================================================
//                        ASYMMETRIC DECIMALS (18 / 6) — LAW 1, harder
// ============================================================================================

contract FloatWithdrawAsymmetricDecimalsTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    // Chosen so the pool seeds ~1,000,000 whole token0 against ~4,000,000 whole token1 at a
    // HUMAN price of 1 token0 = 4 token1 regardless of which token sorts first. See _sqrtPrice().
    uint128 constant LIQ = 2e18;

    Currency c0;
    Currency c1;
    uint8 d0;
    uint8 d1;
    FloatQueueHook hook;
    PoolKey k;
    uint256 hookBase0;
    uint256 hookBase1;

    function setUp() public {
        deployArtifactsAndLabel();
        MockERC20 ta = _mk(18);
        MockERC20 tb = _mk(6);
        (MockERC20 lo_, MockERC20 hi_) = ta < tb ? (ta, tb) : (tb, ta);
        c0 = Currency.wrap(address(lo_));
        c1 = Currency.wrap(address(hi_));
        d0 = lo_.decimals();
        d1 = hi_.decimals();
        vm.roll(100);
    }

    function _mk(uint8 dec) internal returns (MockERC20 t) {
        t = new MockERC20("T", "T", dec);
        t.mint(address(this), 10_000_000 * 10 ** dec);
        t.approve(address(permit2), type(uint256).max);
        t.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(t), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(t), address(poolManager), type(uint160).max, type(uint48).max);
    }

    /// @dev sqrtPriceX96 for a HUMAN price of 1 whole token0 == 4 whole token1, given the two
    ///      decimal counts. NEVER 1:1, and never unit-decimalled either.
    function _sqrtPrice() internal view returns (uint160) {
        if (d1 >= d0) {
            return uint160((uint256(2) * (10 ** ((uint256(d1) - d0) / 2))) << 96);
        }
        return uint160((uint256(1) << 96) / (uint256(2) * (10 ** ((uint256(d0) - d1) / 2))));
    }

    function test_X1_floatWithdrawSurvivesUnequalDecimals() public {
        emit log_named_uint("token0 decimals", d0);
        emit log_named_uint("token1 decimals", d1);
        assertTrue(d0 != d1, "fixture is not asymmetric");

        address a = address(FLAGS ^ (uint160(0x3101) << 144));
        deployCodeTo("FloatWithdraw.t.sol:FloatQueueHook", abi.encode(poolManager, uint8(3)), a);
        hook = FloatQueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 20_000_000 * 10 ** d0);
        MockERC20(Currency.unwrap(c1)).mint(a, 20_000_000 * 10 ** d1);

        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, _sqrtPrice()); // human 1:4, NEVER 1:1
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        emit log_named_uint("seeded token0 (raw)", s0);
        emit log_named_uint("seeded token1 (raw)", s1);
        require(s0 != s1, "fixture is unit-priced");
        hookBase0 = MockERC20(Currency.unwrap(c0)).balanceOf(a);
        hookBase1 = MockERC20(Currency.unwrap(c1)).balanceOf(a);

        // the spike's swap profile, scaled: 0.2%, 15%, 2.5% of the token0 reserve, then 4% of
        // the token1 reserve back the other way. Drives the head to full conversion.
        _swap(true, s0 / 500);
        _swap(true, s0 * 15 / 100);
        _swap(true, s0 * 25 / 1000);
        _swap(false, s1 * 4 / 100);

        for (uint256 i; i < 3; i++) {
            (uint256 x0, uint256 x1) = hook.entry(i);
            emit log_named_uint("seat", i);
            emit log_named_uint("   a0", x0);
            emit log_named_uint("   a1", x1);
        }

        // find a fully-converted seat if one exists; otherwise use the head.
        uint256 target = 0;
        for (uint256 i; i < 3; i++) {
            (uint256 x0, uint256 x1) = hook.entry(i);
            if ((x0 == 0) != (x1 == 0)) {
                target = i;
                break;
            }
        }
        (uint256 t0, uint256 t1) = hook.entry(target);
        emit log_named_uint("TARGET seat", target);
        uint256 p0b = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 p1b = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        (uint256 paid0_, uint256 paid1_) = hook.withdraw(target, t0, t1);
        assertEq(paid0_, t0, "asym: token0 leg not paid exactly");
        assertEq(paid1_, t1, "asym: token1 leg not paid exactly");
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(this)) - p0b, t0, "asym: token0 did not arrive");
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - p1b, t1, "asym: token1 did not arrive");
        emit log_named_uint("float0 after", hook.float0());
        emit log_named_uint("float1 after", hook.float1());
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(hook)) - hookBase0, hook.float0(), "asym float0");
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(hook)) - hookBase1, hook.float1(), "asym float1");

        // then drain the rest
        for (uint256 i; i < 3; i++) {
            (uint256 x0, uint256 x1) = hook.entry(i);
            if (x0 == 0 && x1 == 0) continue;
            hook.withdraw(i, x0, x1);
            assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(hook)) - hookBase0, hook.float0(), "asym f0");
            assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(hook)) - hookBase1, hook.float1(), "asym f1");
        }
        (uint256 lft0, uint256 lft1) = hook.totals();
        emit log_named_uint("LEFTOVER ledger dust token0", lft0);
        emit log_named_uint("LEFTOVER ledger dust token1", lft1);
        assertLe(lft0, 8, "asym: leftover token0 exceeds rounding residual");
        assertLe(lft1, 8, "asym: leftover token1 exceeds rounding residual");
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, k, "", address(this), block.timestamp);
    }
}
