// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {DeployTest} from "./Deploy.t.sol";
import {console} from "forge-std/console.sol";

/// @notice PHASE 7 — the SAME five deployment tests, against a fork of the chain QUEUE deploys to.
///
/// **WHY A FORK AND NOT JUST THE LOCAL STACK.** `test/queue/Deploy.t.sol` runs against a v4 stack
/// this repo deploys itself. That proves the sequence is right; it does NOT prove that the
/// addresses it will use on the day are real, that the canonical CREATE2 proxy is present there, or
/// that the vendored `AddressConstants` is not stale — and `PLAN.md` §H.2 warns in as many words
/// that a hardcoded address in a vendored dependency is exactly the kind of thing that goes silently
/// stale. A fork answers all three against the live chain, without spending a testnet wei.
///
/// It is OFF by default because the default suite must not need a network. Turn it on:
///
/// ```
/// QUEUE_FORK=true forge test --match-path "test/queue/DeployFork.t.sol" -vv
/// ```
///
/// Skipping is LOUD (`vm.skip`), never a silent pass — a test that quietly does nothing is the
/// exact failure mode `AGENTS.md` §2 exists to prevent.
contract DeployForkTest is DeployTest {
    string constant DEFAULT_RPC = "https://sepolia.unichain.org";

    function setUp() public override {
        super.setUp();
    }

    function _selectChain() internal override {
        if (!vm.envOr("QUEUE_FORK", false)) {
            console.log("SKIPPED: set QUEUE_FORK=true to run the deployment tests against a live fork");
            vm.skip(true);
            return;
        }
        string memory url = vm.envOr("UNICHAIN_SEPOLIA_RPC_URL", string(DEFAULT_RPC));
        vm.createSelectFork(url);
        // Fail loudly rather than silently falling back to a locally deployed stack: the whole
        // point of this file is that the addresses came from the live chain.
        require(block.chainid == 1301, "QUEUE_FORK is set but the RPC is not Unichain Sepolia");
    }
}
