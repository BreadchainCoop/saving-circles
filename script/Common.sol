// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';

import {DelegatedSavingCircles} from '../src/contracts/DelegatedSavingCircles.sol';
import {SavingCircles} from '../src/contracts/SavingCircles.sol';
import {SavingCirclesViewer} from '../src/contracts/SavingCirclesViewer.sol';

/**
 * @title Common Contract
 * @author Bread
 * @notice This contract is used to deploy an upgradeable Saving Circles contract
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
    SavingCircles impl = _deploySavingCircles();
    ProxyAdmin proxyAdmin = _deployProxyAdmin(_admin);

    TransparentUpgradeableProxy proxy = _deployTransparentProxy(
      address(impl), address(proxyAdmin), abi.encodeWithSelector(SavingCircles.initialize.selector, _admin)
    );

    // Deploy helpers
    new DelegatedSavingCircles(address(proxy));
    new SavingCirclesViewer(address(proxy));

    return proxy;
  }
}
