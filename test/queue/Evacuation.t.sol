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

    /// @notice `_onSeatTransfer` evacuates a seat's ENTIRE capital on any change of holder and
    ///         **leaves the rank where it is** — "Rank moves; capital does not". So a holder with a
    ///         second address has an evacuation that never touches `withdraw` at all.
    ///
    /// @dev This matters for exactly one reason: a remedy that demotes on `withdraw` does not
    ///      demote here. What DOES cost the holder something is the firm quote — on a PRICED seat
    ///      the transfer arms `firmPrice = paid = 0` for `FIRM_WINDOW`, so the seat is free for
    ///      anyone to take for an hour, and repricing cannot lift it (the window's running minimum
    ///      only ever falls, and `_setPrice` EXTENDS `firmUntil`). On an UNPRICED seat — the state
    ///      every founding seat starts in — `live` is false, nothing is armed, and the door is free.
    function test_8_6_transferToASecondAddressEvacuatesAndKEEPSTheRank() public {
        _use(atkHook, atkKey);
        address head = atkRoster[0];
        address alt = address(0xA17E);

        // ---- ARM 1: the founding, UNPRICED seat. The door is completely free.
        (uint256 a0, uint256 a1) = atkHook.seat(0);
        assertGt(a0 + a1, 0, "nothing happened: the head is empty, this test proves nothing");
        vm.prank(head);
        atkHook.transfer(alt, 0, 1);

        (uint256 b0, uint256 b1) = atkHook.seat(0);
        assertEq(b0 + b1, 0, "the transfer did not evacuate the seat");
        assertEq(atkHook.rankOfId(0), 0, "THE RANK MOVED: a withdraw-only remedy would still bind here");
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
        assertEq(atkHook.buyPrice(0), 0, "the evacuated unpriced seat is not free to take");

        // ---- ARM 2: a PRICED seat. The same door, and here it does cost something.
        MockERC20(Currency.unwrap(c0)).mint(alt, a0);
        MockERC20(Currency.unwrap(c1)).mint(alt, a1);
        vm.startPrank(alt);
        MockERC20(Currency.unwrap(c0)).approve(address(atkHook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(atkHook), type(uint256).max);
        atkHook.addToSeat(0, a0, a1);
        atkHook.setSelfPrice(0, 100e18);
        vm.stopPrank();
        // FUND THE METER. Without this the seat forecloses on the warp below and is demoted to the
        // tail — which is the rent mechanism working, not the transfer door, and it would make this
        // arm pass for the wrong reason. (It failed exactly that way on the first run.)
        MockERC20(Currency.unwrap(c0)).mint(alt, 20e18);
        vm.prank(alt);
        atkHook.fundRent(0, 20e18);
        vm.warp(block.timestamp + FIRM_WINDOW + 1); // let the repricing window lapse
        assertEq(atkHook.rankOfId(0), 0, "the seat foreclosed before the transfer: this arm proves nothing");
        assertEq(atkHook.buyPrice(0), 100e18, "the seat is not actually priced: this arm proves nothing");

        vm.prank(alt);
        atkHook.transfer(head, 0, 1);
        assertEq(atkHook.rankOfId(0), 0, "THE RANK MOVED on the priced arm");
        assertEq(atkHook.buyPrice(0), 0, "the transfer did not leave the seat firm at zero");

        // ...and repricing cannot lift it. The window's quote is a RUNNING MINIMUM and `_setPrice`
        // extends the deadline, so the attempt makes the exposure longer, not shorter.
        vm.prank(head);
        atkHook.setSelfPrice(0, 500e18);
        assertEq(atkHook.buyPrice(0), 0, "repricing lifted the firm-at-zero quote");
        emit log_string("priced arm: the evacuation door costs a FIRM_WINDOW free option on the rank");
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
    ///      **WHAT THIS DOES AND DOES NOT PROVE.** It proves the mechanical precondition: the
    ///      promoted seat's quote is stale and immediately hittable. It does NOT prove the strike
    ///      is profitable after the remedy — that depends on how holders price rank, which is
    ///      behaviour, not code. The gap between a rank-1 and a rank-0 price is the attacker's
    ///      discount, and nothing in the contract makes it small.
    function test_8_7_aPromotedSeatIsTakeableAtItsSTALEPrice() public {
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

        // ...and it is hittable on the spot, by anybody, for the rank-1 price.
        MockERC20(Currency.unwrap(c0)).mint(mallory, SECOND_PRICE);
        vm.startPrank(mallory);
        MockERC20(Currency.unwrap(c0)).approve(address(ctlHook), type(uint256).max);
        ctlHook.buySeat(1, SECOND_PRICE, SECOND_PRICE);
        vm.stopPrank();

        assertEq(ctlHook.ownerOf(1), mallory, "the front seat was not takeable at the stale price");
        assertEq(ctlHook.rankOfId(1), 0, "the buyer did not end up at the front");
        emit log_named_uint("paid for RANK 0                    ", SECOND_PRICE);
        emit log_named_uint("the outgoing front seat's own quote ", FRONT_PRICE);
        emit log_named_uint("discount, x                        ", FRONT_PRICE / SECOND_PRICE);
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
    // 8.9 — TAKING PROFIT IS NOT LEAVING. The refined demotion rule, asserted directly.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice **A WITHDRAWAL THAT TAKES DEPTH OUT COSTS A RANK. ONE THAT TAKES EARNINGS OUT DOES
    ///         NOT.** The blanket "any payout demotes" rule closed the attack and punished the
    ///         holder the mechanism is supposed to be paying: the front seat is where the flow is,
    ///         so realising a coupon means calling `withdraw`, and a blanket rule charged the seat
    ///         for collecting what it was owed.
    ///
    /// @dev This exists because a mutation said it had to. Restoring the blanket rule
    ///      (`if (p0 != 0 || p1 != 0) _demoteToTail(...)`) was caught by exactly ONE test in the
    ///      whole suite — the interleaving cursor fuzz — and only incidentally, through its order
    ///      witness. A rule whose only detector is a fuzz test's side effect is a rule nobody has
    ///      actually asserted (AGENTS §3b: a surviving or thinly-caught mutation is a finding, and
    ///      the honest answer is to write the missing test).
    function test_8_9_takingProfitDoesNotCostARankButLeavingDoes() public {
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

        assertEq(atkHook.seatLiquidity(0), lBefore, "taking profit burned contributed depth");
        assertEq(atkHook.rankOfId(0), 0, "TAKING PROFIT COST THE HOLDER THEIR RANK");
        emit log_named_uint("paid out of float, token0", p0);
        emit log_named_uint("paid out of float, token1", p1);

        // ...and the other half of the rule: taking the DEPTH out does cost the rank.
        (a0, a1) = atkHook.seat(0);
        vm.prank(head);
        atkHook.withdraw(0, a0, a1);
        assertLt(atkHook.seatLiquidity(0), lBefore, "the full withdrawal did not burn contributed depth");
        assertEq(atkHook.rankOfId(0), N - 1, "LEAVING DID NOT COST THE HOLDER THEIR RANK");

        _checkInvariantL("after profit-then-exit");
        _checkInvariantF("after profit-then-exit", 64);
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
}
