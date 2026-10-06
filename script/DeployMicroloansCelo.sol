// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

import {CELO_SEPOLIA_USDC, CELO_USDT} from 'script/Registry.sol';

import {Microloans} from '../src/contracts/Microloans.sol';

uint256 constant MICROLOANS_CELO_SEPOLIA_CHAIN_ID = 11_142_220;

/**
 * @title Deploy Microloans (Celo)
 * @notice Deploys Microloans behind a transparent proxy and allows the loan stablecoin: USDT on
 *         mainnet, USDC on Celo Sepolia. LOAN_TOKEN_ADDRESS overrides either default.
 *         If MICROLOAN_VAULT_ADDRESS is set (an ERC-4626 vault over the loan token, e.g. the Aave
 *         v3 static aToken wrapper for USDT on Celo), it is allowed for escrow yield too.
 *         The broadcasting key MUST be ADMIN_ADDRESS, since the allowlist setters are onlyOwner.
 */
contract DeployMicroloansCelo is Script {
  function run() public {
    address admin = vm.envAddress('ADMIN_ADDRESS');
    address loanToken = vm.envOr('LOAN_TOKEN_ADDRESS', _defaultLoanToken());
    address vault = vm.envOr('MICROLOAN_VAULT_ADDRESS', address(0));

    vm.startBroadcast();

    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new Microloans()), admin, abi.encodeWithSelector(Microloans.initialize.selector, admin)
    );
    Microloans(address(proxy)).setTokenAllowed(loanToken, true);
    if (vault != address(0)) Microloans(address(proxy)).setVaultAllowed(vault, true);

    vm.stopBroadcast();

    console2.log('Microloans proxy:', address(proxy));
  }

  function _defaultLoanToken() internal view returns (address _token) {
    _token = block.chainid == MICROLOANS_CELO_SEPOLIA_CHAIN_ID ? CELO_SEPOLIA_USDC : CELO_USDT;
  }
}
