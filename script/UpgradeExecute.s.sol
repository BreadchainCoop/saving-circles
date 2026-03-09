// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {console2} from 'forge-std/console2.sol';

import {Common} from 'script/Common.sol';

contract UpgradeExecute is Common {
  error NewImplementationHasNoCode(address implementation);
  error NewImplementationMatchesCurrent(address implementation);
  error AlreadyUpgraded(address implementation);

  function run() public {
    address proxy = vm.envAddress('PROXY_ADDRESS');
    address expectedAdminOwner = vm.envAddress('EXPECTED_ADMIN_OWNER');
    address expectedCurrentImplementation = vm.envAddress('EXPECTED_CURRENT_IMPLEMENTATION');
    address newImplementation = vm.envAddress('NEW_IMPLEMENTATION');
    bytes memory upgradeCalldata = _upgradeCalldataOrEmpty();

    address currentImplementation = _readAddressFromSlot(proxy, _ERC1967_IMPLEMENTATION_SLOT);
    if (currentImplementation == newImplementation) revert AlreadyUpgraded(newImplementation);

    address proxyAdmin = _assertDeployment(proxy, expectedCurrentImplementation, expectedAdminOwner);

    if (newImplementation.code.length == 0) revert NewImplementationHasNoCode(newImplementation);
    if (newImplementation == expectedCurrentImplementation) {
      revert NewImplementationMatchesCurrent(newImplementation);
    }

    console2.log('Executing upgrade');
    console2.log('Proxy', proxy);
    console2.log('ProxyAdmin', proxyAdmin);
    console2.log('AdminOwner', expectedAdminOwner);
    console2.log('CurrentImplementation', currentImplementation);
    console2.log('NewImplementation', newImplementation);
    console2.log('CalldataLength');
    console2.log(upgradeCalldata.length);

    vm.startBroadcast();
    ProxyAdmin(proxyAdmin)
      .upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), newImplementation, upgradeCalldata);
    vm.stopBroadcast();

    _assertDeployment(proxy, newImplementation, expectedAdminOwner);

    console2.log('Upgrade successful');
    console2.log('Proxy', proxy);
    console2.log('ProxyAdmin', proxyAdmin);
    console2.log('CurrentImplementation', _readAddressFromSlot(proxy, _ERC1967_IMPLEMENTATION_SLOT));
  }

  function _upgradeCalldataOrEmpty() internal view returns (bytes memory data) {
    try vm.envBytes('UPGRADE_CALLDATA') returns (bytes memory envData) {
      return envData;
    } catch {
      return bytes('');
    }
  }
}
