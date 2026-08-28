// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

/// @dev NEGATIVE CONTROL for the Phase 5b narrowing. Exactly one line differs from production: the
///      checked cast becomes a bare truncating one, which is what "pack it into a uint128" looks
///      like when nobody thinks about the boundary. It ADDS nothing and overrides one function, so
///      everything else under test is still production.
contract WrappingQueueHook is QueueHarness {
    constructor(
        IPoolManager pm,
        Currency c0_,
        Currency c1_,
        uint24 f,
        int24 sp,
        address[] memory roster,
        uint256 rb,
        uint256 rp,
        uint256 fw
    ) QueueHarness(pm, c0_, c1_, f, sp, roster, rb, rp, fw) {}

    function _u128(uint256 x) internal pure override returns (uint128) {
        return uint128(x); // WRAPS
    }
}

/// @notice PHASE 5b — the packing is only allowed to be faster, never different.
///
/// Two claims, and they are separate:
///
///   * **5.4 / G5** — the packed ledger produces WEI-IDENTICAL results to a `uint256`
///     implementation over a randomised swap sequence. The `uint256` implementation it is compared
///     against is `QueueFixture`'s independent reference allocator, which is written from PLAN
///     §B.5's prose rather than from `src/`, keeps its balances as `uint256[]`, and predates the
///     packing. Diffing against an INDEPENDENT `uint256` witness is a stronger claim than diffing
///     against the pre-optimisation copy of my own code, which could be wrong in the same way.
///
///   * **5.5 / G6** — the narrowing REVERTS on overflow and never wraps. Asserted at the exact
///     boundary through the production function, forced through a real `addToSeat`, and paired
///     with a control that wraps so the check is shown to be load-bearing (LAW 2).
contract PackingTest is QueueFixture {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CARL = address(0xCA71);

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
    }

    function _threeSeats(uint160 nonce, uint8 d0, uint8 d1) internal {
        dec0 = d0;
        dec1 = d1;
        startPrice = Constants.SQRT_PRICE_1_4; // LAW 1 — never 1:1
        _deployTokens();
        address[] memory roster = _roster(ALICE, BOB, CARL);
        _deployHookUnfunded(nonce, roster);
        _initPool();
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 60e18, 15e18);
        _addTo(CARL, 2, 900e18, 225e18);
    }

    // ─────────────────────────────────────────────────────────── 5.4 / G5 — the differential

    /// @dev A randomised swap sequence, both directions, checked seat by seat against the
    ///      `uint256` witness after EVERY swap. 256 runs x 8 swaps is >= 2,000 randomised swaps,
    ///      against §D.7 G5's floor of 1,000.
    ///
    ///      `_check` asserts three things at once and all three matter here: the ledger conserves
    ///      against PoolManager, every seat's `(a0, a1)` equals the witness's to the wei, and
    ///      INVARIANT C still holds. A packing bug that lost a wei on a narrowing would fail the
    ///      second long before the first.
    function testFuzz_5_4_packedLedgerIsWeiIdenticalToTheUint256Reference(uint16[8] memory raw, uint8 dirs) public {
        _threeSeats(0xD100, 18, 18);

        uint256 swaps;
        for (uint256 i; i < 8; i++) {
            bool zeroForOne = (dirs >> i) & 1 == 1;
            // Bounded so the swap is neither dust nor larger than the book can source.
            uint256 pool = zeroForOne ? expT0 : expT1;
            uint256 amt = bound(uint256(raw[i]), pool / 5_000, pool / 4);
            if (amt == 0) continue;

            _swap(zeroForOne, amt);
            _check(string.concat("packed vs uint256 reference, swap ", vm.toString(i)));
            swaps++;
        }

        // Rule 8 — before believing a path is covered, check that it was ENTERED.
        assertGt(swaps, 0, "no swap executed: this run proves nothing");
    }

    /// @dev The same claim at UNEQUAL DECIMALS, both ways round (LAW 1). A narrowing bug that only
    ///      shows up when one leg is six orders of magnitude smaller than the other is exactly the
    ///      kind an 18/18 fixture cannot see.
    function testFuzz_5_4b_weiIdenticalAtUnequalDecimals(uint16[6] memory raw, uint8 dirs, bool flip) public {
        _threeSeats(flip ? uint160(0xD200) : uint160(0xD300), flip ? 6 : 18, flip ? 18 : 6);

        uint256 swaps;
        for (uint256 i; i < 6; i++) {
            bool zeroForOne = (dirs >> i) & 1 == 1;
            uint256 pool = zeroForOne ? expT0 : expT1;
            uint256 amt = bound(uint256(raw[i]), pool / 5_000, pool / 4);
            if (amt == 0) continue;

            _swap(zeroForOne, amt);
            _check("packed vs uint256 reference, unequal decimals");
            swaps++;
        }
        assertGt(swaps, 0, "no swap executed: this run proves nothing");
    }

    // ──────────────────────────────────────────────── 5.5 / G6 — the narrowing reverts, never wraps

    /// @dev THE BOUNDARY, through the production function. `2^128 - 1` is the largest legal seat
    ///      balance and must pass unchanged; `2^128` is the first illegal one and must revert.
    function test_5_5_theNarrowingBoundaryIsExact() public {
        _threeSeats(0xD400, 18, 18);

        assertEq(hook.u128(0), 0, "zero did not survive the cast");
        assertEq(hook.u128(type(uint128).max), type(uint128).max, "the largest legal balance was rejected");

        vm.expectRevert(abi.encodeWithSelector(QueueHook.SeatBalanceOverflow.selector, uint256(type(uint128).max) + 1));
        hook.u128(uint256(type(uint128).max) + 1);

        vm.expectRevert(abi.encodeWithSelector(QueueHook.SeatBalanceOverflow.selector, type(uint256).max));
        hook.u128(type(uint256).max);
    }

    /// @dev FORCED THROUGH A REAL PATH. `addToSeat` on a seat already holding the maximum must
    ///      revert with the hook's own error, not wrap and not panic.
    ///
    ///      The seat is driven to `type(uint128).max` with `vm.store`, because no sequence of
    ///      Uniswap operations can put it there — v4 settles in `int128`, so a position it can
    ///      account for never holds `2^127` of anything, and the bound therefore costs nothing
    ///      real. That is the reason the state has to be forged, and it is also the reason the
    ///      bound is safe. The write is READ BACK through the contract's own view so a future
    ///      repacking fails loudly instead of leaving this test poking an unrelated slot.
    function test_5_5b_aFullSeatRevertsRatherThanWrapping() public {
        _threeSeats(0xD500, 18, 18);
        _maxOutSeatToken0(0);

        _fund(ALICE, 1, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.SeatBalanceOverflow.selector, uint256(type(uint128).max) + 1));
        hook.addToSeat(0, 1, 0);
    }

    /// @dev THE NEGATIVE CONTROL (LAW 2). One line changed — the checked cast becomes a bare
    ///      truncating one — and the same deposit that reverts above now DESTROYS the seat's entire
    ///      balance, wrapping `2^128 - 1 + 1` to zero. Without this the test above would be
    ///      consistent with the cast being decorative.
    function test_5_5c_negativeControl_theUncheckedCastWrapsAndErasesTheSeat() public {
        dec0 = 18;
        dec1 = 18;
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();

        address a = address(FLAGS ^ (uint160(0xD600) << 144));
        deployCodeTo("Packing.t.sol:WrappingQueueHook", _ctorArgs(_roster(ALICE, BOB, CARL)), a);
        hook = QueueHarness(a);
        _initPool();
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 60e18, 15e18);
        _addTo(CARL, 2, 900e18, 225e18);

        _maxOutSeatToken0(0);

        _fund(ALICE, 1, 0);
        vm.prank(ALICE);
        hook.addToSeat(0, 1, 0); // does NOT revert under the mutant

        (uint256 a0,) = hook.seat(0);
        assertEq(a0, 0, "the control did not wrap: it proves nothing about the production check");
    }

    /// @dev Force seat `id`'s token0 balance to `type(uint128).max`, leaving token1 alone.
    ///
    ///      This deliberately breaks INVARIANT F — the ledger now claims far more token0 than the
    ///      position holds — so nothing downstream of it may assert conservation. The only claim
    ///      these two tests make is about the CAST.
    function _maxOutSeatToken0(uint256 id) internal {
        (, uint256 a1) = hook.seat(id);
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(hook.seatArraySlot()))) + id);
        vm.store(address(hook), slot, bytes32((a1 << 128) | uint256(type(uint128).max)));

        (uint256 got0, uint256 got1) = hook.seat(id);
        assertEq(got0, type(uint128).max, "seat layout moved: token0 was not filled");
        assertEq(got1, a1, "seat layout moved: the poke clobbered token1");
    }
}
