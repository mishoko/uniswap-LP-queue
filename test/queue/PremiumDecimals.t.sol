// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title IS THE PRIORITY PREMIUM INERT ON THE POOL THE DEPLOY SCRIPT ACTUALLY SHIPS?
///
/// @notice `_accruePremium` compares a pot denominated in the INCOMING token against a weight
///         denominated in the OUTGOING token, **in raw units**. `Premium.t.sol` runs `dec0 == dec1
///         == 18`, where those two units happen to be the same size — a LAW 1 violation inside the
///         one suite that tests the premium, and LAW 1 exists because a symmetric fixture "hides
///         EVERY token0/token1 unit-mixing bug". `QueueDeployBase` ships **18/6**.
///
/// @dev **THE CONTROL IS THE POINT.** The same scenario is run twice, at 18/6 and at 18/18, with
///      the same HUMAN economics both times: one whole token0 buys four whole token1, seats funded
///      100 and 400 whole units, swaps of one whole token0 and four whole token1. Everything that
///      could explain a difference is held equal except the decimals, so a difference IS the
///      decimals. Both pools are real v4 pools; nothing here is mocked.
abstract contract PremiumDecimalsBase is QueueFixture {
    uint256 constant PHI = 8_500; // the shipping φ — QueueDeployBase.PREMIUM_BPS
    uint256 constant N = 5; // the shipping roster — QueueDeployBase.SEATS
    uint256 constant PRICE_NUM = 4;
    uint256 constant PRICE_DEN = 1;

    function _premiumBps() internal view virtual override returns (uint256) {
        return PHI;
    }

    /// @dev Whole units, so the two fixtures describe the same market.
    function _whole0(uint256 n) internal view returns (uint256) {
        return n * (10 ** dec0);
    }

    function _whole1(uint256 n) internal view returns (uint256) {
        return n * (10 ** dec1);
    }

    /// @dev `QueueDeployBase._sqrtPriceX96`, reproduced so the two pools open at the price their own
    ///      decimals imply rather than at a constant that only suits one of them.
    function _priceFor(uint8 d0, uint8 d1) internal pure returns (uint160) {
        uint256 ratioX192 = (PRICE_NUM * (10 ** d1) * (1 << 192)) / (PRICE_DEN * (10 ** d0));
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }

    function _setUpAt(uint8 d0, uint8 d1, uint160 nonce) internal {
        deployArtifactsAndLabel();
        vm.roll(100);
        vm.warp(1_700_000_000);
        dec0 = d0;
        dec1 = d1;
        _deployTokens();
        startPrice = _priceFor(d0, d1);

        address[] memory roster = new address[](N);
        for (uint256 i; i < N; i++) {
            roster[i] = address(uint160(0x9E00 + i));
        }
        _deployHookUnfunded(nonce, roster);
        _initPool();
        // The shipping demo's own funding amounts, in whole units.
        for (uint256 i; i < N; i++) {
            _addTo(roster[i], i, _whole0(100), _whole1(400));
        }
        _sweepTracked();
    }

    /// @dev Eight swaps, alternating direction, one whole token0 / four whole token1 each — the
    ///      same trade in both fixtures. After every one, record whether the accumulator moved.
    function _run(string memory tag) internal {
        emit log_string(string.concat("================ ", tag));
        (uint256 s0, uint256 s1) = hook.standings();
        emit log_named_uint("standing0 (weight for the token1 pot)", s0);
        emit log_named_uint("standing1 (weight for the token0 pot)", s1);
        // The candidate replacement weight. Liquidity is ONE unit for both directions, which is
        // exactly what the two `standing` figures are not — note how far apart they are above.
        emit log_named_uint("position liquidity (candidate weight)", hook.positionLiquidity());

        uint256 movedG0;
        uint256 movedG1;
        for (uint256 i; i < 8; i++) {
            bool zeroForOne = i % 2 == 0;
            (uint256 g0b, uint256 g1b) = hook.growths();
            _swap(zeroForOne, zeroForOne ? _whole0(1) : _whole1(4));
            // **THE INDEPENDENT WITNESS, WHICH THIS SUITE COULD NOT CALL UNTIL PHASE 8.** Until
            // `_refAllocate` modelled the premium, `_check`'s seat-by-seat composition assertion was
            // unavailable at φ > 0 and the per-seat SPLIT rested on this file's own aggregates. It
            // now runs on the 18/6 pool the deploy script ships, which is the pair the premium was
            // once completely inert on.
            _check(string.concat(tag, " swap ", vm.toString(i)));
            (uint256 g0a, uint256 g1a) = hook.growths();
            if (g0a > g0b) movedG0++;
            if (g1a > g1b) movedG1++;
        }

        (uint256 owed0, uint256 owed1, uint256 held0, uint256 held1) = hook.premiums();
        (uint256 g0, uint256 g1) = hook.growths();
        emit log_named_uint("token0 pot: accruals that MOVED premGrowth0 (of 4)", movedG0);
        emit log_named_uint("token1 pot: accruals that MOVED premGrowth1 (of 4)", movedG1);
        emit log_named_uint("premiumOwed0 (withheld, token0)      ", owed0);
        emit log_named_uint("premiumHeld0 (stuck, token0)         ", held0);
        emit log_named_uint("premiumOwed1 (withheld, token1)      ", owed1);
        emit log_named_uint("premiumHeld1 (stuck, token1)         ", held1);
        emit log_named_uint("premGrowth0                          ", g0);
        emit log_named_uint("premGrowth1                          ", g1);
        if (owed0 != 0) {
            emit log_named_uint("token0 premium STUCK, % of withheld   ", (held0 * 100) / owed0);
        }
        if (owed1 != 0) {
            emit log_named_uint("token1 premium STUCK, % of withheld   ", (held1 * 100) / owed1);
        }

        // What a seat can actually CLAIM is the only thing that matters to a holder. `seat()`
        // reports raw ledger + accrued premium, so the difference against `totals()` (raw only) is
        // the premium that has actually reached the roster.
        uint256 claimable0;
        uint256 claimable1;
        (uint256 t0, uint256 t1) = hook.totals();
        for (uint256 i; i < N; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            claimable0 += a0;
            claimable1 += a1;
        }
        emit log_named_uint("premium REACHING the roster, token0  ", claimable0 - t0);
        emit log_named_uint("premium REACHING the roster, token1  ", claimable1 - t1);

        // PITFALLS 5.54 — prove the path was entered before believing anything measured on it.
        assertGt(owed0, 0, "no token0 premium was withheld at all: this test proves nothing");
        assertGt(owed1, 0, "no token1 premium was withheld at all: this test proves nothing");

        // **THE ASSERTION IS NOT A TOLERANCE SOMEBODY PICKED — IT IS WHAT THE CONTROL ACHIEVES.**
        // At 18/18 both directions strand 0% of the premium they withhold, over the identical
        // scenario. A mechanism whose behaviour depends on the DECIMALS of the pair is broken, so
        // the shipped pool is held to the number its own control reaches. Stated as "under 1%"
        // rather than "exactly 0" only because the last accrual of a run is legitimately unsettled.
        assertLt((held0 * 100) / owed0, 1, "token0 premium is STRANDED: the pot is not reaching the roster");
        assertLt((held1 * 100) / owed1, 1, "token1 premium is STRANDED: the pot is not reaching the roster");
        assertEq(movedG0, 4, "the token0 accumulator did not advance on every accrual");
        assertEq(movedG1, 4, "the token1 accumulator did not advance on every accrual");
    }
}

/// @notice THE SHIPPED POOL: `QueueDeployBase.DEC_A = 18`, `DEC_B = 6`.
contract PremiumDecimals18_6Test is PremiumDecimalsBase {
    function setUp() public {
        _setUpAt(18, 6, 0xF100);
    }

    function test_9_1_shippedDecimals() public {
        _run("18 / 6 - THE POOL THE DEPLOY SCRIPT SHIPS");
    }
}

/// @notice THE CONTROL: identical in every respect but the decimals.
contract PremiumDecimals18_18Test is PremiumDecimalsBase {
    function setUp() public {
        _setUpAt(18, 18, 0xF200);
    }

    function test_9_1_controlDecimals() public {
        _run("18 / 18 - THE CONTROL (and what Premium.t.sol runs)");
    }
}
