// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// SPIKE 2026-08-26 — HASTE / SWITCHBACK router-compatibility.
//
// Question under test: does a hook that NoOps the swap (returns zero output to the caller) survive
// the CANONICAL periphery swap path, or does the router's slippage check reject it?
//
// Two independent router paths are exercised, both real code, neither written by us:
//   (1) UniswapV4Router04  — the deployed artifact hookmate ships; what this repo's own tests use.
//   (2) V4Router           — the abstract in v4-periphery/src that UniversalRouter inherits for its
//                            v4 actions. Driven here through a 20-line concrete subclass that is a
//                            copy of v4-periphery's own test/mocks/MockV4Router.sol.
//
// Everything asserted below is asserted by execution. Nothing is asserted from reading source.

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {V4Router} from "./vendor/V4Router_vendored.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {ReentrancyLock} from "@uniswap/v4-periphery/src/base/ReentrancyLock.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";


import {BaseTest} from "../utils/BaseTest.sol";
import {HardcapLP} from "../utils/HardcapLP.sol";

/*//////////////////////////////////////////////////////////////
                              ROUTER
//////////////////////////////////////////////////////////////*/

/// @dev Byte-for-byte the shape of v4-periphery's own test/mocks/MockV4Router.sol. It exists only to
///      make the abstract `V4Router` concrete. `V4Router` is the exact contract UniversalRouter
///      inherits to dispatch v4 actions, so a revert here is a revert through UniversalRouter.
contract UniversalRouterStandIn is V4Router, ReentrancyLock {
    constructor(IPoolManager _pm) V4Router(_pm) {}

    function executeActions(bytes calldata params) external payable isNotLocked {
        _executeActions(params);
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        MockERC20(Currency.unwrap(token)).transferFrom(payer, address(this), amount);
        MockERC20(Currency.unwrap(token)).transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function msgSender() public view override returns (address) {
        return _getLocker();
    }
}

/*//////////////////////////////////////////////////////////////
                               HOOKS
//////////////////////////////////////////////////////////////*/

/// @notice HASTE's deferred lane, reduced to its essential shape: consume the entire specified
///         amount in beforeSwap, touch the curve for zero, escrow the input as an ERC-6909 claim,
///         and give the caller nothing back now.
contract NoOpEscrowHook is BaseHook {
    address public lastSender;
    bytes public lastHookData;
    uint256 public escrowed;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        lastSender = sender;
        lastHookData = hookData;

        // exact-input only for this spike
        require(params.amountSpecified < 0, "exactIn only");
        uint256 amountIn = uint256(-params.amountSpecified);
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Take the input off the ledger as a 6909 claim. This is the escrow.
        poolManager.mint(address(this), inputCurrency.toId(), amountIn);
        escrowed += amountIn;

        // amountToSwap = amountSpecified + specifiedDelta = 0  ->  the curve is never touched.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(-params.amountSpecified), 0), 0);
    }
}

/// @notice SWITCHBACK's fee shape: let the swap execute normally, then skim a slice of the
///         UNSPECIFIED (output) side via afterSwapReturnDelta.
contract OutputSkimHook is BaseHook {
    uint256 public constant SKIM_BPS = 500; // 5%
    uint256 public skimmed;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // exact-in: the unspecified side is the output, positive on the caller's delta.
        int128 out = params.zeroForOne ? delta.amount1() : delta.amount0();
        require(out > 0, "no output");
        uint256 fee = (uint256(uint128(out)) * SKIM_BPS) / 10_000;

        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        poolManager.mint(address(this), outputCurrency.toId(), fee);
        skimmed += fee;

        // positive unspecified delta = the hook is owed; the caller pays it out of their output.
        return (BaseHook.afterSwap.selector, int128(uint128(fee)));
    }
}

/// @notice Q4 variant: keep the curve untouched (so the pool's price is NOT moved now) but pay the
///         caller their output IMMEDIATELY out of the hook's own inventory. The hook, not the
///         trader, then carries the timing risk. Router-clean by construction, because the caller
///         does receive a real, nonzero output in the same transaction.
contract InventoryFillHook is BaseHook {
    uint256 public constant QUOTE_BPS = 9_900; // pays 99% of notional, 1:1 pool
    uint256 public deferredInventory;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @dev seed the hook with output-side inventory, held as 6909 claims
    function seed(Currency c, uint256 amount) external {
        MockERC20(Currency.unwrap(c)).transferFrom(msg.sender, address(this), amount);
        poolManager.unlock(abi.encode(c, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm only");
        (Currency c, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.sync(c);
        MockERC20(Currency.unwrap(c)).transfer(address(poolManager), amount);
        poolManager.settle();
        poolManager.mint(address(this), c.toId(), amount);
        return "";
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(params.amountSpecified < 0, "exactIn only");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 payOut = (amountIn * QUOTE_BPS) / 10_000;

        Currency inC = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outC = params.zeroForOne ? key.currency1 : key.currency0;

        // escrow the input; release the output from inventory
        poolManager.mint(address(this), inC.toId(), amountIn);
        poolManager.burn(address(this), outC.toId(), payOut);
        deferredInventory += amountIn;

        // specified: +amountIn (curve untouched). unspecified: -payOut (hook owes it -> caller receives it).
        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(int128(-params.amountSpecified), -int128(uint128(payOut))),
            0
        );
    }
}

/*//////////////////////////////////////////////////////////////
                                TEST
//////////////////////////////////////////////////////////////*/

contract RouterCompatibilityTest is BaseTest {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint128 internal constant LIQUIDITY = 1_000e18;
    uint256 internal constant SWAP_IN = 1e18;

    Currency currency0;
    Currency currency1;
    HardcapLP lp;
    UniversalRouterStandIn urStandIn;

    NoOpEscrowHook noOpHook;
    OutputSkimHook skimHook;
    InventoryFillHook invHook;
    PoolKey noOpKey;
    PoolKey skimKey;
    PoolKey invKey;
    PoolKey vanillaKey;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        _approve(address(lp));

        urStandIn = new UniversalRouterStandIn(poolManager);
        _approve(address(urStandIn));

        noOpHook = NoOpEscrowHook(_deployAt("RouterCompatibility.t.sol:NoOpEscrowHook", 0x88, Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        skimHook = OutputSkimHook(_deployAt("RouterCompatibility.t.sol:OutputSkimHook", 0x99, Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        invHook = InventoryFillHook(_deployAt("RouterCompatibility.t.sol:InventoryFillHook", 0xaa, Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));

        noOpKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(noOpHook)));
        skimKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(skimHook)));
        invKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(invHook)));
        vanillaKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));

        poolManager.initialize(noOpKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(skimKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(invKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);

        ModifyLiquidityParams memory add = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: int256(uint256(LIQUIDITY)),
            salt: bytes32(0)
        });
        lp.modifyLiquidity(noOpKey, add, "");
        lp.modifyLiquidity(skimKey, add, "");
        lp.modifyLiquidity(invKey, add, "");
        lp.modifyLiquidity(vanillaKey, add, "");

        _approve(address(invHook));
        invHook.seed(currency1, 100e18);

        vm.roll(block.number + 1);
    }

    /* ---------------------------------------------------------------------- */
    /* Q1 — does the canonical router reject a NoOp'd swap?                    */
    /* ---------------------------------------------------------------------- */

    /// PROVES: through UniswapV4Router04 with any nonzero amountOutMin, a NoOp'd swap reverts.
    function test_Q1_hookmateRouter_revertsOnNoOpWithSlippage() public {
        try swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_IN,
            amountOutMin: 1,
            zeroForOne: true,
            poolKey: noOpKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        }) {
            fail();
        } catch (bytes memory reason) {
            emit log_named_bytes("hookmate UniswapV4Router04 revert", reason);
            // Recorded by execution: 0x8199f5f3 == SlippageExceeded(), the router's own error.
            // Asserting the EXACT selector matters: an earlier, looser version of this test
            // ("reverted with data") passed under a mutant that reverted with CurrencyNotSettled()
            // instead, i.e. it proved nothing about slippage.
            assertEq(bytes4(reason), bytes4(0x8199f5f3), "must be SlippageExceeded(), not some other revert");
            assertEq(reason.length, 4, "no args");
        }
    }

    /// PROVES: through V4Router (== UniversalRouter's v4 dispatch) the revert is
    ///         IV4Router.V4TooLittleReceived(minOut, 0) and it originates in _swapExactInputSingle.
    function test_Q1_v4Router_revertsWithV4TooLittleReceived() public {
        uint128 minOut = 1;
        bytes memory actions = _exactInSingleActions(noOpKey, SWAP_IN, minOut, "");

        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, uint256(minOut), uint256(0)));
        urStandIn.executeActions(actions);
    }

    /// CONTROL: the identical action sequence on a hookless pool succeeds, so the revert above is
    /// caused by the NoOp and not by the harness.
    function test_Q1_control_vanillaPoolSucceedsThroughV4Router() public {
        uint256 before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        urStandIn.executeActions(_exactInSingleActions(vanillaKey, SWAP_IN, 1, ""));
        assertGt(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)), before, "vanilla swap produced output");
    }

    /* ---------------------------------------------------------------------- */
    /* Q2 — does amountOutMinimum = 0 rescue it, and what does it cost?        */
    /* ---------------------------------------------------------------------- */

    /// PROVES: minOut = 0 does pass the router's slippage check. The user pays the input, receives
    /// ZERO output in the same transaction, and the hook holds the escrow. Reachable — but the only
    /// way to reach it is to disable slippage protection entirely.
    function test_Q2_zeroMinOutPasses_userReceivesNothing() public {
        uint256 in0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 in1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        urStandIn.executeActions(_exactInSingleActions(noOpKey, SWAP_IN, 0, ""));

        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)), in0 - SWAP_IN, "user paid the input");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)), in1, "user received nothing");
        assertEq(noOpHook.escrowed(), SWAP_IN, "hook escrowed the input");
        assertEq(poolManager.balanceOf(address(noOpHook), currency0.toId()), SWAP_IN, "escrow is a 6909 claim");
    }

    /// PROVES: the same works through the hookmate UniswapV4Router04 artifact.
    function test_Q2_zeroMinOutPasses_onHookmateRouter() public {
        uint256 in1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: noOpKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)), in1, "user received nothing");
        assertEq(noOpHook.escrowed(), SWAP_IN, "hook escrowed the input");
    }

    /* ---------------------------------------------------------------------- */
    /* Q3 — what does the hook actually see about the trader?                  */
    /* ---------------------------------------------------------------------- */

    /// PROVES: `sender` in beforeSwap is the ROUTER, not the trader. A deferred order placed through
    /// standard routing has no way to learn its own owner except from hookData, which the router
    /// does forward verbatim.
    function test_Q3_senderIsTheRouterNotTheTrader() public {
        urStandIn.executeActions(_exactInSingleActions(noOpKey, SWAP_IN, 0, abi.encode(address(this))));

        assertEq(noOpHook.lastSender(), address(urStandIn), "hook sees the router as sender");
        assertTrue(noOpHook.lastSender() != address(this), "hook cannot see the trader");
        assertEq(abi.decode(noOpHook.lastHookData(), (address)), address(this), "hookData carries the beneficiary");
    }

    /// PROVES the failure mode: default (empty) hookData leaves the hook with no beneficiary at all.
    function test_Q3_emptyHookDataLeavesNoBeneficiary() public {
        urStandIn.executeActions(_exactInSingleActions(noOpKey, SWAP_IN, 0, ""));
        assertEq(noOpHook.lastHookData().length, 0, "no beneficiary was supplied");
    }

    /* ---------------------------------------------------------------------- */
    /* Q5 — is a fee taken via afterSwapReturnDelta router-clean?              */
    /* ---------------------------------------------------------------------- */

    /// PROVES: the skimmed fee is invisible to the caller except as reduced output, so the router's
    /// slippage check sees the POST-fee number. Router-clean, but the fee is inside the user's
    /// slippage budget: a swap quoted before the fee was known reverts if the fee exceeds tolerance.
    function test_Q5_outputSkimRevertsAgainstAPreFeeQuote() public {
        // quote on the hookless twin, then demand that number from the fee-charging pool
        uint256 before1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        urStandIn.executeActions(_exactInSingleActions(vanillaKey, SWAP_IN, 0, ""));
        uint128 preFeeQuote = uint128(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before1);
        assertGt(preFeeQuote, 0, "control quote is nonzero");

        vm.expectRevert(); // V4TooLittleReceived(preFeeQuote, preFeeQuote - 5%)
        urStandIn.executeActions(_exactInSingleActions(skimKey, SWAP_IN, preFeeQuote, ""));
    }

    /// PROVES: with a normal slippage tolerance that accommodates the fee, the skim is fully
    /// router-clean — the swap settles, the user is paid, the hook holds the fee.
    function test_Q5_outputSkimIsRouterCleanWithinTolerance() public {
        uint256 before1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        urStandIn.executeActions(_exactInSingleActions(skimKey, SWAP_IN, 0, ""));
        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before1;

        assertGt(received, 0, "user was paid");
        assertGt(skimHook.skimmed(), 0, "hook took the fee");
        assertEq(
            poolManager.balanceOf(address(skimHook), currency1.toId()), skimHook.skimmed(), "fee held as 6909 claim"
        );
        // the 5% skim is inside the user's output, not an extra charge on the input:
        // gross = received + skimmed, and skimmed == 5% of gross.
        uint256 gross = received + skimHook.skimmed();
        assertApproxEqRel(skimHook.skimmed(), gross * 500 / 10_000, 0.0001e18, "skim is 5% of gross output");
        assertLt(received, gross, "user's output is reduced by exactly the skim");
    }

    /// PROVES: the same on the deployed hookmate router artifact.
    function test_Q5_outputSkimIsRouterCleanOnHookmateRouter() public {
        uint256 before1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: skimKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
        assertGt(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before1, 0, "user was paid");
        assertGt(skimHook.skimmed(), 0, "hook took the fee");
    }

    /* ---------------------------------------------------------------------- */
    /* Q4 — is there a deferred-lane variant that IS router-clean?             */
    /* ---------------------------------------------------------------------- */

    /// PROVES: yes, one exists. If the hook pays the caller out of its OWN inventory while leaving
    /// the curve untouched, a full-slippage-protected swap settles through V4Router with a normal
    /// minOut. The trader is filled instantly; the deferral moves onto the hook's balance sheet.
    function test_Q4_inventoryBackedFillIsRouterCleanWithRealSlippage() public {
        uint128 minOut = uint128(SWAP_IN * 9_800 / 10_000); // demand 98%, hook quotes 99%
        uint256 before1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        urStandIn.executeActions(_exactInSingleActions(invKey, SWAP_IN, minOut, ""));

        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before1;
        assertGe(received, minOut, "real slippage protection was satisfied");
        assertEq(received, SWAP_IN * 9_900 / 10_000, "filled at the hook's quote");
        assertEq(invHook.deferredInventory(), SWAP_IN, "hook now carries the unhedged input");
    }

    /// PROVES the cost of that variant: the pool's price did NOT move, so the hook is short the
    /// trade and the timing risk it removed from the trader now sits on the hook.
    function test_Q4_inventoryFillLeavesThePoolPriceUntouched() public {
        (uint160 before_,,,) = _slot0(invKey);
        urStandIn.executeActions(_exactInSingleActions(invKey, SWAP_IN, 0, ""));
        (uint160 after_,,,) = _slot0(invKey);
        assertEq(after_, before_, "curve untouched: the hook absorbed the whole trade");
    }

    /* ---------------------------------------------------------------------- */
    /* DELIBERATE BREAK — confirm these tests can go red                       */
    /* ---------------------------------------------------------------------- */

    /// The Q1 assertion is only meaningful if a NON-NoOp hook on the same harness DOES satisfy a
    /// nonzero minOut. If this ever reverts, Q1 is proving something about the harness, not the hook.
    function test_break_nonNoOpHookOnSameHarnessSatisfiesSlippage() public {
        urStandIn.executeActions(_exactInSingleActions(skimKey, SWAP_IN, 1, ""));
        urStandIn.executeActions(_exactInSingleActions(invKey, SWAP_IN, 1, ""));
        urStandIn.executeActions(_exactInSingleActions(vanillaKey, SWAP_IN, 1, ""));
    }

    /* ---------------------------------------------------------------------- */
    /* helpers                                                                */
    /* ---------------------------------------------------------------------- */

    function _exactInSingleActions(PoolKey memory key, uint256 amountIn, uint128 minOut, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        Plan memory plan = Planner.init().add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: true,
                    amountIn: uint128(amountIn),
                    amountOutMinimum: minOut,
                    hookData: hookData
                })
            )
        );
        return plan.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
    }

    function _slot0(PoolKey memory key) internal view returns (uint160, int24, uint24, uint24) {
        return StateLibrary.getSlot0(poolManager, key.toId());
    }

    function _approve(address spender) internal {
        MockERC20(Currency.unwrap(currency0)).approve(spender, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(spender, type(uint256).max);
    }

    function _deployAt(string memory what, uint160 ns, uint160 flags) internal returns (address addr) {
        addr = address(uint160(flags) ^ (ns << 144));
        deployCodeTo(what, abi.encode(poolManager), addr);
    }
}
