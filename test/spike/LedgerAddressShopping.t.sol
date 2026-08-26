// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolLedger} from "../../src/assay/PoolLedger.sol";

/// @dev bytes32(uint256(keccak256("NonzeroDeltaCount")) - 1), from v4-core NonzeroDeltaCount.sol
bytes32 constant NONZERO_DELTA_COUNT_SLOT = 0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;

/// @notice The second address. Holds no capital and never touches an ERC20.
contract Accomplice {
    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    /// @dev Converts ERC-6909 claims it already holds back into a live PoolManager credit.
    function absorb(Currency c, uint256 amount) external {
        pm.burn(address(this), c.toId(), amount);
    }

    function cashOut(Currency c, uint256 amount, address to) external {
        pm.take(c, to, amount);
    }
}

/// @notice PROVES: a positive flash-accounting delta can be relocated to an arbitrary address,
/// inside a single unlock, with zero external capital and no ERC20 movement.
///
/// Consequence: any hook that infers a COUNTERPARTY'S behaviour from `exttload` on the caller's
/// delta is defeated by address-shopping. The ledger tells the truth about an address; the
/// adversary chooses which address faces the hook.
contract LedgerAddressShoppingTest is Test, IUnlockCallback {
    IPoolManager pm;
    MockERC20 token;
    Currency c;
    Accomplice bob;

    uint256 constant AMT = 1_000e18;

    // recorded mid-unlock
    int256 aliceAfterSettle;
    int256 aliceAfterMint;
    int256 bobAfterMint;
    int256 bobAfterBurn;
    uint256 countAfterSettle;
    uint256 countAfterMint;
    uint256 gasLaunder;

    function setUp() public {
        pm = IPoolManager(V4PoolManagerDeployer.deploy(address(this)));
        token = new MockERC20("T", "T", 18);
        c = Currency.wrap(address(token));
        bob = new Accomplice(pm);
        token.mint(address(this), AMT);
    }

    function _delta(address who) internal view returns (int256) {
        return PoolLedger.delta(pm, who, c);
    }

    function _count() internal view returns (uint256) {
        return uint256(pm.exttload(NONZERO_DELTA_COUNT_SLOT));
    }

    function test_positiveDeltaIsRelocatableToAnyAddressForFree() public {
        pm.unlock("");

        // 1. Alice is genuinely owed AMT by the PoolManager. This is the state a hook would read.
        assertEq(aliceAfterSettle, int256(AMT), "alice should be in credit after settling");
        assertEq(countAfterSettle, 1, "one nonzero delta outstanding");

        // 2. After minting ERC-6909 to Bob, Alice's ledger entry is IDENTICALLY ZERO while she is
        //    still economically owed the money. She reads clean to every hook in the transaction.
        assertEq(aliceAfterMint, 0, "alice's ledger entry is wiped");
        assertEq(bobAfterMint, 0, "and it has NOT appeared on bob's ledger entry either");
        assertEq(countAfterMint, 0, "PoolManager believes nothing is outstanding at all");

        // 3. Bob converts the claim back into a live credit on HIS address, on demand.
        assertEq(bobAfterBurn, int256(AMT), "the credit is now bob's");

        emit log_named_uint("gas to relocate a delta between two addresses", gasLaunder);
        assertLt(gasLaunder, 150_000, "laundering is cheap");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        // Alice funds herself the honest way: real tokens in.
        pm.sync(c);
        token.transfer(address(pm), AMT);
        pm.settle();
        aliceAfterSettle = _delta(address(this));
        countAfterSettle = _count();

        uint256 g0 = gasleft();
        // The entire evasion. No ERC20 leaves anyone's balance. No capital is posted.
        pm.mint(address(bob), c.toId(), AMT);
        aliceAfterMint = _delta(address(this));
        bobAfterMint = _delta(address(bob));
        countAfterMint = _count();

        bob.absorb(c, AMT);
        gasLaunder = g0 - gasleft();
        bobAfterBurn = _delta(address(bob));

        // Bob settles the session; Alice never appears to have been owed anything.
        bob.cashOut(c, AMT, address(this));
        return "";
    }
}
