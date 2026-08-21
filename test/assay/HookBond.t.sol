// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookBond} from "../../src/assay/HookBond.sol";
import {IHookPredicate, Verdict} from "../../src/assay/IHookPredicate.sol";
import {SolvencyPredicate, IAssayAccounting} from "../../src/assay/predicates/SolvencyPredicate.sol";
import {
    NoSwapDeltaPredicate,
    PermissionMatchPredicate,
    CodehashPredicate
} from "../../src/assay/predicates/PermissionPredicates.sol";

/// @dev A hook whose declared liability can be made to exceed its assets on demand, i.e. a hook
/// that can be made provably insolvent. Stands in for the broken-hook fleet.
contract MockBondedHook is IAssayAccounting {
    mapping(address => uint256) public declared;

    function setDeclared(address token, uint256 amount) external {
        declared[token] = amount;
    }

    function assayAccrued(address token) external view returns (uint256) {
        return declared[token];
    }
}

contract FlipPredicate is IHookPredicate {
    bool public value = true;

    function set(bool v) external {
        value = v;
    }

    function check(address) external view returns (bool) {
        return value;
    }

    function describe() external pure returns (string memory) {
        return "flip";
    }
}

/// @dev Becomes permanently un-evaluable on command.
contract BreakablePredicate is IHookPredicate {
    bool public broken;

    function breakIt() external {
        broken = true;
    }

    function check(address) external view returns (bool) {
        require(!broken, "broken");
        return true;
    }

    function describe() external pure returns (string memory) {
        return "breakable";
    }
}

contract ReentrantChallenger {
    HookBond bondContract;
    bytes32 id;
    bool armed = true;

    constructor(HookBond b, bytes32 id_) {
        bondContract = b;
        id = id_;
    }

    function commit() external {
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, bytes32("a"), address(this)));
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, bytes32("b"), address(this)));
    }

    function go() external {
        bondContract.challenge{value: 0.01 ether}(id, 0, bytes32("a"));
    }

    receive() external payable {
        if (armed) {
            armed = false;
            bondContract.challenge{value: 0.01 ether}(id, 0, bytes32("b"));
        }
    }
}

contract HookBondTest is Test {
    HookBond bondContract;
    MockBondedHook hook;
    MockERC20 token;
    SolvencyPredicate solvency;

    address author = address(0xA17403);
    address challenger = address(0xC4A11E);

    uint256 constant BOND = 1 ether;

    function setUp() public {
        bondContract = new HookBond();
        hook = new MockBondedHook();
        token = new MockERC20("T", "T", 18);
        solvency = new SolvencyPredicate(address(token));
        vm.deal(author, 100 ether);
        vm.deal(challenger, 100 ether);
    }

    uint256 internal saltNonce;

    /// @dev Full commit-reveal round trip for `who`.
    function _challenge(bytes32 id, uint256 index, address who) internal {
        bytes32 salt = bytes32(++saltNonce);
        vm.startPrank(who);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, index, salt, who));
        vm.roll(block.number + 1);
        bondContract.challenge{value: 0.01 ether}(id, index, salt);
        vm.stopPrank();
    }

    /// @dev One-element stake array for the common single-assertion bond.
    function _stakes1(uint96 v) internal pure returns (uint96[] memory st) {
        st = new uint96[](1);
        st[0] = v;
    }

    function _bondSolvency() internal returns (bytes32 id) {
        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        vm.prank(author);
        id = bondContract.bond{value: BOND}(address(hook), ps, _stakes1(uint96(BOND)));
    }

    function _breakSolvency() internal {
        hook.setDeclared(address(token), 1_000e18); // declares a liability it does not hold
    }

    // --------------------------------------------------------------- bonding

    function test_bond_requiresEveryPredicateToHoldNow() public {
        _breakSolvency();
        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(HookBond.PredicateDoesNotHold.selector, address(solvency), Verdict.VIOLATED)
        );
        bondContract.bond{value: BOND}(address(hook), ps, _stakes1(uint96(BOND)));
    }

    /// @dev Closes "bond an un-evaluable spec so nobody can ever slash you".
    function test_bond_rejectsUnevaluablePredicate() public {
        BreakablePredicate p = new BreakablePredicate();
        p.breakIt();
        address[] memory ps = new address[](1);
        ps[0] = address(p);
        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(HookBond.PredicateDoesNotHold.selector, address(p), Verdict.INCONCLUSIVE)
        );
        bondContract.bond{value: BOND}(address(hook), ps, _stakes1(uint96(BOND)));
    }

    function test_bond_isKeyedByHookAndAuthor_noSquatting() public {
        bytes32 a = _bondSolvency();
        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        address other = address(0xBEEF);
        vm.deal(other, 1 ether);
        vm.prank(other);
        bytes32 b = bondContract.bond{value: 0.01 ether}(address(hook), ps, _stakes1(uint96(0.01 ether)));
        assertTrue(a != b, "a dust bond cannot block a real one on the same hook");
    }

    function test_bond_capsPredicateCount() public {
        address[] memory ps = new address[](9);
        for (uint256 i = 0; i < 9; ++i) {
            ps[i] = address(new FlipPredicate());
        }
        uint96[] memory st = new uint96[](9);
        for (uint256 i = 0; i < 9; ++i) {
            st[i] = uint96(BOND / 9);
        }
        vm.prank(author);
        vm.expectRevert(HookBond.TooManyPredicates.selector);
        bondContract.bond{value: BOND}(address(hook), ps, st);
    }

    function test_spec_canOnlyBeStrengthened() public {
        bytes32 id = _bondSolvency();
        FlipPredicate p = new FlipPredicate();
        vm.prank(author);
        bondContract.addPredicate{value: 0.01 ether}(id, address(p));
        assertEq(bondContract.predicatesOf(id).length, 2);
    }

    function test_addPredicate_mustHoldAndIsAuthorOnly() public {
        bytes32 id = _bondSolvency();
        FlipPredicate p = new FlipPredicate();
        p.set(false);
        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(HookBond.PredicateDoesNotHold.selector, address(p), Verdict.VIOLATED));
        bondContract.addPredicate{value: 0.01 ether}(id, address(p));

        FlipPredicate ok = new FlipPredicate();
        vm.prank(challenger);
        vm.expectRevert(HookBond.NotAuthor.selector);
        bondContract.addPredicate{value: 0.01 ether}(id, address(ok));
    }

    // ------------------------------------------------- TRAP 1: the exit race

    function test_exit_happyPath() public {
        bytes32 id = _bondSolvency();
        vm.startPrank(author);
        bondContract.requestExit(id);
        vm.warp(block.timestamp + 7 days);
        uint256 before = author.balance;
        bondContract.withdraw(id);
        vm.stopPrank();
        assertEq(author.balance - before, BOND);
    }

    /// @dev THE race this design exists to close: the author holds a matured exit request, sees a
    /// challenge coming, and tries to front-run it with withdraw(). Exit re-checks the spec.
    function test_exit_isBlockedWhileSpecIsViolated() public {
        bytes32 id = _bondSolvency();
        vm.prank(author);
        bondContract.requestExit(id);
        vm.warp(block.timestamp + 7 days);

        _breakSolvency();

        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(HookBond.SpecViolated.selector, address(solvency)));
        bondContract.withdraw(id);

        // and it stays blocked forever, not merely until the escape window opens
        vm.warp(block.timestamp + 3650 days);
        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(HookBond.SpecViolated.selector, address(solvency)));
        bondContract.withdraw(id);

        // so the bond is still there to be slashed
        _challenge(id, 0, challenger);
        (,, uint96 amount,, bool slashed) = bondContract.bonds(id);
        assertEq(amount, 0);
        assertTrue(slashed);
    }

    function test_exit_requiresMaturedRequest() public {
        bytes32 id = _bondSolvency();
        vm.startPrank(author);
        vm.expectRevert(HookBond.ExitNotRequested.selector);
        bondContract.withdraw(id);
        bondContract.requestExit(id);
        vm.expectRevert(HookBond.ExitNotMatured.selector);
        bondContract.withdraw(id);
        vm.stopPrank();
    }

    /// @dev An un-evaluable predicate must not lock an honest author's principal forever, but it
    /// must cost real time. VIOLATED gets no such escape (asserted above).
    function test_exit_inconclusiveBlocksUntilEscapeDelay() public {
        BreakablePredicate p = new BreakablePredicate();
        address[] memory ps = new address[](1);
        ps[0] = address(p);
        vm.prank(author);
        bytes32 id = bondContract.bond{value: BOND}(address(hook), ps, _stakes1(uint96(BOND)));

        vm.prank(author);
        bondContract.requestExit(id);
        vm.warp(block.timestamp + 7 days);
        p.breakIt();

        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(HookBond.SpecInconclusive.selector, address(p)));
        bondContract.withdraw(id);

        vm.warp(block.timestamp + 90 days);
        uint256 before = author.balance;
        vm.prank(author);
        bondContract.withdraw(id);
        assertEq(author.balance - before, BOND);
    }

    // --------------------------------------------------- TRAP 2: self-slash

    function test_slash_paysBountyAndForfeitsTheRest() public {
        bytes32 id = _bondSolvency();
        _breakSolvency();

        uint256 before = challenger.balance;
        _challenge(id, 0, challenger);

        assertEq(challenger.balance - before, 0.1 ether, "10% bounty, stake returned");
        assertEq(bondContract.forfeited(address(hook)), 0.9 ether, "90% leaves the author's reach");
        assertEq(address(bondContract).balance, 0.9 ether);
    }

    /// @dev Slashing must not be a refund. An author who sybils a challenge against their own
    /// violated hook recovers only the bounty and loses the rest permanently.
    function test_selfSlash_isNotARefund() public {
        bytes32 id = _bondSolvency();
        _breakSolvency();

        uint256 before = author.balance;
        _challenge(id, 0, author);

        assertEq(author.balance - before, 0.1 ether, "author recovers only the 10% bounty");
        assertEq(bondContract.forfeited(address(hook)), 0.9 ether, "90% of their own bond is gone");
    }

    // ---------------------------------------------------- TRAP 3: griefing

    function test_falseChallenge_forfeitsStake() public {
        bytes32 id = _bondSolvency();
        uint256 before = challenger.balance;
        _challenge(id, 0, challenger);
        assertEq(before - challenger.balance, 0.01 ether, "spam costs the challenger");
        assertEq(bondContract.forfeited(address(hook)), 0.01 ether, "and never pays the author");
        (,, uint96 amount,, bool slashed) = bondContract.bonds(id);
        assertEq(amount, uint96(BOND), "honest bond untouched");
        assertFalse(slashed);
    }

    /// @dev An un-evaluable predicate is not a false claim. Refund the stake; only gas is lost.
    function test_inconclusiveChallenge_refundsStake() public {
        BreakablePredicate p = new BreakablePredicate();
        address[] memory ps = new address[](1);
        ps[0] = address(p);
        vm.prank(author);
        bytes32 id = bondContract.bond{value: BOND}(address(hook), ps, _stakes1(uint96(BOND)));
        p.breakIt();

        uint256 before = challenger.balance;
        _challenge(id, 0, challenger);
        assertEq(challenger.balance, before, "stake refunded");
        (,, uint96 amount,,) = bondContract.bonds(id);
        assertEq(amount, uint96(BOND), "un-evaluable is not slashable");
    }

    function test_challenge_requiresExactStake() public {
        bytes32 id = _bondSolvency();
        vm.prank(challenger);
        vm.expectRevert(HookBond.BadStake.selector);
        bondContract.challenge{value: 0.005 ether}(id, 0, bytes32(0));
    }

    function test_challenge_reentrancyIsBlocked() public {
        bytes32 id = _bondSolvency();
        _breakSolvency();
        ReentrantChallenger r = new ReentrantChallenger(bondContract, id);
        vm.deal(address(r), 1 ether);
        r.commit();
        vm.roll(block.number + 1);

        vm.expectRevert(HookBond.TransferFailed.selector);
        r.go();

        (,, uint96 amount,, bool slashed) = bondContract.bonds(id);
        assertEq(amount, uint96(BOND), "state rolled back");
        assertFalse(slashed);
    }

    /// @dev The tranche model's defining behaviour. Slashing settles ONE assertion; the assertions
    /// that still hold are still backed, so the bond stays alive and the hook does not lose the
    /// capital standing behind claims it never broke.
    function test_slashingOneTrancheLeavesTheRestStanding() public {
        FlipPredicate other = new FlipPredicate();
        address[] memory ps = new address[](2);
        ps[0] = address(solvency);
        ps[1] = address(other);
        uint96[] memory st = new uint96[](2);
        st[0] = uint96(0.25 ether);
        st[1] = uint96(0.75 ether);

        vm.prank(author);
        bytes32 id = bondContract.bond{value: 1 ether}(address(hook), ps, st);
        _breakSolvency();

        uint256 before = challenger.balance;
        _challenge(id, 0, challenger);

        assertEq(challenger.balance - before, 0.025 ether, "bounty is 10% of THAT tranche, not the bond");
        assertEq(bondContract.forfeited(address(hook)), 0.225 ether);

        (,, uint96 amount,, bool everSlashed) = bondContract.bonds(id);
        assertEq(amount, 0.75 ether, "the untouched assertion keeps its backing");
        assertTrue(everSlashed, "and the slashing is permanent public record");

        uint96[] memory after_ = bondContract.stakesOf(id);
        assertEq(after_[0], 0, "settled");
        assertEq(after_[1], 0.75 ether, "still staked");

        // the bond is still live: the surviving tranche can still be topped up and still slashed
        vm.prank(author);
        bondContract.topUp{value: 0.1 ether}(id, 1);
        (,, amount,,) = bondContract.bonds(id);
        assertEq(amount, 0.85 ether);
    }

    function test_slashedTrancheCannotBeSlashedTwice() public {
        bytes32 id = _bondSolvency();
        _breakSolvency();
        _challenge(id, 0, challenger);

        vm.startPrank(challenger);
        bytes32 salt2 = bytes32(uint256(99));
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, salt2, challenger));
        vm.roll(block.number + 1);
        // the whole bond was one tranche, so nothing is left at all
        vm.expectRevert(HookBond.BondEmpty.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt2);
        vm.stopPrank();
    }

    /// @dev A settled tranche must stop constraining the exit. Otherwise one broken assertion locks
    /// the author's other tranches forever, punishing twice for a breach already paid for.
    function test_slashedAssertionNoLongerBlocksTheExit() public {
        FlipPredicate other = new FlipPredicate();
        address[] memory ps = new address[](2);
        ps[0] = address(solvency);
        ps[1] = address(other);
        uint96[] memory st = new uint96[](2);
        st[0] = uint96(0.25 ether);
        st[1] = uint96(0.75 ether);

        vm.prank(author);
        bytes32 id = bondContract.bond{value: 1 ether}(address(hook), ps, st);
        _breakSolvency();
        _challenge(id, 0, challenger);

        // solvency is STILL false, but that claim has been settled and paid out
        assertFalse(solvency.check(address(hook)));

        vm.startPrank(author);
        bondContract.requestExit(id);
        vm.warp(block.timestamp + 7 days);
        uint256 before = author.balance;
        bondContract.withdraw(id);
        vm.stopPrank();
        assertEq(author.balance - before, 0.75 ether, "the honest tranche comes back");
    }

    function test_bond_rejectsMismatchedStakes() public {
        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        uint96[] memory st = new uint96[](1);
        st[0] = uint96(0.5 ether);
        vm.prank(author);
        vm.expectRevert(HookBond.StakeMismatch.selector);
        bondContract.bond{value: 1 ether}(address(hook), ps, st);
    }

    /// @dev A spec cannot be padded with claims backed by dust.
    function test_bond_rejectsDustTranche() public {
        FlipPredicate other = new FlipPredicate();
        address[] memory ps = new address[](2);
        ps[0] = address(solvency);
        ps[1] = address(other);
        uint96[] memory st = new uint96[](2);
        st[0] = uint96(1 ether - 1 wei);
        st[1] = 1 wei;
        vm.prank(author);
        vm.expectRevert(HookBond.TrancheTooSmall.selector);
        bondContract.bond{value: 1 ether}(address(hook), ps, st);
    }

    // ------------------------------------------- address-derived predicates

    function test_permissionPredicates_areZeroCall() public {
        NoSwapDeltaPredicate nd = new NoSwapDeltaPredicate();
        address safe = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        address delta = address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        assertTrue(nd.check(safe));
        assertFalse(nd.check(delta), "a delta-returning hook cannot claim it takes nothing");

        PermissionMatchPredicate pm = new PermissionMatchPredicate(uint160(Hooks.BEFORE_SWAP_FLAG));
        assertTrue(pm.check(address(uint160(Hooks.BEFORE_SWAP_FLAG))));
        assertFalse(pm.check(safe), "undeclared authority is a violation");
    }

    function test_codehashPredicate_pinsDeployedCode() public {
        CodehashPredicate cp = new CodehashPredicate(address(hook));
        assertTrue(cp.check(address(hook)));
        assertFalse(cp.check(address(new MockERC20("X", "X", 18))), "different code fails the pin");
    }
}

/// @dev Conservation: HookBond preaches solvency, so it must be solvent. Every wei in the contract
/// is either a live bond or forfeited, never both and never unaccounted.
contract HookBondConservationTest is Test {
    HookBond bondContract;
    MockBondedHook hook;
    MockERC20 token;
    SolvencyPredicate solvency;
    address author = address(0xA17403);
    address challenger = address(0xC4A11E);

    function setUp() public {
        bondContract = new HookBond();
        hook = new MockBondedHook();
        token = new MockERC20("T", "T", 18);
        solvency = new SolvencyPredicate(address(token));
        vm.deal(author, 100 ether);
        vm.deal(challenger, 100 ether);
    }

    uint256 internal saltNonce;

    /// @dev Full commit-reveal round trip for `who`.
    function _challenge(bytes32 id, uint256 index, address who) internal {
        bytes32 salt = bytes32(++saltNonce);
        vm.startPrank(who);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, index, salt, who));
        vm.roll(block.number + 1);
        bondContract.challenge{value: 0.01 ether}(id, index, salt);
        vm.stopPrank();
    }

    /// @dev One-element stake array for the common single-assertion bond.
    function _stakes1(uint96 v) internal pure returns (uint96[] memory st) {
        st = new uint96[](1);
        st[0] = v;
    }

    function _bond(uint256 amount) internal returns (bytes32 id) {
        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        vm.prank(author);
        id = bondContract.bond{value: amount}(address(hook), ps, _stakes1(uint96(amount)));
    }

    function test_conservation_acrossFullLifecycle() public {
        bytes32 id = _bond(1 ether);
        (,, uint96 amount,,) = bondContract.bonds(id);
        assertEq(address(bondContract).balance, uint256(amount) + bondContract.forfeited(address(hook)));

        vm.prank(author);
        bondContract.topUp{value: 2 ether}(id, 0);
        (,, amount,,) = bondContract.bonds(id);
        assertEq(address(bondContract).balance, uint256(amount) + bondContract.forfeited(address(hook)));

        _challenge(id, 0, challenger); // false challenge, stake forfeited
        (,, amount,,) = bondContract.bonds(id);
        assertEq(address(bondContract).balance, uint256(amount) + bondContract.forfeited(address(hook)));

        hook.setDeclared(address(token), 1e18);
        _challenge(id, 0, challenger); // real slash
        (,, amount,,) = bondContract.bonds(id);
        assertEq(amount, 0);
        assertEq(address(bondContract).balance, bondContract.forfeited(address(hook)));
    }

    /// @dev The unbonding delay must cover every wei, not just the first deposit.
    function test_topUp_restartsTheExitClock() public {
        bytes32 id = _bond(0.01 ether);
        vm.prank(author);
        bondContract.requestExit(id);
        vm.warp(block.timestamp + 7 days);

        vm.prank(author);
        bondContract.topUp{value: 50 ether}(id, 0);

        vm.prank(author);
        vm.expectRevert(HookBond.ExitNotRequested.selector);
        bondContract.withdraw(id); // the matured exit was consumed by the top-up
    }

    function test_topUp_isAuthorOnly() public {
        bytes32 id = _bond(1 ether);
        vm.prank(challenger);
        vm.expectRevert(HookBond.NotAuthor.selector);
        bondContract.topUp{value: 1 wei}(id, 0); // otherwise anyone could reset the author's clock
    }

    /// @dev A withdrawn bond must vanish, not linger at zero: a lingering bond is challengeable for
    /// a 0-value "slash" the registry would read as real, and it would permanently block the author
    /// from re-bonding this hook, since bondId is (hook, author).
    function test_withdrawnBondIsDeletedAndRebondable() public {
        bytes32 id = _bond(1 ether);
        vm.startPrank(author);
        bondContract.requestExit(id);
        vm.warp(block.timestamp + 7 days);
        bondContract.withdraw(id);
        vm.stopPrank();

        (address h, address a,,,) = bondContract.bonds(id);
        assertEq(h, address(0));
        assertEq(a, address(0));
        assertEq(bondContract.predicatesOf(id).length, 0);

        vm.startPrank(challenger);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, bytes32(uint256(7)), challenger));
        vm.roll(block.number + 1);
        vm.expectRevert(HookBond.NoBond.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, bytes32(uint256(7)));
        vm.stopPrank();

        bytes32 again = _bond(1 ether);
        assertEq(again, id, "same author can bond the same hook again");
    }
}

/// @dev The reason challenges are commit-reveal at all: a bare challenge transaction is copyable
/// out of the mempool, so the researcher who found the violation loses the bounty to whoever is
/// ordered first. If findings are stealable, nobody looks for them.
contract HookBondCommitRevealTest is Test {
    HookBond bondContract;
    MockBondedHook hook;
    MockERC20 token;
    SolvencyPredicate solvency;
    address author = address(0xA17403);
    address researcher = address(0x9E5EA5);
    address copier = address(0xC0271E);
    bytes32 id;

    function setUp() public {
        bondContract = new HookBond();
        hook = new MockBondedHook();
        token = new MockERC20("T", "T", 18);
        solvency = new SolvencyPredicate(address(token));
        vm.deal(author, 100 ether);
        vm.deal(researcher, 100 ether);
        vm.deal(copier, 100 ether);

        address[] memory ps = new address[](1);
        ps[0] = address(solvency);
        vm.prank(author);
        uint96[] memory st = new uint96[](1);
        st[0] = uint96(1 ether);
        id = bondContract.bond{value: 1 ether}(address(hook), ps, st);
        hook.setDeclared(address(token), 1_000e18); // provably insolvent
    }

    /// @dev THE property. The copier watches the reveal, learns (bondId, index, salt) verbatim, and
    /// still cannot use it: the commitment binds the challenger's address.
    function test_revealedSaltIsUselessToAnObserver() public {
        bytes32 salt = bytes32(uint256(0xDEADBEEF));
        vm.prank(researcher);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, salt, researcher));
        vm.roll(block.number + 1);

        // copier front-runs the reveal with the exact same arguments
        vm.prank(copier);
        vm.expectRevert(HookBond.NoCommit.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt);

        uint256 before = researcher.balance;
        vm.prank(researcher);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt);
        assertEq(researcher.balance - before, 0.1 ether, "the researcher is paid, not the copier");
    }

    function test_commitCannotBeRevealedInTheSameBlock() public {
        bytes32 salt = bytes32(uint256(1));
        vm.startPrank(researcher);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, salt, researcher));
        vm.expectRevert(HookBond.CommitTooYoung.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt);
        vm.stopPrank();
    }

    function test_commitExpires() public {
        bytes32 salt = bytes32(uint256(2));
        vm.startPrank(researcher);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, salt, researcher));
        vm.roll(block.number + 257);
        vm.expectRevert(HookBond.CommitExpired.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt);
        vm.stopPrank();
    }

    function test_challengeWithoutCommitReverts() public {
        vm.prank(researcher);
        vm.expectRevert(HookBond.NoCommit.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, bytes32(uint256(3)));
    }

    function test_commitIsSingleUse() public {
        bytes32 salt = bytes32(uint256(4));
        vm.startPrank(researcher);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, salt, researcher));
        vm.roll(block.number + 1);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt);
        vm.expectRevert(HookBond.NoCommit.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, salt);
        vm.stopPrank();
    }

    /// @dev Honest limit, asserted rather than hidden: a searcher who blanket pre-commits across
    /// every (bond, predicate) pair beforehand CAN still race the reveal and take the bounty.
    /// Commit-reveal converts a free copy into a speculative, gas-costly position; it does not
    /// eliminate it. Note the slash still happens either way — only the payee changes.
    function test_knownLimit_preCommittedSearcherCanStillRace() public {
        bytes32 sSalt = bytes32(uint256(5));
        vm.prank(copier);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, sSalt, copier));

        bytes32 rSalt = bytes32(uint256(6));
        vm.prank(researcher);
        bondContract.commitChallenge(bondContract.challengeCommitment(id, 0, rSalt, researcher));

        vm.roll(block.number + 1);

        uint256 copierBefore = copier.balance;
        vm.prank(copier);
        bondContract.challenge{value: 0.01 ether}(id, 0, sSalt);
        assertEq(copier.balance - copierBefore, 0.1 ether, "pre-committed searcher wins the race");

        vm.prank(researcher);
        vm.expectRevert(HookBond.BondEmpty.selector);
        bondContract.challenge{value: 0.01 ether}(id, 0, rSalt);
    }
}
