// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SavingsCircle} from '../src/contracts/SavingsCircle.sol';

import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';

contract DeploySavingsCircle is Script {
  function run() external returns (address proxy, address admin) {
    vm.startBroadcast();

    // Deploy implementation
    SavingsCircle implementation = new SavingsCircle();

    // Deploy ProxyAdmin
    ProxyAdmin proxyAdmin = new ProxyAdmin(msg.sender);

    // Encode initialization call
    bytes memory initData = abi.encodeWithSelector(SavingsCircle.initialize.selector);

    // Deploy proxy
    TransparentUpgradeableProxy transparentProxy =
      new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

    vm.stopBroadcast();
    return (address(transparentProxy), address(proxyAdmin));
  }
}
