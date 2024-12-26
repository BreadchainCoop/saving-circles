// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';

import {SavingCircles} from '../src/contracts/SavingCircles.sol';

/**
 * @title Common Contract
 * @author Breadchain
 * @notice This contract is used to deploy an upgradable Saving Circles contract
 * @dev This contract is intended for use in Scripts and Integration Tests
 */
contract Common is Script {
  function setUp() public virtual {}

  function _deploySavingCircles() internal returns (SavingCircles) {
    return new SavingCircles();
  }

  function _deployProxyAdmin(address _admin) internal returns (ProxyAdmin) {
    return new ProxyAdmin(_admin);
  }

  function _deployTransparentProxy(
    address _implementation,
    address _proxyAdmin,
    bytes memory _initData
  ) internal returns (TransparentUpgradeableProxy) {
    return new TransparentUpgradeableProxy(_implementation, _proxyAdmin, _initData);
  }

  function _deployContracts(address _admin) internal returns (TransparentUpgradeableProxy) {
    return _deployTransparentProxy(
      address(_deploySavingCircles()),
      address(_deployProxyAdmin(_admin)),
      abi.encodeWithSelector(SavingCircles.initialize.selector, _admin)
    );
  }
}
