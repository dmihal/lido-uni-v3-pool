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

/// @title MetaPool for allocating to the Lido stETH Uniswap V3 Pool
/// @author David Mihal
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

  uint128 public immutable liquidityRatio;

  uint160 public immutable tightLowerSqrtRatioX96;
  uint160 public immutable tightUpperSqrtRatioX96;
  uint160 public immutable wideLowerSqrtRatioX96;
  uint160 public immutable wideUpperSqrtRatioX96;

  bytes32 public immutable tightPositionID;
  bytes32 public immutable widePositionID;

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
    (liquidity,,,,) = pool.positions(tightPositionID);

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
    bytes32 positionID = keccak256(abi.encodePacked(address(this), wideLowerTick, wideUpperTick));
    (liquidity,,,,) = pool.positions(positionID);

    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    (token0Amount, token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, wideLowerSqrtRatioX96, wideUpperSqrtRatioX96, liquidity);
  }

  /// @notice Return the total amount of tokens held by the pool's positions in Uniswap
  /// @return token0Amount Total amount of token0 held in the pool's positions
  /// @return token1Amount Total amount of token1 held in the pool's positions
  function totalPosition() external view returns (uint256 token0Amount, uint256 token1Amount) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    (uint128 tightLiquidity,,,,) = pool.positions(tightPositionID);
    (uint256 tightToken0, uint256 tightToken1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtRatioX96, tightLowerSqrtRatioX96, tightUpperSqrtRatioX96, tightLiquidity);

    (uint128 wideLiquidity,,,,) = pool.positions(widePositionID);
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
    (uint128 initialTightLiquidity, , , , ) = pool.positions(tightPositionID);
    (uint128 initialWideLiquidity, , , , ) = pool.positions(widePositionID);
    require(initialTightLiquidity > 0 && initialWideLiquidity > 0, "INI");

    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    uint256 _totalSupply = totalSupply; // Single SLOAD for gas saving
    uint256 newTightLiquidity = newLPTokens.mul(initialTightLiquidity) / _totalSupply;
    uint256 newWideLiquidity = newLPTokens.mul(initialWideLiquidity) / _totalSupply;

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
    (uint128 tightLiquidity, , , , ) = pool.positions(tightPositionID);
    (uint128 wideLiquidity, , , , ) = pool.positions(widePositionID);

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
    (uint128 tightLiquidity, , , , ) = pool.positions(tightPositionID);
    (uint128 wideLiquidity, , , , ) = pool.positions(widePositionID);

    // Ensure the pool hasn't been initialized yet
    require(tightLiquidity == 0 && wideLiquidity == 0);

    pool.mint(
      address(this),
      wideLowerTick,
      wideUpperTick,
      100,
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    pool.mint(
      address(this),
      tightLowerTick,
      tightUpperTick,
      100 * liquidityRatio, // Won't overflow, since we assume reasonable liquidityRatio
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

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
    (uint128 initialTightLiquidity, , , , ) = pool.positions(tightPositionID);
    (uint128 initialWideLiquidity, , , , ) = pool.positions(widePositionID);
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

    // Withdraw from tight position
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

    // Withdraw from wide position
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

  function deposit() private {
    requireMinimalPriceMovement();
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

    // Query the actual balances, so we can soop up any un-deposited
    // tokens from the last rebalance
    uint256 amount0 = IERC20Minimal(token0).balanceOf(address(this));
    uint256 amount1 = IERC20Minimal(token1).balanceOf(address(this));

    // Total liquidity values, only used for logging
    uint128 tightLiquidityAdded;
    uint128 wideLiquidityAdded;

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

      // Can't overflow
      amount0 -= (tightToken0 + wideToken0);
      amount1 -= (tightToken1 + wideToken1);

      tightLiquidityAdded += newTightLiquidity;
      wideLiquidityAdded += newWideLiquidity;
    }

    // If we still have some left-over, we need to swap so it's balanced
    // We check if it's bigger than 2, since there's no use in swapping dust
    if (amount0 > 2 || amount1 > 2) {
      {
        bool zeroForOne;
        int256 swapAmount;
        if (amount0 <= 2 || amount1 <= 2) {
          // If we only have a balance of one token, we'll swap half of it into the other token
          zeroForOne = amount0 > amount1;
          swapAmount = int256(zeroForOne ? amount0 : amount1);
        } else {
          // If we have a balance of each token, we'll swap the difference between the two
          uint256 equivelantAmount0 = UniMathHelpers.getQuoteFromSqrt(sqrtRatioX96, uint128(amount1), token1, token0);
          zeroForOne = amount0 > equivelantAmount0;
          swapAmount = zeroForOne
            ? int256(amount0 - equivelantAmount0)
            : int256(amount1 - UniMathHelpers.getQuoteFromSqrt(sqrtRatioX96, uint128(amount0), token0, token1));
        }

        (address fromAddr, address toAddr) = zeroForOne ? (token0, token1) : (token1, token0);
        // Approximate the price ratio by getting a quote for 1e10
        // This approximation lets us avoid doing decimal exponent math
        uint256 price = UniMathHelpers.getQuoteFromSqrt(sqrtRatioX96, 1e10, fromAddr, toAddr);
        // Multiply the starting swap amount by the price ratio
        // If the pool is balanced, this will end up being equivelant to `swapAmount / 2`
        swapAmount = swapAmount * 1e10 / int256(1e10 + price);

        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
          address(this),
          zeroForOne,
          swapAmount,
          zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
          abi.encode(address(this))
        );

        amount0 = uint256(int256(amount0) - amount0Delta);
        amount1 = uint256(int256(amount1) - amount1Delta);
      }

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

        if (newTightLiquidity > 0) {
          (uint256 tightToken0, uint256 tightToken1) = pool.mint(
            address(this),
            tightLowerTick,
            tightUpperTick,
            newTightLiquidity,
            abi.encode(address(this)) // Data field for uniswapV3MintCallback
          );
          amount0 -= tightToken0;
          amount1 -= tightToken1;
          tightLiquidityAdded += newTightLiquidity;
        }

        if (newWideLiquidity > 0) {
          (uint256 wideToken0, uint256 wideToken1) = pool.mint(
            address(this),
            wideLowerTick,
            wideUpperTick,
            newWideLiquidity,
            abi.encode(address(this)) // Data field for uniswapV3MintCallback
          );
          amount0 -= wideToken0;
          amount1 -= wideToken1;
          wideLiquidityAdded += newWideLiquidity;
        }
      }
    }

    emit Rebalanced(tightLiquidityAdded, wideLiquidityAdded, amount0, amount1);
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
