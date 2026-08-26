// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
import {AssayBaseHook} from "../../src/assay/AssayBaseHook.sol";
import {AssayHook} from "../../src/assay/AssayHook.sol";
import {IHookPredicate, Verdict} from "../../src/assay/IHookPredicate.sol";
import {BalanceFloorPredicate} from "../../src/assay/predicates/BalanceFloorPredicate.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @dev A careless integrator. It declares a spec, drains on every swap, and NEVER calls
/// `_assertInvariants()` anywhere. Under a mixin that trusts the author to remember, this hook
/// would advertise a guarantee it does not enforce. Under `AssayBaseHook` it cannot.
contract ForgetfulHook is AssayBaseHook {
    address public immutable token;
    address public immutable thief;

    constructor(IPoolManager pm, address token_, address thief_, address[] memory invs) AssayBaseHook(pm, invs) {
        token = token_;
        thief = thief_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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

    // Note what is absent: no _assertInvariants(), no super call, nothing.
    function _assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        IERC20(token).transfer(thief, 1e18);
        return (this.afterSwap.selector, int128(0));
    }
}

contract AssayBaseHookTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);
    uint256 constant FUNDED = 100e18;

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    address thief = address(0x7417F);
    address token;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        token = Currency.unwrap(currency1);
        vm.roll(100);
        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);
    }

    /// @dev The guarantee is structural, not a convention the author has to honour. `_afterSwap` is
    /// implemented in `AssayBaseHook` WITHOUT `virtual`, so this subclass could not have skipped the
    /// assertion even deliberately: the compiler would reject the override.
    function test_enforcementSurvivesAnIntegratorWhoNeverCallsIt() public {
        BalanceFloorPredicate floor = new BalanceFloorPredicate(token, FUNDED);
        address[] memory invs = new address[](1);
        invs[0] = address(floor);

        address h = address(FLAGS ^ (uint160(0x9911) << 144));
        deal(token, h, FUNDED);
        deployCodeTo("AssayBaseHook.t.sol:ForgetfulHook", abi.encode(poolManager, token, thief, invs), h);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: ForgetfulHook(h)
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

        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        assertEq(IERC20(token).balanceOf(h), FUNDED, "the drain was refused");
        assertEq(IERC20(token).balanceOf(thief), 0);
    }
}

/// @dev Burns well past the 30k runtime budget, then succeeds. Under the generous adjudication
/// budget it HOLDS; under the runtime budget it cannot answer.
contract HungryPredicate is IHookPredicate {
    function check(address) external view returns (bool) {
        uint256 target = gasleft() > 60_000 ? gasleft() - 60_000 : 0;
        while (gasleft() > target) {}
        return true;
    }

    function describe() external pure returns (string memory) {
        return "expensive";
    }
}

/// @dev Does nothing. Isolates the spec machinery from any hook behaviour.
contract QuietHook is AssayBaseHook {
    constructor(IPoolManager pm, address[] memory invs) AssayBaseHook(pm, invs) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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
}

contract AssaySpecConsistencyTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);

    Currency currency0;
    Currency currency1;
    HardcapLP lp;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);
        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);
    }

    /// @dev `verifySpec` must answer at the SAME budget the callback uses. Evaluated generously it
    /// would report HOLDS for a predicate the 30k runtime check cannot afford — the registry would
    /// call a bricked hook healthy, which is the worst possible failure for a trust tool.
    function test_verifySpecAgreesWithRuntime_notWithAGenerousBudget() public {
        address[] memory invs = new address[](1);
        invs[0] = address(new HungryPredicate());

        address h = address(FLAGS ^ (uint160(0xAB01) << 144));
        deployCodeTo("AssayBaseHook.t.sol:QuietHook", abi.encode(poolManager, invs), h);

        Verdict[] memory v = AssayHook(h).verifySpec();
        assertEq(uint256(v[0]), uint256(Verdict.INCONCLUSIVE), "reported as un-evaluable, matching runtime");

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: QuietHook(h)
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

        vm.expectRevert();
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
}

/// @dev A predicate that works, then permanently stops being evaluable. Models infrastructure
/// failure rather than an attack: the hook did nothing wrong and has no way to recover.
contract DecayingPredicate is IHookPredicate {
    bool public dead;

    function kill() external {
        dead = true;
    }

    function check(address) external view returns (bool) {
        require(!dead, "unevaluable");
        return true;
    }

    function describe() external pure returns (string memory) {
        return "decaying";
    }
}

contract AssayExitPathTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    DecayingPredicate pred;
    PoolKey key;
    address hookAddr;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);
        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        pred = new DecayingPredicate();
        address[] memory invs = new address[](1);
        invs[0] = address(pred);

        hookAddr = address(FLAGS ^ (uint160(0xEE01) << 144));
        deployCodeTo("AssayBaseHook.t.sol:ExitQuietHook", abi.encode(poolManager, invs), hookAddr);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: ExitQuietHook(hookAddr)
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

    /// @dev The asymmetry that keeps fail-closed from being a trap. The invariant set is immutable
    /// with no recovery path, so a predicate that permanently stops answering would otherwise lock
    /// every LP's capital in the pool forever.
    function test_lpCanAlwaysExitEvenWhenTheSpecIsUnevaluable() public {
        pred.kill();

        // swaps are refused: doubt fails closed everywhere except the way out
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 before = currency0.balanceOf(address(this));
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: -int256(500e18),
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        assertGt(currency0.balanceOf(address(this)), before, "the LP got their capital back");
    }
}

contract ExitQuietHook is AssayBaseHook {
    constructor(IPoolManager pm, address[] memory invs) AssayBaseHook(pm, invs) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
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
}
