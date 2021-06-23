// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.7.6;

import { IERC20Minimal } from "../uniswap-v3/interfaces/IERC20Minimal.sol";
import { IUniswapV3SwapCallback } from "../uniswap-v3/interfaces/callback/IUniswapV3SwapCallback.sol";
import { IUniswapV3Pool } from "../uniswap-v3/interfaces/IUniswapV3Pool.sol";
import { TickMath } from "../uniswap-v3/libraries/TickMath.sol";

contract SwapTest is IUniswapV3SwapCallback {
    function swap(
        address pool,
        bool zeroForOne,
        int256 amountSpecified
    )
        external
    {
        IUniswapV3Pool(pool).swap(
            address(1),
            zeroForOne,
            amountSpecified,
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(msg.sender)
        );
    }

    function washTrade(
        address pool,
        int256 amountSpecified,
        uint256 numTrades,
        uint256 ratio
    )
        external
    {
        for (uint i = 0; i < numTrades; i++) {
            bool zeroForOne = i % ratio > 0;
            IUniswapV3Pool(pool).swap(
                address(1),
                zeroForOne,
                amountSpecified,
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                abi.encode(msg.sender)
            );
            if (i % ratio == 0 || (i + 1) % ratio == 0) {
                amountSpecified = amountSpecified * -1;
            }
        }
    }



    function getSwapResult(
        address pool,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    )
        external
        returns (
            int256 amount0Delta,
            int256 amount1Delta,
            uint160 nextSqrtRatio
        )
    {
        (amount0Delta, amount1Delta) = IUniswapV3Pool(pool).swap(
            address(1),
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(msg.sender)
        );

        (nextSqrtRatio, , , , , , ) = IUniswapV3Pool(pool).slot0();
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        address sender = abi.decode(data, (address));

        if (amount0Delta > 0) {
            IERC20Minimal(IUniswapV3Pool(msg.sender).token0()).transferFrom(sender, msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20Minimal(IUniswapV3Pool(msg.sender).token1()).transferFrom(sender, msg.sender, uint256(amount1Delta));
        }
    }
}
