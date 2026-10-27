// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Common} from 'script/Common.sol';
import {POLYGON_AMOY_USDC, POLYGON_USDC} from 'script/Registry.sol';

import {GoalSavingCircles} from '../src/contracts/GoalSavingCircles.sol';
import {SavingCircles} from '../src/contracts/SavingCircles.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

uint256 constant POLYGON_AMOY_CHAIN_ID = 80_002;

/**
 * @title Deploy Polygon
 * @notice Deploys Saving Circles to a Polygon network and allows the deposit
 *         stablecoin on both proxies in one broadcast: native USDC on mainnet, Circle's USDC
 *         on Amoy (both 6-decimal). POLYGON_DEPOSIT_TOKEN_ADDRESS overrides either
 *         default.
 *         The broadcasting key MUST be ADMIN_ADDRESS, since setTokenAllowed is
 *         onlyOwner.
 */
contract DeployPolygon is Common {
  function run() public {
    address admin = vm.envAddress('ADMIN_ADDRESS');
    address depositToken = vm.envOr('POLYGON_DEPOSIT_TOKEN_ADDRESS', _defaultDepositToken());

    vm.startBroadcast();

    (TransparentUpgradeableProxy proxy, TransparentUpgradeableProxy goalProxy) = _deployAllContracts(admin);
    SavingCircles(address(proxy)).setTokenAllowed(depositToken, true);
    GoalSavingCircles(address(goalProxy)).setTokenAllowed(depositToken, true);

    vm.stopBroadcast();
  }

  /// @dev Amoy has its own USDC deployment; mainnet USDC has no code there.
  function _defaultDepositToken() internal view returns (address _token) {
    _token = block.chainid == POLYGON_AMOY_CHAIN_ID ? POLYGON_AMOY_USDC : POLYGON_USDC;
  }
}
