// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueSeats} from "../../src/queue/QueueSeats.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice THE ATTACK, IN ONE EXTERNAL CALL, so "single transaction" is executed rather than argued.
///
/// @dev `withdraw`, the swap and `addToSeat` are three separate top-level calls into the hook, so
///      the `nonReentrant` guard never sees them nested and does not bind. Nothing else in the
///      contract does: `withdraw` takes no lock beyond the transaction, does not touch the order
///      word, and imposes no cooldown — the comment on `addToSeat` says a per-block cooldown is
///      deliberately excluded because PLAN §B.12 counts a one-block wait as a PROVEN evasion.
contract Evacuator {
    QueueHarness immutable h;
    IUniswapV4Router04 immutable router;
    MockERC20 immutable t0;
    MockERC20 immutable t1;
    PoolKey key;

    constructor(QueueHarness h_, IUniswapV4Router04 r, MockERC20 a, MockERC20 b, PoolKey memory key_) {
        (h, router, t0, t1) = (h_, r, a, b);
        key = key_;
    }

    function approveAll(address permit2) external {
        t0.approve(address(h), type(uint256).max);
        t1.approve(address(h), type(uint256).max);
        t0.approve(permit2, type(uint256).max);
        t1.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(t0), address(router), type(uint160).max, type(uint48).max);
        IAllowanceTransfer(permit2).approve(address(t1), address(router), type(uint160).max, type(uint48).max);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
    }

    /// @notice evacuate -> trade against the seats behind -> retake the seat. One transaction.
    function strike(uint256 seatId, uint256 amountIn) external {
        (uint256 a0, uint256 a1) = h.seat(seatId);
        h.withdraw(seatId, a0, a1);
        router.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
        h.addToSeat(seatId, a0, a1);
    }
}

/// @title THE EVACUATION ATTACK — is subordination ENFORCED, or merely described?
///
/// @notice QUEUE sells one thing: RANK. The front seat is filled first, so it eats the adverse
///         selection first, and the seats behind it are "subordinated" — protected from small
///         moves by the inventory standing in front of them. That is the product.
///
///         `withdraw()` is INSTANT. No lock, no cooldown, no rank penalty, and `withdraw` does not
///         touch the order word — so a seat that empties itself keeps its rank and can be refilled
///         in the same transaction. The claim under test:
///
///             withdraw(head) → adverse swap → addToSeat(head)
///
///         hands the toxic fill to the seats BEHIND the head while the head keeps its place in
///         line. If that is profitable net of its cost, the subordination is a description of what
///         usually happens, not a rule the contract enforces.
///
/// @dev **THE EXPERIMENT.** Two live pools, identical in every respect — same φ, same roster
///      shape, same per-seat capital, same start price — differing only in whether the head
///      evacuates around the adverse swap. `Premium.t.sol` established this shape; it is the only
///      construction under which "the evacuation moved this much money" is a claim rather than an
///      assertion about a number nobody can place.
///
///      **THE ADVERSE SWAP IS SIZED TO A TARGET PRICE, NOT TO A FIXED INPUT, AND THAT IS
///      LOAD-BEARING.** An evacuation BURNS the head's share of the position, so the attack pool is
///      thinner while the swap runs. A fixed input would therefore push the two pools to two
///      different final prices, and the two scenarios would be marked to two different numeraires —
///      the comparison would be meaningless. An informed trader does not trade a fixed size; they
///      trade until the pool quotes the price they believe, which is the standard LVR formulation.
///      So each pool's input is computed from ITS OWN live liquidity to reach the SAME target
///      sqrt price, and both scenarios are then valued at that one common price. `test_8_0`
///      asserts the two pools really did land on it.
///
///      **LAW 1** — 18/6 decimals, 1:4 start price. **LAW 3** — every flow is measured on
///      PoolManager's own ERC20 balances net of `protocolFeesAccrued`, and INVARIANT F is asserted
///      against the live position at the end of every episode; nothing here trusts the hook's own
///      bookkeeping for a conservation claim. **LAW 4** — the gas numbers below are RAW `gasleft()`
///      deltas inside a test body. They are NOT LAW 4 measurements (state built in the test body is
///      dirty and cheap to rewrite) and they are labelled as such everywhere they appear. They are
///      a lower bound, which is the conservative direction for an attack-cost argument.
contract EvacuationTest is QueueFixture {
    using StateLibrary for IPoolManager;

    uint256 constant N = 8;
    uint256 constant PHI = 8_500; // the shipping φ — QueueDeployBase.PREMIUM_BPS

    /// @dev Per-seat capital, in the band's own ratio (start price is 1:4 raw), so the deposit is
    ///      not lopsidedly float.
    uint256 constant SEAT0 = 500e18;
    uint256 constant SEAT1 = 125e18;

    /// @dev How far the informed trader moves the pool. 600 ticks (~5.8%) inside a ±960 band.
    int24 constant ADVERSE_TICKS = 600;

    QueueHarness ctlHook;
    PoolKey ctlKey;
    address[] ctlRoster;

    QueueHarness atkHook;
    PoolKey atkKey;
    address[] atkRoster;

    struct Result {
        uint256 amountIn; // what the informed trader spent
        uint256 amountOut; // what the informed trader received
        uint160 finalSqrt; // where the pool ended
        uint256 headGave1; // token1 the HEAD seat gave up over the episode
        uint256 backGave1; // token1 ranks 1..N-1 gave up over the episode
        uint256 head0;
        uint256 head1; // head holder's END holdings (wallet + seat + pending)
        uint256 back0;
        uint256 back1; // ranks 1..N-1 END ledger
        uint256 headStart0;
        uint256 headStart1;
        uint256 backStart0;
        uint256 backStart1;
        uint256 gasRoundTrip; // NOT a LAW 4 measurement — raw gasleft() delta
        uint256 dustLost; // face value asked minus tokens actually received, token0+token1 face
        uint256 endRank; // where the head holder is standing when it is all over
    }

    function setUp() public {
        deployArtifactsAndLabel();
        vm.roll(100);
        vm.warp(1_700_000_000);
        dec0 = 18;
        dec1 = 6; // LAW 1 — unequal decimals
        startPrice = Constants.SQRT_PRICE_1_4; // LAW 1 — never 1:1
        _deployTokens();

        ctlRoster = _rosterAt(0xC0FFEE00);
        atkRoster = _rosterAt(0xA77AC000);

        (ctlHook, ctlKey) = _build(0xE100, ctlRoster, PHI);
        (atkHook, atkKey) = _build(0xE200, atkRoster, PHI);
    }

    function _rosterAt(uint160 base) internal pure returns (address[] memory r) {
        r = new address[](N);
        for (uint256 i; i < N; i++) {
            r[i] = address(base + uint160(i));
        }
    }

    /// @dev Built through the PRODUCTION deposit path (`addToSeat`), on an UNFUNDED hook, so the
    ///      hook holds nothing it was not given and INVARIANT R/F mean something. `seed()` would
    ///      hand the roster capital out of the hook's own pocket, which is a different contract.
    function _build(uint160 nonce, address[] memory roster, uint256 phi)
        internal
        returns (QueueHarness h, PoolKey memory key_)
    {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgsPremium(roster, phi), a);
        hook = QueueHarness(a);

        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, startPrice);

        for (uint256 i; i < N; i++) {
            _give(roster[i], SEAT0, SEAT1);
            vm.prank(roster[i]);
            QueueHarness(a).addToSeat(i, SEAT0, SEAT1);
        }
        // Push the unconsumed leg back into the position so the pool's depth reflects the capital
        // that was actually committed. Permissionless, credits nobody — see `sweepFloatIntoPosition`.
        QueueHarness(a).sweepFloatIntoPosition();
        // Age past MIN_TENURE, exactly as `QueueFixture._seedAt` does — this suite builds its own
        // rosters and would otherwise be testing evacuation against seats still inside their term.
        // `test_8_21` is the one that deliberately stays inside it.
        _ageRoster();
        return (QueueHarness(a), k);
    }

    function _give(address who, uint256 a0, uint256 a1) internal {
        if (a0 != 0) MockERC20(Currency.unwrap(c0)).mint(who, a0);
        if (a1 != 0) MockERC20(Currency.unwrap(c1)).mint(who, a1);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _use(QueueHarness h, PoolKey memory key_) internal {
        hook = h;
        k = key_;
    }

    // ───────────────────────────────────────────────────────────────────────────── the episode

    /// @dev One adverse move against one pool. `evacuate` is the ONLY difference between the two
    ///      runs. The informed trader is `address(this)` — a third party, not the head holder: the
    ///      attack does not require being the informed trader, only seeing the trade.
    function _episode(QueueHarness h, PoolKey memory key_, address[] memory roster, bool evacuate, uint160 target)
        internal
        returns (Result memory r)
    {
        _use(h, key_);
        address head = roster[0];

        (r.headStart0, r.headStart1) = _holdings(head, 0);
        (r.backStart0, r.backStart1) = _backLedger();

        uint256 g0;
        uint256 g1;
        if (evacuate) {
            (uint256 a0, uint256 a1) = h.seat(0);
            uint256 before = gasleft();
            vm.prank(head);
            (uint256 p0, uint256 p1) = h.withdraw(0, a0, a1);
            g0 = before - gasleft();
            r.dustLost = (a0 - p0) + (a1 - p1);
            assertGt(p0 + p1, 0, "nothing happened: the evacuation paid out nothing");
        }

        // The informed trader sizes the trade against THIS pool's live depth to reach the common
        // target price. Exact-input, so the size is the input that walks sqrtP to `target` plus the
        // LP fee that sits in front of it.
        r.amountIn = _inputToReach(target);
        (, r.amountOut) = _advSwap(address(this), true, r.amountIn);

        if (evacuate) {
            uint256 w0 = MockERC20(Currency.unwrap(c0)).balanceOf(head);
            uint256 w1 = MockERC20(Currency.unwrap(c1)).balanceOf(head);
            uint256 before = gasleft();
            vm.prank(head);
            h.addToSeat(0, w0, w1);
            g1 = before - gasleft();
        }
        r.gasRoundTrip = g0 + g1;

        (r.finalSqrt,,,) = poolManager.getSlot0(key_.toId());
        r.endRank = h.rankOfId(0);
        (r.head0, r.head1) = _holdings(head, 0);
        (r.back0, r.back1) = _backLedger();

        r.headGave1 = r.headStart1 > r.head1 ? r.headStart1 - r.head1 : 0;
        r.backGave1 = r.backStart1 > r.back1 ? r.backStart1 - r.back1 : 0;

        // Conservation, on the live position rather than on the hook's own arithmetic (LAW 3).
        _checkInvariantF("evacuation episode", 64);
        _checkInvariantR("evacuation episode");
        _checkInvariantL("evacuation episode");
    }

    /// @dev Everything a seat holder owns: wallet + seat ledger (`seat()` includes accrued premium)
    ///      + anything an evacuation could not pay on the spot.
    function _holdings(address who, uint256 seatId) internal view returns (uint256 a0, uint256 a1) {
        (uint256 s0, uint256 s1) = hook.seat(seatId);
        (uint256 d0, uint256 d1) = hook.pendingOf(who);
        a0 = s0 + d0 + MockERC20(Currency.unwrap(c0)).balanceOf(who);
        a1 = s1 + d1 + MockERC20(Currency.unwrap(c1)).balanceOf(who);
    }

    /// @dev Every seat EXCEPT the attacker's, by SEAT ID.
    ///
    ///      It was written as "ranks 1..N-1" and that was wrong the moment `withdraw` began to
    ///      demote: the attacker's own seat then sits at a back RANK, so it was counted both here
    ///      and in `_holdings(head, 0)`, and the same tokens appeared on both sides of the ledger.
    ///      The mirror check caught it — trader gain 1.39e19 against a queue loss of 7.53e18 — which
    ///      is precisely the job it was put there to do. The set this function means is "the seats
    ///      the attacker is standing in front of, or was", and that set is defined by identity, not
    ///      by position.
    function _backLedger() internal view returns (uint256 a0, uint256 a1) {
        for (uint256 id = 1; id < N; id++) {
            (uint256 x0, uint256 x1) = hook.seat(id);
            a0 += x0;
            a1 += x1;
        }
    }

    /// @dev The exact-input size that walks this pool's spot price to `target`, gross of the LP fee.
    ///      Read from PoolManager's own liquidity, not from the hook's view of its position.
    function _inputToReach(uint160 target) internal view returns (uint256) {
        (uint160 sp,,,) = poolManager.getSlot0(k.toId());
        uint128 L = poolManager.getLiquidity(k.toId());
        require(L != 0, "no depth");
        require(target < sp, "target must be below spot for a zeroForOne move");
        uint256 net = SqrtPriceMath.getAmount0Delta(target, sp, L, true);
        return FullMath.mulDiv(net, 1e6, 1e6 - FEE);
    }

    /// @dev LAW 3: flows measured on PoolManager's own ERC20 balances, net of the protocol fee this
    ///      swap accrued. Deliberately NOT `_swapFrom` — that one drives the fixture's single-pool
    ///      witness, and this suite holds two pools open at once.
    function _advSwap(address who, bool zeroForOne, uint256 amountIn) internal returns (uint256 inAmt, uint256 out) {
        uint256 p0 = _pmBal(c0);
        uint256 p1 = _pmBal(c1);
        uint256 pf0 = poolManager.protocolFeesAccrued(c0);
        uint256 pf1 = poolManager.protocolFeesAccrued(c1);
        vm.prank(who);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: who,
            deadline: block.timestamp
        });
        uint256 pf = zeroForOne ? poolManager.protocolFeesAccrued(c0) - pf0 : poolManager.protocolFeesAccrued(c1) - pf1;
        if (zeroForOne) {
            (inAmt, out) = (_pmBal(c0) - p0 - pf, p1 - _pmBal(c1));
        } else {
            (inAmt, out) = (_pmBal(c1) - p1 - pf, p0 - _pmBal(c0));
        }
    }

    /// @dev Value a (token0, token1) bundle in raw token1 units at one common price. Both scenarios
    ///      are valued at the SAME sqrt price — the informed trader's price — which is the whole
    ///      reason the swap is sized to a target rather than to a fixed input.
    function _value1(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        uint256 x = FullMath.mulDiv(a0, sp, 1 << 96);
        return a1 + FullMath.mulDiv(x, sp, 1 << 96);
    }

    function _target() internal view returns (uint160) {
        int24 t = TickMath.getTickAtSqrtPrice(startPrice);
        return TickMath.getSqrtPriceAtTick(t - ADVERSE_TICKS);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.0 — the two pools really are the same pool until the evacuation
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_8_0_thePoolsAreIdenticalBeforeTheAttack() public view {
        (uint160 sA,,,) = poolManager.getSlot0(ctlKey.toId());
        (uint160 sB,,,) = poolManager.getSlot0(atkKey.toId());
        assertEq(sA, sB, "the two pools do not start at the same price");
        assertEq(
            poolManager.getLiquidity(ctlKey.toId()),
            poolManager.getLiquidity(atkKey.toId()),
            "the two pools do not start at the same depth"
        );
        for (uint256 i; i < N; i++) {
            (uint256 a0, uint256 a1) = ctlHook.seat(i);
            (uint256 b0, uint256 b1) = atkHook.seat(i);
            assertEq(a0, b0, "seat a0 differs between the pools");
            assertEq(a1, b1, "seat a1 differs between the pools");
        }
    }

    /// @dev THE VALUATION FUNCTION IS AN INSTRUMENT, SO IT IS TESTED LIKE ONE. `SQRT_PRICE_1_4`
    ///      means one raw token0 is worth a quarter of a raw token1 — a fact about v4's own
    ///      constant, not about the formula below it. If `_value1` squared the wrong thing, or
    ///      squared nothing, this is what says so. PITFALLS 5.75/5.79: a broken instrument that
    ///      looks like a broken mechanism has cost this project more time than any real bug.
    function test_8_0c_theValuationInstrumentIsCalibrated() public view {
        assertApproxEqAbs(_value1(4e18, 0, startPrice), 1e18, 1e6, "_value1 misprices the 1:4 anchor");
        assertEq(_value1(0, 7e18, startPrice), 7e18, "_value1 must be the identity on token1");
        // ...and it must be strictly monotone in the price, or "marked at the same price" is empty.
        assertLt(_value1(1e18, 0, _target()), _value1(1e18, 0, startPrice), "_value1 is not falling with the price");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.1 — THE ATTACK
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_8_1_evacuationHandsTheAdverseFillToTheBackOfTheBook() public {
        uint160 target = _target();

        Result memory ctl = _episode(ctlHook, ctlKey, ctlRoster, false, target);
        Result memory atk = _episode(atkHook, atkKey, atkRoster, true, target);

        _reportPrices(ctl, atk, target);
        _reportFills(ctl, atk);

        // **THE INSTRUMENT IS CHECKED BEFORE ITS OUTPUT IS BELIEVED — AND HERE IS EXACTLY WHAT
        // THE CHECK DOES AND DOES NOT COVER.** The informed trader's P&L is computed from
        // PoolManager's OWN ERC20 balances; the queue's is computed from the seat ledger. They are
        // two independent measurements of one closed system, so at a common price they must be
        // exact mirrors. That pins the ACCOUNTING: no token leaked, nothing was double-counted,
        // and `_holdings` is not missing a pot.
        //
        // It is BLIND to the price itself, and saying otherwise would be the overclaim this
        // project keeps paying for. Any valuation linear in `a0` conserves this identity, because
        // both tokens are conserved separately — so a `_value1` that applied the price once
        // instead of squaring it passes this check unchanged. It was executed: the mirror stayed
        // green and only the VERDICT went red. The exponent is pinned by `test_8_0c` instead.
        _checkMirror(ctl, target, "control");
        _checkMirror(atk, target, "attack");

        // THE FINDING, stated as two assertions. If either goes red the attack does not work and
        // this suite says so rather than dressing it up.
        int256 edge = _reportHeadPnl(ctl, atk, target);
        int256 backHarm = _reportBackPnl(ctl, atk, target);

        // **THE REMEDY DOES NOT REFUND THE DODGE, AND SAYING IT DID WOULD BE THE OVERCLAIM.**
        // `withdraw` demoting to the tail cannot claw back a loss the attacker never took: capital
        // that was not in the pool cannot be filled, so the ONE-SHOT edge above is exactly what it
        // was before the remedy existed. What the remedy takes is the FUTURE — the head keeps its
        // seat and loses its place, and has to buy its way back. The before/after is therefore a
        // change in RANK, not in this transaction's P&L, and the two must not be conflated.
        emit log_string("--- where the head is standing when it is over ---");
        emit log_named_uint("control end rank       ", ctl.endRank);
        emit log_named_uint("attack  end rank       ", atk.endRank);
        assertEq(ctl.endRank, 0, "the control lost its rank without withdrawing anything");
        assertEq(atk.endRank, N - 1, "THE STRIKE KEPT THE FRONT: the demotion did not fire");

        emit log_string("--- round-trip cost (NOT a LAW 4 gas measurement) ---");
        emit log_named_uint("gas withdraw+addToSeat ", atk.gasRoundTrip);
        emit log_named_uint("dust eaten (face-paid) ", atk.dustLost);

        assertGt(edge, 0, "VERDICT: evacuation did NOT profit the head");
        assertLt(backHarm, 0, "VERDICT: the back of the book was NOT made worse off");
    }

    /// @dev Both runs must land on the same price or the two marks are in different numeraires.
    function _reportPrices(Result memory ctl, Result memory atk, uint160 target) internal {
        emit log_named_uint("target sqrtP           ", uint256(target));
        emit log_named_uint("control final sqrtP    ", uint256(ctl.finalSqrt));
        emit log_named_uint("attack  final sqrtP    ", uint256(atk.finalSqrt));
        uint256 spread = ctl.finalSqrt > atk.finalSqrt
            ? uint256(ctl.finalSqrt - atk.finalSqrt)
            : uint256(atk.finalSqrt - ctl.finalSqrt);
        uint256 bps = (spread * 10_000) / uint256(ctl.finalSqrt);
        emit log_named_uint("final price spread bps ", bps);
        assertLt(bps, 5, "the two pools did not land on the same price: the marks are incomparable");
        emit log_string("--- informed trader's input to reach the same price ---");
        emit log_named_uint("control  amountIn      ", ctl.amountIn);
        emit log_named_uint("attack   amountIn      ", atk.amountIn);
        // The informed trader's own P&L at the price they moved the pool to. It is the mirror of
        // what the queue lost, and the evacuation SHRINKS it — an evacuated head is depth that is
        // not there to be picked off. Reported because it is the one number that shows the attack
        // is not purely redistributive.
        int256 tC = int256(ctl.amountOut) - int256(_value1(ctl.amountIn, 0, target));
        int256 tA = int256(atk.amountOut) - int256(_value1(atk.amountIn, 0, target));
        emit log_named_int("informed trader, CONTROL", tC);
        emit log_named_int("informed trader, ATTACK ", tA);
    }

    function _reportFills(Result memory ctl, Result memory atk) internal {
        // PITFALLS 5.54 — prove the path was ENTERED before believing anything measured on it.
        assertGt(ctl.headGave1, 0, "nothing happened: the head absorbed no fill in the CONTROL");
        assertGt(atk.backGave1, 0, "nothing happened: the back absorbed no fill in the ATTACK");

        emit log_string("--- token1 inventory GIVEN UP (the adverse fill) ---");
        emit log_named_uint("control  head (rank 0) ", ctl.headGave1);
        emit log_named_uint("attack   head (rank 0) ", atk.headGave1);
        emit log_named_uint("control  back (1..7)   ", ctl.backGave1);
        emit log_named_uint("attack   back (1..7)   ", atk.backGave1);
        emit log_named_int("EXTRA fill on the back ", int256(atk.backGave1) - int256(ctl.backGave1));
    }

    /// @dev Trader gain == queue loss, at the common price, to the wei-ish. Two instruments, one
    ///      system, opposite signs.
    function _checkMirror(Result memory r, uint160 target, string memory tag) internal {
        int256 trader = int256(r.amountOut) - int256(_value1(r.amountIn, 0, target));
        int256 head = int256(_value1(r.head0, r.head1, target)) - int256(_value1(r.headStart0, r.headStart1, target));
        int256 back = int256(_value1(r.back0, r.back1, target)) - int256(_value1(r.backStart0, r.backStart1, target));
        assertApproxEqAbs(
            trader, -(head + back), 1e9, string.concat(tag, ": the trader's gain is not the queue's loss")
        );
    }

    function _reportHeadPnl(Result memory ctl, Result memory atk, uint160 target) internal returns (int256 edge) {
        int256 pnlC =
            int256(_value1(ctl.head0, ctl.head1, target)) - int256(_value1(ctl.headStart0, ctl.headStart1, target));
        int256 pnlA =
            int256(_value1(atk.head0, atk.head1, target)) - int256(_value1(atk.headStart0, atk.headStart1, target));
        edge = pnlA - pnlC;
        uint256 base = _value1(ctl.headStart0, ctl.headStart1, target);
        emit log_string("--- head holder MTM in raw token1, both marked at the SAME target price ---");
        emit log_named_uint("head seat start value  ", base);
        emit log_named_int("head P&L, CONTROL      ", pnlC);
        emit log_named_int("head P&L, ATTACK       ", pnlA);
        emit log_named_int("ATTACK EDGE            ", edge);
        if (base != 0) emit log_named_int("edge, bps of seat value", (edge * 10_000) / int256(base));
    }

    function _reportBackPnl(Result memory ctl, Result memory atk, uint160 target) internal returns (int256 harm) {
        int256 bC =
            int256(_value1(ctl.back0, ctl.back1, target)) - int256(_value1(ctl.backStart0, ctl.backStart1, target));
        int256 bA =
            int256(_value1(atk.back0, atk.back1, target)) - int256(_value1(atk.backStart0, atk.backStart1, target));
        harm = bA - bC;
        emit log_string("--- ranks 1..7 MTM, same price ---");
        emit log_named_int("back P&L, CONTROL      ", bC);
        emit log_named_int("back P&L, ATTACK       ", bA);
        emit log_named_int("BACK'S EXTRA LOSS      ", harm);

        // IS SUBORDINATION EVEN ECONOMICALLY REAL? In the CONTROL, per unit of seat value, how
        // much worse off is the head than the seats behind it? That ratio is what the priority
        // premium is being asked to compensate — and it is exactly what `withdraw` deletes.
        uint256 headBase = _value1(ctl.headStart0, ctl.headStart1, target);
        uint256 backBase = _value1(ctl.backStart0, ctl.backStart1, target);
        int256 headBps = (int256(_value1(ctl.head0, ctl.head1, target)) - int256(headBase)) * 10_000 / int256(headBase);
        int256 backBps = bC * 10_000 / int256(backBase);
        emit log_string("--- CONTROL: adverse-selection loss per unit of seat value ---");
        emit log_named_int("rank 0, bps            ", headBps);
        emit log_named_int("ranks 1..7, bps        ", backBps);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.2 — the same experiment with the premium OFF, so nobody can say φ did the work
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_8_2_theEdgeIsNotAnArtefactOfThePremium() public {
        address[] memory rA = _rosterAt(0xD0000000);
        address[] memory rB = _rosterAt(0xD1000000);
        (QueueHarness hA, PoolKey memory kA) = _build(0xE300, rA, 0);
        (QueueHarness hB, PoolKey memory kB) = _build(0xE400, rB, 0);

        uint160 target = _target();
        Result memory ctl = _episode(hA, kA, rA, false, target);
        Result memory atk = _episode(hB, kB, rB, true, target);

        int256 pnlC =
            int256(_value1(ctl.head0, ctl.head1, target)) - int256(_value1(ctl.headStart0, ctl.headStart1, target));
        int256 pnlA =
            int256(_value1(atk.head0, atk.head1, target)) - int256(_value1(atk.headStart0, atk.headStart1, target));

        assertGt(ctl.headGave1, 0, "nothing happened: the head absorbed no fill at phi = 0");
        emit log_named_int("phi=0 head P&L, CONTROL", pnlC);
        emit log_named_int("phi=0 head P&L, ATTACK ", pnlA);
        emit log_named_int("phi=0 ATTACK EDGE      ", pnlA - pnlC);
        assertGt(pnlA, pnlC, "at phi = 0 the evacuation did not profit the head");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.3 — CAN A THIRD PARTY EVACUATE A SEAT IT DOES NOT OWN?
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev `withdraw` is owner-gated. This is the NEGATIVE half of the answer and it asserts the
    ///      SPECIFIC reason (LAW 2) — `NotSeatOwner`, not merely "it reverted".
    function test_8_3_withdrawIsOwnerGated() public {
        _use(ctlHook, ctlKey);
        (uint256 a0, uint256 a1) = ctlHook.seat(0);
        address mallory = address(0x4A110);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(QueueSeats.NotSeatOwner.selector, uint256(0), mallory));
        ctlHook.withdraw(0, a0, a1);
    }

    /// @dev ...and the POSITIVE half. `buySeat` -> `_moveSeat` -> `_onSeatTransfer` evacuates the
    ///      seat's whole capital on any change of holder, and it is UNBLOCKABLE by design (§B.8).
    ///      A seat that has never been priced quotes ZERO, so on a fresh roster a third party can
    ///      empty the head at a moment of its own choosing for the price of gas — and the rank
    ///      arrives EMPTY, so the fill it would have absorbed passes straight to rank 1.
    function test_8_3b_aThirdPartyCanEmptyTheHeadThroughBuySeat() public {
        _use(ctlHook, ctlKey);
        address mallory = address(0x4A110);
        _give(mallory, 0, 0);

        (uint256 a0, uint256 a1) = ctlHook.seat(0);
        assertGt(a0 + a1, 0, "nothing happened: the head is already empty, this test proves nothing");
        assertEq(ctlHook.buyPrice(0), 0, "the founding roster is supposed to start unpriced");

        uint256 before = gasleft();
        vm.prank(mallory);
        ctlHook.buySeat(0, 0, 0);
        uint256 gasUsed = before - gasleft();

        (uint256 b0, uint256 b1) = ctlHook.seat(0);
        assertEq(b0, 0, "the head still holds token0 after the buyout");
        assertEq(b1, 0, "the head still holds token1 after the buyout");
        assertEq(ctlHook.ownerOf(0), mallory, "the rank did not move");

        emit log_named_uint("buySeat evacuation gas (NOT a LAW 4 number)", gasUsed);

        // ...and the fill now starts at rank 1.
        (, uint256 r1Before) = ctlHook.seat(ctlHook.idAtRank(1));
        _advSwap(address(this), true, _inputToReach(_target()));
        (, uint256 r1After) = ctlHook.seat(ctlHook.idAtRank(1));
        assertLt(r1After, r1Before, "nothing happened: rank 1 absorbed nothing, this test proves nothing");
        emit log_named_uint("token1 rank 1 gave up after a forced head evacuation", r1Before - r1After);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.0b — THE POSITIVE CONTROL. Without this, an "edge" that is really a difference between
    //        the two pools looks exactly like a successful attack.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_8_0b_withoutTheEvacuationTheTwoPoolsMoveIdentically() public {
        uint160 target = _target();
        Result memory a = _episode(ctlHook, ctlKey, ctlRoster, false, target);
        Result memory b = _episode(atkHook, atkKey, atkRoster, false, target);

        assertGt(a.headGave1, 0, "nothing happened: no fill at all, this test proves nothing");
        assertEq(a.amountIn, b.amountIn, "the two pools needed different inputs with nobody evacuating");
        assertEq(a.headGave1, b.headGave1, "the head absorbed different fills with nobody evacuating");
        assertEq(a.backGave1, b.backGave1, "the back absorbed different fills with nobody evacuating");

        int256 edge = int256(_value1(b.head0, b.head1, target)) - int256(_value1(a.head0, a.head1, target));
        assertEq(edge, 0, "the two pools differ before any evacuation: 8.1's edge would be an artefact");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.4 — the whole attack in ONE transaction, from one contract
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_8_4_theRoundTripFitsInOneTransaction() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];

        Evacuator e =
            new Evacuator(atkHook, swapRouter, MockERC20(Currency.unwrap(c0)), MockERC20(Currency.unwrap(c1)), atkKey);
        e.approveAll(address(permit2));

        // The seat moves to the attacking contract. A plain transfer evacuates the seat, so it is
        // refunded first and then re-funded by the contract — this is setup, not the attack.
        (uint256 a0, uint256 a1) = atkHook.seat(0);
        vm.prank(head);
        atkHook.transfer(address(e), 0, 1);
        MockERC20(Currency.unwrap(c0)).mint(address(e), a0);
        MockERC20(Currency.unwrap(c1)).mint(address(e), a1);
        vm.prank(address(e));
        atkHook.addToSeat(0, a0, a1);
        atkHook.sweepFloatIntoPosition();

        // ... and the informed trader's own capital.
        uint256 amountIn = _inputToReach(_target());
        MockERC20(Currency.unwrap(c0)).mint(address(e), amountIn);

        // ---- PART A: INSIDE THE TERM, THE ROUND TRIP IS NOT AVAILABLE AT ALL.
        //
        // **THIS IS THE PHASE 12 RESULT AND IT IS A CHANGE OF KIND, NOT OF DEGREE.** Phase 10 could
        // only PRICE this dodge — `withdraw` demotes, so the attacker paid a rank for it — and
        // PROGRESS recorded plainly that "no rule can claw back a loss the attacker never took".
        // `MIN_TENURE` does not try to. It removes the manoeuvre from the menu while the seat is
        // inside the term it took on when it funded: the round trip opens with a `withdraw`, and a
        // seat inside its term cannot voluntarily give up its rank.
        //
        // The setup above re-funded seat 0 from EMPTY, which arms a fresh term — so the attacker
        // here is in exactly the position a newly-committed subordinated LP is in.
        {
            uint256 unlock = atkHook.unlockAt(0);
            assertGt(unlock, block.timestamp, "the term already elapsed: PART A proves nothing");
            vm.expectRevert(
                abi.encodeWithSelector(QueueHook.SeatWithinTerm.selector, uint256(0), unlock, block.timestamp)
            );
            e.strike(0, amountIn);
        }

        // ---- PART B: OUTSIDE THE TERM IT IS AVAILABLE AGAIN, AND IT STILL COSTS THE RANK.
        //
        // Stated rather than hidden: the term closes the window, it does not abolish the attack. A
        // holder who has served their term can still step aside — and Phase 10's demotion is what
        // charges them for it. Both halves are asserted so neither can be quoted alone.
        vm.warp(block.timestamp + atkHook.MIN_TENURE() + 1);

        (uint256 s0Before, uint256 s1Before) = atkHook.seat(0);
        (, uint256 r1Before) = atkHook.seat(atkHook.idAtRank(1));

        uint256 g = gasleft();
        e.strike(0, amountIn);
        uint256 used = g - gasleft();

        (uint256 s0After, uint256 s1After) = atkHook.seat(0);
        (, uint256 r1After) = atkHook.seat(atkHook.idAtRank(1));

        assertLt(r1After, r1Before, "nothing happened: rank 1 absorbed nothing, this test proves nothing");
        assertEq(s1After, s1Before, "the head's token1 inventory moved: it did not escape the fill");
        assertEq(s0After, s0Before, "the head's token0 ledger did not come back whole");
        assertEq(atkHook.ownerOf(0), address(e), "the attacker did not keep rank 0");

        emit log_named_uint("ONE-TX strike gas incl. the swap (NOT a LAW 4 number)", used);
        emit log_named_uint("token1 rank 1 gave up instead of the head", r1Before - r1After);
        _checkInvariantF("after the one-tx strike", 64);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.5 — HARBERGER PRICES THE *DURATION* OF AN ABSENCE. THE STRIKE HAS NO DURATION.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice PITFALLS 5.9 records rank-then-run as **CLOSED by Phase 4**, on the strength of
    ///         `test_4_7`: "priced, the same window costs exactly thirty days of rent". Every arm of
    ///         that test contains `vm.warp(block.timestamp + 30 days)`.
    ///
    /// @dev Rent is a TIME INTEGRAL — `Rent.owed(price, elapsed, ...)`, and `_settleSeat` returns on
    ///      its own `if (elapsed == 0) return;`. So the bill for an abandonment window is
    ///      proportional to how long the holder is away, and the strike in `test_8_4` is away for
    ///      ZERO SECONDS. This test runs `test_4_7`'s arm 2 with the warp deleted and the seat
    ///      priced as richly as you like: the meter does not move.
    ///
    ///      That does not make 5.9 wrong. It makes its scope narrower than the word CLOSED suggests:
    ///      Harberger prices a holder who is absent for a while, and cannot see a holder who is
    ///      absent for no time at all.
    function test_8_5_anAtomicEvacuationCostsZeroRentAtAnySelfPrice() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];

        // A richly priced seat with a full meter — the most expensive configuration to abandon.
        vm.prank(head);
        atkHook.setSelfPrice(0, 100e18);
        MockERC20(Currency.unwrap(c0)).mint(head, 20e18);
        vm.prank(head);
        atkHook.fundRent(0, 20e18);

        // Let a real bill accrue and settle it, so the meter is demonstrably live before the strike.
        vm.warp(block.timestamp + 1 days);
        (, uint256 escBefore,,,) = atkHook.leaseOf(0);
        atkHook.settleRent(0);
        (, uint256 escSettled,,,) = atkHook.leaseOf(0);
        assertLt(escSettled, escBefore, "nothing happened: the meter is not running, this test proves nothing");
        emit log_named_uint("rent for ONE DAY of tenure   ", escBefore - escSettled);

        // ---- THE STRIKE, with no warp anywhere in it ----
        (uint256 a0, uint256 a1) = atkHook.seat(0);
        vm.prank(head);
        atkHook.withdraw(0, a0, a1);
        _advSwap(address(this), true, _inputToReach(_target()));
        uint256 w0 = MockERC20(Currency.unwrap(c0)).balanceOf(head);
        uint256 w1 = MockERC20(Currency.unwrap(c1)).balanceOf(head);
        vm.prank(head);
        atkHook.addToSeat(0, w0, w1);

        (, uint256 escAfter,,,) = atkHook.leaseOf(0);
        emit log_named_uint("rent for the WHOLE STRIKE    ", escSettled - escAfter);

        assertEq(escAfter, escSettled, "the atomic evacuation was charged rent");
        assertEq(atkHook.rentDue(0), 0, "the atomic evacuation left a bill behind");
        assertEq(atkHook.ownerOf(0), head, "the strike cost the holder their seat");
        // THE RANK IS THE ONLY THING IT COSTS, AND THAT IS THE WHOLE ARGUMENT FOR THE REMEDY.
        // The lease charged zero above — at any self-price, because the absence had no duration.
        // Rank is what is left for the mechanism to take, so rank is what it takes.
        assertEq(atkHook.rankOfId(0), N - 1, "the strike kept its rank: the demotion did not fire");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.6 — THE SECOND DOOR. Relevant to any remedy that only guards `withdraw`.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **THE DOOR IS SHUT, AND THIS IS THE TEST THAT SAYS SO.** `_onSeatTransfer` still
    ///         evacuates a seat's ENTIRE capital on any change of holder — it must, or the
    ///         allocator quotes depth the queue cannot source (§B.8) — but taking that depth out
    ///         now costs the holder their place in the queue, exactly as `withdraw` does.
    ///
    /// @dev **WHAT THIS TEST USED TO ASSERT.** It asserted `rankOfId(0) == 0` after the transfer,
    ///      under the message "THE RANK MOVED: a withdraw-only remedy would still bind here". That
    ///      was the finding: a holder with a second address had the whole `test_8_1` evacuation
    ///      without ever calling `withdraw`, and on the UNPRICED seats the founding roster starts
    ///      in it was completely free. PITFALLS 5.123(a). The assertions below are the same
    ///      sequence with the expected rank flipped.
    ///
    ///      Both arms are kept, because the two states are genuinely different: an unpriced seat
    ///      arms nothing on transfer (`live` is false) and a priced one leaves a firm quote at what
    ///      was paid, which for a plain transfer is ZERO. The firm quote was the ONLY cost of this
    ///      door before, it was conditional on the seat being priced, and it is still not the
    ///      mechanism that closes it — the demotion is.
    function test_8_6_transferToASecondAddressCostsTheRank() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        address alt = address(0xA17E);

        // ---- ARM 1: the founding, UNPRICED seat. Free before; it costs the front now.
        (uint256 a0, uint256 a1) = atkHook.seat(0);
        assertGt(a0 + a1, 0, "nothing happened: the head is empty, this test proves nothing");
        assertGt(atkHook.seatLiquidity(0), 0, "the head contributed no depth: this test proves nothing");
        assertEq(atkHook.rankOfId(0), 0, "setup: seat 0 is not at the front");

        vm.prank(head);
        atkHook.transfer(alt, 0, 1);

        (uint256 b0, uint256 b1) = atkHook.seat(0);
        assertEq(b0 + b1, 0, "the transfer did not evacuate the seat");
        assertEq(atkHook.seatLiquidity(0), 0, "the transfer left the departing holder's depth behind");
        assertEq(atkHook.rankOfId(0), N - 1, "THE TRANSFER KEPT ITS RANK: the second evacuation door is open");
        assertEq(atkHook.idAtRank(0), 1, "seat 1 was not promoted into the vacated front");
        assertEq(atkHook.ownerOf(0), alt, "the seat did not change hands");
        (uint256 got0, uint256 got1) =
            (MockERC20(Currency.unwrap(c0)).balanceOf(head), MockERC20(Currency.unwrap(c1)).balanceOf(head));
        assertEq(got0, a0, "the departing holder was not paid their token0");
        assertEq(got1, a1, "the departing holder was not paid their token1");
        // `leaseOf` returns FIVE values (selfPrice, escrow, firmPrice, firmUntil, lastSettled).
        // The first draft of this line skipped three and read `lastSettled` into `fu` — it passed,
        // because a never-settled seat has `lastSettled == 0` too. A green assertion on the wrong
        // slot, caught by `test_8_7` failing on the identical mistake.
        (,, uint256 fp, uint64 fu,) = atkHook.leaseOf(0);
        assertEq(fu, 0, "an unpriced seat armed a firm quote it had no price to protect");
        assertEq(fp, 0, "an unpriced seat armed a firm PRICE it had no price to protect");

        // ---- ARM 2: a PRICED seat, and one that is NOT at the tail, or the demotion would be a
        // no-op and this arm would prove nothing (`test_8_8c`). Seat 1 was promoted into rank 0
        // above, so it is the one to use.
        uint256 id = atkHook.idAtRank(0);
        address holder = atkHook.ownerOf(id);
        address alt2 = address(0xA17E3);
        assertGt(atkHook.seatLiquidity(id), 0, "the promoted seat contributed no depth: arm 2 is vacuous");

        vm.startPrank(holder);
        atkHook.setSelfPrice(id, 100e18);
        vm.stopPrank();
        // FUND THE METER. Without this the seat forecloses on the warp below and is demoted by the
        // RENT mechanism, which would make this arm pass for the wrong reason. (It failed exactly
        // that way on the first run of the version of this test that preceded the remedy.)
        MockERC20(Currency.unwrap(c0)).mint(holder, 20e18);
        vm.prank(holder);
        atkHook.fundRent(id, 20e18);
        vm.warp(block.timestamp + FIRM_WINDOW + 1); // let the repricing window lapse
        assertEq(atkHook.rankOfId(id), 0, "the seat foreclosed before the transfer: this arm proves nothing");
        assertEq(atkHook.buyPrice(id), 100e18, "the seat is not actually priced: this arm proves nothing");

        vm.prank(holder);
        atkHook.transfer(alt2, id, 1);
        assertEq(atkHook.rankOfId(id), N - 1, "THE PRICED ARM KEPT ITS RANK");
        assertEq(atkHook.buyPrice(id), 0, "the transfer did not leave the seat firm at zero");

        // ...and repricing still cannot lift the firm quote. The window's quote is a RUNNING
        // MINIMUM and `_setPrice` extends the deadline, so the attempt makes the exposure longer,
        // not shorter. That was the only cost this door ever carried; it is no longer the only one.
        vm.prank(alt2);
        atkHook.setSelfPrice(id, 500e18);
        assertEq(atkHook.buyPrice(id), 0, "repricing lifted the firm-at-zero quote");

        _checkInvariantF("after two transfer evacuations", 64);
        _checkInvariantR("after two transfer evacuations");
        _checkInvariantL("after two transfer evacuations");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.7 — A PROMOTION REPRICES NOTHING AND ARMS NOTHING. The bypass the demotion remedy needs.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The proposed remedy is "a successful `withdraw` demotes the seat to the tail". The
    ///         attacker then has to buy their way back to the front — and the question is what that
    ///         costs. It costs whatever the seat NOW at rank 0 is priced at, and that seat's price
    ///         was set while it stood at rank 1.
    ///
    /// @dev `_demoteToTail` (QueueHook.sol:575) writes exactly three things: `order`, `cursor0`,
    ///      `cursor1`. It touches NO lease. Nothing anywhere arms a firm quote on a PROMOTION, and
    ///      `_setPrice` is holder-only — so a holder who is promoted into rank 0 by somebody else's
    ///      demotion cannot reprice inside that somebody's transaction. They are takeable, at the
    ///      price of a worse rank, with no window in which to react.
    ///
    ///      This is driven through FORECLOSURE rather than through the unbuilt remedy, because
    ///      foreclosure calls the same `_demoteToTail`. The fact under test is a property of the
    ///      promotion, and the promotion is identical either way.
    ///
    ///      **WHAT THIS USED TO PROVE, AND WHAT IT PROVES NOW.** It proved the mechanical
    ///      precondition — the promoted seat's quote is stale and immediately hittable — and
    ///      mallory took rank 0 for the rank-1 price, a 10x discount. Both halves of the remedy are
    ///      asserted below on the same fixture: Rule A refuses the take inside the promoting block,
    ///      and Rule B lets the holder actually do something with that block. The gap between a
    ///      rank-1 and a rank-0 price is still whatever holders make it; what the contract now
    ///      guarantees is that nobody collects it inside the transaction that created it.
    function test_8_7_aPromotedSeatIsNoLongerTakeableAtItsStalePrice() public {
        _use(ctlHook, ctlKey);
        address r0 = ctlRoster[0];
        address r1 = ctlRoster[1];
        address mallory = address(0x4A110);

        // Rank 0 prices itself like a front seat; rank 1 prices itself like a rank-1 seat. The
        // ratio is the point, not the absolute numbers.
        uint256 FRONT_PRICE = 100e18;
        uint256 SECOND_PRICE = 10e18;

        vm.prank(r0);
        ctlHook.setSelfPrice(0, FRONT_PRICE);
        vm.prank(r1);
        ctlHook.setSelfPrice(1, SECOND_PRICE);

        // Rank 0's meter is nearly dry; rank 1's is funded. A founding seat's FIRST price arms no
        // window (`_setPrice`'s else-branch needs a previous price), so both quotes are live now.
        assertEq(ctlHook.buyPrice(0), FRONT_PRICE, "rank 0's quote is not live: this test proves nothing");
        assertEq(ctlHook.buyPrice(1), SECOND_PRICE, "rank 1's quote is not live: this test proves nothing");
        MockERC20(Currency.unwrap(c0)).mint(r0, 1e15);
        vm.prank(r0);
        ctlHook.fundRent(0, 1e15);
        MockERC20(Currency.unwrap(c0)).mint(r1, 1e18);
        vm.prank(r1);
        ctlHook.fundRent(1, 1e18);

        // ---- the demotion. Same `_demoteToTail` the remedy would call. ----
        vm.warp(block.timestamp + 30 days);
        ctlHook.settleRent(0);

        assertEq(ctlHook.rankOfId(0), N - 1, "nothing happened: seat 0 was not demoted, this test proves nothing");
        assertEq(ctlHook.idAtRank(0), 1, "seat 1 was not promoted into rank 0");

        // ---- THE FINDING: the promoted seat's quote is untouched and unarmed. ----
        (,, uint256 firmPrice, uint64 firmUntil,) = ctlHook.leaseOf(1);
        assertEq(firmUntil, 0, "the promotion armed a firm quote");
        firmPrice;
        assertEq(ctlHook.buyPrice(1), SECOND_PRICE, "the promoted seat repriced itself: the bypass would be closed");

        // ---- RULE A: AND IT IS NO LONGER HITTABLE IN THE BLOCK THAT PROMOTED IT. ----
        //
        // The demotion above published `lastDemotionBlock`/`lastDemotionRank`, and seat 1's price
        // was stamped at rank 1, so the take is refused BY NAME. LAW 2: the exact reason, with its
        // arguments, not merely "it reverted". `buySeat` is a direct call into the hook and not a
        // v4 callback, so the error is NOT wrapped in `CustomRevert.WrappedError` (PITFALLS 5.83).
        uint128 depthBefore = ctlHook.seatLiquidity(1);
        assertGt(depthBefore, 0, "the promoted seat contributed no depth: this test proves nothing");
        MockERC20(Currency.unwrap(c0)).mint(mallory, SECOND_PRICE + 1_500e18);
        MockERC20(Currency.unwrap(c1)).mint(mallory, 400e18);
        vm.startPrank(mallory);
        MockERC20(Currency.unwrap(c0)).approve(address(ctlHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(ctlHook), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(QueueHook.SeatWasJustPromoted.selector, uint256(1), uint256(0), uint8(1))
        );
        ctlHook.buySeatAndFund(1, SECOND_PRICE, SECOND_PRICE, 1_000e18, 250e18, 0);
        vm.stopPrank();

        emit log_named_uint("what the stale quote WOULD have bought rank 0 for", SECOND_PRICE);
        emit log_named_uint("the outgoing front seat's own quote              ", FRONT_PRICE);
        emit log_named_uint("discount refused, x                              ", FRONT_PRICE / SECOND_PRICE);

        // ---- RULE B: and the grace is worth something, because the holder can actually act. ----
        //
        // Without this half, Rule A buys the holder nothing: an ordinary raise leaves the seat firm
        // at the OLD number for a whole `FIRM_WINDOW`, so a promoted holder is defenceless however
        // fast they react. Because their rank IMPROVED since they priced, the raise binds at once.
        vm.prank(r1);
        ctlHook.setSelfPrice(1, FRONT_PRICE);
        assertEq(
            ctlHook.buyPrice(1), FRONT_PRICE, "RULE B DID NOT BIND: the promoted seat is still firm at the stale price"
        );

        // ...and the seat is for sale again immediately, at the number its holder now stands behind.
        // Rule A is a one-block grace, not a veto: no warp, no new block, only a fresh price.
        MockERC20(Currency.unwrap(c0)).mint(mallory, FRONT_PRICE);
        vm.startPrank(mallory);
        ctlHook.buySeatAndFund(1, FRONT_PRICE, FRONT_PRICE, 1_000e18, 250e18, 0);
        vm.stopPrank();
        assertEq(ctlHook.ownerOf(1), mallory, "the repriced seat was not takeable at its NEW price");
        assertEq(ctlHook.rankOfId(1), 0, "the funded buyer did not end up at the front");
        assertGe(ctlHook.seatLiquidity(1), depthBefore, "the buyer did not replace the depth");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.17 — RULE A IS A GRACE, NOT A VETO. The seat is takeable in the very next block.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **THE OTHER HALF OF RULE A, AND THE ONE THAT KEEPS IT FROM BEING A PERMANENT VETO.**
    ///         A promoted seat whose holder never reprices is refused for the block the promotion
    ///         happened in, and is takeable at the stale price in the next one.
    ///
    /// @dev A rule that refused the buyout until the holder acted would be exactly the incumbent
    ///      veto §B.8 exists to forbid: post a price at rank 7, wait to be promoted, and never
    ///      touch the seat again. The block boundary is what bounds it. What the holder gets is one
    ///      block in which to use Rule B; what they do NOT get is the ability to sit on a stale
    ///      quote for ever.
    ///
    ///      The negative control is the same call in the same state one block later, so the ONLY
    ///      difference between the refusal and the sale is `block.number` (PITFALLS 5.53: assert
    ///      the identity, not the direction).
    function test_8_17_ruleAIsAGraceNotAVeto() public {
        _use(ctlHook, ctlKey);
        address mallory = address(0x4A111);
        (uint256 stale,) = _promoteSeatOneByForeclosingSeatZero();

        MockERC20(Currency.unwrap(c0)).mint(mallory, stale * 4 + 2_000e18);
        MockERC20(Currency.unwrap(c1)).mint(mallory, 500e18);
        vm.startPrank(mallory);
        MockERC20(Currency.unwrap(c0)).approve(address(ctlHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(ctlHook), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(QueueHook.SeatWasJustPromoted.selector, uint256(1), uint256(0), uint8(1))
        );
        ctlHook.buySeatAndFund(1, stale, stale, 1_000e18, 250e18, 0);

        // ONE BLOCK LATER, nothing else changed, the holder did not act: the sale goes through at
        // the stale number. That is the cost of Rule A being bounded, stated as an assertion.
        vm.roll(block.number + 1);
        ctlHook.buySeatAndFund(1, stale, stale, 1_000e18, 250e18, 0);
        vm.stopPrank();
        assertEq(ctlHook.ownerOf(1), mallory, "the seat was not takeable in the block after the promotion");
        assertEq(ctlHook.rankOfId(1), 0, "the buyer did not end up at the front");
    }

    /// @dev Foreclose the head so the seat behind it is promoted into rank 0, and hand back the
    ///      price the promoted seat had posted for its OLD rank. Shared by `test_8_7` and
    ///      `test_8_17` so the two cannot drift apart about what "promoted" means.
    function _promoteSeatOneByForeclosingSeatZero() internal returns (uint256 stale, uint256 front) {
        address r0 = ctlRoster[0];
        address r1 = ctlRoster[1];
        (front, stale) = (100e18, 10e18);

        vm.prank(r0);
        ctlHook.setSelfPrice(0, front);
        vm.prank(r1);
        ctlHook.setSelfPrice(1, stale);
        MockERC20(Currency.unwrap(c0)).mint(r0, 1e15);
        vm.prank(r0);
        ctlHook.fundRent(0, 1e15);
        MockERC20(Currency.unwrap(c0)).mint(r1, 1e18);
        vm.prank(r1);
        ctlHook.fundRent(1, 1e18);

        vm.warp(block.timestamp + 30 days);
        ctlHook.settleRent(0);
        assertEq(ctlHook.rankOfId(0), N - 1, "nothing happened: seat 0 was not demoted");
        assertEq(ctlHook.idAtRank(0), 1, "seat 1 was not promoted into rank 0");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.18 — RULE B MUST NOT BE REACHABLE BY A HOLDER WHOSE RANK DID NOT IMPROVE.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **THE GUARD ON RULE B, ASSERTED FROM BOTH SIDES.** A holder who was promoted
    ///         reprices with immediate effect; a holder who was NOT still leaves the old number
    ///         firm for a whole `FIRM_WINDOW`. If the second half did not hold, Rule B would be a
    ///         general escape from the firm quote and Harberger would deliver nothing but a tax.
    ///
    /// @dev The two arms run on the SAME hook, the same holder, and the same shape of raise —
    ///      100e18 to 500e18, window lapsed in both — so the only thing that differs is whether the
    ///      seat's rank improved since it was priced. That is what makes this a control rather than
    ///      two unrelated observations.
    function test_8_18_immediateRepricingIsOnlyForAHolderWhoWasPromoted() public {
        _use(ctlHook, ctlKey);

        // ---- ARM 1: rank UNCHANGED. The raise must not bind for FIRM_WINDOW.
        address r2 = ctlRoster[2];
        vm.prank(r2);
        ctlHook.setSelfPrice(2, 100e18);
        MockERC20(Currency.unwrap(c0)).mint(r2, 50e18);
        vm.prank(r2);
        ctlHook.fundRent(2, 50e18);
        vm.warp(block.timestamp + FIRM_WINDOW + 1);
        assertEq(ctlHook.rankOfId(2), 2, "the seat moved: arm 1 is not the unchanged-rank case");
        vm.prank(r2);
        ctlHook.setSelfPrice(2, 500e18);
        assertEq(ctlHook.buyPrice(2), 100e18, "A HOLDER WHO WAS NOT PROMOTED ESCAPED THE FIRM QUOTE");

        // ---- ARM 2: the same holder, the same raise, after a PROMOTION they did not choose.
        // Foreclose the two seats in front, which slides seat 2 to the front.
        vm.warp(block.timestamp + 30 days);
        ctlHook.settleRent(2); // fund the meter first so this one does not foreclose itself
        assertEq(ctlHook.rankOfId(2), 2, "seat 2 foreclosed: arm 2 would prove nothing");
        (uint256 s0a, uint256 s0b) = ctlHook.seat(0);
        vm.prank(ctlHook.ownerOf(0));
        ctlHook.withdraw(0, s0a, s0b);
        (uint256 s1a, uint256 s1b) = ctlHook.seat(1);
        vm.prank(ctlHook.ownerOf(1));
        ctlHook.withdraw(1, s1a, s1b);
        assertEq(ctlHook.rankOfId(2), 0, "seat 2 was not promoted to the front: arm 2 proves nothing");

        vm.warp(block.timestamp + FIRM_WINDOW + 1); // let arm 1's window lapse, so only rank differs
        uint256 quoteBefore = ctlHook.buyPrice(2);
        vm.prank(r2);
        ctlHook.setSelfPrice(2, 900e18);
        assertEq(ctlHook.buyPrice(2), 900e18, "RULE B DID NOT BIND for a holder who WAS promoted");
        assertTrue(quoteBefore != 900e18, "the quote was already the new number: arm 2 proves nothing");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.12 — THE DODGE AND THE RANK ARE MUTUALLY EXCLUSIVE. The exemption, attacked directly.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **THE ONE WAY TO KEEP THE FRONT IS TO BE STANDING IN IT.** A sybil who uses
    ///         `buySeatAndFund` keeps rank 0 — and the capital they had to put back is in the pool
    ///         while the adverse swap runs, so it eats exactly the fill they were trying to dodge.
    ///
    /// @dev This is the assertion the exemption in `_settleRankOnTransfer` lives or dies on. If
    ///      there were any way to satisfy the depth test with capital that is not exposed, the
    ///      remedy would be theatre: `test_8_11`'s attacker would simply pay the extra call. The
    ///      claim is stated as the two facts that cannot both be true — the seat is at rank 0, AND
    ///      the seat gave up inventory to the adverse fill — measured against `test_8_11`, where
    ///      the same attacker on the same fixture gave up NOTHING and stood at rank 7.
    ///
    ///      It is deliberately NOT stated as "the edge is zero". The attacker's total exposure to
    ///      the move is what they chose to deposit, and they must deposit at least the seller's
    ///      depth to keep the rank; a P&L comparison would therefore be a statement about how much
    ///      they overfunded, not about the mechanism. The fill is the mechanism.
    function test_8_12_aSybilWhoKeepsTheFrontEatsTheFill() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        address alt = address(0xA17E4);
        uint256 PRICE = 100e18;

        uint128 depthBefore = atkHook.seatLiquidity(0);
        assertGt(depthBefore, 0, "the head contributed no depth: this test proves nothing");

        vm.prank(head);
        atkHook.setSelfPrice(0, PRICE);

        MockERC20(Currency.unwrap(c0)).mint(alt, PRICE + 600e18);
        MockERC20(Currency.unwrap(c1)).mint(alt, 150e18);
        vm.startPrank(alt);
        MockERC20(Currency.unwrap(c0)).approve(address(atkHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(atkHook), type(uint256).max);
        atkHook.buySeatAndFund(0, PRICE, PRICE, 600e18, 150e18, type(uint256).max);
        vm.stopPrank();

        assertEq(atkHook.ownerOf(0), alt, "the seat did not change hands");
        assertEq(atkHook.rankOfId(0), 0, "the funded sybil buyout LOST the front");
        assertGe(atkHook.seatLiquidity(0), depthBefore, "the depth was not replaced: this test is vacuous");

        (, uint256 held1) = atkHook.seat(0);
        assertGt(held1, 0, "the refunded seat holds no outgoing inventory: this test proves nothing");

        _advSwap(address(this), true, _inputToReach(_target()));

        (, uint256 after1) = atkHook.seat(0);
        assertEq(atkHook.rankOfId(0), 0, "the attacker did not hold the front across the swap");
        assertLt(after1, held1, "THE FRONT SEAT DODGED THE FILL WHILE KEEPING RANK 0");
        emit log_named_uint("token1 the funded sybil GAVE UP at rank 0", held1 - after1);
        emit log_string("...against 0 for the unfunded sybil in test_8_11, which stood at rank 7");

        _checkInvariantF("funded sybil buyout", 64);
        _checkInvariantR("funded sybil buyout");
        _checkInvariantL("funded sybil buyout");
    }

    /// @notice **THE BOUNDARY: EXACTLY THE DEPTH IS ENOUGH.** The rule is `after < before`, not
    ///         `after <= before`, and the difference is a whole seat's rank.
    ///
    /// @dev **THIS TEST EXISTS BECAUSE THE MUTATION SURVIVED.** Turning `<` into `<=` — so that a
    ///      buyer who replaces the depth EXACTLY is demoted anyway — passed the entire suite,
    ///      because every other keep-rank test overfunds. A boundary that only ever gets
    ///      approached from one side is not a boundary anybody has asserted (AGENTS §3b).
    ///
    ///      The equality is constructible rather than lucky: `_liquidityForAmounts` is a
    ///      deterministic function of the amounts and the live price, and NOTHING here has moved
    ///      the price since the roster was funded — adding and removing liquidity do not. So
    ///      depositing exactly what the seller deposited mints exactly what the seller minted.
    ///      `assertEq` on the depth is what makes that a claim rather than a hope.
    function test_8_12b_replacingExactlyTheDepthKeepsTheRank() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        address alt = address(0xA17E7);

        uint128 depthBefore = atkHook.seatLiquidity(0);
        assertGt(depthBefore, 0, "the head contributed no depth: this test proves nothing");

        MockERC20(Currency.unwrap(c0)).mint(alt, SEAT0);
        MockERC20(Currency.unwrap(c1)).mint(alt, SEAT1);
        vm.startPrank(alt);
        MockERC20(Currency.unwrap(c0)).approve(address(atkHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(atkHook), type(uint256).max);
        // Never priced, so the seat is free to take: the PRICE is not what this test is about.
        atkHook.buySeatAndFund(0, 0, 0, SEAT0, SEAT1, type(uint256).max);
        vm.stopPrank();

        assertEq(atkHook.seatLiquidity(0), depthBefore, "the deposit did not mint EXACTLY the seller's depth");
        assertEq(atkHook.rankOfId(0), 0, "REPLACING EXACTLY THE DEPTH LOST THE RANK");
        assertEq(atkHook.ownerOf(0), alt, "the seat did not change hands");

        _checkInvariantF("after an exact-depth buyout", 64);
        _checkInvariantL("after an exact-depth buyout");
    }

    /// @notice **A BUYOUT OF AN EMPTY SEAT CAN FUND IT IN THE SAME CALL.** `_onSeatTransfer`
    ///         returns EARLY for a seat that holds nothing and owes nothing — the pure-rank path
    ///         the whole Phase 4 market leans on — so the funding has to be applied on that branch
    ///         too, and the line that does it is asserted here.
    ///
    /// @dev Deleting `_settleRankOnTransfer` from the early-return branch survived every other
    ///      test in the suite before this one existed.
    ///
    ///      The demotion half of that call is live on this branch too, since the branch now empties
    ///      a seat that reached it holding depth and no balances — see `test_8_16`.
    function test_8_14_aBuyoutOfAnEmptySeatCanFundItInTheSameCall() public {
        _use(ctlHook, ctlKey);
        address first = address(0xB0B0);
        address second = address(0xB0B1);

        // Reach the pure-rank state through production: a buyout evacuates the seat outright.
        _give(first, 0, 0);
        vm.prank(first);
        ctlHook.buySeat(0, 0, 0);
        (uint256 e0, uint256 e1) = ctlHook.seat(0);
        assertEq(e0 + e1, 0, "the seat is not empty: this test proves nothing");
        assertEq(ctlHook.seatLiquidity(0), 0, "the seat still holds depth: this test proves nothing");
        uint256 rankBefore = ctlHook.rankOfId(0);

        _give(second, SEAT0, SEAT1);
        vm.prank(second);
        ctlHook.buySeatAndFund(0, 0, 0, SEAT0, SEAT1, type(uint256).max);

        assertEq(ctlHook.ownerOf(0), second, "the empty seat did not change hands");
        (uint256 g0, uint256 g1) = ctlHook.seat(0);
        assertEq(g0, SEAT0, "THE FUNDING DID NOT LAND: the empty-seat branch skipped it (token0)");
        assertEq(g1, SEAT1, "THE FUNDING DID NOT LAND: the empty-seat branch skipped it (token1)");
        assertGt(ctlHook.seatLiquidity(0), 0, "the funded buyout minted no depth on the empty-seat branch");
        // It took no depth out — there was none — so it costs no rank.
        assertEq(ctlHook.rankOfId(0), rankBefore, "funding an EMPTY seat cost the buyer a rank");

        _checkInvariantF("after funding an empty seat through the buyout", 64);
        _checkInvariantR("after funding an empty seat through the buyout");
        _checkInvariantL("after funding an empty seat through the buyout");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.15 — A FOURTH DOOR. The PITFALLS 5.122 demotion is bypassed by PRE-FUNDING THE FLOAT.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice 🚨 **THE `withdraw` DEMOTION IS CONDITIONAL ON A BURN, AND THE BURN IS CONDITIONAL
    ///         ON THE FLOAT.** `_payOut` only touches the position when the float cannot cover the
    ///         request, so a holder who arranges for the float to cover their WHOLE balance
    ///         withdraws everything, burns nothing, is charged nothing by `_chargeBurn`, and keeps
    ///         their place in the queue. That is the PITFALLS 5.122 evacuation with the remedy
    ///         switched off.
    ///
    /// @dev **THIS IS NOT A CORNER, AND THE FLOAT IS CHEAP TO BUILD.** A SINGLE-TOKEN in-range
    ///      deposit mints zero liquidity (`_liquidityForAmounts` takes the min of the two legs),
    ///      so the whole of it goes into the shared float while the depositing seat is credited
    ///      the full amount — it is not a fee, it is not spent, and it can be withdrawn again the
    ///      same way. The attacker needs a SECOND seat to hold that credit (funding their own seat
    ///      inflates the balance they are trying to withdraw by exactly the amount they added), and
    ///      the roster runs to `MAX_SEATS = 32`.
    ///
    ///      **IT COLLIDED HEAD-ON WITH THE RULE PITFALLS 5.130 PAID FOR, AND THAT COLLISION HAS NOW
    ///      BEEN RESOLVED AGAINST 5.130.** `test_8_9` used to establish that taking PROFIT out must
    ///      not cost a rank, and the definition of profit it used was exactly "a withdrawal the
    ///      float can cover burns no depth" — under which pre-funding the float makes EVERYTHING
    ///      profit. The two rules could not both stand.
    ///
    ///      The refinement is WITHDRAWN. `withdraw` now demotes on any payout at all. Every attempt
    ///      to separate the two cases collapses: "did `s.liquidity` fall" is the same question as
    ///      "was anything burned" (`_chargeBurn` returns early on `burned == 0`), and every other
    ///      formulation compares the seat's remaining ledger against the depth it is credited with,
    ///      which needs a price-dependent valuation of principal — under which an honest front seat
    ///      is demoted for its MARKOUT LOSSES, i.e. 5.130 one level deeper rather than a fix for it.
    ///
    ///      The blanket rule stands on its own merits: the product sells SUBORDINATION, and a holder
    ///      cannot be subordinate and liquid at the same time. **This test is kept EXACTLY as it was
    ///      executed, because the manoeuvre is the evidence** — only its final assertion is
    ///      inverted, and the "bypass engaged" assertion above it is retained deliberately so the
    ///      test still proves the burn-based rule would have been blind here.
    ///
    ///      It is also the security half of the accounting defect tracked separately in
    ///      `Maturity.t.sol` (a seat's contributed depth outliving the balances that backed it).
    function test_8_15_prefundingTheFloatNoLongerKEEPSTheRankThroughAFullWithdrawal() public {
        _use(atkHook, atkKey);
        uint256 victim = atkHook.idAtRank(1); // not the tail: demoting the tail is a no-op
        address holder = atkHook.ownerOf(victim);
        uint256 spare = atkHook.idAtRank(N - 1);
        address spareHolder = atkHook.ownerOf(spare);

        (uint256 b0, uint256 b1) = atkHook.seat(victim);
        assertGt(b0 + b1, 0, "the victim seat is empty: this test proves nothing");
        uint128 depth = atkHook.seatLiquidity(victim);
        assertGt(depth, 0, "the victim seat contributed no depth: this test proves nothing");

        // Build the float out of two SINGLE-TOKEN deposits, which mint nothing and land whole.
        uint128 spareDepth = atkHook.seatLiquidity(spare);
        _give(spareHolder, b0 + 1e18, b1 + 1e18);
        vm.startPrank(spareHolder);
        atkHook.addToSeat(spare, b0 + 1e18, 0);
        atkHook.addToSeat(spare, 0, b1 + 1e18);
        vm.stopPrank();
        // The two deposits added NO depth — that is what makes the float free to build. The seat
        // that supplied it is credited every wei and can take it back out the same way.
        assertEq(atkHook.seatLiquidity(spare), spareDepth, "a single-token deposit minted depth: the setup is wrong");
        (uint256 f0, uint256 f1) = atkHook.floats();
        assertGe(f0, b0, "the float does not cover the victim's token0: this test proves nothing");
        assertGe(f1, b1, "the float does not cover the victim's token1: this test proves nothing");

        _strikeThroughTheFloat(victim, holder, b0, b1, depth);
    }

    /// @dev The strike itself, split out of `test_8_15` only because that function hit
    ///      `Stack too deep`. Every assertion is the finding.
    function _strikeThroughTheFloat(uint256 victim, address holder, uint256 b0, uint256 b1, uint128 depth) internal {
        uint256 wallet0 = MockERC20(Currency.unwrap(c0)).balanceOf(holder);
        vm.prank(holder);
        (uint256 p0, uint256 p1) = atkHook.withdraw(victim, b0, b1);

        // THE FINDING: the whole balance left, and the rank did not.
        assertEq(p0, b0, "the withdrawal did not pay the whole token0 balance");
        assertEq(p1, b1, "the withdrawal did not pay the whole token1 balance");
        assertGt(MockERC20(Currency.unwrap(c0)).balanceOf(holder), wallet0, "the holder was not actually paid");
        (uint256 z0, uint256 z1) = atkHook.seat(victim);
        assertEq(z0 + z1, 0, "the seat is not empty after withdrawing everything");
        // **THE BYPASS STILL ENGAGES — THAT IS THE POINT.** Zero depth is burned, so every rule
        // phrased in terms of the BURN (`_chargeBurn`'s return, or equivalently "did `s.liquidity`
        // fall") is still blind here. Asserting it keeps this test measuring the actual hole rather
        // than a state where the hole closed itself.
        assertEq(atkHook.seatLiquidity(victim), depth, "the withdrawal burned depth: the bypass did not engage");

        // THE INVERSION. This was `assertEq(rankOfId(victim), 1)` — the door standing open. The
        // demotion no longer asks what was burned; it asks whether anything was PAID.
        assertEq(atkHook.rankOfId(victim), N - 1, "FOURTH DOOR STILL OPEN: full withdrawal, zero burn, rank retained");
        emit log_string("FOURTH DOOR SHUT: full withdrawal, zero burn, rank surrendered anyway");
        emit log_named_uint("token0 taken out  ", p0);
        emit log_named_uint("token1 taken out  ", p1);
        emit log_named_uint("depth still credited to the emptied seat", depth);
    }

    /// @notice **A SEAT CAN HOLD DEPTH WITH NO BALANCES, AND MOVING IT MUST TAKE THAT DEPTH WITH
    ///         IT — AND COST THE RANK.** The pure-rank early return in `_onSeatTransfer` was the
    ///         sibling of the INVARIANT L mirror below it, and it had the same hole.
    ///
    /// @dev The state is `test_8_15`'s: a withdrawal the float covered empties the ledger while
    ///      every unit of the seat's contributed depth stays in the position. Handing that seat on
    ///      used to carry the departing holder's depth — and their share of `standingL`, THE
    ///      PREMIUM'S DENOMINATOR — to the new holder for free, which is precisely what the main
    ///      evacuation branch goes out of its way to refuse ("the buyer receives rank, never
    ///      depth"). One rule, two branches, right in one: the family this project has now been
    ///      bitten by seven times (5.37, 5.50, 5.52 twice, 5.73, 5.125, 5.132).
    ///
    ///      INVARIANT L is asserted on BOTH sides of the transfer, which is the assertion that
    ///      would have caught the missing branch on its own: the orphaned depth has to land in
    ///      `liquidityUnattributed` or the identity stops closing.
    function test_8_16_aDepthOnlySeatLeavesItsDepthBehindAndLosesItsRank() public {
        _use(atkHook, atkKey);
        uint256 victim = atkHook.idAtRank(1); // not the tail: demoting the tail is a no-op
        address holder = atkHook.ownerOf(victim);
        uint128 depth = _emptyThroughTheFloat(victim, holder);

        (,, uint256 unattrBefore) = (uint256(0), uint256(0), _unattributed());
        _checkInvariantL("a seat holding depth and no balances");

        vm.prank(holder);
        atkHook.transfer(address(0xA17E8), victim, 1);

        assertEq(atkHook.seatLiquidity(victim), 0, "THE TRANSFER LEFT THE DEPARTING HOLDER'S DEPTH ON THE SEAT");
        assertEq(_unattributed(), unattrBefore + depth, "the orphaned depth was not booked as unattributed");
        assertEq(atkHook.rankOfId(victim), N - 1, "A DEPTH-ONLY SEAT KEPT ITS RANK ACROSS A TRANSFER");
        _checkInvariantL("after transferring a depth-only seat");
        _checkInvariantF("after transferring a depth-only seat", 64);
        _checkInvariantR("after transferring a depth-only seat");
    }

    function _unattributed() internal view returns (uint256 u) {
        (, u,) = atkHook.liquidityTotals();
    }

    /// @dev Drive a seat to zero balances while every unit of its contributed depth stays in the
    ///      position, through production calls only. Two SINGLE-TOKEN deposits into another seat
    ///      mint nothing (`_liquidityForAmounts` takes the min of the legs) and land in the shared
    ///      float whole; once the float covers the whole request, `_payOut` burns nothing. Shared
    ///      by `test_8_15` (which is about what that costs the RANK) and `test_8_16` (about what it
    ///      does to the DEPTH).
    function _emptyThroughTheFloat(uint256 victim, address holder) internal returns (uint128 depth) {
        uint256 spare = atkHook.idAtRank(N - 1);
        address spareHolder = atkHook.ownerOf(spare);

        (uint256 b0, uint256 b1) = atkHook.seat(victim);
        assertGt(b0 + b1, 0, "the victim seat is empty: this test proves nothing");
        depth = atkHook.seatLiquidity(victim);
        assertGt(depth, 0, "the victim seat contributed no depth: this test proves nothing");

        uint128 spareDepth = atkHook.seatLiquidity(spare);
        _give(spareHolder, b0 + 1e18, b1 + 1e18);
        vm.startPrank(spareHolder);
        atkHook.addToSeat(spare, b0 + 1e18, 0);
        atkHook.addToSeat(spare, 0, b1 + 1e18);
        vm.stopPrank();
        assertEq(atkHook.seatLiquidity(spare), spareDepth, "a single-token deposit minted depth: the setup is wrong");

        vm.prank(holder);
        atkHook.withdraw(victim, b0, b1);
        (uint256 z0, uint256 z1) = atkHook.seat(victim);
        assertEq(z0 + z1, 0, "the withdrawal did not empty the seat: this test proves nothing");
        assertEq(atkHook.seatLiquidity(victim), depth, "the withdrawal burned depth: the setup did not engage");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.13 — THE SIDE CHANNEL IS CLEARED. A transient that outlives its call is a free deposit.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **A TRANSIENT IS CLEARED AT THE END OF THE TRANSACTION, NOT AT THE END OF THE
    ///         CALL.** `fundOnTransfer0/1` carry the buyer's deposit into `_onSeatTransfer`, and
    ///         `_buySeat` zeroes them when it is done. If it did not, the NEXT change of holder in
    ///         the same transaction — an ordinary `transfer`, which passes no funding at all —
    ///         would re-read them, pull the tokens from whoever called it, and keep a rank it did
    ///         not pay for.
    ///
    /// @dev A Foundry test body is ONE transaction, so two consecutive top-level calls here are
    ///      exactly the shape the hazard needs; no helper contract is required to build it. This
    ///      is the same class as `paidForSeat`, which is cleared for the same reason on the line
    ///      below — and the reason both are asserted rather than argued is that "it is transient,
    ///      so it cannot survive" is true of the TRANSACTION and false of the CALL.
    function test_8_13_theFundingSideChannelDoesNotLeakIntoTheNextTransfer() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        address alt = address(0xA17E5);
        address third = address(0xA17E6);
        uint256 PRICE = 100e18;

        vm.prank(head);
        atkHook.setSelfPrice(0, PRICE);

        MockERC20(Currency.unwrap(c0)).mint(alt, PRICE + 5_000e18);
        MockERC20(Currency.unwrap(c1)).mint(alt, 1_000e18);
        vm.startPrank(alt);
        MockERC20(Currency.unwrap(c0)).approve(address(atkHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(atkHook), type(uint256).max);
        atkHook.buySeatAndFund(0, PRICE, PRICE, 600e18, 150e18, type(uint256).max);
        assertEq(atkHook.rankOfId(0), 0, "the funded buyout did not keep the rank: this test proves nothing");
        assertGt(atkHook.seatLiquidity(0), 0, "the funded buyout minted no depth: this test proves nothing");

        // Same transaction, ordinary transfer, no funding passed. It must be an evacuation like any
        // other: the seat leaves empty, contributes nothing, and goes to the tail.
        uint256 spentBefore = MockERC20(Currency.unwrap(c1)).balanceOf(alt);
        atkHook.transfer(third, 0, 1);
        vm.stopPrank();

        assertEq(atkHook.seatLiquidity(0), 0, "THE STALE FUNDING RE-FUNDED THE SEAT ON A PLAIN TRANSFER");
        assertEq(atkHook.rankOfId(0), N - 1, "THE STALE FUNDING BOUGHT A RANK ON A PLAIN TRANSFER");
        assertGt(
            MockERC20(Currency.unwrap(c1)).balanceOf(alt),
            spentBefore,
            "the transfer took token1 from the caller instead of paying it out"
        );

        _checkInvariantF("after a buyout followed by a transfer", 64);
        _checkInvariantL("after a buyout followed by a transfer");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.19 — `buySeat` NAMES A SEAT AND PAYS FOR A RANK. The seller can move the rank first.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice 🚨 **THE BUYER HAD NO RANK GUARD AT ALL — ONLY `maxPrice`.** Since a withdrawal that
    ///         takes depth out costs the holder their place (PITFALLS 5.122), a seller who sees a
    ///         buyout coming front-runs it with `withdraw(all)`: the seat lands at the tail, the
    ///         buyout still succeeds, and the buyer pays the rank-0 price for rank `N-1` while the
    ///         seller keeps BOTH the price and their capital.
    ///
    /// @dev Arm 1 executes the rug against the three-argument `buySeat`, which accepts any rank by
    ///      construction and always will — that is what "no guard" means, and it is left executable
    ///      rather than removed so the shape stays visible. Arm 2 is the remedy: the buyer names the
    ///      worst rank they will accept and the call is refused BY NAME (LAW 2 — the exact reason
    ///      with its arguments; `buySeat` is a direct call, not a v4 callback, so nothing wraps it).
    ///
    ///      **THE GUARD IS A VETO AND THE HONEST THING IS TO SAY SO.** An incumbent can make a
    ///      rank-guarded buyout revert by demoting themselves first. What it costs them is their
    ///      whole place in the queue, permanently, and it cannot be repeated — a seat already at the
    ///      tail has nothing left to give up, and it is still buyable by anyone who passes
    ///      `type(uint256).max`. So: you can always be bought out of your SEAT; you can only defend
    ///      your RANK by giving it up. That is not the free, repeatable veto §B.8 forbids.
    function test_8_19_theSellerCanMoveTheRankOutFromUnderTheBuyer() public {
        _use(ctlHook, ctlKey);
        address seller = ctlRoster[0];
        address buyer = address(0x8B0B);
        uint256 PRICE = 100e18;

        vm.prank(seller);
        ctlHook.setSelfPrice(0, PRICE);
        assertEq(ctlHook.rankOfId(0), 0, "setup: the seat under test is not at the front");

        // THE FRONT-RUN. Same block, before the buyout lands.
        (uint256 a0, uint256 a1) = ctlHook.seat(0);
        vm.prank(seller);
        ctlHook.withdraw(0, a0, a1);
        assertEq(ctlHook.rankOfId(0), N - 1, "the front-run did not move the rank: this test proves nothing");
        assertEq(ctlHook.buyPrice(0), PRICE, "the front-run also moved the price: this test proves nothing");

        MockERC20(Currency.unwrap(c0)).mint(buyer, PRICE * 2 + 2_000e18);
        MockERC20(Currency.unwrap(c1)).mint(buyer, 500e18);
        vm.startPrank(buyer);
        MockERC20(Currency.unwrap(c0)).approve(address(ctlHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(ctlHook), type(uint256).max);

        // ---- ARM 2 first, because a revert leaves the state untouched: THE GUARD REFUSES IT.
        vm.expectRevert(abi.encodeWithSelector(QueueHook.RankBelowMinimum.selector, uint256(0), N - 1, uint256(0)));
        ctlHook.buySeatAndFund(0, PRICE, PRICE, 1_000e18, 250e18, 0);

        // ---- ARM 1: the unguarded buyout still lands, and the buyer is at the back.
        uint256 spent = MockERC20(Currency.unwrap(c0)).balanceOf(buyer);
        ctlHook.buySeat(0, PRICE, PRICE);
        spent -= MockERC20(Currency.unwrap(c0)).balanceOf(buyer);
        vm.stopPrank();

        assertEq(spent, PRICE, "the unguarded buyer did not pay the posted price");
        assertEq(ctlHook.ownerOf(0), buyer, "the unguarded buyout did not land");
        assertEq(ctlHook.rankOfId(0), N - 1, "the unguarded buyer did NOT end up at the tail");
        (uint256 owed,) = ctlHook.pendingOf(seller);
        assertGe(owed, PRICE, "the seller was not credited the price they were paid for a tail seat");
        emit log_named_uint("paid for what was rank 0 when the buyer signed", spent);
        emit log_named_uint("rank actually delivered                       ", ctlHook.rankOfId(0));
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.8 — THE REMEDY. Written BEFORE it was built, and red against the pre-remedy hook.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice A successful `withdraw` must cost the holder their place in the queue. This is the
    ///         `test_8_4` strike again, with the one thing the remedy is supposed to change asserted.
    ///
    /// @dev The rank is the whole assertion. The attacker still dodges the fill — nothing can stop
    ///      capital that is not in the pool from being filled — but they must not still be standing
    ///      at the front afterwards. What that costs them is a SEPARATE question, answered by the
    ///      before/after in the report and bounded by `test_8_7`: they can buy back in at whatever
    ///      the promoted seat is priced at.
    function test_8_8_aWithdrawCostsTheHolderTheirPlaceInTheQueue() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        assertEq(atkHook.rankOfId(0), 0, "setup: seat 0 is not at the front");

        (uint256 a0, uint256 a1) = atkHook.seat(0);
        vm.prank(head);
        (uint256 p0, uint256 p1) = atkHook.withdraw(0, a0, a1);
        assertGt(p0 + p1, 0, "nothing happened: the withdrawal paid nothing, this test proves nothing");

        assertEq(atkHook.rankOfId(0), N - 1, "THE STRIKE KEPT ITS RANK: subordination is still unenforced");
        assertEq(atkHook.idAtRank(0), 1, "seat 1 was not promoted into the vacated front");
        assertEq(atkHook.ownerOf(0), head, "the demotion took the seat as well as the rank");

        // ...and the seats it stood in front of really do fill first now.
        _advSwap(address(this), true, _inputToReach(_target()));
        (, uint256 tailA1) = atkHook.seat(0);
        assertEq(tailA1, 0, "setup: the demoted seat should still be empty");
        _checkInvariantF("after a demoting withdrawal", 64);
        _checkInvariantR("after a demoting withdrawal");
        _checkInvariantL("after a demoting withdrawal");
    }

    /// @dev A withdrawal that moves NOTHING must not cost a rank. Otherwise a holder whose request
    ///      is clamped to zero by the dust policy pays the full penalty for receiving nothing, and
    ///      `withdraw(id, 0, 0)` becomes a way to demote yourself by accident. This is a boundary,
    ///      not a threshold: the rule is "a withdrawal that paid nothing changes nothing".
    function test_8_8b_aZeroWithdrawalDoesNotCostARank() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        vm.prank(head);
        (uint256 p0, uint256 p1) = atkHook.withdraw(0, 0, 0);
        assertEq(p0 + p1, 0, "the zero withdrawal paid something: this test proves nothing");
        assertEq(atkHook.rankOfId(0), 0, "a withdrawal that paid nothing still cost a rank");
    }

    /// @dev (2a) A tail seat taking its premium coupon is demoted to... the tail. `_demoteToTail`
    ///      has no early return by design (PITFALLS 5.49), and the general path is exactly
    ///      equivalent at `r == n-1`. Asserted rather than assumed, because "it is a no-op" is the
    ///      kind of claim that is true until the order word is repacked.
    function test_8_8c_demotingTheTailSeatIsANoOp() public {
        _use(atkHook, atkKey);
        uint256 tailId = atkHook.idAtRank(N - 1);
        uint256[] memory before = atkHook.ranking();

        (uint256 a0, uint256 a1) = atkHook.seat(tailId);
        vm.prank(atkHook.ownerOf(tailId));
        atkHook.withdraw(tailId, a0, a1);

        uint256[] memory got = atkHook.ranking();
        for (uint256 i; i < N; i++) {
            assertEq(got[i], before[i], "demoting the tail seat permuted the queue");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.9 — ANY PAYOUT IS LEAVING. The refined rule was exploitable and has been WITHDRAWN.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **INVERTED 2026-09-02. THIS TEST USED TO ASSERT THAT TAKING PROFIT KEPT THE RANK.**
    ///         The refined rule — demote only when the withdrawal burned into the seat's own
    ///         contributed depth — is exactly the rule `test_8_15` walks through the front door:
    ///         `_payOut` spends the FLOAT first and only burns the remainder, so a float-covered
    ///         payout burns nothing, charges nothing, and demotes nothing while the entire balance
    ///         leaves. **The scenario below is kept UNCHANGED, because it is the evidence** — it
    ///         constructs precisely the float-covered "profit" withdrawal the old rule protected,
    ///         and that is the same observable an evacuator uses.
    ///
    /// @dev **WHY THERE IS NO THIRD RULE.** "Did `s.liquidity` fall?" is the same question as "was
    ///      anything burned?" — `_chargeBurn` returns early on `burned == 0`. Every other
    ///      formulation compares the seat's remaining ledger against the depth it is credited with,
    ///      which needs a price-dependent valuation of principal, under which an honest front seat
    ///      is demoted for its MARKOUT LOSSES — PITFALLS 5.130 one level deeper, not a fix for it.
    ///
    ///      So the rule is the blanket one, on the merits: **the product sells SUBORDINATION, and a
    ///      holder cannot be subordinate and liquid at the same time.** The seats behind pay this
    ///      one to STAND THERE. It cannot be griefed — only the seat holder may call `withdraw`.
    ///      A holder who wants both leaves earnings in the seat, where they go on earning.
    function test_8_9_takingProfitAlsoCostsTheRankBecauseTheFloatMakesThemIndistinguishable() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];

        // Give the pool some history, so the head is holding earnings and not only principal.
        _advSwap(address(this), true, _inputToReach(_target()));

        // A withdrawal the FLOAT can cover burns no liquidity, so it takes no depth out of the
        // pool. That is what "taking profit" means here, and it is a property of the payout rather
        // than of a threshold somebody chose.
        (uint256 f0, uint256 f1) = atkHook.floats();
        (uint256 a0, uint256 a1) = atkHook.seat(0);
        uint256 w0 = f0 < a0 ? f0 : a0;
        uint256 w1 = f1 < a1 ? f1 : a1;
        assertGt(w0 + w1, 0, "there is no float to pay from: this test proves nothing");

        uint128 lBefore = atkHook.seatLiquidity(0);
        assertGt(lBefore, 0, "the head contributed no depth: this test proves nothing");

        vm.prank(head);
        (uint256 p0, uint256 p1) = atkHook.withdraw(0, w0, w1);
        assertGt(p0 + p1, 0, "the profit withdrawal paid nothing: this test proves nothing");

        // **THE STATE THAT MADE THE OLD RULE UNSOUND, ASSERTED SO THE INVERSION IS NOT VACUOUS:**
        // real money left the seat and NOTHING was burned, so the old trigger could not see it.
        assertEq(atkHook.seatLiquidity(0), lBefore, "the float did not cover it: this is not the case under test");

        // THE INVERSION. This was `assertEq(rankOfId(0), 0)` — profit-taking kept the rank.
        assertEq(atkHook.rankOfId(0), N - 1, "a payout that moved real value did NOT cost the rank");
        emit log_named_uint("paid out of float, token0", p0);
        emit log_named_uint("paid out of float, token1", p1);

        // ...and a withdrawal that moves NOTHING still changes nothing. That is the whole of the
        // remaining exemption, and it is the dust-policy clamp rather than a judgement about
        // earnings. Seat 1 is used because seat 0 has just been demoted to the tail, where a
        // "did not move" assertion would hold vacuously (AGENTS §3b).
        uint256 rank1Before = atkHook.rankOfId(1);
        assertTrue(rank1Before != N - 1, "seat 1 is already at the tail: the check below is vacuous");
        vm.prank(atkRoster[1]);
        (uint256 z0, uint256 z1) = atkHook.withdraw(1, 0, 0);
        assertEq(z0 + z1, 0, "a zero request paid something");
        assertEq(atkHook.rankOfId(1), rank1Before, "a withdrawal that paid NOTHING cost the holder their rank");

        _checkInvariantL("after profit-then-exit");
        _checkInvariantF("after profit-then-exit", 64);
    }

    /// @notice **THE RULE HAS TWO LEGS AND EACH ONE IS ASSERTED SEPARATELY.** `withdraw` demotes on
    ///         `p0 != 0 || p1 != 0`; a mutant that drops either half lets a holder evacuate in the
    ///         OTHER token and keep their rank.
    ///
    /// @dev This exists because a mutation said it had to. `if (p0 != 0)` alone — a rule blind to a
    ///      token1-only exit — was caught by exactly ONE test in the whole suite, and `if (p1 != 0)`
    ///      alone by two. **A security rule whose only detector is incidental is a rule nobody has
    ///      asserted** (AGENTS §3b), and this is the one-rule-two-places family that has now bitten
    ///      this project eight times (5.37, 5.50, 5.52 twice, 5.73, 5.125, 5.132, and here).
    ///
    ///      Each leg is driven on its OWN seat, because the first withdrawal demotes the seat it
    ///      touches and a second assertion against an already-tail seat would hold vacuously.
    function test_8_10_eitherLegAloneCostsTheRank() public {
        _use(atkHook, atkKey);
        _advSwap(address(this), true, _inputToReach(_target()));

        // **SEATS ARE CHOSEN BY WHAT THEY HOLD, NOT BY RANK.** A zeroForOne fill drains token1
        // FRONT-FIRST, so the head is exactly the seat with no token1 left — picking by rank made
        // the first arm fire its own "this proves nothing" guard, which is the guard working.
        uint256 only1 = type(uint256).max;
        uint256 only0 = type(uint256).max;
        for (uint256 r = 1; r < N - 1; r++) {
            uint256 id = atkHook.idAtRank(r);
            (uint256 s0, uint256 s1) = atkHook.seat(id);
            if (s1 != 0 && only1 == type(uint256).max) only1 = id;
            else if (s0 != 0 && only0 == type(uint256).max) only0 = id;
        }
        assertTrue(only1 != type(uint256).max, "no non-tail seat holds token1: this test proves nothing");
        assertTrue(only0 != type(uint256).max, "no second non-tail seat holds token0: this test proves nothing");
        assertTrue(only1 != only0, "the two arms share a seat: the second would be vacuous");

        // LEG ONE: pay token1 and nothing else.
        (, uint256 b1) = atkHook.seat(only1);
        assertGt(b1, 0, "no token1 to withdraw: this arm proves nothing");
        vm.prank(atkHook.ownerOf(only1));
        (uint256 q0, uint256 q1) = atkHook.withdraw(only1, 0, b1);
        assertEq(q0, 0, "the token1-only arm paid token0: it is not testing one leg");
        assertGt(q1, 0, "the token1-only arm paid nothing: this arm proves nothing");
        assertEq(atkHook.rankOfId(only1), N - 1, "a token1-ONLY withdrawal did not cost the rank");

        // LEG TWO: the mirror. Pay token0 and nothing else.
        (uint256 c0_,) = atkHook.seat(only0);
        assertGt(c0_, 0, "no token0 to withdraw: this arm proves nothing");
        uint256 rankBefore = atkHook.rankOfId(only0);
        assertTrue(rankBefore != N - 1, "the seat is already at the tail: this arm would be vacuous");
        vm.prank(atkHook.ownerOf(only0));
        (uint256 r0, uint256 r1) = atkHook.withdraw(only0, c0_, 0);
        assertEq(r1, 0, "the token0-only arm paid token1: it is not testing one leg");
        assertGt(r0, 0, "the token0-only arm paid nothing: this arm proves nothing");
        assertEq(atkHook.rankOfId(only0), N - 1, "a token0-ONLY withdrawal did not cost the rank");

        _checkInvariantL("after single-leg exits");
        _checkInvariantF("after single-leg exits", 64);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.11 — THE THIRD DOOR. A SYBIL BUYOUT IS AN EVACUATION THAT KEEPS THE RANK, AND IT DEFEATS
    //        EVERY REMEDY OF THE FORM "a PAID takeover keeps its rank, a gift does not".
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **THE TEST THAT DECIDED THE REMEDY.** `buySeat` evacuates a seat exactly as
    ///         `transfer` does (`test_8_3b`), and it is available to ANYBODY — so it is available
    ///         to the holder's own second address. The price flows from one of the attacker's
    ///         addresses to the other's `pending0`, where `claimPending` returns it in the same
    ///         episode: **the buyout price is a WASH between two addresses one person controls.**
    ///
    /// @dev **WHAT THIS KILLED.** The natural remedy for PITFALLS 5.123(a) is "demote on a change
    ///      of holder UNLESS it is a settled buyout at the posted price" — rank survives a PAID
    ///      takeover but not a gift. This test executes the sybil form of that payment, and before
    ///      the remedy it reproduced `test_8_1`'s attack in full: the same +267 bps edge, the same
    ///      +50.4e18 of extra fill dumped on ranks 1..7, ZERO rent (the absence has no duration —
    ///      `test_8_5`), and the rank kept. The only residual was a firm quote at a number THE
    ///      ATTACKER CHOSE, which is not a cost the mechanism imposes: set it above whatever the
    ///      rank is worth to anybody else and nobody takes it. Rent over one `FIRM_WINDOW` at
    ///      tau = 10%/yr is ~1.1e-5 of the posted price against 2.67e-2 of seat capital.
    ///
    ///      So the exemption could not be WHO PAID. It had to be whether the depth the rank is
    ///      priority over is still standing when the call ends — see `_settleRankOnTransfer`, and
    ///      `test_8_12` for the sybil who does put it back and gains nothing by it.
    ///
    ///      **THE CLAIM IS THE PAIR'S NET, NOT ONE ADDRESS'S.** Everything is measured across BOTH
    ///      addresses — wallets, seat ledger and pending claims — because measuring only the
    ///      buyer's wallet would report the self-payment as a cost when it is an internal transfer.
    function test_8_11_aSybilBuyoutCostsTheRankToo() public {
        uint160 target = _target();
        Result memory ctl = _episode(ctlHook, ctlKey, ctlRoster, false, target);
        Result memory atk = _sybilEpisode(target);

        _reportFills(ctl, atk);
        _checkMirror(atk, target, "sybil-buyout attack");
        int256 edge = _reportHeadPnl(ctl, atk, target);
        int256 backHarm = _reportBackPnl(ctl, atk, target);

        emit log_string("--- where the attacker is standing when it is over ---");
        emit log_named_uint("control end rank       ", ctl.endRank);
        emit log_named_uint("sybil   end rank       ", atk.endRank);

        // **THE REMEDY DOES NOT REFUND THE DODGE, AND SAYING IT DID WOULD BE THE OVERCLAIM** —
        // the same sentence `test_8_1` carries, for the same reason. Capital that is not in the
        // pool cannot be filled, so the ONE-SHOT edge below is exactly what it was before the
        // remedy existed. What the remedy takes is the FUTURE: the attacker is standing at the
        // BACK when it is over and has to buy their way forward, and doing that now costs them a
        // deposit they cannot pull back out without paying the same price again.
        assertGt(edge, 0, "the sybil strike does not dodge the fill at all: this test proves nothing");
        assertLt(backHarm, 0, "the back of the book was not made worse off: this test proves nothing");
        assertEq(atk.endRank, N - 1, "THE SYBIL BUYOUT KEPT THE FRONT: the third door is still open");
    }

    /// @dev The strike, through `buySeat` instead of `withdraw`. Self-price 100e18, paid by the
    ///      attacker's own second address, reclaimed through `claimPending` in the same episode.
    function _sybilEpisode(uint160 target) internal returns (Result memory r) {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        address alt = address(0xA17E2);
        uint256 PRICE = 100e18;

        (r.headStart0, r.headStart1) = _pairHoldings(head, alt, 0);
        (r.backStart0, r.backStart1) = _backLedger();

        // The attacker posts their OWN number. A founding seat's first price arms no firm window
        // (`_setPrice`'s else-branch needs a previous price), so the quote is live immediately.
        vm.prank(head);
        atkHook.setSelfPrice(0, PRICE);
        assertEq(atkHook.buyPrice(0), PRICE, "the seat is not priced: this test proves nothing");

        // Fund the second address with the price. It is the attacker's own money moving between
        // the attacker's own addresses; `_pairHoldings` counts both, so it cannot flatter the
        // result. Minted rather than transferred out of `head` only so the wallet split is legible.
        MockERC20(Currency.unwrap(c0)).mint(alt, PRICE);
        vm.startPrank(alt);
        MockERC20(Currency.unwrap(c0)).approve(address(atkHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(atkHook), type(uint256).max);
        vm.stopPrank();
        r.headStart0 += PRICE; // the mint is not profit: count it on both sides of the episode

        (uint256 a0, uint256 a1) = atkHook.seat(0);
        assertGt(a0 + a1, 0, "nothing happened: the head is empty, this test proves nothing");

        uint256 before = gasleft();
        vm.prank(alt);
        atkHook.buySeat(0, PRICE, PRICE);
        uint256 gasBuy = before - gasleft();

        // The evacuation half is unchanged — a change of holder still empties the seat — but the
        // rank it was standing in is gone with the depth.
        (uint256 e0, uint256 e1) = atkHook.seat(0);
        assertEq(e0 + e1, 0, "the buyout did not evacuate the seat");
        assertEq(atkHook.rankOfId(0), N - 1, "THE SYBIL BUYOUT KEPT ITS RANK: the third door is open");
        assertEq(atkHook.ownerOf(0), alt, "the seat did not change hands");
        (uint256 pend0,) = atkHook.pendingOf(head);
        assertGe(pend0, PRICE, "the price was not credited back to the attacker's other address");

        // The informed trader walks the pool to the common target while the front stands empty.
        r.amountIn = _inputToReach(target);
        (, r.amountOut) = _advSwap(address(this), true, r.amountIn);

        // Back to the front, fully funded, same seat, same rank.
        r.gasRoundTrip = gasBuy + _sybilRestore(head, alt);

        // ZERO RENT, for the reason `test_8_5` gives: the absence had no duration.
        assertEq(atkHook.rentDue(0), 0, "the sybil buyout left a rent bill behind");

        (r.finalSqrt,,,) = poolManager.getSlot0(atkKey.toId());
        r.endRank = atkHook.rankOfId(0);
        (r.head0, r.head1) = _pairHoldings(head, alt, 0);
        (r.back0, r.back1) = _backLedger();
        r.headGave1 = r.headStart1 > r.head1 ? r.headStart1 - r.head1 : 0;
        r.backGave1 = r.backStart1 > r.back1 ? r.backStart1 - r.back1 : 0;

        // THE RESIDUAL COST, and it is a number the ATTACKER chose: the seat stands firm at their
        // own price for FIRM_WINDOW. Nobody takes a seat at a price its holder is happy with.
        emit log_string("--- what the sybil buyout actually cost ---");
        emit log_named_uint("firm quote left standing ", atkHook.buyPrice(0));
        emit log_named_uint("rent charged             ", 0);
        emit log_named_uint("gas, buySeat+addToSeat   ", r.gasRoundTrip);
        assertEq(atkHook.buyPrice(0), PRICE, "the seat is firm at something other than the attacker's own price");

        _checkInvariantF("sybil buyout episode", 64);
        _checkInvariantR("sybil buyout episode");
        _checkInvariantL("sybil buyout episode");
    }

    /// @dev The second half of the strike: the capital moves between the attacker's two addresses
    ///      in the open, goes back into the seat it never lost, and the self-payment is claimed.
    ///      Split out of `_sybilEpisode` only because that function hit `Stack too deep`.
    function _sybilRestore(address head, address alt) internal returns (uint256 gasUsed) {
        uint256 h0 = MockERC20(Currency.unwrap(c0)).balanceOf(head);
        uint256 h1 = MockERC20(Currency.unwrap(c1)).balanceOf(head);
        vm.startPrank(head);
        MockERC20(Currency.unwrap(c0)).transfer(alt, h0);
        MockERC20(Currency.unwrap(c1)).transfer(alt, h1);
        vm.stopPrank();

        // The arguments are read BEFORE the prank. `vm.prank` binds the NEXT external call, and an
        // argument expression that makes one would eat it — the first run of this test failed with
        // `NotSeatOwner(0, <the test contract>)` for exactly that reason.
        uint256 back0 = MockERC20(Currency.unwrap(c0)).balanceOf(alt);
        uint256 back1 = MockERC20(Currency.unwrap(c1)).balanceOf(alt);
        uint256 before = gasleft();
        vm.prank(alt);
        atkHook.addToSeat(0, back0, back1);
        gasUsed = before - gasleft();

        // ...and the self-payment comes straight back out.
        (uint256 cp0, uint256 cp1) = atkHook.pendingOf(head);
        vm.prank(head);
        atkHook.claimPending(cp0, cp1);
    }

    /// @dev Everything the attacker owns across BOTH of their addresses. A single-address measure
    ///      would score the self-payment as a cost, which is the mistake this test is about.
    function _pairHoldings(address a, address b, uint256 seatId) internal view returns (uint256 t0, uint256 t1) {
        (uint256 s0, uint256 s1) = hook.seat(seatId);
        (uint256 pa0, uint256 pa1) = hook.pendingOf(a);
        (uint256 pb0, uint256 pb1) = hook.pendingOf(b);
        t0 = s0 + pa0 + pb0 + MockERC20(Currency.unwrap(c0)).balanceOf(a) + MockERC20(Currency.unwrap(c0)).balanceOf(b);
        t1 = s1 + pa1 + pb1 + MockERC20(Currency.unwrap(c1)).balanceOf(a) + MockERC20(Currency.unwrap(c1)).balanceOf(b);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // 8.10 — INVARIANT L ACROSS A SWEEP THAT ACTUALLY MINTS. Written because a mutation survived.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice `sweepFloatIntoPosition` mints depth that NO seat contributed, and it must be
    ///         recorded in `liquidityUnattributed` or INVARIANT L stops tying out.
    ///
    /// @dev **THIS EXISTS BECAUSE DELETING THAT LINE SURVIVED THE ENTIRE SUITE.** Every test that
    ///      asserts INVARIANT L reaches a sweep only through `_build`, where the seats are funded
    ///      almost exactly on-ratio — so `_liquidityForAmounts(float0, float1)` returns ZERO, the
    ///      function early-returns, and the line under test never executes. A rule whose only
    ///      exercise is a no-op call is not covered, it is visited (PITFALLS 5.54).
    ///
    ///      Real float needs an IMBALANCED movement. A withdrawal is the natural source: `_payOut`
    ///      burns liquidity sized on the leg that binds and retains the surplus of the other leg as
    ///      float, which is the whole reason the float exists.
    function test_8_10_invariantLSurvivesASweepThatMints() public {
        _use(atkHook, atkKey);

        // Move the price so the position is no longer near the ratio the seats deposited at, then
        // take a withdrawal out: what the position releases on the non-binding leg becomes float.
        _advSwap(address(this), true, _inputToReach(_target()));
        (uint256 a0, uint256 a1) = atkHook.seat(1);
        vm.prank(atkRoster[1]);
        atkHook.withdraw(1, a0, a1);

        (uint256 f0, uint256 f1) = atkHook.floats();
        assertGt(f0 + f1, 0, "no float was created: this test proves nothing");
        _checkInvariantL("before the sweep");

        (, uint256 unattrBefore, uint256 shortBefore) = atkHook.liquidityTotals();
        uint128 added = atkHook.sweepFloatIntoPosition();
        assertGt(added, 0, "the sweep minted nothing: this test proves nothing");

        (uint256 contributed, uint256 unattrAfter, uint256 shortAfter) = atkHook.liquidityTotals();
        emit log_named_uint("liquidity the sweep minted    ", added);
        emit log_named_uint("unattributed before / after   ", unattrBefore);
        emit log_named_uint("                              ", unattrAfter);

        // The whole of it lands in the unattributed pot, and nowhere else: no seat's contribution
        // moved, so nobody's premium weight changed because someone swept.
        assertEq(unattrAfter, unattrBefore + added, "the swept liquidity was not recorded as unattributed");
        assertEq(shortAfter, shortBefore, "the sweep moved the shortfall");
        uint256 sum;
        for (uint256 i; i < N; i++) {
            sum += atkHook.seatLiquidity(i);
        }
        assertEq(sum, contributed, "the sweep changed a seat's contributed depth");

        _checkInvariantL("after a sweep that minted");
        _checkInvariantF("after a sweep that minted", 64);
        _checkInvariantR("after a sweep that minted");
    }


    /// @notice **THE SENIORITY FREE LANE — is the TAIL reachable for the price of gas?**
    ///
    /// @dev Every other evacuation test in this file asks whether a holder can DODGE a fill while
    ///      KEEPING its rank. This one asks the opposite question, and nothing in the repo had
    ///      asked it: can a holder deliberately THROW its rank away in order to reach a BETTER one?
    ///
    ///      **WHY THAT IS THE MORE DANGEROUS DIRECTION.** `withdraw` demotes on any payout, and
    ///      PITFALLS 5.171 defends that rule on the ground that it "cannot be griefed — only the
    ///      seat holder may call `withdraw`". That answers involuntary demotion. It does not answer
    ///      a holder who WANTS to be demoted, and our own economics say every holder does: at the
    ///      shipped φ = 5,100, `results-shipping-basis.txt` measures the tail beating rank 2 by
    ///      +0.6 pp in BENIGN, +1.3 pp in NORMAL and +3.0 pp in TOXIC. The tail is the best seat in
    ///      the book in every regime measured, and demotion is the only thing that reaches it.
    ///
    ///      **WHAT THIS TEST PROVES AND WHAT IT DOES NOT.** It proves the MECHANISM is free: the
    ///      manoeuvre is one call, the payout is one wei, and the seat's contributed depth arrives
    ///      at the tail intact. It does NOT prove the PRIZE is real — that is the simulator's
    ///      claim, measured by a different instrument, and conflating the two would be exactly the
    ///      tautology AGENTS §3 LAW 5 warns about. Both halves are needed.
    ///
    ///      **AGENTS §3 LAW 5's QUESTION — what would have to be true for this to read FAIL?**
    ///      Either the demotion does not happen (so the tail is unreachable and rank is sticky), or
    ///      reaching it costs the seat its depth (so the prize is paid for). Both are real,
    ///      plausible designs and either one turns this test red. It is not arithmetic.
    function test_8_20_theTailIsReachableForOneWeiAndItPromotesSomebodyElse() public {
        _use(atkHook, atkKey);

        // Give the book history, so the seats hold earnings and not only principal.
        _advSwap(address(this), true, _inputToReach(_target()));

        // THE MOVER is whoever stands at rank 1 — the measured WORST seat behind the head. Read it
        // from the order word rather than assuming founding order still holds.
        uint256 mover = atkHook.ranking()[1];
        uint256 promoted = atkHook.ranking()[2];
        assertEq(atkHook.rankOfId(mover), 1, "the mover is not at rank 1: wrong seat under test");
        assertEq(atkHook.rankOfId(promoted), 2, "the follower is not at rank 2");

        uint128 lBefore = atkHook.seatLiquidity(mover);
        assertGt(lBefore, 0, "the mover contributed no depth: this test proves nothing");

        // ---- THE MANOEUVRE. One call, one wei of whichever token the seat actually holds.
        //      Nothing about the request looks like an exit.
        _oneWeiOut(mover);

        // ---- (1) THE TAIL WAS REACHED FOR ONE WEI.
        assertEq(atkHook.rankOfId(mover), N - 1, "one wei did NOT buy the tail");

        // ---- (2) IT COST ESSENTIALLY NOTHING. The depth that arrives at the tail is the depth
        //      that left rank 1, less at most the one wei actually paid out.
        assertLe(
            uint256(lBefore) - uint256(atkHook.seatLiquidity(mover)),
            1,
            "one wei of payout burned more than one wei of contributed depth"
        );
        emit log_named_uint("depth the mover carried to the tail", atkHook.seatLiquidity(mover));

        // ---- (3) SOMEBODY ELSE WAS MOVED INTO THE SEAT IT LEFT, WITHOUT BEING ASKED. This is the
        //      half that makes it an externality rather than a private choice.
        assertEq(
            atkHook.rankOfId(promoted),
            1,
            "the follower was NOT promoted into rank 1: the manoeuvre has no victim, so it is not a free lane"
        );

        // ---- (4) AND IT IS REPEATABLE, which is what turns a one-off dodge into a rotation
        //      nobody can opt out of.
        assertGt(atkHook.seatLiquidity(promoted), 0, "the promoted seat has no depth: the repeat proves nothing");
        _oneWeiOut(promoted);
        assertEq(atkHook.rankOfId(promoted), N - 1, "the repeat did not reach the tail");

        _checkInvariantL("after the seniority walk");
        _checkInvariantF("after the seniority walk", 64);
    }

    /// @dev Withdraw exactly one wei from `seatId`, as its holder, in whichever token it holds.
    ///      Factored out to keep `test_8_16` inside the stack limit, and it asserts the payout so a
    ///      clamped-to-zero request cannot make the caller's demotion assertions vacuous.
    function _oneWeiOut(uint256 seatId) internal {
        (uint256 a0, uint256 a1) = atkHook.seat(seatId);
        assertGt(a0 + a1, 0, "the seat holds nothing: a one-wei withdrawal proves nothing");
        vm.prank(atkRoster[seatId]);
        (uint256 p0, uint256 p1) = atkHook.withdraw(seatId, a0 > 0 ? 1 : 0, a0 > 0 ? 0 : 1);
        assertEq(p0 + p1, 1, "a one-wei request did not pay exactly one wei: the premise has moved");
    }

    /// @notice **THE TERM — a seat cannot be dropped the moment it is about to cost something.**
    ///
    /// @dev This is the directed test for `MIN_TENURE`. `test_8_20` proves the manoeuvre it
    ///      answers: one wei of withdrawal reaches the TAIL, carrying the seat's depth intact, and
    ///      our own economics make the tail the best seat in the book in every regime measured. So
    ///      without a term, a holder who sees an adverse swap coming steps out of the front for the
    ///      price of gas and puts somebody else in it.
    ///
    ///      **FOUR CLAIMS, AND THE LAST TWO ARE WHAT KEEP THIS FROM BEING A LOCKUP.**
    ///        1. Inside the term, a withdrawal that would demote is REFUSED, by name.
    ///        2. A withdrawal that pays NOTHING is still allowed — the term guards the RANK, not
    ///           the function, and dust policy F1 clamping a request to zero must not be punished
    ///           as an exit attempt.
    ///        3. **The seat is still SELLABLE inside the term.** A holder who wants out posts a
    ///           price and anyone may take it. That is the exit, and what it costs is what the rank
    ///           is worth — set by the holder, not by us.
    ///        4. Once the term is served, the withdrawal goes through.
    ///
    ///      AGENTS §3 LAW 5's question — what would have to be true for this to read FAIL? Delete
    ///      the guard and (1) goes green-to-red. Put the guard on the whole function instead of on
    ///      the demotion and (2) breaks. Make it a capital lock and (3) breaks. Make it permanent
    ///      and (4) breaks. Four independent ways to be wrong, and each has its own assertion.
    function test_8_21_theTermRefusesAVoluntaryDemotionAndTheSeatIsStillSellable() public {
        _use(atkHook, atkKey);

        // Re-fund a seat FROM EMPTY so it is inside a fresh term. The fixture ages its roster past
        // `MIN_TENURE`, so without this the seat would be free to leave and every claim below would
        // hold for the wrong reason.
        uint256 id = atkHook.ranking()[1];
        address who = atkRoster[id];
        (uint256 a0, uint256 a1) = atkHook.seat(id);
        vm.prank(who);
        atkHook.withdraw(id, a0, a1); // legal: the term has been served
        _give(who, a0, a1);
        vm.prank(who);
        atkHook.addToSeat(id, a0, a1); // ...and this arms a NEW term

        uint256 unlock = atkHook.unlockAt(id);
        assertGt(unlock, block.timestamp, "the deposit did not arm a term: this test proves nothing");
        assertEq(unlock, block.timestamp + atkHook.MIN_TENURE(), "the term is not MIN_TENURE long");

        uint256 rankBefore = atkHook.rankOfId(id);
        (uint256 b0, uint256 b1) = atkHook.seat(id);
        assertGt(b0 + b1, 0, "the seat holds nothing: the refusal below would be vacuous");

        // ---- (1) A WITHDRAWAL THAT WOULD DEMOTE IS REFUSED, BY NAME.
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(QueueHook.SeatWithinTerm.selector, id, unlock, block.timestamp));
        atkHook.withdraw(id, b0 > 0 ? 1 : 0, b0 > 0 ? 0 : 1);
        assertEq(atkHook.rankOfId(id), rankBefore, "the refused withdrawal moved the rank anyway");

        // ---- (2) A WITHDRAWAL THAT PAYS NOTHING IS STILL ALLOWED.
        vm.prank(who);
        (uint256 z0, uint256 z1) = atkHook.withdraw(id, 0, 0);
        assertEq(z0 + z1, 0, "a zero request paid something");
        assertEq(atkHook.rankOfId(id), rankBefore, "a zero withdrawal moved the rank");

        // ---- (3) THE SEAT IS STILL SELLABLE INSIDE THE TERM, and (4) once the term is served the
        //      withdrawal goes through. Scoped into a helper to stay inside the stack limit.
        _sellThenServeTheTerm(id, who, b0, b1);

        _checkInvariantL("after the term");
        _checkInvariantF("after the term", 64);
    }

    /// @dev Halves (3) and (4) of `test_8_21`, factored out for the stack.
    ///
    ///      (3) THE ESCAPE VALVE. Without it the term would be a capital lock rather than a rank
    ///      commitment: a holder who wants out posts a price and anybody may take it, and what that
    ///      costs them is exactly what the rank is worth.
    ///      (4) THE TERM ENDS. A served term permits the withdrawal, and it still demotes.
    function _sellThenServeTheTerm(uint256 id, address who, uint256 b0, uint256 b1) internal {
        address buyer = address(0xB0FFEE);
        vm.prank(who);
        atkHook.setSelfPrice(id, 1e18);
        _give(buyer, 1e18, 0);
        vm.prank(buyer);
        atkHook.buySeat(id, 1e18, 1e18);
        assertEq(atkHook.ownerOf(id), buyer, "the seat could not be sold inside its term");

        // The buyout emptied the seat, so re-fund it — which arms a new term — and serve that.
        _give(buyer, b0, b1);
        vm.prank(buyer);
        atkHook.addToSeat(id, b0, b1);
        vm.warp(atkHook.unlockAt(id));

        (uint256 d0,) = atkHook.seat(id);
        vm.prank(buyer);
        (uint256 p0, uint256 p1) = atkHook.withdraw(id, d0 > 0 ? 1 : 0, d0 > 0 ? 0 : 1);
        assertEq(p0 + p1, 1, "the served term did not permit a withdrawal");
        assertEq(atkHook.rankOfId(id), N - 1, "the served withdrawal did not demote");
    }

    /// @notice **A TOP-UP DOES NOT RE-ARM THE TERM — an honest LP cannot be locked by their own
    ///         good behaviour.**
    ///
    /// @dev **WRITTEN BECAUSE A MUTATION SURVIVED.** `Lease.tenureFrom`'s docblock states that only
    ///      a funding FROM EMPTY starts a term, and changing `if (s.liquidity == 0) lease[...] =
    ///      ...` to an unconditional stamp broke nothing in the whole suite. A claim in a comment
    ///      with no assertion behind it is a claim nobody checks (AGENTS §3b), and this one is not
    ///      cosmetic: under the mutant every deposit restarts the lock, so a holder who tops up
    ///      weekly can never withdraw, and anyone able to fund somebody else's seat could extend
    ///      their lock indefinitely.
    ///
    ///      AGENTS §3 LAW 5's question — what would have to be true for this to read FAIL? The
    ///      stamp becoming unconditional. That is a one-character edit somebody could plausibly
    ///      make while "simplifying", and it is exactly what this now catches.
    function test_8_22_aTopUpDoesNotRestartTheTerm() public {
        _use(atkHook, atkKey);

        uint256 id = atkHook.ranking()[1];
        address who = atkRoster[id];

        // Empty the seat and re-fund it, so we know precisely when its term started.
        (uint256 a0, uint256 a1) = atkHook.seat(id);
        vm.prank(who);
        atkHook.withdraw(id, a0, a1);
        _give(who, a0, a1);
        vm.prank(who);
        atkHook.addToSeat(id, a0, a1);

        uint256 armedAt = atkHook.unlockAt(id);
        assertEq(armedAt, block.timestamp + atkHook.MIN_TENURE(), "the refund did not arm a term");

        // Serve most of it, then TOP UP. Under the mutant this restarts the clock.
        vm.warp(block.timestamp + atkHook.MIN_TENURE() - 1);
        _give(who, a0, a1);
        vm.prank(who);
        atkHook.addToSeat(id, a0, a1);
        assertGt(atkHook.seatLiquidity(id), 0, "the top-up minted no depth: this test proves nothing");

        // ---- THE CLAIM, AS AN IDENTITY RATHER THAN A BOUND (PITFALLS 5.53). The unlock time is
        //      the one the ORIGINAL funding set, unchanged to the second.
        assertEq(atkHook.unlockAt(id), armedAt, "THE TOP-UP RESTARTED THE TERM: an honest LP is locked by depositing");

        // ...and the consequence, executed rather than described: one second later the holder is
        // free, which under the mutant they would not be for another MIN_TENURE.
        vm.warp(armedAt);
        (uint256 b0,) = atkHook.seat(id);
        vm.prank(who);
        (uint256 p0, uint256 p1) = atkHook.withdraw(id, b0 > 0 ? 1 : 0, b0 > 0 ? 0 : 1);
        assertEq(p0 + p1, 1, "the holder was still locked after serving the ORIGINAL term");
        assertEq(atkHook.rankOfId(id), N - 1, "the withdrawal did not demote");
    }
}
