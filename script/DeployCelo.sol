// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Common} from 'script/Common.sol';
import {CELO_SEPOLIA_USDC, CELO_USDT} from 'script/Registry.sol';

import {SavingCircles} from '../src/contracts/SavingCircles.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

uint256 constant CELO_SEPOLIA_CHAIN_ID = 11_142_220;

/**
 * @title Deploy Celo
 * @notice Deploys Saving Circles to a Celo network and allows the deposit
 *         stablecoin in one transaction: USDT on mainnet, USDC on Celo Sepolia
 *         (both 6-decimal, so the testnet run exercises the same non-18-decimal
 *         path as mainnet). DEPOSIT_TOKEN_ADDRESS overrides either default.
 *         The broadcasting key MUST be ADMIN_ADDRESS, since setTokenAllowed is
 *         onlyOwner.
 */
contract DeployCelo is Common {
  function run() public {
    address admin = vm.envAddress('ADMIN_ADDRESS');
    address depositToken = vm.envOr('DEPOSIT_TOKEN_ADDRESS', _defaultDepositToken());

    vm.startBroadcast();

    TransparentUpgradeableProxy proxy = _deployContracts(admin);
    SavingCircles(address(proxy)).setTokenAllowed(depositToken, true);

    vm.stopBroadcast();
  }

  /// @dev Celo Sepolia has its own USDC deployment; mainnet USDT has no code there.
  function _defaultDepositToken() internal view returns (address _token) {
    _token = block.chainid == CELO_SEPOLIA_CHAIN_ID ? CELO_SEPOLIA_USDC : CELO_USDT;
  }
}
