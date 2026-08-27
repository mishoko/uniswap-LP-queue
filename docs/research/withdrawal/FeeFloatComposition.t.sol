// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// RESEARCH ARTEFACT — settles PITFALLS §5.22: the P2 netted allocator (protocol-fee remedy,
// owner decision 2026-08-26) and the two-slot shared FLOAT withdraw have never been exercised
// together. Every withdrawal test ran at protocolFeesAccrued == 0 (asserted); every protocol-fee
// test ran without the float.
//
//   FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/withdrawal \
//     forge test --match-path "docs/research/withdrawal/FeeFloatComposition.t.sol" -vv
//
// The hook below is a COPY of docs/research/withdrawal/FloatWithdraw.t.sol's FloatQueueHook
// (float0/float1 + withdraw() + the wmode mutations, character-for-character) plus the ONE
// behavioural change from archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol's
// PFQueueHookNetted: the P2 netting block in _allocate. Neither source file is modified.
//
// THE CENTRAL QUESTION: does INVARIANT F — sum(q[i].aX) == redeemable X + floatX — still hold
// with a nonzero protocol fee, measured under LAW 3 AS AMENDED (PoolManager balance MINUS
// protocolFeesAccrued, plus the float)? And does the residual stay at dust, or scale with the fee?

import {BaseTest} from "../../../archive/2026-08-26/test/utils/BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract FeeFloatQueueHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;

    // withdraw modes — IDENTICAL to FloatWithdraw.t.sol.
    uint8 constant W_OK = 0;
    uint8 constant W_FLOAT_OFF_BY_ONE = 1;
    uint8 constant W_WRONG_CURRENCY = 2;
    uint8 constant W_F1_SETTLE_ACTUAL = 3; // PLAN §B.7 (F1): pay min(face, available)
    uint8 constant W_MIN_LEG = 4;

    // allocator modes.
    uint8 constant N_P2_NETTED = 0; // the owner's 2026-08-26 decision
    uint8 constant N_NO_NETTING = 1; // MUTATION: P2 removed, float + fee kept

    uint8 public immutable wmode;
    uint8 public immutable nmode;

    struct Entry {
        uint256 a0;
        uint256 a1;
    }

    Entry[] public q;

    PoolKey public key;
    int24 public tl;
    int24 public tu;
    uint128 public liq;

    uint256 public float0;
    uint256 public float1;

    uint256 public paid0;
    uint256 public paid1;
    uint256 public lastWithdrawGas;
    uint256 public lastPulledLiquidity;

    uint256 public lastAllocGas;
    uint256 public entriesTouched;

    // P2 state: last-seen protocolFeesAccrued, per currency.
    uint256 public pfSeen0;
    uint256 public pfSeen1;
    uint256 public lastPfDelta;
    uint256 public cumNetted;

    error QueueUnderflow(uint256 shortfall);
    error OverEntitlement(uint256 want, uint256 have);
    error FloatShort(uint256 want, uint256 have);

    constructor(IPoolManager pm, uint8 wmode_, uint8 nmode_) BaseHook(pm) {
        wmode = wmode_;
        nmode = nmode_;
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
    //                                    (character-for-character from FloatWithdraw.t.sol)

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

    function liquidityToCover(uint256 need0, uint256 need1) external view returns (uint128) {
        return _liquidityToCover(need0, need1);
    }

    function _liquidityToCover(uint256 need0, uint256 need1) internal view returns (uint128) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint160 lo = TickMath.getSqrtPriceAtTick(tl);
        uint160 hi = TickMath.getSqrtPriceAtTick(tu);
        uint128 l0 = need0 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount0(sqrtP, hi, need0);
        uint128 l1 = need1 == 0 ? 0 : LiquidityAmounts.getLiquidityForAmount1(lo, sqrtP, need1);
        uint256 d = wmode == W_MIN_LEG ? (l0 < l1 ? l0 : l1) : (l0 > l1 ? l0 : l1);
        if (d != 0) d += 1;
        if (d > liq) d = liq;
        return uint128(d);
    }

    // ------------------------------------------------------------------ the allocator + P2

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

        // >>>>>>>>>>>>>>>>>>>>> PLAN §E.5 option P2, owner decision 2026-08-26 <<<<<<<<<<<<<<<<<<
        // Net the protocol fee PoolManager actually skimmed on THIS swap out of `amtIn`, so the
        // ledger credits only what the position actually received. _updateProtocolFees has ONE
        // call site (PoolManager.sol:238, inside _swap) and it runs BEFORE afterSwap (:221), so
        // the diff is readable here and is wei-exact. Verified in source, not assumed.
        if (nmode == N_P2_NETTED) {
            uint256 pfNow = outIsOne
                ? poolManager.protocolFeesAccrued(key.currency0)
                : poolManager.protocolFeesAccrued(key.currency1);
            uint256 seen = outIsOne ? pfSeen0 : pfSeen1;
            uint256 pfDelta = pfNow - seen;
            if (outIsOne) pfSeen0 = pfNow;
            else pfSeen1 = pfNow;
            lastPfDelta = pfDelta;
            cumNetted += pfDelta;
            amtIn -= pfDelta;
        }
        // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

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

contract FeeFloatCompositionTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant LP_FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint128 constant LIQ = 1_000e18;
    address constant PM_OWNER = address(0x4444); // Deployers.sol: V4PoolManagerDeployer.deploy(0x4444)
    uint256 constant DUST = 8; // the §E.4 residual bound the float suite asserts

    Currency c0;
    Currency c1;
    FeeFloatQueueHook hook;
    PoolKey k;

    uint24 pfee;
    bool netting;

    // GROSS PoolManager-measured flows (LAW 3), and the protocol fee inside them.
    uint256 expT0;
    uint256 expT1;
    uint256 cumPf0;
    uint256 cumPf1;

    uint256 hookBase0;
    uint256 hookBase1;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        vm.roll(100);
    }

    // ------------------------------------------------------------------ fixture

    function _maxPacked() internal pure returns (uint24) {
        uint24 m = uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE);
        return m | (m << 12); // (1000 << 12) | 1000
    }

    function _deploy(uint8 wmode, uint8 nmode, uint160 nonce) internal returns (FeeFloatQueueHook h) {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("FeeFloatComposition.t.sol:FeeFloatQueueHook", abi.encode(poolManager, wmode, nmode), a);
        h = FeeFloatQueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 100_000e18);
        MockERC20(Currency.unwrap(c1)).mint(a, 100_000e18);
    }

    /// @dev Owner -> controller -> setProtocolFee. A silently-ignored setProtocolFee would make
    ///      the whole experiment void, so both legs are asserted against slot0 afterwards.
    function _applyProtocolFee(PoolKey memory key_, uint24 fee) internal {
        vm.prank(PM_OWNER);
        poolManager.setProtocolFeeController(address(this));
        require(poolManager.protocolFeeController() == address(this), "controller not set");
        poolManager.setProtocolFee(key_, fee);
        (,, uint24 got,) = poolManager.getSlot0(key_.toId());
        require(got == fee, "setProtocolFee SILENTLY NO-OPPED: experiment void");
    }

    /// @dev The float spike's exact fixture: 1:4 price, three seats 400/600/9000 bps, four swaps.
    ///      Plus a protocol fee, applied and verified before the first swap.
    function _scenario(uint8 wmode, uint8 nmode, uint24 fee, uint160 nonce) internal {
        pfee = fee;
        netting = nmode == 0;
        hook = _deploy(wmode, nmode, nonce);
        k = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4); // 1:4, NEVER 1:1 (LAW 1)
        if (fee != 0) _applyProtocolFee(k, fee);

        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        require(s0 != s1, "fixture is unit-priced");
        expT0 = s0;
        expT1 = s1;
        cumPf0 = poolManager.protocolFeesAccrued(c0);
        cumPf1 = poolManager.protocolFeesAccrued(c1);
        require(cumPf0 == 0 && cumPf1 == 0, "protocol fee accrued before any swap");
        hookBase0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(hook));
        hookBase1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(hook));

        _swap(true, 4e18);
        _swap(true, 300e18);
        _swap(true, 50e18);
        _swap(false, 20e18);

        if (fee != 0) {
            // (0) if this fails, NOTHING below means anything.
            require(cumPf0 > 0, "protocolFeesAccrued(c0) == 0: fee never applied, experiment VOID");
            require(cumPf1 > 0, "protocolFeesAccrued(c1) == 0: reverse leg took no fee, VOID");
        }
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        uint256 p0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 p1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        uint256 f0 = poolManager.protocolFeesAccrued(c0);
        uint256 f1 = poolManager.protocolFeesAccrued(c1);
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, k, "", address(this), block.timestamp);
        uint256 n0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 n1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        cumPf0 += poolManager.protocolFeesAccrued(c0) - f0;
        cumPf1 += poolManager.protocolFeesAccrued(c1) - f1;
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

    function _assertFloatIsReal(string memory tag) internal view {
        uint256 h0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(hook)) - hookBase0;
        uint256 h1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(hook)) - hookBase1;
        assertEq(h0, hook.float0(), string.concat(tag, ": float0 not backed by real token0"));
        assertEq(h1, hook.float1(), string.concat(tag, ": float1 not backed by real token1"));
    }

    /// @dev LEDGER CONSERVATION against PoolManager's own balances, NET of protocol fees when the
    ///      allocator nets them (P2), GROSS when it does not (the mutation).
    function _assertLedgerConserved(string memory tag) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        uint256 e0 = netting ? expT0 - cumPf0 : expT0;
        uint256 e1 = netting ? expT1 - cumPf1 : expT1;
        assertEq(t0 + hook.paid0(), e0, string.concat(tag, ": token0 ledger conservation"));
        assertEq(t1 + hook.paid1(), e1, string.concat(tag, ": token1 ledger conservation"));
    }

    /// @dev INVARIANT F, LAW-3-AMENDED FORM: sum(q[i].aX) == (PM balance - protocolFeesAccrued) + floatX.
    ///      Returns the signed slack (backing - ledger) for both tokens so it can be REPORTED, not
    ///      just asserted.
    function _invariantF() internal view returns (int256 s0, int256 s1) {
        (uint256 t0, uint256 t1) = hook.totals();
        s0 = int256(_pmBacking(c0) + hook.float0()) - int256(t0);
        s1 = int256(_pmBacking(c1) + hook.float1()) - int256(t1);
    }

    function _assertInvariantF(string memory tag) internal {
        (int256 s0, int256 s1) = _invariantF();
        emit log_named_int(string.concat("  INV-F slack t0 (backing-ledger) ", tag), s0);
        emit log_named_int(string.concat("  INV-F slack t1 (backing-ledger) ", tag), s1);
        assertGe(s0, 0, string.concat(tag, ": INVARIANT F BROKEN - INSOLVENT on token0"));
        assertGe(s1, 0, string.concat(tag, ": INVARIANT F BROKEN - INSOLVENT on token1"));
        assertLe(uint256(s0), DUST, string.concat(tag, ": INVARIANT F residual token0 exceeds v4 dust"));
        assertLe(uint256(s1), DUST, string.concat(tag, ": INVARIANT F residual token1 exceeds v4 dust"));
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }

    function _strip(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = err[i + 4];
        }
    }

    // ==========================================================================================
    // P0 — THE INSTRUMENT. The fee is real, maximal, and packed both directions.
    // ==========================================================================================
    function test_P0_maxLegalProtocolFeeIsActuallyOn() public {
        assertEq(uint256(ProtocolFeeLibrary.MAX_PROTOCOL_FEE), 1000, "MAX_PROTOCOL_FEE moved; re-read source");
        uint24 packed = _maxPacked();
        assertEq(uint256(packed), (uint256(1000) << 12) | 1000, "packing is not (1000<<12)|1000");
        assertEq(uint256(ProtocolFeeLibrary.getZeroForOneFee(packed)), 1000, "zeroForOne leg not at max");
        assertEq(uint256(ProtocolFeeLibrary.getOneForZeroFee(packed)), 1000, "oneForZero leg not at max");

        _scenario(3, 0, packed, 0x4101);

        (,, uint24 onChain,) = poolManager.getSlot0(k.toId());
        assertEq(uint256(onChain), uint256(packed), "slot0 does not carry the fee we set");
        emit log_named_uint("protocolFeesAccrued(c0) after 4 swaps (wei)", cumPf0);
        emit log_named_uint("protocolFeesAccrued(c1) after 4 swaps (wei)", cumPf1);
        emit log_named_uint("hook cumulative NETTED out of amtIn      (wei)", hook.cumNetted());
        assertGt(cumPf0, 0, "protocolFeesAccrued(c0) == 0 - EXPERIMENT VOID");
        assertGt(cumPf1, 0, "protocolFeesAccrued(c1) == 0 - EXPERIMENT VOID");
        // and P2 netted EXACTLY what v4 skimmed, wei for wei.
        assertEq(hook.cumNetted(), cumPf0 + cumPf1, "P2 netted a different amount than v4 skimmed");
        // the fee is 15 orders of magnitude above the dust residual.
        assertGt(cumPf0, 1e14, "fee is dust-sized: not a real stress test");
    }

    // ==========================================================================================
    // P1 — THE CENTRAL QUESTION. INVARIANT F under a MAXIMUM protocol fee, three ways:
    //      (a) balance form, before any withdrawal
    //      (b) balance form, with the float ENGAGED
    //      (c) DESTRUCTIVE form: redeemAll() + float vs the ledger (the honest one)
    // ==========================================================================================
    function test_P1_invariantF_survivesMaxProtocolFee() public {
        _scenario(3, 0, _maxPacked(), 0x4202);

        (uint256 t0, uint256 t1) = hook.totals();
        emit log_named_uint("ledger t0                     ", t0);
        emit log_named_uint("ledger t1                     ", t1);
        emit log_named_uint("PM raw balance c0             ", MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)));
        emit log_named_uint("protocolFeesAccrued c0        ", poolManager.protocolFeesAccrued(c0));
        emit log_named_uint("PM backing c0 (raw - pfee)    ", _pmBacking(c0));
        _assertInvariantF("P1/pre-withdraw");

        // engage the float: the fully-converted seat withdraws first.
        (uint256 a0, uint256 a1) = hook.entry(1);
        assertEq(a1, 0, "fixture: seat1 must be fully converted under the fee too");
        emit log_named_uint("seat1 ledger a0 (fee ON)      ", a0);
        hook.withdraw(1, a0, a1);
        assertGt(hook.float1(), 0, "no token1 float was created: the mechanism did not engage");
        _assertFloatIsReal("P1");
        _assertLedgerConserved("P1");
        _assertInvariantF("P1/float-engaged");

        // (c) THE DESTRUCTIVE MEASUREMENT. Burn what is left, add the float, compare to the ledger.
        (t0, t1) = hook.totals();
        (uint256 g0, uint256 g1) = hook.redeemAll();
        uint256 have0 = g0 + hook.float0();
        uint256 have1 = g1 + hook.float1();
        emit log_named_uint("REDEEMED t0 + float0          ", have0);
        emit log_named_uint("ledger t0                     ", t0);
        emit log_named_int("RESIDUAL t0 (have - ledger)   ", int256(have0) - int256(t0));
        emit log_named_uint("REDEEMED t1 + float1          ", have1);
        emit log_named_uint("ledger t1                     ", t1);
        emit log_named_int("RESIDUAL t1 (have - ledger)   ", int256(have1) - int256(t1));
        emit log_named_uint("protocolFeesAccrued c0 (for scale)", cumPf0);
        assertLe(have0, t0, "position redeemed MORE than the ledger claims: re-derive E.4");
        assertLe(have1, t1, "position redeemed MORE than the ledger claims: re-derive E.4");
        assertLe(t0 - have0, DUST, "INVARIANT F residual token0 GREW with the protocol fee");
        assertLe(t1 - have1, DUST, "INVARIANT F residual token1 GREW with the protocol fee");
    }

    // ==========================================================================================
    // P2 — ALL SEATS WITHDRAW, in the four adversarial orders the float suite used, fee ON.
    // ==========================================================================================
    function _drain(uint256[3] memory order, string memory tag) internal returns (uint256 d0, uint256 d1) {
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
            emit log_named_uint("     SHORT a0 ", a0 - p0);
            emit log_named_uint("     SHORT a1 ", a1 - p1);
            assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(this)) - b0, p0, "token0 did not arrive");
            assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - b1, p1, "token1 did not arrive");
            _assertFloatIsReal(tag);
            _assertLedgerConserved(tag);
            _assertInvariantF(tag);
        }
        (d0, d1) = hook.totals();
    }

    function _drainOrder(uint256[3] memory order, uint160 nonce, string memory tag) internal {
        _scenario(3, 0, _maxPacked(), nonce); // F1 dust policy, P2 netting, MAX fee
        (uint256 d0, uint256 d1) = _drain(order, tag);
        emit log_named_uint("LEFTOVER ledger dust token0   ", d0);
        emit log_named_uint("LEFTOVER ledger dust token1   ", d1);
        emit log_named_uint("protocolFeesAccrued c0 (scale)", cumPf0);
        assertLe(d0, DUST, string.concat(tag, ": leftover token0 exceeds v4 rounding residual"));
        assertLe(d1, DUST, string.concat(tag, ": leftover token1 exceeds v4 rounding residual"));
        assertLe(hook.float0(), DUST, string.concat(tag, ": float0 stranded"));
        assertLe(hook.float1(), DUST, string.concat(tag, ": float1 stranded"));
        _assertFloatIsReal(tag);
        _assertLedgerConserved(tag);
    }

    function test_P2a_allSeats_convertedFIRST() public {
        _drainOrder([uint256(1), 0, 2], 0x4303, "fee/order[1,0,2]");
    }

    function test_P2b_allSeats_convertedLAST() public {
        _drainOrder([uint256(0), 2, 1], 0x4404, "fee/order[0,2,1]");
    }

    function test_P2c_allSeats_reverse() public {
        _drainOrder([uint256(2), 1, 0], 0x4505, "fee/order[2,1,0]");
    }

    function test_P2d_allSeats_inOrder() public {
        _drainOrder([uint256(0), 1, 2], 0x4606, "fee/order[0,1,2]");
    }

    function test_P2e_interleavedWithSwaps() public {
        _scenario(3, 0, _maxPacked(), 0x4707);
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        _assertInvariantF("interleave/w1");
        _swap(true, 25e18);
        _assertLedgerConserved("interleave/s1");
        _assertInvariantF("interleave/s1");
        _swap(false, 10e18);
        _assertLedgerConserved("interleave/s2");
        _assertInvariantF("interleave/s2");

        (uint256 b0, uint256 b1) = hook.entry(0);
        hook.withdraw(0, b0 / 2, b1 / 2);
        _assertInvariantF("interleave/w0partial");
        (uint256 r0, uint256 r1) = hook.entry(0);
        assertEq(r0, b0 - b0 / 2, "partial withdraw debited the wrong token0 amount");
        assertEq(r1, b1 - b1 / 2, "partial withdraw debited the wrong token1 amount");

        _swap(true, 5e18);
        _assertInvariantF("interleave/s3");

        (uint256 d0, uint256 d1) = _drain([uint256(0), 2, 1], "interleave/drain");
        emit log_named_uint("LEFTOVER ledger dust token0   ", d0);
        emit log_named_uint("LEFTOVER ledger dust token1   ", d1);
        emit log_named_uint("protocolFeesAccrued c0 (scale)", cumPf0);
        assertLe(d0, 16, "leftover token0 exceeds residual after 7 swaps");
        assertLe(d1, 16, "leftover token1 exceeds residual after 7 swaps");
    }

    // ==========================================================================================
    // P3 — THE DUST POLICY under a nonzero fee. Does the last withdrawer still lose 3-8 wei, or
    //      does the shortfall become material (fee-sized)?
    // ==========================================================================================
    function test_P3a_dustPolicyExactPayout_lastWithdrawerUnderMaxFee() public {
        // W_OK: EXACT payout, no F1 truncation - the last withdrawer must REVERT rather than be
        // silently short-paid, and the revert amount IS the dust measurement.
        _scenario(0, 0, _maxPacked(), 0x4808);
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        (a0, a1) = hook.entry(0);
        hook.withdraw(0, a0, a1);
        (a0, a1) = hook.entry(2);
        emit log_named_uint("last seat face a0             ", a0);
        emit log_named_uint("last seat face a1             ", a1);
        emit log_named_uint("float0 available              ", hook.float0());
        emit log_named_uint("float1 available              ", hook.float1());
        (bool ok, bytes memory err) = address(hook).call(abi.encodeWithSelector(hook.withdraw.selector, 2, a0, a1));
        emit log_named_string("last withdrawal succeeded?", ok ? "YES" : "NO");
        if (!ok) {
            assertEq(bytes4(err), FeeFloatQueueHook.FloatShort.selector, "reverted for the WRONG reason");
            (uint256 want, uint256 have) = abi.decode(_strip(err), (uint256, uint256));
            emit log_named_uint("  FloatShort want             ", want);
            emit log_named_uint("  FloatShort have             ", have);
            emit log_named_uint("  SHORTFALL (wei)             ", want - have);
            emit log_named_uint("  protocolFeesAccrued (scale) ", cumPf0);
            assertLe(want - have, DUST, "SHORTFALL IS FEE-SIZED, not dust: the dust policy does NOT survive");
        }

    }

    /// @dev the F1 half of the dust question, in its own test (protocolFeesAccrued is a GLOBAL
    ///      counter, so two scenarios cannot share one test).
    function test_P3b_dustPolicyF1_lastWithdrawerUnderMaxFee() public {
        _scenario(3, 0, _maxPacked(), 0x4809);
        (uint256 d0, uint256 d1) = _drain([uint256(1), 0, 2], "P3/F1");
        emit log_named_uint("F1 leftover ledger dust t0    ", d0);
        emit log_named_uint("F1 leftover ledger dust t1    ", d1);
        emit log_named_uint("protocolFeesAccrued c0 (scale)", cumPf0);
        assertLe(d0, DUST, "F1 shortfall on token0 is material, not dust");
        assertLe(d1, DUST, "F1 shortfall on token1 is material, not dust");
    }

    // ==========================================================================================
    // P4 — ORDERING. Does a withdrawal (modifyLiquidity + take) move protocolFeesAccrued? If it
    //      did, the P2 snapshot would have to be ordered against the float bookkeeping.
    //      PoolManager.sol:238 says no. This asserts it by EXECUTION.
    // ==========================================================================================
    function test_P4_ordering_withdrawDoesNotAccrueProtocolFees() public {
        _scenario(3, 0, _maxPacked(), 0x490A);
        uint256 f0 = poolManager.protocolFeesAccrued(c0);
        uint256 f1 = poolManager.protocolFeesAccrued(c1);
        uint256 seen0 = hook.pfSeen0();
        uint256 seen1 = hook.pfSeen1();

        vm.recordLogs();
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        (a0, a1) = hook.entry(2);
        hook.withdraw(2, a0 / 2, a1 / 2);
        hook.redeemAll();

        assertEq(poolManager.protocolFeesAccrued(c0), f0, "a withdrawal MOVED protocolFeesAccrued(c0)");
        assertEq(poolManager.protocolFeesAccrued(c1), f1, "a withdrawal MOVED protocolFeesAccrued(c1)");
        assertEq(hook.pfSeen0(), seen0, "withdrawal touched the P2 snapshot");
        assertEq(hook.pfSeen1(), seen1, "withdrawal touched the P2 snapshot");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == IPoolManager.Swap.selector) swaps++;
        }
        assertGt(logs.length, 0, "recorded nothing: the check would pass vacuously");
        assertEq(swaps, 0, "withdraw() called poolManager.swap - PITFALLS 5.6 violated");
        emit log_named_uint("PoolManager Swap events during withdrawals", swaps);
    }

    // ==========================================================================================
    // NC-1 — REMOVE P2, KEEP THE FLOAT AND THE FEE. The suite MUST go red, by a fee-sized amount.
    // ==========================================================================================
    function test_NC1_nettingRemoved_goesRed() public {
        _scenario(0, 1, _maxPacked(), 0x4A0B); // W_OK, N_NO_NETTING, MAX fee
        assertEq(hook.cumNetted(), 0, "the mutation still netted something");

        // (1) INVARIANT F is broken BEFORE anyone withdraws, by exactly the accrued protocol fee.
        (int256 s0, int256 s1) = _invariantF();
        emit log_named_int("NC1 INV-F slack t0 (backing-ledger)", s0);
        emit log_named_int("NC1 INV-F slack t1 (backing-ledger)", s1);
        emit log_named_uint("NC1 protocolFeesAccrued c0        ", cumPf0);
        emit log_named_uint("NC1 protocolFeesAccrued c1        ", cumPf1);
        assertLt(s0, 0, "NC1: token0 not insolvent - the control proves nothing");
        assertLt(s1, 0, "NC1: token1 not insolvent - the control proves nothing");
        assertEq(uint256(-s0), cumPf0, "NC1: the token0 insolvency is NOT exactly the protocol fee");
        assertEq(uint256(-s1), cumPf1, "NC1: the token1 insolvency is NOT exactly the protocol fee");
        assertGt(uint256(-s0), 1e14, "NC1: insolvency is dust-sized");

        // (2) and the seats find out: the last withdrawer is FloatShort by a fee-sized amount.
        (uint256 a0, uint256 a1) = hook.entry(1);
        hook.withdraw(1, a0, a1);
        (a0, a1) = hook.entry(0);
        hook.withdraw(0, a0, a1);
        (a0, a1) = hook.entry(2);
        (bool ok, bytes memory err) = address(hook).call(abi.encodeWithSelector(hook.withdraw.selector, 2, a0, a1));
        assertFalse(ok, "NC1: the un-netted allocator paid everyone in full - P2 is not load-bearing");
        assertEq(bytes4(err), FeeFloatQueueHook.FloatShort.selector, "NC1 went red for the WRONG reason");
        (uint256 want, uint256 have) = abi.decode(_strip(err), (uint256, uint256));
        emit log_named_uint("NC1 FloatShort want           ", want);
        emit log_named_uint("NC1 FloatShort have           ", have);
        emit log_named_uint("NC1 SHORTFALL (wei)           ", want - have);
        emit log_named_uint("NC1 shortfall / DUST bound    ", (want - have) / DUST);
        assertGt(want - have, DUST, "NC1: shortfall is within v4 dust - P2 changed nothing");
        assertGt(want - have, 1e14, "NC1: shortfall is not fee-sized");
    }

    /// @dev NC-1b: LAW 5. Prove the INVARIANT F assertion that P1/P2 rely on CAN fail. Same
    ///      assertion, same fixture, P2 removed -> it must go RED.
    function callAssertInvariantF() external {
        _assertInvariantF("mutation");
    }

    function test_NC1b_theInvariantFAssertionIsLoadBearing() public {
        _scenario(3, 1, _maxPacked(), 0x4A1C); // F1 dust policy, NO NETTING, MAX fee
        vm.expectRevert();
        this.callAssertInvariantF();
    }

    /// @dev NC-1c: with P2 removed and the F1 dust policy on, nobody reverts - the loss is
    ///      SILENT and lands on whoever withdraws last. Measure it against the protocol fee.
    function test_NC1c_nettingRemoved_F1_silentlyStripsTheLastWithdrawers() public {
        _scenario(3, 1, _maxPacked(), 0x4A2D);
        uint256[3] memory order = [uint256(1), 0, 2];
        for (uint256 j; j < 3; j++) {
            uint256 i = order[j];
            (uint256 a0, uint256 a1) = hook.entry(i);
            (uint256 p0, uint256 p1) = hook.withdraw(i, a0, a1);
            emit log_named_uint("  seat            ", i);
            emit log_named_uint("     SHORT-PAID t0", a0 - p0);
            emit log_named_uint("     SHORT-PAID t1", a1 - p1);
        }
        (uint256 d0, uint256 d1) = hook.totals();
        emit log_named_uint("NC1c leftover UNPAID ledger t0", d0);
        emit log_named_uint("NC1c leftover UNPAID ledger t1", d1);
        emit log_named_uint("NC1c protocolFeesAccrued c0   ", cumPf0);
        emit log_named_uint("NC1c protocolFeesAccrued c1   ", cumPf1);
        emit log_named_uint("NC1c unpaid / the 8-wei bound ", (d0 + d1) / DUST);
        assertGt(d0 + d1, DUST, "NC1c: removing P2 cost nobody anything - P2 is not load-bearing");
        // and the loss is the protocol fee, to within v4 dust.
        assertLe(_abs(int256(d0) - int256(cumPf0)), int256(DUST), "NC1c: token0 loss is not the protocol fee");
        assertLe(_abs(int256(d1) - int256(cumPf1)), int256(DUST), "NC1c: token1 loss is not the protocol fee");
    }

    // ==========================================================================================
    // NC-2 — protocolFee = 0 WITH the float. The composition must reproduce the existing float
    //        suite EXACTLY: same seat-1 ledger, same post-withdrawal liquidity, same dust.
    // ==========================================================================================
    function test_NC2_zeroProtocolFee_reproducesTheFloatSuiteExactly() public {
        _scenario(3, 0, 0, 0x4B0C);
        assertEq(poolManager.protocolFeesAccrued(c0), 0, "control leaked a protocol fee in token0");
        assertEq(poolManager.protocolFeesAccrued(c1), 0, "control leaked a protocol fee in token1");
        assertEq(hook.cumNetted(), 0, "P2 netted something at fee 0");

        // FloatWithdraw.t.sol test_R1's recorded number, to the wei.
        (uint256 a0, uint256 a1) = hook.entry(1);
        assertEq(a0, 258877453809749247723, "seat1 a0 differs from FloatWithdraw.t.sol test_R1");
        assertEq(a1, 0, "seat1 is not fully converted");

        // FloatWithdraw.t.sol test_ATK_2's recorded post-withdrawal liquidity, to the wei.
        hook.withdraw(1, a0, a1);
        assertEq(hook.liq(), 884814917170750529333, "post-withdrawal liquidity differs from ATK_2");
        _assertFloatIsReal("NC2");
        _assertLedgerConserved("NC2");
        _assertInvariantF("NC2");

        (uint256 d0, uint256 d1) = _drain([uint256(0), 2], "NC2/drain");
        emit log_named_uint("NC2 leftover ledger dust t0   ", d0);
        emit log_named_uint("NC2 leftover ledger dust t1   ", d1);
        assertLe(d0, DUST, "NC2: leftover token0 exceeds the float suite's bound");
        assertLe(d1, DUST, "NC2: leftover token1 exceeds the float suite's bound");
    }

    /// @dev two-seat drain helper (seat 1 already withdrawn)
    function _drain(uint256[2] memory order, string memory tag) internal returns (uint256 d0, uint256 d1) {
        for (uint256 j; j < 2; j++) {
            uint256 i = order[j];
            (uint256 a0, uint256 a1) = hook.entry(i);
            hook.withdraw(i, a0, a1);
            _assertFloatIsReal(tag);
            _assertLedgerConserved(tag);
            _assertInvariantF(tag);
        }
        (d0, d1) = hook.totals();
    }

    // ==========================================================================================
    // NC-3 — a withdrawer still cannot exceed its entitlement with the fee ON.
    // ==========================================================================================
    function test_NC3_cannotExceedEntitlement_feeOn() public {
        _scenario(0, 0, _maxPacked(), 0x4C0D);
        (uint256 a0, uint256 a1) = hook.entry(1);
        vm.expectRevert(abi.encodeWithSelector(FeeFloatQueueHook.OverEntitlement.selector, a0 + 1, a0));
        hook.withdraw(1, a0 + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(FeeFloatQueueHook.OverEntitlement.selector, uint256(1), a1));
        hook.withdraw(1, 0, 1);

        hook.withdraw(1, a0, a1);
        vm.expectRevert(abi.encodeWithSelector(FeeFloatQueueHook.OverEntitlement.selector, uint256(1), uint256(0)));
        hook.withdraw(1, 1, 0);

        assertGt(hook.float1(), 0, "no float to attack");
        (uint256 b0, uint256 b1) = hook.entry(0);
        vm.expectRevert(abi.encodeWithSelector(FeeFloatQueueHook.OverEntitlement.selector, b1 + 1, b1));
        hook.withdraw(0, b0, b1 + 1);

        // and the queue as a whole cannot reach the protocol's money: drain everything and check
        // PoolManager still backs protocolFeesAccrued in full.
        _assertInvariantF("NC3");
        hook.redeemAll();
        emit log_named_uint("PM raw balance c0 after full teardown", MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)));
        emit log_named_uint("protocolFeesAccrued c0               ", poolManager.protocolFeesAccrued(c0));
        assertGe(
            MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)),
            poolManager.protocolFeesAccrued(c0),
            "the queue drained PoolManager below its protocol-fee obligation"
        );
        assertGe(
            MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager)),
            poolManager.protocolFeesAccrued(c1),
            "the queue drained PoolManager below its protocol-fee obligation"
        );
    }

    // ==========================================================================================
    // G1 — GAS, cold, versus the float-only baseline of 252,672.
    // ==========================================================================================
    function test_G1_gasOfTheFloatWithdrawUnderAProtocolFee() public {
        _scenario(3, 0, _maxPacked(), 0x4D0E);
        vm.cool(address(hook));
        vm.cool(address(poolManager));
        vm.cool(Currency.unwrap(c0));
        vm.cool(Currency.unwrap(c1));
        (uint256 a0, uint256 a1) = hook.entry(1);
        uint256 g = gasleft();
        hook.withdraw(1, a0, a1);
        uint256 total = g - gasleft();
        emit log_named_uint("HARD CASE withdraw gas, fee ON (cold, incl. call overhead)", total);
        emit log_named_uint("float-only baseline (FloatWithdraw.t.sol test_G1)         ", 252672);
        emit log_named_int("GAS DELTA vs the float-only baseline                      ", int256(total) - int256(252672));
        emit log_named_uint("allocator gas last swap (P2 SLOAD included)               ", hook.lastAllocGas());
    }

    // ==========================================================================================
    // X — A SEPARATE, FLOAT-INDEPENDENT DEFECT IN P2 ITSELF: protocolFeesAccrued is a GLOBAL
    //     per-currency counter, not per-pool. Any OTHER v4 pool sharing a currency corrupts the
    //     diff. This is not a composition failure; it is a P2 failure the composition surfaces.
    // ==========================================================================================
    function _openForeignPool(uint160 nonce) internal returns (FeeFloatQueueHook hb, PoolKey memory kb) {
        hb = _deploy(3, 0, nonce);
        kb = PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hb))});
        poolManager.initialize(kb, Constants.SQRT_PRICE_1_4);
        _applyProtocolFee(kb, _maxPacked());
        uint256[] memory bps = new uint256[](1);
        bps[0] = 10_000;
        hb.seed(kb, TickMath.minUsableTick(10), TickMath.maxUsableTick(10), LIQ, bps);
    }

    function test_X1_foreignPoolSharingACurrencyCorruptsTheP2Diff() public {
        // our pool, with the fee on, but NO swaps yet.
        pfee = _maxPacked();
        netting = true;
        hook = _deploy(3, 0, 0x4E0F);
        k = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        _applyProtocolFee(k, pfee);
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        expT0 = s0;
        expT1 = s1;
        hookBase0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(hook));
        hookBase1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(hook));

        // A DIFFERENT pool, same currency pair, different fee tier. Anyone can create it.
        (, PoolKey memory kb) = _openForeignPool(0x4F10);
        uint256 before0 = poolManager.protocolFeesAccrued(c0);
        swapRouter.swapExactTokensForTokens(2e18, 0, true, kb, "", address(this), block.timestamp);
        uint256 foreignFee0 = poolManager.protocolFeesAccrued(c0) - before0;
        emit log_named_uint("foreign pool accrued protocolFees(c0)", foreignFee0);
        assertGt(foreignFee0, 0, "the foreign pool took no protocol fee: the setup proves nothing");

        // Now swap on OUR pool, big enough that the diff does not underflow so the mis-credit is
        // MEASURABLE rather than merely fatal. NOTE: PoolManager's ERC20 balance now backs TWO
        // pools, so the LAW-3 balance form is not pool-local here - measure the CREDIT itself.
        (uint256 tb0,) = hook.totals();
        uint256 pmb0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 pf0 = poolManager.protocolFeesAccrued(c0);
        swapRouter.swapExactTokensForTokens(300e18, 0, true, k, "", address(this), block.timestamp);
        uint256 inAmt = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)) - pmb0;
        uint256 ourFee = poolManager.protocolFeesAccrued(c0) - pf0;
        (uint256 ta0,) = hook.totals();
        uint256 credited = ta0 - tb0;
        emit log_named_uint("our swap input (PM delta)     ", inAmt);
        emit log_named_uint("our pool's OWN protocol fee   ", ourFee);
        emit log_named_uint("CORRECT credit (in - ourFee)  ", inAmt - ourFee);
        emit log_named_uint("hook ACTUALLY credited        ", credited);
        emit log_named_uint("hook lastPfDelta (over-netted)", hook.lastPfDelta());
        emit log_named_uint("foreign pool's fee            ", foreignFee0);
        // The hook subtracted the FOREIGN pool's fee from ITS OWN queue's credit: the queue is
        // UNDER-credited by exactly that amount, stranded in the position, owed to nobody.
        assertEq((inAmt - ourFee) - credited, foreignFee0, "under-credit is not exactly the foreign fee");
        assertEq(hook.lastPfDelta(), ourFee + foreignFee0, "pfDelta did not absorb the foreign pool's fee");
        assertGt(foreignFee0, DUST, "no measurable corruption");
    }

    function test_X2_foreignPoolCanBrickTheHookEntirely() public {
        pfee = _maxPacked();
        netting = true;
        hook = _deploy(3, 0, 0x5011);
        k = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        _applyProtocolFee(k, pfee);
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);

        // CONTROL: without the foreign accrual, a 1e15 swap on our pool SUCCEEDS.
        swapRouter.swapExactTokensForTokens(1e15, 0, true, k, "", address(this), block.timestamp);
        emit log_named_uint("control swap OK, hook pfSeen0", hook.pfSeen0());

        // Attacker accrues a large protocol fee on ANOTHER pool sharing currency0.
        (, PoolKey memory kb) = _openForeignPool(0x5112);
        uint256 before0 = poolManager.protocolFeesAccrued(c0);
        swapRouter.swapExactTokensForTokens(4e18, 0, true, kb, "", address(this), block.timestamp);
        uint256 foreignFee0 = poolManager.protocolFeesAccrued(c0) - before0;
        emit log_named_uint("foreign fee parked in the counter", foreignFee0);

        // Now a NORMAL small swap on our pool: pfDelta (>= foreignFee0) exceeds amtIn -> the
        // subtraction underflows inside afterSwap -> the whole swap reverts. Permanently: the
        // failed swap never advances pfSeen0.
        (bool ok, bytes memory err) = address(swapRouter).call(
            abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,bool,(address,address,uint24,int24,address),bytes,address,uint256)",
                uint256(1e15),
                uint256(0),
                true,
                k,
                bytes(""),
                address(this),
                block.timestamp
            )
        );
        emit log_named_string("small swap after the foreign accrual", ok ? "SUCCEEDED" : "REVERTED");
        assertFalse(ok, "X2: expected the hook's P2 subtraction to underflow");
        assertTrue(_containsPanic(err, 0x11), "X2: reverted, but NOT with arithmetic underflow (Panic 0x11)");
        emit log_named_uint("hook pfSeen0 after the failed swap (unchanged => permanent)", hook.pfSeen0());
    }

    /// @dev true if `data` contains an ABI-encoded Panic(uint256) with the given code, anywhere
    ///      (v4 wraps hook reverts in WrappedError, preserving the inner reason verbatim).
    function _containsPanic(bytes memory data, uint256 code) internal pure returns (bool) {
        bytes memory needle = abi.encodeWithSignature("Panic(uint256)", code);
        if (data.length < needle.length) return false;
        for (uint256 i; i <= data.length - needle.length; i++) {
            bool m = true;
            for (uint256 j; j < needle.length; j++) {
                if (data[i + j] != needle[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }
}

// ============================================================================================
//        ASYMMETRIC DECIMALS (18 / 6) WITH A MAXIMUM PROTOCOL FEE — LAW 1, harder
// ============================================================================================

contract FeeFloatAsymmetricDecimalsTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant LP_FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint128 constant LIQ = 2e18;
    address constant PM_OWNER = address(0x4444);

    Currency c0;
    Currency c1;
    uint8 d0;
    uint8 d1;
    FeeFloatQueueHook hook;
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

    function _sqrtPrice() internal view returns (uint160) {
        if (d1 >= d0) {
            return uint160((uint256(2) * (10 ** ((uint256(d1) - d0) / 2))) << 96);
        }
        return uint160((uint256(1) << 96) / (uint256(2) * (10 ** ((uint256(d0) - d1) / 2))));
    }

    function _pmBacking(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(poolManager)) - poolManager.protocolFeesAccrued(c);
    }

    function test_X1_composition_survivesUnequalDecimalsWithMaxFee() public {
        assertTrue(d0 != d1, "fixture is not asymmetric");
        uint24 packed = uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) | (uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) << 12);

        address a = address(FLAGS ^ (uint160(0x6101) << 144));
        deployCodeTo("FeeFloatComposition.t.sol:FeeFloatQueueHook", abi.encode(poolManager, uint8(3), uint8(0)), a);
        hook = FeeFloatQueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 20_000_000 * 10 ** d0);
        MockERC20(Currency.unwrap(c1)).mint(a, 20_000_000 * 10 ** d1);

        k = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, _sqrtPrice()); // human 1:4, NEVER 1:1
        vm.prank(PM_OWNER);
        poolManager.setProtocolFeeController(address(this));
        poolManager.setProtocolFee(k, packed);
        (,, uint24 got,) = poolManager.getSlot0(k.toId());
        assertEq(uint256(got), uint256(packed), "setProtocolFee silently no-opped: experiment VOID");

        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        require(s0 != s1, "fixture is unit-priced");
        hookBase0 = MockERC20(Currency.unwrap(c0)).balanceOf(a);
        hookBase1 = MockERC20(Currency.unwrap(c1)).balanceOf(a);
        emit log_named_uint("token0 decimals", d0);
        emit log_named_uint("token1 decimals", d1);
        emit log_named_uint("seeded token0 (raw)", s0);
        emit log_named_uint("seeded token1 (raw)", s1);

        _swap(true, s0 / 500);
        _swap(true, s0 * 15 / 100);
        _swap(true, s0 * 25 / 1000);
        _swap(false, s1 * 4 / 100);

        assertGt(poolManager.protocolFeesAccrued(c0), 0, "no protocol fee accrued: VOID");
        assertGt(poolManager.protocolFeesAccrued(c1), 0, "no reverse-leg protocol fee: VOID");
        emit log_named_uint("protocolFeesAccrued c0", poolManager.protocolFeesAccrued(c0));
        emit log_named_uint("protocolFeesAccrued c1", poolManager.protocolFeesAccrued(c1));

        // drain everything, checking INVARIANT F after each withdrawal.
        for (uint256 i; i < 3; i++) {
            (uint256 x0, uint256 x1) = hook.entry(i);
            if (x0 == 0 && x1 == 0) continue;
            hook.withdraw(i, x0, x1);
            assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(a) - hookBase0, hook.float0(), "asym float0 unbacked");
            assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(a) - hookBase1, hook.float1(), "asym float1 unbacked");
            (uint256 t0, uint256 t1) = hook.totals();
            int256 sl0 = int256(_pmBacking(c0) + hook.float0()) - int256(t0);
            int256 sl1 = int256(_pmBacking(c1) + hook.float1()) - int256(t1);
            emit log_named_int("asym INV-F slack t0", sl0);
            emit log_named_int("asym INV-F slack t1", sl1);
            assertGe(sl0, 0, "asym: INVARIANT F BROKEN - insolvent token0");
            assertGe(sl1, 0, "asym: INVARIANT F BROKEN - insolvent token1");
            assertLe(uint256(sl0), 8, "asym: INV-F residual token0 exceeds v4 dust");
            assertLe(uint256(sl1), 8, "asym: INV-F residual token1 exceeds v4 dust");
        }
        (uint256 lft0, uint256 lft1) = hook.totals();
        emit log_named_uint("asym LEFTOVER ledger dust token0", lft0);
        emit log_named_uint("asym LEFTOVER ledger dust token1", lft1);
        assertLe(lft0, 8, "asym: leftover token0 exceeds rounding residual");
        assertLe(lft1, 8, "asym: leftover token1 exceeds rounding residual");
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, k, "", address(this), block.timestamp);
    }
}
