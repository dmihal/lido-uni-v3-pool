//SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

interface IMetaPoolFactory {
  event PoolCreated(address indexed token0, address indexed token1, address pool);
  
  function createPool(address tokenA, address tokenB) external returns (address pool);

  function getDeployProps() external view returns (address, address, address);
 
  function owner() external view returns (address);
}
