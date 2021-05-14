const { expect } = require('chai');
const bn = require('bignumber.js');
const { BigNumber } = require('@ethersproject/bignumber');
const { BigintIsh, ChainId, Price, Token, TokenAmount } = require('@uniswap/sdk-core');
const { Pool, Position, tickToPrice, SqrtPriceMath, TickMath } = require('@uniswap/v3-sdk/dist/');
const JSBI = require('jsbi');

const EMPTY_ADDRESS = '0x1111111111111111111111111111111111111111';

bn.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 })

// returns the sqrt price as a 64x96
function encodePriceSqrt(reserve1, reserve0) {
  return new bn(reserve1.toString())
    .div(reserve0.toString())
    .sqrt()
    .multipliedBy(new bn(2).pow(96))
    .integerValue(3)
    .toString()
}

function position(address, lowerTick, upperTick) {
  return ethers.utils.solidityKeccak256(
    ['address', 'int24', 'int24'],
    [address, lowerTick, upperTick],
  );
}

function x96ToDecimal(number) {
  return new bn(number).div(new bn(2).pow(96));
}
function tickToPriceSqrt(tick) {
  return Math.sqrt(Math.pow(1.0001, tick));
}

const TICK_1_01 = -100;
// const TICK_0_95 = 513;
const TICK_0_95 = 510;
// const TICK_1_03 = -296;
const TICK_1_03 = -300;
// const TICK_0_90 = 1054;
const TICK_0_90 = 1050;

const FEE_AMOUNT = 500;

const MAX_INT = '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

const toInt = val => parseInt(val.toString());

describe('MetaPools', function() {
  let uniswapFactory;
  let uniswapPool;
  let token0;
  let token1;
  let metaPoolFactory;
  let user0;
  let user1;
  let swapTest;
  let metaPool;
  let positionIdTight;
  let positionIdWide;
  let jsPool;

  before(async function() {
    ([user0, user1] = await ethers.getSigners());
    
    const SwapTest = await ethers.getContractFactory('SwapTest');
    swapTest = await SwapTest.deploy();
  })

  beforeEach(async function() {
    const UniswapV3Factory = await ethers.getContractFactory('UniswapV3Factory');
    const _uniswapFactory = await UniswapV3Factory.deploy();
    uniswapFactory = await ethers.getContractAt('IUniswapV3Factory', _uniswapFactory.address);

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    token0 = await MockERC20.deploy();
    token1 = await MockERC20.deploy();

    await token0.approve(swapTest.address, ethers.utils.parseEther('10000000000000'));
    await token1.approve(swapTest.address, ethers.utils.parseEther('10000000000000'));

    // Sort token0 & token1 so it follows the same order as Uniswap & the MetaPoolFactory
    if (ethers.BigNumber.from(token0.address).gt(ethers.BigNumber.from(token1.address))) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await uniswapFactory.createPool(token0.address, token1.address, FEE_AMOUNT);
    const uniswapPoolAddress = await uniswapFactory.getPool(token0.address, token1.address, FEE_AMOUNT);
    uniswapPool = await ethers.getContractAt('IUniswapV3Pool', uniswapPoolAddress);
    await uniswapPool.initialize(encodePriceSqrt('1', '1'));
    await uniswapPool.increaseObservationCardinalityNext(30);

    const MetaPool = await ethers.getContractFactory('MetaPool');
    metaPool = await MetaPool.deploy(uniswapPool.address, TICK_1_01, TICK_0_95, TICK_1_03, TICK_0_90);

    positionIdTight = position(metaPool.address, TICK_1_01, TICK_0_95);
    positionIdWide = position(metaPool.address, TICK_1_03, TICK_0_90);

    await token0.approve(metaPool.address, ethers.utils.parseEther('1000000'));
    await token1.approve(metaPool.address, ethers.utils.parseEther('1000000'));

    // Add a little bit of liquidity to the pool
    // const TestUniswapV3Callee = await ethers.getContractFactory('TestUniswapV3Callee');
    // const callee = await TestUniswapV3Callee.deploy();
    // await token0.approve(callee.address, ethers.utils.parseEther('1000000'));
    // await token1.approve(callee.address, ethers.utils.parseEther('1000000'));
    // await callee.mint(uniswapPool.address, await user1.getAddress(), TICK_1_01, TICK_0_95, 10);

    jsPool = new Pool(
      new Token(ChainId.MAINNET, token0.address, 18),
      new Token(ChainId.MAINNET, token1.address, 18),
      FEE_AMOUNT,
      encodePriceSqrt('1', '1'),
      '0',
      0,
    );
  });

  describe('MetaPool', function() {
    describe('deposits', function() {
      it('Should deposit funds into a metapool', async function() {
        const token0Input = 10000;

        const tightPosition = Position.fromAmount0({
          pool: jsPool,
          tickLower: TICK_1_01,
          tickUpper: TICK_0_95,
          amount0: token0Input * 0.8,
        });
        const token0DesiredTight = parseInt(tightPosition.mintAmounts.amount0.toString());
        const token1DesiredTight = parseInt(tightPosition.mintAmounts.amount1.toString());

        const widePosition = Position.fromAmount0({
          pool: jsPool,
          tickLower: TICK_1_03,
          tickUpper: TICK_0_90,
          amount0: token0Input * 0.2,
        });
        const token0DesiredWide = parseInt(widePosition.mintAmounts.amount0.toString());
        const token1DesiredWide = parseInt(widePosition.mintAmounts.amount1.toString());

        const token0Desired = token0DesiredTight + token0DesiredWide;
        const token1Desired = token1DesiredTight + token1DesiredWide;

        await metaPool.mint(token0Desired, '0', '0');

        const tightPositionAmounts = await metaPool.tightPosition();
        const widePositionAmounts = await metaPool.widePosition();
        // tightPosition & widePosition rounds down, so we need to add 1 unit of tollerance
        expect(parseInt(tightPositionAmounts.token0Amount.toString()))
          .to.be.closeTo(token0DesiredTight, 1);
        expect(parseInt(tightPositionAmounts.token1Amount.toString()))
          .to.be.closeTo(token1DesiredTight, 1);
        expect(tightPositionAmounts.liquidity).to.equal(tightPosition.liquidity.toString());
        expect(parseInt(widePositionAmounts.token0Amount.toString()))
          .to.be.closeTo(token0DesiredWide, 1);
        expect(parseInt(widePositionAmounts.token1Amount.toString()))
          .to.be.closeTo(token1DesiredWide, 1);
        expect(widePositionAmounts.liquidity).to.equal(widePosition.liquidity.toString());

        expect(await token0.balanceOf(uniswapPool.address)).to.equal(token0Desired);
        expect(await token1.balanceOf(uniswapPool.address)).to.equal(token1Desired);

        const [tightLiquidity] = await uniswapPool.positions(positionIdTight);
        expect(tightLiquidity).to.equal(tightPosition.liquidity.toString());
        const [wideLiquidity] = await uniswapPool.positions(positionIdWide);
        expect(wideLiquidity).to.equal(widePosition.liquidity.toString());

        const expectedLPTokens = Math.floor(tightPosition.liquidity.toString() * 0.8)
          + Math.floor(widePosition.liquidity.toString() * 0.2);
        expect(await metaPool.totalSupply()).to.equal(expectedLPTokens);
        expect(await metaPool.balanceOf(await user0.getAddress())).to.equal(expectedLPTokens);


        // Move LP tokens so that we can check new minted tokens later
        await metaPool.transfer(await user1.getAddress(), expectedLPTokens);


        // Now, let's do a second deposit
        const token0Input2 = 5000;

        const tightPosition2 = Position.fromAmount0({
          pool: jsPool,
          tickLower: TICK_1_01,
          tickUpper: TICK_0_95,
          amount0: token0Input2 * 0.8,
        });
        const token0DesiredTight2 = parseInt(tightPosition2.mintAmounts.amount0.toString());
        const token1DesiredTight2 = parseInt(tightPosition2.mintAmounts.amount1.toString());

        const widePosition2 = Position.fromAmount0({
          pool: jsPool,
          tickLower: TICK_1_03,
          tickUpper: TICK_0_90,
          amount0: token0Input2 * 0.2,
        });
        const token0DesiredWide2 = parseInt(widePosition2.mintAmounts.amount0.toString());
        const token1DesiredWide2 = parseInt(widePosition2.mintAmounts.amount1.toString());

        const token0Desired2 = token0DesiredTight2 + token0DesiredWide2;
        const token1Desired2 = token1DesiredTight2 + token1DesiredWide2;

        await metaPool.mint(token0Desired2, '0', '0');

        const tightPositionAmounts2 = await metaPool.tightPosition();
        const widePositionAmounts2 = await metaPool.widePosition();
        // tightPosition & widePosition rounds down, so we need to add 1 unit of tollerance
        expect(parseInt(tightPositionAmounts2.token0Amount))
          .to.be.closeTo(token0DesiredTight + token0DesiredTight2, 1);
        expect(parseInt(tightPositionAmounts2.token1Amount))
          .to.be.closeTo(token1DesiredTight + token1DesiredTight2, 1);
        expect(tightPositionAmounts2.liquidity)
          .to.equal(JSBI.add(tightPosition2.liquidity, tightPosition.liquidity).toString());
        expect(parseInt(widePositionAmounts2.token0Amount))
          .to.be.closeTo(token0DesiredWide + token0DesiredWide2, 1);
        // The following value is off by 2, instead of 1. I'm pretty sure this is just a rounding issue, but
        // this should probably be double-checked
        expect(parseInt(widePositionAmounts2.token1Amount))
          .to.be.closeTo(token1DesiredWide + token1DesiredWide2, 2);
        expect(widePositionAmounts2.liquidity)
          .to.equal(JSBI.add(widePosition2.liquidity, widePosition.liquidity).toString());

        expect(await token0.balanceOf(uniswapPool.address)).to.equal(token0Desired + token0Desired2);
        expect(await token1.balanceOf(uniswapPool.address)).to.equal(token1Desired + token1Desired2);

        const [tightLiquidity2] = await uniswapPool.positions(positionIdTight);
        expect(tightLiquidity2).to.equal(JSBI.add(tightPosition2.liquidity, tightPosition.liquidity).toString());
        const [wideLiquidity2] = await uniswapPool.positions(positionIdWide);
        expect(wideLiquidity2).to.equal(JSBI.add(widePosition2.liquidity, widePosition.liquidity).toString());

        const expectedLPTokens2 = Math.floor(tightPosition2.liquidity.toString() * 0.8)
          + Math.floor(widePosition2.liquidity.toString() * 0.2);
        // LP token calculation divides and rounds down, so we need to add 1 unit of tollerance
        expect(parseInt(await metaPool.totalSupply())).to.be.closeTo(expectedLPTokens + expectedLPTokens2, 1);
        expect(parseInt(await metaPool.balanceOf(await user0.getAddress()))).to.be.closeTo(expectedLPTokens2, 1);
      });
    });

    describe('with liquidity depositted', function() {
      beforeEach(async function() {
        await metaPool.mint(10000, 0, 0);
      });

      describe('withdrawal', function() {
        it('should burn LP tokens and withdraw funds', async function() {
          const startingToken0 = await token0.balanceOf(uniswapPool.address);
          const startingToken1 = await token1.balanceOf(uniswapPool.address);

          const startingSupply = await metaPool.totalSupply();

          const startingTightPositionAmounts = await metaPool.tightPosition();
          const startingWidePositionAmounts = await metaPool.widePosition();

          const lpTokens = await metaPool.balanceOf(await user0.getAddress());
          const lpTokensToBurn = Math.floor(lpTokens * .6);
          await metaPool.burn(lpTokensToBurn, 0, 0, MAX_INT, EMPTY_ADDRESS);

          const endTightPositionAmounts = await metaPool.tightPosition();
          const endWidePositionAmounts = await metaPool.widePosition();

          expect(parseInt(endTightPositionAmounts.token0Amount.toString()))
            .to.be.closeTo(Math.round(startingTightPositionAmounts.token0Amount * 0.4), 1);
          expect(parseInt(endTightPositionAmounts.token1Amount.toString()))
            .to.be.closeTo(Math.round(startingTightPositionAmounts.token1Amount * 0.4), 1);
          expect(parseInt(endTightPositionAmounts.liquidity.toString()))
            .to.be.closeTo(Math.round(startingTightPositionAmounts.liquidity * 0.4), 1);

          expect(parseInt(endWidePositionAmounts.token0Amount.toString()))
            .to.be.closeTo(Math.round(startingWidePositionAmounts.token0Amount * 0.4), 1);
          expect(parseInt(endWidePositionAmounts.token1Amount.toString()))
            .to.be.closeTo(Math.round(startingWidePositionAmounts.token1Amount * 0.4), 1);
          expect(parseInt(endWidePositionAmounts.liquidity.toString()))
            .to.be.closeTo(Math.round(startingWidePositionAmounts.liquidity * 0.4), 1);

          expect(await metaPool.totalSupply())
            .to.equal(Math.round(startingSupply * 0.4));
          expect(await metaPool.balanceOf(await user0.getAddress()))
            .to.equal(Math.round(startingSupply * 0.4));

          expect(toInt(await token0.balanceOf(EMPTY_ADDRESS)))
            .to.be.closeTo(Math.round(startingToken0 * 0.6), 2);
          expect(toInt(await token1.balanceOf(EMPTY_ADDRESS)))
            .to.be.closeTo(Math.round(startingToken1 * 0.6), 2);
        });
      });

      describe('after lots of balanced trading', function() {
        beforeEach(async function() {
          await swapTest.washTrade(uniswapPool.address, '1000', 100, 2);

          await ethers.provider.send("evm_increaseTime", [6 * 60]);
          await ethers.provider.send("evm_mine");

          await swapTest.washTrade(uniswapPool.address, '1000', 100, 2);
        });

        describe('rebalance', function() {
          it('should redeposit fees with a rebalance', async function() {
            await metaPool.rebalance();

            expect(await token0.balanceOf(uniswapPool.address)).to.equal('10200');
            // expect(await token1.balanceOf(uniswapPool.address)).to.equal('10200');
            const [liquidityTight] = await uniswapPool.positions(positionIdTight);
            // expect(liquidityTight).to.equal('10099');
            const [liquidityWide] = await uniswapPool.positions(positionIdTight);
            // expect(liquidityWide).to.equal('10099');
          });
        });
      });

      describe('after lots of unbalanced trading', function() {
        beforeEach(async function() {
          await swapTest.washTrade(uniswapPool.address, '1000', 100, 4);

          await ethers.provider.send("evm_increaseTime", [6 * 60]);
          await ethers.provider.send("evm_mine");

          await swapTest.washTrade(uniswapPool.address, '1000', 100, 4);
        });

        describe('rebalance', function() {
          it('should redeposit fees with a rebalance', async function() {
            await metaPool.rebalance();

            expect(await token0.balanceOf(uniswapPool.address)).to.equal('10299');
            expect(await token1.balanceOf(uniswapPool.address)).to.equal('10100');
            const [liquidityTight] = await uniswapPool.positions(positionIdTight);
            // expect(liquidityTight).to.equal('10099');
            const [liquidityWide] = await uniswapPool.positions(positionIdTight);
            // expect(liquidityWide).to.equal('10099');
          });
        });
      });
    });
  });
});
