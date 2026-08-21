// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {HardcapLP} from "../utils/HardcapLP.sol";
import {HardcapHook} from "../../src/HardcapHook.sol";
import {HardcapMath} from "../../src/libraries/HardcapMath.sol";
import {HookBond} from "../../src/assay/HookBond.sol";
import {Verdict} from "../../src/assay/IHookPredicate.sol";
import {SolvencyPredicate} from "../../src/assay/predicates/SolvencyPredicate.sol";
import {NoSwapDeltaPredicate, PermissionMatchPredicate} from "../../src/assay/predicates/PermissionPredicates.sol";

/// @dev End-to-end: a real v4 hook backing real assertions with real capital, and the same
/// assertions having teeth against it. This is the demo.
contract AssayHardcapTest is BaseTest {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    HardcapHook hook;
    HardcapLP lp;
    HookBond bondContract;
    SolvencyPredicate solvency1;

    address author = address(0xA17403);
    address researcher = address(0x9E5EA5);
    bytes32 bondId;
    uint256 saltNonce;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        vm.roll(100);

        lp = new HardcapLP(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lp), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lp), type(uint256).max);

        address hookAddr = address(FLAGS ^ (uint160(0xA55A) << 144));
        bytes memory args = abi.encode(
            poolManager, currency0, currency1, FEE, TICK_SPACING, uint16(5), HardcapMath.DEFAULT_MAX_TAKE_BPS, uint48(1)
        );
        deployCodeTo("HardcapHook.sol:HardcapHook", args, hookAddr);
        hook = HardcapHook(hookAddr);

        poolKey = hook.boundPoolKey();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1_000e18,
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        vm.roll(block.number + 1);

        bondContract = new HookBond();
        solvency1 = new SolvencyPredicate(Currency.unwrap(currency1));
        vm.deal(author, 100 ether);
        vm.deal(researcher, 100 ether);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    /// @dev One-element stake array for the common single-assertion bond.
    function _stakes1(uint96 v) internal pure returns (uint96[] memory st) {
        st = new uint96[](1);
        st[0] = v;
    }

    function _bond() internal returns (bytes32 id) {
        address[] memory ps = new address[](1);
        ps[0] = address(solvency1);
        vm.prank(author);
        id = bondContract.bond{value: 1 ether}(address(hook), ps, _stakes1(uint96(1 ether)));
    }

    function _challenge(bytes32 id, address who) internal {
        bytes32 salt = bytes32(++saltNonce);
        vm.startPrank(who);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, salt, who));
        vm.roll(block.number + 1);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt);
        vm.stopPrank();
    }

    /// @dev Simulates the hook's vault being emptied without its accounting being updated —
    /// the failure mode SolvencyPredicate exists to make falsifiable.
    function _drain() internal {
        address token = Currency.unwrap(currency1);
        uint256 accrued = hook.assayAccrued(token);
        assertGt(accrued, 0, "need a non-zero liability for the drain to be meaningful");
        deal(token, address(hook), accrued - 1);
    }

    function test_hardcapBondsItsOwnSolvency() public {
        _swap(true, 1e18);
        assertGt(hook.assayAccrued(Currency.unwrap(currency1)), 0, "hook declares a liability");
        bondId = _bond();
        (address h, address a, uint96 amount,,) = bondContract.bonds(bondId);
        assertEq(h, address(hook));
        assertEq(a, author);
        assertEq(amount, 1 ether);
    }

    /// @dev Honest hooks are not slashable. A challenge against a solvent hook costs the challenger.
    function test_challengingASolventHookCostsTheChallenger() public {
        _swap(true, 1e18);
        bondId = _bond();

        uint256 before = researcher.balance;
        _challenge(bondId, researcher);

        assertEq(before - researcher.balance, 0.01 ether, "false challenge forfeits the stake");
        (,, uint96 amount,, bool slashed) = bondContract.bonds(bondId);
        assertEq(amount, 1 ether, "bond untouched");
        assertFalse(slashed);
    }

    /// @dev And the same assertion has teeth: drain the vault, and anyone can slash.
    function test_drainedVaultIsSlashableByAnyone() public {
        _swap(true, 1e18);
        bondId = _bond();
        _drain();

        uint256 before = researcher.balance;
        _challenge(bondId, researcher);

        assertEq(researcher.balance - before, 0.1 ether, "bounty paid");
        assertEq(bondContract.forfeited(address(hook)), 0.9 ether);
        (,, uint96 amount,, bool slashed) = bondContract.bonds(bondId);
        assertEq(amount, 0);
        assertTrue(slashed);
    }

    function test_authorCannotExitADrainedHook() public {
        _swap(true, 1e18);
        bondId = _bond();

        vm.prank(author);
        bondContract.requestExit(bondId);
        vm.warp(block.timestamp + 7 days);

        _drain();

        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(HookBond.SpecViolated.selector, address(solvency1)));
        bondContract.withdraw(bondId);
    }

    /// @dev The zero-call predicate has teeth against the hook's own author. Hardcap takes a fee
    /// via afterSwapReturnDelta, so its ADDRESS says it can move a swap delta and it cannot bond a
    /// claim to the contrary — no matter what its README says. Nothing is called to prove this.
    function test_hardcapCannotBondAClaimItsAddressContradicts() public {
        NoSwapDeltaPredicate nd = new NoSwapDeltaPredicate();
        address[] memory ps = new address[](1);
        ps[0] = address(nd);
        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(HookBond.PredicateDoesNotHold.selector, address(nd), Verdict.VIOLATED));
        bondContract.bond{value: 1 ether}(address(hook), ps, _stakes1(uint96(1 ether)));
    }

    function test_hardcapCanBondItsExactPermissionSet() public {
        PermissionMatchPredicate pm = new PermissionMatchPredicate(FLAGS);
        address[] memory ps = new address[](1);
        ps[0] = address(pm);
        vm.prank(author);
        bytes32 id = bondContract.bond{value: 1 ether}(address(hook), ps, _stakes1(uint96(1 ether)));
        assertEq(bondContract.predicatesOf(id).length, 1);

        PermissionMatchPredicate wrong = new PermissionMatchPredicate(uint160(Hooks.BEFORE_SWAP_FLAG));
        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(HookBond.PredicateDoesNotHold.selector, address(wrong), Verdict.VIOLATED)
        );
        bondContract.addPredicate{value: 0.01 ether}(id, address(wrong));
    }
}
