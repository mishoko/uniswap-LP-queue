// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {QueueDeployBase} from "./QueueDeployBase.sol";

/// @notice Deploy QUEUE and run the demo, on **Unichain Sepolia only**.
///
/// ```
/// export PRIVATE_KEY=0x...
/// forge script script/DeployQueue.s.sol:DeployQueue \
///   --rpc-url https://sepolia.unichain.org --broadcast -vvv
/// ```
///
/// **EVERY RISKY STEP HERE IS ALREADY UNDER TEST.** Address mining, the CREATE2 deploy, the pool
/// bind, `addToSeat` into a virgin position, the swaps, the transfer and the buyout all live in
/// `script/QueueDeployBase.sol` and are executed and asserted beat by beat by
/// `test/queue/Deploy.t.sol`. What is written out below is only the ORDER they run in, so that the
/// transcript reads the way the README describes it.
///
/// **NO MAINNET. EVER.** Enforced by `_requireTestnet` rather than by intention.
contract DeployQueue is Script, QueueDeployBase {
    /// @dev secp256k1 group order; a derived key must land inside it.
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint256[2] internal pk;
    Deployment d;

    function _as(uint256 who) internal override {
        vm.startBroadcast(pk[who]);
    }

    function _stopActing() internal override {
        vm.stopBroadcast();
    }

    /// @dev The chains this may touch, named explicitly. An allow-list rather than a mainnet
    ///      deny-list: a new mainnet id added to `AddressConstants` tomorrow must not become
    ///      deployable here by default.
    function _requireTestnet() internal view {
        uint256 id = block.chainid;
        require(id == 1301 || id == 11155111 || id == 31337, "QUEUE: testnet only (Unichain Sepolia 1301)");
    }

    function run() public {
        _requireTestnet();

        pk[0] = vm.envUint("PRIVATE_KEY");
        // The demo needs a SECOND signer — somebody to take a seat off the first at its own posted
        // price — and a buyout with only one key would be `CannotBuyOwnSeat`. Derived from the
        // deployer's key so the operator manages exactly one secret, and funded below.
        pk[1] = (uint256(keccak256(abi.encodePacked("QUEUE demo counterparty", pk[0]))) % (SECP256K1_N - 1)) + 1;
        actor[0] = vm.addr(pk[0]);
        actor[1] = vm.addr(pk[1]);

        d.poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        d.router = IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));
        require(address(d.poolManager).code.length != 0, "no PoolManager on this chain");
        require(address(d.router).code.length != 0, "no V4SwapRouter on this chain");

        console.log("chainId       ", block.chainid);
        console.log("deployer      ", actor[0]);
        console.log("counterparty  ", actor[1]);
        console.log("PoolManager   ", address(d.poolManager));
        console.log("SwapRouter    ", address(d.router));

        // Gas for the counterparty. It signs four transactions in the sequence below.
        _as(0);
        payable(actor[1]).transfer(0.01 ether);
        _stopActing();

        // ---------------------------------------------------------------- STEP 1-3: the deployment
        (d.token0, d.token1) = _deployTokens();
        d.sqrtPriceX96 = _sqrtPriceX96(d.token0.decimals(), d.token1.decimals());

        address[] memory roster = new address[](SEATS);
        for (uint256 i; i < SEATS; i++) {
            roster[i] = actor[0];
        }
        (d.hook, d.salt) =
            _deployHook(d.poolManager, Currency.wrap(address(d.token0)), Currency.wrap(address(d.token1)), roster);
        d.key = _initPool(d);

        console.log("");
        console.log("token0 (18dp) ", address(d.token0));
        console.log("token1 (6dp)  ", address(d.token1));
        console.log("QueueHook     ", address(d.hook));
        console.log("salt          ", vm.toString(d.salt));
        console.log("sqrtPriceX96  ", d.sqrtPriceX96);

        // ------------------------------------------------------------------------ STEP 4-5: capital
        _fundActors(d, 5_000_000e18, 20_000_000e6);
        for (uint256 i; i < SEATS; i++) {
            uint256 mul = SEATS - i;
            _fundSeat(d, 0, i, mul * 100e18, mul * 400e6);
        }
        _logSeats(d, "BEAT 1 - five founding seats, funded, in the founding order");

        // ------------------------------------------------------- BEAT 2: a small swap fills the head
        _swap(d, 1, true, 1e18);
        _logSeats(d, "BEAT 2 - a SMALL swap: the head seat pays out, nobody behind it moves");

        // ---------------------------------------------------------- BEAT 3: a large swap walks the queue
        _swap(d, 1, true, 2_500e18);
        _logSeats(d, "BEAT 3 - a SWEEPING swap: ranks exhaust front-first, cursor1 advances");

        // -------------------------------------------- BEAT 4: a transfer moves rank, capital goes back
        _transferSeat(d, 0, actor[1], 4);
        _logSeats(d, "BEAT 4 - seat 4 transferred: rank changed hands, the capital went to the seller");

        // ------------------------------------------------- BEAT 5: an under-priced seat is taken
        _setSelfPrice(d, 0, 0, 100e18);
        _logSeats(d, "BEAT 5a - the head seat posts its own price of 100e18");
        _buySeat(d, 1, 0, 100e18, 250e18);
        _logSeats(d, "BEAT 5b - the head seat was TAKEN at the price its holder set");

        // --------------------------------------------------- BEAT 6: rent, front to back, in real time
        _fundRent(d, 1, 0, 50e18);
        _settle(0);
        (uint256 escrowed, uint256 unallocated) = d.hook.rentTotals();
        console.log("");
        console.log("BEAT 6 - rent settled. escrowTotal / unallocated:", escrowed, unallocated);
        console.log("head-seat self price (the number nobody has):", d.hook.buyPrice(0));

        console.log("");
        console.log("=== ADDRESSES FOR THE README =================================");
        console.log("QueueHook  ", address(d.hook));
        console.log("token0     ", address(d.token0));
        console.log("token1     ", address(d.token1));
        console.log("PoolManager", address(d.poolManager));
        console.log("==============================================================");
    }

    function _settle(uint256 seatId) internal {
        _as(0);
        d.hook.settleRent(seatId);
        _stopActing();
    }
}
