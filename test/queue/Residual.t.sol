// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev THE MANDATORY DUST CONTROL (PLAN §D.4). Dust policy F1 replaced by face-value payment.
contract FaceValueQueueHook is QueueHarness {
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
    ) QueueHarness(pm, c0_, c1_, f, sp, bhw, roster, rb, rp, fw, pb) {}

    error FloatShort(uint256 want, uint256 have);

    function _applyDustPolicy(uint256 w0, uint256 w1) internal view override returns (uint256, uint256) {
        if (float0 < w0) revert FloatShort(w0, float0);
        if (float1 < w1) revert FloatShort(w1, float1);
        return (w0, w1);
    }
}

/// @notice The §E.4 redemption residual — measured, bounded, and proven not to compound.
///
/// The queue's face value is NOT what the position redeems for; it redeems for slightly less,
/// because v4 computes a swap's amounts and a position's redeemable value with two differently
/// rounded formulas, both in the pool's favour. This cannot be removed — v4 does not agree with
/// itself — so what matters is that the gap is SMALL, LINEAR, and never compounds.
contract ResidualTest is QueueFixture {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CARL = address(0xCAF1);

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        startPrice = Constants.SQRT_PRICE_1_4;
        dec0 = 18;
        dec1 = 6;
        _deployTokens();
    }

    function _seedThree() internal returns (uint256, uint256, uint256) {
        _addTo(ALICE, 0, 40e18, 10e18);
        _addTo(BOB, 1, 60e18, 15e18);
        _addTo(CARL, 2, 900e18, 225e18);
        return (0, 1, 2);
    }

    function _residual() internal view returns (uint256 r0, uint256 r1) {
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 p0, uint256 p1) = _positionValue();
        r0 = t0 > p0 + f0 ? t0 - (p0 + f0) : 0;
        r1 = t1 > p1 + f1 ? t1 - (p1 + f1) : 0;
    }

    /// @dev THE SAFETY PROPERTY. Not "the residual is zero" — it is not — but that it grows
    ///      LINEARLY in swap count. A compounding residual would eventually be real money; a linear
    ///      one at ~7 wei per swap needs ~10^17 swaps to cost a single token.
    function test_2_13_residualIsLinearNotCompounding() public {
        _deployHookUnfunded(0x6001, _roster(ALICE, BOB, CARL));
        _initPool();
        _seedThree();

        uint256[3] memory marks = [uint256(20), 60, 120];
        uint256[3] memory seen;
        uint256 done;
        for (uint256 m; m < 3; m++) {
            while (done < marks[m]) {
                _swap(done % 4 != 3, done % 4 == 3 ? 1e18 : 4e18);
                done++;
            }
            (uint256 r0,) = _residual();
            seen[m] = r0;
            emit log_named_uint(string.concat("residual token0 @ swaps=", vm.toString(marks[m])), r0);
        }

        assertGt(seen[0], 0, "no residual at all: the instrument is not measuring anything");
        // 6x the swaps must cost ~6x the residual, never 36x. Generous band, but it separates
        // LINEAR from QUADRATIC by a mile, which is the distinction that matters.
        uint256 ratio = (seen[2] * 100) / seen[0];
        assertGt(ratio, 200, "residual grew SUB-linearly: the measurement is suspect");
        assertLt(ratio, 1200, "RESIDUAL IS COMPOUNDING, not linear: this becomes real money");
        // And per-swap it must stay tiny in absolute terms.
        assertLt(seen[2] / marks[2], 32, "per-swap residual is larger than rounding explains");
    }

    /// @dev THE MANDATORY CONTROL, and §D.4 calls it the point of the gate: with F1 removed the
    ///      last withdrawer's call must FAIL. Without this there is no evidence the policy does
    ///      anything at all — the bug is a few hundred wei and is invisible unless hunted.
    function test_2_14_negativeControl_faceValueWithdrawLeavesTheLastWithdrawerShort() public {
        address a = address(FLAGS ^ (uint160(0x6002) << 144));
        deployCodeTo("Residual.t.sol:FaceValueQueueHook", _ctorArgs(_roster(ALICE, BOB, CARL)), a);
        hook = QueueHarness(a);
        _initPool();
        (uint256 i0, uint256 i1, uint256 i2) = _seedThree();

        for (uint256 s; s < 40; s++) {
            _swap(s % 4 != 3, s % 4 == 3 ? 1e18 : 4e18);
        }

        uint256[3] memory ids = [i0, i1, i2];
        address[3] memory who = [ALICE, BOB, CARL];
        bool sawShortfall;
        for (uint256 j; j < 3; j++) {
            (uint256 x0, uint256 x1) = hook.seat(ids[j]);
            vm.prank(who[j]);
            (bool ok, bytes memory err) = address(hook).call(abi.encodeCall(hook.withdraw, (ids[j], x0, x1)));
            if (!ok) {
                assertEq(
                    bytes4(err),
                    FaceValueQueueHook.FloatShort.selector,
                    "face-value withdraw failed for the WRONG reason"
                );
                sawShortfall = true;
            }
        }
        assertTrue(sawShortfall, "paying FACE VALUE exactly drained everyone: F1 is doing nothing");
    }

    /// @dev The positive half: with F1 in place, the identical scenario pays everyone.
    function test_2_15_positiveControl_F1DrainsEveryone() public {
        _deployHookUnfunded(0x6003, _roster(ALICE, BOB, CARL));
        _initPool();
        (uint256 i0, uint256 i1, uint256 i2) = _seedThree();

        for (uint256 s; s < 40; s++) {
            _swap(s % 4 != 3, s % 4 == 3 ? 1e18 : 4e18);
        }

        uint256[3] memory ids = [i0, i1, i2];
        address[3] memory who = [ALICE, BOB, CARL];
        for (uint256 j; j < 3; j++) {
            (uint256 x0, uint256 x1) = hook.seat(ids[j]);
            vm.prank(who[j]);
            hook.withdraw(ids[j], x0, x1);
        }
        (uint256 t0, uint256 t1) = hook.totals();
        assertLt(t0, 1_000, "F1 left more than dust unpaid in token0");
        assertLt(t1, 1_000, "F1 left more than dust unpaid in token1");
    }

    // ============================================== two honest limitations, asserted not asserted-away

    /// @dev A deposit far off the pool's RAW ratio is almost entirely absorbed into float rather
    ///      than becoming depth. Under the owner's ABSORB decision the depositor is still credited
    ///      in full and loses nothing — but the pool gains almost no depth from them until the
    ///      other leg arrives and `sweepFloatIntoPosition` can pair it up.
    ///      This is a real consequence of ABSORB-over-REFUND and it must not be a surprise.
    function test_2_16_lopsidedDepositBecomesFloatNotDepth() public {
        _deployHookUnfunded(0x6004, _roster(ALICE, BOB));
        _initPool();
        _addTo(ALICE, 0, 1000e18, 250e18); // on-ratio, establishes the pool
        uint128 liqBefore = hook.positionLiquidity();

        // Wildly off-ratio: lots of token0, almost no token1.
        _addTo(BOB, 1, 1000e18, 1e6);
        uint128 liqAfter = hook.positionLiquidity();

        (uint256 f0,) = hook.floats();
        assertGt(f0, 900e18, "the off-ratio leg did NOT land in float");
        (uint256 b0, uint256 b1) = hook.seat(1);
        assertEq(b0, 1000e18, "the depositor was not credited in full");
        assertEq(b1, 1e6, "the depositor was not credited in full");
        // Depth barely moved despite a deposit the size of the whole pool.
        assertLt(liqAfter - liqBefore, liqBefore / 100, "off-ratio deposit unexpectedly bought depth");
    }

    /// @dev `sweepFloatIntoPosition` IS LIMITED BY THE SMALLER LEG, and this bounds how much depth
    ///      recovery STEP 2b can honestly promise.
    ///
    ///      Adding to a range that straddles the price requires BOTH tokens, so the sweep can only
    ///      pair up float in the pool's current ratio. A lopsided float is reinjected in proportion
    ///      to its MINORITY token and the majority stays stranded until its counterpart arrives.
    ///      It is a near-no-op, not a revert.
    ///
    ///      (An earlier version of this test claimed the sweep "cannot" reinject a one-sided float
    ///      at all. That was too strong: with 1e6 wei of the minority leg it still added 41 units of
    ///      liquidity. Asserting the real behaviour, not the tidier claim.)
    function test_2_17_sweepIsBoundedByTheSmallerLeg() public {
        _deployHookUnfunded(0x6005, _roster(ALICE, BOB));
        _initPool();
        _addTo(ALICE, 0, 1000e18, 250e18);
        _addTo(BOB, 1, 1000e18, 1e6); // a large token0 float against a sliver of token1

        (uint256 f0Before, uint256 f1Before) = hook.floats();
        assertGt(f0Before, 900e18, "no lopsided float was created");
        assertLt(f1Before, 1e7, "the float is not lopsided: the test proves nothing");

        hook.sweepFloatIntoPosition();
        (uint256 f0After,) = hook.floats();

        // Essentially none of the stranded majority leg comes back.
        uint256 consumed = f0Before - f0After;
        assertLt(consumed, f0Before / 1000, "the sweep reclaimed the stranded leg: re-check the sizing");
        assertGt(f0After, 900e18, "the majority float was unexpectedly drained");
    }
}
