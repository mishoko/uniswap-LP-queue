// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

/// @notice The degenerate fill: a swap so small that the fee eats the whole input and the pool pays
///         out NOTHING.
///
/// This was a real defect. Deriving the swap direction from the SIGN of the balance delta reads it
/// backwards when the output leg is exactly zero, and the hook reverted `DirectionMismatch` on
/// swaps that v4 itself accepts — a liveness bug on any pool QUEUE serves. Measured: 1, 2 and 3 wei
/// on a 0.30% pool at 1:4.
contract DustTest is QueueFixture {
    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x8001, 3);
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        _open(bps);
    }

    function test_dustSwapsSucceedAndConserve() public {
        uint256[4] memory amts = [uint256(1), 2, 3, 7];
        for (uint256 i; i < amts.length; i++) {
            _swap(true, amts[i]);
            _check(string.concat("dust ", vm.toString(amts[i])));
        }
        // And the pool still works normally afterwards.
        _swap(true, expT0 / 500);
        _check("normal after dust");
    }

    /// @dev The input MUST be credited, not dropped. Dropping it would leave the ledger
    ///      UNDER-counting the position — value stranded and owed to nobody, which is the same
    ///      pathology as the protocol-fee under-credit this project already paid for once.
    function test_dustInputIsCreditedNotDropped() public {
        (uint256 t0Before,) = hook.totals();
        uint256 pmBefore = _pmBal(c0);

        this.doSwap(true, 3);

        (uint256 t0After,) = hook.totals();
        uint256 received = _pmBal(c0) - pmBefore - lastPfDelta;
        assertGt(received, 0, "the pool received nothing: the fixture proves nothing");
        assertEq(t0After - t0Before, received, "the ledger dropped the dust input");
    }

    /// @dev A zero-output swap must touch exactly ONE seat, and it must be the seat the fill would
    ///      have begun at. Front-first, even in the degenerate case.
    function test_dustCreditsTheSeatAtTheCursor() public {
        (uint256 h0Before,) = hook.seat(0);
        (uint256 s1Before,) = hook.seat(1);
        (uint256 s2Before,) = hook.seat(2);

        this.doSwap(true, 3);

        (uint256 h0After,) = hook.seat(0);
        (uint256 s1After,) = hook.seat(1);
        (uint256 s2After,) = hook.seat(2);
        assertGt(h0After, h0Before, "the head was not credited");
        assertEq(s1After, s1Before, "a non-head seat moved on a zero-output swap");
        assertEq(s2After, s2Before, "a non-head seat moved on a zero-output swap");
    }
}
