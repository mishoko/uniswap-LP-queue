// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// RESEARCH ARTEFACT — PLAN §E.5 protocol-fee exposure. NOT production code, NOT a Phase-1 gate test.
// Run with:  FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/protocol-fee forge test -vv

import {BaseTest} from "../../../archive/2026-08-26/test/utils/BaseTest.sol";
import {QueueHook} from "../../../archive/2026-08-26/test/spike/QueueAllocator.t.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice A copy of the spike hook with the PLAN §E.5 (P1) "refuse" guard bolted into _afterSwap
///         ONLY. Used to answer: does refusing also brick withdrawals?
contract RefusingHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;

    struct Entry {
        uint256 a0;
        uint256 a1;
    }

    Entry[] public q;
    PoolKey public key;
    int24 public tl;
    int24 public tu;
    uint128 public liq;

    error ProtocolFeeIsOn(uint24 fee);

    constructor(IPoolManager pm) BaseHook(pm) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.afterSwap = true;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        require(sender == address(this), "QUEUE: hook is sole LP");
        return BaseHook.beforeAddLiquidity.selector;
    }

    uint256 public lastGuardGas;

    function _afterSwap(address, PoolKey calldata k, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 g = gasleft();
        (,, uint24 pf,) = poolManager.getSlot0(k.toId());
        lastGuardGas = g - gasleft();
        if (pf != 0) revert ProtocolFeeIsOn(pf);
        return (BaseHook.afterSwap.selector, 0);
    }

    function seed(PoolKey calldata k, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        key = k;
        tl = tickLower;
        tu = tickUpper;
        liq = liquidity;
        poolManager.unlock(abi.encode(int256(uint256(liquidity))));
    }

    function redeemAll() external returns (uint256 g0, uint256 g1) {
        uint256 b0 = _bal(key.currency0);
        uint256 b1 = _bal(key.currency1);
        poolManager.unlock(abi.encode(-int256(uint256(liq))));
        g0 = _bal(key.currency0) - b0;
        g1 = _bal(key.currency1) - b1;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm");
        int256 ld = abi.decode(data, (int256));
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: ld, salt: bytes32(0)}), ""
        );
        _resolve(key.currency0, d.amount0());
        _resolve(key.currency1, d.amount1());
        return "";
    }

    function _resolve(Currency c, int128 amt) internal {
        if (amt < 0) {
            poolManager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(poolManager), uint256(uint128(-amt)));
            poolManager.settle();
        } else if (amt > 0) {
            poolManager.take(c, address(this), uint256(uint128(amt)));
        }
    }

    function _bal(Currency c) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this));
    }
}

contract ProtocolFeeExposureTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint128 constant LIQ = 1_000e18;
    address constant PM_OWNER = address(0x4444);

    Currency c0;
    Currency c1;
    QueueHook hook;
    PoolKey k;

    uint256 expT0;
    uint256 expT1;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        vm.roll(100);
        // become the protocol fee controller
        vm.prank(PM_OWNER);
        poolManager.setProtocolFeeController(address(this));
    }

    function _deploy(uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueAllocator.t.sol:QueueHook", abi.encode(poolManager, uint8(0)), a);
        hook = QueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 100_000e18);
        MockERC20(Currency.unwrap(c1)).mint(a, 100_000e18);
    }

    function _open(uint24 protoFee) internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        if (protoFee != 0) poolManager.setProtocolFee(k, protoFee);
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        (uint256 s0, uint256 s1) = hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        expT0 = s0;
        expT1 = s1;
    }

    /// @dev LAW-3 style measurement: PoolManager's OWN ERC20 balances.
    function _swap(bool zeroForOne, uint256 amountIn) internal {
        uint256 p0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 p1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
        uint256 n0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
        uint256 n1 = MockERC20(Currency.unwrap(c1)).balanceOf(address(poolManager));
        if (zeroForOne) {
            expT0 += (n0 - p0);
            expT1 -= (p1 - n1);
        } else {
            expT1 += (n1 - p1);
            expT0 -= (p0 - n0);
        }
    }

    function _scenario() internal {
        _swap(true, 4e18);
        _swap(true, 300e18);
        _swap(true, 50e18);
        _swap(false, 20e18);
    }

    // =========================================================================================
    // EXPERIMENT 1 — does a nonzero protocol fee break the ledger, and does LAW-3 conservation
    //                notice?  protoFee = 1000 pips (0.1%) = v4's MAX, both directions.
    // =========================================================================================
    function _run(uint24 protoFee, uint160 nonce) internal returns (uint256 t0, uint256 t1, uint256 g0, uint256 g1) {
        _deploy(nonce);
        _open(protoFee);
        _scenario();
        (t0, t1) = hook.totals();

        emit log_named_uint("  ledger t0                        ", t0);
        emit log_named_uint("  PoolManager-ERC20-measured expT0 ", expT0);
        emit log_named_uint("  ledger t1                        ", t1);
        emit log_named_uint("  PoolManager-ERC20-measured expT1 ", expT1);
        emit log_named_uint("  protocolFeesAccrued c0           ", poolManager.protocolFeesAccrued(c0));
        emit log_named_uint("  protocolFeesAccrued c1           ", poolManager.protocolFeesAccrued(c1));

        // THE PLAN'S OWN PROPOSED TEST (PLAN.md:2092 "set a protocol fee, run the conservation test")
        assertEq(t0, expT0, "LAW-3 conservation token0");
        assertEq(t1, expT1, "LAW-3 conservation token1");

        (g0, g1) = hook.redeemAll();
        emit log_named_uint("  redeemed token0 (real ERC20)     ", g0);
        emit log_named_uint("  redeemed token1 (real ERC20)     ", g1);
        emit log_named_int("  SHORTFALL token0 (redeemed-ledger)", int256(g0) - int256(t0));
        emit log_named_int("  SHORTFALL token1 (redeemed-ledger)", int256(g1) - int256(t1));
    }

    function test_E5_protocolFeeZero_baseline() public {
        emit log("=== protocolFee = 0 (the spike's world) ===");
        _run(0, 0x1111);
    }

    function test_E5_protocolFeeMax_ledgerOvercredits() public {
        emit log("=== protocolFee = 1000|1000 pips (0.1%, v4 MAX, both directions) ===");
        (uint256 t0,, uint256 g0,) = _run(uint24(1000) | (uint24(1000) << 12), 0x2222);
        uint256 accrued0 = poolManager.protocolFeesAccrued(c0);
        emit log_named_uint("  shortfall0 magnitude             ", t0 - g0);
        emit log_named_uint("  protocol fee accrued in token0   ", accrued0);
        emit log_named_int("  shortfall0 - accrued0            ", int256(t0 - g0) - int256(accrued0));
    }

    /// @dev Is the LP's fee income actually preserved when the protocol fee is on (i.e. is the
    ///      over-credit exactly the EXTRA the swapper paid, not stolen LP revenue)?
    function test_E5_swapperPaysMore_lpIncomeRoughlyUnchanged() public {
        _deploy(0x3333);
        _open(0);
        _swap(true, 100e18);
        (uint256 a0, uint256 a1) = hook.totals();
        (uint256 r0, uint256 r1) = hook.redeemAll();
        emit log_named_int("ZERO-FEE   redeem0 - ledger0", int256(r0) - int256(a0));
        emit log_named_int("ZERO-FEE   redeem1 - ledger1", int256(r1) - int256(a1));

        _deploy(0x4444);
        _open(uint24(1000) | (uint24(1000) << 12));
        _swap(true, 100e18);
        (uint256 b0, uint256 b1) = hook.totals();
        (uint256 s0, uint256 s1) = hook.redeemAll();
        emit log_named_int("PROTO-FEE  redeem0 - ledger0", int256(s0) - int256(b0));
        emit log_named_int("PROTO-FEE  redeem1 - ledger1", int256(s1) - int256(b1));
        emit log_named_uint("PROTO-FEE  protocolFeesAccrued c0", poolManager.protocolFeesAccrued(c0));
    }

    // =========================================================================================
    // EXPERIMENT 2 — (P1) "refuse if protocolFee != 0" placed in _afterSwap ONLY.
    //                Does it brick swaps?  Does it brick WITHDRAWAL (modifyLiquidity(-Δ))?
    // =========================================================================================
    function test_E5_P1_refuseInAfterSwap_doesNotBrickWithdrawal() public {
        address a = address(FLAGS ^ (uint160(0x5555) << 144));
        deployCodeTo("ProtocolFeeExposure.t.sol:RefusingHook", abi.encode(poolManager), a);
        RefusingHook rh = RefusingHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 100_000e18);
        MockERC20(Currency.unwrap(c1)).mint(a, 100_000e18);

        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(rh))});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        rh.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ);

        // fee OFF: swap works. Measure what the guard's slot0 read COSTS, cold.
        vm.cool(address(poolManager));
        swapRouter.swapExactTokensForTokens(4e18, 0, true, k, "", address(this), block.timestamp);
        emit log("swap with protocolFee=0: OK");
        emit log_named_uint("COLD  gas for the protocolFee slot0 read + branch", rh.lastGuardGas());
        swapRouter.swapExactTokensForTokens(4e18, 0, true, k, "", address(this), block.timestamp);
        emit log_named_uint("WARM  gas for the protocolFee slot0 read + branch", rh.lastGuardGas());

        // governance turns the fee ON, mid-life, with depositors' money in the pool
        poolManager.setProtocolFee(k, uint24(1000) | (uint24(1000) << 12));

        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(4e18, 0, true, k, "", address(this), block.timestamp);
        emit log("swap with protocolFee!=0: REVERTED (pool is dead)");

        // Q3: did the REVERTED swap leak any protocol fee? If the revert rolls back
        // _updateProtocolFees (PoolManager.sol:238) then the halt is leak-free.
        emit log_named_uint("protocolFeesAccrued c0 after the reverted swap", poolManager.protocolFeesAccrued(c0));
        emit log_named_uint("protocolFeesAccrued c1 after the reverted swap", poolManager.protocolFeesAccrued(c1));
        assertEq(poolManager.protocolFeesAccrued(c0), 0, "P1 leaked a protocol fee before halting");
        assertEq(poolManager.protocolFeesAccrued(c1), 0, "P1 leaked a protocol fee before halting");

        // THE QUESTION: can the LPs still get their money out?
        (uint256 g0, uint256 g1) = rh.redeemAll();
        emit log_named_uint("WITHDRAWAL after refusal, token0", g0);
        emit log_named_uint("WITHDRAWAL after refusal, token1", g1);
        assertGt(g0, 0, "withdrawal bricked - total loss");
        assertGt(g1, 0, "withdrawal bricked - total loss");
    }
}
