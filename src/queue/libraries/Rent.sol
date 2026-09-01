// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Allocation} from "./Allocation.sol";

/// @notice The QUEUE rent arithmetic — Harberger, and nothing more than Harberger.
///
/// A seat carries a `selfPrice` its holder sets freely, denominated in `currency0`. Rent accrues on
/// that number in ELAPSED TIME, and the seat is always for sale at it. There is no oracle, no mark,
/// no collateral and no liquidation: the two functions here are a multiplication and a division.
///
/// **THE DISTRIBUTION IS `Allocation`, NOT A SECOND IMPLEMENTATION.** Handing `amount` out over a
/// set of weights so the parts sum EXACTLY to the whole is the same problem as handing a swap's
/// input out over the seats it filled, and this project has already paid for getting that wrong
/// once (PLAN §B.5 step 4): every floored share loses up to a wei, and without a remainder line the
/// shortfall compounds forever. So `distribute` drives `Allocation.step` with
/// `amtIn = amount, amtOut = Σweights`. One algorithm, one remainder line, one set of mutations.
library Rent {
    /// @dev A self-price is bounded so the rent product cannot overflow, and the bound is checked
    ///      where the price is SET rather than where it is used. An unbounded `selfPrice` is a
    ///      denial of service, not an arithmetic curiosity: a settlement that reverts is a seat
    ///      that can never be foreclosed, and `_settleAhead` would carry the revert into every
    ///      deposit behind it. `type(uint128).max` is above every amount v4 itself can represent
    ///      (its deltas are `int128`), so the bound costs nothing real.
    uint256 internal constant MAX_SELF_PRICE = type(uint128).max;

    /// @dev τ is capped at one whole period. A rate above that is expressed by shortening
    ///      `RENT_PERIOD`, not by inflating τ, and the cap is what keeps `bps * elapsed` small.
    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Rent accrued on `selfPrice` over `elapsed` seconds.
    ///
    /// @dev `selfPrice · τ · elapsed / RENT_PERIOD`, in `currency0`.
    ///
    ///      **Seconds, never blocks.** Block times differ by chain, so a block-denominated rate
    ///      silently changes meaning the moment the same bytecode is deployed somewhere else.
    ///
    ///      No `FullMath` and no overflow guard, because the inputs are bounded at their entry
    ///      points and the product cannot reach 2²⁵⁶: `selfPrice < 2¹²⁸`, `bps ≤ 10⁴` and
    ///      `elapsed < 2⁶⁴` give `selfPrice · bps · elapsed < 2²⁰⁶`. Plain arithmetic is therefore
    ///      EXACT here, which a saturating or 512-bit form would not be.
    function owed(uint256 selfPrice, uint256 elapsed, uint256 bps, uint256 period) internal pure returns (uint256) {
        return (selfPrice * bps * elapsed) / (MAX_BPS * period);
    }

    /// @notice Hand `amount` out over `weights`, summing to EXACTLY `amount`.
    /// @dev Array-driven form, for fuzzing with no pool at all. The hook drives `Allocation.step`
    ///      over storage with the identical arithmetic, exactly as it does for a swap.
    /// @return credits one entry per weight, in the same order; zero-weight entries get zero
    function distribute(uint256[] memory weights, uint256 amount) internal pure returns (uint256[] memory credits) {
        credits = new uint256[](weights.length);
        uint256 total;
        for (uint256 i; i < weights.length; i++) {
            total += weights[i];
        }
        if (total == 0 || amount == 0) return credits;

        // **`(0, 0)` PRICES AT THE AVERAGE, AND THAT IS THE POINT HERE.** A swap gets a price
        // curve because a swap sweeps a range of prices and the seats it reaches did not all trade
        // at the same one. Rent has no price and no range: it is one number split pro-rata by
        // weight, so every weight must be worth the same. Handing this a curve would silently make
        // rent depend on queue position twice — once through the split and once through the curve.
        Allocation.State memory st = Allocation.init(amount, total);
        for (uint256 i; i < weights.length && st.remaining > 0; i++) {
            if (weights[i] == 0) continue;
            (, uint256 give) = Allocation.step(st, weights[i], 0, 0);
            credits[i] = give;
        }
    }
}
