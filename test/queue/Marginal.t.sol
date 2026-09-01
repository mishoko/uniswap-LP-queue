// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {Allocation} from "../../src/queue/libraries/Allocation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

/// @notice **MARGINAL PRICING — the property that separates this hook from a pro-rata pool with a
///         label on it.** Every other suite checks that the parts sum to the whole. These check
///         WHO GETS WHICH PART, which conservation is blind to by construction.
///
/// A swap sweeps a RANGE of prices. Being first in line means being filled first, and the first
/// fills happen at the STALEST end of that range. So the head must fill WORSE than the swap's
/// average and the seats behind it BETTER, in both directions, by an amount that is economically
/// visible rather than a wei of rounding.
///
/// Until this landed the hook credited every seat the swap's average price, which handed the head
/// all of the volume and none of the price risk. `Controls.t.sol`'s N6 restores that and asserts
/// this suite notices; these tests state the positive form of the same claim.
///
/// LAW 1: 1:4, 18/6 — a 1:1 fixture would hide every token0/token1 mixing bug in the curve.
contract MarginalTest is QueueFixture {
    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        dec0 = 18;
        dec1 = 6;
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
    }

    /// @dev Five roughly equal seats, so a single swap can walk several of them and leave a chain
    ///      of prices to compare rather than a single pair.
    function _five() internal returns (uint256[] memory bps) {
        _deployHook(0x8801, 5);
        bps = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            bps[i] = 2_000;
        }
        _openBand(bps);
    }

    /// @dev `give/take` for every seat the swap touched, in rank order, as a Q64 fixed-point
    ///      ratio. Measured on the CONTRACT's own seat balances, never on the fixture's
    ///      expectations (AGENTS.md §3b: comparing two fixture-side quantities is tautological).
    function _prices(uint256 n, uint256[] memory a0, uint256[] memory a1, bool outIsOne)
        internal
        view
        returns (uint256[] memory px, uint256 touched)
    {
        px = new uint256[](n);
        for (uint256 i; i < n; i++) {
            (uint256 n0, uint256 n1) = hook.seat(i);
            uint256 take = outIsOne ? a1[i] - n1 : a0[i] - n0;
            uint256 give = outIsOne ? n0 - a0[i] : n1 - a1[i];
            if (take == 0) continue;
            px[touched++] = (give << 64) / take;
        }
        assembly ("memory-safe") {
            mstore(px, touched)
        }
    }

    function _before(uint256 n) internal view returns (uint256[] memory a0, uint256[] memory a1) {
        a0 = new uint256[](n);
        a1 = new uint256[](n);
        for (uint256 i; i < n; i++) {
            (a0[i], a1[i]) = hook.seat(i);
        }
    }

    /// @dev The core claim, selling token0. The head gives up token1 and is paid token0; a seat
    ///      further back is paid MORE token0 for the same token1, because the price it filled at
    ///      is further through the move.
    function test_8_1_deeperSeatsFillStrictlyBetter_zeroForOne() public {
        _five();
        (uint256[] memory a0, uint256[] memory a1) = _before(5);

        _swap(true, expT0 * 3); // sized to walk the whole roster, not just the head
        _check("8.1");

        (uint256[] memory px, uint256 touched) = _prices(5, a0, a1, true);
        assertGe(touched, 3, "nothing happened: this swap did not walk enough seats to prove anything");
        for (uint256 i = 1; i < touched; i++) {
            assertGt(px[i], px[i - 1], "a deeper seat did not fill at a better price than the one ahead of it");
        }
        // ...and by an amount that is a price move rather than a rounding wei. See 8.3 for why a
        // sign alone is not enough here.
        assertGe((px[touched - 1] - px[0]) * 10_000 / px[0], 10, "the price spread across the book is under 10 bps");
    }

    /// @dev The same claim in the other direction. **It is a separate test on purpose.** Four times
    ///      on this project a rule has been correct in one direction and absent in the other
    ///      (PITFALLS 5.37, 5.50, 5.52 twice); a curve read with the wrong sign would pass 8.1 and
    ///      pay the back of the book worse than the front here.
    function test_8_2_deeperSeatsFillStrictlyBetter_oneForZero() public {
        _five();
        // No priming swap: seeding leaves every seat holding BOTH tokens, so the reverse leg walks
        // the same fresh book 8.1 does. A primed book would also have concentrated token0 in the
        // head and reduced this to a one-seat fill, which proves nothing.
        (uint256[] memory a0, uint256[] memory a1) = _before(5);

        _swap(false, expT1 * 3);
        _check("8.2");

        (uint256[] memory px, uint256 touched) = _prices(5, a0, a1, false);
        assertGe(touched, 3, "nothing happened: the reverse leg did not walk enough seats");
        for (uint256 i = 1; i < touched; i++) {
            assertGt(px[i], px[i - 1], "one-for-zero: a deeper seat did not fill better than the one ahead of it");
        }
    }

    /// @dev **THE ECONOMIC STATEMENT, ASSERTED RATHER THAN CLAIMED IN A DOC.** The head fills worse
    ///      than the swap's own realised average and the last seat reached fills better. That
    ///      sentence is the entire argument for why the front of the book is a risk position and
    ///      not a subsidy, and it is what `BUSINESS.md` is allowed to say because of this test.
    function test_8_3_theHeadFillsWorseThanAverageAndTheTailBetter() public {
        _five();
        (uint256[] memory a0, uint256[] memory a1) = _before(5);

        (uint256 amtIn, uint256 amtOut) = _swap(true, expT0 * 3);
        _check("8.3");

        uint256 avg = (amtIn << 64) / amtOut; // the price EVERY seat used to get
        (uint256[] memory px, uint256 touched) = _prices(5, a0, a1, true);
        assertGe(touched, 3, "nothing happened: not enough seats to have a head and a tail");
        emit log_named_uint("head  price (Q64)", px[0]);
        emit log_named_uint("swap  average    ", avg);
        emit log_named_uint("tail  price (Q64)", px[touched - 1]);
        // **BOUNDED BY A MAGNITUDE, NOT BY A SIGN — this test was wrong the first time and the
        // mutant caught it.** Asserting only `px[0] < avg` PASSES under average pricing: the
        // floored per-seat shares land a wei below the average and the remainder line puts the
        // last seat a wei above it, so the signs come out right for a pure rounding reason. That
        // is AGENTS.md §3b's "a bound in the right direction is not a correctness assertion",
        // reproduced exactly. 10 bps is fifteen orders of magnitude above the rounding it has to
        // clear, and the measured spread here is ~400 bps on each side.
        assertGe((avg - px[0]) * 10_000 / avg, 10, "the head did NOT fill materially worse than the swap average");
        assertGe(
            (px[touched - 1] - avg) * 10_000 / avg,
            10,
            "the last seat reached did not fill materially better than the swap average"
        );
    }

    /// @dev A swap the head absorbs alone must be handed the whole input, untouched by any curve.
    ///      This is what keeps marginal pricing free on the path almost every trade takes, and it
    ///      is a correctness claim too: with one claimant there is no segment to divide.
    function test_8_4_aHeadOnlySwapIsHandedTheWholeInput() public {
        _five();
        (uint256[] memory a0, uint256[] memory a1) = _before(5);

        (uint256 amtIn,) = _swap(true, expT0 / 400);
        _check("8.4");

        (uint256 h0, uint256 h1) = hook.seat(0);
        assertEq(h0 - a0[0], amtIn, "a head-only fill was not credited the whole input");
        assertLt(h1, a1[0], "nothing happened: the head gave up no token1");
        (uint256 s10,) = hook.seat(1);
        assertEq(s10, a0[1], "a head-only fill leaked into seat 2");
    }
}
