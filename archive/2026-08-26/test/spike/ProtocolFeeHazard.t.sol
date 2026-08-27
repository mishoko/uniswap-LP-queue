// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {IProtocolFees} from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";

/// @notice PROTOCOL-FEE HAZARD experiment (PLAN §E.5). The allocator below is a VERBATIM copy of
/// archive/2026-08-26/test/spike/QueueAllocator.t.sol's QueueHook (renamed only). NOT ONE LINE OF THE
/// ALLOCATOR WAS CHANGED. Only the fixture around it differs: a NONZERO PROTOCOL FEE on the pool.
///
/// Original header follows.
/// @notice QUEUE spike — is front-first allocation at the swap's realised average price EXACT?
///
/// The hook custodies the pool's whole liquidity as ONE position and keeps an ordered list of
/// entries. Every swap's aggregate entitlement (= the negation of the swapper's BalanceDelta) is
/// allocated FRONT-FIRST rather than pro-rata: the head entry surrenders as much of the outgoing
/// token as it holds and receives the incoming token at the swap's own realised average price.
///
/// MODE is the single switch separating the real allocator from three deliberate mutations, so the
/// negative controls run the identical test body against identical state.
contract PFQueueHook is BaseHook, IUnlockCallback {
    uint8 constant FRONT_FIRST = 0;
    uint8 constant PRO_RATA = 1; // mutation: v3/v4's actual behaviour
    uint8 constant OFF_BY_ONE = 2; // mutation: cursor starts at entry 1
    uint8 constant FLOOR_ONLY = 3; // mutation: no remainder assignment, every share floored

    uint8 public immutable mode;

    struct Entry {
        uint256 a0;
        uint256 a1;
    }

    Entry[] public q;

    PoolKey public key;
    int24 public tl;
    int24 public tu;
    uint128 public liq;

    uint256 public lastAllocGas;
    uint256 public entriesTouched;
    uint256 public swapsSeen;

    error PFQueueUnderflow(uint256 shortfall);

    constructor(IPoolManager pm, uint8 mode_) BaseHook(pm) {
        mode = mode_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.afterSwap = true;
    }

    function len() external view returns (uint256) {
        return q.length;
    }

    function entry(uint256 i) external view returns (uint256, uint256) {
        return (q[i].a0, q[i].a1);
    }

    function totals() external view returns (uint256 t0, uint256 t1) {
        for (uint256 i; i < q.length; i++) {
            t0 += q[i].a0;
            t1 += q[i].a1;
        }
    }

    // ------------------------------------------------------------------ liquidity

    /// @dev Only the hook may be an LP. Every external add is refused, so the hook's ledger is the
    ///      pool's ledger.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        require(sender == address(this), "QUEUE: hook is sole LP");
        return BaseHook.beforeAddLiquidity.selector;
    }

    function seed(PoolKey calldata k, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256[] calldata bps)
        external
        returns (uint256 c0, uint256 c1)
    {
        key = k;
        tl = tickLower;
        tu = tickUpper;
        liq = liquidity;
        bytes memory r = poolManager.unlock(abi.encode(int256(uint256(liquidity))));
        (c0, c1) = abi.decode(r, (uint256, uint256));

        uint256 s0;
        uint256 s1;
        for (uint256 i; i < bps.length; i++) {
            uint256 a0 = i == bps.length - 1 ? c0 - s0 : FullMath.mulDiv(c0, bps[i], 10_000);
            uint256 a1 = i == bps.length - 1 ? c1 - s1 : FullMath.mulDiv(c1, bps[i], 10_000);
            s0 += a0;
            s1 += a1;
            q.push(Entry(a0, a1));
        }
    }

    /// @dev Full teardown: burn the position, collect fees, and report the REAL tokens received.
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
        uint256 m0 = _resolve(key.currency0, d.amount0());
        uint256 m1 = _resolve(key.currency1, d.amount1());
        return abi.encode(m0, m1);
    }

    function _resolve(Currency c, int128 amt) internal returns (uint256 magnitude) {
        if (amt < 0) {
            magnitude = uint256(uint128(-amt));
            poolManager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(poolManager), magnitude);
            poolManager.settle();
        } else if (amt > 0) {
            magnitude = uint256(uint128(amt));
            poolManager.take(c, address(this), magnitude);
        }
    }

    function _bal(Currency c) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this));
    }

    // ------------------------------------------------------------------ the allocator

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta d, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 g = gasleft();
        _allocate(d);
        lastAllocGas = g - gasleft();
        swapsSeen++;
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @dev The queue's aggregate entitlement is exactly the NEGATION of the swapper's delta:
    ///      whatever the swapper paid (fee included) is owed to the sole LP, and whatever the
    ///      swapper received came out of the sole LP's position. Nothing here is the hook's opinion
    ///      — the numbers come from PoolManager.
    function _allocate(BalanceDelta d) internal {
        int256 e0 = -int256(d.amount0());
        int256 e1 = -int256(d.amount1());
        if (e0 == 0 && e1 == 0) return;

        bool outIsOne = e1 < 0;
        uint256 amtOut = outIsOne ? uint256(-e1) : uint256(-e0);
        uint256 amtIn = outIsOne ? uint256(e0) : uint256(e1);

        uint256 touched;
        uint256 remaining = amtOut;
        uint256 assignedIn;

        if (mode == PRO_RATA) {
            uint256 total;
            for (uint256 i; i < q.length; i++) {
                total += outIsOne ? q[i].a1 : q[i].a0;
            }
            for (uint256 i; i < q.length; i++) {
                uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
                if (bal == 0) continue;
                bool last = i == q.length - 1;
                uint256 take_ = last ? remaining : FullMath.mulDiv(amtOut, bal, total);
                uint256 give = last ? amtIn - assignedIn : FullMath.mulDiv(amtIn, bal, total);
                remaining -= take_;
                assignedIn += give;
                _apply(i, outIsOne, take_, give);
                touched++;
            }
        } else {
            uint256 start = mode == OFF_BY_ONE ? 1 : 0;
            for (uint256 i = start; i < q.length && remaining > 0; i++) {
                uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
                if (bal == 0) continue;
                uint256 take_ = bal < remaining ? bal : remaining;
                remaining -= take_;
                uint256 give = (remaining == 0 && mode != FLOOR_ONLY)
                    ? amtIn - assignedIn // the LAST filled entry absorbs the rounding remainder
                    : FullMath.mulDiv(amtIn, take_, amtOut);
                assignedIn += give;
                _apply(i, outIsOne, take_, give);
                touched++;
            }
            if (remaining != 0) revert PFQueueUnderflow(remaining);
        }
        entriesTouched = touched;
    }

    function _apply(uint256 i, bool outIsOne, uint256 take_, uint256 give) internal {
        if (outIsOne) {
            q[i].a1 -= take_;
            q[i].a0 += give;
        } else {
            q[i].a0 -= take_;
            q[i].a1 += give;
        }
    }
}


// ============================================================================================
//  LAW-5 MUTANT — PLAN §E.5 option P2 ("account for it"). Byte-for-byte the allocator above,
//  except for the clearly-marked netting block. Purpose: prove the experiment below can detect
//  the ABSENCE of the hazard, not only its presence. If the shortfall does not collapse to the
//  benign v4 rounding residual under this mutant, the experiment is measuring something else.
// ============================================================================================
contract PFQueueHookNetted is BaseHook, IUnlockCallback {
    uint8 constant FRONT_FIRST = 0;
    uint8 constant PRO_RATA = 1; // mutation: v3/v4's actual behaviour
    uint8 constant OFF_BY_ONE = 2; // mutation: cursor starts at entry 1
    uint8 constant FLOOR_ONLY = 3; // mutation: no remainder assignment, every share floored

    uint8 public immutable mode;

    struct Entry {
        uint256 a0;
        uint256 a1;
    }

    Entry[] public q;

    PoolKey public key;
    int24 public tl;
    int24 public tu;
    uint128 public liq;

    uint256 public lastAllocGas;
    uint256 public entriesTouched;
    uint256 public swapsSeen;

    error PFQueueUnderflow(uint256 shortfall);

    // MUTANT STATE: last-seen protocolFeesAccrued, per currency.
    uint256 public pfSeen0;
    uint256 public pfSeen1;

    constructor(IPoolManager pm, uint8 mode_) BaseHook(pm) {
        mode = mode_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.afterSwap = true;
    }

    function len() external view returns (uint256) {
        return q.length;
    }

    function entry(uint256 i) external view returns (uint256, uint256) {
        return (q[i].a0, q[i].a1);
    }

    function totals() external view returns (uint256 t0, uint256 t1) {
        for (uint256 i; i < q.length; i++) {
            t0 += q[i].a0;
            t1 += q[i].a1;
        }
    }

    // ------------------------------------------------------------------ liquidity

    /// @dev Only the hook may be an LP. Every external add is refused, so the hook's ledger is the
    ///      pool's ledger.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        require(sender == address(this), "QUEUE: hook is sole LP");
        return BaseHook.beforeAddLiquidity.selector;
    }

    function seed(PoolKey calldata k, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256[] calldata bps)
        external
        returns (uint256 c0, uint256 c1)
    {
        key = k;
        tl = tickLower;
        tu = tickUpper;
        liq = liquidity;
        bytes memory r = poolManager.unlock(abi.encode(int256(uint256(liquidity))));
        (c0, c1) = abi.decode(r, (uint256, uint256));

        uint256 s0;
        uint256 s1;
        for (uint256 i; i < bps.length; i++) {
            uint256 a0 = i == bps.length - 1 ? c0 - s0 : FullMath.mulDiv(c0, bps[i], 10_000);
            uint256 a1 = i == bps.length - 1 ? c1 - s1 : FullMath.mulDiv(c1, bps[i], 10_000);
            s0 += a0;
            s1 += a1;
            q.push(Entry(a0, a1));
        }
    }

    /// @dev Full teardown: burn the position, collect fees, and report the REAL tokens received.
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
        uint256 m0 = _resolve(key.currency0, d.amount0());
        uint256 m1 = _resolve(key.currency1, d.amount1());
        return abi.encode(m0, m1);
    }

    function _resolve(Currency c, int128 amt) internal returns (uint256 magnitude) {
        if (amt < 0) {
            magnitude = uint256(uint128(-amt));
            poolManager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(poolManager), magnitude);
            poolManager.settle();
        } else if (amt > 0) {
            magnitude = uint256(uint128(amt));
            poolManager.take(c, address(this), magnitude);
        }
    }

    function _bal(Currency c) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this));
    }

    // ------------------------------------------------------------------ the allocator

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta d, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 g = gasleft();
        _allocate(d);
        lastAllocGas = g - gasleft();
        swapsSeen++;
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @dev The queue's aggregate entitlement is exactly the NEGATION of the swapper's delta:
    ///      whatever the swapper paid (fee included) is owed to the sole LP, and whatever the
    ///      swapper received came out of the sole LP's position. Nothing here is the hook's opinion
    ///      — the numbers come from PoolManager.
    function _allocate(BalanceDelta d) internal {
        int256 e0 = -int256(d.amount0());
        int256 e1 = -int256(d.amount1());
        if (e0 == 0 && e1 == 0) return;

        bool outIsOne = e1 < 0;
        uint256 amtOut = outIsOne ? uint256(-e1) : uint256(-e0);
        uint256 amtIn = outIsOne ? uint256(e0) : uint256(e1);

        // >>>>>>>>>>>>>>>>>>>>> THE ONLY BEHAVIOURAL CHANGE (PLAN §E.5 option P2) <<<<<<<<<<<<<<<<
        // Net the protocol fee the PoolManager actually skimmed on THIS swap out of `amtIn`.
        // PoolManager credits protocolFeesAccrued inside _swap(), BEFORE calling afterSwap
        // (PoolManager.sol:238 vs :221), so the delta is readable here and is wei-exact.
        {
            uint256 pfNow = outIsOne
                ? poolManager.protocolFeesAccrued(key.currency0)
                : poolManager.protocolFeesAccrued(key.currency1);
            uint256 seen = outIsOne ? pfSeen0 : pfSeen1;
            uint256 pfDelta = pfNow - seen;
            if (outIsOne) pfSeen0 = pfNow;
            else pfSeen1 = pfNow;
            amtIn -= pfDelta;
        }
        // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

        uint256 touched;
        uint256 remaining = amtOut;
        uint256 assignedIn;

        if (mode == PRO_RATA) {
            uint256 total;
            for (uint256 i; i < q.length; i++) {
                total += outIsOne ? q[i].a1 : q[i].a0;
            }
            for (uint256 i; i < q.length; i++) {
                uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
                if (bal == 0) continue;
                bool last = i == q.length - 1;
                uint256 take_ = last ? remaining : FullMath.mulDiv(amtOut, bal, total);
                uint256 give = last ? amtIn - assignedIn : FullMath.mulDiv(amtIn, bal, total);
                remaining -= take_;
                assignedIn += give;
                _apply(i, outIsOne, take_, give);
                touched++;
            }
        } else {
            uint256 start = mode == OFF_BY_ONE ? 1 : 0;
            for (uint256 i = start; i < q.length && remaining > 0; i++) {
                uint256 bal = outIsOne ? q[i].a1 : q[i].a0;
                if (bal == 0) continue;
                uint256 take_ = bal < remaining ? bal : remaining;
                remaining -= take_;
                uint256 give = (remaining == 0 && mode != FLOOR_ONLY)
                    ? amtIn - assignedIn // the LAST filled entry absorbs the rounding remainder
                    : FullMath.mulDiv(amtIn, take_, amtOut);
                assignedIn += give;
                _apply(i, outIsOne, take_, give);
                touched++;
            }
            if (remaining != 0) revert PFQueueUnderflow(remaining);
        }
        entriesTouched = touched;
    }

    function _apply(uint256 i, bool outIsOne, uint256 take_, uint256 give) internal {
        if (outIsOne) {
            q[i].a1 -= take_;
            q[i].a0 += give;
        } else {
            q[i].a0 -= take_;
            q[i].a1 += give;
        }
    }
}

// ============================================================================================
//              THE EXPERIMENT — PLAN §E.5: does a NONZERO PROTOCOL FEE break the ledger?
// ============================================================================================
//
// The allocator credits the queue with `amtIn` = the swapper's FULL fee-inclusive input, on the
// assumption that the sole LP is owed all of it. v4's protocol fee is skimmed off the input BEFORE
// the LP fee (ProtocolFeeLibrary.calculateSwapFee) and is parked in `protocolFeesAccrued`, which
// the LP position can never redeem. If the hazard is real, the queue's face value exceeds what the
// position can actually pay, by exactly the accrued protocol fee.
//
// MEASUREMENT DISCIPLINE (unchanged from the spike):
//   * every flow is read from POOLMANAGER'S OWN ERC20 BALANCES, never from the hook's bookkeeping;
//   * the price is 1:4, NEVER 1:1;
//   * the SAME four-swap scenario as the spike, on a VERBATIM copy of the allocator.
//
// NEW: we ALSO read `poolManager.protocolFeesAccrued(currency)`, because PoolManager's raw ERC20
// balance INCLUDES undistributed protocol fees. The queue-claimable balance is
//     (PoolManager ERC20 balance) - (protocolFeesAccrued).

contract ProtocolFeeHazardTest is BaseTest {
    uint24 constant LP_FEE = 3000;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint128 constant LIQ = 1_000e18;
    address constant PM_OWNER = address(0x4444); // Deployers.sol: V4PoolManagerDeployer.deploy(0x4444)

    Currency c0;
    Currency c1;
    PFQueueHook hook;
    PoolKey k;

    uint24 pfee; // packed protocol fee applied to the pool for this run (0 = control)

    // independently-maintained reference queue + independently-measured totals
    uint256[] r0;
    uint256[] r1;
    uint256 expT0; // GROSS: PoolManager's own ERC20 balance movements
    uint256 expT1;
    uint256 cumPf0; // cumulative protocolFeesAccrued(currency0)
    uint256 cumPf1;
    uint256 ledgerExp0; // what the hook's ledger SHOULD hold under the allocator being run
    uint256 ledgerExp1;
    bool netMode; // true => the hook nets the protocol fee out of amtIn (P2 mutant)
    string hookArtifact = "ProtocolFeeHazard.t.sol:PFQueueHook";

    struct SwapRec {
        bool zeroForOne;
        uint256 inAmt;
        uint256 outAmt;
        uint256 dpf0;
        uint256 dpf1;
    }

    SwapRec[] recs;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        vm.roll(100);
    }

    // ------------------------------------------------------------------ fixture

    function _deploy(uint160 nonce) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo(hookArtifact, abi.encode(poolManager, uint8(0)), a);
        hook = PFQueueHook(a);
        MockERC20(Currency.unwrap(c0)).mint(a, 100_000e18);
        MockERC20(Currency.unwrap(c1)).mint(a, 100_000e18);
    }

    /// @dev Owner -> controller -> setProtocolFee. Reverts loudly if any leg is refused; a silently
    ///      unset protocol fee would make the whole experiment prove nothing.
    function _applyProtocolFee(uint24 fee) internal {
        vm.prank(PM_OWNER);
        poolManager.setProtocolFeeController(address(this));
        require(poolManager.protocolFeeController() == address(this), "controller not set");
        poolManager.setProtocolFee(k, fee);
    }

    function _open(uint256[] memory bps) internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        // 1:4 — NEVER 1:1 (LAW 1).
        poolManager.initialize(k, Constants.SQRT_PRICE_1_4);
        if (pfee != 0) _applyProtocolFee(pfee);

        (uint256 s0, uint256 s1) =
            hook.seed(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), LIQ, bps);
        require(s0 != s1, "fixture is unit-priced");

        delete r0;
        delete r1;
        delete recs;
        cumPf0 = poolManager.protocolFeesAccrued(c0);
        cumPf1 = poolManager.protocolFeesAccrued(c1);
        require(cumPf0 == 0 && cumPf1 == 0, "protocol fee accrued before any swap");

        uint256 sum0;
        uint256 sum1;
        for (uint256 i; i < bps.length; i++) {
            (uint256 a0, uint256 a1) = hook.entry(i);
            r0.push(a0);
            r1.push(a1);
            sum0 += a0;
            sum1 += a1;
        }
        require(sum0 == s0 && sum1 == s1, "seed split lost a wei");
        expT0 = s0;
        expT1 = s1;
        ledgerExp0 = s0;
        ledgerExp1 = s1;
    }

    function _pmBal(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(poolManager));
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint256 inAmt, uint256 outAmt) {
        uint256 p0 = _pmBal(c0);
        uint256 p1 = _pmBal(c1);
        uint256 q0 = poolManager.protocolFeesAccrued(c0);
        uint256 q1 = poolManager.protocolFeesAccrued(c1);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 n0 = _pmBal(c0);
        uint256 n1 = _pmBal(c1);
        uint256 dpf0 = poolManager.protocolFeesAccrued(c0) - q0;
        uint256 dpf1 = poolManager.protocolFeesAccrued(c1) - q1;
        cumPf0 += dpf0;
        cumPf1 += dpf1;

        uint256 credited; // what the allocator under test is expected to credit
        if (zeroForOne) {
            (inAmt, outAmt) = (n0 - p0, p1 - n1);
            expT0 += inAmt;
            expT1 -= outAmt;
            credited = netMode ? inAmt - dpf0 : inAmt;
            ledgerExp0 += credited;
            ledgerExp1 -= outAmt;
        } else {
            (inAmt, outAmt) = (n1 - p1, p0 - n0);
            expT1 += inAmt;
            expT0 -= outAmt;
            credited = netMode ? inAmt - dpf1 : inAmt;
            ledgerExp1 += credited;
            ledgerExp0 -= outAmt;
        }
        recs.push(SwapRec(zeroForOne, inAmt, outAmt, dpf0, dpf1));
        _refAllocate(zeroForOne, credited, outAmt);
    }

    /// @dev VERBATIM from the spike: a second, independently-written front-first allocator.
    function _refAllocate(bool outIsOne, uint256 amtIn, uint256 amtOut) internal {
        uint256 left = amtOut;
        uint256 paid;
        for (uint256 i; i < r0.length; i++) {
            if (left == 0) break;
            uint256 have = outIsOne ? r1[i] : r0[i];
            if (have == 0) continue;
            uint256 t = have < left ? have : left;
            left -= t;
            uint256 g = left == 0 ? amtIn - paid : FullMath.mulDiv(amtIn, t, amtOut);
            paid += g;
            if (outIsOne) {
                r1[i] = have - t;
                r0[i] += g;
            } else {
                r0[i] = have - t;
                r1[i] += g;
            }
        }
        require(left == 0, "reference underflow");
    }

    /// @dev GROSS conservation: the spike's own check, against PoolManager's raw ERC20 balances.
    function _check(string memory tag) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        require(t0 == ledgerExp0, string.concat(tag, ": token0 GROSS conservation"));
        require(t1 == ledgerExp1, string.concat(tag, ": token1 GROSS conservation"));
        for (uint256 i; i < r0.length; i++) {
            (uint256 a0, uint256 a1) = hook.entry(i);
            require(a0 == r0[i], string.concat(tag, ": entry a0"));
            require(a1 == r1[i], string.concat(tag, ": entry a1"));
        }
    }

    // ------------------------------------------------------------------ the scenario (spike's)

    function harness(uint160 nonce) public {
        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        _deploy(nonce);
        _open(bps);

        (uint256 e0a0, uint256 e0a1) = hook.entry(0);
        (, uint256 e1a1) = hook.entry(1);

        _swap(true, 4e18);
        _check("swap1");
        {
            (uint256 a0, uint256 a1) = hook.entry(1);
            (uint256 b0, uint256 b1) = hook.entry(2);
            require(a0 == r0[1] && a1 == r1[1] && b0 == r0[2] && b1 == r1[2], "swap1: ref");
            require(a1 == e1a1, "swap1: entry a0");
            (uint256 h0, uint256 h1) = hook.entry(0);
            require(h1 < e0a1 && h0 > e0a0, "swap1: head did not fill");
            require(hook.entriesTouched() == 1, "swap1: touched != 1");
        }

        _swap(true, 300e18);
        _check("swap2");
        {
            (, uint256 a1) = hook.entry(0);
            (, uint256 b1) = hook.entry(1);
            (, uint256 cc1) = hook.entry(2);
            require(a1 == 0, "swap2: entry0 not exhausted");
            require(b1 == 0, "swap2: entry1 not exhausted");
            require(cc1 > 0, "swap2: entry2 should be partial, not exhausted");
            require(hook.entriesTouched() >= 2, "swap2: cursor never advanced");
        }

        {
            (, uint256 before2) = hook.entry(2);
            _swap(true, 50e18);
            _check("swap3");
            (, uint256 after2) = hook.entry(2);
            require(after2 > 0 && after2 < before2, "swap3: not a partial fill");
            require(hook.entriesTouched() == 1, "swap3: touched != 1");
        }

        {
            (uint256 h0before,) = hook.entry(0);
            _swap(false, 20e18);
            _check("swap4");
            (uint256 h0after, uint256 h1after) = hook.entry(0);
            require(h0after < h0before, "swap4: head did not fill on the reverse leg");
            require(h1after > 0, "swap4: head received no token1");
        }
    }

    // ------------------------------------------------------------------ reporting

    function _report(string memory tag) internal returns (int256 d0, int256 d1) {
        (uint256 t0, uint256 t1) = hook.totals();
        emit log_string(string.concat("=============== ", tag));
        emit log_named_uint("protocol fee packed (uint24)", pfee);
        emit log_named_uint("queue ledger total token0", t0);
        emit log_named_uint("queue ledger total token1", t1);
        emit log_named_uint("PoolManager-measured GROSS token0", expT0);
        emit log_named_uint("PoolManager-measured GROSS token1", expT1);
        emit log_named_uint("protocolFeesAccrued(c0)", cumPf0);
        emit log_named_uint("protocolFeesAccrued(c1)", cumPf1);
        emit log_named_uint("expected ledger token0 (allocator under test)", ledgerExp0);
        emit log_named_uint("expected ledger token1 (allocator under test)", ledgerExp1);
        emit log_named_int("GROSS conservation gap token0 (ledger - PM)", int256(t0) - int256(expT0));
        emit log_named_int("GROSS conservation gap token1 (ledger - PM)", int256(t1) - int256(expT1));
        emit log_named_int("NET  conservation gap token0 (ledger - (PM - pfAccrued))", int256(t0) - int256(expT0 - cumPf0));
        emit log_named_int("NET  conservation gap token1 (ledger - (PM - pfAccrued))", int256(t1) - int256(expT1 - cumPf1));

        for (uint256 i; i < recs.length; i++) {
            SwapRec memory rr = recs[i];
            emit log_named_uint("--- swap #", i + 1);
            emit log_named_string("    direction", rr.zeroForOne ? "0 -> 1" : "1 -> 0");
            emit log_named_uint("    input (PM balance delta, wei)", rr.inAmt);
            emit log_named_uint("    output (PM balance delta, wei)", rr.outAmt);
            uint256 pf = rr.zeroForOne ? rr.dpf0 : rr.dpf1;
            emit log_named_uint("    protocol fee skimmed this swap (wei)", pf);
            if (rr.inAmt > 0) {
                emit log_named_uint("    protocol fee as ppm of input", FullMath.mulDiv(pf, 1_000_000, rr.inAmt));
                uint256 lpFeeAmt = FullMath.mulDiv(rr.inAmt - pf, LP_FEE, 1_000_000);
                emit log_named_uint("    LP fee this swap (wei, derived)", lpFeeAmt);
                if (lpFeeAmt > 0) {
                    emit log_named_uint("    protocol fee as ppm of LP fee", FullMath.mulDiv(pf, 1_000_000, lpFeeAmt));
                }
            }
        }

        (uint256 g0, uint256 g1) = hook.redeemAll();
        emit log_named_uint("redeemed token0 (real ERC20)", g0);
        emit log_named_uint("redeemed token1 (real ERC20)", g1);
        d0 = int256(g0) - int256(t0);
        d1 = int256(g1) - int256(t1);
        emit log_named_int("REDEMPTION residual token0 (redeemed - ledger)", d0);
        emit log_named_int("REDEMPTION residual token1 (redeemed - ledger)", d1);
        emit log_named_uint("protocolFeesAccrued(c0) at end", poolManager.protocolFeesAccrued(c0));
        emit log_named_uint("protocolFeesAccrued(c1) at end", poolManager.protocolFeesAccrued(c1));
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }

    // ==========================================================================================
    // C1 — NEGATIVE CONTROL: protocolFee = 0. Must reproduce the archived spike EXACTLY.
    // ==========================================================================================
    function test_C1_control_zeroProtocolFee_reproducesTheSpike() public {
        pfee = 0;
        harness(0xC001);
        (int256 d0, int256 d1) = _report("C1: protocolFee = 0 (control)");
        assertEq(cumPf0, 0, "control leaked a protocol fee in token0");
        assertEq(cumPf1, 0, "control leaked a protocol fee in token1");
        (uint256 t0, uint256 t1) = hook.totals();
        assertEq(t0, expT0, "C1 token0 conservation");
        assertEq(t1, expT1, "C1 token1 conservation");
        // Same bound the archived spike asserts.
        assertLe(_abs(d0), 8, "C1 token0 residual larger than v4 rounding explains");
        assertLe(_abs(d1), 8, "C1 token1 residual larger than v4 rounding explains");
    }

    // ==========================================================================================
    // C2 — CONTROL ON THE INSTRUMENT: MAX_PROTOCOL_FEE read FROM SOURCE, and the boundary is real.
    // ==========================================================================================
    function test_C2_control_maxProtocolFeeBoundaryIsReal() public {
        assertEq(uint256(ProtocolFeeLibrary.MAX_PROTOCOL_FEE), 1000, "MAX_PROTOCOL_FEE moved; re-read the source");

        uint256[] memory bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
        pfee = 0;
        _deploy(0xC002);
        _open(bps);

        vm.prank(PM_OWNER);
        poolManager.setProtocolFeeController(address(this));

        uint24 tooBig0 = uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) + 1; // zeroForOne leg over max
        vm.expectRevert(abi.encodeWithSelector(IProtocolFees.ProtocolFeeTooLarge.selector, tooBig0));
        poolManager.setProtocolFee(k, tooBig0);

        uint24 tooBig1 = uint24(uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) + 1) << 12; // oneForZero leg
        vm.expectRevert(abi.encodeWithSelector(IProtocolFees.ProtocolFeeTooLarge.selector, tooBig1));
        poolManager.setProtocolFee(k, tooBig1);

        // The maximum legal packed value IS accepted.
        uint24 maxPacked = _maxPacked();
        poolManager.setProtocolFee(k, maxPacked);
        emit log_named_uint("max legal packed protocol fee accepted", maxPacked);
    }

    function _maxPacked() internal pure returns (uint24) {
        uint24 m = uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE);
        return m | (m << 12);
    }

    // ==========================================================================================
    // E1 — THE EXPERIMENT: maximum legal protocol fee, same scenario, same price.
    // ==========================================================================================
    function test_E1_maxProtocolFee_breaksTheLedger() public {
        pfee = _maxPacked();
        harness(0xE001);
        (int256 d0, int256 d1) = _report("E1: protocolFee = MAX (1000|1000<<12)");

        // (0) The experiment must have actually done something. If this fails, nothing below means
        //     anything — setProtocolFee was silently ignored.
        assertGt(cumPf0, 0, "protocolFeesAccrued(c0) == 0: the protocol fee was NEVER APPLIED, experiment void");
        assertGt(cumPf1, 0, "protocolFeesAccrued(c1) == 0: the reverse leg took no protocol fee, experiment void");

        // (1) THE SPIKE'S OWN CONSERVATION CHECK IS BLIND. PoolManager's raw ERC20 balance still
        //     holds the protocol fee, so gross conservation passes while the position is insolvent.
        (uint256 t0, uint256 t1) = hook.totals();
        assertEq(t0, expT0, "E1 GROSS token0 conservation unexpectedly broke");
        assertEq(t1, expT1, "E1 GROSS token1 conservation unexpectedly broke");

        // (2) The REAL number: redemption. The queue's face value exceeds what the position pays.
        assertLt(d0, 0, "expected a token0 shortfall");
        assertLt(d1, 0, "expected a token1 shortfall");
        assertGt(_abs(d0), 8, "shortfall within v4 rounding: the fee changed nothing (control C1 bound)");

        // (3) Is the shortfall EXACTLY the protocol fee? Assert it up to the benign rounding residual.
        emit log_named_int("shortfall0 - protocolFeesAccrued(c0)", -d0 - int256(cumPf0));
        emit log_named_int("shortfall1 - protocolFeesAccrued(c1)", -d1 - int256(cumPf1));
        assertLe(_abs(-d0 - int256(cumPf0)), 8, "token0 shortfall is NOT the protocol fee (+/- rounding)");
        assertLe(_abs(-d1 - int256(cumPf1)), 8, "token1 shortfall is NOT the protocol fee (+/- rounding)");

        // (4) Order of magnitude vs the benign ~0.26 wei/swap residual (PLAN §E.4).
        emit log_named_uint("shortfall token0 per swap (wei)", uint256(_abs(d0)) / 4);
        emit log_named_uint("x larger than the 0.26 wei/swap benign residual (token0)", uint256(_abs(d0)) * 100 / 4 / 26);
    }

    // ==========================================================================================
    // E2 — the same, at the minimum NONZERO protocol fee, to show it is not a max-fee artefact.
    // ==========================================================================================
    function test_E2_oneWeiPipProtocolFee_alsoLeaks() public {
        pfee = uint24(1) | (uint24(1) << 12); // 1 pip = 0.0001%
        harness(0xE002);
        (int256 d0, int256 d1) = _report("E2: protocolFee = 1 pip each direction");
        assertGt(cumPf0, 0, "1-pip protocol fee never accrued; experiment void");
        assertGt(_abs(d0), 8, "1-pip fee produced no measurable shortfall");
        assertLe(_abs(-d0 - int256(cumPf0)), 8, "token0 shortfall is NOT the protocol fee (+/- rounding)");
    }

    // ==========================================================================================
    // M1 — LAW 5 MUTATION: run the E1 assertions with the fee turned OFF. MUST go red, on the
    //      "experiment void" assertion, proving E1 is not green-by-construction.
    // ==========================================================================================
    function test_M1_mutation_E1AssertionsFailWithoutTheFee() public {
        pfee = 0;
        harness(0x1111);
        (uint256 t0,) = hook.totals();
        (uint256 g0,) = hook.redeemAll();
        int256 d0 = int256(g0) - int256(t0);
        emit log_named_uint("cumPf0 with fee OFF", cumPf0);
        emit log_named_int("shortfall token0 with fee OFF", d0);
        assertEq(cumPf0, 0, "fee leaked into the mutation run");
        assertLe(_abs(d0), 8, "shortfall without a fee is NOT within v4 rounding");
        // The two E1 claims are FALSE here — that is the point.
        assertFalse(cumPf0 > 0, "M1: E1's 'fee was applied' assertion would have passed with no fee");
        assertFalse(_abs(d0) > 8, "M1: E1's 'shortfall exceeds rounding' assertion would have passed with no fee");
    }

    // ==========================================================================================
    // M2 — LAW 5 MUTATION: run the C1 control's bound WITH the max fee on. MUST be violated.
    // ==========================================================================================
    function test_M2_mutation_C1BoundIsViolatedWithTheFee() public {
        pfee = _maxPacked();
        harness(0x2222);
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 g0, uint256 g1) = hook.redeemAll();
        int256 d0 = int256(g0) - int256(t0);
        int256 d1 = int256(g1) - int256(t1);
        emit log_named_int("shortfall token0 vs C1 bound of 8 wei", d0);
        emit log_named_int("shortfall token1 vs C1 bound of 8 wei", d1);
        assertGt(_abs(d0), 8, "M2: C1 8-wei bound survived a max protocol fee - C1 is not a control");
        assertGt(_abs(d1), 8, "M2: C1 8-wei bound survived a max protocol fee - C1 is not a control");
    }

    // ==========================================================================================
    // M3 — LAW 5 MUTATION on the ALLOCATOR ITSELF: PLAN §E.5 option P2. Max protocol fee, same
    //      scenario, but the allocator nets the skimmed fee out of amtIn. The shortfall MUST
    //      collapse to the benign v4 rounding residual. If it does not, E1 measured the wrong thing.
    // ==========================================================================================
    function test_M3_mutation_P2NettedAllocatorClosesTheGap() public {
        hookArtifact = "ProtocolFeeHazard.t.sol:PFQueueHookNetted";
        netMode = true;
        pfee = _maxPacked();
        harness(0x3333);
        (int256 d0, int256 d1) = _report("M3: P2-netted allocator, protocolFee = MAX");
        assertGt(cumPf0, 0, "M3: fee never applied, mutation void");
        assertGt(cumPf1, 0, "M3: reverse-leg fee never applied, mutation void");
        // The ledger now equals PoolManager's balance MINUS the accrued protocol fee.
        (uint256 t0, uint256 t1) = hook.totals();
        assertEq(t0, expT0 - cumPf0, "M3 token0 NET conservation");
        assertEq(t1, expT1 - cumPf1, "M3 token1 NET conservation");
        // And redemption is solvent again, to within v4 rounding.
        assertLe(_abs(d0), 8, "M3: P2 netting did NOT close the token0 gap");
        assertLe(_abs(d1), 8, "M3: P2 netting did NOT close the token1 gap");
    }
}
