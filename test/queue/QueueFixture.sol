// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Shared fixture for the Phase 1 allocator suite.
///
/// LAW 1 — the price is NEVER 1:1 and the decimals are configurable, because a unit fixture hides
/// every token0/token1 mixing bug. Phase 0 found that the reference spike ran 18/18 and therefore
/// only half-satisfied this law (PITFALLS 5.31); this fixture runs 18/6 as well.
///
/// LAW 3 (AS AMENDED) — conservation is measured on PoolManager's own ERC20 balances **net of
/// `protocolFeesAccrued`**, because accrued protocol fees sit inside PoolManager's ERC20 balance
/// until they are collected. The raw-balance form passes at 0 wei error while the position is
/// short. Solvency is asserted SEPARATELY, by really redeeming (`redeemAll`).
abstract contract QueueFixture is BaseTest {
    using StateLibrary for IPoolManager;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    /// @dev beforeAddLiquidity (1<<11) | beforeSwap (1<<7) | afterSwap (1<<6) == 0x8C0.
    /// @dev afterInitialize (1<<12) | beforeAddLiquidity (1<<11) | beforeSwap (1<<7)
    ///      | afterSwap (1<<6) == 0x18C0.
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    uint128 constant LIQ = 1_000e18;
    address constant PM_OWNER = address(0x4444);

    Currency c0;
    Currency c1;
    QueueHarness hook;
    PoolKey k;

    uint8 dec0 = 18;
    uint8 dec1 = 18;
    uint160 startPrice;

    // ---- the INDEPENDENT witness. Written from PLAN §B.5, deliberately not shaped like src/.
    uint256[] ref0;
    uint256[] ref1;
    uint256 refC0;
    uint256 refC1;

    // ---- conservation ground truth, measured on PoolManager, net of protocol fees
    uint256 expT0;
    uint256 expT1;

    // ---- bookkeeping for structural assertions
    uint256 lastTouched;
    uint256 lastPfDelta;
    /// @dev What THE HOOK actually credited to the ledger on the input token for the last swap.
    ///      Assertions about the hook's arithmetic must use THIS, never `lastPfDelta` — that one is
    ///      the fixture's own measurement, and comparing it to another fixture-side number is
    ///      tautological. (Caught by executing the old mechanism against an earlier draft.)
    uint256 lastHookCreditedIn;

    function _deployTokens() internal {
        MockERC20 t0 = new MockERC20("Token A", "A", dec0);
        MockERC20 t1 = new MockERC20("Token B", "B", dec1);
        if (t0 > t1) (t0, t1) = (t1, t0);
        (c0, c1) = (Currency.wrap(address(t0)), Currency.wrap(address(t1)));
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(i == 0 ? c0 : c1));
            // RAW units, deliberately NOT scaled by decimals: v4 works in raw units, and a
            // decimals-scaled mint starves the 6-decimal side of the 18/6 fixture.
            t.mint(address(this), 1e30);
            t.approve(address(permit2), type(uint256).max);
            t.approve(address(swapRouter), type(uint256).max);
            permit2.approve(address(t), address(positionManager), type(uint160).max, type(uint48).max);
            permit2.approve(address(t), address(poolManager), type(uint160).max, type(uint48).max);
        }
    }

    /// @dev Phase 3: the roster is fixed at construction, so the fixture must decide up front how
    ///      many seats exist. `_syntheticRoster` names them; nothing can create one afterwards.
    function _deployHook(uint160 nonce, uint256 nSeats) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo(
            "QueueHarness.sol:QueueHarness", abi.encode(poolManager, c0, c1, FEE, SPACING, _syntheticRoster(nSeats)), a
        );
        hook = QueueHarness(a);
        _fundHook(a);
    }

    /// @dev Distinct, non-zero, deterministic holders for the allocator suites, which care about
    ///      seat ARITHMETIC and not about who owns what.
    function _syntheticRoster(uint256 n) internal pure returns (address[] memory r) {
        r = new address[](n);
        for (uint256 i; i < n; i++) {
            r[i] = address(uint160(0x5EA700 + i));
        }
    }

    function _fundHook(address a) internal {
        MockERC20(Currency.unwrap(c0)).mint(a, 1e30);
        MockERC20(Currency.unwrap(c1)).mint(a, 1e30);
    }

    function _open(uint256[] memory bps) internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, startPrice);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        require(s0 != s1, "LAW 1: fixture is unit-priced");

        delete ref0;
        delete ref1;
        refC0 = 0;
        refC1 = 0;
        uint256 sum0;
        uint256 sum1;
        for (uint256 i; i < bps.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            ref0.push(a0);
            ref1.push(a1);
            sum0 += a0;
            sum1 += a1;
        }
        require(sum0 == s0 && sum1 == s1, "seed split lost a wei");
        expT0 = s0;
        expT1 = s1;
    }

    /// @dev Aggregate flows measured on POOLMANAGER'S OWN ERC20 BALANCES, net of the protocol fee
    ///      accrued by THIS swap. Nothing here reads the hook's bookkeeping — that is the thing
    ///      under test.
    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint256 inAmt, uint256 outAmt) {
        uint256 p0 = _pmBal(c0);
        uint256 p1 = _pmBal(c1);
        uint256 pf0 = poolManager.protocolFeesAccrued(c0);
        uint256 pf1 = poolManager.protocolFeesAccrued(c1);

        uint256[] memory before = _snapshot(zeroForOne);
        (uint256 lt0, uint256 lt1) = hook.totals();

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 n0 = _pmBal(c0);
        uint256 n1 = _pmBal(c1);
        lastPfDelta = zeroForOne ? poolManager.protocolFeesAccrued(c0) - pf0 : poolManager.protocolFeesAccrued(c1) - pf1;

        if (zeroForOne) {
            (inAmt, outAmt) = (n0 - p0 - lastPfDelta, p1 - n1);
            expT0 += inAmt;
            expT1 -= outAmt;
        } else {
            (inAmt, outAmt) = (n1 - p1 - lastPfDelta, p0 - n0);
            expT1 += inAmt;
            expT0 -= outAmt;
        }

        {
            (uint256 nt0, uint256 nt1) = hook.totals();
            lastHookCreditedIn = zeroForOne ? nt0 - lt0 : nt1 - lt1;
        }
        lastTouched = _countChanged(zeroForOne, before);
        _refAllocate(zeroForOne, inAmt, outAmt);
    }

    // ------------------------------------------------------------------- the independent reference

    /// @dev Written from PLAN §B.5's prose, not from `src/queue/libraries/Allocation.sol`. If both
    ///      are wrong in the same way, conservation against PoolManager still catches it — that is
    ///      the point of two mismatched witnesses rather than one.
    ///
    ///      Phase 0 established why this matters concretely: a one-wei misallocation leaves the
    ///      AGGREGATE totals tying out perfectly and is only visible seat by seat (PITFALLS 5.29).
    function _refAllocate(bool zeroForOne, uint256 amtIn, uint256 amtOut) internal {
        bool outIsOne = zeroForOne;
        uint256 begin = outIsOne ? refC1 : refC0;

        // THE DEGENERATE FILL: the pool took input and paid nothing out. No seat gives anything
        // up, so the whole input is credited to the seat the fill would have begun at.
        if (amtOut == 0) {
            if (amtIn != 0 && ref0.length != 0) {
                uint256 at = begin < ref0.length ? begin : 0;
                if (outIsOne) ref0[at] += amtIn;
                else ref1[at] += amtIn;
            }
            return;
        }

        uint256 owed = amtOut;
        uint256 handed;
        uint256 lastIdx;
        bool touchedAny;

        for (uint256 i = begin; i < ref0.length; i++) {
            if (owed == 0) break;
            uint256 have = outIsOne ? ref1[i] : ref0[i];
            if (have == 0) continue;

            uint256 t = have >= owed ? owed : have;
            owed -= t;
            uint256 g = (owed == 0) ? (amtIn - handed) : FullMath.mulDiv(amtIn, t, amtOut);
            handed += g;

            if (outIsOne) {
                ref1[i] = have - t;
                ref0[i] += g;
            } else {
                ref0[i] = have - t;
                ref1[i] += g;
            }
            lastIdx = i;
            touchedAny = true;
        }
        require(owed == 0, "reference underflow");

        if (touchedAny) {
            uint256 adv = (outIsOne ? ref1[lastIdx] : ref0[lastIdx]) == 0 ? lastIdx + 1 : lastIdx;
            if (outIsOne) {
                refC1 = adv;
                if (begin < refC0) refC0 = begin;
            } else {
                refC0 = adv;
                if (begin < refC1) refC1 = begin;
            }
        }
    }

    // ------------------------------------------------------------------------------- assertions

    /// @dev The two claims are DIFFERENT and need different assertions (LAW 3, second corollary):
    ///      (1) the LEDGER conserves, (2) each seat's COMPOSITION matches the independent witness.
    function _check(string memory tag) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        assertEq(t0, expT0, string.concat(tag, ": token0 conservation"));
        assertEq(t1, expT1, string.concat(tag, ": token1 conservation"));

        for (uint256 i; i < ref0.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            assertEq(a0, ref0[i], string.concat(tag, ": seat a0"));
            assertEq(a1, ref1[i], string.concat(tag, ": seat a1"));
        }
        _checkInvariantC(tag);
    }

    /// @dev INVARIANT C (§B.6): every seat below cursorX holds zero of token X. This is exactly the
    ///      statement "the cursor never LEADS". A lagging cursor costs gas; a leading cursor skips a
    ///      funded seat, which is silent theft of rank.
    function _checkInvariantC(string memory tag) internal view {
        (uint256 k0, uint256 k1) = hook.cursors();
        for (uint256 i; i < k0; i++) {
            (uint256 a0,) = hook.seat(i);
            assertEq(a0, 0, string.concat(tag, ": INVARIANT C cursor0 leads"));
        }
        for (uint256 i; i < k1; i++) {
            (, uint256 a1) = hook.seat(i);
            assertEq(a1, 0, string.concat(tag, ": INVARIANT C cursor1 leads"));
        }
    }

    // ------------------------------------------------------------------------------------ helpers

    // ------------------------------------------------------ Phase 2: the PRODUCTION deposit path

    /// @dev Deploys the hook with NO pre-funding. This is deliberate and load-bearing: if the hook
    ///      holds tokens it did not receive through `deposit`, a float-accounting bug simply pays
    ///      out of the surplus and stays invisible. Every Phase 2 assertion depends on the hook
    ///      owning exactly what the queue put in.
    function _deployHookUnfunded(uint160 nonce, address[] memory roster) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", abi.encode(poolManager, c0, c1, FEE, SPACING, roster), a);
        hook = QueueHarness(a);
    }

    function _roster(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _roster(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _roster(address a, address b, address c_) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c_);
    }

    /// @dev Initialize the pool only. `afterInitialize` binds the key inside the hook.
    function _initPool() internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, startPrice);
        delete ref0;
        delete ref1;
        // Every seat exists from deployment, empty. The witness must have the same shape as the
        // queue from the first block, or a seat that is skipped for being empty in one and absent
        // in the other would agree by accident.
        uint256 n = hook.seatCount();
        for (uint256 i; i < n; i++) {
            ref0.push(0);
            ref1.push(0);
        }
        refC0 = 0;
        refC1 = 0;
        expT0 = 0;
        expT1 = 0;
    }

    function _fund(address who, uint256 a0, uint256 a1) internal {
        MockERC20(Currency.unwrap(c0)).mint(who, a0);
        MockERC20(Currency.unwrap(c1)).mint(who, a1);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Fund a seat its holder ALREADY owns. Phase 3 deleted the arrival-order `deposit()`
    ///      that used to create the seat as a side effect, so the seat id is an input now, not an
    ///      output — which is exactly the property that made the head dust-griefable.
    function _addTo(address who, uint256 seatId, uint256 a0, uint256 a1) internal {
        _fund(who, a0, a1);
        vm.prank(who);
        hook.addToSeat(seatId, a0, a1);
        // The seat is credited the FULL amount: what the position consumed plus what became float.
        ref0[seatId] += a0;
        ref1[seatId] += a1;
        expT0 += a0;
        expT1 += a1;
    }

    /// @dev Re-base the witness after a seat evacuation. A transfer empties the seat OUTRIGHT —
    ///      the dust clamp changes what was PAID, never what the seat is left holding — so the
    ///      adjustment is exact and does not need to read the contract's arithmetic back. Cursors
    ///      are deliberately left alone, because evacuation does not move them.
    function _evacuateRef(uint256 seatId) internal {
        expT0 -= ref0[seatId];
        expT1 -= ref1[seatId];
        ref0[seatId] = 0;
        ref1[seatId] = 0;
    }

    /// @dev INVARIANT F: sum(q[i].aX) == what the position would release in X, PLUS floatX.
    ///      This is the aggregate identity that makes paying seats first-come-first-served out of a
    ///      SHARED float safe. Asserted non-destructively from the live position.
    ///      Phase 3 adds `pendingTotalX` to the left-hand side. A seat evacuation pays the departing
    ///      holder immediately, so the term is normally zero; it is non-zero only for whatever the
    ///      position could not release on the spot. Leaving it out would let a whole class of
    ///      evacuation bug hide behind the residual tolerance.
    function _checkInvariantF(string memory tag, uint256 tol) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 w0, uint256 w1) = hook.pendingTotals();
        (uint256 p0, uint256 p1) = _positionValue();
        assertApproxEqAbs(t0 + w0, p0 + f0, tol, string.concat(tag, ": INVARIANT F token0"));
        assertApproxEqAbs(t1 + w1, p1 + f1, tol, string.concat(tag, ": INVARIANT F token1"));
    }

    /// @dev What the position would actually hand back: PRINCIPAL **plus UNCOLLECTED LP FEES**.
    ///
    ///      The fee half is not optional and omitting it is not a small error. v4 accrues LP fees
    ///      into `feeGrowthInside` and only realises them on `modifyLiquidity`, so a principal-only
    ///      valuation understates the position by every fee it has ever earned. Measured on this
    ///      fixture: the "residual" grew ~9.6e15 wei PER SWAP — about 80% of the LP fee — and looked
    ///      exactly like a catastrophic ledger bug. It was the instrument.
    ///
    ///      (`withdraw` collects the whole fee balance into the float on the first `modifyLiquidity`
    ///      of any size, which is why the float can pay seats their fee share at all.)
    function _positionValue() internal view returns (uint256 a0, uint256 a1) {
        uint128 L = hook.positionLiquidity();
        if (L == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        int24 lower = TickMath.minUsableTick(SPACING);
        int24 upper = TickMath.maxUsableTick(SPACING);

        // Release rounds DOWN, matching what `modifyLiquidity(-L)` would actually hand back.
        a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(upper), L, false);
        a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(lower), sqrtP, L, false);

        (, uint256 insideLast0, uint256 insideLast1) =
            poolManager.getPositionInfo(k.toId(), address(hook), lower, upper, bytes32(0));
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(k.toId(), lower, upper);
        unchecked {
            a0 += FullMath.mulDiv(inside0 - insideLast0, L, 1 << 128);
            a1 += FullMath.mulDiv(inside1 - insideLast1, L, 1 << 128);
        }
    }

    /// @dev External so a negative control can capture the revert and assert its SPECIFIC reason.
    function doSwap(bool zeroForOne, uint256 amountIn) external {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    /// @dev v4 wraps a hook revert in `WrappedError(address,bytes4,bytes,bytes)`. LAW 2 demands the
    ///      SPECIFIC reason, so unwrap it rather than accepting any revert.
    function _expectSwapRevert(bool zeroForOne, uint256 amountIn, bytes4 wantSelector, string memory what)
        internal
        returns (bytes memory reason)
    {
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.doSwap, (zeroForOne, amountIn)));
        assertFalse(ok, what);
        reason = _unwrap(err);
        assertEq(bytes4(reason), wantSelector, string.concat(what, ": went red for the WRONG reason"));
    }

    function _unwrap(bytes memory err) internal pure returns (bytes memory) {
        // Peel every nested WrappedError until a non-wrapped payload remains.
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

    function _hookBal(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(hook));
    }

    function _pmBal(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(poolManager));
    }

    function _snapshot(bool zeroForOne) internal view returns (uint256[] memory out) {
        uint256 n = hook.seatCount();
        out = new uint256[](n);
        for (uint256 i; i < n; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            out[i] = zeroForOne ? a1 : a0;
        }
    }

    function _countChanged(bool zeroForOne, uint256[] memory before) internal view returns (uint256 c) {
        for (uint256 i; i < before.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            if ((zeroForOne ? a1 : a0) != before[i]) c++;
        }
    }

    function _setProtocolFee(PoolKey memory key_, uint24 fee) internal {
        vm.prank(PM_OWNER);
        poolManager.setProtocolFeeController(address(this));
        poolManager.setProtocolFee(key_, fee);
    }

    function _one0() internal view returns (uint256) {
        return 10 ** dec0;
    }

    function _one1() internal view returns (uint256) {
        return 10 ** dec1;
    }
}
