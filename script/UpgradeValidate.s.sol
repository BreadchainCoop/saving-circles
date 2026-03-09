// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {console2} from 'forge-std/console2.sol';

import {Common} from 'script/Common.sol';
import {SavingCircles} from 'src/contracts/SavingCircles.sol';

contract UpgradeValidate is Common {
  error NewImplementationHasNoCode(address implementation);
  error NewImplementationMatchesCurrent(address implementation);

  function run() public view {
    address proxy = vm.envAddress('PROXY_ADDRESS');
    address expectedAdminOwner = vm.envAddress('EXPECTED_ADMIN_OWNER');
    address expectedCurrentImplementation = vm.envAddress('EXPECTED_CURRENT_IMPLEMENTATION');
    address newImplementation = vm.envAddress('NEW_IMPLEMENTATION');

    address proxyAdmin = _assertDeployment(proxy, expectedCurrentImplementation, expectedAdminOwner);

    if (newImplementation.code.length == 0) revert NewImplementationHasNoCode(newImplementation);
    if (newImplementation == expectedCurrentImplementation) {
      revert NewImplementationMatchesCurrent(newImplementation);
    }

    // Lightweight smoke check against proxy to confirm implementation responds.
    uint256 nextId = SavingCircles(proxy).nextId();

    console2.log('Validation successful');
    console2.log('Proxy', proxy);
    console2.log('ProxyAdmin', proxyAdmin);
    console2.log('AdminOwner', ProxyAdmin(proxyAdmin).owner());
    console2.log('CurrentImplementation', expectedCurrentImplementation);
    console2.log('NewImplementation', newImplementation);
    console2.log('SmokeCheck.nextId');
    console2.log(nextId);
  }
}
