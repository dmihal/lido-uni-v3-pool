const { expect } = require('chai');
const bn = require('bignumber.js');
const { BigNumber } = require('@ethersproject/bignumber');
const { BigintIsh, ChainId, Price, Token, TokenAmount } = require('@uniswap/sdk-core');
const { Pool, Position, tickToPrice, SqrtPriceMath, TickMath } = require('@uniswap/v3-sdk/dist/');
const JSBI = require('jsbi');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
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
const maxTickMovement = 100;
const INITIAL_LIQ = 20;

const MAX_INT = '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

const toInt = val => parseInt(val.toString());

async function logRebalance(call) {
  const tx = await call;
  const { events } = await tx.wait();

  const { interface } = await ethers.getContractFactory('UniswapV3Pool');

  for (const event of events) {
    switch (event.topics[0]) {
      case interface.getEventTopic('Collect'):
        const collectLog = interface.decodeEventLog('Collect', event.data, event.topics);
        console.log(`Collect [${collectLog.tickLower}:${collectLog.tickUpper}] Collected ${collectLog.amount0} token0 & ${collectLog.amount1} token1`);
        break;

      case interface.getEventTopic('Mint'):
        const mintLog = interface.decodeEventLog('Mint', event.data, event.topics);
        console.log(`Mint [${mintLog.tickLower}:${mintLog.tickUpper}] Added ${mintLog.amount0} token0 & ${mintLog.amount1} token1 for ${mintLog.amount} Liquidity`);
        break;

      case interface.getEventTopic('Swap'):
        const swapLog = interface.decodeEventLog('Swap', event.data, event.topics);
        if (parseInt(swapLog.amount0.toString()) < 0) {
          console.log(`Swap ${swapLog.amount0 * -1} token0 for ${swapLog.amount1} token1`);
        } else {
          console.log(`Swap ${swapLog.amount1 * -1} token1 for ${swapLog.amount0} token0`);
        }
        break;
    }
  }
}

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
    metaPool = await MetaPool.deploy(uniswapPool.address, TICK_1_01, TICK_0_95, TICK_1_03, TICK_0_90, maxTickMovement);

    positionIdTight = position(metaPool.address, TICK_1_01, TICK_0_95);
    positionIdWide = position(metaPool.address, TICK_1_03, TICK_0_90);

    await token0.approve(metaPool.address, ethers.utils.parseEther('1000000'));
    await token1.approve(metaPool.address, ethers.utils.parseEther('1000000'));

    // Add a little bit of liquidity to the pool
    const TestUniswapV3Callee = await ethers.getContractFactory('TestUniswapV3Callee');
    const callee = await TestUniswapV3Callee.deploy();
    await token0.approve(callee.address, ethers.utils.parseEther('1000000'));
    await token1.approve(callee.address, ethers.utils.parseEther('1000000'));
    await callee.mint(uniswapPool.address, await user1.getAddress(), -887220, 887220, INITIAL_LIQ);

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
    describe('initialize', function() {
      it('should initialize the pool', async function() {
        const tightPosition = new Position({
          pool: jsPool,
          liquidity: 800,
          tickLower: TICK_1_01,
          tickUpper: TICK_0_95,
        });
        const token0DesiredTight = parseInt(tightPosition.amount0.numerator.toString());
        const token1DesiredTight = parseInt(tightPosition.amount1.numerator.toString());

        const widePosition = new Position({
          pool: jsPool,
          liquidity: 100,
          tickLower: TICK_1_03,
          tickUpper: TICK_0_90,
        });
        const token0DesiredWide = parseInt(widePosition.amount0.numerator.toString());
        const token1DesiredWide = parseInt(widePosition.amount1.numerator.toString());

        await metaPool.initialize();
        
        expect(await metaPool.totalSupply()).to.equal('100');
        expect(await metaPool.balanceOf(ZERO_ADDRESS)).to.equal('100');

        const tightPositionAmounts = await metaPool.tightPosition();
        const widePositionAmounts = await metaPool.widePosition();
        // tightPosition & widePosition rounds down, so we need to add 1 unit of tollerance
        expect(toInt(tightPositionAmounts.token0Amount))
          .to.equal(token0DesiredTight);
        expect(toInt(tightPositionAmounts.token1Amount))
          .to.equal(token1DesiredTight);
        expect(tightPositionAmounts.liquidity).to.equal(tightPosition.liquidity.toString());
        expect(toInt(widePositionAmounts.token0Amount))
          .to.equal(token0DesiredWide);
        expect(toInt(widePositionAmounts.token1Amount))
          .to.equal(token1DesiredWide);
        expect(widePositionAmounts.liquidity).to.equal(widePosition.liquidity.toString());
      });

      it('should not initialize the pool twice', async function() {
        await metaPool.initialize();

        await expect(metaPool.initialize()).to.be.reverted;
      });

      it('should not mint before initialization', async function() {
        await expect(metaPool.mint(1000, 100000, 100000)).to.be.revertedWith('INI');
      });
    });

    describe('initialized', function() {
      let initialTightPosition;
      let initialWidePosition;
      let initialPosition;

      beforeEach(async function() {
        await metaPool.initialize();

        initialTightPosition = await metaPool.tightPosition();
        initialWidePosition = await metaPool.widePosition();
        initialPosition = await metaPool.totalPosition();
      });

      describe('deposits', function() {
        it('should deposit funds into a metapool', async function() {
          const mintAmount = 1000;

          const startingToken0 = await token0.balanceOf(uniswapPool.address);
          const startingToken1 = await token1.balanceOf(uniswapPool.address);

          const tightPosition = new Position({
            pool: jsPool,
            tickLower: TICK_1_01,
            tickUpper: TICK_0_95,
            liquidity: mintAmount * 8,
          });
          const token0DesiredTight = parseInt(tightPosition.mintAmounts.amount0.toString());
          const token1DesiredTight = parseInt(tightPosition.mintAmounts.amount1.toString());

          const widePosition = new Position({
            pool: jsPool,
            tickLower: TICK_1_03,
            tickUpper: TICK_0_90,
            liquidity: mintAmount,
          });
          const token0DesiredWide = parseInt(widePosition.mintAmounts.amount0.toString());
          const token1DesiredWide = parseInt(widePosition.mintAmounts.amount1.toString());

          const token0Desired = token0DesiredTight + token0DesiredWide;
          const token1Desired = token1DesiredTight + token1DesiredWide;

          await metaPool.mint(mintAmount, 1000000, 1000000);

          const tightPositionAmounts = await metaPool.tightPosition();
          const widePositionAmounts = await metaPool.widePosition();
          // tightPosition & widePosition rounds down, so we need to add 1 unit of tollerance
          expect(toInt(tightPositionAmounts.token0Amount))
            .to.be.closeTo(token0DesiredTight + toInt(initialTightPosition.token0Amount), 1);
          expect(toInt(tightPositionAmounts.token1Amount))
            .to.be.closeTo(token1DesiredTight + toInt(initialTightPosition.token1Amount), 1);
          expect(tightPositionAmounts.liquidity)
            .to.equal(toInt(tightPosition.liquidity) + toInt(initialTightPosition.liquidity));
          expect(toInt(widePositionAmounts.token0Amount))
            .to.be.closeTo(token0DesiredWide + toInt(initialWidePosition.token0Amount), 1);
          expect(toInt(widePositionAmounts.token1Amount))
            .to.be.closeTo(token1DesiredWide + toInt(initialWidePosition.token1Amount), 1);
          expect(widePositionAmounts.liquidity)
            .to.equal(toInt(widePosition.liquidity) + toInt(initialWidePosition.liquidity));

          expect(await token0.balanceOf(uniswapPool.address))
            .to.equal(token0Desired + toInt(startingToken0));
          expect(await token1.balanceOf(uniswapPool.address))
            .to.equal(token1Desired + toInt(startingToken1));
          expect(await metaPool.totalSupply()).to.equal(mintAmount + 100);
          expect(await metaPool.balanceOf(await user0.getAddress())).to.equal(mintAmount);

          // Move LP tokens so that we can check new minted tokens later
          await metaPool.transfer(await user1.getAddress(), mintAmount);



          const mintAmount2 = 500;

          const tightPosition2 = new Position({
            pool: jsPool,
            tickLower: TICK_1_01,
            tickUpper: TICK_0_95,
            liquidity: mintAmount2 * 8,
          });
          const token0DesiredTight2 = parseInt(tightPosition2.mintAmounts.amount0.toString());
          const token1DesiredTight2 = parseInt(tightPosition2.mintAmounts.amount1.toString());

          const widePosition2 = new Position({
            pool: jsPool,
            tickLower: TICK_1_03,
            tickUpper: TICK_0_90,
            liquidity: mintAmount2,
          });
          const token0DesiredWide2 = parseInt(widePosition2.mintAmounts.amount0.toString());
          const token1DesiredWide2 = parseInt(widePosition2.mintAmounts.amount1.toString());

          const token0Desired2 = token0DesiredTight2 + token0DesiredWide2;
          const token1Desired2 = token1DesiredTight2 + token1DesiredWide2;

          await metaPool.mint(mintAmount2, 1000000, 1000000);

          const tightPositionAmounts2 = await metaPool.tightPosition();
          const widePositionAmounts2 = await metaPool.widePosition();
          // tightPosition & widePosition rounds down, so we need to add 1 unit of tollerance
          expect(toInt(tightPositionAmounts2.token0Amount))
            .to.be.closeTo(token0DesiredTight2 + token0DesiredTight + toInt(initialTightPosition.token0Amount), 2);
          expect(toInt(tightPositionAmounts2.token1Amount))
            .to.be.closeTo(token1DesiredTight2 + token1DesiredTight + toInt(initialTightPosition.token1Amount), 2);
          expect(tightPositionAmounts2.liquidity)
            .to.equal(toInt(tightPosition2.liquidity) + toInt(tightPosition.liquidity) + toInt(initialTightPosition.liquidity));
          expect(toInt(widePositionAmounts2.token0Amount))
            .to.be.closeTo(token0DesiredWide2 + token0DesiredWide + toInt(initialWidePosition.token0Amount), 2);
          expect(toInt(widePositionAmounts2.token1Amount))
            .to.be.closeTo(token1DesiredWide2 + token1DesiredWide + toInt(initialWidePosition.token1Amount), 2);
          expect(widePositionAmounts2.liquidity)
            .to.equal(toInt(widePosition2.liquidity) + toInt(widePosition.liquidity) + toInt(initialWidePosition.liquidity));

          expect(await token0.balanceOf(uniswapPool.address))
            .to.equal(token0Desired2 + token0Desired + toInt(startingToken0));
          expect(await token1.balanceOf(uniswapPool.address))
            .to.equal(token1Desired2 + token1Desired + toInt(startingToken1));
          expect(await metaPool.totalSupply()).to.equal(mintAmount2 + mintAmount + 100);
          expect(await metaPool.balanceOf(await user0.getAddress())).to.equal(mintAmount2);
        });
      });

    describe('with the price outside of the pool ranges', function() {
      beforeEach(async function() {
        // This should move the tick to -1907
        await swapTest.swap(uniswapPool.address, true, 2);

        initialTightPosition = await metaPool.tightPosition();
        initialWidePosition = await metaPool.widePosition();
      });

      it('should allow deposits', async function() {
        const { sqrtPriceX96, tick } = await uniswapPool.slot0();
        jsPool = new Pool(
          new Token(ChainId.MAINNET, token0.address, 18),
          new Token(ChainId.MAINNET, token1.address, 18),
          FEE_AMOUNT,
          sqrtPriceX96.toString(),
          '0',
          tick,
        );

        const mintAmount = 1000;

        const startingToken0 = await token0.balanceOf(uniswapPool.address);
        const startingToken1 = await token1.balanceOf(uniswapPool.address);

        const tightPosition = new Position({
          pool: jsPool,
          tickLower: TICK_1_01,
          tickUpper: TICK_0_95,
          liquidity: mintAmount * 8,
        });
        const token0DesiredTight = parseInt(tightPosition.mintAmounts.amount0.toString());
        const token1DesiredTight = parseInt(tightPosition.mintAmounts.amount1.toString());

        const widePosition = new Position({
          pool: jsPool,
          tickLower: TICK_1_03,
          tickUpper: TICK_0_90,
          liquidity: mintAmount,
        });
        const token0DesiredWide = parseInt(widePosition.mintAmounts.amount0.toString());
        const token1DesiredWide = parseInt(widePosition.mintAmounts.amount1.toString());

        const token0Desired = token0DesiredTight + token0DesiredWide;
        const token1Desired = token1DesiredTight + token1DesiredWide;

        await metaPool.mint(mintAmount, 1000000, 1000000);

        const tightPositionAmounts = await metaPool.tightPosition();
        const widePositionAmounts = await metaPool.widePosition();
        // tightPosition & widePosition rounds down, so we need to add 1 unit of tollerance
        expect(toInt(tightPositionAmounts.token0Amount))
          .to.be.closeTo(token0DesiredTight + toInt(initialTightPosition.token0Amount), 1);
        expect(toInt(tightPositionAmounts.token1Amount))
          .to.be.closeTo(token1DesiredTight + toInt(initialTightPosition.token1Amount), 1);
        expect(tightPositionAmounts.liquidity)
          .to.equal(toInt(tightPosition.liquidity) + toInt(initialTightPosition.liquidity));
        expect(toInt(widePositionAmounts.token0Amount))
          .to.be.closeTo(token0DesiredWide + toInt(initialWidePosition.token0Amount), 1);
        expect(toInt(widePositionAmounts.token1Amount))
          .to.be.closeTo(token1DesiredWide + toInt(initialWidePosition.token1Amount), 1);
        expect(widePositionAmounts.liquidity)
          .to.equal(toInt(widePosition.liquidity) + toInt(initialWidePosition.liquidity));

        expect(await token0.balanceOf(uniswapPool.address))
          .to.equal(token0Desired + toInt(startingToken0));
        expect(await token1.balanceOf(uniswapPool.address))
          .to.equal(token1Desired + toInt(startingToken1));
        expect(await metaPool.totalSupply()).to.equal(mintAmount + 100);
        expect(await metaPool.balanceOf(await user0.getAddress())).to.equal(mintAmount);
      });
    });

    describe('with liquidity depositted', function() {
      beforeEach(async function() {
        await metaPool.mint(10000, 1000000, 1000000);
        await ethers.provider.send("evm_increaseTime", [6 * 60]);
        await ethers.provider.send("evm_mine");
      });

      describe('withdrawal', function() {
        it('should burn LP tokens and withdraw funds', async function() {
          const startingToken0 = toInt(await token0.balanceOf(uniswapPool.address)) - INITIAL_LIQ;
          const startingToken1 = toInt(await token1.balanceOf(uniswapPool.address)) - INITIAL_LIQ;

          const startingSupply = await metaPool.totalSupply();

          const startingTightPositionAmounts = await metaPool.tightPosition();
          const startingWidePositionAmounts = await metaPool.widePosition();

          const lpTokens = await metaPool.balanceOf(await user0.getAddress());
          const lpTokensToBurn = Math.floor(lpTokens * .6);
          await metaPool.burn(lpTokensToBurn, 0, 0, MAX_INT, EMPTY_ADDRESS);

          const endTightPositionAmounts = await metaPool.tightPosition();
          const endWidePositionAmounts = await metaPool.widePosition();

          expect(parseInt(endTightPositionAmounts.liquidity.toString()))
            .to.be.closeTo(Math.round((startingTightPositionAmounts.liquidity - initialTightPosition.liquidity) * 0.4) + toInt(initialTightPosition.liquidity), 1);

          expect(parseInt(endWidePositionAmounts.liquidity.toString()))
            .to.be.closeTo(Math.round((startingWidePositionAmounts.liquidity - initialWidePosition.liquidity) * 0.4) + toInt(initialWidePosition.liquidity), 1);

          expect(await metaPool.totalSupply())
            .to.equal(Math.round((startingSupply - 100) * 0.4) + 100);
          expect(await metaPool.balanceOf(await user0.getAddress()))
            .to.equal(Math.round((startingSupply - 100) * 0.4));

          // Tollerance of 4 since each token of each position will round down
          expect(toInt(await token0.balanceOf(EMPTY_ADDRESS)))
            .to.be.closeTo(Math.round((startingToken0 - toInt(initialPosition.token0Amount)) * 0.6), 4);
          expect(toInt(await token1.balanceOf(EMPTY_ADDRESS)))
            .to.be.closeTo(Math.round((startingToken1 - toInt(initialPosition.token1Amount)) * 0.6), 4);
        });
      });

      describe('after a significant price movement', function() {
        beforeEach(async function() {
          await swapTest.swap(uniswapPool.address, false, 5000);
        });

        it('should fail to rebalance', async function() {
          // await swapTest.swap(uniswapPool.address, false, 1000);

          // await ethers.provider.send("evm_increaseTime", [1 * 60]);
          // await ethers.provider.send("evm_mine");
          // const oracle = await uniswapPool.observe([5 * 60, 0]);
          // console.log(oracle.tickCumulatives);

          const { tick, sqrtPriceX96 } = await uniswapPool.slot0();
          console.log({ tick, sqrtPriceX96 });
          await expect(metaPool.rebalance()).to.be.revertedWith('Slippage');
        })
      });

      describe('after lots of balanced trading', function() {
        beforeEach(async function() {
          await swapTest.washTrade(uniswapPool.address, '1000', 50, 2);

          await ethers.provider.send("evm_increaseTime", [6 * 60]);
          await ethers.provider.send("evm_mine");

          // await swapTest.washTrade(uniswapPool.address, '1000', 101, 2);

          const { tick, sqrtPriceX96 } = await uniswapPool.slot0();
          console.log('balanced', { tick, sqrtPriceX96 });
        });

          describe('withdrawal', function() {
            it('should burn LP tokens and withdraw funds', async function() {
            const startingToken0 = toInt(await token0.balanceOf(uniswapPool.address)) - INITIAL_LIQ;
            const startingToken1 = toInt(await token1.balanceOf(uniswapPool.address)) - INITIAL_LIQ;

            const startingSupply = await metaPool.totalSupply();

            const startingTightPositionAmounts = await metaPool.tightPosition();
            const startingWidePositionAmounts = await metaPool.widePosition();

            const lpTokens = await metaPool.balanceOf(await user0.getAddress());
            const lpTokensToBurn = Math.floor(lpTokens * .6);
            await metaPool.burn(lpTokensToBurn, 0, 0, MAX_INT, EMPTY_ADDRESS);

            const endTightPositionAmounts = await metaPool.tightPosition();
            const endWidePositionAmounts = await metaPool.widePosition();

            expect(parseInt(endTightPositionAmounts.liquidity.toString()))
              .to.be.closeTo(Math.round((startingTightPositionAmounts.liquidity - initialTightPosition.liquidity) * 0.4) + toInt(initialTightPosition.liquidity), 1);

            expect(parseInt(endWidePositionAmounts.liquidity.toString()))
              .to.be.closeTo(Math.round((startingWidePositionAmounts.liquidity - initialWidePosition.liquidity) * 0.4) + toInt(initialWidePosition.liquidity), 1);

            expect(await metaPool.totalSupply())
              .to.equal(Math.round((startingSupply - 100) * 0.4) + 100);
            expect(await metaPool.balanceOf(await user0.getAddress()))
              .to.equal(Math.round((startingSupply - 100) * 0.4));

            // Tollerance of 4 since each token of each position will round down
            // TODO: calculate these
            // expect(toInt(await token0.balanceOf(EMPTY_ADDRESS)))
            //   .to.be.closeTo(Math.round((startingToken0 - toInt(initialPosition.token0Amount)) * 0.6), 4);
            // expect(toInt(await token1.balanceOf(EMPTY_ADDRESS)))
            //   .to.be.closeTo(Math.round((startingToken1 - toInt(initialPosition.token1Amount)) * 0.6), 4);
            });
          });

        describe('rebalance', function() {
          it('should redeposit fees with a rebalance', async function() {
            const startingPositionAmounts = await metaPool.totalPosition();
            const startingTightPositionAmounts = await metaPool.tightPosition();
            const startingWidePositionAmounts = await metaPool.widePosition();

            await logRebalance(metaPool.rebalance());

            // expect(toInt(await token0.balanceOf(uniswapPool.address)))
            //   .to.be.closeTo(Math.round(startingPositionAmounts.token0Amount * 1.02), 1);
            // expect(toInt(await token1.balanceOf(uniswapPool.address)))
            //   .to.be.closeTo(Math.round(startingPositionAmounts.token1Amount * 1.02), 1);

            //TODO: this should be 0 once the test does true balanced trading
            expect(toInt(await token0.balanceOf(metaPool.address))).to.be.closeTo(0, 1);
            // expect(toInt(await token1.balanceOf(metaPool.address))).to.equal(0);

            const endTightPositionAmounts = await metaPool.tightPosition();
            const endWidePositionAmounts = await metaPool.widePosition();

            // TODO: find mathamatical source of these liquidity values
            expect(toInt(endTightPositionAmounts.liquidity))
              .to.be.greaterThan(toInt(startingTightPositionAmounts.liquidity));
            expect(toInt(endWidePositionAmounts.liquidity))
              .to.be.greaterThan(toInt(startingWidePositionAmounts.liquidity));
          });
        });
      });

      describe('after lots of unbalanced trading', function() {
        beforeEach(async function() {
          // await swapTest.washTrade(uniswapPool.address, '1000', 100, 3);
          await swapTest.washTrade(uniswapPool.address, '25', 50, 3);

          await ethers.provider.send("evm_increaseTime", [6 * 60]);
          await ethers.provider.send("evm_mine");

          // await swapTest.washTrade(uniswapPool.address, '1000', 100, 3);

          const { tick, sqrtPriceX96 } = await uniswapPool.slot0();
          console.log('unbalanced', { tick, sqrtPriceX96 });
        });

        describe('withdrawal', function() {
          it('should burn LP tokens and withdraw funds', async function() {
            const startingToken0 = toInt(await token0.balanceOf(uniswapPool.address)) - INITIAL_LIQ;
            const startingToken1 = toInt(await token1.balanceOf(uniswapPool.address)) - INITIAL_LIQ;

            const startingSupply = await metaPool.totalSupply();

            const startingTightPositionAmounts = await metaPool.tightPosition();
            const startingWidePositionAmounts = await metaPool.widePosition();

            const lpTokens = await metaPool.balanceOf(await user0.getAddress());
            const lpTokensToBurn = Math.floor(lpTokens * .6);
            await metaPool.burn(lpTokensToBurn, 0, 0, MAX_INT, EMPTY_ADDRESS);

            const endTightPositionAmounts = await metaPool.tightPosition();
            const endWidePositionAmounts = await metaPool.widePosition();

            expect(parseInt(endTightPositionAmounts.liquidity.toString()))
              .to.be.closeTo(Math.round((startingTightPositionAmounts.liquidity - initialTightPosition.liquidity) * 0.4) + toInt(initialTightPosition.liquidity), 1);

            expect(parseInt(endWidePositionAmounts.liquidity.toString()))
              .to.be.closeTo(Math.round((startingWidePositionAmounts.liquidity - initialWidePosition.liquidity) * 0.4) + toInt(initialWidePosition.liquidity), 1);

            expect(await metaPool.totalSupply())
              .to.equal(Math.round((startingSupply - 100) * 0.4) + 100);
            expect(await metaPool.balanceOf(await user0.getAddress()))
              .to.equal(Math.round((startingSupply - 100) * 0.4));

            expect(toInt(await token0.balanceOf(EMPTY_ADDRESS)))
              .to.be.greaterThan(0);
            expect(toInt(await token1.balanceOf(EMPTY_ADDRESS)))
              .to.be.greaterThan(0);

            // Tollerance of 4 since each token of each position will round down
            // expect(toInt(await token0.balanceOf(EMPTY_ADDRESS)))
            //   .to.be.closeTo(Math.round((startingToken0 - toInt(initialPosition.token0Amount)) * 0.6), 4);
            // expect(toInt(await token1.balanceOf(EMPTY_ADDRESS)))
            //   .to.be.closeTo(Math.round((startingToken1 - toInt(initialPosition.token1Amount)) * 0.6), 4);
          });
        });

        describe('rebalance', function() {
          it('should redeposit fees with a rebalance', async function() {
            const startingPositionAmounts = await metaPool.totalPosition();
            const startingTightPositionAmounts = await metaPool.tightPosition();
            const startingWidePositionAmounts = await metaPool.widePosition();

            await logRebalance(metaPool.rebalance());

            expect(toInt(await token0.balanceOf(metaPool.address))).to.be.closeTo(0, 1);
            //TODO: this should be 0 once the test does true balanced trading
            expect(toInt(await token1.balanceOf(metaPool.address))).to.be.closeTo(5, 1);

            const endTightPositionAmounts = await metaPool.tightPosition();
            const endWidePositionAmounts = await metaPool.widePosition();

            // TODO: find mathamatical source of these liquidity values
            expect(toInt(endTightPositionAmounts.liquidity))
              .to.be.greaterThan(toInt(startingTightPositionAmounts.liquidity));
            expect(toInt(endWidePositionAmounts.liquidity))
              .to.be.greaterThan(toInt(startingWidePositionAmounts.liquidity));
          });
        });
      });
    });
    });
  });
});
