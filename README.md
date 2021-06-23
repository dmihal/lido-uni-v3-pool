# Lido stETH pool for Uniswap V3

This codebase, derived from the [uniswap-liquidity-dao](https://github.com/dmihal/uniswap-liquidity-dao) code, creates a pool for wstETH & ETH tokens, depositted into Uniswap V3. Liquidity is depositted 80% into the 0.95-1.01 range, and 20% to the 0.90-1.03 range. Liquidity positions are represented as fungible ERC-20 tokens, similar to Uniswap V2 positions.

For more details, view the [project specification & discussion](https://research.lido.fi/t/lego-lido-steth-uniswap-v3-pool/509).

## Privileged roles

This contract has a single "pauser" address, that may pause deposits & rebalances.
Users may still withdraw funds at any time.

Aside from the pauser role, there are no special privileges granted to any address.
