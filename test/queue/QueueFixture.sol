// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    /// @dev beforeAddLiquidity (1<<11) | beforeSwap (1<<7) | afterSwap (1<<6) == 0x8C0.
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
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

    function _deployHook(uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", abi.encode(poolManager), a);
        hook = QueueHarness(a);
        _fundHook(a);
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
