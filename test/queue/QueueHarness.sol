// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueHook} from "../../src/queue/QueueHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

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

    constructor(IPoolManager pm) QueueHook(pm) {}

    function seed(PoolKey calldata k, int24 tl, int24 tu, uint128 liq, uint256[] calldata bps)
        external
        returns (uint256 s0, uint256 s1)
    {
        if (liquidity != 0) revert AlreadySeeded();
        if (bps.length == 0) revert SeatCountMismatch();

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
            _pushSeat(a0, a1);
        }
    }

    /// @dev The Phase 1 solvency oracle. LAW 3 as amended: a raw PoolManager-balance conservation
    ///      test is BLIND to accrued protocol fees, which sit inside PoolManager's ERC20 balance
    ///      until collected. Redeeming for real is the assertion that cannot be fooled.
    function redeemAll() external returns (uint256 g0, uint256 g1) {
        return _burnPosition(liquidity);
    }
}
