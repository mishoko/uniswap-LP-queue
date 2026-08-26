// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HardcapMath} from "./libraries/HardcapMath.sol";

/// @title HardcapHook
/// @notice Single-pool Uniswap v4 hook: immutable hook-take cap, LP-only vault, fail-closed callbacks, JIT exit lock.
///
/// Spike (v4-core + OZ hooks in this repo — do not rediscover):
/// 1. Callback `sender` is PoolManager's unlock caller (the position owner). Solidity `msg.sender` is PoolManager.
///    Key lastAdd/shares/claim by Position.calculatePositionKey(sender, ticks, salt).
/// 2. afterSwap's int128 is unspecified-only (Hooks.afterSwap). FeeTakingHook / BaseHookFee take that currency.
///    Notional = abs(unspecified BalanceDelta). Same-currency as the take. amountSpecified is the request, not the fill.
/// 3. take() during afterSwap then return +feeAmount. Signs copied from FeeTakingHook, not invented.
/// 4. Never poolManager.donate(). Never honor hookData. Never beforeSwapReturnDelta.
///
/// ToB-spot (SwapMath.computeSwapStep — v4-core SwapMath.t.sol + Pool.swap):
/// 5. feePips = PoolKey.fee (3000 = 0.30% = 3000/1e6). Include LP fee or the quote is not comparable.
///    Direction is inferred: target < current ⇒ zeroForOne. amountRemaining < 0 ⇒ exact-in.
///    Target = getSqrtPriceAtTick(openTick ± tickSpacing). wouldCross iff sqrtNext == target.
///    Exact-in unspecified target = amountOut. Exact-out unspecified target = amountIn + feeAmount.
///    Same-dir after a same-dir fill cannot beat open. The claw is the opposite-dir backrun.
///    Any zeroForOne from an exact tick bound decrements slot0.tick — that swap is a tick-cross skip.
///
/// extraFeeBps > 0 keeps the v1 tax path (envelope tests). Production extraFeeBps = 0 is ToB-spot.
/// Native 0.30% still goes to whoever is in range. Tick-crossing sandwiches are not clawed.
contract HardcapHook is BaseHook, ReentrancyGuard {
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint16 public constant DEFAULT_EXTRA_FEE_BPS = HardcapMath.DEFAULT_EXTRA_FEE_BPS;
    uint16 public constant DEFAULT_MAX_TAKE_BPS = HardcapMath.DEFAULT_MAX_TAKE_BPS;
    uint48 public constant DEFAULT_OFFSET = HardcapMath.DEFAULT_OFFSET;
    uint48 public constant MIN_OFFSET = HardcapMath.MIN_OFFSET;

    /// @dev Bound pool. One hook deployment ⇔ one PoolKey. hooks is always address(this).
    Currency public immutable currency0;
    Currency public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint16 public immutable extraFeeBps;
    uint16 public immutable maxTakeBps;
    uint48 public immutable offset;

    mapping(bytes32 positionKey => uint48 blockNumber) public lastAddBlock;
    /// @dev Claimable (aged) shares. Unaged liquidity sits in `pendingShares` until OFFSET elapses.
    mapping(bytes32 positionKey => uint256 shareAmount) public shares;
    mapping(bytes32 positionKey => uint256 shareAmount) public pendingShares;
    mapping(Currency currency => uint256 amount) public vaultAccrued;
    uint256 public totalShares;
    uint256 public pendingTotal;

    /// @dev Block-open snapshot. Written on the first `_beforeSwap` of `block.number`.
    uint48 public openBlock;
    uint160 public openSqrtPriceX96;
    uint128 public openLiquidity;
    int24 public openTick;
    int24 transient swapStartTick;
    bool transient firstSwapOfBlock;

    error NativeCurrencyNotSupported();
    error InvalidCurrencyOrder();
    error ExtraFeeExceedsCap();
    error InvalidMaxTakeBps();
    error InvalidFee();
    error InvalidTickSpacing();
    error OffsetTooLow();
    error HookDataNotAllowed();
    error InvalidPoolKey();
    error RemoveTooSoon();
    error PositionNotAged();
    error NoShares();

    event HookTake(bytes32 indexed poolId, Currency currency, uint256 notional, uint256 surplus, uint256 take);
    event LiquidityStamped(bytes32 indexed positionKey, address indexed owner, uint48 blockNumber, uint256 sharesAdded);
    event Claimed(bytes32 indexed positionKey, address indexed owner, uint256 amount0, uint256 amount1);

    constructor(
        IPoolManager _poolManager,
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        uint16 _extraFeeBps,
        uint16 _maxTakeBps,
        uint48 _offset
    ) BaseHook(_poolManager) {
        if (_currency0.isAddressZero() || _currency1.isAddressZero()) {
            revert NativeCurrencyNotSupported();
        }
        if (!(_currency0 < _currency1)) revert InvalidCurrencyOrder();
        // `fee` is fed straight to SwapMath.computeSwapStep as feePips by the ToB quote, so an
        // out-of-range value is unvalidated input reaching math. A dynamic-fee pool (0x800000) is
        // also rejected here: its key.fee is a flag, not a rate, and the quote would be garbage.
        if (_fee > LPFeeLibrary.MAX_LP_FEE) revert InvalidFee();
        if (_tickSpacing < TickMath.MIN_TICK_SPACING || _tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing();
        }
        if (_maxTakeBps > HardcapMath.BPS_DENOMINATOR) revert InvalidMaxTakeBps();
        if (_extraFeeBps > _maxTakeBps) revert ExtraFeeExceedsCap();
        if (_offset < MIN_OFFSET) revert OffsetTooLow();

        currency0 = _currency0;
        currency1 = _currency1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        extraFeeBps = _extraFeeBps;
        maxTakeBps = _maxTakeBps;
        offset = _offset;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
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

    /// @notice Liability this hook declares it owes to others in `token`, for Assay's
    /// SolvencyPredicate. Reporting the accounting counter (not `balanceOf`) is the point: the hook
    /// publishes a liability, the chain publishes the asset, and anyone can compare them.
    function assayAccrued(address token) external view returns (uint256) {
        return vaultAccrued[Currency.wrap(token)];
    }

    function boundPoolKey() public view returns (PoolKey memory) {
        return PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: this});
    }

    function positionKeyOf(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
    }

    /// @notice Single-shot claim of vault surplus for an aged position owned by `msg.sender`.
    /// @dev `msg.sender` must be the PoolManager position owner (unlock caller), not the EOA behind a router.
    function claim(int24 tickLower, int24 tickUpper, bytes32 salt) external nonReentrant {
        bytes32 key = Position.calculatePositionKey(msg.sender, tickLower, tickUpper, salt);
        if (block.number < uint256(lastAddBlock[key]) + uint256(offset)) revert PositionNotAged();
        _sync(key);

        uint256 recorded = shares[key];
        if (recorded == 0) revert NoShares();

        // Ghost-share rail: if remove accounting ever drifts, do not pay more than live L.
        (uint128 liveL,,) = poolManager.getPositionInfo(boundPoolKey().toId(), msg.sender, tickLower, tickUpper, salt);
        uint256 owned = recorded < uint256(liveL) ? recorded : uint256(liveL);
        if (owned == 0) revert NoShares();

        // Weight is recorded rights + still-pending. Age gates *receipt*. Lazy per-key
        // `_sync` cannot see other keys; matured-only denom lets the first claimer take 100%.
        uint256 weight = totalShares + pendingTotal;
        shares[key] = 0;
        totalShares -= recorded;

        uint256 payout0 = _proRata(vaultAccrued[currency0], owned, weight);
        uint256 payout1 = _proRata(vaultAccrued[currency1], owned, weight);
        vaultAccrued[currency0] -= payout0;
        vaultAccrued[currency1] -= payout1;

        if (payout0 > 0) currency0.transfer(msg.sender, payout0);
        if (payout1 > 0) currency1.transfer(msg.sender, payout1);

        emit Claimed(key, msg.sender, payout0, payout1);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateCallback(key, hookData);
        _snapshotOpen(key);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        _validateCallback(key, hookData);

        (Currency unspecified, uint256 notional) = _unspecifiedNotional(key, params, delta);
        if (notional == 0) return (this.afterSwap.selector, 0);

        // extraFeeBps > 0: envelope tax / test overrides. extraFeeBps == 0: ToB-spot.
        uint256 surplus = extraFeeBps > 0 ? _computeSurplus(notional) : _computeToBSurplus(key, params, delta, notional);
        uint256 cap = HardcapMath.capOf(notional, maxTakeBps);
        uint256 take = _boundTake(notional, surplus);

        if (take > 0) {
            _creditVault(unspecified, take, cap);
            // Debt now, credit via returned delta. Same pattern as v4-core FeeTakingHook.
            unspecified.take(poolManager, address(this), take, false);
            emit HookTake(PoolId.unwrap(key.toId()), unspecified, notional, surplus, take);
        }

        return (this.afterSwap.selector, take.toInt128());
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        _validateCallback(key, hookData);

        if (params.liquidityDelta > 0) {
            bytes32 key_ = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
            _sync(key_);
            uint256 added = uint256(params.liquidityDelta);
            lastAddBlock[key_] = uint48(block.number);
            pendingShares[key_] += added;
            pendingTotal += added;
            emit LiquidityStamped(key_, sender, uint48(block.number), added);
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _validateCallback(key, hookData);

        bytes32 key_ = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        if (block.number < uint256(lastAddBlock[key_]) + uint256(offset)) revert RemoveTooSoon();

        _sync(key_);
        if (params.liquidityDelta < 0) {
            _burnRights(key_, uint256(-params.liquidityDelta));
        }

        return this.beforeRemoveLiquidity.selector;
    }

    /// @dev Move pending shares that have cleared OFFSET into the claimable bucket.
    /// Per-key lazy mature: no global LP census, no donate.
    function _sync(bytes32 key) internal {
        uint256 pending = pendingShares[key];
        if (pending == 0) return;
        if (block.number < uint256(lastAddBlock[key]) + uint256(offset)) return;

        pendingShares[key] = 0;
        pendingTotal -= pending;
        shares[key] += pending;
        totalShares += pending;
    }

    /// @dev Burn matured first, then pending. Full exit must clear both buckets even if
    /// JIT and `_sync` later use different age predicates.
    function _burnRights(bytes32 key, uint256 removed) internal {
        uint256 matured = shares[key];
        uint256 fromMatured = removed < matured ? removed : matured;
        if (fromMatured > 0) {
            shares[key] = matured - fromMatured;
            totalShares -= fromMatured;
            removed -= fromMatured;
        }
        if (removed == 0) return;

        uint256 pending = pendingShares[key];
        uint256 fromPending = removed < pending ? removed : pending;
        if (fromPending == 0) return;
        pendingShares[key] = pending - fromPending;
        pendingTotal -= fromPending;
    }

    function _validateCallback(PoolKey calldata key, bytes calldata hookData) internal view {
        if (hookData.length != 0) revert HookDataNotAllowed();
        if (!_isBoundPool(key)) revert InvalidPoolKey();
    }

    function _isBoundPool(PoolKey calldata key) internal view returns (bool) {
        return key.currency0 == currency0 && key.currency1 == currency1 && key.fee == fee
            && key.tickSpacing == tickSpacing && address(key.hooks) == address(this);
    }

    /// @dev Unspecified currency and its executed amount. Copied from OZ BaseHookFee / v4-core FeeTakingHook.
    function _unspecifiedNotional(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (Currency unspecified, uint256 notional)
    {
        int128 unspecifiedAmount;
        (unspecified, unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        notional = _abs(unspecifiedAmount);
    }

    function _abs(int128 x) private pure returns (uint256) {
        if (x >= 0) return uint256(uint128(x));
        if (x == type(int128).min) return uint256(1) << 127;
        return uint256(uint128(-x));
    }

    function _snapshotOpen(PoolKey calldata key) private {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        swapStartTick = tick;
        if (openBlock == uint48(block.number)) {
            firstSwapOfBlock = false;
            return;
        }
        openBlock = uint48(block.number);
        openSqrtPriceX96 = sqrtPriceX96;
        openLiquidity = poolManager.getLiquidity(key.toId());
        openTick = tick;
        firstSwapOfBlock = true;
    }

    /// @dev ToB-spot: later in-range fill beating the block-open one-step quote.
    /// First swap, this-swap tick change, L change since open, or would-cross-at-open → 0.
    function _computeToBSurplus(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, uint256 notional)
        internal
        view
        returns (uint256)
    {
        if (firstSwapOfBlock) return 0;

        (, int24 tickAfter,,) = poolManager.getSlot0(key.toId());
        if (tickAfter != swapStartTick) return 0;
        if (poolManager.getLiquidity(key.toId()) != openLiquidity) return 0;
        if (openLiquidity == 0) return 0;

        int256 remaining = _executedSpecified(params, delta);
        (, uint256 amountIn, uint256 amountOut, uint256 feeAmount, bool wouldCross) = HardcapMath.quoteOpenStep(
            openSqrtPriceX96, openLiquidity, openTick, tickSpacing, params.zeroForOne, remaining, fee
        );
        if (wouldCross) return 0;

        bool exactIn = params.amountSpecified < 0;
        uint256 target = exactIn ? amountOut : amountIn + feeAmount;
        return HardcapMath.tobSurplus(exactIn, notional, target);
    }

    /// @dev Specified-currency executed amount, signed like SwapParams.amountSpecified.
    function _executedSpecified(SwapParams calldata params, BalanceDelta delta) private pure returns (int256) {
        int128 specifiedAmount = (params.amountSpecified < 0 == params.zeroForOne) ? delta.amount0() : delta.amount1();
        return int256(specifiedAmount);
    }

    /// @dev v1 surplus = extraFeeBps of notional. Virtual so a test hook can feed a huge leftover (clamp path)
    /// and so a later start-of-block surplus definition can replace this without touching settlement.
    function _computeSurplus(uint256 notional) internal view virtual returns (uint256) {
        return HardcapMath.surplusOf(notional, extraFeeBps);
    }

    /// @dev Clamp to the cap. Virtual so a test hook can skip the min and hit the bug-path revert in `_creditVault`.
    function _boundTake(uint256 notional, uint256 surplus) internal view virtual returns (uint256) {
        return HardcapMath.boundTake(notional, surplus, maxTakeBps);
    }

    /// @dev Last rail: no vault write above cap. Not virtual — inheritors cannot delete this check.
    function _creditVault(Currency currency, uint256 take, uint256 cap) internal {
        if (take > cap) revert HardcapMath.TakeExceedsCap(take, cap);
        vaultAccrued[currency] += take;
    }

    function _proRata(uint256 vault, uint256 owned, uint256 total) private pure returns (uint256) {
        if (vault == 0 || owned == 0 || total == 0) return 0;
        return FullMath.mulDiv(vault, owned, total);
    }
}
