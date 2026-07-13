// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Common} from 'script/Common.sol';
import {CELO_USDT} from 'script/Registry.sol';

import {SavingCircles} from '../src/contracts/SavingCircles.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

/**
 * @title Deploy Celo
 * @notice Deploys Saving Circles to Celo mainnet and allows the deposit
 *         stablecoin (USDT by default) in one transaction. The broadcasting
 *         key MUST be ADMIN_ADDRESS, since setTokenAllowed is onlyOwner.
 */
contract DeployCelo is Common {
  function run() public {
    address admin = vm.envAddress('ADMIN_ADDRESS');
    address depositToken = vm.envOr('DEPOSIT_TOKEN_ADDRESS', CELO_USDT);

    vm.startBroadcast();

    TransparentUpgradeableProxy proxy = _deployContracts(admin);
    SavingCircles(address(proxy)).setTokenAllowed(depositToken, true);

    vm.stopBroadcast();
  }
}
