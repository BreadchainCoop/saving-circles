// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

import {CELO_SEPOLIA_USDC, CELO_USDT} from 'script/Registry.sol';

import {ConditionalGrants} from '../src/contracts/ConditionalGrants.sol';

uint256 constant CONDITIONAL_GRANTS_CELO_CHAIN_ID = 42_220;
uint256 constant CONDITIONAL_GRANTS_CELO_SEPOLIA_CHAIN_ID = 11_142_220;

/// @dev ERC-1967 admin slot: holds the ProxyAdmin that can upgrade the proxy
bytes32 constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

/// @notice Only Celo mainnet and Celo Sepolia are supported
error UnsupportedChain();
/// @notice The grant token has no code on this chain
error GrantTokenHasNoCode();
/// @notice On mainnet the admin must be a contract or an account that has already sent a transaction
error AdminLooksUnused();
/// @notice A role did not end up with ADMIN_ADDRESS, or the token was not allowed
error DeployCheckFailed(string check);

/**
 * @title Deploy ConditionalGrants (Celo)
 * @notice Deploys ConditionalGrants behind a transparent proxy and allows the stablecoin used for
 *         advances and grants: USDT on mainnet, USDC on Celo Sepolia. GRANT_TOKEN_ADDRESS
 *         overrides either default.
 *         Any key can broadcast. The broadcaster owns the contract only long enough to allow the
 *         token, then ownership moves to ADMIN_ADDRESS, which also owns the ProxyAdmin from the
 *         start. ADMIN_ADDRESS can be a Safe or an EOA. Both moves are single-step, so on mainnet
 *         it must be a contract or an account that has already sent a transaction: a typo'd
 *         address would lose admin control for good.
 */
contract DeployConditionalGrantsCelo is Script {
  function run() public {
    bool _mainnet = block.chainid == CONDITIONAL_GRANTS_CELO_CHAIN_ID;
    if (!_mainnet && block.chainid != CONDITIONAL_GRANTS_CELO_SEPOLIA_CHAIN_ID) revert UnsupportedChain();

    address admin = vm.envAddress('ADMIN_ADDRESS');
    address grantToken = vm.envOr('GRANT_TOKEN_ADDRESS', _mainnet ? CELO_USDT : CELO_SEPOLIA_USDC);
    if (grantToken.code.length == 0) revert GrantTokenHasNoCode();

    vm.startBroadcast();
    (, address deployer,) = vm.readCallers();
    if (_mainnet && admin.code.length == 0 && vm.getNonce(admin) == 0) revert AdminLooksUnused();

    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new ConditionalGrants()), admin, abi.encodeWithSelector(ConditionalGrants.initialize.selector, deployer)
    );
    ConditionalGrants grants = ConditionalGrants(address(proxy));
    grants.setTokenAllowed(grantToken, true);
    grants.transferOwnership(admin);

    vm.stopBroadcast();

    address proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ERC1967_ADMIN_SLOT))));
    if (grants.owner() != admin) revert DeployCheckFailed('owner');
    if (ProxyAdmin(proxyAdmin).owner() != admin) revert DeployCheckFailed('ProxyAdmin owner');
    if (!grants.isTokenAllowed(grantToken)) revert DeployCheckFailed('token allowed');

    console2.log('ConditionalGrants proxy:', address(proxy));
    console2.log('ProxyAdmin (upgrades):', proxyAdmin);
    console2.log('Allowed token:', grantToken);
    console2.log('Owner and ProxyAdmin owner:', admin);
  }
}
