//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3Pool } from "./uniswap-v3/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "./uniswap-v3/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3MintCallback } from "./uniswap-v3/interfaces/callback/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "./uniswap-v3/interfaces/callback/IUniswapV3SwapCallback.sol";
import { SqrtPriceMath } from "./uniswap-v3/libraries/SqrtPriceMath.sol";
import { TickMath } from "./uniswap-v3/libraries/TickMath.sol";
import { IERC20Minimal } from './uniswap-v3/interfaces/IERC20Minimal.sol';

import { TransferHelper } from "./libraries/TransferHelper.sol";
import { LiquidityAmounts } from "./libraries/LiquidityAmounts.sol";
import { LowGasSafeMath } from "./libraries/LowGasSafeMath.sol";
import { UniMathHelpers } from "./libraries/UniMathHelpers.sol";
import { ERC20 } from "./ERC20.sol";

/// @title MetaPool for allocating to the Lido stETH Uniswap V3 Pool
/// @author David Mihal
contract MetaPool is IUniswapV3MintCallback, IUniswapV3SwapCallback, ERC20 {
  using LowGasSafeMath for uint256;
  using LowGasSafeMath for uint128;

  IUniswapV3Pool public immutable pool;

  address public immutable token0; // wstETH
  address public immutable token1; // WETH

  int24 public immutable tightLowerTick;
  int24 public immutable tightUpperTick;
  int24 public immutable wideLowerTick;
  int24 public immutable wideUpperTick;

  uint24 public immutable maxTickMovement;

  uint128 public immutable liquidityRatio;

  uint160 public immutable tightLowerSqrtRatioX96;
  uint160 public immutable tightUpperSqrtRatioX96;
  uint160 public immutable wideLowerSqrtRatioX96;
  uint160 public immutable wideUpperSqrtRatioX96;

  bytes32 public immutable tightPositionID;
  bytes32 public immutable widePositionID;

  // We must track our own liquidity, to prevent someone from manipulating the liquidity ratio
  uint128 private tightLiquidity;
  uint128 private wideLiquidity;

  event Rebalanced(
    uint128 newTightLiquidity,
    uint128 newWideLiquidity,
    uint256 amount0Remainder,
    uint256 amount1Remainder
  );

  /// @param _pool Address of the Uniswap V3 pool to use
  /// @param _tightLowerTick Lower tick to use for the tight position
  /// @param _tightUpperTick Upper tick to use for the tight position
  /// @param _wideLowerTick Lower tick to use for the wide position
  /// @param _wideUpperTick Upper tick to use for the wide position
  /// @param _maxTickMovement Maximum number of ticks between the current tick & TWAP for rebalancing
  /// @param _liquidityRatio Default ratio of wide liquidity to tight liquidity
  constructor(
    IUniswapV3Pool _pool,
    int24 _tightLowerTick,
    int24 _tightUpperTick,
    int24 _wideLowerTick,
    int24 _wideUpperTick,
    uint24 _maxTickMovement,
    uint128 _liquidityRatio
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
    liquidityRatio = _liquidityRatio;

    tightPositionID = keccak256(abi.encodePacked(address(this), _tightLowerTick, _tightUpperTick));
    widePositionID = keccak256(abi.encodePacked(address(this), _wideLowerTick, _wideUpperTick));
  }

  ///
  //  View functions
  ///

  /// @notice Return the amount of tokens and liquidity held by the pool's tight position
  /// @return token0Amount Amount of token0 in the tight position
  /// @return token1Amount Amount of token1 in the tight position
  /// @return liquidity Amount Uniswap liquidity in the tight position
  function tightPosition() external view returns (
    uint256 token0Amount,
    uint256 token1Amount,
    uint128 liquidity
  ) {
    liquidity = tightLiquidity;
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    (token0Amount, token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, tightLowerSqrtRatioX96, tightUpperSqrtRatioX96, liquidity);
  }

  /// @notice Return the amount of tokens and liquidity held by the pool's wide position
  /// @return token0Amount Amount of token0 in the wide position
  /// @return token1Amount Amount of token1 in the wide position
  /// @return liquidity Amount Uniswap liquidity in the wide position
  function widePosition() external view returns (
    uint256 token0Amount,
    uint256 token1Amount,
    uint128 liquidity
  ) {
    liquidity = wideLiquidity;
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    (token0Amount, token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, wideLowerSqrtRatioX96, wideUpperSqrtRatioX96, liquidity);
  }

  /// @notice Return the total amount of tokens held by the pool's positions in Uniswap
  /// @return token0Amount Total amount of token0 held in the pool's positions
  /// @return token1Amount Total amount of token1 held in the pool's positions
  function totalPosition() external view returns (uint256 token0Amount, uint256 token1Amount) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    (uint256 tightToken0, uint256 tightToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, tightLowerSqrtRatioX96, tightUpperSqrtRatioX96, tightLiquidity);

    (uint256 wideToken0, uint256 wideToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, wideLowerSqrtRatioX96, wideUpperSqrtRatioX96, wideLiquidity);

    return (tightToken0 + wideToken0, tightToken1 + wideToken1); // Can't overflow
  }

  /// @notice Return the amount of tokens needed to mint a given amount of LP tokens
  /// @param newLPTokens Number of MetaPool LP tokens to simulate minting
  /// @return token0Amount Total amount of token0 that will be transfered to mint
  /// @return token1Amount Total amount of token1 that will be transfered to mint
  function previewMint(uint256 newLPTokens) external view returns (
    uint256 token0Amount,
    uint256 token1Amount
  ) {
    require(tightLiquidity > 0 && wideLiquidity > 0, "INI");

    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving
    uint256 newTightLiquidity = newLPTokens.mul(tightLiquidity) / _totalSupply;
    uint256 newWideLiquidity = newLPTokens.mul(wideLiquidity) / _totalSupply;

    // Check so we can cast to 128
    require(newTightLiquidity < type(uint128).max);
    require(newWideLiquidity < type(uint128).max);

    (uint256 tightToken0, uint256 tightToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, tightLowerSqrtRatioX96, tightUpperSqrtRatioX96, uint128(newTightLiquidity));

    (uint256 wideToken0, uint256 wideToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, wideLowerSqrtRatioX96, wideUpperSqrtRatioX96, uint128(newWideLiquidity));

    return (tightToken0.add(wideToken0), tightToken1.add(wideToken1));
  }

  /// @notice Return the amount of tokens returned when burning an amount of LP tokens
  /// @param burnAmount Number of MetaPool LP tokens to simulate burning
  /// @return token0Amount Total amount of token0 that will be returned
  /// @return token1Amount Total amount of token1 that will be returned
  function previewBurn(uint256 burnAmount) external view returns (
    uint256 token0Amount,
    uint256 token1Amount
  ) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    uint256 tightLiquidityBurned = burnAmount.mul(tightLiquidity) / totalSupply; // Can't overflow
    require(tightLiquidityBurned < type(uint128).max); // Check so we can cast to 128

    uint256 wideLiquidityBurned = burnAmount.mul(wideLiquidity) / totalSupply; // Can't overflow
    require(wideLiquidityBurned < type(uint128).max); // Check so we can cast to 128

    (uint256 tightToken0, uint256 tightToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, tightLowerSqrtRatioX96, tightUpperSqrtRatioX96, uint128(tightLiquidityBurned));
    (uint256 wideToken0, uint256 wideToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, wideLowerSqrtRatioX96, wideUpperSqrtRatioX96, uint128(wideLiquidityBurned));

    return (tightToken0 + wideToken0, tightToken1 + wideToken1); // Can't overflow
  }

  ///
  //  Mutative functions
  ///

  /// @notice Initialize the pool, depositting a negligable amount of tokens
  ///         and minting LP tokens to 0x0
  /// @dev The caller must have approved the contract to transfer token0 and token1
  function initialize() external {
    // Ensure the pool hasn't been initialized yet
    require(tightLiquidity == 0 && wideLiquidity == 0);

    pool.mint(
      address(this),
      wideLowerTick,
      wideUpperTick,
      100,
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    require(liquidityRatio * 100 > liquidityRatio); // Prevent overflow
    pool.mint(
      address(this),
      tightLowerTick,
      tightUpperTick,
      100 * liquidityRatio,
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    wideLiquidity = 100;
    tightLiquidity = 100 * liquidityRatio;

    _mint(address(0), 100);
  }

  /// @notice Deposits tokens into Uniswap positions and mints LP tokens
  /// @dev The caller must have approved the contract to transfer token0 and token1
  /// @param newLPTokens Number of MetaPool LP tokens to mint
  /// @param amount0Max Maximum amount of token0 to deposit, to prevent slippage
  /// @param amount1Max Maximum amount of token1 to deposit, to prevent slippage
  function mint(
    uint256 newLPTokens,
    uint256 amount0Max,
    uint256 amount1Max
  ) external notPaused {
    (uint128 initialTightLiquidity, uint128 initialWideLiquidity) = (tightLiquidity, wideLiquidity); // Single SLOAD
    // Ensure the pool is already initalized
    require(initialTightLiquidity > 0 && initialWideLiquidity > 0, "INI");

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving

    // Will deposit in the same ratio of liquidity tokens as the pool already holds
    uint256 newTightLiquidity = newLPTokens.mul(initialTightLiquidity) / _totalSupply;
    uint256 newWideLiquidity = newLPTokens.mul(initialWideLiquidity) / _totalSupply;

    // Check so we can cast to 128
    require(newTightLiquidity < type(uint128).max);
    require(newWideLiquidity < type(uint128).max);

    (uint256 tightToken0, uint256 tightToken1) = pool.mint(
      address(this),
      tightLowerTick,
      tightUpperTick,
      uint128(newTightLiquidity),
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    (uint256 wideToken0, uint256 wideToken1) = pool.mint(
      address(this),
      wideLowerTick,
      wideUpperTick,
      uint128(newWideLiquidity),
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    // Can't overflow
    require(tightToken0 + wideToken0 <= amount0Max && tightToken1 + wideToken1 <= amount1Max, "Slippage");

    tightLiquidity = initialTightLiquidity.add128(uint128(newTightLiquidity));
    wideLiquidity = initialWideLiquidity.add128(uint128(newWideLiquidity));

    _mint(msg.sender, newLPTokens);
  }

  /// @notice Burns LP tokens and returns underlying tokens to recipient
  /// @param burnAmount Number of MetaPool LP tokens to burn
  /// @param amount0Min Minimum number of token0 to receive, to prevent slippage
  /// @param amount1Min Minimum number of token0 to receive, to prevent slippage
  /// @param recipient Address to receive the underlying tokens (typically sender)
  /// @return amount0 Number of token0 returned
  /// @return amount1 Number of token1 returned
  function burn(
    uint256 burnAmount,
    uint256 amount0Min,
    uint256 amount1Min,
    address recipient
  ) external returns (uint256 amount0, uint256 amount1) {
    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving

    _burn(msg.sender, burnAmount);

    uint256 tightLiquidityBurned;
    uint256 wideLiquidityBurned;

    // Withdraw from tight position
    {
      tightLiquidityBurned = burnAmount.mul(tightLiquidity) / _totalSupply; // Can't overflow
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

    // Withdraw from wide position
    {
      wideLiquidityBurned = burnAmount.mul(wideLiquidity) / _totalSupply; // Can't overflow
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

    tightLiquidity = tightLiquidity.sub128(uint128(tightLiquidityBurned));
    wideLiquidity = wideLiquidity.sub128(uint128(wideLiquidityBurned));
  }

  /// @notice Claim all accrued fees and attempt to re-deposit into Uniswap positions
  function rebalance() external notPaused {
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

  /// @notice Tries to deposit remaining tokens into pool, distributing new liquidity to all users
  function deposit() private {
    requireMinimalPriceMovement();

    // Query the actual balances, so we can soop up any un-deposited
    // tokens from the last rebalance
    uint256 amount0 = IERC20Minimal(token0).balanceOf(address(this));
    uint256 amount1 = IERC20Minimal(token1).balanceOf(address(this));

    (uint128 newTightLiquidity, uint128 newWideLiquidity) = getLiquidityFromAmounts(amount0, amount1);
    (newTightLiquidity, newWideLiquidity) = balanceLiquidity(newTightLiquidity, newWideLiquidity);

    {
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

      // Can't overflow
      amount0 -= (tightToken0 + wideToken0);
      amount1 -= (tightToken1 + wideToken1);
    }

    tightLiquidity = tightLiquidity.add128(newTightLiquidity);
    wideLiquidity = wideLiquidity.add128(newWideLiquidity);

    emit Rebalanced(newTightLiquidity, newWideLiquidity, amount0, amount1);
  }

  /// @notice Calculates tight & wide liquidity values that are roughly within the liquidity ratio
  /// @param token0Amount Amount of token0 to deposit
  /// @param token1Amount Amount of token1 to deposit
  /// @return newTightLiquidity Calculated amount of tight liquidity
  /// @return newWideLiquidity Calculated amount of wide liquidity
  function getLiquidityFromAmounts(
    uint256 token0Amount,
    uint256 token1Amount
  ) private view returns (
    uint128 newTightLiquidity,
    uint128 newWideLiquidity
  ) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    uint256 token0Wide = token0Amount / (liquidityRatio + 1);
    uint256 token1Wide = token1Amount / (liquidityRatio + 1);

    uint256 token0Tight = token0Amount.mul(liquidityRatio) / (liquidityRatio + 1);
    uint256 token1Tight = token1Amount.mul(liquidityRatio) / (liquidityRatio + 1);

    if (sqrtRatioX96 < tightUpperSqrtRatioX96 && sqrtRatioX96 > tightLowerSqrtRatioX96) {
      // --|---|-----|---|--
      //   |      ^      |

      uint128 tightLiquidity0 = LiquidityAmounts.getLiquidityForAmount0(
        sqrtRatioX96,
        tightUpperSqrtRatioX96,
        token0Tight
      );
      uint128 tightLiquidity1 = LiquidityAmounts.getLiquidityForAmount1(
        tightLowerSqrtRatioX96,
        sqrtRatioX96,
        token1Tight
      );

      uint128 wideLiquidity0 = LiquidityAmounts.getLiquidityForAmount0(
        sqrtRatioX96,
        wideUpperSqrtRatioX96,
        token0Wide
      );
      uint128 wideLiquidity1 = LiquidityAmounts.getLiquidityForAmount1(
        wideLowerSqrtRatioX96,
        sqrtRatioX96,
        token1Wide
      );

      if (tightLiquidity0 < tightLiquidity1 && wideLiquidity0 < wideLiquidity1) {
        return (tightLiquidity0, wideLiquidity0);
      } else /*if (tightLiquidity0 >= tightLiquidity1 && wideLiquidity0 >= wideLiquidity1)*/ {
        return (tightLiquidity1, wideLiquidity1);
      }
    }

    else if (sqrtRatioX96 > tightUpperSqrtRatioX96) {
      uint128 _tightLiquidity = LiquidityAmounts.getLiquidityForAmount1(
        tightLowerSqrtRatioX96,
        tightUpperSqrtRatioX96,
        token1Tight
      );
      uint128 _wideLiquidity;

      if (sqrtRatioX96 < wideUpperSqrtRatioX96) {
        // --|---|-----|---|--
        //   |           ^ |

        uint128 wideLiquidity0 = LiquidityAmounts.getLiquidityForAmount0(
          sqrtRatioX96,
          wideUpperSqrtRatioX96,
          token0Wide
        );
        uint128 wideLiquidity1 = LiquidityAmounts.getLiquidityForAmount1(
          wideLowerSqrtRatioX96,
          sqrtRatioX96,
          token1Wide
        );

        _wideLiquidity = wideLiquidity0 < wideLiquidity1 ? wideLiquidity0 : wideLiquidity1;
      } else {
        // --|---|-----|---|--
        //   |             | ^

        _wideLiquidity = LiquidityAmounts.getLiquidityForAmount1(
          wideLowerSqrtRatioX96,
          wideUpperSqrtRatioX96,
          token1Wide
        );
      }

      return (_tightLiquidity, _wideLiquidity);
    }

    else /*if (sqrtRatioX96 < tightLowerSqrtRatioX96)*/ {
      uint128 _tightLiquidity = LiquidityAmounts.getLiquidityForAmount0(
        tightLowerSqrtRatioX96,
        tightUpperSqrtRatioX96,
        token0Tight
      );
      uint128 _wideLiquidity;

      if (sqrtRatioX96 > wideLowerSqrtRatioX96) {
        // --|---|-----|---|--
        //   | ^           |

        uint128 wideLiquidity0 = LiquidityAmounts.getLiquidityForAmount0(
          sqrtRatioX96,
          wideUpperSqrtRatioX96,
          token0Wide
        );
        uint128 wideLiquidity1 = LiquidityAmounts.getLiquidityForAmount1(
          wideLowerSqrtRatioX96,
          sqrtRatioX96,
          token1Wide
        );

        _wideLiquidity = wideLiquidity0 < wideLiquidity1 ? wideLiquidity0 : wideLiquidity1;
      } else {
        // --|---|-----|---|--
        // ^ |             |

        _wideLiquidity = LiquidityAmounts.getLiquidityForAmount0(
          wideLowerSqrtRatioX96,
          wideUpperSqrtRatioX96,
          token0Wide
        );
      }
      
      return (_tightLiquidity, _wideLiquidity);
    }
  }

  /// @notice Takes a tight & wide liquidity amount, and rounds them down so they match the liquidity ratio
  /// @param tightLiquidity Input amount of tight liquidity
  /// @param wideLiquidity Input amount of wide liquidity
  /// @return Output rounded amount of tight liquidity
  /// @return Output rounded amount of wide liquidity
  function balanceLiquidity(
    uint128 _tightLiquidity,
    uint128 _wideLiquidity
  ) private view returns (uint128, uint128) {
    uint128 roundDownTightLiquidity = _wideLiquidity * liquidityRatio;
    require(roundDownTightLiquidity > _wideLiquidity, 'Overflow');
    uint128 roundDownWideLiquidity = _tightLiquidity / liquidityRatio;

    return roundDownTightLiquidity < _tightLiquidity
      ? (roundDownTightLiquidity, _wideLiquidity)
      : (_tightLiquidity, roundDownWideLiquidity);
  }

  /// @notice Ensure that the current price isn't too far from the 5 minute TWAP price
  function requireMinimalPriceMovement() private view {
    (, int24 currentTick, , , , , ) = pool.slot0();

    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = 5 minutes;
    secondsAgos[1] = 0;
    (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

    int24 averageTick = int24(int256(tickCumulatives[1] - tickCumulatives[0]) / 5 minutes);

    int24 diff = averageTick > currentTick ? averageTick - currentTick : currentTick - averageTick;
    require(uint24(diff) < maxTickMovement, "Slippage");
  }

  ///
  //  Uniswap callbacks
  ///

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
