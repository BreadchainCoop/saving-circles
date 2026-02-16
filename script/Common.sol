// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
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
  bytes32 internal constant _ERC1967_IMPLEMENTATION_SLOT =
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
  bytes32 internal constant _ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
  bytes4 internal constant _OWNER_SELECTOR = bytes4(keccak256('owner()'));
  bytes4 internal constant _UPGRADE_INTERFACE_VERSION_SELECTOR = bytes4(keccak256('UPGRADE_INTERFACE_VERSION()'));

  error InvalidAdminAddress();
  error InvalidAdminProxyAdmin(address admin);
  error ProxyAdminOwnerMismatch(address proxyAdmin, address expectedOwner, address actualOwner);
  error ProxyAdminNotDeployed(address proxy);
  error ProxyImplementationSlotMismatch(address proxy, address expectedImplementation, address actualImplementation);

  function setUp() public virtual {}

  function _deploySavingCircles() internal returns (SavingCircles) {
    return new SavingCircles();
  }

  function _deployTransparentProxy(
    address _implementation,
    address _adminOwner,
    bytes memory _initData
  ) internal returns (TransparentUpgradeableProxy) {
    return new TransparentUpgradeableProxy(_implementation, _adminOwner, _initData);
  }

  function _deployContracts(address _admin) internal returns (TransparentUpgradeableProxy) {
    _assertValidAdmin(_admin);

    SavingCircles implementation = _deploySavingCircles();
    TransparentUpgradeableProxy proxy = _deployTransparentProxy(
      address(implementation), _admin, abi.encodeWithSelector(SavingCircles.initialize.selector, _admin)
    );

    // Deploy auxiliary contracts that reference the SavingCircles proxy
    AutomaticSavingCircles automaticSavingCircles = new AutomaticSavingCircles(address(proxy), _admin);
    SavingCirclesViewer savingCirclesViewer = new SavingCirclesViewer(address(proxy));

    console2.log('SavingCircles proxy:', address(proxy));
    console2.log('AutomaticSavingCircles:', address(automaticSavingCircles));
    console2.log('SavingCirclesViewer:', address(savingCirclesViewer));

    address proxyAdmin = _assertDeployment(address(proxy), address(implementation), _admin);

    console2.log('Deployer', msg.sender);
    console2.log('Admin', _admin);
    console2.log('ProxyAdmin', proxyAdmin);
    console2.log('Proxy', address(proxy));
    console2.log('Implementation', address(implementation));

    return proxy;
  }

  function _assertValidAdmin(address _admin) internal view {
    if (_admin == address(0)) revert InvalidAdminAddress();
    if (_isProxyAdmin(_admin)) revert InvalidAdminProxyAdmin(_admin);
  }

  function _assertDeployment(
    address _proxy,
    address _implementation,
    address _expectedAdminOwner
  ) internal view returns (address proxyAdmin) {
    proxyAdmin = _readAddressFromSlot(_proxy, _ERC1967_ADMIN_SLOT);
    if (proxyAdmin == address(0)) revert ProxyAdminNotDeployed(_proxy);

    address actualOwner = ProxyAdmin(proxyAdmin).owner();
    if (actualOwner != _expectedAdminOwner) {
      revert ProxyAdminOwnerMismatch(proxyAdmin, _expectedAdminOwner, actualOwner);
    }

    address actualImplementation = _readAddressFromSlot(_proxy, _ERC1967_IMPLEMENTATION_SLOT);
    if (actualImplementation != _implementation) {
      revert ProxyImplementationSlotMismatch(_proxy, _implementation, actualImplementation);
    }
  }

  function _readAddressFromSlot(address _contract, bytes32 _slot) internal view returns (address) {
    return address(uint160(uint256(vm.load(_contract, _slot))));
  }

  function _isProxyAdmin(address _candidate) internal view returns (bool) {
    if (_candidate.code.length == 0) return false;

    (bool ownerCallSuccess,) = _candidate.staticcall(abi.encodeWithSelector(_OWNER_SELECTOR));
    if (!ownerCallSuccess) return false;

    (bool versionCallSuccess,) = _candidate.staticcall(abi.encodeWithSelector(_UPGRADE_INTERFACE_VERSION_SELECTOR));
    return versionCallSuccess;
  }
}
