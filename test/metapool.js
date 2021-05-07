const { expect } = require('chai');
const bn = require('bignumber.js');
const { BigintIsh, ChainId, Price, Token, TokenAmount } = require('@uniswap/sdk-core');
const {
  Pool,
  FeeAmount,
  Position,
  priceToClosestTick,
  TickMath,
  tickToPrice,
  TICK_SPACINGS,
} = require('@uniswap/v3-sdk/dist/');


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

describe('MetaPools', function() {
  let uniswapFactory;
  let uniswapPool;
  let token0;
  let token1;
  let metaPoolFactory;
  const nonExistantToken = '0x1111111111111111111111111111111111111111';
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
    beforeEach(async function() {
      await token0.approve(metaPool.address, ethers.utils.parseEther('1000000'));
      await token1.approve(metaPool.address, ethers.utils.parseEther('1000000'));
    });

    describe('deposits', function() {
      it('Should deposit funds into a metapool', async function() {
        const token0Desired = 1000;

        const tightPosition = Position.fromAmount0({
          pool: jsPool,
          tickLower: TICK_1_01,
          tickUpper: TICK_0_95,
          amount0: token0Desired * 0.8,
        });
        const token1DesiredTight = parseInt(tightPosition.amount1.raw.toString());

        const widePosition = Position.fromAmount0({
          pool: jsPool,
          tickLower: TICK_1_03,
          tickUpper: TICK_0_90,
          amount0: token0Desired * 0.2,
        });
        const token1DesiredWide = parseInt(widePosition.amount1.raw.toString());

        const token1Desired = token1DesiredTight + token1DesiredWide;

        await metaPool.mint(token0Desired, token1Desired, '0', '0');

        // expect(await token0.balanceOf(uniswapPool.address)).to.equal(token0Desired);
        // expect(await token1.balanceOf(uniswapPool.address)).to.equal(token1Desired);
        const [tightLiquidity] = await uniswapPool.positions(positionIdTight);
        expect(tightLiquidity).to.equal('31775');
        const [wideLiquidity] = await uniswapPool.positions(positionIdWide);
        // expect(wideLiquidity).to.equal('3910');
        expect(await metaPool.totalSupply()).to.equal('17331');
        expect(await metaPool.balanceOf(await user0.getAddress())).to.equal('17331');

        await metaPool.mint('500', '500', '0', '0');

        // expect(await token0.balanceOf(uniswapPool.address)).to.equal('1500');
        // expect(await token1.balanceOf(uniswapPool.address)).to.equal('328');
        const [tightLiquidity2] = await uniswapPool.positions(positionIdTight);
        expect(tightLiquidity2).to.equal('47662');
        const [wideLiquidity2] = await uniswapPool.positions(positionIdWide);
        // expect(wideLiquidity2).to.equal('5865');
        expect(await metaPool.totalSupply()).to.equal('27529');
        expect(await metaPool.balanceOf(await user0.getAddress())).to.equal('27529');
      });
    });

    describe('with liquidity depositted', function() {
      beforeEach(async function() {
        await metaPool.mint(10000, 10000, 0, 0);
      });

      describe('withdrawal', function() {
        it('should burn LP tokens and withdraw funds', async function() {
          const startingToken0 = await token0.balanceOf(uniswapPool.address);
          const startingToken1 = await token1.balanceOf(uniswapPool.address);

          const lpTokens = await metaPool.balanceOf(await user0.getAddress());
          const lpTokensToBurn = Math.floor(lpTokens * 0.4);
          await metaPool.burn(lpTokensToBurn, 0, 0, MAX_INT);

          expect(await token0.balanceOf(uniswapPool.address)).to.equal(startingToken0 * 0.6);
          expect(await token1.balanceOf(uniswapPool.address)).to.equal(startingToken1 * 0.6);
          // const [liquidity2] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
          // expect(liquidity2).to.equal('4000');
          expect(await metaPool.totalSupply()).to.equal('4000');
          expect(await metaPool.balanceOf(await user0.getAddress())).to.equal('4000');
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
