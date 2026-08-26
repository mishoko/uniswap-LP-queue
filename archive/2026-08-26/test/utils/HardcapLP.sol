// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {HardcapHook} from "../../src/HardcapHook.sol";

/// @notice Position owner for Hardcap tests. PoolManager keys the position to this contract
/// (the unlock caller), not the EOA. `claim` must therefore be invoked here.
contract HardcapLP is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result = manager.unlock(abi.encode(msg.sender, key, params, hookData));
        return abi.decode(result, (BalanceDelta));
    }

    /// @dev Position owner and token payer are this contract (not the EOA). Use for economic tests.
    function modifyLiquiditySelf(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result = manager.unlock(abi.encode(address(this), key, params, hookData));
        return abi.decode(result, (BalanceDelta));
    }

    function claim(HardcapHook hook, int24 tickLower, int24 tickUpper, bytes32 salt) external {
        hook.claim(tickLower, tickUpper, salt);
        _forward(hook.currency0(), msg.sender);
        _forward(hook.currency1(), msg.sender);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert();

        (address payer, PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData) =
            abi.decode(raw, (address, PoolKey, ModifyLiquidityParams, bytes));

        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, hookData);

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (d0 < 0) key.currency0.settle(manager, payer, uint256(uint128(-d0)), false);
        if (d1 < 0) key.currency1.settle(manager, payer, uint256(uint128(-d1)), false);
        if (d0 > 0) key.currency0.take(manager, payer, uint256(uint128(d0)), false);
        if (d1 > 0) key.currency1.take(manager, payer, uint256(uint128(d1)), false);

        return abi.encode(delta);
    }

    function _forward(Currency currency, address to) private {
        uint256 bal = currency.balanceOfSelf();
        if (bal > 0) currency.transfer(to, bal);
    }
}
