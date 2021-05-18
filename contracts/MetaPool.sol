//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3Pool } from "./uniswap-v3/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "./uniswap-v3/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3MintCallback } from "./uniswap-v3/interfaces/callback/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "./uniswap-v3/interfaces/callback/IUniswapV3SwapCallback.sol";
import { LowGasSafeMath } from "./uniswap-v3/libraries/LowGasSafeMath.sol";
import { SqrtPriceMath } from "./uniswap-v3/libraries/SqrtPriceMath.sol";
import { TickMath } from "./uniswap-v3/libraries/TickMath.sol";
import { IERC20Minimal } from './uniswap-v3/interfaces/IERC20Minimal.sol';

import { TransferHelper } from "./libraries/TransferHelper.sol";
import { LiquidityAmounts } from "./libraries/LiquidityAmounts.sol";
import { UniMathHelpers } from "./libraries/UniMathHelpers.sol";
import { ERC20 } from "./ERC20.sol";
import "hardhat/console.sol";

contract MetaPool is IUniswapV3MintCallback, IUniswapV3SwapCallback, ERC20 {
  using LowGasSafeMath for uint256;

  IUniswapV3Pool public immutable pool;

  address public immutable token0; // wstETH
  address public immutable token1; // WETH

  int24 public immutable tightLowerTick;
  int24 public immutable tightUpperTick;
  int24 public immutable wideLowerTick;
  int24 public immutable wideUpperTick;

  uint24 public immutable maxTickMovement;

  uint160 public immutable tightLowerSqrtRatioX96;
  uint160 public immutable tightUpperSqrtRatioX96;
  uint160 public immutable wideLowerSqrtRatioX96;
  uint160 public immutable wideUpperSqrtRatioX96;

  bytes32 public immutable tightPositionID;
  bytes32 public immutable widePositionID;

  constructor(
    IUniswapV3Pool _pool,
    int24 _tightLowerTick,
    int24 _tightUpperTick,
    int24 _wideLowerTick,
    int24 _wideUpperTick,
    uint24 _maxTickMovement
  ) {
    pool = _pool;
    token0 = _pool.token0();
    token1 = _pool.token1();

    _pool.increaseObservationCardinalityNext(30);

    tightLowerTick = _tightLowerTick;
    tightUpperTick = _tightUpperTick;
    wideLowerTick = _wideLowerTick;
    wideUpperTick = _wideUpperTick;
    tightLowerSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_tightLowerTick);
    tightUpperSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_tightUpperTick);
    wideLowerSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_wideLowerTick);
    wideUpperSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_wideUpperTick);

    maxTickMovement = _maxTickMovement;

    tightPositionID = keccak256(abi.encodePacked(address(this), _tightLowerTick, _tightUpperTick));
    widePositionID = keccak256(abi.encodePacked(address(this), _wideLowerTick, _wideUpperTick));
  }

  ///
  //  View functions
  ///

  function tightPosition() external view returns (
    uint256 token0Amount,
    uint256 token1Amount,
    uint128 liquidity
  ) {
    (liquidity,,,,) = pool.positions(tightPositionID);

    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    (token0Amount, token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, tightLowerSqrtRatioX96, tightUpperSqrtRatioX96, liquidity);
  }

  function widePosition() external view returns (
    uint256 token0Amount,
    uint256 token1Amount,
    uint128 liquidity
  ) {
    bytes32 positionID = keccak256(abi.encodePacked(address(this), wideLowerTick, wideUpperTick));
    (liquidity,,,,) = pool.positions(positionID);

    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    (token0Amount, token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, wideLowerSqrtRatioX96, wideUpperSqrtRatioX96, liquidity);
  }

  function totalPosition() external view returns (uint256 token0Amount, uint256 token1Amount) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    (uint128 tightLiquidity,,,,) = pool.positions(tightPositionID);
    (uint256 tightToken0, uint256 tightToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, tightLowerSqrtRatioX96, tightUpperSqrtRatioX96, tightLiquidity);

    (uint128 wideLiquidity,,,,) = pool.positions(widePositionID);
    (uint256 wideToken0, uint256 wideToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, wideLowerSqrtRatioX96, wideUpperSqrtRatioX96, wideLiquidity);

    return (tightToken0 + wideToken0, tightToken1 + wideToken1);
  }

  ///
  //  Mutative functions
  ///

  function depositFromToken0Amount(
    uint256 amount0Desired,
    uint256 amount0Min,
    uint256 amount1Min
  ) external returns (uint256 mintAmount) {
    uint256 tightAmount0Desired = amount0Desired.mul(8000) / 10000; // 80%
    uint256 wideAmount0Desired = amount0Desired - tightAmount0Desired; // 20%, can't overflow

    (uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();
    require(tick <= tightUpperTick, "Outside range");

    (uint128 initialTightLiquidity, , , , ) = pool.positions(tightPositionID);
    (uint128 initialWideLiquidity, , , , ) = pool.positions(widePositionID);

    uint128 newTightLiquidity = LiquidityAmounts.getLiquidityForAmount0(
      sqrtRatioX96 < tightLowerSqrtRatioX96 ? tightLowerSqrtRatioX96 : sqrtRatioX96,
      tightUpperSqrtRatioX96,
      tightAmount0Desired
    );

    uint128 newWideLiquidity = LiquidityAmounts.getLiquidityForAmount0(
      sqrtRatioX96 < wideLowerSqrtRatioX96 ? wideLowerSqrtRatioX96 : sqrtRatioX96,
      wideUpperSqrtRatioX96,
      wideAmount0Desired
    );

    { // Prevent stack too deep
      (uint256 tightToken0, uint256 tightToken1) = pool.mint(
        address(this),
        tightLowerTick,
        tightUpperTick,
        newTightLiquidity,
        abi.encode(msg.sender) // Data field for uniswapV3MintCallback
      );

      (uint256 wideToken0, uint256 wideToken1) = pool.mint(
        address(this),
        wideLowerTick,
        wideUpperTick,
        newWideLiquidity,
        abi.encode(msg.sender) // Data field for uniswapV3MintCallback
      );

      require(tightToken0 + wideToken0 >= amount0Min && tightToken1 + wideToken1 >= amount1Min, "Slippage");
    }

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving
    if (_totalSupply == 0) {
      mintAmount = uint256(newTightLiquidity).mul(8000).add(uint256(newWideLiquidity).mul(2000)) / 10000;
    } else {
      uint256 tightRatio = uint256(newTightLiquidity).mul(_totalSupply) / initialTightLiquidity;
      uint256 wideRatio = uint256(newWideLiquidity).mul(_totalSupply) / initialWideLiquidity;
      mintAmount = tightRatio.mul(8000).add(wideRatio.mul(2000)) / 10000; // Mean of the two liquidity ratios
    }
    _mint(msg.sender, mintAmount);
  }

  function depositFromToken1Amount(
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min
  ) external returns (uint256 mintAmount) {
    uint256 tightAmount1Desired = amount1Desired.mul(8000) / 10000; // 80%
    uint256 wideAmount1Desired = amount1Desired - tightAmount1Desired; // 20%, can't overflow

    (uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();
    require(tick >= tightLowerTick, "Outside range");
    (uint128 initialTightLiquidity, , , , ) = pool.positions(tightPositionID);
    (uint128 initialWideLiquidity, , , , ) = pool.positions(widePositionID);

    uint128 newTightLiquidity = LiquidityAmounts.getLiquidityForAmount1(
      tightLowerSqrtRatioX96,
      sqrtRatioX96 > tightUpperSqrtRatioX96 ? tightUpperSqrtRatioX96 : sqrtRatioX96,
      tightAmount1Desired
    );

    uint128 newWideLiquidity = LiquidityAmounts.getLiquidityForAmount1(
      wideLowerSqrtRatioX96,
      sqrtRatioX96 > wideUpperSqrtRatioX96 ? wideUpperSqrtRatioX96 : sqrtRatioX96,
      wideAmount1Desired
    );

    { // Prevent stack too deep
      (uint256 tightToken0, uint256 tightToken1) = pool.mint(
        address(this),
        tightLowerTick,
        tightUpperTick,
        newTightLiquidity,
        abi.encode(msg.sender) // Data field for uniswapV3MintCallback
      );

      (uint256 wideToken0, uint256 wideToken1) = pool.mint(
        address(this),
        wideLowerTick,
        wideUpperTick,
        newWideLiquidity,
        abi.encode(msg.sender) // Data field for uniswapV3MintCallback
      );

      require(tightToken0 + wideToken0 >= amount0Min && tightToken1 + wideToken1 >= amount1Min, "Slippage");
    }

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving
    if (_totalSupply == 0) {
      mintAmount = uint256(newTightLiquidity).mul(8000).add(uint256(newWideLiquidity).mul(2000)) / 10000;
    } else {
      uint256 tightRatio = uint256(newTightLiquidity).mul(_totalSupply) / initialTightLiquidity;
      uint256 wideRatio = uint256(newWideLiquidity).mul(_totalSupply) / initialWideLiquidity;
      mintAmount = tightRatio.mul(8000).add(wideRatio.mul(2000)) / 10000; // Mean of the two liquidity ratios
    }
    _mint(msg.sender, mintAmount);
  }

  function burn(
    uint256 burnAmount,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 deadline,
    address recipient
  ) external returns (uint256 amount0, uint256 amount1) {
    require(deadline >= block.timestamp);

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving

    _burn(msg.sender, burnAmount);

    {
      (uint128 tightLiqiudity,,,,) = pool.positions(tightPositionID);

      uint256 tightLiquidityBurned = burnAmount.mul(tightLiqiudity) / _totalSupply; // Can't overflow
      require(tightLiquidityBurned < type(uint128).max); // Check so we can cast to 128

      (amount0, amount1) = pool.burn(tightLowerTick, tightUpperTick, uint128(tightLiquidityBurned));

      // Withdraw tokens to user
      pool.collect(
        recipient,
        tightLowerTick,
        tightUpperTick,
        uint128(amount0), // cast can't overflow
        uint128(amount1) // cast can't overflow
      );
    }

    {
      (uint128 wideLiquidity,,,,) = pool.positions(widePositionID);

      uint256 wideLiquidityBurned = burnAmount.mul(wideLiquidity) / _totalSupply; // Can't overflow
      require(wideLiquidityBurned < type(uint128).max); // Check so we can cast to 128

      (uint256 wideAmount0, uint256 wideAmount1) =
        pool.burn(wideLowerTick, wideUpperTick, uint128(wideLiquidityBurned));

      // Can't overflow
      amount0 += wideAmount0;
      amount1 += wideAmount1;

      // Withdraw tokens to user
      pool.collect(
        recipient,
        wideLowerTick,
        wideUpperTick,
        uint128(wideAmount0), // cast can't overflow
        uint128(wideAmount1) // cast can't overflow
      );
    }

    require(amount0 >= amount0Min && amount1 >= amount1Min, "Slippage");
  }

  function rebalance() external {
    // Calling burn with 0 liquidity will update fee balances
    pool.burn(tightLowerTick, tightUpperTick, 0);
    pool.burn(wideLowerTick, wideUpperTick, 0);

    // Collect fees from tight range
    pool.collect(
      address(this),
      tightLowerTick,
      tightUpperTick,
      // We can request MAX_INT, and Uniswap will just give whatever we're owed
      type(uint128).max,
      type(uint128).max
    );

    // Collect fees from wide range
    pool.collect(
      address(this),
      wideLowerTick,
      wideUpperTick,
      // We can request MAX_INT, and Uniswap will just give whatever we're owed
      type(uint128).max,
      type(uint128).max
    );

    deposit();
  }

  ///
  //  Private functions
  ///

  function deposit() private {
    requireMinimalPriceMovement();
    // (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
    // TODO: check against TWAP

    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    // Query the actual balances, so we can soop up any un-deposited
    // tokens from the last rebalance
    uint256 amount0 = IERC20Minimal(token0).balanceOf(address(this));
    uint256 amount1 = IERC20Minimal(token1).balanceOf(address(this));

    {
      uint256 tightAmount0Desired = amount0.mul(8000) / 10000; // 80%
      uint256 tightAmount1Desired = amount1.mul(8000) / 10000; // 80%
      uint256 wideAmount0Desired = amount0.mul(2000) / 10000; // 20%
      uint256 wideAmount1Desired = amount1.mul(2000) / 10000; // 20%

      uint128 newTightLiquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtRatioX96,
        tightLowerSqrtRatioX96,
        tightUpperSqrtRatioX96,
        tightAmount0Desired,
        tightAmount1Desired
      );

      uint128 newWideLiquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtRatioX96,
        wideLowerSqrtRatioX96,
        wideUpperSqrtRatioX96,
        wideAmount0Desired,
        wideAmount1Desired
      );

      (uint256 tightToken0, uint256 tightToken1) = pool.mint(
        address(this),
        tightLowerTick,
        tightUpperTick,
        newTightLiquidity,
        abi.encode(address(this)) // Data field for uniswapV3MintCallback
      );

      (uint256 wideToken0, uint256 wideToken1) = pool.mint(
        address(this),
        wideLowerTick,
        wideUpperTick,
        newWideLiquidity,
        abi.encode(address(this)) // Data field for uniswapV3MintCallback
      );

      amount0 -= (tightToken0 + wideToken0);
      amount1 -= (tightToken1 + wideToken1);
    }

    // If we still have some left-over, we need to swap so it's balanced
    // We check if it's bigger than 2, since there's no use in swapping dust
    if (amount0 > 2 || amount1 > 2) {
      // NOTE: These calculations assume 1 wstETH ~= 1 ETH
      bool zeroForOne;
      int256 swapAmount;
      if (amount0 <= 2 || amount1 <= 2) {
        zeroForOne = amount0 > amount1;
        swapAmount = int256(zeroForOne ? amount0 : amount1) / 2;
      } else {
        uint256 equivelantAmount0 = UniMathHelpers.getQuoteFromSqrt(sqrtRatioX96, uint128(amount1), token1, token0);
        zeroForOne = amount0 > equivelantAmount0;
        swapAmount = zeroForOne
          ? int256(amount0 - equivelantAmount0)
          : int256(amount1 - UniMathHelpers.getQuoteFromSqrt(sqrtRatioX96, uint128(amount0), token0, token1));
      }

      (int256 amount0Delta, int256 amount1Delta) = pool.swap(
        address(this),
        zeroForOne,
        swapAmount,
        zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
        abi.encode(address(this))
      );

      amount0 = uint256(int256(amount0) - amount0Delta);
      amount1 = uint256(int256(amount1) - amount1Delta);

      // Add liquidity a second time
      {
        uint256 tightAmount0Desired = amount0.mul(8000) / 10000; // 80%
        uint256 tightAmount1Desired = amount1.mul(8000) / 10000; // 80%
        uint256 wideAmount0Desired = amount0.mul(2000) / 10000; // 20%
        uint256 wideAmount1Desired = amount1.mul(2000) / 10000; // 20%

        uint128 newTightLiquidity = LiquidityAmounts.getLiquidityForAmounts(
          sqrtRatioX96,
          tightLowerSqrtRatioX96,
          tightUpperSqrtRatioX96,
          tightAmount0Desired,
          tightAmount1Desired
        );

        uint128 newWideLiquidity = LiquidityAmounts.getLiquidityForAmounts(
          sqrtRatioX96,
          wideLowerSqrtRatioX96,
          wideUpperSqrtRatioX96,
          wideAmount0Desired,
          wideAmount1Desired
        );

        pool.mint(
          address(this),
          tightLowerTick,
          tightUpperTick,
          newTightLiquidity,
          abi.encode(address(this)) // Data field for uniswapV3MintCallback
        );

        pool.mint(
          address(this),
          wideLowerTick,
          wideUpperTick,
          newWideLiquidity,
          abi.encode(address(this)) // Data field for uniswapV3MintCallback
        );
      }
    }
  }

  function requireMinimalPriceMovement() private view {
    // Q: Should we simplify this and just ensure it's inside the tight range?
    (, int24 currentTick, , , , , ) = pool.slot0();

    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = 5 minutes;
    secondsAgos[1] = 0;
    (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

    int24 averageTick = int24(int256(tickCumulatives[1] - tickCumulatives[0]) / 5 minutes);

    int24 diff = averageTick > currentTick ? averageTick - currentTick : currentTick - averageTick;
    require(uint24(diff) < maxTickMovement, "Slippage");
  }

  function uniswapV3MintCallback(
    uint256 amount0Owed,
    uint256 amount1Owed,
    bytes calldata data
  ) external override {
    require(msg.sender == address(pool));

    (address sender) = abi.decode(data, (address));

    if (sender == address(this)) {
      if (amount0Owed > 0) {
        TransferHelper.safeTransfer(token0, msg.sender, amount0Owed);
      }
      if (amount1Owed > 0) {
        TransferHelper.safeTransfer(token1, msg.sender, amount1Owed);
      }
    } else {
      if (amount0Owed > 0) {
        TransferHelper.safeTransferFrom(token0, sender, msg.sender, amount0Owed);
      }
      if (amount1Owed > 0) {
        TransferHelper.safeTransferFrom(token1, sender, msg.sender, amount1Owed);
      }
    }
  }

  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata /*data*/
  ) external override {
    require(msg.sender == address(pool));

    if (amount0Delta > 0) {
      TransferHelper.safeTransfer(token0, msg.sender, uint256(amount0Delta));
    } else if (amount1Delta > 0) {
      TransferHelper.safeTransfer(token1, msg.sender, uint256(amount1Delta));
    }
  }
}
