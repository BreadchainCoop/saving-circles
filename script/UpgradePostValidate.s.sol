// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {console2} from 'forge-std/console2.sol';

import {Common} from 'script/Common.sol';
import {SavingCircles} from 'src/contracts/SavingCircles.sol';
import {SavingCirclesViewer} from 'src/contracts/SavingCirclesViewer.sol';

contract UpgradePostValidate is Common {
  error ViewerProxyMismatch(address viewer, address expectedProxy, address actualProxy);

  function run() public view {
    address proxy = vm.envAddress('PROXY_ADDRESS');
    address expectedAdminOwner = vm.envAddress('EXPECTED_ADMIN_OWNER');
    address expectedImplementation = vm.envAddress('EXPECTED_IMPLEMENTATION');

    address proxyAdmin = _assertDeployment(proxy, expectedImplementation, expectedAdminOwner);
    uint256 nextId = SavingCircles(proxy).nextId();

    console2.log('Post-upgrade validation successful');
    console2.log('Proxy', proxy);
    console2.log('ProxyAdmin', proxyAdmin);
    console2.log('AdminOwner', ProxyAdmin(proxyAdmin).owner());
    console2.log('Implementation', expectedImplementation);
    console2.log('SmokeCheck.nextId');
    console2.log(nextId);

    address viewer = _viewerAddressOrZero();
    if (viewer == address(0)) return;

    address viewerProxy = address(SavingCirclesViewer(viewer).SAVING_CIRCLES());
    if (viewerProxy != proxy) revert ViewerProxyMismatch(viewer, proxy, viewerProxy);

    uint256 totalBalance = SavingCirclesViewer(viewer).getTotalBalance(expectedAdminOwner);
    console2.log('Viewer', viewer);
    console2.log('Viewer.SAVING_CIRCLES', viewerProxy);
    console2.log('ViewerSmoke.totalBalance(owner)');
    console2.log(totalBalance);
  }

  function _viewerAddressOrZero() internal view returns (address viewer) {
    try vm.envAddress('VIEWER_ADDRESS') returns (address envViewer) {
      return envViewer;
    } catch {
      return address(0);
    }
  }
}
