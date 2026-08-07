// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

import {AccumulatingSavingCircles} from '../src/contracts/AccumulatingSavingCircles.sol';
import {AutomaticSavingCircles} from '../src/contracts/AutomaticSavingCircles.sol';
import {CollectiveFundCircles} from '../src/contracts/CollectiveFundCircles.sol';
import {GoalSavingCircles} from '../src/contracts/GoalSavingCircles.sol';
import {SavingCircles} from '../src/contracts/SavingCircles.sol';
import {SavingCirclesViewer} from '../src/contracts/SavingCirclesViewer.sol';
import {SEPOLIA_CHAIN_ID, SEPOLIA_TEST_TOKEN} from './Registry.sol';

/**
 * @title Common Contract
 * @author Bread Cooperative
 * @notice This contract is used to deploy an upgradeable Saving Circles contract
 * @dev This contract is intended for use in Scripts and Integration Tests
 */
contract Common is Script {
  /**
   * @notice Every registry deployed by _deployAll
   * @param savingCircles The rotating saving circles (ROSCA) proxy
   * @param automaticSavingCircles The Chainlink automation satellite
   * @param savingCirclesViewer The read aggregation satellite
   * @param accumulatingSavingCircles The ASCA proxy
   * @param goalSavingCircles The goal savings proxy
   * @param collectiveFundCircles The collective fund proxy
   */
  struct Deployment {
    TransparentUpgradeableProxy savingCircles;
    AutomaticSavingCircles automaticSavingCircles;
    SavingCirclesViewer savingCirclesViewer;
    TransparentUpgradeableProxy accumulatingSavingCircles;
    TransparentUpgradeableProxy goalSavingCircles;
    TransparentUpgradeableProxy collectiveFundCircles;
  }

  function setUp() public virtual {}

  function _deploySavingCircles() internal returns (SavingCircles) {
    return new SavingCircles();
  }

  function _deployTransparentProxy(
    address _implementation,
    address _initialAdminOwner,
    bytes memory _initData
  ) internal returns (TransparentUpgradeableProxy) {
    return new TransparentUpgradeableProxy(_implementation, _initialAdminOwner, _initData);
  }

  function _deployContracts(address _admin) internal returns (TransparentUpgradeableProxy) {
    return _deployAll(_admin).savingCircles;
  }

  function _deployAll(address _admin) internal returns (Deployment memory) {
    TransparentUpgradeableProxy proxy = _deployTransparentProxy(
      address(_deploySavingCircles()), _admin, abi.encodeWithSelector(SavingCircles.initialize.selector, _admin)
    );

    // Deploy auxiliary contracts that reference the SavingCircles proxy
    AutomaticSavingCircles automaticSavingCircles = new AutomaticSavingCircles(address(proxy), _admin);
    SavingCirclesViewer savingCirclesViewer = new SavingCirclesViewer(address(proxy));

    // Deploy the other stack types behind their own transparent proxies
    TransparentUpgradeableProxy accumulatingProxy = _deployTransparentProxy(
      address(new AccumulatingSavingCircles()),
      _admin,
      abi.encodeWithSelector(AccumulatingSavingCircles.initialize.selector, _admin)
    );
    TransparentUpgradeableProxy goalProxy = _deployTransparentProxy(
      address(new GoalSavingCircles()), _admin, abi.encodeWithSelector(GoalSavingCircles.initialize.selector, _admin)
    );
    TransparentUpgradeableProxy collectiveProxy = _deployTransparentProxy(
      address(new CollectiveFundCircles()),
      _admin,
      abi.encodeWithSelector(CollectiveFundCircles.initialize.selector, _admin)
    );

    console2.log('SavingCircles proxy:', address(proxy));
    console2.log('AutomaticSavingCircles:', address(automaticSavingCircles));
    console2.log('SavingCirclesViewer:', address(savingCirclesViewer));
    console2.log('AccumulatingSavingCircles proxy:', address(accumulatingProxy));
    console2.log('GoalSavingCircles proxy:', address(goalProxy));
    console2.log('CollectiveFundCircles proxy:', address(collectiveProxy));

    return Deployment({
      savingCircles: proxy,
      automaticSavingCircles: automaticSavingCircles,
      savingCirclesViewer: savingCirclesViewer,
      accumulatingSavingCircles: accumulatingProxy,
      goalSavingCircles: goalProxy,
      collectiveFundCircles: collectiveProxy
    });
  }

  /**
   * @dev Allow a token on every registry so a fresh deployment is usable straight away.
   *      Testnet deployments are throwaway and would otherwise need a manual owner
   *      transaction before anyone can create a stack. On chains with no token configured
   *      this is a no-op.
   * @dev The calls are deliberately NOT wrapped in try/catch: forge only records calls for
   *      broadcast outside a try context, so a try/catch here would simulate successfully
   *      and then silently never be broadcast, leaving the deployment un-allowlisted. A
   *      deployer that does not own the registries means ADMIN_ADDRESS does not match the
   *      broadcasting key, which should fail the deployment loudly.
   */
  function _allowlistToken(Deployment memory _deployment, address _token) internal {
    if (_token == address(0)) return;

    address[4] memory registries = [
      address(_deployment.savingCircles),
      address(_deployment.accumulatingSavingCircles),
      address(_deployment.goalSavingCircles),
      address(_deployment.collectiveFundCircles)
    ];

    for (uint256 i = 0; i < registries.length; i++) {
      SavingCircles(registries[i]).setTokenAllowed(_token, true);
      console2.log('Allowed token on:', registries[i]);
    }
  }

  /// @dev The token to allow at deploy time, or address(0) when the chain has none configured.
  ///      ALLOWLIST_TOKEN overrides the per-chain default.
  function _tokenToAllowlist() internal view returns (address) {
    address configured = vm.envOr('ALLOWLIST_TOKEN', address(0));
    if (configured != address(0)) return configured;
    if (block.chainid == SEPOLIA_CHAIN_ID) return SEPOLIA_TEST_TOKEN;
    return address(0);
  }
}
