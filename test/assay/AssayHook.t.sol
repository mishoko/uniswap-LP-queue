// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {HardcapLP} from "../utils/HardcapLP.sol";
import {AssayHook} from "../../src/assay/AssayHook.sol";
import {Verdict} from "../../src/assay/IHookPredicate.sol";
import {BalanceFloorPredicate} from "../../src/assay/predicates/BalanceFloorPredicate.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @dev A hook with a drain bug: it leaks tokens on every swap. Exactly the class of bug that
/// post-hoc bonding cannot help with — by the time a challenger can prove insolvency, the tokens
/// are already gone.
contract LeakyHook is BaseHook {
    address public immutable token;
    address public immutable thief;
    uint256 public constant LEAK = 1e18;

    constructor(IPoolManager pm, address token_, address thief_) BaseHook(pm) {
        token = token_;
        thief = thief_;
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        IERC20(token).transfer(thief, LEAK);
        return (this.afterSwap.selector, 0);
    }
}

/// @dev The SAME bug, in a hook that carries a runtime spec. The transfer still executes; the
/// transaction does not survive it.
contract AssayedLeakyHook is LeakyHook, AssayHook {
    constructor(IPoolManager pm, address token_, address thief_, address[] memory invs)
        LeakyHook(pm, token_, thief_)
        AssayHook(invs)
    {}

    function _afterSwap(address s, PoolKey calldata k, SwapParams calldata p, BalanceDelta d, bytes calldata h)
        internal
        override
        returns (bytes4, int128)
    {
        (bytes4 sel, int128 delta) = super._afterSwap(s, k, p, d, h);
        _assertInvariants();
        return (sel, delta);
    }
}

contract AssayHookTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);
    uint256 constant FUNDED = 100e18;

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    address thief = address(0x7417F);
    address token;
    BalanceFloorPredicate floorInv;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        token = Currency.unwrap(currency1);
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        floorInv = new BalanceFloorPredicate(token, FUNDED);
    }

    function _hookAddr(uint160 nonce) internal pure returns (address) {
        return address(FLAGS ^ (nonce << 144));
    }

    function _openPool(address hookAddr) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: LeakyHook(hookAddr)
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1_000e18,
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);
    }

    function _swap(PoolKey memory key) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _deployLeaky(uint160 nonce) internal returns (address a) {
        a = _hookAddr(nonce);
        deal(token, a, FUNDED);
        deployCodeTo("AssayHook.t.sol:LeakyHook", abi.encode(poolManager, token, thief), a);
    }

    function _deployAssayed(uint160 nonce, address[] memory invs) internal returns (address a) {
        a = _hookAddr(nonce);
        deal(token, a, FUNDED);
        deployCodeTo("AssayHook.t.sol:AssayedLeakyHook", abi.encode(poolManager, token, thief, invs), a);
    }

    function _oneInvariant() internal view returns (address[] memory invs) {
        invs = new address[](1);
        invs[0] = address(floorInv);
    }

    // ------------------------------------------------------------ the demo

    /// @dev Baseline: the bug works. A swap drains the hook and nothing stops it.
    function test_unprotectedHook_isDrainedBySwapping() public {
        address h = _deployLeaky(0x1111);
        PoolKey memory key = _openPool(h);

        _swap(key);
        assertEq(IERC20(token).balanceOf(h), FUNDED - 1e18, "drained");
        assertEq(IERC20(token).balanceOf(thief), 1e18, "thief paid");

        for (uint256 i = 0; i < 5; ++i) {
            _swap(key);
        }
        assertEq(IERC20(token).balanceOf(thief), 6e18, "and it keeps draining");
    }

    /// @dev THE point of the project. Identical bug, identical transfer, but the hook carries a
    /// runtime invariant, so the transaction cannot survive the violation. Not compensated — not
    /// executable.
    function test_assayedHook_cannotCompleteASwapThatBreaksItsSpec() public {
        address h = _deployAssayed(0x2222, _oneInvariant());
        PoolKey memory key = _openPool(h);

        vm.expectRevert();
        _swap(key);

        assertEq(IERC20(token).balanceOf(h), FUNDED, "not one wei left the hook");
        assertEq(IERC20(token).balanceOf(thief), 0, "thief got nothing");
    }

    function test_assayedHook_publishesItsSpec() public {
        address h = _deployAssayed(0x3333, _oneInvariant());
        address[] memory invs = AssayHook(h).runtimeInvariants();
        assertEq(invs.length, 1);
        assertEq(invs[0], address(floorInv));
        string[] memory spec = AssayHook(h).describeSpec();
        assertEq(spec[0], "hook token balance never falls below its declared floor");
    }

    /// @dev A hook whose spec does not hold is bricked on arrival: it deploys, but it cannot serve
    /// a single callback. Stronger than a constructor gate, and unlike a constructor gate it works
    /// for predicates that inspect the hook — during construction the hook has no code, so those
    /// are un-evaluable by definition.
    function test_hookWithBrokenSpecCannotServeASwap() public {
        address a = _hookAddr(0x4444);
        deal(token, a, FUNDED - 1); // already below the declared floor
        deployCodeTo("AssayHook.t.sol:AssayedLeakyHook", abi.encode(poolManager, token, thief, _oneInvariant()), a);
        PoolKey memory key = _openPool(a);

        Verdict[] memory verdicts = AssayHook(a).verifySpec();
        assertEq(uint256(verdicts[0]), uint256(Verdict.VIOLATED), "the spec is publicly broken");

        vm.expectRevert();
        _swap(key);
        assertEq(IERC20(token).balanceOf(thief), 0, "and the hook is inert, not merely reported");
    }

    /// @dev What runtime enforcement actually costs. The comparison must be like-for-like: both
    /// hooks perform the SAME token transfer, and both are measured on a WARM second swap. A first
    /// measurement here read 23.5k, which was almost entirely a cold zero-to-nonzero SSTORE on the
    /// recipient's balance slot that only the guarded hook paid — an artefact, not a cost.
    function test_gasCostOfRuntimeEnforcement() public {
        address bare = _hookAddr(0x5555);
        deal(token, bare, FUNDED * 100);
        deployCodeTo("AssayHook.t.sol:LeakyHook", abi.encode(poolManager, token, thief), bare);
        PoolKey memory bareKey = _openPool(bare);

        address[] memory none = new address[](0);
        address assayed0 = _hookAddr(0x6666);
        deal(token, assayed0, FUNDED * 100);
        deployCodeTo("AssayHook.t.sol:AssayedLeakyHook", abi.encode(poolManager, token, thief, none), assayed0);
        PoolKey memory key0 = _openPool(assayed0);

        address assayed1 = _hookAddr(0x7777);
        deal(token, assayed1, FUNDED * 100);
        deployCodeTo(
            "AssayHook.t.sol:AssayedLeakyHook", abi.encode(poolManager, token, thief, _oneInvariant()), assayed1
        );
        PoolKey memory key1 = _openPool(assayed1);

        // warm every storage slot the measured swaps will touch
        _swap(bareKey);
        _swap(key0);
        _swap(key1);

        uint256 g0 = gasleft();
        _swap(bareKey);
        uint256 bareGas = g0 - gasleft();

        g0 = gasleft();
        _swap(key0);
        uint256 zeroInv = g0 - gasleft();

        g0 = gasleft();
        _swap(key1);
        uint256 oneInv = g0 - gasleft();

        emit log_named_uint("swap, plain hook            ", bareGas);
        emit log_named_uint("swap, AssayHook, 0 invariants", zeroInv);
        emit log_named_uint("swap, AssayHook, 1 invariant ", oneInv);
        emit log_named_uint("cost of the machinery        ", zeroInv - bareGas);
        emit log_named_uint("cost of one invariant        ", oneInv - zeroInv);
        assertLt(oneInv - bareGas, 15_000, "one runtime invariant must be cheap enough to ship");
    }

    function test_tooManyInvariantsRejected() public {
        address[] memory invs = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            invs[i] = address(floorInv);
        }
        address a = _hookAddr(0x8888);
        deal(token, a, FUNDED);
        vm.expectRevert();
        deployCodeTo("AssayHook.t.sol:AssayedLeakyHook", abi.encode(poolManager, token, thief, invs), a);
    }
}
