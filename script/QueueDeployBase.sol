// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {QueueHook} from "../src/queue/QueueHook.sol";

/// @notice The deployment and demo sequence for QUEUE, written ONCE and executed by two callers.
///
/// **WHY THIS IS A SHARED BASE AND NOT A SCRIPT.** `script/DeployQueue.s.sol` broadcasts this
/// sequence to Unichain Sepolia; `test/queue/Deploy.t.sol` runs the SAME functions against a fork
/// of that chain and asserts the outcome of every step. If the deploy path lived only in a script,
/// the first time it ever ran would be the time it ran with real money and a judge watching — and
/// this project's whole method is that a path nobody has attacked is a path nobody has tested.
///
/// The only difference between the two callers is WHO SIGNS. That is isolated behind `_as` /
/// `_stopActing`: the script implements them with `vm.startBroadcast`, the test with
/// `vm.startPrank`. Nothing else forks.
///
/// **LAW 1 APPLIES TO THE DEMO TOO.** The pool is 18/6 decimals at 1 token0 = 4 token1. A 1:1 demo
/// pool would hide exactly the token0/token1 mixing bug the suite spends its life hunting, and it
/// would be an embarrassing thing for a judge to notice (PLAN §H.3).
abstract contract QueueDeployBase is CommonBase {
    using StateLibrary for IPoolManager;

    // --------------------------------------------------------------------------- pool parameters

    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;

    /// @dev THE HOOK FLAG BITS, DERIVED FROM THE CONTRACT'S OWN PERMISSIONS RATHER THAN COPIED.
    ///      `PLAN.md` §H.3 said `0x0840`, which was the Phase-1 permission set and is now stale:
    ///      the shipping hook also uses `afterInitialize` (to bind its one pool) and
    ///      `beforeAddLiquidity` (to refuse every external LP), so the real value is `0x18C0`.
    ///      `test/queue/Deploy.t.sol::test_7_1` asserts this constant against
    ///      `getHookPermissions()` so the two can never drift again.
    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    /// @dev Harberger governance parameters. τ = 10% per year is the conventional figure — a
    ///      citation, not a number somebody picked — and `PLAN.md` §B.10 forbids defending a value.
    ///      They are immutable in the contract because a rent rate somebody can change afterwards
    ///      is a privileged role over everyone's money, and this contract has none.
    /// @dev Band half-width in ticks, snapped to spacing at `_afterInitialize`. ~+10.08%/-9.16%.
    ///      A DEPLOYMENT PARAMETER: band width sets depth at the money, and depth sets how large a
    ///      swap must be to reach rank 2. A stablecoin pair wants tens of ticks, not 960.
    int24 internal constant BAND_HALF_WIDTH = 960;

    uint256 internal constant RENT_BPS = 1_000;
    uint256 internal constant RENT_PERIOD = 365 days;
    uint256 internal constant FIRM_WINDOW = 1 hours;

    /// @dev φ — the share of the LP fee a filled seat hands to the seats still standing behind it.
    ///      7,900 bps = 79%.
    ///
    ///      **SOLVED FROM A STATED PARTICIPATION CONSTRAINT, NOT SWEPT FOR A GREEN NUMBER, AND
    ///      MEASURED ON THE ROSTER THIS SCRIPT ACTUALLY DEPLOYS.** The previous value of 8,500 was
    ///      chosen against "0 of 32 seats negative" — a SIGN TEST, which AGENTS.md §3b names as the
    ///      thing that is not a correctness assertion — on a 32-equal book whose head is $31,250.
    ///      This deploys FIVE seats funded 5:4:3:2:1, so the head is $333,333, and the answer is
    ///      different. Both bounds below are measured on THAT configuration.
    ///
    ///      Two constraints, and they are asymmetric because the two sides have different
    ///      alternatives:
    ///
    ///        * **The seats behind have no option**, so their bar is hard: beat passive LPing or do
    ///          not fund. In the benign regime seat 2 falls to exactly the pro-rata LP's return at
    ///          φ = 7,455 and below it the funding pool has no reason to exist.  =>  φ >= 7455
    ///        * **The front buys something no LP can sell it** — costless two-sided re-anchoring —
    ///          so it can rationally accept a below-LP return, and its bar is the cheapest way to
    ///          replicate that: a keeper-managed narrow ATM range, which costs 80-123%/yr in
    ///          conversion fee and price impact at the widths that actually compete. The front stops
    ///          beating that alternative at φ = 8,312.  =>  φ <= 8312
    ///
    ///      Intersection [7455, 8312], midpoint **7,900**. It also sits inside the 45%-vol window
    ///      [4114, 8921], so a more volatile pair widens the window downward and 7,900 stays valid.
    ///      A pair calmer than 25% vol raises the lower bound and is the untested edge.
    ///
    ///      **THE SENSITIVITY THAT DECIDES THE PRODUCT, stated here because it is not a detail.**
    ///      Hold the front to the PASSIVE-LP bar instead of the managed-wing bar and it falls below
    ///      at φ = 6,397 — below the 7,455 the back needs — so **both windows are empty and no
    ///      shipping constant exists.** The window is non-empty only because re-anchoring is worth
    ///      something to the front. What it COSTS to replicate is measured; what a buyer will PAY
    ///      for it is not, and no simulator can say.
    ///
    ///      TOXIC is excluded by calendar weight rather than by deletion: a toxic band dies in ~1.4
    ///      days against ~61 benign, so it is ~1.7% of the calendar even at equal likelihood.
    ///
    ///      Reproduce: `python3 docs/research/seat-economics/report_shipping.py`. The sweep is
    ///      checked in — which, before 2026-09-02, this comment claimed while it was not.
    uint256 internal constant PREMIUM_BPS = 7_900;

    /// @dev The canonical deterministic CREATE2 proxy. Verified to have code on Unichain Sepolia.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint8 internal constant DEC_A = 18;
    uint8 internal constant DEC_B = 6;

    /// @dev One whole unit of `currency0` buys `PRICE_NUM / PRICE_DEN` whole units of `currency1`.
    ///      Stated in WHOLE units so it stays non-unit whichever way the two tokens happen to sort.
    uint256 internal constant PRICE_NUM = 4;
    uint256 internal constant PRICE_DEN = 1;

    /// @dev Five founding seats over two holders. Small enough to read on screen, large enough that
    ///      a sweeping swap visibly walks more than one seat.
    uint256 internal constant SEATS = 5;

    struct Deployment {
        IPoolManager poolManager;
        IUniswapV4Router04 router;
        MockERC20 token0;
        MockERC20 token1;
        QueueHook hook;
        PoolKey key;
        uint160 sqrtPriceX96;
        bytes32 salt;
    }

    /// @dev Index 0 is the deployer; index 1 is the counterparty. Both are set by the caller before
    ///      any step runs. The demo needs exactly TWO signing accounts — one to hold and price
    ///      seats, one to take a seat away from the other at its own posted price — and no more,
    ///      because every extra funded key on a testnet is another way for a live demo to fail.
    address[2] internal actor;

    /// @dev Set identity for the next call. Broadcast in the script, prank in the test.
    function _as(uint256 who) internal virtual;
    function _stopActing() internal virtual;

    // ------------------------------------------------------------------------------ price helper

    /// @dev `sqrt(rawPrice) · 2^96`, where `rawPrice` is currency1-per-currency0 in RAW units.
    ///      v4 works in raw units, so the decimals must be folded in here or the pool opens at a
    ///      price twelve orders of magnitude from the one the demo claims (LAW 1's corollary).
    function _sqrtPriceX96(uint8 dec0, uint8 dec1) internal pure returns (uint160) {
        // ratioX192 = (num · 10^dec1 · 2^192) / (den · 10^dec0). Widest case here is
        // 4 · 10^18 · 2^192 ≈ 2.5e76, comfortably inside 2^256 ≈ 1.16e77.
        uint256 ratioX192 = (PRICE_NUM * (10 ** dec1) * (1 << 192)) / (PRICE_DEN * (10 ** dec0));
        uint256 s = FixedPointMathLib.sqrt(ratioX192);
        require(s > TickMath.MIN_SQRT_PRICE && s < TickMath.MAX_SQRT_PRICE, "demo price out of range");
        return uint160(s);
    }

    // ------------------------------------------------------------------------ constructor args

    /// @dev THE DEPLOYMENT COPY OF THE CONSTRUCTOR ARGUMENT LIST, and the reason this comment is
    ///      now a warning rather than a note.
    ///
    ///      There are three hand-written copies of this list in the repo — `QueueFixture._ctorArgs`,
    ///      this one, and (until Phase 7 deleted it) one inside `Controls.t.sol`. Adding
    ///      `bandHalfWidth` broke the third. Adding `premiumBps` broke this one AND the third, and
    ///      **this one failed silently**: `abi.encode` is untyped, so a ten-argument payload against
    ///      an eleven-argument constructor compiles, deploys, and decodes the missing parameter out
    ///      of whatever bytes follow the roster's tail. The pool came up with a garbage φ and the
    ///      only symptom was `test_7_5` reporting the demo's seller short by 2.4e15 wei.
    ///
    ///      A typed call would have been a compile error. If a fourth copy is ever needed, give the
    ///      constructor a parameter STRUCT instead, so the compiler checks the shape.
    function _ctorArgs(IPoolManager pm, Currency c0, Currency c1, address[] memory roster)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            pm, c0, c1, FEE, SPACING, BAND_HALF_WIDTH, roster, RENT_BPS, RENT_PERIOD, FIRM_WINDOW, PREMIUM_BPS
        );
    }

    // --------------------------------------------------------------------------------- the steps

    /// @notice STEP 1 — two demo ERC-20s at asymmetric decimals, sorted into (currency0, currency1).
    /// @dev Deployed by actor 0. `MockERC20.mint` is public on purpose: it makes the demo pool a
    ///      faucet, so a judge can get tokens and try the hook themselves without asking anyone.
    function _deployTokens() internal returns (MockERC20 t0, MockERC20 t1) {
        _as(0);
        MockERC20 a = new MockERC20("QUEUE Demo A", "QDA", DEC_A);
        MockERC20 b = new MockERC20("QUEUE Demo B", "QDB", DEC_B);
        _stopActing();
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        require(address(t0) != address(t1), "token collision");
    }

    /// @notice STEP 2 — mine a CREATE2 salt whose address carries the hook's four permission bits,
    ///         then deploy through the canonical deterministic proxy.
    /// @dev The mine and the deploy MUST agree on the deployer address: v4 reads a hook's
    ///      permissions out of its address, and `BaseHook`'s constructor validates them before any
    ///      of QUEUE's own constructor runs. Deploy from the wrong address and it reverts on the
    ///      flags check with nothing built.
    function _deployHook(IPoolManager pm, Currency c0, Currency c1, address[] memory roster)
        internal
        returns (QueueHook hook, bytes32 salt)
    {
        bytes memory args = _ctorArgs(pm, c0, c1, roster);
        address predicted;
        (predicted, salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(QueueHook).creationCode, args);

        _as(0);
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(QueueHook).creationCode, args));
        _stopActing();

        require(ok, "CREATE2 deploy failed");
        address deployed = address(uint160(bytes20(ret)));
        require(deployed == predicted, "mined address != deployed address");
        require(deployed.code.length != 0, "hook has no code");
        hook = QueueHook(deployed);
    }

    /// @notice STEP 3 — open the pool. `afterInitialize` is what BINDS the hook to this one key.
    function _initPool(Deployment memory d) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(d.token0)),
            currency1: Currency.wrap(address(d.token1)),
            fee: FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(d.hook))
        });
        _as(0);
        d.poolManager.initialize(key, d.sqrtPriceX96);
        _stopActing();
    }

    /// @notice STEP 4 — mint demo balances and set every approval the demo needs.
    /// @dev The hook is approved directly (it pulls with `safeTransferFrom` in `_fundSeat`) and so
    ///      is the router (`V4SwapRouter` pulls the trader's input the same way).
    function _fundActors(Deployment memory d, uint256 amt0, uint256 amt1) internal {
        for (uint256 i; i < actor.length; i++) {
            // The mint must sit INSIDE an identity block. A bare call here executes in the test but
            // is never broadcast by the script, so the deployment would arrive on chain with two
            // unfunded actors and every later step would revert on an allowance of zero.
            _as(0);
            d.token0.mint(actor[i], amt0);
            d.token1.mint(actor[i], amt1);
            _stopActing();
            _as(i);
            d.token0.approve(address(d.hook), type(uint256).max);
            d.token1.approve(address(d.hook), type(uint256).max);
            d.token0.approve(address(d.router), type(uint256).max);
            d.token1.approve(address(d.router), type(uint256).max);
            _stopActing();
        }
    }

    /// @notice STEP 5 — put capital behind a seat, through the ONLY path production has.
    /// @dev There is no `seed()` on the shipping hook and no `deposit()` that mints a seat. The
    ///      roster was fixed in the constructor; `addToSeat` is how a holder funds rank they
    ///      already hold. That asymmetry is the whole of PITFALLS 5.8.
    function _fundSeat(Deployment memory d, uint256 who, uint256 seatId, uint256 a0, uint256 a1) internal {
        _as(who);
        d.hook.addToSeat(seatId, a0, a1);
        _stopActing();
    }

    /// @notice STEP 6 — a swap through the ordinary v4 router. The queue is invisible to the trader.
    function _swap(Deployment memory d, uint256 who, bool zeroForOne, uint256 amountIn)
        internal
        returns (BalanceDelta delta)
    {
        _as(who);
        delta = d.router
            .swapExactTokensForTokens({
                amountIn: amountIn,
                amountOutMin: 0,
                zeroForOne: zeroForOne,
                poolKey: d.key,
                hookData: "",
                receiver: actor[who],
                deadline: block.timestamp + 1
            });
        _stopActing();
    }

    function _setSelfPrice(Deployment memory d, uint256 who, uint256 seatId, uint256 price) internal {
        _as(who);
        d.hook.setSelfPrice(seatId, price);
        _stopActing();
    }

    function _fundRent(Deployment memory d, uint256 who, uint256 seatId, uint256 amount) internal {
        _as(who);
        d.hook.fundRent(seatId, amount);
        _stopActing();
    }

    function _buySeat(Deployment memory d, uint256 who, uint256 seatId, uint256 maxPrice, uint256 newPrice) internal {
        _as(who);
        d.hook.buySeat(seatId, maxPrice, newPrice);
        _stopActing();
    }

    function _transferSeat(Deployment memory d, uint256 who, address to, uint256 seatId) internal {
        _as(who);
        d.hook.transfer(to, seatId, 1);
        _stopActing();
    }

    // ----------------------------------------------------------------------------- the transcript

    /// @dev The demo is only convincing if the numbers are on screen. Every step prints the full
    ///      seat table, so the README transcript is a copy of what the chain actually did rather
    ///      than a description of it.
    function _logSeats(Deployment memory d, string memory tag) internal view {
        console.log("");
        console.log("--------------------------------------------------------------");
        console.log(tag);
        console.log("rank | seat | holder                                     | amount0 | amount1 | selfPrice");
        uint256[] memory ids = d.hook.ranking();
        for (uint256 r; r < ids.length; r++) {
            uint256 id = ids[r];
            (uint256 a0, uint256 a1) = d.hook.seat(id);
            (, uint256 price,,,) = d.hook.leaseOf(id);
            console.log(
                string.concat(
                    "  ",
                    vm.toString(r),
                    "  |   ",
                    vm.toString(id),
                    "  | ",
                    vm.toString(d.hook.ownerOf(id)),
                    " | ",
                    vm.toString(a0),
                    " | ",
                    vm.toString(a1),
                    " | ",
                    vm.toString(price)
                )
            );
        }
        (uint256 c0, uint256 c1) = d.hook.cursors();
        console.log(string.concat("cursor0 = ", vm.toString(c0), "   cursor1 = ", vm.toString(c1)));
    }
}
