// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IAssaySwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        PoolKey memory poolKey,
        bytes calldata hookData,
        address receiver,
        uint256 deadline
    ) external payable returns (int256);
}

interface IAssayLiquidityRouter {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData) external;
}

/// @notice Drives bounded, realistic traffic at a hook under test: swaps in both directions, exact
/// in and exact out, liquidity added and removed, and block advancement so per-block logic is
/// actually exercised.
///
/// Every call is wrapped in try/catch on purpose. A reverting operation is not a failure of the
/// campaign — for a fail-closed hook it is the expected outcome of an attempt to violate the spec,
/// and it is precisely the case the invariants must survive. A handler that let reverts bubble
/// would abort the sequence at the first refusal and never explore what happens afterwards.
contract AssayHandler {
    IPoolManager public immutable poolManager;
    IAssaySwapRouter public immutable swapRouter;
    IAssayLiquidityRouter public immutable liquidityRouter;
    PoolKey internal key;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    uint256 public swaps;
    uint256 public reverts;

    constructor(
        IPoolManager poolManager_,
        IAssaySwapRouter swapRouter_,
        IAssayLiquidityRouter liquidityRouter_,
        PoolKey memory key_,
        int24 tickLower_,
        int24 tickUpper_
    ) {
        poolManager = poolManager_;
        swapRouter = swapRouter_;
        liquidityRouter = liquidityRouter_;
        key = key_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function swap(bool zeroForOne, uint256 amountIn) external {
        amountIn = _bound(amountIn, 1e12, 5e17);
        try swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", address(this), type(uint256).max) {
            swaps++;
        } catch {
            reverts++;
        }
    }

    function addLiquidity(uint256 liq, uint256 saltSeed) external {
        try liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(_bound(liq, 1e16, 50e18)),
                salt: bytes32(_bound(saltSeed, 1, 4))
            }),
            ""
        ) {}
            catch {}
    }

    function removeLiquidity(uint256 liq, uint256 saltSeed) external {
        try liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(_bound(liq, 1e16, 50e18)),
                salt: bytes32(_bound(saltSeed, 1, 4))
            }),
            ""
        ) {}
            catch {}
    }

    /// @dev Without this the whole campaign runs inside one block and every per-block rule is
    /// exercised in exactly one state.
    function advanceBlock(uint256 n) external {
        uint256 target = block.number + _bound(n, 1, 3);
        vm().roll(target);
    }

    function vm() internal pure returns (VmLike) {
        return VmLike(address(uint160(uint256(keccak256("hevm cheat code")))));
    }
}

interface VmLike {
    function roll(uint256) external;
}
