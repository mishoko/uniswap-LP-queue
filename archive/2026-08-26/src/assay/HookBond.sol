// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHookPredicate, Verdict} from "./IHookPredicate.sol";
import {PredicateSandbox} from "./PredicateSandbox.sol";

/// @title HookBond
/// @notice Capital posted by a hook author to back a set of falsifiable, present-state assertions
/// about their Uniswap v4 hook. Anyone can slash the bond by proving on-chain that an assertion is
/// false. This prices trust in a hook instead of asking for it.
///
/// What this is NOT (must not lie):
/// 1. The bond does not cover losses. A bond smaller than the pool's TVL does not deter a rational
///    attacker. It is a costly signal plus challenger funding. The number that matters is
///    bond/TVL, which the registry surfaces — not a badge, not a grade.
/// 2. Only present-state invariants are provable. "This swap was unfairly priced" and "the hook
///    stole from a user in block N" are NOT expressible and are never claimed.
/// 3. Slashing is compensation-shaped, not prevention. It fires after the fact.
///
/// Design rails, each closing a specific attack (see docs/SPIKE-predicate-sandbox.md §5):
/// - Exit requires proving your own spec. `withdraw` re-evaluates every predicate; a VIOLATED
///   predicate blocks withdrawal permanently. This closes the front-run where an author races a
///   pending challenge with an exit — you cannot leave while your own spec is broken.
/// - Unbonding delay gives challengers time to find violations before capital can leave at all.
/// - Specs can only be STRENGTHENED. `addPredicate` exists; there is no remove.
/// - Self-slashing is not a refund. The bounty is a small fraction; the remainder leaves the
///   author's reach permanently, so sybil-challenging your own violated hook costs real money.
/// - Capital is staked PER ASSERTION. An all-or-nothing bond makes the rational author declare the
///   weakest spec that survives, because one tight claim puts the whole stake at risk. Tranches
///   price each claim separately: slashing one leaves the others standing, and the amount behind
///   each specific assertion becomes a public number. That is the price signal the registry exists
///   to publish — "this hook staked 40 ETH on never exceeding its budget and 0.01 ETH on its
///   codehash" says something a single total cannot.
/// - Predicate count is capped, because a hostile predicate can burn the sandbox stipend and
///   evaluation is O(predicates).
contract HookBond is ReentrancyGuard {
    /// @dev Time between requesting an exit and being allowed to take it.
    uint64 public constant UNBONDING_DELAY = 7 days;
    /// @dev After this much additional time, an author may exit past predicates that have become
    /// permanently un-evaluable (INCONCLUSIVE). VIOLATED never becomes exitable. Without this an
    /// author's capital could be locked forever by a predicate contract breaking outside their
    /// control; with it, a broken predicate costs time, not principal.
    uint64 public constant ESCAPE_DELAY = 90 days;
    /// @dev Challenger's cut of a successful slash. Small on purpose: see self-slashing above.
    uint256 public constant BOUNTY_BPS = 1_000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @dev Anti-spam. Forfeited only on a provably FALSE challenge, never on INCONCLUSIVE.
    uint256 public constant CHALLENGER_STAKE = 0.01 ether;
    uint256 public constant MIN_BOND = 0.01 ether;
    /// @dev Floor per assertion, so a spec cannot be padded with claims backed by dust.
    uint256 public constant MIN_TRANCHE = 0.001 ether;
    /// @dev Bounded because each predicate can burn PredicateSandbox.STIPEND.
    uint256 public constant MAX_PREDICATES = 8;
    /// @dev Blocks a commitment must age before it can be revealed. One block is deliberate: it is
    /// the minimum that defeats a reactive copier (who cannot forge a commit for a past block) and
    /// the maximum shortness, which matters because the gap is also the window in which the AUTHOR
    /// can notice a commit and cure the violation, costing an honest challenger their stake.
    uint256 public constant COMMIT_DELAY = 1;
    /// @dev Commitments expire so stale ones cannot be hoarded indefinitely.
    uint256 public constant REVEAL_WINDOW = 256;

    struct Bond {
        address hook;
        address author;
        /// @dev Total still at stake, summed over live tranches.
        uint96 amount;
        uint64 unbondingAt; // 0 = no exit requested
        /// @dev Has EVER been slashed. A permanent public record; it does not kill the bond, because
        /// the assertions that still hold are still backed.
        bool everSlashed;
    }

    mapping(bytes32 bondId => Bond) public bonds;
    mapping(bytes32 bondId => address[]) internal _predicates;
    /// @dev Parallel to `_predicates`. Zero means that assertion has been slashed and settled.
    mapping(bytes32 bondId => uint96[]) internal _stakes;
    /// @dev Slashed principal and forfeited stakes. Deliberately has no withdrawal path in v1:
    /// value must leave the author's reach for slashing to cost anything. A victim-claim path is
    /// out of scope and is not claimed to exist.
    mapping(address hook => uint256) public forfeited;
    /// @dev commitment => block it was made in. The commitment binds the challenger's address, so a
    /// revealed (bondId, index, salt) is useless to anyone else.
    mapping(bytes32 commitment => uint256 blockNumber) public commits;
    /// @dev Every bondId ever opened on a hook, so a registry can total the capital standing behind
    /// it without an archive node. Entries are NOT removed on withdraw or slash: `bonds[id]` is the
    /// authority on whether one is live, and rewriting history to look tidy would let a hook shed
    /// the record of a slashing.
    mapping(address hook => bytes32[]) internal _bondsOfHook;
    /// @dev `bondId` is deterministic in (hook, author), so an author who bonds, withdraws and
    /// re-bonds would otherwise append the same id again and again. Left unchecked that is a cheap
    /// unbounded-growth attack on anything that iterates the list: withdrawal returns the principal,
    /// so the only cost is gas. Index each id once.
    mapping(bytes32 bondId => bool) internal _indexed;

    error BondExists();
    error NoBond();
    error NotAuthor();
    error BondTooSmall();
    error TooManyPredicates();
    error NoPredicates();
    error PredicateDoesNotHold(address predicate, Verdict verdict);
    error TrancheAlreadySlashed();
    error StakeMismatch();
    error TrancheTooSmall();
    error LengthMismatch();
    error ExitNotRequested();
    error ExitNotMatured();
    error SpecViolated(address predicate);
    error SpecInconclusive(address predicate);
    error BadStake();
    error BondEmpty();
    error CommitExists();
    error NoCommit();
    error CommitTooYoung();
    error CommitExpired();
    error IndexOutOfRange();
    error TransferFailed();

    event Bonded(bytes32 indexed bondId, address indexed hook, address indexed author, uint256 amount);
    event PredicateAdded(bytes32 indexed bondId, address predicate, uint256 stake);
    event ToppedUp(bytes32 indexed bondId, uint256 index, uint256 amount, uint256 newTotal);
    event ExitRequested(bytes32 indexed bondId, uint64 maturesAt);
    event Withdrawn(bytes32 indexed bondId, uint256 amount);
    event Slashed(
        bytes32 indexed bondId, address indexed challenger, address predicate, uint256 bounty, uint256 forfeitedAmount
    );
    event ChallengeFailed(bytes32 indexed bondId, address indexed challenger, address predicate, Verdict verdict);
    event ChallengeCommitted(bytes32 indexed commitment, uint256 blockNumber);

    function bondIdOf(address hook, address author) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(hook, author));
    }

    /// @notice Binding for a challenge commitment. Includes `challenger` so that revealing the
    /// (bondId, index, salt) triple in a public transaction hands nothing to an observer.
    function challengeCommitment(bytes32 bondId, uint256 index, bytes32 salt, address challenger)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(bondId, index, salt, challenger));
    }

    /// @notice Stake nothing, reveal nothing. Step one of a challenge.
    function commitChallenge(bytes32 commitment) external {
        if (commits[commitment] != 0) revert CommitExists();
        commits[commitment] = block.number;
        emit ChallengeCommitted(commitment, block.number);
    }

    function bondsOfHook(address hook) external view returns (bytes32[] memory) {
        return _bondsOfHook[hook];
    }

    function predicatesOf(bytes32 bondId) external view returns (address[] memory) {
        return _predicates[bondId];
    }

    /// @notice Capital standing behind each assertion, in the same order. Zero means slashed.
    function stakesOf(bytes32 bondId) external view returns (uint96[] memory) {
        return _stakes[bondId];
    }

    /// @notice Post a bond on `hook` backing `predicates`. Every predicate must HOLD right now:
    /// an author cannot bond a spec that is already broken, nor one that is un-evaluable.
    /// @dev Permissionless and keyed by (hook, author), so nobody can squat a hook with dust.
    function bond(address hook, address[] calldata predicates, uint96[] calldata stakes)
        external
        payable
        nonReentrant
        returns (bytes32 bondId)
    {
        if (msg.value < MIN_BOND) revert BondTooSmall();
        if (predicates.length == 0) revert NoPredicates();
        if (predicates.length > MAX_PREDICATES) revert TooManyPredicates();
        if (predicates.length != stakes.length) revert LengthMismatch();

        bondId = bondIdOf(hook, msg.sender);
        if (bonds[bondId].author != address(0)) revert BondExists();

        uint256 total;
        for (uint256 i = 0; i < predicates.length; ++i) {
            if (stakes[i] < MIN_TRANCHE) revert TrancheTooSmall();
            Verdict v = PredicateSandbox.evaluate(predicates[i], hook);
            if (v != Verdict.HOLDS) revert PredicateDoesNotHold(predicates[i], v);
            _predicates[bondId].push(predicates[i]);
            _stakes[bondId].push(stakes[i]);
            total += stakes[i];
        }
        if (total != msg.value) revert StakeMismatch();

        bonds[bondId] =
            Bond({hook: hook, author: msg.sender, amount: uint96(msg.value), unbondingAt: 0, everSlashed: false});
        if (!_indexed[bondId]) {
            _indexed[bondId] = true;
            _bondsOfHook[hook].push(bondId);
        }
        emit Bonded(bondId, hook, msg.sender, msg.value);
    }

    /// @notice Strengthen a spec. There is no counterpart that weakens one.
    function addPredicate(bytes32 bondId, address predicate) external payable nonReentrant {
        Bond storage b = _liveBond(bondId);
        if (msg.sender != b.author) revert NotAuthor();
        if (_predicates[bondId].length >= MAX_PREDICATES) revert TooManyPredicates();
        if (msg.value < MIN_TRANCHE) revert TrancheTooSmall();

        Verdict v = PredicateSandbox.evaluate(predicate, b.hook);
        if (v != Verdict.HOLDS) revert PredicateDoesNotHold(predicate, v);

        _predicates[bondId].push(predicate);
        _stakes[bondId].push(uint96(msg.value));
        b.amount += uint96(msg.value);
        b.unbondingAt = 0;
        emit PredicateAdded(bondId, predicate, msg.value);
    }

    /// @dev Author-only, and it RESTARTS the exit clock. Otherwise the unbonding delay applies
    /// only to the first deposit: bond dust, let the exit mature, then top up and withdraw in the
    /// same block. Author-only because a third party must not be able to reset someone's clock.
    function topUp(bytes32 bondId, uint256 index) external payable nonReentrant {
        Bond storage b = _liveBond(bondId);
        if (msg.sender != b.author) revert NotAuthor();
        uint96[] storage st = _stakes[bondId];
        if (index >= st.length) revert IndexOutOfRange();
        if (st[index] == 0) revert TrancheAlreadySlashed();
        st[index] += uint96(msg.value);
        b.amount += uint96(msg.value);
        b.unbondingAt = 0;
        emit ToppedUp(bondId, index, msg.value, b.amount);
    }

    function requestExit(bytes32 bondId) external nonReentrant {
        Bond storage b = _liveBond(bondId);
        if (msg.sender != b.author) revert NotAuthor();
        b.unbondingAt = uint64(block.timestamp) + UNBONDING_DELAY;
        emit ExitRequested(bondId, b.unbondingAt);
    }

    /// @notice Take the bond back. Requires a matured exit request AND that the whole spec still
    /// holds. A VIOLATED predicate blocks withdrawal forever; an INCONCLUSIVE one blocks it until
    /// ESCAPE_DELAY has additionally elapsed.
    function withdraw(bytes32 bondId) external nonReentrant {
        Bond storage b = _liveBond(bondId);
        if (msg.sender != b.author) revert NotAuthor();
        if (b.unbondingAt == 0) revert ExitNotRequested();
        if (block.timestamp < b.unbondingAt) revert ExitNotMatured();

        bool escapeOpen = block.timestamp >= uint256(b.unbondingAt) + ESCAPE_DELAY;
        address[] storage ps = _predicates[bondId];
        uint96[] storage st = _stakes[bondId];
        for (uint256 i = 0; i < ps.length; ++i) {
            // A slashed tranche no longer constrains the exit. That claim has already been settled
            // and paid out; leaving it in force would block the author's OTHER tranches forever
            // over a failure that has already cost them the stake behind it -- punishing twice for
            // one breach, and giving an author who broke one assertion no reason to keep honouring
            // the rest.
            if (st[i] == 0) continue;
            Verdict v = PredicateSandbox.evaluate(ps[i], b.hook);
            if (v == Verdict.VIOLATED) revert SpecViolated(ps[i]);
            if (v == Verdict.INCONCLUSIVE && !escapeOpen) revert SpecInconclusive(ps[i]);
        }

        uint256 amount = b.amount;
        address to = b.author;
        delete bonds[bondId];
        delete _predicates[bondId];
        delete _stakes[bondId];
        emit Withdrawn(bondId, amount);
        _send(to, amount);
    }

    /// @notice Prove one assertion false and take a bounty out of the capital staked on THAT
    /// assertion. The bond's other tranches are untouched. Requires CHALLENGER_STAKE, forfeited only
    /// if the predicate provably HOLDS. An un-evaluable predicate refunds the stake and is recorded
    /// publicly — a hook whose spec cannot be evaluated is not a hook with a passing spec.
    function challenge(bytes32 bondId, uint256 index, bytes32 salt) external payable nonReentrant {
        if (msg.value != CHALLENGER_STAKE) revert BadStake();

        bytes32 commitment = challengeCommitment(bondId, index, salt, msg.sender);
        uint256 committedAt = commits[commitment];
        if (committedAt == 0) revert NoCommit();
        if (block.number < committedAt + COMMIT_DELAY) revert CommitTooYoung();
        if (block.number > committedAt + REVEAL_WINDOW) revert CommitExpired();
        delete commits[commitment];

        Bond storage b = _liveBond(bondId);
        address[] storage ps = _predicates[bondId];
        if (index >= ps.length) revert IndexOutOfRange();
        address predicate = ps[index];

        Verdict v = PredicateSandbox.evaluate(predicate, b.hook);

        if (v == Verdict.HOLDS) {
            forfeited[b.hook] += msg.value; // stake is burned to the pot, never paid to the author
            emit ChallengeFailed(bondId, msg.sender, predicate, v);
            return;
        }
        if (v == Verdict.INCONCLUSIVE) {
            emit ChallengeFailed(bondId, msg.sender, predicate, v);
            _send(msg.sender, msg.value); // no false claim was made; only gas is lost
            return;
        }

        uint96[] storage st = _stakes[bondId];
        uint256 tranche = st[index];
        if (tranche == 0) revert TrancheAlreadySlashed();

        uint256 bounty = (tranche * BOUNTY_BPS) / BPS_DENOMINATOR;
        uint256 burned = tranche - bounty;

        // Only this assertion's backing is taken. The others still hold and remain backed.
        st[index] = 0;
        b.amount -= uint96(tranche);
        b.everSlashed = true;
        forfeited[b.hook] += burned;

        emit Slashed(bondId, msg.sender, predicate, bounty, burned);
        _send(msg.sender, bounty + msg.value); // bounty plus the challenger's own stake back
    }

    function _liveBond(bytes32 bondId) private view returns (Bond storage b) {
        b = bonds[bondId];
        if (b.author == address(0)) revert NoBond();
        // `everSlashed` deliberately does NOT gate anything: a bond with one assertion slashed and
        // three still backed is a live bond. Only an empty one is dead.
        if (b.amount == 0) revert BondEmpty();
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
