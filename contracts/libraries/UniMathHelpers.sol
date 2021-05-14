//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import '../uniswap-v3/libraries/FullMath.sol';
import '../uniswap-v3/libraries/TickMath.sol';
import '../uniswap-v3/interfaces/IUniswapV3Pool.sol';
import '../uniswap-v3/libraries/LowGasSafeMath.sol';

library UniMathHelpers {
  /// @notice Given a sqrtRatio and a token amount, calculates the amount of token received in exchange
  /// @param sqrtRatioX96 Sqare root ratio price
  /// @param baseAmount Amount of token to be converted
  /// @param baseToken Address of an ERC20 token contract used as the baseAmount denomination
  /// @param quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
  /// @return quoteAmount Amount of quoteToken received for baseAmount of baseToken
  function getQuoteFromSqrt(
    uint160 sqrtRatioX96,
    uint128 baseAmount,
    address baseToken,
    address quoteToken
  ) internal pure returns (uint256 quoteAmount) {
    // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
    if (sqrtRatioX96 <= type(uint128).max) {
      uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
      quoteAmount = baseToken < quoteToken
        ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
        : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
    } else {
      uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
      quoteAmount = baseToken < quoteToken
        ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
        : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
    }
  }
}
