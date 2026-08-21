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
import {AssayStack} from "../../src/assay/AssayStack.sol";
import {IAssaySubHook} from "../../src/assay/IAssaySubHook.sol";
import {DeltaBudgetPredicate} from "../../src/assay/predicates/DeltaBudgetPredicate.sol";

/// @dev Well-behaved guest: asks for 0.5% of the fill.
contract PoliteSubHook is IAssaySubHook {
    function assayAfterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        external
        pure
        returns (uint256)
    {
        int128 amount = (params.amountSpecified < 0 == params.zeroForOne) ? delta.amount1() : delta.amount0();
        uint256 notional = amount >= 0 ? uint256(uint128(amount)) : uint256(uint128(-amount));
        key; // silence
        return notional / 200;
    }
}

/// @dev Asks for everything. A guest with real authority would take it.
contract GreedySubHook is IAssaySubHook {
    function assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta)
        external
        pure
        returns (uint256)
    {
        return type(uint256).max;
    }
}

/// @dev Simply broken.
contract RevertingSubHook is IAssaySubHook {
    function assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta)
        external
        pure
        returns (uint256)
    {
        revert("i am broken");
    }
}

/// @dev Burns everything it is given and never returns.
contract GasBurningSubHook is IAssaySubHook {
    function assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta)
        external
        view
        returns (uint256)
    {
        while (gasleft() > 0) {}
        return 0;
    }
}

contract AssayStackTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint256 constant SWAP_IN = 1e16;

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    AssayStack stack;
    PoolKey key;

    PoliteSubHook polite;
    GreedySubHook greedy;
    RevertingSubHook broken;
    GasBurningSubHook burner;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);
        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        polite = new PoliteSubHook();
        greedy = new GreedySubHook();
        broken = new RevertingSubHook();
        burner = new GasBurningSubHook();

        address[] memory subs = new address[](4);
        subs[0] = address(polite);
        subs[1] = address(greedy);
        subs[2] = address(broken);
        subs[3] = address(burner);
        uint16[] memory budgets = new uint16[](4);
        budgets[0] = 100; // 1%
        budgets[1] = 50; // 0.5% -- the greedy guest gets exactly this and not a wei more
        budgets[2] = 100;
        budgets[3] = 100;

        address[] memory invs = new address[](1);
        invs[0] = address(new DeltaBudgetPredicate(poolManager, currency1, 1e15));

        address h = address(FLAGS ^ (uint160(0x57AC) << 144));
        deployCodeTo("AssayStack.sol:AssayStack", abi.encode(poolManager, subs, budgets, uint16(300), invs), h);
        stack = AssayStack(h);

        key = PoolKey({currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: stack});
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

    function _swap() internal returns (uint256 userOut) {
        uint256 before = currency1.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        userOut = currency1.balanceOf(address(this)) - before;
    }

    /// @dev Four guests on one pool, one of them hostile, one broken, one that eats gas — and the
    /// pool works. This is what v4's one-hook-per-pool limit costs today, and what bounding
    /// authority buys back.
    function test_fourGuestsOneHostileAndThePoolStillWorks() public {
        uint256 userOut = _swap();
        assertGt(userOut, 0, "the swap completed");

        uint256 politeGot = stack.accrued(address(polite), currency1);
        uint256 greedyGot = stack.accrued(address(greedy), currency1);
        assertGt(politeGot, 0, "the polite guest was paid what it asked for");
        assertGt(greedyGot, 0, "the hostile guest was paid");

        uint256 notional = userOut + politeGot + greedyGot;
        assertApproxEqRel(greedyGot, (notional * 50) / 10_000, 0.01e18, "hostile guest got EXACTLY its budget");
        assertEq(stack.accrued(address(broken), currency1), 0, "broken guest got nothing");
        assertEq(stack.accrued(address(burner), currency1), 0, "gas burner got nothing");
    }

    /// @dev A guest asking for the entire universe receives exactly its budget. Its request is a
    /// number, not an authority — so asking for `type(uint256).max` buys nothing that asking for the
    /// budget would not have. That is the whole containment model in one assertion.
    function test_hostileRequestBuysNothing() public {
        uint256 userOut = _swap();
        uint256 greedyGot = stack.accrued(address(greedy), currency1);
        uint256 politeGot = stack.accrued(address(polite), currency1);
        uint256 notional = userOut + greedyGot + politeGot;

        assertEq(greedyGot, (notional * 50) / 10_000, "exactly its budget, to the wei");
        assertLe(greedyGot, politeGot, "and no more than a guest that asked politely within a larger budget");
    }

    /// @dev A broken guest must not be able to brick a pool other people's liquidity sits in.
    function test_brokenGuestIsSkippedNotFatal() public {
        uint256 first = _swap();
        uint256 second = _swap();
        assertGt(first, 0);
        assertGt(second, 0, "and it keeps working, swap after swap");
    }

    function test_guestsWithdrawSeparatelyFromTheSwap() public {
        _swap();
        uint256 owed = stack.accrued(address(polite), currency1);
        assertGt(owed, 0);

        vm.prank(address(polite));
        stack.withdraw(currency1);
        assertEq(currency1.balanceOf(address(polite)), owed, "guest collected");
        assertEq(stack.accrued(address(polite), currency1), 0);

        vm.prank(address(broken));
        vm.expectRevert(AssayStack.NothingAccrued.selector);
        stack.withdraw(currency1);
    }

    /// @dev The guest list is immutable and there is no admin. Nobody can slip a new guest into a
    /// live pool, so a set audited once stays the set.
    function test_guestSetIsImmutableAndPublic() public view {
        (address[] memory hooks, uint16[] memory budgets) = stack.subHooks();
        assertEq(hooks.length, 4);
        assertEq(hooks[1], address(greedy));
        assertEq(budgets[1], 50);
        assertEq(stack.stackMaxBps(), 300);
    }

    /// @dev Total extraction is bounded by the stack's own ceiling even if the guests' individual
    /// budgets sum higher, and the stack's own ledger invariant bounds it again.
    function test_totalIsCappedByTheStackCeiling() public {
        uint256 userOut = _swap();
        uint256 total = stack.accrued(address(polite), currency1) + stack.accrued(address(greedy), currency1);
        uint256 notional = userOut + total;
        assertLe(total, (notional * 300) / 10_000, "stack ceiling holds");
        // individual budgets sum to 3.5%, above the 3% ceiling, so the ceiling is load-bearing
        assertLt(total, (notional * 350) / 10_000);
    }
}

/// @dev Returns 128KB of data. Under a naive `(bool, bytes memory)` call the SWAPPER pays for the
/// memory expansion, on every swap, forever.
contract BombingSubHook is IAssaySubHook {
    function assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta)
        external
        pure
        returns (uint256)
    {
        assembly {
            return(0, 0x20000)
        }
    }
}

/// @dev Tries to pull tokens out of the stack from inside its own dispatch.
contract ReentrantSubHook is IAssaySubHook {
    AssayStack public stack;
    Currency public currency;

    function arm(AssayStack s, Currency c) external {
        stack = s;
        currency = c;
    }

    function assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta) external returns (uint256) {
        stack.withdraw(currency);
        return 0;
    }
}

contract AssayStackHostileGuestTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    AssayStack stack;
    PoolKey key;
    BombingSubHook bomber;
    ReentrantSubHook reenterer;
    PoliteSubHook polite;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);
        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        bomber = new BombingSubHook();
        reenterer = new ReentrantSubHook();
        polite = new PoliteSubHook();

        address[] memory subs = new address[](3);
        subs[0] = address(polite);
        subs[1] = address(bomber);
        subs[2] = address(reenterer);
        uint16[] memory budgets = new uint16[](3);
        budgets[0] = 100;
        budgets[1] = 100;
        budgets[2] = 100;

        address h = address(FLAGS ^ (uint160(0x57B0) << 144));
        deployCodeTo(
            "AssayStack.sol:AssayStack", abi.encode(poolManager, subs, budgets, uint16(300), new address[](0)), h
        );
        stack = AssayStack(h);
        reenterer.arm(stack, currency1);

        key = PoolKey({currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: stack});
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

    function _swap() internal {
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

    /// @dev Never let untrusted code choose how much memory the caller allocates. The stack copies
    /// at most one word back, so a guest's 128KB return is its own problem.
    function test_returndataBombDoesNotChargeTheSwapper() public {
        _swap(); // warm

        uint256 g0 = gasleft();
        _swap();
        uint256 used = g0 - gasleft();

        emit log_named_uint("swap with a bombing guest", used);
        assertLt(used, 250_000, "the bomb is contained to the guest's own stipend");
        assertEq(stack.accrued(address(bomber), currency1), 0, "and it earns nothing");
        assertGt(stack.accrued(address(polite), currency1), 0, "well-behaved guests unaffected");
    }

    /// @dev A guest reentering mid-dispatch is refused, and being refused only costs the guest its
    /// own turn -- the swap and the other guests are untouched.
    function test_reentrantGuestIsRefusedAndOnlyHurtsItself() public {
        _swap();
        assertEq(stack.accrued(address(reenterer), currency1), 0, "reverted, so skipped");
        assertGt(stack.accrued(address(polite), currency1), 0, "the pool and its other guests carry on");
    }
}
