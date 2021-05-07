//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import { IMetaPoolFactory } from "./interfaces/IMetaPoolFactory.sol";
import { TransferHelper } from "./libraries/TransferHelper.sol";
import { LiquidityAmounts } from "./libraries/LiquidityAmounts.sol";
import { ERC20 } from "./ERC20.sol";

contract MetaPool is IUniswapV3MintCallback, IUniswapV3SwapCallback, ERC20 {
  using LowGasSafeMath for uint256;

  address public immutable token0; // wstETH
  address public immutable token1; // WETH

  int24 public immutable tightLowerTick;
  int24 public immutable tightUpperTick;
  int24 public immutable wideLowerTick;
  int24 public immutable wideUpperTick;

  uint160 public immutable tightLowerSqrtRatioX96;
  uint160 public immutable tightUpperSqrtRatioX96;
  uint160 public immutable wideLowerSqrtRatioX96;
  uint160 public immutable wideUpperSqrtRatioX96;

  IUniswapV3Pool public immutable pool;

  constructor(
    IUniswapV3Pool _pool,
    int24 _tightLowerTick,
    int24 _tightUpperTick,
    int24 _wideLowerTick,
    int24 _wideUpperTick
  ) {
    pool = _pool;
    token0 = _pool.token0();
    token1 = _pool.token1();

    tightLowerTick = _tightLowerTick;
    tightUpperTick = _tightUpperTick;
    wideLowerTick = _wideLowerTick;
    wideUpperTick = _wideUpperTick;
    tightLowerSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_tightLowerTick);
    tightUpperSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_tightUpperTick);
    wideLowerSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_wideLowerTick);
    wideUpperSqrtRatioX96 = TickMath.getSqrtRatioAtTick(_wideUpperTick);
  }

  function mint(
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min
  ) external returns (uint256 mintAmount) {
    // Casts don't overflow, since we're decreasing the number
    // uint128 newTightLiquidity = uint128(uint256(newLiquidity).mul(8000) / 10000); // 80%
    // uint128 newWideLiquidity = uint128(uint256(newLiquidity).mul(2000) / 10000); // 20%

    uint256 tightAmount0Desired = amount0Desired.mul(8000) / 10000; // 80%
    uint256 tightAmount1Desired = amount1Desired.mul(8000) / 10000; // 80%
    uint256 wideAmount0Desired = amount0Desired.mul(2000) / 10000; // 80%
    uint256 wideAmount1Desired = amount1Desired.mul(2000) / 10000; // 80%

    (
      uint128 initialTightLiquidity,
      uint128 newTightLiquidity,
      uint256 tightToken0,
      uint256 tightToken1
    ) = mintPosition(
      tightAmount0Desired,
      tightAmount1Desired,
      tightLowerTick,
      tightUpperTick,
      tightLowerSqrtRatioX96,
      tightUpperSqrtRatioX96,
      msg.sender
    );

    (
      uint128 initialWideLiquidity,
      uint128 newWideLiquidity,
      uint256 wideToken0,
      uint256 wideToken1
    ) = mintPosition(
      wideAmount0Desired,
      wideAmount1Desired,
      wideLowerTick,
      wideUpperTick,
      wideLowerSqrtRatioX96,
      wideUpperSqrtRatioX96,
      msg.sender
    );

    require(tightToken0 + wideToken0 >= amount0Min && tightToken1 + wideToken1 >= amount1Min, "Slippage");

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving
    if (_totalSupply == 0) {
      mintAmount = (newTightLiquidity + newWideLiquidity) / 2;
    } else {
      uint256 tightRatio = uint256(newTightLiquidity).mul(_totalSupply) / initialTightLiquidity;
      uint256 wideRatio = uint256(newWideLiquidity).mul(_totalSupply) / initialWideLiquidity;
      mintAmount = tightRatio.add(wideRatio) / 2; // Mean of the two liquidity ratios
    }
    _mint(msg.sender, mintAmount);
  }

  function burn(
    uint256 burnAmount,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 deadline
  ) external returns (uint256 amount0, uint256 amount1) {
    require(deadline >= block.timestamp);

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving

    _burn(msg.sender, burnAmount);


    // (lpBurn/totalSupply) * liquidity * percent

    (uint256 tightAmount0, uint256 tightAmount1) = burnPosition(
      burnAmount.mul(8e18) / _totalSupply, // 80%
      tightLowerTick,
      tightUpperTick
    );
    (uint256 wideAmount0, uint256 wideAmount1) = burnPosition(
      burnAmount.mul(2e18) / _totalSupply, // 20%
      wideLowerTick,
      wideUpperTick
    );

    amount0 = tightAmount0 + wideAmount0; // Can't overflow
    amount1 = tightAmount1 + wideAmount1; // Can't overflow
    require(amount0 >= amount0Min && amount1 >= amount1Min, "Slippage");
  }

  function rebalance() external {
    claim(tightLowerTick, tightUpperTick);
    claim(wideLowerTick, wideUpperTick);

    deposit();
  }

  ///
  //  Private functions
  ///

  /// dev Deposits a given amount of liquidity into a Uniswap position
  /// param liquidity The liquidity paramater to be passed to Uniswap
  /// param lowerTick The lower tick of the position's tick range
  /// param upperTick The upper tick of the position's tick range
  /// return initialLiquidity The amount of liquidity held by the MetaPool before the deposit
  
  // test
  function mintPosition(
    uint256 amount0Desired,
    uint256 amount1Desired,
    int24 tickLower,
    int24 tickUpper,
    uint160 sqrtRatio0X96,
    uint160 sqrtRatio1X96,
    address sender
  ) internal returns (
    uint128 initialLiquidity,
    uint128 newLiquidity,
    uint256 amount0,
    uint256 amount1
  ) {
    {
      bytes32 positionID = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
      (initialLiquidity,,,,) = pool.positions(positionID);
    }

    // compute the liquidity amount
    {
      (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

      newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtPriceX96,
        sqrtRatio0X96,
        sqrtRatio1X96,
        amount0Desired,
        amount1Desired
      );
    }

    (amount0, amount1) = pool.mint(
      address(this),
      tickLower,
      tickUpper,
      newLiquidity,
      abi.encode(sender) // Data field for uniswapV3MintCallback
    );
  }

  /// @dev Withdraw liquidity from a single position to the sender
  /// @param burnRatio The amount of LP tokens burned, multiplied by the total token
  ///   supply before the burn (this is ugly, but saves gas by preventing multiple SLOADs)
  /// @param lowerTick The lower tick of the position's tick range
  /// @param upperTick The upper tick of the position's tick range
  /// @return amount0 The amount of token0 withdrawn to the sender address
  /// @return amount1 The amount of token1 withdrawn to the sender address
  function burnPosition(
    uint256 burnRatio,
    int24 lowerTick,
    int24 upperTick
  ) private returns (uint256 amount0, uint256 amount1) {
    bytes32 positionID = keccak256(abi.encodePacked(address(this), lowerTick, upperTick));
    (uint128 liqiudity,,,,) = pool.positions(positionID);

    uint256 liquidityBurned = burnRatio.mul(liqiudity) / 10e18; // Can't overflow
    require(liquidityBurned < type(uint128).max); // Check so we can cast to 128

    (amount0, amount1) = pool.burn(lowerTick, upperTick, uint128(liquidityBurned));

    // Withdraw tokens to user
    pool.collect(
      msg.sender, // We only ever burn to the user, so we can hardcode msg.sender to save gas
      lowerTick,
      upperTick,
      uint128(amount0), // cast can't overflow
      uint128(amount1) // cast can't overflow
    );
  }

  function deposit() private {
    requireMinimalPriceMovement();
    // (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
    // TODO: check against TWAP

    // First, deposit as much as we can
    // uint128 baseLiquidity = LiquidityAmounts.getLiquidityForAmounts(
    //   sqrtRatioX96,
    //   // Todo: inline these
    //   TickMath.getSqrtRatioAtTick(tightLowerTick),
    //   TickMath.getSqrtRatioAtTick(tightUpperTick),
    //   amount0,
    //   amount1
    // );
    // (uint256 amountDeposited0, uint256 amountDeposited1) = pool.mint(
    //   address(this),
    //   tightLowerTick,
    //   tightUpperTick,
    //   baseLiquidity,
    //   abi.encode(address(this))
    // );

    // Query the actual balances, so we can soop up any un-deposited
    // tokens from the last rebalance
    uint256 amount0 = ERC20(token0).balanceOf(address(this));
    uint256 amount1 = ERC20(token1).balanceOf(address(this));

    {
      uint256 tightAmount0Desired = amount0.mul(8000) / 10000; // 80%
      uint256 tightAmount1Desired = amount1.mul(8000) / 10000; // 80%
      uint256 wideAmount0Desired = amount0.mul(2000) / 10000; // 80%
      uint256 wideAmount1Desired = amount1.mul(2000) / 10000; // 80%

      ( , , uint256 tightToken0, uint256 tightToken1) = mintPosition(
        tightAmount0Desired,
        tightAmount1Desired,
        tightLowerTick,
        tightUpperTick,
        tightLowerSqrtRatioX96,
        tightUpperSqrtRatioX96,
        address(this)
      );

      ( , , uint256 wideToken0, uint256 wideToken1) = mintPosition(
        wideAmount0Desired,
        wideAmount1Desired,
        wideLowerTick,
        wideUpperTick,
        wideLowerSqrtRatioX96,
        wideUpperSqrtRatioX96,
        address(this)
      );

      amount0 -= (tightToken0 + wideToken0);
      amount1 -= (tightToken1 + wideToken1);
    }

    // If we still have some leftover, we need to swap so it's balanced
    // This part is still a PoC, would need much more intelligent swapping
    if (amount0 > 0 || amount1 > 0) {
      // NOTE: These calculations assume 1 wstETH ~= 1 ETH
      bool zeroForOne = amount0 > amount1;

      (int256 amount0Delta, int256 amount1Delta) = pool.swap(
        address(this),
        zeroForOne,
        int256(zeroForOne ? amount0 : amount1) / 2,
        zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
        abi.encode(address(this))
      );

      amount0 = uint256(int256(amount0) - amount0Delta);
      amount1 = uint256(int256(amount1) - amount1Delta);

      // Add liquidity a second time
      {
        uint256 tightAmount0Desired = amount0.mul(8000) / 10000; // 80%
        uint256 tightAmount1Desired = amount1.mul(8000) / 10000; // 80%
        uint256 wideAmount0Desired = amount0.mul(2000) / 10000; // 80%
        uint256 wideAmount1Desired = amount1.mul(2000) / 10000; // 80%

        /*( , , uint256 tightToken0, uint256 tightToken1) =*/ mintPosition(
          tightAmount0Desired,
          tightAmount1Desired,
          tightLowerTick,
          tightUpperTick,
          tightLowerSqrtRatioX96,
          tightUpperSqrtRatioX96,
          address(this)
        );

        /*( , , uint256 wideToken0, uint256 wideToken1) =*/ mintPosition(
          wideAmount0Desired,
          wideAmount1Desired,
          wideLowerTick,
          wideUpperTick,
          wideLowerSqrtRatioX96,
          wideUpperSqrtRatioX96,
          address(this)
        );
      }
    }
  }

  function claim(
    int24 lowerTick,
    int24 upperTick
  ) private /*returns (uint256 collected0, uint256 collected1)*/ {
    pool.burn(lowerTick, upperTick, 0); // Calling burn with 0 liquidity will update fee balances

    // Collect all fees owed
    /*(collected0, collected1) =*/ pool.collect(
      address(this),
      lowerTick,
      upperTick,
      // We can request MAX_INT, and Uniswap will just give whatever we're owed
      type(uint128).max,
      type(uint128).max
    );
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
    require(diff < 100, "Slippage");
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
