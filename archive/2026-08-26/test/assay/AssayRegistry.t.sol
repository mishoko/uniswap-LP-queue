// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {AssayRegistry} from "../../src/assay/AssayRegistry.sol";
import {HookBond} from "../../src/assay/HookBond.sol";
import {SolvencyPredicate, IAssayAccounting} from "../../src/assay/predicates/SolvencyPredicate.sol";
import {IHookPredicate} from "../../src/assay/IHookPredicate.sol";

contract PlainHook is IAssayAccounting {
    function assayAccrued(address) external pure returns (uint256) {
        return 0;
    }
}

contract AssayRegistryTest is Test {
    AssayRegistry registry;
    HookBond bondContract;
    PlainHook hook;
    MockERC20 token;
    SolvencyPredicate solvency;
    address author = address(0xA17403);
    address challenger = address(0xC4A11E);

    function setUp() public {
        bondContract = new HookBond();
        registry = new AssayRegistry(bondContract);
        hook = new PlainHook();
        token = new MockERC20("T", "T", 18);
        solvency = new SolvencyPredicate(address(token));
        vm.deal(author, 100 ether);
        vm.deal(challenger, 100 ether);
    }

    /// @dev One-element stake array for the common single-assertion bond.
    function _stakes1(uint96 v) internal pure returns (uint96[] memory st) {
        st = new uint96[](1);
        st[0] = v;
    }

    function _bond(uint256 amount, address who) internal returns (bytes32 id) {
        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        vm.prank(who);
        id = bondContract.bond{value: amount}(address(hook), ps, _stakes1(uint96(amount)));
    }

    /// @dev Permission decoding is pure address arithmetic: it works for any address, including one
    /// that has never been deployed. No RPC, no bytecode, no trust.
    function test_permissionsDecodeFromAddressAlone() public view {
        address deltaTaker = address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        AssayRegistry.HookReport memory r = registry.report(deltaTaker);
        assertTrue(r.canReturnSwapDelta, "address says it can move a swap delta");
        assertFalse(r.canReturnLiquidityDelta);
        assertEq(r.permissionBits, uint16(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        assertEq(deltaTaker.code.length, 0, "and it is not even deployed");
    }

    /// @dev The common case, and the point of the whole table: a hook that declares nothing and
    /// backs nothing is reported as such rather than omitted.
    function test_undeclaredUnbondedHookIsReportedNotOmitted() public view {
        AssayRegistry.HookReport memory r = registry.report(address(hook));
        assertFalse(r.hasRuntimeSpec, "no declared spec");
        assertFalse(r.metered);
        assertEq(r.bondedWei, 0);
        assertEq(r.liveBondCount, 0);
    }

    function test_totalsCapitalAcrossAuthors() public {
        _bond(1 ether, author);
        _bond(2 ether, challenger);
        AssayRegistry.HookReport memory r = registry.report(address(hook));
        assertEq(r.bondedWei, 3 ether, "backing is the sum over every author");
        assertEq(r.liveBondCount, 2);
    }

    /// @dev A matured exit means the backing can vanish in the next block. Reporting only the
    /// amount would overstate the guarantee, so the countdown is a column.
    function test_surfacesExitStateBecauseBackingCanVanish() public {
        bytes32 id = _bond(1 ether, author);

        AssayRegistry.HookReport memory r = registry.report(address(hook));
        assertFalse(r.anyExitRequested);

        vm.prank(author);
        bondContract.requestExit(id);
        r = registry.report(address(hook));
        assertTrue(r.anyExitRequested, "exit announced");
        assertFalse(r.anyExitMatured, "but not yet takeable");
        assertEq(r.bondedWei, 1 ether, "amount alone would look unchanged");

        vm.warp(block.timestamp + 7 days);
        r = registry.report(address(hook));
        assertTrue(r.anyExitMatured, "this bond can leave at any block");
    }

    /// @dev A slashing is permanent public record. Withdrawal deletes a bond; slashing must not be
    /// erasable the same way, or a hook could launder its history by re-bonding.
    function test_slashingStaysOnTheRecord() public {
        bytes32 id = _bond(1 ether, author);
        token.mint(address(0xdead), 1); // no-op, keeps the token live
        vm.mockCall(address(hook), abi.encodeWithSignature("assayAccrued(address)"), abi.encode(uint256(1e30)));

        vm.startPrank(challenger);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, bytes32("s"), challenger));
        vm.roll(block.number + 1);
        bondContract.challenge{value: 0.01 ether}(id, 0, bytes32("s"));
        vm.stopPrank();

        AssayRegistry.HookReport memory r = registry.report(address(hook));
        assertEq(r.slashedBondCount, 1, "the slashing is visible");
        assertEq(r.liveBondCount, 0);
        assertEq(r.bondedWei, 0);

        vm.clearMockedCalls();
        _bond(5 ether, challenger);
        r = registry.report(address(hook));
        assertEq(r.bondedWei, 5 ether, "new capital shows");
        assertEq(r.slashedBondCount, 1, "and does not erase the old slashing");
    }

    function test_reportManyBatches() public {
        _bond(1 ether, author);
        address[] memory hooks = new address[](2);
        hooks[0] = address(hook);
        hooks[1] = address(uint160(Hooks.BEFORE_SWAP_FLAG));
        AssayRegistry.HookReport[] memory rs = registry.reportMany(hooks);
        assertEq(rs.length, 2);
        assertEq(rs[0].bondedWei, 1 ether);
        assertEq(rs[1].bondedWei, 0);
    }
}

/// @dev Growth attacks on the per-hook bond list. The list is permissionless, so its length is
/// attacker-influenced, and anything that iterates it is a denial-of-service target.
contract AssayRegistryGrowthTest is Test {
    AssayRegistry registry;
    HookBond bondContract;
    PlainHook hook;
    MockERC20 token;
    SolvencyPredicate solvency;

    function setUp() public {
        bondContract = new HookBond();
        registry = new AssayRegistry(bondContract);
        hook = new PlainHook();
        token = new MockERC20("T", "T", 18);
        solvency = new SolvencyPredicate(address(token));
    }

    function _stakes1(uint96 v) internal pure returns (uint96[] memory st) {
        st = new uint96[](1);
        st[0] = v;
    }

    function _bond(address who, uint256 amount) internal returns (bytes32 id) {
        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        vm.deal(who, amount);
        vm.prank(who);
        id = bondContract.bond{value: amount}(address(hook), ps, _stakes1(uint96(amount)));
    }

    /// @dev bondId is deterministic in (hook, author), so bond -> withdraw -> re-bond would append
    /// the same id forever. Withdrawal returns the principal, so the attack costs only gas.
    function test_rebondingDoesNotGrowTheList() public {
        address a = address(0xBEEF);
        for (uint256 i = 0; i < 5; ++i) {
            bytes32 id = _bond(a, 0.01 ether);
            vm.startPrank(a);
            bondContract.requestExit(id);
            vm.warp(block.timestamp + 7 days);
            bondContract.withdraw(id);
            vm.stopPrank();
        }
        assertEq(bondContract.bondsOfHook(address(hook)).length, 1, "one entry per (hook, author), ever");
    }

    /// @dev Sybil authors still grow it, so the scan is bounded and says so rather than quietly
    /// reporting a partial total as complete.
    function test_scanIsBoundedAndAdmitsTruncation() public {
        for (uint256 i = 1; i <= 260; ++i) {
            _bond(address(uint160(0x10000 + i)), 0.01 ether);
        }
        AssayRegistry.HookReport memory r = registry.report(address(hook));
        assertTrue(r.bondScanTruncated, "partial totals must be labelled partial");
        assertEq(r.liveBondCount, registry.MAX_BOND_SCAN());
        assertLt(r.bondedWei, 2.6 ether, "and the reported figure is an explicit lower bound");
    }
}

contract RevertingSpecHook {
    function verifySpec() external pure returns (bytes memory) {
        revert("boom");
    }
}

contract AssayRegistryProbeTest is Test {
    AssayRegistry registry;
    HookBond bondContract;

    function setUp() public {
        bondContract = new HookBond();
        registry = new AssayRegistry(bondContract);
    }

    /// @dev "Declares no spec" and "we could not read the spec" are different facts about a hook.
    /// Collapsing them reports a hook with a perfectly good spec as having none, which is the
    /// direction of error a trust tool must never make.
    function test_probeFailureIsDistinctFromNoSpec() public {
        address broken = address(new RevertingSpecHook());
        AssayRegistry.HookReport memory r = registry.report(broken);
        assertTrue(r.specProbeFailed, "unreadable");
        assertFalse(r.hasRuntimeSpec);

        AssayRegistry.HookReport memory plain = registry.report(address(new PlainHook()));
        assertFalse(plain.specProbeFailed, "silence is not failure");
        assertFalse(plain.hasRuntimeSpec);
    }
}

contract AssayRegistryBreakdownTest is Test {
    AssayRegistry registry;
    HookBond bondContract;
    PlainHook hook;
    MockERC20 token;
    SolvencyPredicate solvency;
    CodehashLike codehash;
    address author = address(0xA17403);

    function setUp() public {
        bondContract = new HookBond();
        registry = new AssayRegistry(bondContract);
        hook = new PlainHook();
        token = new MockERC20("T", "T", 18);
        solvency = new SolvencyPredicate(address(token));
        codehash = new CodehashLike();
        vm.deal(author, 100 ether);
    }

    /// @dev A single bonded total hides which claims are actually backed. Tranches make the price of
    /// each assertion legible, which is the only thing that stops a spec being padded with claims
    /// nobody is really staking on.
    function test_breakdownShowsThePricePerClaim() public {
        address[] memory ps = new address[](2);
        ps[0] = address(solvency);
        ps[1] = address(codehash);
        uint96[] memory st = new uint96[](2);
        st[0] = uint96(40 ether);
        st[1] = uint96(0.01 ether);

        vm.prank(author);
        bondContract.bond{value: 40.01 ether}(address(hook), ps, st);

        (address[] memory preds, uint256[] memory stakes,) = registry.bondBreakdown(address(hook));
        assertEq(preds.length, 2);
        assertEq(stakes[0], 40 ether, "heavily backed");
        assertEq(stakes[1], 0.01 ether, "and this claim is decoration, visibly");

        AssayRegistry.HookReport memory r = registry.report(address(hook));
        assertEq(r.bondedWei, 40.01 ether, "a single total would make these look alike");
    }
}

contract CodehashLike is IHookPredicate {
    function check(address) external pure returns (bool) {
        return true;
    }

    function describe() external pure returns (string memory) {
        return "trivial";
    }
}
