// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {HardcapHook} from "../src/HardcapHook.sol";
import {HardcapHookFinal} from "../src/HardcapHookFinal.sol";

/// @notice Mines CREATE2 flags and deploys HardcapHook. Currencies come from BaseScript config.
contract DeployHardcapScript is BaseScript {
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    function run() public {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs =
            abi.encode(poolManager, currency0, currency1, FEE, TICK_SPACING, uint16(0), uint16(15), uint48(1));

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(HardcapHookFinal).creationCode, constructorArgs);

        vm.startBroadcast();
        HardcapHookFinal hook = new HardcapHookFinal{salt: salt}(
            poolManager, currency0, currency1, FEE, TICK_SPACING, uint16(0), uint16(15), uint48(1)
        );
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHardcap: flag mismatch");
        require(hook.extraFeeBps() <= hook.maxTakeBps(), "DeployHardcap: extra > max");
    }
}
