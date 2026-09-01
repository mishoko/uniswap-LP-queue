// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {QueueFixture} from "./QueueFixture.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {Allocation} from "../../src/queue/libraries/Allocation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Exposes the pure library so it can be fuzzed with no pool at all (§C.1 1.12).
contract AllocationHarness {
    /// @dev No curve: prices at the swap average. This is a LIVE production branch, not a legacy
    ///      one — `_allocate` takes it whenever the band holds no liquidity to read a price from.
    function allocate(uint256[] memory balances, uint256 start, uint256 amtIn, uint256 amtOut)
        external
        pure
        returns (Allocation.Fill[] memory fills)
    {
        return Allocation.allocate(balances, start, amtIn, amtOut, new uint256[](0), 0);
    }

    /// @dev The marginal-pricing branch, driven by a caller-supplied curve. Conservation is a
    ///      property of the CUMULATIVE FORM, not of the particular curve the hook happens to
    ///      build, so a fuzzer must be able to hand it an arbitrary monotone sequence.
    function allocateCurve(
        uint256[] memory balances,
        uint256 start,
        uint256 amtIn,
        uint256 amtOut,
        uint256[] memory cumW,
        uint256 wTotal
    ) external pure returns (Allocation.Fill[] memory fills) {
        return Allocation.allocate(balances, start, amtIn, amtOut, cumW, wTotal);
    }
}

contract AllocatorTest is QueueFixture {
    AllocationHarness harness;

    function setUp() public {
        deployArtifactsAndLabel();
        harness = new AllocationHarness();
        vm.roll(100);
    }

    function _bps() internal pure returns (uint256[] memory bps) {
        bps = new uint256[](3);
        (bps[0], bps[1], bps[2]) = (400, 600, 9000);
    }

    /// @dev The four-swap scenario. Sizes are FRACTIONS OF THE SEEDED RESERVES, not constants, so
    ///      the identical scenario runs at any price and any decimals.
    function _runScenario() internal {
        _open(_bps());
        uint256 s0 = expT0;
        uint256 s1 = expT1;

        (uint256 h0Start, uint256 h1Start) = hook.seat(0);
        (, uint256 seat1Start) = hook.seat(1);

        // --- SWAP 1: small. Must land entirely inside the head seat. (1.5)
        _swap(true, s0 / 500);
        _check("swap1");
        {
            (uint256 h0, uint256 h1) = hook.seat(0);
            (, uint256 a1) = hook.seat(1);
            assertEq(a1, seat1Start, "swap1: fill smeared past the head (pro-rata)");
            assertLt(h1, h1Start, "swap1: head gave up no token1");
            assertGt(h0, h0Start, "swap1: head received no token0");
            assertEq(lastTouched, 1, "swap1: touched != 1");
        }

        // --- SWAP 2: sweeping. Must EXHAUST >=2 seats and partially fill a third. (1.6)
        _swap(true, (s0 * 16) / 100);
        _check("swap2");
        {
            (, uint256 a1) = hook.seat(0);
            (, uint256 b1) = hook.seat(1);
            (, uint256 c1_) = hook.seat(2);
            assertEq(a1, 0, "swap2: seat0 not exhausted");
            assertEq(b1, 0, "swap2: seat1 not exhausted");
            assertGt(c1_, 0, "swap2: seat2 should be partial, not exhausted");
            assertGe(lastTouched, 2, "swap2: cursor never advanced");
        }

        // --- SWAP 3: lands mid-seat. Only seat 2 has token1 left.
        {
            (, uint256 before2) = hook.seat(2);
            _swap(true, (s0 * 26) / 1000);
            _check("swap3");
            (, uint256 after2) = hook.seat(2);
            assertGt(after2, 0, "swap3: not a partial fill");
            assertLt(after2, before2, "swap3: seat2 did not fill");
            assertEq(lastTouched, 1, "swap3: touched != 1");
        }

        // --- SWAP 4: REVERSE. The head holds token0 now, so the head must fill again. (1.7)
        //     This is the "the front seat sees every swap" claim, executed.
        {
            (uint256 h0Before,) = hook.seat(0);
            _swap(false, s1 / 100);
            _check("swap4");
            (uint256 h0After, uint256 h1After) = hook.seat(0);
            assertLt(h0After, h0Before, "swap4: head did not fill on the reverse leg");
            assertGt(h1After, 0, "swap4: head received no token1");
        }
    }

    // =========================================================== 1.1 / 1.4 / 1.5-1.8 — the 1:4 case

    function test_1_1_conservationAndComposition_at1to4() public {
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x1001, 3);
        _runScenario();
    }

    // ============================================================= 1.2 — two more non-unit fixtures

    function test_1_2_conservation_at1to1000() public {
        startPrice = Constants.SQRT_PRICE_1_1 / 31; // ~1:1000
        _deployTokens();
        _deployHook(0x1002, 3);
        _runScenario();
    }

    function test_1_2_conservation_at1000to1() public {
        startPrice = Constants.SQRT_PRICE_1_1 * 31; // ~1000:1
        _deployTokens();
        _deployHook(0x1003, 3);
        _runScenario();
    }

    // ==================================================================== 1.3 — asymmetric decimals

    /// @dev Phase 0 found the reference spike runs 18/18 and so only half-satisfies LAW 1
    ///      (PITFALLS 5.31). This is the missing half.
    function test_1_3_conservation_at18by6decimals() public {
        dec0 = 18;
        dec1 = 6;
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x1004, 3);
        _runScenario();
    }

    function test_1_3_conservation_at6by18decimals() public {
        dec0 = 6;
        dec1 = 18;
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x1005, 3);
        _runScenario();
    }

    // ======================================================== 1.9 — oversized swap reverts, loudly

    /// @dev **THE ALLOCATOR DOES NOT READ THE POSITION'S RANGE, AND THAT IS WHY §5.17 IS A
    ///      PARAMETER CHOICE RATHER THAN A FLAW IN THE MECHANISM.**
    ///
    ///      `PITFALLS.md` 5.17 calls thin full-range depth "the sharpest unanswered attack" — one
    ///      full-range position offers ~1/200th the depth per dollar of a ±1% concentrated one —
    ///      and adds that the range is "a reversible design choice, not a v4 constraint". That
    ///      second half was **ANALYSIS**, and the README stated the attack with no answer attached.
    ///      This executes it.
    ///
    ///      Structurally the claim is that `tickLower` / `tickUpper` appear in exactly two places —
    ///      the liquidity SIZING helpers and the `modifyLiquidity` call — and nowhere in `_allocate`
    ///      or `Allocation.sol`, which see only the realised deltas of a swap that already happened.
    ///      Structure is not evidence, so: seed the identical roster over a **±10% band instead of
    ///      the full range** and run swaps in both directions against the INDEPENDENT witness. If
    ///      any part of the allocation depended on the range, `_check` diverges seat by seat.
    ///
    ///      What this does NOT claim: that a narrow-range QUEUE is a finished product. Out-of-range
    ///      behaviour, rebalancing and the depth/coverage trade-off are unbuilt. It claims exactly
    ///      one thing — **the queue is orthogonal to the range** — so concentrating the custodied
    ///      position is a v2 parameter and not a redesign.
    function test_1_11_theAllocatorIsIndependentOfThePositionRange() public {
        // LAW 1 holds here too: a non-unit price and asymmetric decimals, exactly as test_1_3.
        dec0 = 18;
        dec1 = 6;
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x1006, 3);

        int24 mid = TickMath.getTickAtSqrtPrice(startPrice);
        // ~±10% in price, snapped to the spacing. Wide enough that the scenario's swaps stay inside
        // it — a swap that leaves the band measures v4 running out of liquidity, not the allocator.
        int24 half = 960;
        int24 tl = ((mid - half) / SPACING) * SPACING;
        int24 tu = ((mid + half) / SPACING) * SPACING;

        _openRange(_bps(), tl, tu);

        // The position really is narrow. Without this the test could pass over a full-range pool
        // and prove nothing at all.
        (, bool isBound, int24 lower, int24 upper) = hook.pool();
        assertTrue(isBound, "pool did not bind");
        assertEq(lower, tl, "the harness did not narrow the range");
        assertEq(upper, tu, "the harness did not narrow the range");
        assertLt(
            int256(upper) - int256(lower),
            int256(TickMath.maxUsableTick(SPACING)) - int256(TickMath.minUsableTick(SPACING)),
            "the range is not narrower than full range"
        );

        uint256 s0 = expT0;
        uint256 s1 = expT1;
        assertTrue(s0 != 0 && s1 != 0, "nothing was seeded: this test proves nothing");

        // Both directions, several sizes. `_check` asserts conservation AND every seat against the
        // independently written reference allocator, plus INVARIANT C.
        // A small swap must land entirely in the head, exactly as it does at full range.
        _swap(true, s0 / 500);
        _check("narrow: small 0->1");
        assertEq(lastTouched, 1, "narrow: a small fill smeared past the head");

        // A sweeping swap must walk. THE CURSOR IS ASSERTED HERE, NOT AT THE END: the reverse swap
        // below re-funds the head with token1, and `_allocate` then correctly pulls `cursor1` back
        // to it — so an end-of-test cursor check reads zero and proves nothing. (A first draft
        // asserted exactly that and failed for this reason, which is the rule about checking a path
        // was ENTERED rather than checking the state you happen to end in.)
        _swap(true, s0 / 12);
        _check("narrow: sweeping 0->1");
        assertGe(lastTouched, 2, "narrow: the sweep never advanced the cursor");
        {
            (, uint256 headA1) = hook.seat(0);
            (, uint256 c1After) = hook.cursors();
            assertEq(headA1, 0, "narrow: the sweep did not exhaust the head");
            assertGt(c1After, 0, "narrow: the head is empty but cursor1 never moved");
        }

        // The other direction, which re-funds the front and pulls the cursor back.
        _swap(false, s1 / 50);
        _check("narrow: medium 1->0");
        {
            (, uint256 headA1) = hook.seat(0);
            (, uint256 c1Back) = hook.cursors();
            assertGt(headA1, 0, "narrow: the reverse swap did not re-fund the head");
            assertEq(c1Back, 0, "narrow: cursor1 was left LEADING a funded seat");
        }

        _swap(true, s0 / 200);
        _check("narrow: small 0->1 again");

        // And it was not vacuous: the seeded composition actually changed.
        (uint256 h0, uint256 h1) = hook.seat(0);
        assertTrue(h0 != 0 || h1 != 0, "narrow: the head seat is empty");
    }

    function test_1_9_swapLargerThanTheQueueReverts() public {
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x1006, 3);
        _open(_bps());

        // Drain the queue's token1 down to a sliver, then ask for more than remains.
        _swap(true, (expT0 * 30) / 100);
        _check("drain");

        // Zero every seat's token1 so the next swap CANNOT be covered by the ledger, while the
        // POSITION still has token1 to pay out. The allocator must refuse rather than under-fill.
        uint256 n = hook.seatCount();
        for (uint256 i; i < n; i++) {
            (, uint256 a1) = hook.seat(i);
            if (a1 != 0) _zeroSeatToken1(i);
        }

        bytes memory reason = _expectSwapRevert(
            true, expT0 / 100, Allocation.QueueUnderflow.selector, "oversized swap silently under-filled"
        );
        (uint256 shortfall) = abi.decode(_tail(reason), (uint256));
        assertGt(shortfall, 0, "QueueUnderflow reported a zero shortfall");
    }

    function _tail(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = err[i + 4];
        }
    }

    /// @dev Force a seat's token1 balance to zero, leaving token0 alone.
    ///
    ///      Since Phase 5b a `Seat` is ONE slot — `a0` in the low 128 bits, `a1` in the high ones —
    ///      where it used to be two. The base slot is read from the contract rather than assumed
    ///      (PITFALLS: never hardcode a storage layout in a test), but the LAYOUT WITHIN the
    ///      element still has to be written down somewhere, so the write is READ BACK THROUGH THE
    ///      CONTRACT'S OWN VIEW. A future repacking makes this fail loudly instead of poking an
    ///      unrelated slot and letting the swap revert for some other reason — which is exactly how
    ///      a negative control passes while proving nothing (LAW 2).
    function _zeroSeatToken1(uint256 i) internal {
        (uint256 a0,) = hook.seat(i);
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(hook.seatArraySlot()))) + i);
        vm.store(address(hook), slot, bytes32(a0));

        (uint256 got0, uint256 got1) = hook.seat(i);
        assertEq(got0, a0, "seat layout moved: the poke clobbered token0");
        assertEq(got1, 0, "seat layout moved: token1 was not zeroed, so this test proves nothing");
    }

    // ================================================== 1.12 — stateless fuzz of the pure arithmetic

    /// @dev No tolerance. `sum(give) == amtIn` and `sum(take) == amtOut`, EXACTLY. This is where the
    ///      remainder line earns its keep.
    function testFuzz_allocationNeverLosesAWei(uint256[8] memory rawBalances, uint256 rawIn, uint256 rawOut)
        public
        view
    {
        uint256[] memory balances = new uint256[](8);
        uint256 total;
        for (uint256 i; i < 8; i++) {
            balances[i] = bound(rawBalances[i], 0, 1e30);
            total += balances[i];
        }
        vm.assume(total > 0);

        uint256 amtOut = bound(rawOut, 1, total);
        uint256 amtIn = bound(rawIn, 1, 1e36);

        Allocation.Fill[] memory fills = harness.allocate(balances, 0, amtIn, amtOut);

        uint256 sumTake;
        uint256 sumGive;
        for (uint256 f; f < fills.length; f++) {
            sumTake += fills[f].take;
            sumGive += fills[f].give;
            assertLe(fills[f].take, balances[fills[f].index], "fill exceeds the seat's balance");
        }
        assertEq(sumTake, amtOut, "sum(take) != amtOut: a wei was lost or invented");
        assertEq(sumGive, amtIn, "sum(give) != amtIn: a wei was lost or invented");
    }

    /// @dev **THE SAME CLAIM, WITH A PRICE CURVE UNDER IT.** The fuzz above exercises the
    ///      average-price branch; production almost always takes the OTHER one, and exactness there
    ///      rests on a different argument — that `give` is the DIFFERENCE of two cumulative
    ///      allocations rather than a rounded share of its own.
    ///
    ///      That argument does not depend on the curve being the hook's, so this hands it an
    ///      arbitrary non-decreasing one. If conservation held only for well-shaped curves it would
    ///      be an accident of the band arithmetic rather than a property of `Allocation.step`, and
    ///      the first pool with an unusual band would find out.
    function testFuzz_curvePricingNeverLosesAWei(
        uint256[8] memory rawBalances,
        uint256[8] memory rawSteps,
        uint256 rawIn,
        uint256 rawOut
    ) public view {
        uint256[] memory balances = new uint256[](8);
        uint256 total;
        for (uint256 i; i < 8; i++) {
            balances[i] = bound(rawBalances[i], 0, 1e30);
            total += balances[i];
        }
        vm.assume(total > 0);

        // Any NON-DECREASING sequence is a legal curve. Built by accumulating bounded steps, so
        // the fuzzer explores flat stretches (a seat that absorbed no price move) as well as jumps.
        uint256[] memory cumW = new uint256[](8);
        uint256 acc;
        for (uint256 i; i < 8; i++) {
            acc += bound(rawSteps[i], 0, 1e24);
            cumW[i] = acc;
        }
        uint256 wTotal = acc == 0 ? 0 : acc + bound(rawIn, 0, 1e24);

        uint256 amtOut = bound(rawOut, 1, total);
        uint256 amtIn = bound(rawIn, 1, 1e36);

        Allocation.Fill[] memory fills = harness.allocateCurve(balances, 0, amtIn, amtOut, cumW, wTotal);

        uint256 sumTake;
        uint256 sumGive;
        for (uint256 f; f < fills.length; f++) {
            sumTake += fills[f].take;
            sumGive += fills[f].give;
            assertLe(fills[f].take, balances[fills[f].index], "fill exceeds the seat's balance");
        }
        assertEq(sumTake, amtOut, "sum(take) != amtOut under a curve");
        assertEq(sumGive, amtIn, "sum(give) != amtIn under a curve: the cumulative form does not close");
    }

    /// @dev INVARIANT C for the cursor0 branch specifically.
    ///
    ///      MUTATION TESTING FOUND THIS GAP, and it is the classic paired-branch asymmetry: the
    ///      pull-back exists twice, once per direction, and the whole Phase 1 suite covered only
    ///      ONE of them. Deleting `if (start < cursor1) cursor1 = start;` was caught by 7 tests.
    ///      Deleting its mirror `if (start < cursor0) cursor0 = start;` was caught by ZERO, because
    ///      every scenario happened to END on the reverse leg, so cursor0 never got the chance to
    ///      lead.
    ///
    ///      The sequence that exposes it: forward (head keeps some token1) -> reverse until the
    ///      head's token0 is exhausted so cursor0 advances -> forward again, which credits token0
    ///      straight back to the head. Without the pull-back, cursor0 now LEADS a funded seat and
    ///      the next reverse swap would skip it — silent theft of rank.
    function test_invariantC_cursor0IsPulledBackAfterAReverseFill() public {
        startPrice = Constants.SQRT_PRICE_1_4;
        _deployTokens();
        _deployHook(0x1007, 3);
        _open(_bps());

        // A: small forward fill. The head must KEEP some token1 for step C to work.
        _swap(true, expT0 / 2000);
        _check("C-A");
        (, uint256 headA1) = hook.seat(0);
        assertGt(headA1, 0, "fixture drifted: the head must still hold token1");

        // B: reverse until the head's token0 is exhausted and cursor0 actually advances.
        for (uint256 i; i < 12; i++) {
            (uint256 k0,) = hook.cursors();
            if (k0 > 0) break;
            _swap(false, expT1 / 40);
            _check("C-B");
        }
        (uint256 c0After,) = hook.cursors();
        assertGt(c0After, 0, "fixture drifted: cursor0 never advanced, nothing to pull back");

        // C: forward again. This credits token0 to seats from cursor1 upward — including the head,
        // which sits BELOW cursor0. The pull-back is the only thing keeping INVARIANT C true.
        _swap(true, expT0 / 2000);
        _check("C-C");

        (uint256 h0,) = hook.seat(0);
        (uint256 k0Final,) = hook.cursors();
        assertGt(h0, 0, "fixture drifted: the head was not re-credited token0");
        assertEq(k0Final, 0, "cursor0 was not pulled back and now LEADS a funded seat");
    }

    /// @dev **THE HEAD-ONLY FLATNESS MEASUREMENT MOVED TO `Gas.t.sol` IN PHASE 5, AND IT WAS
    ///      WRONG HERE.** It built its rosters inside its own test body, so every `SSTORE` the
    ///      swap performed was priced at 100 gas — a write to a slot the same transaction had
    ///      already dirtied — instead of the 2,900 or 20,000 a real swap pays. `vm.cool()` does not
    ///      fix that: it resets the EIP-2929 access list, not the value EIP-2200 meters a write
    ///      against. Measured, same swap: 172,263 in-body vs 252,966 from `setUp()`.
    ///
    ///      It also scaled the swap size by `1/(n·400)` so the fill stayed head-only, which made
    ///      swap size a second variable, and it measured the first row before the router and the
    ///      ERC20s were warm, which put 21,179 gas of first-call cost into that row alone. Both
    ///      artefacts read as depth effects.
    ///
    ///      `GasTest.test_5_1_theGasTable` makes the same claim — a head-only swap must cost the
    ///      same at a full roster as at one seat, or the cursors are not working — from state built
    ///      in `setUp()`, at a constant swap size, after a warm-up. It measures 118,012 gas flat
    ///      from 1 to 32 seats, a spread of 3 gas.

    /// @dev A swap the queue cannot cover must REVERT, never silently under-fill. Under-filling
    ///      would hand the swapper tokens no seat owns. Mutation testing showed the pool-level test
    ///      alone was the only thing covering this; the fuzz makes it cheap to cover properly.
    function testFuzz_oversizedAllocationAlwaysReverts(uint256[5] memory rawBalances, uint256 excess) public {
        uint256[] memory balances = new uint256[](5);
        uint256 total;
        for (uint256 i; i < 5; i++) {
            balances[i] = bound(rawBalances[i], 0, 1e24);
            total += balances[i];
        }
        uint256 amtOut = total + bound(excess, 1, 1e24);

        vm.expectPartialRevert(Allocation.QueueUnderflow.selector);
        harness.allocate(balances, 0, 1e18, amtOut);
    }

    /// @dev Front-first is an ORDERING claim, not just a conservation claim: with the cursor at 0,
    ///      no seat may be touched while an earlier seat still holds the outgoing token.
    function testFuzz_allocationIsStrictlyFrontFirst(uint256[6] memory rawBalances, uint256 rawOut) public view {
        uint256[] memory balances = new uint256[](6);
        uint256 total;
        for (uint256 i; i < 6; i++) {
            balances[i] = bound(rawBalances[i], 0, 1e24);
            total += balances[i];
        }
        vm.assume(total > 0);
        uint256 amtOut = bound(rawOut, 1, total);

        Allocation.Fill[] memory fills = harness.allocate(balances, 0, 1e18, amtOut);

        for (uint256 f; f + 1 < fills.length; f++) {
            assertLt(fills[f].index, fills[f + 1].index, "fills are not in rank order");
            assertEq(fills[f].take, balances[fills[f].index], "an earlier seat was left partially filled");
        }
    }
}
