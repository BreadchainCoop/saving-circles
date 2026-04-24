// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

import {AutomaticSavingCircles} from '../src/contracts/AutomaticSavingCircles.sol';
import {SavingCircles} from '../src/contracts/SavingCircles.sol';
import {SavingCirclesViewer} from '../src/contracts/SavingCirclesViewer.sol';

contract UpgradeTestnet is Script {
  bytes32 internal constant _ERC1967_IMPLEMENTATION_SLOT =
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
  bytes32 internal constant _ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

  error InvalidAdminAddress();
  error ProxyAdminNotDeployed(address proxy);
  error ProxyAdminOwnerMismatch(address proxyAdmin, address expectedOwner, address actualOwner);
  error AlreadyUpgraded(address implementation);
  error ProxyImplementationSlotMismatch(address proxy, address expectedImplementation, address actualImplementation);

  function run() public {
    address proxy = vm.envAddress('PROXY_ADDRESS');
    address admin = vm.envAddress('ADMIN_ADDRESS');

    if (admin == address(0)) revert InvalidAdminAddress();

    address proxyAdmin = _readAddressFromSlot(proxy, _ERC1967_ADMIN_SLOT);
    if (proxyAdmin == address(0)) revert ProxyAdminNotDeployed(proxy);

    address actualOwner = ProxyAdmin(proxyAdmin).owner();
    if (actualOwner != admin) {
      revert ProxyAdminOwnerMismatch(proxyAdmin, admin, actualOwner);
    }

    address currentImplementation = _readAddressFromSlot(proxy, _ERC1967_IMPLEMENTATION_SLOT);

    console2.log('Preparing testnet upgrade');
    console2.log('Proxy', proxy);
    console2.log('ProxyAdmin', proxyAdmin);
    console2.log('Admin', admin);
    console2.log('CurrentImplementation', currentImplementation);

    vm.startBroadcast();

    SavingCircles implementation = new SavingCircles();
    if (address(implementation) == currentImplementation) revert AlreadyUpgraded(address(implementation));

    ProxyAdmin(proxyAdmin)
      .upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), address(implementation), bytes(''));

    AutomaticSavingCircles automaticSavingCircles = new AutomaticSavingCircles(proxy, admin);
    SavingCirclesViewer savingCirclesViewer = new SavingCirclesViewer(proxy);

    vm.stopBroadcast();

    address upgradedImplementation = _readAddressFromSlot(proxy, _ERC1967_IMPLEMENTATION_SLOT);
    if (upgradedImplementation != address(implementation)) {
      revert ProxyImplementationSlotMismatch(proxy, address(implementation), upgradedImplementation);
    }

    console2.log('Upgrade successful');
    console2.log('SavingCircles', address(implementation));
    console2.log('TransparentUpgradeableProxy', proxy);
    console2.log('AutomaticSavingCircles', address(automaticSavingCircles));
    console2.log('SavingCirclesViewer', address(savingCirclesViewer));
  }

  function _readAddressFromSlot(address _contract, bytes32 _slot) internal view returns (address) {
    return address(uint160(uint256(vm.load(_contract, _slot))));
  }
}
