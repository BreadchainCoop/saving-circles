// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

import {AutomaticSavingCircles} from '../src/contracts/AutomaticSavingCircles.sol';
import {SavingCircles} from '../src/contracts/SavingCircles.sol';
import {SavingCirclesViewer} from '../src/contracts/SavingCirclesViewer.sol';

/**
 * @title Common Contract
 * @author Bread Cooperative
 * @notice This contract is used to deploy an upgradeable Saving Circles contract
 * @dev This contract is intended for use in Scripts and Integration Tests
 */
contract Common is Script {
  function setUp() public virtual {}

  function _deploySavingCircles() internal returns (SavingCircles) {
    return new SavingCircles();
  }

  function _deployTransparentProxy(
    address _implementation,
    address _initialAdminOwner,
    bytes memory _initData
  ) internal returns (TransparentUpgradeableProxy) {
    return new TransparentUpgradeableProxy(_implementation, _initialAdminOwner, _initData);
  }

  function _deployContracts(address _admin) internal returns (TransparentUpgradeableProxy) {
    TransparentUpgradeableProxy proxy = _deployTransparentProxy(
      address(_deploySavingCircles()), _admin, abi.encodeWithSelector(SavingCircles.initialize.selector, _admin)
    );

    // Deploy auxiliary contracts that reference the SavingCircles proxy
    AutomaticSavingCircles automaticSavingCircles = new AutomaticSavingCircles(address(proxy), _admin);
    SavingCirclesViewer savingCirclesViewer = new SavingCirclesViewer(address(proxy));

    console2.log('SavingCircles proxy:', address(proxy));
    console2.log('AutomaticSavingCircles:', address(automaticSavingCircles));
    console2.log('SavingCirclesViewer:', address(savingCirclesViewer));

    return proxy;
  }
}
