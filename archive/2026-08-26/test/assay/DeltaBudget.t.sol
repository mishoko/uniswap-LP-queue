// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
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
import {DeltaBudgetPredicate} from "../../src/assay/predicates/DeltaBudgetPredicate.sol";
import {SolvencyPredicate} from "../../src/assay/predicates/SolvencyPredicate.sol";

/// @dev A hook with an over-extraction bug: it siphons a large slice of every swap's output out of
/// the PoolManager. It ALSO lies about its own accounting, reporting zero liability — which is what
/// a hook whose accounting is buggy, or malicious, actually looks like.
contract GreedyHook is BaseHook {
    using CurrencySettler for Currency;

    uint256 public constant SIPHON_BPS = 5_000; // half of every fill

    constructor(IPoolManager pm) BaseHook(pm) {}

    /// @dev The lie. Any predicate that trusts the hook's own numbers is satisfied by this.
    function assayAccrued(address) external pure returns (uint256) {
        return 0;
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
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        (Currency unspecified, int128 amount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        uint256 notional = amount >= 0 ? uint256(uint128(amount)) : uint256(uint128(-amount));
        uint256 siphon = (notional * SIPHON_BPS) / 10_000;
        if (siphon == 0) return (this.afterSwap.selector, 0);

        unspecified.take(poolManager, address(this), siphon, false);
        return (this.afterSwap.selector, int128(uint128(siphon)));
    }
}

/// @dev Identical extraction code, plus a declared budget it cannot exceed.
contract AssayedGreedyHook is GreedyHook, AssayHook {
    constructor(IPoolManager pm, address[] memory invs) GreedyHook(pm) AssayHook(invs) {}

    function _afterSwap(address s, PoolKey calldata k, SwapParams calldata p, BalanceDelta d, bytes calldata h)
        internal
        override
        returns (bytes4, int128)
    {
        (bytes4 sel, int128 amt) = super._afterSwap(s, k, p, d, h);
        _assertInvariants();
        return (sel, amt);
    }
}

contract DeltaBudgetTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint256 constant SWAP_IN = 1e16;
    /// @dev Far below the ~50% the buggy hook tries to siphon.
    uint256 constant BUDGET = 1e13;

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    DeltaBudgetPredicate budget;
    SolvencyPredicate solvency;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        budget = new DeltaBudgetPredicate(poolManager, currency1, BUDGET);
        solvency = new SolvencyPredicate(Currency.unwrap(currency1));
    }

    function _openPool(address hookAddr) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: GreedyHook(hookAddr)
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
            amountIn: SWAP_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _budgetInv() internal view returns (address[] memory invs) {
        invs = new address[](1);
        invs[0] = address(budget);
    }

    /// @dev Baseline: unbounded extraction works, and the user eats it.
    function test_greedyHook_siphonsHalfOfEveryFill() public {
        address h = address(FLAGS ^ (uint160(0xAA11) << 144));
        deployCodeTo("DeltaBudget.t.sol:GreedyHook", abi.encode(poolManager), h);
        PoolKey memory key = _openPool(h);

        uint256 before = currency1.balanceOf(address(this));
        _swap(key);
        uint256 userOut = currency1.balanceOf(address(this)) - before;
        uint256 hookTook = currency1.balanceOf(h);

        assertGt(hookTook, 0, "hook extracted");
        assertApproxEqRel(hookTook, userOut, 0.02e18, "roughly half the fill went to the hook");
    }

    /// @dev The same extraction, refused. Not compensated — not executable.
    function test_assayedGreedy_cannotExceedItsDeclaredBudget() public {
        address h = address(FLAGS ^ (uint160(0xBB22) << 144));
        deployCodeTo("DeltaBudget.t.sol:AssayedGreedyHook", abi.encode(poolManager, _budgetInv()), h);
        PoolKey memory key = _openPool(h);

        vm.expectRevert();
        _swap(key);
        assertEq(currency1.balanceOf(h), 0, "nothing left the pool");
    }

    /// @dev THE point, as a controlled differential: ONE hook, ONE bug, two declared specs. The
    /// only variable is which invariant the hook carries, so the outcome difference can only come
    /// from the invariant.
    ///
    /// The hook reports owing nothing. A predicate that trusts the hook's own numbers is therefore
    /// satisfied — vacuously — and the extraction goes through. The ledger predicate reads the
    /// number PoolManager keeps, which the hook does not own and cannot lie about, and the same
    /// extraction becomes unexecutable.
    function test_sameBugSameHook_solvencyPassesItLedgerStopsIt() public {
        address[] memory solvencySpec = new address[](1);
        solvencySpec[0] = address(solvency);
        address trusting = address(FLAGS ^ (uint160(0xCC33) << 144));
        deployCodeTo("DeltaBudget.t.sol:AssayedGreedyHook", abi.encode(poolManager, solvencySpec), trusting);
        PoolKey memory trustingKey = _openPool(trusting);

        address ledgered = address(FLAGS ^ (uint160(0xCC44) << 144));
        deployCodeTo("DeltaBudget.t.sol:AssayedGreedyHook", abi.encode(poolManager, _budgetInv()), ledgered);
        PoolKey memory ledgeredKey = _openPool(ledgered);

        // Spec = "I am solvent by my own accounting". The lie satisfies it; the drain completes.
        _swap(trustingKey);
        assertGt(currency1.balanceOf(trusting), 0, "self-reported solvency did not stop the extraction");
        assertEq(
            GreedyHook(trusting).assayAccrued(Currency.unwrap(currency1)), 0, "because the hook reports owing nothing"
        );
        assertTrue(solvency.check(trusting), "and the predicate agrees, vacuously");

        // Spec = "my debt to PoolManager stays within budget". Same bug, refused.
        vm.expectRevert();
        _swap(ledgeredKey);
        assertEq(currency1.balanceOf(ledgered), 0, "not one wei left the pool");
    }

    /// @dev No false positives: extraction inside the declared budget is untouched.
    function test_extractionWithinBudgetIsAllowed() public {
        DeltaBudgetPredicate generous = new DeltaBudgetPredicate(poolManager, currency1, 1e18);
        address[] memory invs = new address[](1);
        invs[0] = address(generous);

        address h = address(FLAGS ^ (uint160(0xDD44) << 144));
        deployCodeTo("DeltaBudget.t.sol:AssayedGreedyHook", abi.encode(poolManager, invs), h);
        PoolKey memory key = _openPool(h);

        _swap(key);
        assertGt(currency1.balanceOf(h), 0, "within budget, the hook still works");
    }

    function test_gasCostOfLedgerInvariant() public {
        address bare = address(FLAGS ^ (uint160(0xEE55) << 144));
        deployCodeTo("DeltaBudget.t.sol:GreedyHook", abi.encode(poolManager), bare);
        PoolKey memory bareKey = _openPool(bare);

        DeltaBudgetPredicate generous = new DeltaBudgetPredicate(poolManager, currency1, 1e18);
        address[] memory invs = new address[](1);
        invs[0] = address(generous);
        address guarded = address(FLAGS ^ (uint160(0xFF66) << 144));
        deployCodeTo("DeltaBudget.t.sol:AssayedGreedyHook", abi.encode(poolManager, invs), guarded);
        PoolKey memory guardedKey = _openPool(guarded);

        _swap(bareKey);
        _swap(guardedKey);

        uint256 g0 = gasleft();
        _swap(bareKey);
        uint256 bareGas = g0 - gasleft();
        g0 = gasleft();
        _swap(guardedKey);
        uint256 guardedGas = g0 - gasleft();

        emit log_named_uint("swap, unbounded hook       ", bareGas);
        emit log_named_uint("swap, ledger-bounded hook  ", guardedGas);
        emit log_named_uint("cost of the ledger check   ", guardedGas - bareGas);
        assertLt(guardedGas - bareGas, 15_000, "reading PoolManager's ledger must be cheap");
    }
}
