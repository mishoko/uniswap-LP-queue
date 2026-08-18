// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {HardcapLP} from "./utils/HardcapLP.sol";
import {HardcapHook} from "../src/HardcapHook.sol";
import {HardcapHookFinal} from "../src/HardcapHookFinal.sol";
import {HardcapMath} from "../src/libraries/HardcapMath.sol";
import {HardcapOverSurplusHook, HardcapBugTakeHook, HardcapHarness} from "./hooks/HardcapAttackHooks.sol";

contract HardcapTest is BaseTest {
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint128 internal constant LIQUIDITY = 1_000e18;
    uint256 internal constant SWAP_IN = 1e18;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    HardcapHook hook;
    HardcapLP lp;
    int24 tickLower;
    int24 tickUpper;
    bytes32 salt;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        _approve(address(lp));

        hook = _deployHardcap("HardcapHook.sol:HardcapHook", 0x4444);
        poolKey = hook.boundPoolKey();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        salt = bytes32(0);

        lp.modifyLiquidity(poolKey, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);
        // Seed LP is aged so later tests can isolate JIT actors.
        vm.roll(block.number + 1);
    }

    // -------------------------------------------------------------------------
    // Cork
    // -------------------------------------------------------------------------

    function test_revert_directCallback() public {
        SwapParams memory swapParams = _swapParams(-int256(SWAP_IN));
        ModifyLiquidityParams memory liq = _addParams(1, salt);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, swapParams, Constants.ZERO_BYTES);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, Constants.ZERO_BYTES);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterAddLiquidity(
            address(this),
            poolKey,
            liq,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            Constants.ZERO_BYTES
        );

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), poolKey, liq, Constants.ZERO_BYTES);
    }

    function test_revert_nonEmptyHookData() public {
        bytes memory junk = hex"01";

        _expectHookRevert(
            address(hook), IHooks.beforeSwap.selector, abi.encodeWithSelector(HardcapHook.HookDataNotAllowed.selector)
        );
        _swap(poolKey, true, SWAP_IN, junk);

        _expectHookRevert(
            address(hook),
            IHooks.afterAddLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.HookDataNotAllowed.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(1e18, bytes32(uint256(2))), junk);

        _expectHookRevert(
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.HookDataNotAllowed.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(-1e18, salt), junk);
    }

    function test_revert_wrongPoolKey() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(hook));
        poolManager.initialize(other, Constants.SQRT_PRICE_1_1);

        _expectHookRevert(
            address(hook), IHooks.beforeSwap.selector, abi.encodeWithSelector(HardcapHook.InvalidPoolKey.selector)
        );
        _swap(other, true, SWAP_IN, Constants.ZERO_BYTES);

        _expectHookRevert(
            address(hook),
            IHooks.afterAddLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.InvalidPoolKey.selector)
        );
        lp.modifyLiquidity(other, _addParams(int256(uint256(LIQUIDITY)), bytes32(uint256(9))), Constants.ZERO_BYTES);
    }

    // -------------------------------------------------------------------------
    // Cap
    // -------------------------------------------------------------------------

    function test_take_clampedToMaxBps() public {
        HardcapOverSurplusHook clampHook =
            HardcapOverSurplusHook(address(_deployHardcap("HardcapAttackHooks.sol:HardcapOverSurplusHook", 0x5555)));
        PoolKey memory clampKey = clampHook.boundPoolKey();
        poolManager.initialize(clampKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(clampKey, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);

        PoolKey memory vanillaKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(vanillaKey, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);

        BalanceDelta vanilla = _swap(vanillaKey, true, SWAP_IN, Constants.ZERO_BYTES);
        uint256 vanillaOut = uint256(uint128(vanilla.amount1()));

        BalanceDelta hooked = _swap(clampKey, true, SWAP_IN, Constants.ZERO_BYTES);
        uint256 userOut = uint256(uint128(hooked.amount1()));
        uint256 take = clampHook.vaultAccrued(currency1);
        uint256 cap = HardcapMath.capOf(vanillaOut, HardcapMath.DEFAULT_MAX_TAKE_BPS);

        assertEq(take, cap, "take must equal cap when surplus is 100%");
        assertEq(userOut + take, vanillaOut, "user + take = pre-take unspecified");
        assertTrue(take < vanillaOut, "user swap still succeeds; leftover is clamped not reverted");
    }

    function test_take_neverExceedsCap_fuzz(uint256 notional, uint256 surplus, uint16 maxBps) public pure {
        maxBps = uint16(bound(maxBps, 0, HardcapMath.BPS_DENOMINATOR));
        uint256 take = HardcapMath.boundTake(notional, surplus, maxBps);
        uint256 cap = HardcapMath.capOf(notional, maxBps);
        assertLe(take, cap);
        if (surplus <= cap) assertEq(take, surplus);
        else assertEq(take, cap);
    }

    function test_revert_overCredit() public {
        HardcapHarness harness =
            HardcapHarness(address(_deployHardcap("HardcapAttackHooks.sol:HardcapHarness", 0x6666)));
        vm.expectRevert(abi.encodeWithSelector(HardcapMath.TakeExceedsCap.selector, 100, 15));
        harness.exposedCredit(currency0, 100, 15);
    }

    function test_revert_bugPathOverTake() public {
        HardcapBugTakeHook bugHook =
            HardcapBugTakeHook(address(_deployHardcap("HardcapAttackHooks.sol:HardcapBugTakeHook", 0x7777)));
        PoolKey memory bugKey = bugHook.boundPoolKey();
        poolManager.initialize(bugKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(bugKey, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);

        PoolKey memory vanillaKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(vanillaKey, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);
        uint256 notional = uint256(uint128(_swap(vanillaKey, true, SWAP_IN, Constants.ZERO_BYTES).amount1()));
        uint256 cap = HardcapMath.capOf(notional, HardcapMath.DEFAULT_MAX_TAKE_BPS);

        // Bug hook tries to take 100% of unspecified; credit rail must revert the unlock.
        _expectHookRevert(
            address(bugHook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(HardcapMath.TakeExceedsCap.selector, notional, cap)
        );
        _swap(bugKey, true, SWAP_IN, Constants.ZERO_BYTES);
        assertEq(bugHook.vaultAccrued(currency1), 0);
    }

    // -------------------------------------------------------------------------
    // JIT
    // -------------------------------------------------------------------------

    function test_revert_sameBlockAddRemove() public {
        bytes32 jitSalt = bytes32(uint256(1));
        lp.modifyLiquidity(poolKey, _addParams(1e18, jitSalt), Constants.ZERO_BYTES);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);

        _expectHookRevert(
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(-1e18, jitSalt), Constants.ZERO_BYTES);
    }

    function test_jitCannotClaimVault() public {
        bytes32 jitSalt = bytes32(uint256(2));
        lp.modifyLiquidity(poolKey, _addParams(1e18, jitSalt), Constants.ZERO_BYTES);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);

        vm.expectRevert(HardcapHook.PositionNotAged.selector);
        lp.claim(hook, tickLower, tickUpper, jitSalt);
    }

    function test_agedLpCanClaim() public {
        uint256 vaultBefore0 = hook.vaultAccrued(currency0);
        uint256 vaultBefore1 = hook.vaultAccrued(currency1);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        uint256 accrued0 = hook.vaultAccrued(currency0) - vaultBefore0;
        uint256 accrued1 = hook.vaultAccrued(currency1) - vaultBefore1;
        assertGt(accrued0 + accrued1, 0, "swap must accrue vault");

        uint256 bal0 = currency0.balanceOf(address(this));
        uint256 bal1 = currency1.balanceOf(address(this));
        lp.claim(hook, tickLower, tickUpper, salt);

        assertEq(hook.shares(hook.positionKeyOf(address(lp), tickLower, tickUpper, salt)), 0);
        assertEq(hook.totalShares(), 0);
        assertEq(hook.vaultAccrued(currency0), 0);
        assertEq(hook.vaultAccrued(currency1), 0);
        assertEq(currency0.balanceOf(address(this)), bal0 + accrued0);
        assertEq(currency1.balanceOf(address(this)), bal1 + accrued1);

        vm.expectRevert(HardcapHook.NoShares.selector);
        lp.claim(hook, tickLower, tickUpper, salt);
    }

    function test_increaseLiquidityUpdatesLastAddBlock() public {
        bytes32 topUpSalt = bytes32(uint256(3));
        lp.modifyLiquidity(poolKey, _addParams(1e18, topUpSalt), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);

        lp.modifyLiquidity(poolKey, _addParams(5e17, topUpSalt), Constants.ZERO_BYTES);

        _expectHookRevert(
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(-1e17, topUpSalt), Constants.ZERO_BYTES);

        vm.roll(block.number + 1);
        lp.modifyLiquidity(poolKey, _addParams(-1e17, topUpSalt), Constants.ZERO_BYTES);
    }

    function test_differentSaltIsDifferentPosition() public {
        bytes32 saltA = bytes32(uint256(10));
        bytes32 saltB = bytes32(uint256(11));

        lp.modifyLiquidity(poolKey, _addParams(1e18, saltA), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        lp.modifyLiquidity(poolKey, _addParams(1e18, saltB), Constants.ZERO_BYTES);

        lp.modifyLiquidity(poolKey, _addParams(-1e18, saltA), Constants.ZERO_BYTES);

        _expectHookRevert(
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(-1e18, saltB), Constants.ZERO_BYTES);
    }

    // -------------------------------------------------------------------------
    // Vault
    // -------------------------------------------------------------------------

    function test_ownerCannotDrainVault() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        assertGt(hook.vaultAccrued(currency1), 0);

        (bool ok,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner()");
        (ok,) = address(hook)
            .call(abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(0), address(this), 1));
        assertFalse(ok, "no rescueTokens");
        (ok,) = address(hook).call(abi.encodeWithSignature("sweep(address)", address(0)));
        assertFalse(ok, "no sweep");
        (ok,) = address(hook).call(abi.encodeWithSignature("withdraw(uint256)", 1));
        assertFalse(ok, "no withdraw");
        (ok,) = address(hook)
            .call(abi.encodeWithSignature("donate((address,address,uint24,int24,address),uint256,uint256,bytes)"));
        assertFalse(ok, "no donate wrapper");

        address thief = address(0xBEEF);
        vm.prank(thief);
        vm.expectRevert(HardcapHook.NoShares.selector);
        hook.claim(tickLower, tickUpper, salt);

        vm.prank(address(this));
        vm.expectRevert(HardcapHook.NoShares.selector);
        hook.claim(tickLower, tickUpper, salt);
    }

    function test_fullRemoveBurnsSharesCannotClaim() public {
        bytes32 s = bytes32(uint256(20));
        lp.modifyLiquidity(poolKey, _addParams(1e18, s), Constants.ZERO_BYTES);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        vm.roll(block.number + 1);

        lp.modifyLiquidity(poolKey, _addParams(-1e18, s), Constants.ZERO_BYTES);
        vm.expectRevert(HardcapHook.NoShares.selector);
        lp.claim(hook, tickLower, tickUpper, s);
    }

    function test_recycleDoesNotStackShares() public {
        bytes32 s = bytes32(uint256(21));
        lp.modifyLiquidity(poolKey, _addParams(1e18, s), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        lp.modifyLiquidity(poolKey, _addParams(-1e18, s), Constants.ZERO_BYTES);

        lp.modifyLiquidity(poolKey, _addParams(1e18, s), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);

        bytes32 key = hook.positionKeyOf(address(lp), tickLower, tickUpper, s);
        assertEq(hook.pendingShares(key) + hook.shares(key), 1e18);
        lp.modifyLiquidity(poolKey, _addParams(-1e18, s), Constants.ZERO_BYTES);
        assertEq(hook.shares(key), 0);
        assertEq(hook.pendingShares(key), 0);
    }

    function test_unagedDilutesButCannotClaim() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        uint256 accrued1 = hook.vaultAccrued(currency1);
        assertGt(accrued1, 0);

        HardcapLP attacker = new HardcapLP(poolManager);
        _approve(address(attacker));
        attacker.modifyLiquidity(
            poolKey, _addParams(int256(uint256(LIQUIDITY) * 10), bytes32(uint256(22))), Constants.ZERO_BYTES
        );

        uint256 bal1 = currency1.balanceOf(address(this));
        lp.claim(hook, tickLower, tickUpper, salt);
        uint256 got = currency1.balanceOf(address(this)) - bal1;
        assertLt(got, accrued1, "unaged L dilutes the denom");
        assertGt(hook.vaultAccrued(currency1), 0);

        vm.expectRevert(HardcapHook.PositionNotAged.selector);
        attacker.claim(hook, tickLower, tickUpper, bytes32(uint256(22)));
    }

    function test_zeroDeltaCollectSameBlockAsAddReverts() public {
        bytes32 s = bytes32(uint256(40));
        lp.modifyLiquidity(poolKey, _addParams(1e18, s), Constants.ZERO_BYTES);
        _expectHookRevert(
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(0, s), Constants.ZERO_BYTES);
    }

    function test_claimThenAddThenClaimAgainAfterOffset() public {
        bytes32 key = hook.positionKeyOf(address(lp), tickLower, tickUpper, salt);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        lp.claim(hook, tickLower, tickUpper, salt);
        assertEq(hook.vaultAccrued(currency1), 0);

        lp.modifyLiquidity(poolKey, _addParams(1e18, salt), Constants.ZERO_BYTES);
        assertEq(hook.pendingShares(key) + hook.shares(key), 1e18);
        assertEq(hook.pendingTotal(), 1e18);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        vm.expectRevert(HardcapHook.PositionNotAged.selector);
        lp.claim(hook, tickLower, tickUpper, salt);

        vm.roll(block.number + 1);
        uint256 vault = hook.vaultAccrued(currency1);
        assertGt(vault, 0);
        lp.claim(hook, tickLower, tickUpper, salt);
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_claimThenFullRemove_succeedsAndConservesTotals() public {
        bytes32 key = hook.positionKeyOf(address(lp), tickLower, tickUpper, salt);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        lp.claim(hook, tickLower, tickUpper, salt);
        assertEq(hook.totalShares(), 0);
        assertEq(hook.pendingTotal(), 0);

        lp.modifyLiquidity(poolKey, _addParams(-int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);
        assertEq(hook.totalShares(), 0);
        assertEq(hook.pendingTotal(), 0);
        assertEq(hook.shares(key), 0);
        assertEq(hook.pendingShares(key), 0);
    }

    function test_addThenTopUpThenRemoveSameBlock_reverts() public {
        bytes32 s = bytes32(uint256(60));
        lp.modifyLiquidity(poolKey, _addParams(1e18, s), Constants.ZERO_BYTES);
        lp.modifyLiquidity(poolKey, _addParams(5e17, s), Constants.ZERO_BYTES);
        _expectHookRevert(
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(-1e17, s), Constants.ZERO_BYTES);
    }

    function test_zeroDeltaCollectAfterOffset_succeedsAndDoesNotBurnShares() public {
        bytes32 s = bytes32(uint256(61));
        lp.modifyLiquidity(poolKey, _addParams(1e18, s), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        bytes32 key = hook.positionKeyOf(address(lp), tickLower, tickUpper, s);
        uint256 before = hook.shares(key) + hook.pendingShares(key);
        lp.modifyLiquidity(poolKey, _addParams(0, s), Constants.ZERO_BYTES);
        assertEq(hook.shares(key) + hook.pendingShares(key), before);
    }

    function test_sameLockerTwoSaltsSplitVault() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        lp.claim(hook, tickLower, tickUpper, salt);

        bytes32 a = bytes32(uint256(41));
        bytes32 b = bytes32(uint256(42));
        lp.modifyLiquidity(poolKey, _addParams(10e18, a), Constants.ZERO_BYTES);
        lp.modifyLiquidity(poolKey, _addParams(10e18, b), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        uint256 vault = hook.vaultAccrued(currency1);

        uint256 bal = currency1.balanceOf(address(this));
        lp.claim(hook, tickLower, tickUpper, a);
        uint256 gotA = currency1.balanceOf(address(this)) - bal;
        assertEq(gotA, vault / 2);
        lp.claim(hook, tickLower, tickUpper, b);
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_fullExitForfeitsInFavorOfOtherLocker() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        lp.claim(hook, tickLower, tickUpper, salt);

        HardcapLP other = new HardcapLP(poolManager);
        _approve(address(other));
        bytes32 s = bytes32(uint256(43));
        lp.modifyLiquidity(poolKey, _addParams(10e18, s), Constants.ZERO_BYTES);
        other.modifyLiquidity(poolKey, _addParams(10e18, bytes32(uint256(44))), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);

        lp.modifyLiquidity(poolKey, _addParams(-10e18, s), Constants.ZERO_BYTES);
        uint256 vault = hook.vaultAccrued(currency1);
        uint256 bal = currency1.balanceOf(address(this));
        other.claim(hook, tickLower, tickUpper, bytes32(uint256(44)));
        assertEq(currency1.balanceOf(address(this)) - bal, vault);
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_oneBlockLpStillEarnsNativeFee() public {
        HardcapLP jit = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).transfer(address(jit), 200e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(jit), 200e18);
        bytes32 s = bytes32(uint256(50));

        uint256 c0Before = currency0.balanceOf(address(jit));
        uint256 c1Before = currency1.balanceOf(address(jit));
        jit.modifyLiquiditySelf(poolKey, _addParams(50e18, s), Constants.ZERO_BYTES);
        _swap(poolKey, true, 20e18, Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        jit.modifyLiquiditySelf(poolKey, _addParams(-50e18, s), Constants.ZERO_BYTES);

        // Native 0.30% still accrued to the in-range JIT. Hook only blocked same-block exit + vault.
        assertGt(
            currency0.balanceOf(address(jit)) + currency1.balanceOf(address(jit)),
            c0Before + c1Before,
            "one-block LP still earns native fees"
        );
        vm.expectRevert(HardcapHook.NoShares.selector);
        jit.claim(hook, tickLower, tickUpper, s);
    }

    function test_tightRangeDominatesVaultClaim() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        lp.claim(hook, tickLower, tickUpper, salt);

        uint256 budget0 = 20e18;
        uint256 budget1 = 20e18;
        int24 tightLo = -TICK_SPACING;
        int24 tightHi = TICK_SPACING;

        uint128 lFull = LiquidityAmounts.getLiquidityForAmounts(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            budget0,
            budget1
        );
        uint128 lTight = LiquidityAmounts.getLiquidityForAmounts(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tightLo),
            TickMath.getSqrtPriceAtTick(tightHi),
            budget0,
            budget1
        );
        assertGt(lTight, lFull, "same tokens mint more L in a tight range");

        HardcapLP fullLp = new HardcapLP(poolManager);
        HardcapLP tightLp = new HardcapLP(poolManager);
        _approve(address(fullLp));
        _approve(address(tightLp));
        fullLp.modifyLiquidity(poolKey, _addParams(int256(uint256(lFull)), bytes32(uint256(51))), Constants.ZERO_BYTES);
        tightLp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tightLo, tickUpper: tightHi, liquidityDelta: int256(uint256(lTight)), salt: bytes32(uint256(52))
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);

        uint256 vault = hook.vaultAccrued(currency1);
        uint256 bal = currency1.balanceOf(address(this));
        tightLp.claim(hook, tightLo, tightHi, bytes32(uint256(52)));
        uint256 tightGot = currency1.balanceOf(address(this)) - bal;
        fullLp.claim(hook, tickLower, tickUpper, bytes32(uint256(51)));
        assertGt(tightGot, vault - tightGot, "tight-range L takes the majority of the vault");
    }

    function test_unagedAddThenClaimNextBlockCapturesRemainder() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        uint256 vault = hook.vaultAccrued(currency1);

        HardcapLP attacker = new HardcapLP(poolManager);
        _approve(address(attacker));
        attacker.modifyLiquidity(
            poolKey, _addParams(int256(uint256(LIQUIDITY) * 10), bytes32(uint256(53))), Constants.ZERO_BYTES
        );

        uint256 bal = currency1.balanceOf(address(this));
        lp.claim(hook, tickLower, tickUpper, salt);
        uint256 honestGot = currency1.balanceOf(address(this)) - bal;
        uint256 leftover = hook.vaultAccrued(currency1);
        assertGt(leftover, 0);
        assertLt(honestGot, vault);

        vm.roll(block.number + 1);
        bal = currency1.balanceOf(address(this));
        attacker.claim(hook, tickLower, tickUpper, bytes32(uint256(53)));
        assertEq(currency1.balanceOf(address(this)) - bal, leftover);
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_tinySwapTakeFloorsToZero() public {
        uint256 before = hook.vaultAccrued(currency1);
        _swap(poolKey, true, 1, Constants.ZERO_BYTES);
        assertEq(hook.vaultAccrued(currency1), before);
    }

    function test_claimRequiresPositionOwnerNotEoa() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        vm.expectRevert(HardcapHook.NoShares.selector);
        hook.claim(tickLower, tickUpper, salt);
        lp.claim(hook, tickLower, tickUpper, salt);
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_vanillaVsHardcap_sameSwaps_vaultAccruesExtra() public {
        PoolKey memory vanillaKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(vanillaKey, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);

        uint256 vaultBefore = hook.vaultAccrued(currency1);
        BalanceDelta vanilla = _swap(vanillaKey, true, SWAP_IN, Constants.ZERO_BYTES);
        BalanceDelta hooked = _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);

        uint256 take = hook.vaultAccrued(currency1) - vaultBefore;
        assertGt(take, 0, "Hardcap vault grows");
        assertEq(uint256(uint128(vanilla.amount1())), uint256(uint128(hooked.amount1())) + take);
        assertEq(take, HardcapMath.surplusOf(uint256(uint128(vanilla.amount1())), HardcapMath.DEFAULT_EXTRA_FEE_BPS));
    }

    function test_take_exactOut_chargesUnspecifiedInput() public {
        PoolKey memory vanillaKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(
            vanillaKey, _addParams(int256(uint256(LIQUIDITY)), bytes32(uint256(4))), Constants.ZERO_BYTES
        );

        uint256 amountOut = 1e17;
        BalanceDelta vanilla = swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: 1e18,
            zeroForOne: true,
            poolKey: vanillaKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        BalanceDelta hooked = swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: 1e18,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 vanillaIn = uint256(uint128(-vanilla.amount0()));
        uint256 hookedIn = uint256(uint128(-hooked.amount0()));
        uint256 take = hook.vaultAccrued(currency0);
        assertGt(take, 0);
        assertEq(hookedIn, vanillaIn + take, "exact-out take is extra input");
        assertEq(take, HardcapMath.surplusOf(vanillaIn, HardcapMath.DEFAULT_EXTRA_FEE_BPS));
    }

    function test_twoAgedLockersSplitVault() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        lp.claim(hook, tickLower, tickUpper, salt);

        HardcapLP a = new HardcapLP(poolManager);
        HardcapLP b = new HardcapLP(poolManager);
        _approve(address(a));
        _approve(address(b));
        a.modifyLiquidity(poolKey, _addParams(10e18, bytes32(uint256(30))), Constants.ZERO_BYTES);
        b.modifyLiquidity(poolKey, _addParams(10e18, bytes32(uint256(31))), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);

        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        uint256 vault = hook.vaultAccrued(currency1);
        assertGt(vault, 0);

        uint256 balA = currency1.balanceOf(address(this));
        a.claim(hook, tickLower, tickUpper, bytes32(uint256(30)));
        uint256 gotA = currency1.balanceOf(address(this)) - balA;
        assertEq(gotA, vault / 2);

        uint256 balB = currency1.balanceOf(address(this));
        b.claim(hook, tickLower, tickUpper, bytes32(uint256(31)));
        uint256 gotB = currency1.balanceOf(address(this)) - balB;
        assertEq(gotA + gotB, vault);
        assertEq(hook.vaultAccrued(currency1), 0);
    }

    function test_partialRemoveThenClaimRemaining() public {
        bytes32 s = bytes32(uint256(32));
        lp.modifyLiquidity(poolKey, _addParams(2e18, s), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        lp.modifyLiquidity(poolKey, _addParams(-1e18, s), Constants.ZERO_BYTES);

        bytes32 key = hook.positionKeyOf(address(lp), tickLower, tickUpper, s);
        assertEq(hook.shares(key), 1e18);
        assertEq(hook.pendingShares(key), 0);

        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        lp.claim(hook, tickLower, tickUpper, s);
        assertEq(hook.shares(key), 0);
    }

    function test_partialRemoveThenAddSameBlockRefreshesLock() public {
        lp.modifyLiquidity(poolKey, _addParams(-1e18, salt), Constants.ZERO_BYTES);
        lp.modifyLiquidity(poolKey, _addParams(1e18, salt), Constants.ZERO_BYTES);

        _expectHookRevert(
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector)
        );
        lp.modifyLiquidity(poolKey, _addParams(-1e18, salt), Constants.ZERO_BYTES);
    }

    function test_offsetWindow_blocksUntilOffsetElapses() public {
        HardcapHook wide = _deployHardcapWith(
            "HardcapHook.sol:HardcapHook",
            0x9999,
            HardcapMath.DEFAULT_EXTRA_FEE_BPS,
            HardcapMath.DEFAULT_MAX_TAKE_BPS,
            2
        );
        PoolKey memory wideKey = wide.boundPoolKey();
        poolManager.initialize(wideKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(wideKey, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);

        vm.roll(block.number + 1);
        _expectHookRevert(
            address(wide),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(HardcapHook.RemoveTooSoon.selector)
        );
        lp.modifyLiquidity(wideKey, _addParams(-1e18, salt), Constants.ZERO_BYTES);
        vm.expectRevert(HardcapHook.PositionNotAged.selector);
        lp.claim(wide, tickLower, tickUpper, salt);

        vm.roll(block.number + 1);
        lp.modifyLiquidity(wideKey, _addParams(-1e18, salt), Constants.ZERO_BYTES);
    }

    function test_finalHook_swapAndClaim() public {
        HardcapHookFinal sealedHook = HardcapHookFinal(
            address(
                _deployHardcapWith(
                    "HardcapHookFinal.sol:HardcapHookFinal",
                    0xB001,
                    HardcapMath.DEFAULT_EXTRA_FEE_BPS,
                    HardcapMath.DEFAULT_MAX_TAKE_BPS,
                    HardcapMath.DEFAULT_OFFSET
                )
            )
        );
        PoolKey memory key = sealedHook.boundPoolKey();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(key, _addParams(int256(uint256(LIQUIDITY)), salt), Constants.ZERO_BYTES);
        vm.roll(block.number + 1);
        _swap(key, true, SWAP_IN, Constants.ZERO_BYTES);
        assertGt(sealedHook.vaultAccrued(currency1), 0);
        lp.claim(sealedHook, tickLower, tickUpper, salt);
        assertEq(sealedHook.vaultAccrued(currency1), 0);
    }

    function test_constructor_rejectsNativeExtraAboveMaxAndZeroOffset() public {
        vm.expectRevert(HardcapHook.NativeCurrencyNotSupported.selector);
        _deployHardcapWith(
            "HardcapHook.sol:HardcapHook",
            0xA001,
            HardcapMath.DEFAULT_EXTRA_FEE_BPS,
            HardcapMath.DEFAULT_MAX_TAKE_BPS,
            1,
            Currency.wrap(address(0)),
            currency1
        );

        vm.expectRevert(HardcapHook.InvalidCurrencyOrder.selector);
        _deployHardcapWith(
            "HardcapHook.sol:HardcapHook",
            0xA002,
            HardcapMath.DEFAULT_EXTRA_FEE_BPS,
            HardcapMath.DEFAULT_MAX_TAKE_BPS,
            1,
            currency1,
            currency0
        );

        vm.expectRevert(HardcapHook.ExtraFeeExceedsCap.selector);
        _deployHardcapWith("HardcapHook.sol:HardcapHook", 0xA003, 16, 15, 1);

        vm.expectRevert(HardcapHook.InvalidMaxTakeBps.selector);
        _deployHardcapWith("HardcapHook.sol:HardcapHook", 0xA004, 0, 10_001, 1);

        vm.expectRevert(HardcapHook.OffsetTooLow.selector);
        _deployHardcapWith(
            "HardcapHook.sol:HardcapHook",
            0xA005,
            HardcapMath.DEFAULT_EXTRA_FEE_BPS,
            HardcapMath.DEFAULT_MAX_TAKE_BPS,
            0
        );
    }

    function test_hookBalanceMatchesVaultAccrued() public {
        _swap(poolKey, true, SWAP_IN, Constants.ZERO_BYTES);
        assertEq(currency1.balanceOf(address(hook)), hook.vaultAccrued(currency1));
        assertEq(currency0.balanceOf(address(hook)), hook.vaultAccrued(currency0));
    }

    function test_take_exactOut_oneForZero() public {
        PoolKey memory vanillaKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(
            vanillaKey, _addParams(int256(uint256(LIQUIDITY)), bytes32(uint256(6))), Constants.ZERO_BYTES
        );

        uint256 amountOut = 1e17;
        uint256 vaultBefore = hook.vaultAccrued(currency1);
        BalanceDelta vanilla = swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: 1e18,
            zeroForOne: false,
            poolKey: vanillaKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        BalanceDelta hooked = swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: 1e18,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 take = hook.vaultAccrued(currency1) - vaultBefore;
        uint256 vanillaIn = uint256(uint128(-vanilla.amount1()));
        uint256 hookedIn = uint256(uint128(-hooked.amount1()));
        assertGt(take, 0);
        assertEq(hookedIn, vanillaIn + take);
        assertEq(take, HardcapMath.surplusOf(vanillaIn, HardcapMath.DEFAULT_EXTRA_FEE_BPS));
    }

    function test_take_oneForZero_chargesUnspecifiedOutput() public {
        PoolKey memory vanillaKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(
            vanillaKey, _addParams(int256(uint256(LIQUIDITY)), bytes32(uint256(5))), Constants.ZERO_BYTES
        );

        uint256 vaultBefore = hook.vaultAccrued(currency0);
        BalanceDelta vanilla = _swap(vanillaKey, false, SWAP_IN, Constants.ZERO_BYTES);
        BalanceDelta hooked = _swap(poolKey, false, SWAP_IN, Constants.ZERO_BYTES);

        uint256 take = hook.vaultAccrued(currency0) - vaultBefore;
        assertGt(take, 0);
        assertEq(uint256(uint128(vanilla.amount0())), uint256(uint128(hooked.amount0())) + take);
        assertEq(take, HardcapMath.surplusOf(uint256(uint128(vanilla.amount0())), HardcapMath.DEFAULT_EXTRA_FEE_BPS));
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _permissions() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
    }

    function _deployHardcap(string memory what, uint160 ns) internal returns (HardcapHook deployed) {
        return _deployHardcapWith(
            what,
            ns,
            HardcapMath.DEFAULT_EXTRA_FEE_BPS,
            HardcapMath.DEFAULT_MAX_TAKE_BPS,
            HardcapMath.DEFAULT_OFFSET,
            currency0,
            currency1
        );
    }

    function _deployHardcapWith(string memory what, uint160 ns, uint16 extra, uint16 maxBps, uint48 off)
        internal
        returns (HardcapHook)
    {
        return _deployHardcapWith(what, ns, extra, maxBps, off, currency0, currency1);
    }

    function _deployHardcapWith(
        string memory what,
        uint160 ns,
        uint16 extra,
        uint16 maxBps,
        uint48 off,
        Currency c0,
        Currency c1
    ) internal returns (HardcapHook deployed) {
        address flags = address(uint160(_permissions()) ^ (ns << 144));
        bytes memory args = abi.encode(poolManager, c0, c1, FEE, TICK_SPACING, extra, maxBps, off);
        deployCodeTo(what, args, flags);
        deployed = HardcapHook(flags);
    }

    function _approve(address spender) internal {
        MockERC20(Currency.unwrap(currency0)).approve(spender, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(spender, type(uint256).max);
    }

    function _addParams(int256 liquidityDelta, bytes32 s) internal view returns (ModifyLiquidityParams memory) {
        return
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: s});
    }

    function _swapParams(int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _expectHookRevert(address target, bytes4 hookFn, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                target,
                hookFn,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
