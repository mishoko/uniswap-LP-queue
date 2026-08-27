// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Criterion 1.10 — the protocol fee, and the two attacks that killed the previous design.
///
/// THE DOCTRINE THIS FILE EXISTS TO HONOUR (PITFALLS 5.27): the previous P2 mechanism was
/// "MEASURED closing the gap to 3 wei" by a test that ran in a SINGLE-POOL fixture. The mechanism
/// was right about WHAT to subtract; the INSTRUMENT was wrong and the fixture was structurally
/// incapable of showing it. `protocolFeesAccrued` is `mapping(Currency => uint256)` — GLOBAL per
/// currency (`ProtocolFees.sol:21`) — so a one-pool fixture can never observe contamination.
///
/// EVERY test here that touches the fee therefore runs with a FOREIGN POOL sharing a currency.
contract ProtocolFeeTest is QueueFixture {
    /// @dev 1000 pips each direction == MAX_PROTOCOL_FEE, i.e. 0.1% of swap input per direction.
    uint24 constant MAX_PF = uint24(1000) | (uint24(1000) << 12);

    QueueHarness foreignHook;
    PoolKey foreignKey;

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x2001, 3);
    }

    function _bps() internal pure returns (uint256[] memory bps) {
        bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
    }

    /// @dev A SECOND, INDEPENDENT v4 pool on the SAME token pair. Its protocol fees land in the very
    ///      same global `protocolFeesAccrued[currency]` slots that QUEUE reads.
    function _deployForeignPool(uint24 poolFee) internal {
        address a = address(FLAGS ^ (uint160(0x9009) << 144));
        // Deployed for ITS OWN pool: the hook now fixes its pool at construction, so a foreign pool
        // on a different fee tier needs a hook constructed for that fee tier.
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(_syntheticRoster(1), poolFee), a);
        foreignHook = QueueHarness(a);
        _fundHook(a);

        foreignKey = PoolKey({
            currency0: c0, currency1: c1, fee: poolFee, tickSpacing: SPACING, hooks: IHooks(address(foreignHook))
        });
        poolManager.initialize(foreignKey, startPrice);
        uint256[] memory bps = new uint256[](1);
        bps[0] = 10_000;
        foreignHook.seed(foreignKey, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
    }

    function _foreignSwap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: foreignKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    // ================================================ 1.10 — the ledger conserves with the fee ON

    function test_1_10_ledgerConservesWithProtocolFeeOn() public {
        _open(_bps());
        _deployForeignPool(500);
        _setProtocolFee(k, MAX_PF);
        _setProtocolFee(foreignKey, MAX_PF);

        // Foreign volume FIRST, so the global counter is already dirty before QUEUE ever swaps.
        // This is the exact state in which the previous mechanism mis-credited its first swap.
        _foreignSwap(true, 40e18);
        assertGt(poolManager.protocolFeesAccrued(c0), 0, "fixture is inert: no foreign accrual");

        uint256 s0 = expT0;
        uint256 s1 = expT1;

        _swap(true, s0 / 500);
        // Criterion 1.10 as CORRECTED: assert the fee is actually on, or the test cannot fail.
        assertGt(lastPfDelta, 0, "protocol fee did not accrue on QUEUE's own swap");
        _check("pf swap1");

        _foreignSwap(true, 40e18); // more contamination, mid-scenario
        _swap(true, (s0 * 16) / 100);
        _check("pf swap2");

        _foreignSwap(false, 10e18);
        _swap(false, s1 / 100);
        _check("pf swap3-reverse");
    }

    // ================================================== 1.10 — SOLVENCY, asserted by really redeeming

    /// @dev Conservation of the LEDGER and redeemability of the POSITION are two different claims
    ///      (LAW 3, second corollary). This is the second one, and it is the one a raw-balance test
    ///      is blind to: accrued protocol fees sit INSIDE PoolManager's ERC20 balance until
    ///      collected, so a balance check can read 0 wei error while the position is short.
    function test_1_10_positionStaysRedeemableWithProtocolFeeOn() public {
        _open(_bps());
        _deployForeignPool(500);
        _setProtocolFee(k, MAX_PF);
        _setProtocolFee(foreignKey, MAX_PF);

        uint256 s0 = expT0;
        for (uint256 i; i < 6; i++) {
            _foreignSwap(i % 2 == 0, 20e18);
            _swap(true, s0 / 200);
            _check("solvency loop");
        }

        (uint256 t0, uint256 t1) = hook.totals();
        uint256 pfBefore0 = poolManager.protocolFeesAccrued(c0);
        assertGt(pfBefore0, 0, "no protocol fee accrued: the test cannot fail");

        (uint256 g0, uint256 g1) = hook.redeemAll();

        // The ledger may exceed what the position returns only by the §E.4 rounding residual, which
        // is a handful of wei and is NOT caused by the protocol fee. It must never be more.
        assertGe(t0, g0, "position returned MORE token0 than the ledger claims");
        assertGe(t1, g1, "position returned MORE token1 than the ledger claims");
        assertLe(t0 - g0, 16, "token0 shortfall is larger than v4 rounding explains");
        assertLe(t1 - g1, 16, "token1 shortfall is larger than v4 rounding explains");

        // Withdrawal must not accrue protocol fees.
        assertEq(poolManager.protocolFeesAccrued(c0), pfBefore0, "redemption accrued a protocol fee");
    }

    // ==================================================== X1 — foreign accrual cannot corrupt us

    /// @dev X1 UNDER THE OLD DESIGN: a foreign pool on the same pair took 2e15 wei and QUEUE's next
    ///      swap under-credited the queue by exactly that — stranded, owed to nobody, no attacker
    ///      required. Here the same setup must leave the ledger EXACT.
    function test_X1_foreignAccrualCannotCorruptTheLedger() public {
        _open(_bps());
        _deployForeignPool(500);
        _setProtocolFee(k, MAX_PF);
        _setProtocolFee(foreignKey, MAX_PF);

        uint256 globalBefore = poolManager.protocolFeesAccrued(c0);
        _foreignSwap(true, 500e18);
        uint256 foreignAccrual = poolManager.protocolFeesAccrued(c0) - globalBefore;
        assertGt(foreignAccrual, 0, "foreign pool accrued nothing: the test proves nothing");

        // QUEUE's own swap. Its measured fee must be ITS OWN, not the global movement.
        _swap(true, expT0 / 500);
        _check("X1");

        assertGt(lastPfDelta, 0, "QUEUE's own swap accrued no fee");
        // The hook must have credited the queue MORE than `foreignAccrual` short of nothing: under
        // the old mechanism the credit was reduced by exactly the foreign pool's take.
        assertGt(
            lastHookCreditedIn, foreignAccrual, "the hook's credit was eaten by the foreign pool's accrual: X1 is ALIVE"
        );
    }

    // ========================================================= X2 — foreign accrual cannot brick us

    /// @dev X2 UNDER THE OLD DESIGN: once foreign accrual exceeded the next swap's input,
    ///      `amtIn -= pfDelta` underflowed inside afterSwap, the swap reverted, the failed swap
    ///      never advanced the stored counter, and EVERY later swap recomputed the same oversized
    ///      delta. The pool was dead permanently. Here: a foreign accrual many times larger than
    ///      QUEUE's next swap input must be a non-event.
    function test_X2_foreignAccrualCannotBrickTheHook() public {
        _open(_bps());
        _deployForeignPool(500);
        _setProtocolFee(k, MAX_PF);
        _setProtocolFee(foreignKey, MAX_PF);

        // Pile up foreign protocol fees on token0.
        for (uint256 i; i < 5; i++) {
            _foreignSwap(true, 2_000e18);
        }
        uint256 globalPf = poolManager.protocolFeesAccrued(c0);

        // A DELIBERATELY TINY QUEUE swap: far smaller than the accumulated global counter.
        uint256 tiny = expT0 / 100_000;
        assertGt(globalPf, tiny, "fixture too weak: global accrual must EXCEED the swap input");

        _swap(true, tiny); // must not revert
        _check("X2");

        // And the pool is still alive afterwards, repeatedly.
        for (uint256 i; i < 3; i++) {
            _swap(true, tiny);
            _check("X2 still alive");
        }
    }

    // ================================================= PITFALLS 5.3 — lpFee == 0 under a protocol fee

    /// @dev With `lpFee == 0`, `swapFee == protocolFee` and v4 takes the ENTIRE `feeAmount` by a
    ///      different formula (`Pool.sol:391-392`). An ARITHMETIC derivation of the fee has to
    ///      special-case this. Reading the accrued number does not — which is the point.
    function test_5_3_lpFeeZeroUnderProtocolFee() public {
        // A zero-lpFee pool needs a hook constructed for a zero-lpFee pool.
        address z = address(FLAGS ^ (uint160(0x2009) << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(_syntheticRoster(3), uint24(0)), z);
        hook = QueueHarness(z);
        _fundHook(z);
        k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, startPrice);
        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, _bps());
        delete refOrder;
        for (uint256 i; i < 3; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            ref0.push(a0);
            ref1.push(a1);
            refOrder.push(i);
        }
        expT0 = s0;
        expT1 = s1;

        _deployForeignPool(500);
        _setProtocolFee(k, MAX_PF);
        _setProtocolFee(foreignKey, MAX_PF);

        _foreignSwap(true, 100e18);
        _swap(true, s0 / 500);
        assertGt(lastPfDelta, 0, "zero-lpFee pool accrued no protocol fee");
        _check("lpFee==0");

        _swap(true, (s0 * 16) / 100);
        _check("lpFee==0 sweep");
    }

    // ============================================== the window claim, asserted rather than assumed

    /// @dev The whole fix rests on one claim: between `beforeSwap` and `afterSwap`, the ONLY change
    ///      to `protocolFeesAccrued[inputCurrency]` is this swap's own. Assert it directly — if a
    ///      future v4 version accrued elsewhere in that window, this goes red.
    function test_measurementWindowSeesExactlyOneSwapsFee() public {
        _open(_bps());
        _deployForeignPool(500);
        _setProtocolFee(k, MAX_PF);
        _setProtocolFee(foreignKey, MAX_PF);

        // FOREIGN VOLUME FIRST. Without this line the test PASSES even against the old, broken
        // cross-transaction mechanism — verified by executing that mutant. That is PITFALLS 5.27
        // reproduced inside this very suite: a fixture with no foreign volume BEFORE the
        // measurement is structurally incapable of observing the contamination.
        _foreignSwap(true, 300e18);

        uint256 before = poolManager.protocolFeesAccrued(c0);
        uint256 pmBefore = _pmBal(c0);
        _swap(true, expT0 / 500);
        uint256 moved = poolManager.protocolFeesAccrued(c0) - before;

        assertGt(moved, 0, "nothing accrued");

        // The load-bearing assertion, and it must be about THE HOOK'S OWN arithmetic. An earlier
        // draft compared two fixture-side numbers and passed even against the broken mechanism.
        uint256 grossIn = _pmBal(c0) - pmBefore;
        assertEq(
            lastHookCreditedIn,
            grossIn - moved,
            "the hook credited the queue from the PRE-skim side, or absorbed a foreign pool's fee"
        );
    }
}
