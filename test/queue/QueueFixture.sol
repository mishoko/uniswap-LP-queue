// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueHarness} from "./QueueHarness.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice The witness's INDEPENDENT source of "how much liquidity does this deposit mint".
///
/// @dev **IT IS A SEPARATE CONTRACT FOR ONE REASON: SO THE FIXTURE CAN `try` IT.** `QueueHook`
///      deliberately does NOT call `LiquidityAmounts.getLiquidityForAmounts` — that helper narrows
///      EACH leg to `uint128` before taking the minimum, so near a tick boundary the leg nobody
///      asked about reverts the call and every depositor is locked out at once (PITFALLS 5.76).
///      The hook reimplements the arithmetic in 256 bits instead.
///
///      That divergence is exactly what makes this helper a witness rather than a copy: it is
///      v4-periphery's own audited code, structured differently, and if the hook's reimplementation
///      picked the wrong branch, the wrong tick, or the wrong leg, the two disagree. Where the
///      helper cannot answer at all — the boundary case it is known to revert on — the witness
///      DISARMS and says so, rather than falling back to reading the hook's own number, which
///      would witness nothing while reading as coverage.
contract RefLiquidityOracle {
    function forAmounts(uint160 sqrtP, uint160 lo, uint160 hi, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(sqrtP, lo, hi, amount0, amount1);
    }
}

/// @notice Shared fixture for the Phase 1 allocator suite.
///
/// LAW 1 — the price is NEVER 1:1 and the decimals are configurable, because a unit fixture hides
/// every token0/token1 mixing bug. Phase 0 found that the reference spike ran 18/18 and therefore
/// only half-satisfied this law (PITFALLS 5.31); this fixture runs 18/6 as well.
///
/// LAW 3 (AS AMENDED) — conservation is measured on PoolManager's own ERC20 balances **net of
/// `protocolFeesAccrued`**, because accrued protocol fees sit inside PoolManager's ERC20 balance
/// until they are collected. The raw-balance form passes at 0 wei error while the position is
/// short. Solvency is asserted SEPARATELY, by really redeeming (`redeemAll`).
abstract contract QueueFixture is BaseTest {
    using StateLibrary for IPoolManager;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    /// @dev beforeAddLiquidity (1<<11) | beforeSwap (1<<7) | afterSwap (1<<6) == 0x8C0.
    /// @dev afterInitialize (1<<12) | beforeAddLiquidity (1<<11) | beforeSwap (1<<7)
    ///      | afterSwap (1<<6) == 0x18C0.
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    uint128 constant LIQ = 1_000e18;
    address constant PM_OWNER = address(0x4444);

    /// @dev Phase 4 governance parameters. τ = 10% per year is the conventional Harberger figure —
    ///      a citation rather than a number somebody picked — and `Harberger.t.sol` runs the
    ///      mechanism at several values rather than defending this one (PLAN §B.10).
    ///      `FIRM_WINDOW` is a SECURITY parameter, not an economic one: it only has to exceed the
    ///      time a holder needs to see a buyout and react to it.
    /// @dev Band half-width, now a DEPLOYMENT parameter rather than a contract constant. 960 ticks
    ///      is the fixture's choice (~+10.08%/-9.16%), kept so every pre-existing measurement stays
    ///      comparable; `Wings.t.sol` and the gas suite are what vary it.
    int24 constant BAND_HALF_WIDTH = 960;

    uint256 constant RENT_BPS = 1_000; // 10%
    uint256 constant RENT_PERIOD = 365 days;
    uint256 constant FIRM_WINDOW = 1 hours;

    /// @dev **THE TERM.** How long a seat may not voluntarily give up its rank. Mirrors
    ///      `QueueDeployBase.MIN_TENURE`; `Hygiene.t.sol::test_7_8` pins the two together, because
    ///      three copies of the shipped φ drifted apart behind a comment naming their source
    ///      (PITFALLS 5.180) and a comment is not an interlock.
    uint256 constant MIN_TENURE = 7 days;

    /// @dev φ — the priority premium, **ZERO for the shared fixture, and that is a deliberate
    ///      experimental control rather than a default worth shipping.**
    ///
    ///      At φ = 0 the Phase 7 machinery moves no VALUE: `_premiumOn` returns 0 on its first
    ///      line, so no accumulator ever advances and every claim is zero. So every one of the 205
    ///      tests written against the pre-Phase-7 contract must still pass UNCHANGED, and if one of
    ///      them moves, the premium has leaked into a path it has no business touching. That is the
    ///      only baseline against which "this is a strict extension" is a claim rather than a hope.
    ///
    ///      **It is NOT gas-free, and saying so was wrong the first time this comment was written.**
    ///      `_syncSeat` still reads two marks and two growths per settled seat, which measured
    ///      +170k on a cold 32-seat sweep. There is deliberately no `PREMIUM_BPS == 0` fast path:
    ///      it would make the code the gas suite measures a different path from the one the product
    ///      ships. `Gas.t.sol` therefore overrides this to the SHIPPING φ.
    ///
    ///      `Premium.t.sol` overrides it to exercise φ > 0 against its own reference model.
    function _premiumBps() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Storage address of seat `id`'s BALANCE word.
    ///
    ///      `q` is a dynamic array of a FOUR-slot struct since Phase 8 — `(a0, a1)` packed in the
    ///      first, `snap0`, `snap1` and `liquidity` in the next three — so element `id` starts at
    ///      `keccak(slot) + 4*id`. Two
    ///      suites poke this directly and both had the stride written into them independently; when
    ///      the struct grew from one slot to three, the copies were wrong in the same way at the
    ///      same time. It is written HERE once, and every caller reads its poke back through the
    ///      contract's own view so a future repacking fails loudly rather than silently addressing
    ///      an unrelated slot (LAW 2).
    uint256 constant SEAT_SLOTS = 4;

    function _seatSlot(uint256 id) internal view returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(hook.seatArraySlot()))) + SEAT_SLOTS * id);
    }

    /// @dev One place the constructor argument list is written. Every suite deploys through it, so
    ///      adding a parameter cannot leave one call site silently on an old shape.
    /// @dev **NOT `view`, AND THAT IS THE POINT.** These four overloads are the single place the
    ///      constructor argument list is written, so they are also the single place the witness can
    ///      learn φ and the fee tier the hook was actually built with — WITHOUT reading them back
    ///      off the deployed contract, which would make a constructor that stored the wrong number
    ///      invisible to the witness meant to catch it.
    /// @dev The governance bundle every fixture builds. **`MIN_TENURE` IS OVERRIDABLE AND DEFAULTS
    ///      TO THE SHIPPED VALUE**, so the term is LIVE in every suite rather than switched off in
    ///      the fixtures and tested in one place — a fixture that disables the feature under test is
    ///      the shape of LAW 1's 1:1 price and 18/18 decimals. Suites that need to withdraw simply
    ///      warp past it, which is what a real holder does.
    function _minTenure() internal view virtual returns (uint256) {
        return MIN_TENURE;
    }

    function _gov(uint256 bps, uint256 period, uint256 window, uint256 phi)
        internal
        view
        returns (QueueHook.Governance memory)
    {
        return QueueHook.Governance({
            rentBps: bps,
            rentPeriod: period,
            firmWindow: window,
            premiumBps: phi,
            minTenure: _minTenure()
        });
    }

    function _ctorArgs(address[] memory roster) internal returns (bytes memory) {
        return _ctorArgs(roster, FEE);
    }

    /// @dev The fee-tier overload: a hook fixes its pool at construction, so a suite that needs a
    ///      pool on a different tier needs a hook built for that tier.
    function _ctorArgs(address[] memory roster, uint24 fee) internal returns (bytes memory) {
        refPhi = _premiumBps();
        refFee = fee;
        return abi.encode(
            poolManager,
            c0,
            c1,
            fee,
            SPACING,
            BAND_HALF_WIDTH,
            roster,
            _gov(RENT_BPS, RENT_PERIOD, FIRM_WINDOW, _premiumBps())
        );
    }

    /// @dev The φ overload. `Premium.t.sol` needs TWO hooks alive at once — one with the premium on
    ///      and one with it off — because the only honest way to state what the premium does is as a
    ///      difference against the same pool without it. A per-contract `_premiumBps()` cannot
    ///      express that, and building the argument list by hand at the call site is the exact
    ///      duplication that broke `Controls.t.sol` and `QueueDeployBase.sol`.
    function _ctorArgsPremium(address[] memory roster, uint256 premiumBps) internal returns (bytes memory) {
        refPhi = premiumBps;
        refFee = FEE;
        return abi.encode(
            poolManager, c0, c1, FEE, SPACING, BAND_HALF_WIDTH, roster, _gov(RENT_BPS, RENT_PERIOD, FIRM_WINDOW, premiumBps)
        );
    }

    /// @dev The governance-parameter overload, for the τ sweep. §B.10 is explicit that τ must not be
    ///      defended as a discovered constant, so the suite has to be able to vary it.
    function _ctorArgs(address[] memory roster, uint256 bps, uint256 period, uint256 window)
        internal
        returns (bytes memory)
    {
        refPhi = _premiumBps();
        refFee = FEE;
        return
            abi.encode(poolManager, c0, c1, FEE, SPACING, BAND_HALF_WIDTH, roster, _gov(bps, period, window, _premiumBps()));
    }

    Currency c0;
    Currency c1;
    QueueHarness hook;
    PoolKey k;
    /// @dev The witness's anchor for the price curve: spot and band liquidity as they were when
    ///      the swap began. Written by `_swapFrom` before it routes, read by `_refCurve`.
    uint160 refSqrtP0;
    uint128 refLiq0;

    uint8 dec0 = 18;
    uint8 dec1 = 18;
    uint160 startPrice;

    // ---- the INDEPENDENT witness. Written from PLAN §B.5, deliberately not shaped like src/.
    ///     `ref0`/`ref1` are indexed by SEAT ID; `refOrder` is the witness's own copy of the rank
    ///     permutation, kept as a plain array precisely because the contract keeps it as a packed
    ///     word. Two differently-shaped representations of the order cannot be wrong in the same way.
    uint256[] ref0;
    uint256[] ref1;
    uint256[] refOrder;
    uint256 refC0;
    uint256 refC1;

    // ---- THE PREMIUM HALF OF THE WITNESS (Phase 8). See `_refAccrue` for the whole argument.
    //
    // `refL` is the witness's own copy of `liquidityContributed`, DERIVED from deposit history and
    // never read from the hook — it is the premium's denominator, so a witness that read it would
    // be witnessing nothing at the step that matters most.
    uint256[] refL;
    uint256 refStandingL;
    uint256 refUnattributedL;
    uint256 refShortfallL;
    // The witness's PENDING premium per seat: what the seat has earned and not yet been credited.
    uint256[] refPend0;
    uint256[] refPend1;
    // `k` — accruals in each direction since this seat's mark was last advanced. It is the whole
    // of the bound in `_assertPremiumClaim`, so it is tracked rather than estimated.
    uint256[] refK0;
    uint256[] refK1;
    uint256 refHeld0;
    uint256 refHeld1;
    // The denominator of the most recent accrual, kept only so a failure can PRINT it.
    uint256 refWLast0;
    uint256 refWLast1;
    /// @dev φ and the fee tier AS THE TEST PASSED THEM TO THE CONSTRUCTOR. Deliberately not
    ///      `hook.PREMIUM_BPS()`: reading the immutable back would make a constructor that stored
    ///      the wrong number invisible to the witness that is supposed to catch it.
    uint256 refPhi;
    uint24 refFee;
    /// @dev False once the witness has hit a deposit whose minted liquidity it could not derive
    ///      independently. Every suite that leans on the premium split asserts this is still true —
    ///      a witness that silently fell back to the hook's own number reads as coverage and is not.
    bool refPremiumArmed = true;
    /// @dev Premium a seat had earned and had ERASED by `_settlePremium` advancing its mark without
    ///      settling it first. Asserted zero. See `_refAccrue`.
    uint256 refErased0;
    uint256 refErased1;
    /// @dev **THE ACCUMULATED ALLOWANCE, AND IT IS DERIVED PER SETTLEMENT RATHER THAN PICKED.**
    ///      The `[-1, k]` bound in `_assertPremiumClaim` is the residual of ONE interval. A seat
    ///      that is settled five times between two comparisons has closed five intervals, and the
    ///      wei each of them rounded away is already inside the witness's ledger. So `_refSettle`
    ///      folds the interval it closes into these, and `_refResyncPremium` — which re-bases the
    ///      ledger onto the contract's — is the only thing that clears them. Growth is at most ONE
    ///      wei per settlement per seat, which is why a suite that checks after every swap keeps
    ///      essentially the raw `k` bound.
    uint256[] refDriftLo0;
    uint256[] refDriftHi0;
    uint256[] refDriftLo1;
    uint256[] refDriftHi1;
    RefLiquidityOracle refOracle;

    // ---- conservation ground truth, measured on PoolManager, net of protocol fees
    uint256 expT0;
    uint256 expT1;

    // ---- bookkeeping for structural assertions
    uint256 lastTouched;
    uint256 lastPfDelta;
    /// @dev What THE HOOK actually credited to the ledger on the input token for the last swap.
    ///      Assertions about the hook's arithmetic must use THIS, never `lastPfDelta` — that one is
    ///      the fixture's own measurement, and comparing it to another fixture-side number is
    ///      tautological. (Caught by executing the old mechanism against an earlier draft.)
    uint256 lastHookCreditedIn;
    /// @dev Non-zero for the duration of one `_swapExactOut`, and zero everywhere else. See there.
    uint256 refExactOut;

    function _deployTokens() internal {
        MockERC20 t0 = new MockERC20("Token A", "A", dec0);
        MockERC20 t1 = new MockERC20("Token B", "B", dec1);
        if (t0 > t1) (t0, t1) = (t1, t0);
        (c0, c1) = (Currency.wrap(address(t0)), Currency.wrap(address(t1)));
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(i == 0 ? c0 : c1));
            // RAW units, deliberately NOT scaled by decimals: v4 works in raw units, and a
            // decimals-scaled mint starves the 6-decimal side of the 18/6 fixture.
            t.mint(address(this), 1e30);
            t.approve(address(permit2), type(uint256).max);
            t.approve(address(swapRouter), type(uint256).max);
            permit2.approve(address(t), address(positionManager), type(uint160).max, type(uint48).max);
            permit2.approve(address(t), address(poolManager), type(uint160).max, type(uint48).max);
        }
    }

    /// @dev Phase 3: the roster is fixed at construction, so the fixture must decide up front how
    ///      many seats exist. `_syntheticRoster` names them; nothing can create one afterwards.
    function _deployHook(uint160 nonce, uint256 nSeats) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(_syntheticRoster(nSeats)), a);
        hook = QueueHarness(a);
        _fundHook(a);
    }

    /// @dev Distinct, non-zero, deterministic holders for the allocator suites, which care about
    ///      seat ARITHMETIC and not about who owns what.
    function _syntheticRoster(uint256 n) internal pure returns (address[] memory r) {
        r = new address[](n);
        for (uint256 i; i < n; i++) {
            r[i] = address(uint160(0x5EA700 + i));
        }
    }

    function _fundHook(address a) internal {
        MockERC20(Currency.unwrap(c0)).mint(a, 1e30);
        MockERC20(Currency.unwrap(c1)).mint(a, 1e30);
    }

    function _open(uint256[] memory bps) internal {
        _openRange(bps, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));
    }

    /// @dev Seed at the concentrated band `_afterInitialize` snapped. Production has no other
    ///      range. Tests that need a full-range blob (packing fuzz, reentrancy) still go through
    ///      `_open` / `forceRange`. Wings tests MUST use this: a full-range position has no
    ///      disjoint ticks left for an outside LP.
    function _openBand(uint256[] memory bps) internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, startPrice);
        (,, int24 tl, int24 tu) = hook.pool();
        _seedAt(bps, tl, tu);
    }

    /// @dev The same, over a CHOSEN range. It exists for one claim: `PITFALLS.md` 5.17 calls thin
    ///      full-range depth "the sharpest unanswered attack" and adds that the range is a
    ///      reversible design choice rather than a v4 constraint. That second half was ANALYSIS
    ///      until `Allocator.t.sol`'s range-independence test used this to execute it.
    function _openRange(uint256[] memory bps, int24 tl, int24 tu) internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, startPrice);
        _seedAt(bps, tl, tu);
    }

    /// @dev Clear every witness array at once. They are parallel and indexed by SEAT ID, so a
    ///      reset that missed one would leave the premium half describing a previous pool.
    function _refReset() internal {
        delete ref0;
        delete ref1;
        delete refOrder;
        delete refL;
        delete refPend0;
        delete refPend1;
        delete refK0;
        delete refK1;
        delete refDriftLo0;
        delete refDriftHi0;
        delete refDriftLo1;
        delete refDriftHi1;
        refC0 = 0;
        refC1 = 0;
        refStandingL = 0;
        refUnattributedL = 0;
        refShortfallL = 0;
        refHeld0 = 0;
        refHeld1 = 0;
        refWLast0 = 0;
        refWLast1 = 0;
        refErased0 = 0;
        refErased1 = 0;
        refPremiumArmed = true;
    }

    function _refPushSeat() internal {
        refL.push(0);
        refPend0.push(0);
        refPend1.push(0);
        refK0.push(0);
        refK1.push(0);
        refDriftLo0.push(0);
        refDriftHi0.push(0);
        refDriftLo1.push(0);
        refDriftHi1.push(0);
    }

    /// @notice Move past `MIN_TENURE` so a freshly built roster is free to leave.
    ///
    /// @dev **CALLED AT THE END OF EVERY ROSTER-BUILDING SETUP, AND THAT IS DELIBERATE.** The term
    ///      is LIVE in every suite rather than switched off in the fixtures: a fixture that disables
    ///      the feature under test is LAW 1's 1:1 price one dimension over, and the whole point of
    ///      `MIN_TENURE` is that it changes what `withdraw` does. Aging the roster puts it in the
    ///      state a real holder is in — funded a while ago — instead of pretending the guard is not
    ///      there.
    ///
    ///      Call it BEFORE any self-price is posted. `_setPrice` stamps `lastSettled` when a price
    ///      comes into existence, so aging first cannot accrue rent behind a test's back; aging
    ///      after would.
    /// @dev True while no seat has a self-price, i.e. while warping cannot accrue rent anywhere.
    function _noSelfPricesPosted() internal view returns (bool) {
        uint256 n = hook.seatCount();
        for (uint256 i; i < n; i++) {
            (uint256 price,,,,) = hook.leaseOf(i);
            if (price != 0) return false;
        }
        return true;
    }

    function _ageRoster() internal {
        vm.warp(block.timestamp + MIN_TENURE + 1);
    }

    function _seedAt(uint256[] memory bps, int24 tl, int24 tu) private {
        (uint256 s0, uint256 s1) = hook.seed(k, tl, tu, LIQ, bps);
        require(s0 != s1, "LAW 1: fixture is unit-priced");

        // **AGE THE ROSTER PAST ITS TERM.** `MIN_TENURE` is live in every suite — a fixture that
        // switched the feature off would be LAW 1's 1:1 price one dimension over — so the seeded
        // seats are aged here, once, to the state a real holder is in: funded a while ago and free
        // to leave. Suites that test the TERM itself do not use this path, or warp their own way
        // back inside it (`Evacuation.t.sol::test_8_21`).
        //
        // It runs BEFORE any self-price is posted, so it cannot accrue rent behind a test's back:
        // `_setPrice` stamps `lastSettled` when the price comes into existence.
        _ageRoster();

        _refAdoptSeed(bps, LIQ);
        expT0 = s0;
        expT1 = s1;
        (uint256 t0, uint256 t1) = hook.totals();
        require(t0 == s0 && t1 == s1, "seed split lost a wei");
    }

    /// @notice Rebuild the whole witness from a freshly seeded roster.
    ///
    /// @dev **ONE PLACE, BECAUSE THERE USED TO BE TWO.** `_seedAt` built this inline and
    ///      `ProtocolFee.t.sol::test_5_3` — which seeds its own zero-lpFee pool — hand-rolled a
    ///      copy of the same loop. The witness has more parallel arrays than that copy knew about,
    ///      so the copy silently left them empty and the first swap indexed past the end of one.
    ///      That is PITFALLS 5.37/5.50/5.52's shape exactly: a rule kept in two places, right in
    ///      only one of them.
    ///
    ///      **THE WITNESS APPORTIONS THE SEEDED DEPTH ITSELF.** `seed()` is test-only, so this is
    ///      the witness's own reading of the same rule — the roster's share of one `_mintPosition`,
    ///      split by the same bps, with a remainder line closing it to the wei. Without it every
    ///      seeded seat weighs zero, `w == 0` on every accrual, and the premium is silently
    ///      switched off in every suite built on `seed()`.
    function _refAdoptSeed(uint256[] memory bps, uint128 liq) internal {
        _refReset();
        uint256 accL;
        for (uint256 i; i < bps.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            ref0.push(a0);
            ref1.push(a1);
            refOrder.push(i); // the founding order is the identity permutation
            _refPushSeat();
            uint256 li = i == bps.length - 1 ? uint256(liq) - accL : FullMath.mulDiv(liq, bps[i], 10_000);
            accL += li;
            refL[i] = li;
        }
        refStandingL = liq;
    }

    /// @dev Aggregate flows measured on POOLMANAGER'S OWN ERC20 BALANCES, net of the protocol fee
    ///      accrued by THIS swap. Nothing here reads the hook's bookkeeping — that is the thing
    ///      under test.
    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint256 inAmt, uint256 outAmt) {
        return _swapFrom(address(this), zeroForOne, amountIn);
    }

    /// @dev The same measurement with a chosen trader. Phase 6 needs it: several adversarial tests
    ///      put the ATTACKER on both sides of the trade, and a swap the witness does not see makes
    ///      every later `_check` fail for the wrong reason.
    function _swapFrom(address who, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 inAmt, uint256 outAmt)
    {
        uint256 p0 = _pmBal(c0);
        uint256 p1 = _pmBal(c1);
        uint256 pf0 = poolManager.protocolFeesAccrued(c0);
        uint256 pf1 = poolManager.protocolFeesAccrued(c1);

        uint256[] memory before = _snapshot(zeroForOne);
        (uint256 lt0, uint256 lt1) = hook.totals();

        // The price curve is anchored where the swap STARTED, so the witness has to read it before
        // the swap, from PoolManager, exactly as `_beforeSwap` does. Liquidity is read here too: a
        // swap never changes it, but a deposit inside the same test would, and reading it after
        // would then price the fill against a band that did not exist while it happened.
        // Held in storage, not on the stack: `_swapFrom` is already at the stack limit without
        // `via_ir`, and two more locals here is what tips it over.
        (refSqrtP0,,,) = poolManager.getSlot0(k.toId());
        refLiq0 = hook.positionLiquidity();

        _routeSwap(who, zeroForOne, amountIn);

        uint256 n0 = _pmBal(c0);
        uint256 n1 = _pmBal(c1);
        lastPfDelta = zeroForOne ? poolManager.protocolFeesAccrued(c0) - pf0 : poolManager.protocolFeesAccrued(c1) - pf1;

        if (zeroForOne) {
            (inAmt, outAmt) = (n0 - p0 - lastPfDelta, p1 - n1);
            expT0 += inAmt;
            expT1 -= outAmt;
        } else {
            (inAmt, outAmt) = (n1 - p1 - lastPfDelta, p0 - n0);
            expT1 += inAmt;
            expT0 -= outAmt;
        }

        {
            (uint256 nt0, uint256 nt1) = hook.totals();
            lastHookCreditedIn = zeroForOne ? nt0 - lt0 : nt1 - lt1;
        }
        lastTouched = _countChanged(zeroForOne, before);
        _refAllocate(zeroForOne, inAmt, outAmt);
    }

    // ------------------------------------------------------------------- the independent reference

    /// @dev Written from PLAN §B.5's prose, not from `src/queue/libraries/Allocation.sol`. If both
    ///      are wrong in the same way, conservation against PoolManager still catches it — that is
    ///      the point of two mismatched witnesses rather than one.
    ///
    ///      Phase 0 established why this matters concretely: a one-wei misallocation leaves the
    ///      AGGREGATE totals tying out perfectly and is only visible seat by seat (PITFALLS 5.29).
    function _refAllocate(bool zeroForOne, uint256 amtIn, uint256 amtOut) internal {
        bool outIsOne = zeroForOne;
        uint256 begin = outIsOne ? refC1 : refC0;

        // THE DEGENERATE FILL: the pool took input and paid nothing out. No seat gives anything
        // up, so the whole input is credited to the seat the fill would have begun at — AND the
        // INCOMING token's cursor is pulled back to that rank, because §B.6's rule is that a cursor
        // must never LEAD a funded seat and this path has just funded one. (Phase 6 found the hook
        // crediting without the pull-back; the rule is stated in §B.6, so the witness carries it
        // too, written from the prose rather than from `src/`.)
        if (amtOut == 0) {
            if (amtIn != 0 && refOrder.length != 0) {
                uint256 rank = begin < refOrder.length ? begin : 0;
                uint256 at = refOrder[rank];
                // SETTLE, for the same reason the hook does: this is one of the six sites that
                // write a seat balance, so the seat's premium claim is cashed at the weight it held
                // before the credit lands. No pot is withheld here and no accrual happens — the
                // whole input is credited, which is what front-first means when there is one
                // claimant — so there is nothing for a payer-exclusion rule to do (test_7_15).
                _refSettle(at);
                if (outIsOne) {
                    ref0[at] += amtIn;
                    if (rank < refC0) refC0 = rank;
                } else {
                    ref1[at] += amtIn;
                    if (rank < refC1) refC1 = rank;
                }
            }
            return;
        }

        // THE PREMIUM COMES OFF THE TOP, exactly as `_allocate` takes it off before
        // `Allocation.init`. The witness computes it from φ and the fee tier THE TEST PASSED to the
        // constructor and from `amtIn` as measured on PoolManager — never from the hook's own
        // numbers, and never as `amtIn - lastHookCreditedIn`, which would make "the pot is φ of the
        // fee" an identity instead of a claim.
        uint256 pot = _refPremiumOn(amtIn);
        amtIn -= pot; // the parameter is REUSED: this function is at the stack limit without via_ir

        uint256 owed = amtOut;
        uint256 handed;
        uint256 lastIdx;
        bool touchedAny;

        // RANKS, not ids. The witness resolves rank -> seat through its own `refOrder` array; the
        // contract resolves it through a packed word. Both must agree seat by seat.
        for (uint256 i = begin; i < refOrder.length; i++) {
            if (owed == 0) break;
            uint256 id = refOrder[i];
            // **SETTLE BEFORE THE EMPTY TEST, NOT AFTER IT**, and settle every rank the walk
            // reaches including the ones it steps over. A settlement credits the token OPPOSITE the
            // weight, so a seat sitting at zero of the outgoing token is not necessarily empty — it
            // may merely be unsettled, and skipping it would be the theft of rank INVARIANT C
            // exists to prevent (test_7_4). The hook enters `_syncBal` before its own `continue`.
            _refSettle(id);
            uint256 have = outIsOne ? ref1[id] : ref0[id];
            if (have == 0) continue;

            uint256 t = have >= owed ? owed : have;
            owed -= t;
            // §B.5 as amended: a seat is credited the input the band absorbs over the PRICE
            // SEGMENT its own take spans. Expressed cumulatively -- G(T) = amtIn * W(T)/W(amtOut),
            // this seat gets G(T_i) - G(T_{i-1}) -- and the last filled seat takes the remainder.
            uint256 g = _refGive(outIsOne, amtIn, amtOut, owed, t, handed);
            handed += g;

            if (outIsOne) {
                ref1[id] = have - t;
                ref0[id] += g;
            } else {
                ref0[id] = have - t;
                ref1[id] += g;
            }
            lastIdx = i;
            touchedAny = true;
        }
        require(owed == 0, "reference underflow");

        // **THE CURSOR AND THE PAYER SET ARE TWO DIFFERENT NUMBERS AND THEY ARE NOW COMPUTED
        // SEPARATELY. That separation IS the fix this witness models.**
        //
        // `adv` is the hook's `next`: the last rank the fill reached, or ONE PAST it when that seat
        // was exactly exhausted. It is a CURSOR — where the next fill in this direction starts.
        // Handing it to the premium as the far end of the payer set was the erasure defect: on an
        // exact exhaustion it names a rank the walk never visited, and marking that rank destroys
        // its claim on every EARLIER accrual (`test_W6`/`test_W7`, 7.17e19 wei).
        //
        // `payerEnd` is the hook's `i` on loop exit: ONE PAST the last rank actually touched, in
        // every case, exhausted or not. The payer set is `[begin, payerEnd)` — a half-open range,
        // written that way here rather than as an inclusive `last` because `touchedAny == false`
        // would underflow an inclusive form at `begin == 0`.
        uint256 adv = begin;
        uint256 payerEnd = begin;
        if (touchedAny) {
            uint256 lastId = refOrder[lastIdx];
            adv = (outIsOne ? ref1[lastId] : ref0[lastId]) == 0 ? lastIdx + 1 : lastIdx;
            payerEnd = lastIdx + 1;
            if (outIsOne) {
                refC1 = adv;
                if (begin < refC0) refC0 = begin;
            } else {
                refC0 = adv;
                if (begin < refC1) refC1 = begin;
            }
        }
        _refAccrue(outIsOne, pot, begin, payerEnd);
    }

    /// @dev What one seat is credited. Split out of `_refAllocate` only because that function is at
    ///      the stack limit; the rule is §B.5's, unchanged.
    ///
    ///      `amtOut - owed` is the outgoing token sourced through the END of this seat's segment,
    ///      so `G(amtOut - owed) - handed` is exactly the segment this seat absorbed.
    function _refGive(bool outIsOne, uint256 amtIn, uint256 amtOut, uint256 owed, uint256 t, uint256 handed)
        internal
        view
        returns (uint256)
    {
        if (owed == 0) return amtIn - handed; // the last filled seat closes the sum to the wei
        uint256 wTot = _refCurve(outIsOne, amtOut);
        // No curve to read (an empty band): §B.5's stated fallback is the swap's average price.
        if (wTot == 0) return FullMath.mulDiv(amtIn, t, amtOut);
        return FullMath.mulDiv(amtIn, _refCurve(outIsOne, amtOut - owed), wTot) - handed;
    }

    /// @dev The witness's own price curve: input the band absorbs over its first `outAmt` of output.
    ///
    ///      **WHAT THIS IS AND IS NOT AN INDEPENDENT WITNESS OF, stated plainly so nobody later
    ///      claims more from it than it gives.** The ALLOCATION RULE is independent — the cumulative
    ///      form, the remainder line, the cursors, and the band clamp are written here from §B.5's
    ///      prose and are composed differently from `_allocate`. The FIXED-POINT PRIMITIVES are not:
    ///      this calls v4's `SqrtPriceMath`, the same library the hook calls, for the same reason
    ///      the witness has always called v4's `FullMath` rather than re-deriving 512-bit division.
    ///      A rounding bug inside `SqrtPriceMath` would therefore be invisible to BOTH — but that
    ///      is v4's own audited arithmetic, it is not the thing under test, and conservation against
    ///      PoolManager's balances still binds regardless of what this function returns.
    ///
    ///      What it DOES catch, and what nothing else in the suite would: the hook walking from the
    ///      wrong anchor, clamping to the wrong edge, reading the curve in the wrong direction, or
    ///      pricing a seat at a segment that is not its own. Those are the ways this can be wrong.
    function _refCurve(bool outIsOne, uint256 outAmt) internal view returns (uint256) {
        (uint160 sqrtP0, uint128 liq) = (refSqrtP0, refLiq0);
        if (liq == 0 || outAmt == 0) return 0;
        (,, int24 lower, int24 upper) = hook.pool();
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);

        // Where the swap met the band, and which edge it is walking toward.
        uint160 from = outIsOne ? (sqrtP0 < hi ? sqrtP0 : hi) : (sqrtP0 > lo ? sqrtP0 : lo);
        uint160 edge = outIsOne ? lo : hi;
        if (outIsOne ? from <= edge : from >= edge) return 0;

        uint256 room = outIsOne
            ? SqrtPriceMath.getAmount1Delta(edge, from, liq, false)
            : SqrtPriceMath.getAmount0Delta(from, edge, liq, false);

        uint160 to;
        if (outAmt >= room) {
            to = edge;
        } else {
            to = outIsOne
                ? SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(from, liq, outAmt, false)
                : SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(from, liq, outAmt, false);
            if (outIsOne ? to < edge : to > edge) to = edge;
        }

        return outIsOne
            ? SqrtPriceMath.getAmount0Delta(to, from, liq, false)
            : SqrtPriceMath.getAmount1Delta(from, to, liq, false);
    }

    // --------------------------------------------------- THE PREMIUM HALF OF THE WITNESS (Phase 8)
    //
    // **WHAT THIS IS, AND THE ONE THING IT DELIBERATELY DOES NOT DO.**
    //
    // Until this existed, `_refAllocate` had never modelled the priority premium, so at φ > 0 the
    // per-seat SPLIT rested entirely on `Premium.t.sol`'s own controls — and this project has been
    // wrong about that mechanism twice (the X64 accumulator that made the premium inert on the
    // shipped 18/6 pool, PITFALLS 5.124/5.126; and the inventory weight that let a one-wei holder
    // take an entire pot, test_7_14).
    //
    // **THE WITNESS DOES NOT REIMPLEMENT THE ACCUMULATOR, AND THAT IS THE WHOLE DESIGN.** The hook
    // takes TWO floors: an inner one in `_accruePremium` (`inc = floor(total·2^128 / w)`) and an
    // outer one in `_claims` (`owed = floor(L_i·Σinc / 2^128)`). A witness that copied `inc` and
    // merely took k floors where the hook takes one would be measuring the accumulator against
    // itself at exactly the step Phase 8 changed — LAW 5's second corollary, an instrument that
    // agrees with its artifact by construction. So the witness computes the TRUE RATIONAL share,
    // per accrual, with no fixed point anywhere:
    //
    //     x_j = total_j · L_i / w_j        W = Σ_j floor(x_j)
    //
    // and the residual between that and the hook's `C` is BOUNDED IN CLOSED FORM — see
    // `_assertPremiumClaim`, which is where the derivation lives. Nothing here is a tolerance.

    /// @notice φ of the LP fee — what this swap hands to the seats it jumped.
    ///
    /// @dev Computed from φ and the fee tier **the test passed to the constructor** and from
    ///      `amtIn` as measured on PoolManager. Deliberately NOT `amtIn - lastHookCreditedIn`,
    ///      which would derive the pot from the hook's own bookkeeping and turn "the pot is φ of
    ///      the fee" (test_7_4) into an identity that cannot fail.
    function _refPremiumOn(uint256 amtIn) internal view returns (uint256) {
        if (refPhi == 0) return 0;
        return FullMath.mulDiv(amtIn, uint256(refFee) * refPhi, 1e6 * 10_000);
    }

    /// @notice The witness's copy of `_syncSeat`: cash the pending claim, close the interval.
    ///
    /// @dev The interval is closed UNCONDITIONALLY, including when the claim was zero. `_syncSeat`
    ///      writes both marks whatever the claim was, and a witness that left one open would let
    ///      the same growth be claimed twice later against a larger weight — the defect mutant M83
    ///      introduced and `test_7_8` catches.
    function _refSettle(uint256 id) internal {
        if (refPend0[id] != 0) {
            ref0[id] += refPend0[id];
            refPend0[id] = 0;
        }
        if (refPend1[id] != 0) {
            ref1[id] += refPend1[id];
            refPend1[id] = 0;
        }
        _refCloseInterval(id);
    }

    /// @dev Close both intervals and BANK what they were allowed to round away. Every place that
    ///      resets `k` goes through here, because the wei an interval rounded is now inside the
    ///      witness's ledger and the next comparison has to still allow for it.
    function _refCloseInterval(uint256 id) internal {
        if (refK0[id] != 0) {
            refDriftHi0[id] += refK0[id];
            refDriftLo0[id] += 1 + FullMath.mulDiv(refK0[id], refL[id], 1 << 128);
            refK0[id] = 0;
        }
        if (refK1[id] != 0) {
            refDriftHi1[id] += refK1[id];
            refDriftLo1[id] += 1 + FullMath.mulDiv(refK1[id], refL[id], 1 << 128);
            refK1[id] = 0;
        }
    }

    /// @dev The two-sided allowance for one seat and one token: the intervals already banked, plus
    ///      the one currently open. Derivation in `_assertPremiumClaim`.
    function _refBound(uint256 id, bool tok0) internal view returns (uint256 lo, uint256 hi) {
        uint256 kAcc = tok0 ? refK0[id] : refK1[id];
        lo = tok0 ? refDriftLo0[id] : refDriftLo1[id];
        hi = (tok0 ? refDriftHi0[id] : refDriftHi1[id]) + kAcc;
        if (kAcc != 0) lo += 1 + FullMath.mulDiv(kAcc, refL[id], 1 << 128);
    }

    /// @notice The witness's copy of `_settlePremium` + `_accruePremium`, written from the rule.
    ///
    /// @dev `payerEnd` is the hook's `i` on loop exit: ONE PAST the last rank the fill actually
    ///      touched. The payer set is ranks **[begin, payerEnd)** — the seats this fill just paid do
    ///      not pay themselves. It used to be the hook's `next`, which is a CURSOR and is one past
    ///      the walk on an exact exhaustion; the witness modelled that faithfully, counted the
    ///      resulting destruction of an untouched seat's claim in `refErased0/1`, and `test_W6`/
    ///      `test_W7` measured it at 7.17e19 wei. The hook no longer hands the cursor over, so
    ///      **`refErased` should now stay at zero for every fill** — it is kept, not deleted,
    ///      because a counter that reads zero because a defect is fixed is evidence, and one that
    ///      starts reading non-zero again is the regression alarm.
    ///
    ///      **THE THREE BRANCHES, AND WHY THE MIDDLE ONE EXISTS.**
    ///
    ///        * `excluded == refStandingL` and there IS depth — the fill reached every standing
    ///          seat. "The payer does not pay itself" has no meaning here: there is no seat that did
    ///          not pay, so there is no seat the rule protects. The pot is divided over the FULL
    ///          `refStandingL`, everybody included, **and no mark moves** — full denominator plus
    ///          unmoved marks is the only self-consistent pairing, exactly as in `_settlePremium`.
    ///          Modelling the old HOLD here would make the witness agree with a contract that
    ///          bricks (`test_M7f`).
    ///        * `refStandingL == 0` — genuinely nobody to pay, because nobody has contributed
    ///          depth. HELD, folded into the next accrual that has a recipient, never destroyed
    ///          (`test_7_12`/`test_7_13`, and control N8 for what dropping it looks like).
    ///        * otherwise — the ordinary exclusion.
    ///
    ///      **THE MARK LOOP IS NOT AN AFTERTHOUGHT.** On the ordinary branch `_settlePremium`
    ///      advances the payers' marks whether or not anything accrued, because it runs after
    ///      `_accruePremium` returns and does not look at what that call decided.
    function _refAccrue(bool outIsOne, uint256 pot, uint256 begin, uint256 payerEnd) internal {
        uint256 n = refOrder.length;
        if (n == 0) return;
        if (payerEnd > n) payerEnd = n;

        bool[] memory payer = new bool[](refL.length);
        uint256 excluded;
        for (uint256 r = begin; r < payerEnd; r++) {
            uint256 id = refOrder[r];
            payer[id] = true;
            excluded += refL[id];
        }

        uint256 total = pot + (outIsOne ? refHeld0 : refHeld1);
        uint256 w = refStandingL - excluded;
        if (outIsOne) {
            refWLast0 = w;
        } else {
            refWLast1 = w;
        }

        // THE WHOLE-BOOK SWEEP. Full denominator, everybody paid, marks untouched — so this returns
        // BEFORE the mark loop at the bottom, which is the half that makes it conserve.
        if (w == 0 && refStandingL != 0) {
            if (total == 0) return;
            if (outIsOne) {
                refHeld0 = 0;
            } else {
                refHeld1 = 0;
            }
            for (uint256 id; id < refL.length; id++) {
                if (refL[id] == 0) continue;
                uint256 share = FullMath.mulDiv(total, refL[id], refStandingL);
                if (outIsOne) {
                    refPend0[id] += share;
                    refK0[id] += 1;
                } else {
                    refPend1[id] += share;
                    refK1[id] += 1;
                }
            }
            return;
        }

        if (total != 0) {
            if (w == 0) {
                // Nobody has contributed depth at all. The wei has left the allocation, so it is
                // HELD and folded into the next accrual that has a recipient — never destroyed
                // (test_7_12 / test_7_13, and control N8 for what dropping it looks like).
                if (outIsOne) {
                    refHeld0 = total;
                } else {
                    refHeld1 = total;
                }
            } else {
                // KNOWN ANSWER, CHECKED RATHER THAN ASSUMED. Production also holds when the
                // accumulator increment floors to zero, which at X128 needs `w > total·2^128` and is
                // unreachable for `uint128`-bounded balances. If that branch ever becomes live the
                // witness stops being a model of this contract, so it says so out loud instead of
                // drifting silently.
                if (total < (1 << 128)) {
                    require(
                        FullMath.mulDiv(total, 1 << 128, w) != 0,
                        "witness: the hook HELD a pot with a live weight -- the inc==0 branch is live"
                    );
                }
                if (outIsOne) {
                    refHeld0 = 0;
                } else {
                    refHeld1 = 0;
                }
                for (uint256 id; id < refL.length; id++) {
                    if (payer[id] || refL[id] == 0) continue;
                    uint256 share = FullMath.mulDiv(total, refL[id], w);
                    if (outIsOne) {
                        refPend0[id] += share;
                        refK0[id] += 1;
                    } else {
                        refPend1[id] += share;
                        refK1[id] += 1;
                    }
                }
            }
        }

        for (uint256 r = begin; r < payerEnd; r++) {
            uint256 id = refOrder[r];
            if (outIsOne) {
                refErased0 += refPend0[id];
                refPend0[id] = 0;
                if (refK0[id] != 0) {
                    refDriftHi0[id] += refK0[id];
                    refDriftLo0[id] += 1 + FullMath.mulDiv(refK0[id], refL[id], 1 << 128);
                    refK0[id] = 0;
                }
            } else {
                refErased1 += refPend1[id];
                refPend1[id] = 0;
                if (refK1[id] != 0) {
                    refDriftHi1[id] += refK1[id];
                    refDriftLo1[id] += 1 + FullMath.mulDiv(refK1[id], refL[id], 1 << 128);
                    refK1[id] = 0;
                }
            }
        }
    }

    /// @notice The witness's OWN `liquidityContributed` for a deposit, derived not read.
    ///
    /// @dev `liquidityContributed` is the premium's denominator, so a witness that read
    ///      `seatLiquidity()` would be witnessing nothing at the step that decides who gets paid.
    ///      It is derived through `RefLiquidityOracle` — v4-periphery's own helper, which is NOT
    ///      what the hook calls (see that contract's docblock).
    ///
    ///      Returns `ok == false` in the two states where the helper cannot answer and the witness
    ///      would have to guess: the near-boundary leg overflow that made the helper unusable for
    ///      production in the first place (PITFALLS 5.76), and the `MAX_LIQUIDITY_PER_TICK` clamp.
    ///      The caller DISARMS on either. It never falls back to the hook's own number: a silent
    ///      fallback reads as coverage and proves nothing.
    function _refMintL(uint256 amount0, uint256 amount1) internal returns (uint128 dl, bool ok) {
        if (address(refOracle) == address(0)) refOracle = new RefLiquidityOracle();
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        (,, int24 lower, int24 upper) = hook.pool();
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        try refOracle.forAmounts(sqrtP, lo, hi, amount0, amount1) returns (uint128 l) {
            uint128 room = Pool.tickSpacingToMaxLiquidityPerTick(SPACING) - hook.positionLiquidity();
            if (l > room) return (0, false);
            return (l, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice The witness's copy of `_chargeBurn`, on a burn it measured at the POSITION.
    ///
    /// @dev `burned` is `Δ positionLiquidity` — a position-level quantity, not a seat-level one, and
    ///      cross-checked by INVARIANT L. `_payOut`'s float sizing is not reproducible in a fixture
    ///      (see `_withdrawTracked`), so that one number is read; the ATTRIBUTION — which seat is
    ///      charged, and the cap at what it actually contributed — is the witness's own rule, and it
    ///      is the half a mutation would change.
    function _refBurn(uint256 id, uint256 burned) internal {
        if (burned == 0) return;
        uint256 fromSeat = burned > refL[id] ? refL[id] : burned;
        refL[id] -= fromSeat;
        refStandingL -= fromSeat;
        uint256 rest = burned - fromSeat;
        uint256 fromPot = rest > refUnattributedL ? refUnattributedL : rest;
        refUnattributedL -= fromPot;
        refShortfallL += rest - fromPot;
    }

    /// @notice Push idle float into the position and keep the witness's depth ledger in step.
    /// @dev The minted depth is credited to NOBODY (`liquidityUnattributed`), so it must not land on
    ///      any seat's premium weight. A suite that calls `sweepFloatIntoPosition()` directly instead
    ///      of this leaves the witness's `refStandingL` intact and its `refUnattributedL` short.
    function _sweepTracked() internal returns (uint128 added) {
        added = hook.sweepFloatIntoPosition();
        refUnattributedL += added;
    }

    /// @notice **THE ASSERTION. THE BOUND IS DERIVED IN FULL BELOW AND MAY NOT BE WIDENED.**
    ///
    /// @dev Fix a seat and a token. Over the `k` accruals since its mark was last advanced, with
    ///      `L_i` constant (every site that moves a seat's liquidity settles it first, so it is),
    ///      write the exact rational entitlement of accrual `j` as `x_j = total_j·L_i/w_j` and
    ///      `S = Σ x_j`.
    ///
    ///      **Witness:**  `W = Σ_j floor(x_j) = S − f`,  `f = Σ_j frac(x_j) ∈ [0, k)`.
    ///
    ///      **Contract:**  `inc_j = floor(total_j·Q/w_j) = total_j·Q/w_j − ε_j`, `ε_j ∈ [0,1)`, so
    ///      `C = floor(L_i·Σinc_j/Q) = floor(S − δ)` with `δ = (L_i/Q)·Σε_j ∈ [0, k·L_i/Q)`.
    ///
    ///      Hence `C − W = f − δ − frac(S−δ)` and
    ///
    ///        * UPPER: `f < k`, `δ ≥ 0`, `frac ≥ 0`  ⇒  `C − W ≤ k − 1`. The contract takes ONE
    ///          floor over the interval where the witness takes `k`.
    ///        * LOWER: `f ≥ 0`, `frac < 1`  ⇒  `C − W ≥ −1 − floor(k·L_i/Q)`. That second term is
    ///          the ACCUMULATOR'S OWN quantisation, worth `L_i/Q` wei per accrual, and it is zero
    ///          for every `L` this pool can hold (`L ≤ MAX_LIQUIDITY_PER_TICK ≈ 1.1e34` against
    ///          `Q = 2^128 ≈ 3.4e38`). It is written out rather than assumed so that a future change
    ///          of `Q` fails loudly instead of silently.
    ///
    ///      **THE `−1` IS STRUCTURAL, NOT A KNIFE EDGE, AND THE HANDOFF'S `0 ≤ C − W` IS WRONG.**
    ///      It needs `f = 0` with `δ > 0`, and `f = 0` happens BY CONSTRUCTION whenever the seat is
    ///      the sole unexcluded payee: then `w = L_i`, every `x_j` is an integer, and the contract
    ///      lands exactly one wei low. A two-seat roster taking head-only swaps hits it on every
    ///      accrual. A witness asserting `C ≥ W` would go red on the most ordinary configuration in
    ///      the suite, and the next person would "fix" it by widening — which is why the term is
    ///      derived here instead.
    ///
    ///      **The `+1` on the upper side** is the price of `_refResyncPremium`: re-basing mid-
    ///      interval introduces one more floor (`floor(A+B) − floor(A) ∈ (B−1, B+1)`), so the honest
    ///      upper bound between two comparisons is `k` rather than `k−1`. At `k == 0` both bounds
    ///      collapse to zero and the comparison is EXACT, which is what makes a second `_check` with
    ///      no swap in between a real assertion rather than a formality.
    function _assertPremiumClaim(string memory tag, uint256 id, bool tok0, uint256 got, uint256 want) internal view {
        (uint256 lo, uint256 hi) = _refBound(id, tok0);
        string memory d = string.concat(
            tag,
            ": PREMIUM seat ",
            vm.toString(id),
            tok0 ? " token0" : " token1",
            " | contract=",
            vm.toString(got),
            " witness=",
            vm.toString(want),
            " | k=",
            vm.toString(tok0 ? refK0[id] : refK1[id])
        );
        d = string.concat(
            d,
            " L_i=",
            vm.toString(refL[id]),
            " w_last=",
            vm.toString(tok0 ? refWLast0 : refWLast1),
            " Q=2^128 bound=[-",
            vm.toString(lo),
            ",+",
            vm.toString(hi),
            "]"
        );
        assertLe(got, want + hi, string.concat(d, " -- contract paid ABOVE the independent pro-rata"));
        assertGe(got + lo, want, string.concat(d, " -- contract paid BELOW the derived floor"));
    }

    /// @notice The WHOLE witness, saved and restored in one move.
    ///
    /// @dev **IT IS ONE STRUCT BECAUSE A SUITE THAT HOLDS TWO POOLS OPEN CANNOT BE TRUSTED TO
    ///      REMEMBER A LIST.** `Premium.t.sol` already carries `expT0`/`expT1` between two hooks by
    ///      hand, and the docblock there records what forgetting one field looked like: "a premium
    ///      leak of 1.9e19 wei", which was the harness. The witness now has fourteen parallel
    ///      arrays and eight scalars, so a hand-carried list is a defect waiting for its turn.
    ///      Save and load the lot, keyed by hook address.
    struct Witness {
        bool present;
        uint256[] r0;
        uint256[] r1;
        uint256[] ord;
        uint256[] l;
        uint256[] p0;
        uint256[] p1;
        uint256[] k0;
        uint256[] k1;
        uint256[] dlo0;
        uint256[] dhi0;
        uint256[] dlo1;
        uint256[] dhi1;
        uint256 c0;
        uint256 c1;
        uint256 standL;
        uint256 unattL;
        uint256 shortL;
        uint256 held0;
        uint256 held1;
        uint256 wl0;
        uint256 wl1;
        uint256 er0;
        uint256 er1;
        uint256 t0;
        uint256 t1;
        bool armed;
        uint256 phi;
        uint24 fee;
    }

    mapping(address => Witness) internal refSaved;

    function _saveWitness(address forHook) internal {
        Witness storage w = refSaved[forHook];
        w.present = true;
        w.r0 = ref0;
        w.r1 = ref1;
        w.ord = refOrder;
        w.l = refL;
        w.p0 = refPend0;
        w.p1 = refPend1;
        w.k0 = refK0;
        w.k1 = refK1;
        w.dlo0 = refDriftLo0;
        w.dhi0 = refDriftHi0;
        w.dlo1 = refDriftLo1;
        w.dhi1 = refDriftHi1;
        w.c0 = refC0;
        w.c1 = refC1;
        w.standL = refStandingL;
        w.unattL = refUnattributedL;
        w.shortL = refShortfallL;
        w.held0 = refHeld0;
        w.held1 = refHeld1;
        w.wl0 = refWLast0;
        w.wl1 = refWLast1;
        w.er0 = refErased0;
        w.er1 = refErased1;
        w.t0 = expT0;
        w.t1 = expT1;
        w.armed = refPremiumArmed;
        // φ AND THE FEE TIER TRAVEL WITH THE POOL. `Premium.t.sol` holds a φ = 8500 pool and a
        // φ = 0 pool open at once; without these two lines the witness would price one pool's fills
        // with the other pool's premium, which is the same class of harness bug the `expT`
        // save/restore exists for.
        w.phi = refPhi;
        w.fee = refFee;
    }

    function _loadWitness(address forHook) internal {
        Witness storage w = refSaved[forHook];
        require(w.present, "witness: no saved state for that hook");
        ref0 = w.r0;
        ref1 = w.r1;
        refOrder = w.ord;
        refL = w.l;
        refPend0 = w.p0;
        refPend1 = w.p1;
        refK0 = w.k0;
        refK1 = w.k1;
        refDriftLo0 = w.dlo0;
        refDriftHi0 = w.dhi0;
        refDriftLo1 = w.dlo1;
        refDriftHi1 = w.dhi1;
        refC0 = w.c0;
        refC1 = w.c1;
        refStandingL = w.standL;
        refUnattributedL = w.unattL;
        refShortfallL = w.shortL;
        refHeld0 = w.held0;
        refHeld1 = w.held1;
        refWLast0 = w.wl0;
        refWLast1 = w.wl1;
        refErased0 = w.er0;
        refErased1 = w.er1;
        expT0 = w.t0;
        expT1 = w.t1;
        refPremiumArmed = w.armed;
        refPhi = w.phi;
        refFee = w.fee;
    }

    /// @notice The same comparison `_check` asserts, RETURNED instead of asserted.
    ///
    /// @dev It exists for exactly one purpose: the mandatory negative controls have to be able to
    ///      say "the witness went red", and a witness nobody has ever seen fail is not a witness
    ///      (LAW 2, LAW 5). Returns the largest number of wei by which any seat's claim falls
    ///      OUTSIDE the derived bound — zero when every seat is inside it. Nothing in the assertion
    ///      path reads this; it is the same arithmetic, reported rather than enforced.
    function _premiumWitnessExcess() internal view returns (uint256 worst) {
        for (uint256 i; i < ref0.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            uint256 e = _excess(i, true, a0, ref0[i] + refPend0[i]);
            if (e > worst) worst = e;
            e = _excess(i, false, a1, ref1[i] + refPend1[i]);
            if (e > worst) worst = e;
        }
    }

    function _excess(uint256 id, bool tok0, uint256 got, uint256 want) private view returns (uint256) {
        (uint256 lo, uint256 hi) = _refBound(id, tok0);
        if (got > want + hi) return got - want - hi;
        if (got + lo < want) return want - got - lo;
        return 0;
    }

    /// @notice Re-base the witness's premium sub-ledger onto the contract's, AFTER asserting it.
    ///
    /// @dev **ASSERT-THEN-RESYNC, NEVER THE REVERSE, AND THE ORDER IS THE WHOLE OF ITS HONESTY.**
    ///      `_check` asserts the derived bound first; only then does this run.
    ///
    ///      It exists because the residual PROPAGATES. Once the witness's ledger differs from the
    ///      contract's by a wei, the next fill differs too — `have` feeds `t`, `t` feeds `g` — so
    ///      without a re-base the interval would have to widen every swap until it hid a real bug.
    ///      Re-basing concedes independence over HISTORY and keeps it over each swap's INCREMENT,
    ///      which is the quantity every premium mutation moves. It is the same division of labour
    ///      `_withdrawTracked` already makes and says so.
    ///
    ///      At φ = 0 it is not called at all, so the 205 pre-Phase-7 assertions keep their full
    ///      one-wei resolution and the exact `assertEq`s they have always had.
    function _refResyncPremium() internal {
        for (uint256 i; i < ref0.length; i++) {
            (uint256 r0, uint256 r1) = hook.rawSeat(i);
            (uint256 s0, uint256 s1) = hook.seat(i);
            ref0[i] = r0;
            ref1[i] = r1;
            refPend0[i] = s0 - r0;
            refPend1[i] = s1 - r1;
            refK0[i] = 0;
            refK1[i] = 0;
            // The ledger IS the contract's now, so every wei those intervals were allowed to round
            // away has been absorbed. This is the only thing that clears the allowance.
            refDriftLo0[i] = 0;
            refDriftHi0[i] = 0;
            refDriftLo1[i] = 0;
            refDriftHi1[i] = 0;
        }
    }

    // ------------------------------------------------------------------------------- assertions

    /// @dev The two claims are DIFFERENT and need different assertions (LAW 3, second corollary):
    ///      (1) the LEDGER conserves, (2) each seat's COMPOSITION matches the independent witness.
    /// @dev **NOT `view` SINCE PHASE 8** — it re-bases the premium sub-ledger after asserting it.
    ///      See `_refResyncPremium`. At φ = 0 nothing is re-based and the assertions below are the
    ///      exact equalities they have always been.
    function _check(string memory tag) internal {
        (uint256 t0, uint256 t1) = hook.totals();
        // `totals()` is the RAW ledger; a withheld premium sits in `premiumOwed` until some seat is
        // next touched, so conservation is the ledger PLUS what is owed against PoolManager's own
        // measured flows. At φ = 0 both `q` terms are zero and this is the identity it always was.
        (uint256 q0, uint256 q1,,) = hook.premiums();
        assertEq(t0 + q0, expT0, string.concat(tag, ": token0 conservation"));
        assertEq(t1 + q1, expT1, string.concat(tag, ": token1 conservation"));

        for (uint256 i; i < ref0.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            if (refPhi == 0) {
                assertEq(a0, ref0[i], string.concat(tag, ": seat a0"));
                assertEq(a1, ref1[i], string.concat(tag, ": seat a1"));
            } else {
                // `seat()` is raw ledger PLUS the live claim, so the witness's comparison is its own
                // ledger plus its own pending. The bound is derived in `_assertPremiumClaim`.
                _assertPremiumClaim(tag, i, true, a0, ref0[i] + refPend0[i]);
                _assertPremiumClaim(tag, i, false, a1, ref1[i] + refPend1[i]);
                // THE PREMIUM'S WEIGHT, and this one carries no slack at all. It is asserted only at
                // φ > 0 because that is where it decides anything, and because a φ = 0 suite that
                // moves depth through a path the witness does not track (a direct
                // `sweepFloatIntoPosition`, say) would otherwise go red for a reason that is not a
                // bug in the thing it is testing.
                assertEq(
                    uint256(hook.seatLiquidity(i)),
                    refL[i],
                    string.concat(tag, ": the witness disagrees about the PREMIUM'S WEIGHT on seat ", vm.toString(i))
                );
            }
        }
        if (refPhi != 0) {
            assertTrue(refPremiumArmed, string.concat(tag, ": the premium witness DISARMED -- this proves nothing"));
            _refResyncPremium();
        }
        _checkInvariantC(tag);
    }

    /// @dev INVARIANT C (§B.6): every seat below cursorX holds zero of token X. This is exactly the
    ///      statement "the cursor never LEADS". A lagging cursor costs gas; a leading cursor skips a
    ///      funded seat, which is silent theft of rank.
    function _checkInvariantC(string memory tag) internal view {
        (uint256 k0, uint256 k1) = hook.cursors();
        // The cursors are RANKS. Reading `seat(i)` here would have been right only while seat id
        // and rank were the same number; after a foreclosure it checks unrelated seats and passes
        // for the wrong reason.
        for (uint256 i; i < k0; i++) {
            (uint256 a0,) = hook.seat(hook.idAtRank(i));
            assertEq(a0, 0, string.concat(tag, ": INVARIANT C cursor0 leads"));
        }
        for (uint256 i; i < k1; i++) {
            (, uint256 a1) = hook.seat(hook.idAtRank(i));
            assertEq(a1, 0, string.concat(tag, ": INVARIANT C cursor1 leads"));
        }
        // AFTER the two loops on purpose, not before. INVARIANT C is the money invariant and must
        // be the reason a control goes red — `test_N4` asserts the exact string "INVARIANT C
        // cursor1 leads" (LAW 2), and checking W first would change that reason and silently
        // convert a passing control into one that fires for a different reason.
        _checkInvariantW(tag);
        _checkOrder(tag);
    }

    /// @dev INVARIANT W — THE WALK ALWAYS STARTS AT THE FRONT: `min(cursor0, cursor1) == 0`.
    ///
    ///      **This is the structural precondition that makes INVARIANT C hold, and it is the
    ///      property PITFALLS 5.164 asked to have written down.** 5.164 states the hazard
    ///      correctly — `_syncSeat` credits a seat and touches NO cursor, so a seat could in
    ///      principle be credited into a window no cursor can reach — but the safety argument it
    ///      records is STALE. That argument was *"every seat below the old cursor holds zero of the
    ///      outgoing token, so it is weighted zero in the accrual"*, which was true only while the
    ///      premium was weighted by the seat's BALANCE. `_claims` now weights by `s.liquidity`
    ///      (`QueueHook.sol:1356`), and liquidity is NOT zeroed by a fill — a fully drained seat
    ///      still carries weight and still accrues. So the old reason no longer holds, and the
    ///      conclusion survives for a DIFFERENT reason, which is this one.
    ///
    ///      The real argument, and it is an induction on two lines of `_allocate`:
    ///
    ///        * a fill raises the OUTGOING token's cursor to `next` and pulls the INCOMING token's
    ///          cursor back to `start`, where `start` is the outgoing cursor's own OLD value;
    ///        * both cursors begin at 0, and every other writer (`_fundSeat`, `_demoteToTail`) only
    ///          ever LOWERS one.
    ///
    ///      So if one cursor is 0 before a fill it is still 0 after: either it is the one being
    ///      pulled back to `start` (and `min(0, start) == 0`), or it IS `start`, in which case the
    ///      other cursor is pulled back to 0. **At least one cursor is therefore always 0, which
    ///      means every fill walks from rank 0 in one of the two directions.** Every seat below a
    ///      NON-zero cursor is consequently swept and re-`_syncSeat`'d by the very fill that grows
    ///      that token's accumulator, so no premium claim is ever left outside a reachable window.
    ///
    ///      **HONEST LIMIT, stated rather than discovered later (LAW 5).** Under the shipped
    ///      one-ended walk W and C are maintained by the SAME line, so the only control available
    ///      for W is the same mutation that C's control uses (`NO_CURSOR_PULLBACK`), and against
    ///      that mutant C fires first. W is not an independent detector today and is not claimed to
    ///      be one. Its value is as a TRIPWIRE: a two-ended book, a reversed walk, or any new
    ///      writer that RAISES a cursor breaks W immediately and structurally, where C might still
    ///      hold locally while the premium strands. That is exactly the change 5.164 warns about.
    ///      `test_C1` drives the mutant and checks W in isolation so the assertion is known to be
    ///      capable of firing at all.
    function _checkInvariantW(string memory tag) internal view {
        (uint256 k0, uint256 k1) = hook.cursors();
        assertEq(
            k0 < k1 ? k0 : k1,
            0,
            string.concat(tag, ": INVARIANT W both cursors lead -- the walk no longer starts at the front")
        );
    }

    /// @dev The contract's packed order word against the witness's plain array, rank by rank.
    function _checkOrder(string memory tag) internal view {
        uint256[] memory got = hook.ranking();
        assertEq(got.length, refOrder.length, string.concat(tag, ": roster size"));
        for (uint256 r; r < refOrder.length; r++) {
            assertEq(got[r], refOrder[r], string.concat(tag, ": rank ", vm.toString(r), " holds the wrong seat"));
        }
    }

    /// @dev The witness's copy of a demotion: the seat leaves its rank and rejoins at the tail.
    function _refDemote(uint256 seatId) internal {
        uint256 n = refOrder.length;
        uint256 r = type(uint256).max;
        for (uint256 i; i < n; i++) {
            if (refOrder[i] == seatId) r = i;
        }
        require(r != type(uint256).max, "witness: no such seat");
        if (r == n - 1) return;
        for (uint256 i = r; i + 1 < n; i++) {
            refOrder[i] = refOrder[i + 1];
        }
        refOrder[n - 1] = seatId;
        if (refC0 > r) refC0 -= 1;
        if (refC1 > r) refC1 -= 1;
    }

    /// @notice INVARIANT R (Phase 4): every wei of currency0 the hook holds is spoken for, and the
    ///         three pots do not overlap.
    ///
    /// @dev `float0` is the queue's own capital outside the position; `escrowTotal` is prepaid rent;
    ///      `unallocatedRent0` is rent charged that had no recipient. If rent accounting ever leaked
    ///      into the float — or the other way — a seat would be paid out of another seat's rent and
    ///      no other assertion in this fixture would notice. Only meaningful on the UNFUNDED
    ///      deployment path, where the hook holds nothing it was not given.
    function _checkInvariantR(string memory tag) internal view {
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 esc, uint256 unalloc) = hook.rentTotals();
        assertEq(_hookBal(c0), f0 + esc + unalloc, string.concat(tag, ": INVARIANT R currency0"));
        assertEq(_hookBal(c1), f1, string.concat(tag, ": INVARIANT R currency1"));

        // ...AND the aggregate against the sum it claims to be. `escrowTotal` is a SECOND WRITER of
        // the same fact as the per-seat escrows, and on this project a rule kept in two places has
        // been wrong four times (PITFALLS 5.37, 5.50, 5.52 twice). Without this line a settlement
        // that credits the recipients without debiting the payer passes every other assertion here:
        // the aggregate stays right while the seats collectively own more than the hook holds.
        assertEq(_sumEscrows(), esc, string.concat(tag, ": escrowTotal disagrees with the seats"));
    }

    /// @notice **INVARIANT L (Phase 8): `Σ seatLiquidity + liquidityUnattributed == positionLiquidity`.**
    ///
    /// @dev EXACT, not a bound. `liquidityContributed` is the premium's denominator, so a drift here
    ///      is a drift in who the premium is paid to — and unlike a token amount it is backed by
    ///      nothing that conservation would notice, because liquidity is not a balance. Only two
    ///      sites write it (`_fundSeat` mints, `_chargeBurn` burns) and one site writes the
    ///      unattributed pot (`sweepFloatIntoPosition`), so the three of them either tie out or one
    ///      of them is wrong.
    ///
    ///      The aggregate `standingL` is a SECOND WRITER of the same fact as the per-seat values, so
    ///      it is checked against the sum rather than trusted — a rule kept in two places has been
    ///      wrong five times on this project. Without that line a burn that decrements the aggregate
    ///      but not the seat (or the reverse) passes every other assertion here while the roster
    ///      collectively claims more depth than the position holds.
    function _checkInvariantL(string memory tag) internal view {
        uint256 n = hook.seatCount();
        uint256 sum;
        for (uint256 i; i < n; i++) {
            sum += hook.seatLiquidity(i);
        }
        (uint256 contributed, uint256 unattributed, uint256 shortfall) = hook.liquidityTotals();
        assertEq(sum, contributed, string.concat(tag, ": standingL disagrees with the seats"));
        assertEq(
            contributed + unattributed,
            hook.positionLiquidity() + shortfall,
            string.concat(tag, ": INVARIANT L - the liquidity ledger does not tie out")
        );
    }

    function _sumEscrows() internal view returns (uint256 s) {
        uint256 n = hook.seatCount();
        for (uint256 i; i < n; i++) {
            (, uint256 e,,,) = hook.leaseOf(i);
            s += e;
        }
    }

    // ------------------------------------------------------------------------------------ helpers

    // ------------------------------------------------------ Phase 2: the PRODUCTION deposit path

    /// @dev Deploys the hook with NO pre-funding. This is deliberate and load-bearing: if the hook
    ///      holds tokens it did not receive through `deposit`, a float-accounting bug simply pays
    ///      out of the surplus and stays invisible. Every Phase 2 assertion depends on the hook
    ///      owning exactly what the queue put in.
    function _deployHookUnfunded(uint160 nonce, address[] memory roster) internal {
        address a = address(FLAGS ^ (nonce << 144));
        deployCodeTo("QueueHarness.sol:QueueHarness", _ctorArgs(roster), a);
        hook = QueueHarness(a);
    }

    function _roster(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _roster(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _roster(address a, address b, address c_) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c_);
    }

    function _roster(address a, address b, address c_, address d) internal pure returns (address[] memory r) {
        r = new address[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c_, d);
    }

    /// @dev Initialize the pool only. `afterInitialize` binds the key inside the hook.
    function _initPool() internal {
        k = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(hook))});
        poolManager.initialize(k, startPrice);
        // Every seat exists from deployment, empty. The witness must have the same shape as the
        // queue from the first block, or a seat that is skipped for being empty in one and absent
        // in the other would agree by accident.
        _refReset();
        uint256 n = hook.seatCount();
        for (uint256 i; i < n; i++) {
            ref0.push(0);
            ref1.push(0);
            refOrder.push(i);
            _refPushSeat();
        }
        expT0 = 0;
        expT1 = 0;
    }

    function _fund(address who, uint256 a0, uint256 a1) internal {
        MockERC20(Currency.unwrap(c0)).mint(who, a0);
        MockERC20(Currency.unwrap(c1)).mint(who, a1);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Fund a seat its holder ALREADY owns. Phase 3 deleted the arrival-order `deposit()`
    ///      that used to create the seat as a side effect, so the seat id is an input now, not an
    ///      output — which is exactly the property that made the head dust-griefable.
    function _addTo(address who, uint256 seatId, uint256 a0, uint256 a1) internal {
        // **AGE PAST THE TERM WHEN THIS DEPOSIT ARMS ONE.** `_fundSeat` stamps `tenureFrom` only
        // when a seat is funded FROM EMPTY, so that is the only case that needs aging — and doing
        // it here means every suite that builds its roster through this helper gets a roster that
        // is free to leave, without the term being switched off anywhere.
        //
        // **THE PRICE GUARD IS NOT COSMETIC.** Warping accrues rent on any seat that already has a
        // self-price, which would silently change the answer in every rent test that funds after
        // pricing. Aging only while the seat is unpriced keeps this invisible to them. A suite that
        // funds an empty seat AFTER pricing it does not get aged and must warp for itself — which
        // is correct, because there the term and the rent clock genuinely interact.
        bool armsTerm = hook.seatLiquidity(seatId) == 0;
        _fund(who, a0, a1);
        // Derived BEFORE the call: `_liquidityForAmounts` reads the price and the position's own
        // liquidity as they stand when the deposit lands, and the second of those moves.
        (uint128 dl, bool ok) = _refMintL(a0, a1);
        vm.prank(who);
        hook.addToSeat(seatId, a0, a1);
        // SETTLE FIRST. `_fundSeat` cashes the seat's claim BEFORE `dl` is added, so the seat is
        // paid at the depth it actually provided rather than at the depth it is about to provide —
        // which is also what stops a flash-loaned deposit weighing on premium it was not there for.
        _refSettle(seatId);
        if (armsTerm && hook.seatLiquidity(seatId) != 0 && _noSelfPricesPosted()) _ageRoster();
        if (ok) {
            refL[seatId] += dl;
            refStandingL += dl;
        } else {
            refPremiumArmed = false;
        }
        // The seat is credited the FULL amount: what the position consumed plus what became float.
        ref0[seatId] += a0;
        ref1[seatId] += a1;
        expT0 += a0;
        expT1 += a1;

        // ...and the witness pulls its own cursors back, by RANK, exactly as the contract does.
        // Without this the two disagree about where the next fill starts the moment a seat below a
        // cursor is re-funded — which is invisible while rank and seat id are the same number, and
        // is not invisible at all once foreclosure can permute the queue.
        uint256 rank;
        for (uint256 i; i < refOrder.length; i++) {
            if (refOrder[i] == seatId) rank = i;
        }
        if (rank < refC0) refC0 = rank;
        if (rank < refC1) refC1 = rank;
    }

    /// @notice Drive the pool into the ONE state in which a premium pot is genuinely HELD:
    ///         `standingL == 0` while the seats hold inventory and the pool still quotes depth.
    ///
    /// @dev **THIS IS NOT A BACK DOOR. Every step is an ordinary external call any address may
    ///      make**, and the state it lands in is a real one the product can reach.
    ///
    ///      Since the whole-book-sweep fix, `_accruePremium`'s HOLD branch is reachable through
    ///      exactly one condition: `w == standingL - excludedL == 0` with `excludedL == 0`, i.e.
    ///      `standingL == 0`. A fill that reaches every standing seat no longer holds — it
    ///      distributes over the full denominator (that was the brick, `test_M7f`). So a test that
    ///      wants the hold path has to reach a pool where **nobody has contributed depth** and yet
    ///      there is depth to trade against and seats to fill. The route:
    ///
    ///        1. every seat withdraws everything, which burns its liquidity and charges the burn
    ///           against its own contribution;
    ///        2. every seat re-funds SINGLE-SIDED. An in-range deposit with one leg at zero mints
    ///           ZERO liquidity — `_liquidityForAmounts` takes the binding leg — so it lands in the
    ///           float whole while the seat is credited every wei;
    ///        3. `sweepFloatIntoPosition()` — permissionless, and it CREDITS NOBODY — turns that
    ///           float into position depth counted as `liquidityUnattributed`;
    ///        4. and once more, because the first exit leaves a handful of units of contribution
    ///           behind against the §E.4 shortfall, and it takes a second burn to charge them down.
    ///
    ///      The end state is asserted rather than hoped for: a caller that silently failed to reach
    ///      `standingL == 0` would be testing the ordinary accrual path while claiming to test the
    ///      hold (PITFALLS 5.54).
    /// @param n the roster size.
    /// @param a0 / @param a1 the single-sided top-ups, one per leg, per seat.
    function _driveStandingLToZero(uint256 n, uint256 a0, uint256 a1) internal {
        for (uint256 round; round < 2; round++) {
            for (uint256 i; i < n; i++) {
                (uint256 b0, uint256 b1) = hook.seat(i);
                if (b0 != 0 || b1 != 0) _withdrawTracked(i, b0, b1);
            }
            for (uint256 i; i < n; i++) {
                address who = hook.ownerOf(i);
                if (a0 != 0) _addTo(who, i, a0, 0);
                if (a1 != 0) _addTo(who, i, 0, a1);
            }
            hook.sweepFloatIntoPosition();
        }

        (uint256 standingL_,,) = hook.liquidityTotals();
        require(standingL_ == 0, "fixture: standingL is not zero -- the hold branch was not reached");
        require(hook.positionLiquidity() != 0, "fixture: the pool quotes no depth -- no fill can happen");
        (uint256 t0, uint256 t1) = hook.totals();
        require(t0 != 0 && t1 != 0, "fixture: the roster is not standing in both tokens");
    }

    /// @dev Withdraw and keep the witness in step. `withdraw` pays `min(face, available)`, so the
    ///      seat is debited by what was PAID, never by what was asked (dust policy F1).
    ///      A withdrawal that takes DEPTH out costs the seat its place in the queue, so the witness
    ///      demotes too. It reads the seat's contributed liquidity either side of the call rather
    ///      than re-deriving `_payOut`'s float arithmetic, and that is a deliberate division of
    ///      labour, stated so nobody mistakes it for an independent check: this keeps the witness's
    ///      ORDER model in step so `_checkOrder`, INVARIANT C and the cursor assertions stay
    ///      meaningful, while WHEN a demotion should happen is asserted directly and independently
    ///      by `Evacuation.t.sol` (`test_8_8`, `test_8_8b`, `test_8_9`).
    function _withdrawTracked(uint256 seatId, uint256 w0, uint256 w1) internal returns (uint256 p0, uint256 p1) {
        uint128 lBefore = hook.seatLiquidity(seatId);
        uint128 posBefore = hook.positionLiquidity();
        vm.prank(hook.ownerOf(seatId));
        (p0, p1) = hook.withdraw(seatId, w0, w1);
        // SETTLE FIRST: `withdraw` settles before it reads the entitlement, so the premium is part
        // of what the holder may take out.
        _refSettle(seatId);
        ref0[seatId] -= p0;
        ref1[seatId] -= p1;
        expT0 -= p0;
        expT1 -= p1;
        // The BURN is measured at the position, and attributed by the witness's own rule.
        _refBurn(seatId, uint256(posBefore) - uint256(hook.positionLiquidity()));
        if (lBefore != hook.seatLiquidity(seatId)) _refDemote(seatId);
    }

    /// @dev Re-base the witness after a seat evacuation. A transfer empties the seat OUTRIGHT —
    ///      the dust clamp changes what was PAID, never what the seat is left holding — so the
    ///      adjustment is exact and does not need to read the contract's arithmetic back. Cursors
    ///      are deliberately left alone, because evacuation does not move them.
    function _evacuateRef(uint256 seatId) internal {
        // SETTLE FIRST: the accrued premium belongs to the DEPARTING holder, who was the one
        // standing in line while it was earned, so it leaves with them rather than with the rank.
        _refSettle(seatId);
        expT0 -= ref0[seatId];
        expT1 -= ref1[seatId];
        ref0[seatId] = 0;
        ref1[seatId] = 0;
        // The seat leaves EMPTY, so its whole recorded contribution leaves with it: the buyer
        // receives rank, never depth. Leaving it behind would pay the new holder a premium weighted
        // by depth somebody else provided and took away.
        refStandingL -= refL[seatId];
        refL[seatId] = 0;

        // **AND THE WITNESS DISARMS HERE, DELIBERATELY, RATHER THAN GUESSING.**
        //
        // `_onSeatTransfer` splits the departing seat's depth THREE ways and the split depends on
        // `burnedOnExit`, which is decided inside `_payOut` during a call this helper did not make:
        // what the payout burned beyond the seat's contribution comes off `liquidityUnattributed`,
        // and — since the INVARIANT L fix — what the FLOAT covered instead of burning goes ONTO it
        // (`liquidityUnattributed += had - burnedOnExit`). A witness cannot see that number from
        // outside the call, and inventing it would make `refUnattributedL` a number that agrees
        // with the contract by construction.
        //
        // So the premium half stops claiming to know the answer. At φ > 0 `_check` asserts
        // `refPremiumArmed`, so an evacuation suite that also wants the premium split has to route
        // the transfer through a helper that measures `positionLiquidity()` either side and calls
        // `_refEvacuateBurn`. At φ = 0 nothing here is load-bearing and nothing changes.
        refPremiumArmed = false;
    }

    /// @dev The evacuation's depth split, for a caller that CAN measure the burn — it must read
    ///      `positionLiquidity()` immediately either side of the transfer. Re-arms the witness.
    ///      `had` is the witness's own record of what the seat contributed, so the attribution rule
    ///      stays the witness's; only the burn magnitude is observed.
    function _refEvacuateBurn(uint256 had, uint256 burned) internal {
        if (burned > had) {
            uint256 rest = burned - had;
            uint256 fromPot = rest > refUnattributedL ? refUnattributedL : rest;
            refUnattributedL -= fromPot;
            refShortfallL += rest - fromPot;
        } else {
            // The float covered the payout, so depth the seat contributed is still in the position
            // and now belongs to nobody. Missing this line broke INVARIANT L by 20% of the position.
            refUnattributedL += had - burned;
        }
        refPremiumArmed = true;
    }

    /// @dev INVARIANT F: sum(q[i].aX) == what the position would release in X, PLUS floatX.
    ///      This is the aggregate identity that makes paying seats first-come-first-served out of a
    ///      SHARED float safe. Asserted non-destructively from the live position.
    ///      Phase 3 adds `pendingTotalX` to the left-hand side. A seat evacuation pays the departing
    ///      holder immediately, so the term is normally zero; it is non-zero only for whatever the
    ///      position could not release on the spot. Leaving it out would let a whole class of
    ///      evacuation bug hide behind the residual tolerance.
    ///      Phase 7 adds `premiumOwed`. A priority premium is withheld from the fill and credited
    ///      to a seat only when that seat is next touched, so between those two moments the tokens
    ///      are inside the position while no seat's ledger claims them. Counting them on the LEDGER
    ///      side is what keeps this an EXACT identity rather than one that drifts by however much
    ///      premium happens to be unsettled — `premiumOwed` is incremented by the whole pot and
    ///      decremented by each claim, so the sum is conserved to the wei by construction.
    ///
    ///      **`totals()` is the RAW slot sum here, deliberately, and `seat()` is not.** `seat()`
    ///      reports what a holder owns (raw + accrued); this identity needs the raw ledger plus the
    ///      whole unsettled pot, and those are two different quantities. Adding `seat()`'s numbers
    ///      instead would double-count every claim that has already been formed and still miss the
    ///      rounding residue and the held-with-nobody-standing pot.
    function _checkInvariantF(string memory tag, uint256 tol) internal view {
        (uint256 t0, uint256 t1) = hook.totals();
        (uint256 f0, uint256 f1) = hook.floats();
        (uint256 w0, uint256 w1) = hook.pendingTotals();
        (uint256 q0, uint256 q1,,) = hook.premiums();
        (uint256 p0, uint256 p1) = _positionValue();
        assertApproxEqAbs(t0 + w0 + q0, p0 + f0, tol, string.concat(tag, ": INVARIANT F token0"));
        assertApproxEqAbs(t1 + w1 + q1, p1 + f1, tol, string.concat(tag, ": INVARIANT F token1"));
    }

    /// @dev What the position would actually hand back: PRINCIPAL **plus UNCOLLECTED LP FEES**.
    ///
    ///      The fee half is not optional and omitting it is not a small error. v4 accrues LP fees
    ///      into `feeGrowthInside` and only realises them on `modifyLiquidity`, so a principal-only
    ///      valuation understates the position by every fee it has ever earned. Measured on this
    ///      fixture: the "residual" grew ~9.6e15 wei PER SWAP — about 80% of the LP fee — and looked
    ///      exactly like a catastrophic ledger bug. It was the instrument.
    ///
    ///      (`withdraw` collects the whole fee balance into the float on the first `modifyLiquidity`
    ///      of any size, which is why the float can pay seats their fee share at all.)
    function _positionValue() internal view returns (uint256 a0, uint256 a1) {
        uint128 L = hook.positionLiquidity();
        if (L == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
        // THE POSITION'S OWN TICKS, not the usable floor. Hardcoding min/max usable made this
        // instrument report a full-range valuation of a concentrated L, which is how INVARIANT F
        // "broke" the moment `_afterInitialize` started shipping a ±10% band (same L, ~20x the
        // token value on paper). PITFALLS 5.75 again: the instrument, not the hook.
        (,, int24 lower, int24 upper) = hook.pool();
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);

        // **CLAMP THE PRICE INTO THE RANGE FIRST.** Out of range the position is entirely one
        // token. The unclamped form OVERSTATED a full-range position by 8.28e18 wei against a
        // real `redeemAll()` (PITFALLS 5.75). A concentrated band can be left even more easily.
        uint160 p = sqrtP < lo ? lo : (sqrtP > hi ? hi : sqrtP);

        // Release rounds DOWN, matching what `modifyLiquidity(-L)` would actually hand back.
        a0 = SqrtPriceMath.getAmount0Delta(p, hi, L, false);
        a1 = SqrtPriceMath.getAmount1Delta(lo, p, L, false);

        (, uint256 insideLast0, uint256 insideLast1) =
            poolManager.getPositionInfo(k.toId(), address(hook), lower, upper, bytes32(0));
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(k.toId(), lower, upper);
        unchecked {
            a0 += FullMath.mulDiv(inside0 - insideLast0, L, 1 << 128);
            a1 += FullMath.mulDiv(inside1 - insideLast1, L, 1 << 128);
        }
    }

    /// @dev Split out of `_swapFrom` for one reason: with the router's named-argument struct inline,
    ///      that function runs out of stack.
    function _routeSwap(address who, bool zeroForOne, uint256 amountIn) private {
        if (refExactOut != 0) {
            vm.prank(who);
            swapRouter.swapTokensForExactTokens({
                amountOut: refExactOut,
                amountInMax: amountIn,
                zeroForOne: zeroForOne,
                poolKey: k,
                hookData: "",
                receiver: who,
                deadline: block.timestamp
            });
            return;
        }
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
    }

    /// @notice An EXACT-OUTPUT swap, measured and witnessed exactly like every other swap.
    ///
    /// @dev **IT EXISTS FOR ONE TEST AND THAT TEST CANNOT BE WRITTEN WITHOUT IT.** `_allocate` sets
    ///      `next = take == bal ? i + 1 : i`, so the boundary where `next` runs one PAST the seats
    ///      the walk actually touched is reached only by a fill that EXACTLY exhausts a seat.
    ///      Inverting the price curve to hit that from an exact-INPUT swap is not something a test
    ///      can do reliably, and a fuzzer will essentially never land on it. Asking the pool for a
    ///      precise output does it in one line — and it is not a synthetic capability, because the
    ///      swap size is the SWAPPER'S choice: any router exposes exact-output, so landing on a seat
    ///      boundary is an attacker's decision rather than a coincidence.
    function _swapExactOut(bool zeroForOne, uint256 amountOut, uint256 amountInMax)
        internal
        returns (uint256 inAmt, uint256 outAmt)
    {
        refExactOut = amountOut;
        (inAmt, outAmt) = _swapFrom(address(this), zeroForOne, amountInMax);
        refExactOut = 0;
    }

    /// @dev External so a negative control can capture the revert and assert its SPECIFIC reason.
    function doSwap(bool zeroForOne, uint256 amountIn) external {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: k,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    /// @dev v4 wraps a hook revert in `WrappedError(address,bytes4,bytes,bytes)`. LAW 2 demands the
    ///      SPECIFIC reason, so unwrap it rather than accepting any revert.
    function _expectSwapRevert(bool zeroForOne, uint256 amountIn, bytes4 wantSelector, string memory what)
        internal
        returns (bytes memory reason)
    {
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.doSwap, (zeroForOne, amountIn)));
        assertFalse(ok, what);
        reason = _unwrap(err);
        assertEq(bytes4(reason), wantSelector, string.concat(what, ": went red for the WRONG reason"));
    }

    function _unwrap(bytes memory err) internal pure returns (bytes memory) {
        // Peel every nested WrappedError until a non-wrapped payload remains.
        while (err.length > 4 && bytes4(err) == bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"))) {
            bytes memory body = new bytes(err.length - 4);
            for (uint256 i; i < body.length; i++) {
                body[i] = err[i + 4];
            }
            (,, bytes memory inner,) = abi.decode(body, (address, bytes4, bytes, bytes));
            err = inner;
        }
        return err;
    }

    function _hookBal(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(hook));
    }

    function _pmBal(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(poolManager));
    }

    function _snapshot(bool zeroForOne) internal view returns (uint256[] memory out) {
        uint256 n = hook.seatCount();
        out = new uint256[](n);
        for (uint256 i; i < n; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            out[i] = zeroForOne ? a1 : a0;
        }
    }

    function _countChanged(bool zeroForOne, uint256[] memory before) internal view returns (uint256 c) {
        for (uint256 i; i < before.length; i++) {
            (uint256 a0, uint256 a1) = hook.seat(i);
            if ((zeroForOne ? a1 : a0) != before[i]) c++;
        }
    }

    function _setProtocolFee(PoolKey memory key_, uint24 fee) internal {
        vm.prank(PM_OWNER);
        poolManager.setProtocolFeeController(address(this));
        poolManager.setProtocolFee(key_, fee);
    }

    function _one0() internal view returns (uint256) {
        return 10 ** dec0;
    }

    function _one1() internal view returns (uint256) {
        return 10 ** dec1;
    }
}
