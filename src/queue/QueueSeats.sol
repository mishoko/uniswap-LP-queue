// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

/// @title QueueSeats — the rank token
///
/// @notice One ERC-6909 id per seat, supply exactly one. Rank is an ORDERING, and an ordering is
///         not divisible: a fungible rank token would have to mean something like "priority
///         points", which needs a sorted structure and re-opens problems this design closes.
///
/// @dev **THERE IS ONE SOURCE OF TRUTH FOR OWNERSHIP AND IT IS `seatHolder`.**
///
///      The obvious implementation inherits v4-core's `ERC6909`, whose ownership lives in
///      `mapping(address => mapping(uint256 => uint256)) balanceOf`, and then keeps a
///      `seatHolder`-style mirror alongside it so the product can answer "who owns seat 3?".
///      That is two writers for one fact, and a writer/reader mismatch between them is a theft:
///      the transfer path would move one and the withdrawal path would authorise against the
///      other. This project has already shipped two paired-branch asymmetries (PITFALLS 5.37,
///      5.50); it does not need a third with funds on it.
///
///      So the direction is inverted. `seatHolder` is the storage, and the whole ERC-6909 surface
///      is a VIEW over it — `balanceOf(owner, id)` is a comparison, not a slot. Two consequences,
///      both load-bearing:
///
///        * **Total supply of every id is exactly one BY CONSTRUCTION.** There is no storage that
///          can represent two, or zero-after-mint. Exit criterion 3.1 stops being a property that
///          tests have to chase across every operation and becomes a property of the type.
///        * A mint is the only way an id comes into existence, and this contract exposes no
///          public one. The roster is created by the inheriting contract, once.
///
///      The interface is `IERC6909Claims` from v4-core rather than a hand-copied signature list,
///      so every selector and event topic is checked by the compiler against the canonical
///      definition. Hand-rolling a token standard is a real risk; hand-rolling one against the
///      canonical interface is a much smaller one.
abstract contract QueueSeats is IERC6909Claims {
    /// @notice The roster is BOUNDED, on purpose (PLAN §B.9).
    ///
    /// @dev A sweeping swap is O(seats touched) at ~6,753 gas each, so a 300k hook-callback budget
    ///      buys ~44 seats and a thousand retail LPs could not be swept at all. 32 is round, sits
    ///      comfortably inside that budget with headroom for the deposit/withdraw path, and is deep
    ///      enough that the queue is interesting.
    ///
    ///      Scarcity is not an unfortunate consequence of the gas table — it is the mechanism. An
    ///      unbounded roster makes rank free, and a seat that is free to occupy has no price.
    uint256 public constant MAX_SEATS = 32;

    /// @dev id => holder. `address(0)` means the id has never been minted. THE SOURCE OF TRUTH.
    mapping(uint256 seatId => address holder) internal seatHolder;

    mapping(address owner => mapping(address operator => bool approved)) public isOperator;

    mapping(address owner => mapping(address spender => mapping(uint256 seatId => uint256 amount))) public allowance;

    /// @dev Transient reentrancy flag. Every externally callable path that touches the ledger takes
    ///      it. See `nonReentrant` for the concrete attack it closes.
    bool private transient entered;

    error NotSeatOwner(uint256 seatId, address caller);
    error InsufficientPermission(uint256 seatId, address spender);
    /// @dev A seat is indivisible: the only meaningful transfer amount is 1. A zero-amount transfer
    ///      is not silently accepted, because on this contract a transfer has a SIDE EFFECT — it
    ///      evacuates the seat — and an integrator that believes it moved nothing would be wrong.
    error SeatIsIndivisible(uint256 seatId, uint256 amount);
    /// @dev Sending a seat to `address(0)` would burn it: supply 0, no holder, and no path to ever
    ///      appoint one — a rank slot occupied forever by nobody, in a roster whose entire value is
    ///      that it is scarce. There is no admin to repair it, so it is refused.
    error SeatCannotBeBurned(uint256 seatId);
    error Reentrancy();

    /// @dev WHAT THIS IS HOLDING, stated as what was measured rather than as a slogan.
    ///
    ///      **The window is real and reachable.** Topping the float up from the position means
    ///      `poolManager.modifyLiquidity` -> `take` -> `IERC20.transfer(hook, amount)`, which hands
    ///      control to one of the pool's own currencies in the middle of an unlock. PoolManager's
    ///      own lock does NOT close it: it stops any reentrant path that needs a second `unlock`,
    ///      but a withdrawal on the leg the float ALREADY covers needs none, and executes in full.
    ///      Executed in `test_3_12_negativeControl_reentrantEvacuationCorruptsTheUnlockMeasurement`.
    ///
    ///      **What it protects is `unlockCallback`'s measurement.** That function reads how much
    ///      actually moved by differencing the hook's own ERC-20 balances across the unlock — which
    ///      it must, because a fee-on-transfer currency delivers less than `callerDelta` says. The
    ///      measurement is therefore only meaningful if NOTHING ELSE moves those balances inside
    ///      the window, and this modifier is the only thing that makes that true. Without it, the
    ///      reentrant payout above lands, the difference is read against a balance that moved for
    ///      an unrelated reason, and `float0`/`float1` are credited a number that is not what the
    ///      position released. In the executed control it happens to underflow and revert; that is
    ///      an accident of direction, not a defence — the same corruption in the other direction is
    ///      silent, and it is the float, i.e. every other seat's money, that absorbs it.
    ///
    ///      **What is NOT claimed:** no path that EXTRACTS value without this guard was found. The
    ///      demonstrated consequence is a corrupted measurement, not a proven theft. It stays
    ///      because a correctness argument that rests on an accidental underflow inside a balance
    ///      difference is not a correctness argument, and Phase 4 adds more externally callable
    ///      ledger paths into the same window.
    modifier nonReentrant() {
        _enter();
        _;
        _exit();
    }

    function _enter() private {
        if (entered) revert Reentrancy();
        entered = true;
    }

    function _exit() private {
        entered = false;
    }

    // ------------------------------------------------------------------------------ ERC-6909 views

    /// @inheritdoc IERC6909Claims
    function balanceOf(address owner, uint256 seatId) public view returns (uint256) {
        return (owner != address(0) && seatHolder[seatId] == owner) ? 1 : 0;
    }

    /// @notice Who holds this seat. `address(0)` for an id that was never minted.
    function ownerOf(uint256 seatId) public view returns (address) {
        return seatHolder[seatId];
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x0f632fb3; // ERC-6909
    }

    // ------------------------------------------------------------------------------ ERC-6909 logic

    /// @inheritdoc IERC6909Claims
    /// @dev `virtual` for ONE reason: the mandatory negative controls in `test/queue/Rank.t.sol`
    ///      subclass this and change exactly one thing each — the forgotten `transferFrom`
    ///      evacuation, and the missing reentrancy guard. Nothing in production overrides either.
    function transfer(address receiver, uint256 seatId, uint256 amount) public virtual nonReentrant returns (bool) {
        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);
        _moveSeat(msg.sender, msg.sender, receiver, seatId, amount);
        return true;
    }

    /// @inheritdoc IERC6909Claims
    function transferFrom(address sender, address receiver, uint256 seatId, uint256 amount)
        public
        virtual
        nonReentrant
        returns (bool)
    {
        if (seatHolder[seatId] != sender) revert NotSeatOwner(seatId, sender);
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][seatId];
            if (allowed < amount) revert InsufficientPermission(seatId, msg.sender);
            if (allowed != type(uint256).max) allowance[sender][msg.sender][seatId] = allowed - amount;
        }
        _moveSeat(msg.sender, sender, receiver, seatId, amount);
        return true;
    }

    /// @inheritdoc IERC6909Claims
    function approve(address spender, uint256 seatId, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender][seatId] = amount;
        emit Approval(msg.sender, spender, seatId, amount);
        return true;
    }

    /// @inheritdoc IERC6909Claims
    function setOperator(address operator, bool approved) public returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @dev THE SINGLE FUNNEL. `transfer` and `transferFrom` differ ONLY in how they authorise;
    ///      everything that HAPPENS to a seat happens here, once.
    ///
    ///      PLAN §B.8 records the canonical form of this bug: `transfer` is overridden to evacuate
    ///      and `transferFrom` is forgotten, because the happy-path test only ever calls
    ///      `transfer`. The answer is not to override two functions carefully — it is for there to
    ///      be one place where a seat can change hands.
    ///
    ///      It is `internal` rather than `private` so the negative controls can build the broken
    ///      variants, which means the funnel is a convention inside this file rather than a
    ///      guarantee against a future subclass. What holds it is that nothing in production
    ///      overrides `transfer` or `transferFrom`, and that both mandatory controls in
    ///      `test/queue/Rank.t.sol` go red — the forgotten override, and the missing guard. Say the
    ///      weaker true thing rather than the stronger false one.
    function _moveSeat(address caller, address from, address to, uint256 seatId, uint256 amount) internal {
        if (amount != 1) revert SeatIsIndivisible(seatId, amount);
        if (to == address(0)) revert SeatCannotBeBurned(seatId);

        // Evacuate BEFORE the holder changes: the capital belongs to whoever held the seat up to
        // this instant, and `_onSeatTransfer` pays it to exactly that address.
        _onSeatTransfer(seatId, from);

        seatHolder[seatId] = to;
        emit Transfer(caller, from, to, seatId, 1);
    }

    /// @dev Create seat `seatId` and appoint `to`. The inheriting contract owns the roster and is
    ///      responsible for `seatId` being the next unused id and for the `MAX_SEATS` bound; this
    ///      contract holds no second copy of the seat count to disagree with it.
    function _mintSeat(address to, uint256 seatId) internal {
        seatHolder[seatId] = to;
        emit Transfer(msg.sender, address(0), to, seatId, 1);
    }

    /// @notice Called on every change of holder, before the holder changes.
    /// @dev Rank moves; capital does not. The implementation returns the seat's capital to `from`
    ///      and leaves the seat empty for its new holder.
    function _onSeatTransfer(uint256 seatId, address from) internal virtual;
}
