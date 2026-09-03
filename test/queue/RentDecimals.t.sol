// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {QueueFixture} from "./QueueFixture.sol";

/// @notice **LAW 1 AS AMENDED, APPLIED TO THE RENT SINK.**
///
///         Rent used to be split pro-rata by each recipient's `currency0` BALANCE. Since 2026-09-02
///         it is split by the depth each recipient CONTRIBUTED, because front-first allocation
///         destroys the balance and a seat holding one wei of currency0 took the entire pot above
///         the band (`test_M9b`, executed as an identity before the fix).
///
///         That change introduces a `pot x (liquidity / liquidity)` division. **The `L`s cancel, so
///         the 5.124 shape — COMPARING a token pot against a liquidity weight in raw units — does
///         not appear here, and that was checked in the source rather than assumed.** This file
///         exists anyway, because on this project the argument that equal decimals were adequate has
///         been wrong before and cost an entire shipped feature (PITFALLS 5.124/5.126).
///
/// @dev **THE DIRECTION THAT MATTERS IS THE ONE NOBODY WAS RUNNING.** `Harberger.t.sol` and
///      `Maturity.t.sol` both run `dec0 = 18, dec1 = 6`, so the rent pot — which is ALWAYS
///      currency0, rent having no mirrored branch — is always the 18-decimal token, i.e. always a
///      large integer. The untested case is the pool where **currency0 is the SMALL-decimal token**:
///      the pot is then a small integer, and a floored `mulDiv(pot, Li, W)` can round a real
///      recipient to ZERO and strand the money. Both configurations are run here and the pair is
///      the point — nothing differs but the decimals, so a difference IS the decimals.
abstract contract RentDecimalsBase is QueueFixture {
    address constant ALICE = address(0xA11CE); // seat 0, rank 0 — a rent RECIPIENT
    address constant BOB = address(0xB0B); // seat 1
    address constant CARL = address(0xCA21); // seat 2
    address constant DAVE = address(0xDA1E); // seat 3, the tail — the rent PAYER

    function _u0(uint256 n) internal view returns (uint256) {
        return n * (10 ** dec0);
    }

    function _u1(uint256 n) internal view returns (uint256) {
        return n * (10 ** dec1);
    }

    function _init(uint8 d0, uint8 d1) internal {
        deployArtifactsAndLabel();
        vm.roll(100);
        vm.warp(1_700_000_000);
        startPrice = Constants.SQRT_PRICE_1_4;
        dec0 = d0;
        dec1 = d1;
        _deployTokens();
        _deployHookUnfunded(0x9301, _roster(ALICE, BOB, CARL, DAVE));
        _initPool();

        // Deliberately NOT round multiples of each other, so a pro-rata split has a real remainder.
        _addTo(ALICE, 0, _u0(40), _u1(10));
        _addTo(BOB, 1, _u0(60), _u1(15));
        _addTo(CARL, 2, _u0(137), _u1(34));
        _addTo(DAVE, 3, _u0(763), _u1(191));
    }

    /// @dev The whole claim, in one place, so both decimal pairs are asked EXACTLY the same question.
    /// @dev **THE PAYER IS THE TAIL SINCE PHASE 12.** Rent moves FORWARD, so a charge from rank 0
    ///      has no recipient at all and would exercise the HELD branch — under which every
    ///      assertion below holds vacuously at zero and the 6-decimal rounding this suite exists to
    ///      catch is never evaluated. The recipients are therefore ranks 0..2.
    function _rentSplitHolds() internal {
        vm.prank(DAVE);
        hook.setSelfPrice(3, _u0(100));
        _fund(DAVE, _u0(20), 0);
        vm.prank(DAVE);
        hook.fundRent(3, _u0(20));

        vm.warp(block.timestamp + 3_153_600);
        uint256 due = hook.rentDue(3);
        assertGt(due, 0, "no rent accrued: this test proves nothing");

        uint256[3] memory before_;
        uint256 depth;
        for (uint256 i; i < 3; i++) {
            uint256 id = hook.idAtRank(i);
            (, before_[i],,,) = hook.leaseOf(id);
            depth += hook.seatLiquidity(id);
        }
        assertGt(depth, 0, "nobody ahead contributes depth: wrong branch, this test proves nothing");

        hook.settleRent(3);
        (, uint256 unalloc) = hook.rentTotals();

        uint256 paid;
        for (uint256 i; i < 3; i++) {
            uint256 id = hook.idAtRank(i);
            (, uint256 e1,,,) = hook.leaseOf(id);
            uint256 got = e1 - before_[i];

            // **THE 6-DECIMAL FAILURE MODE, ASSERTED DIRECTLY.** A seat that contributed real depth
            // must receive real money. If a floored `mulDiv` of a small pot rounds it to zero, this
            // is the assertion that says so — and it is exactly what an 18-decimal pot cannot test.
            assertGt(hook.seatLiquidity(id), 0, "a recipient contributed no depth: fixture is wrong");
            assertGt(got, 0, "a recipient with real depth was floored to ZERO: the pot does not divide");
            assertGe(
                got, (due * hook.seatLiquidity(id)) / depth, "a recipient was paid less than its floored depth share"
            );
            paid += got;
        }

        // Conservation, as an identity rather than a bound. `Allocation`'s remainder line closes the
        // split to the wei, so nothing may be held and nothing may be lost.
        assertEq(unalloc, 0, "rent was held rather than distributed: wrong branch");
        assertEq(paid, due, "the distribution did not sum to the rent charged");
    }
}

/// @notice The pool `QueueDeployBase` ships: currency0 is the 18-decimal token, so the rent pot is
///         large. This is the configuration every existing rent test already runs.
contract RentDecimals18_6Test is RentDecimalsBase {
    function setUp() public {
        _init(18, 6);
    }

    function test_R1_rentDividesByDepth_pot18() public {
        _rentSplitHolds();
    }
}

/// @notice **THE MIRROR, AND THE ONE THAT WAS NEVER RUN.** currency0 is the 6-decimal token, so the
///         rent pot is a small integer and the floored depth split has somewhere to lose it.
contract RentDecimals6_18Test is RentDecimalsBase {
    function setUp() public {
        _init(6, 18);
    }

    function test_R2_rentDividesByDepth_pot6() public {
        _rentSplitHolds();
    }
}
