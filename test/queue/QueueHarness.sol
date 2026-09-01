// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueHook} from "../../src/queue/QueueHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice TEST-ONLY. Phase 1 stand-ins for the Phase 2 deposit/withdraw path.
///
/// These two functions used to live on `QueueHook` itself, and both were real holes:
///   * `seed()` funds the position from THE HOOK'S OWN BALANCE, so on a pre-funded deployment the
///     first caller would claim the whole queue for free.
///   * `redeemAll()` burns the entire position and is callable by anyone — pure griefing.
///
/// Keeping them here means the shipping contract has NO permissionless way to move liquidity, and
/// the allocator under test is still exactly the production one: this contract ADDS entry points
/// and OVERRIDES NOTHING.
contract QueueHarness is QueueHook {
    error SeatCountMismatch();
    error AlreadySeeded();

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
    ) QueueHook(pm, c0_, c1_, f, sp, bhw, roster, rb, rp, fw, pb) {}

    /// @dev TEST-ONLY. `_afterInitialize` now snaps a ±10% Uniswap band. Tests written against
    ///      a full-range blob (reentrancy, packing fuzz that walks the whole curve) call this
    ///      BEFORE any mint to restore that fixture. Production has no equivalent: the band is
    ///      the product.
    function forceRange(int24 tl, int24 tu) external {
        if (liquidity != 0) revert AlreadySeeded();
        tickLower = tl;
        tickUpper = tu;
    }

    function seed(PoolKey calldata k, int24 tl, int24 tu, uint128 liq, uint256[] calldata bps)
        external
        returns (uint256 s0, uint256 s1)
    {
        if (liquidity != 0) revert AlreadySeeded();
        // The roster is fixed at construction and `seed` may not extend it — Phase 3 removed every
        // path that creates a seat, and a harness that quietly grew the queue would be testing a
        // contract the product does not ship.
        if (bps.length != q.length) revert SeatCountMismatch();

        (s0, s1) = _mintPosition(k, tl, tu, liq);

        uint256 sum;
        for (uint256 i; i < bps.length; i++) {
            sum += bps[i];
        }
        if (sum != 10_000) revert SeatCountMismatch();

        uint256 acc0;
        uint256 acc1;
        for (uint256 i; i < bps.length; i++) {
            bool last = i == bps.length - 1;
            uint256 a0 = last ? s0 - acc0 : FullMath.mulDiv(s0, bps[i], 10_000);
            uint256 a1 = last ? s1 - acc1 : FullMath.mulDiv(s1, bps[i], 10_000);
            acc0 += a0;
            acc1 += a1;
            q[i].a0 = _u128(a0);
            q[i].a1 = _u128(a1);
        }

        // **THE SEVENTH WRITER.** Phase 7's premium accumulators are denominated by `standing0` /
        // `standing1`, and every site in `src/` that moves a seat balance moves those with it. This
        // function is the one balance writer that lives OUTSIDE `src/`, so it has to obey the same
        // rule or the first swap underflows `standing -= amtOut` against a book it never counted.
        // `acc0`/`acc1` are exactly `s0`/`s1` by the loop's own remainder line, and `seed` runs once
        // on an empty roster, so this is an assignment rather than an increment.
        standing0 = s0;
        standing1 = s1;
    }

    /// @dev The storage slot of `q`, read from the contract rather than assumed. An earlier version
    ///      of the oversized-swap test hardcoded slot 0, which was silently wrong the moment
    ///      `QueueSeats` put three mappings in front of the array.
    function seatArraySlot() external pure returns (uint256 slot) {
        assembly {
            slot := q.slot
        }
    }

    /// @dev The Phase 5b narrowing check, exposed so its BOUNDARY can be asserted directly. The
    ///      production paths that reach it cannot be driven past `2^128` through Uniswap — v4's own
    ///      deltas are `int128` — so a test that only went through `addToSeat` could never reach
    ///      the exact edge. This calls the production function, it does not reimplement it.
    function u128(uint256 x) external pure returns (uint128) {
        return _u128(x);
    }

    /// @dev The Phase 6 boundary check, exposed so the ZERO-SPAN case can be asserted directly.
    ///      At `sqrtP == sqrtPriceAt(tickLower)` the position holds no token1, and asking how much
    ///      liquidity releases some of it divides by a zero span — `FullMath.mulDiv` answers a bare
    ///      `require`, so the caller dies with EMPTY revert data and both `withdraw` and the seat
    ///      EVACUATION are blocked. Reaching that state through the public API needs the ledger and
    ///      the position to differ by the one-wei §E.4 residual at the same instant, which the
    ///      invariant campaign produces and a directed test cannot reliably stage. So the fixed
    ///      line is asserted where it lives. This CALLS the production function, it does not
    ///      reimplement it.
    function liquidityToCover(uint256 need0, uint256 need1) external view returns (uint128) {
        return _liquidityToCover(need0, need1);
    }

    /// @dev The Phase 1 solvency oracle. LAW 3 as amended: a raw PoolManager-balance conservation
    ///      test is BLIND to accrued protocol fees, which sit inside PoolManager's ERC20 balance
    ///      until collected. Redeeming for real is the assertion that cannot be fooled.
    /// @dev TEST-ONLY. Burns whatever the position still holds so a suite can assert REDEEMABILITY
    ///      (LAW 3, second corollary) rather than merely ledger conservation.
    ///
    ///      The zero guard lives HERE and not in `_burnPosition`, because this is the only caller in
    ///      the project that can pass zero: a fully-withdrawn position has `liquidity == 0`, and
    ///      poking an empty position reverts `CannotUpdateEmptyPosition` inside v4. The production
    ///      caller (`_payOut`) is already behind `if (dl != 0)`.
    function redeemAll() external returns (uint256 g0, uint256 g1) {
        if (liquidity == 0) return (0, 0);
        return _burnPosition(liquidity);
    }
}
