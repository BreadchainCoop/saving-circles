// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AutomaticSavingCircles} from '../../src/contracts/AutomaticSavingCircles.sol';
import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {IAutomaticSavingCircles} from '../../src/interfaces/IAutomaticSavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {SavingCirclesTestBase} from '../utils/SavingCirclesTestBase.t.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

contract AutomaticSavingCirclesUnit is SavingCirclesTestBase {
  SavingCircles public savingCircles;
  AutomaticSavingCircles public automaticSavingCircles;
  MockERC20 public token;
  ProxyAdmin public proxyAdmin;

  address public owner = makeAddr('owner');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public gelatoExecutor = makeAddr('gelatoExecutor');
  uint256 internal _ownerPrivateKey;
  uint256 internal _alicePrivateKey;
  uint256 internal _bobPrivateKey;
  uint256 internal _carolPrivateKey;

  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 weeks;

  uint256 public baseCircleId;
  ISavingCircles.Circle public baseCircle;
  address[] public members;

  function setUp() external {
    token = new MockERC20('Test Token', 'TEST');

    (owner, _ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, _alicePrivateKey) = makeAddrAndKey('alice');
    (bob, _bobPrivateKey) = makeAddrAndKey('bob');
    (carol, _carolPrivateKey) = makeAddrAndKey('carol');

    proxyAdmin = new ProxyAdmin(owner);
    SavingCircles implementation = new SavingCircles();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation), address(proxyAdmin), abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
    );
    savingCircles = SavingCircles(address(proxy));

    automaticSavingCircles = new AutomaticSavingCircles(address(savingCircles), owner);

    vm.prank(owner);
    automaticSavingCircles.setAutomationExecutor(gelatoExecutor);

    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);

    baseCircle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));
    baseCircleId = _createCircleWithMembers(savingCircles, baseCircle, members, _alicePrivateKey);
  }

  function test_SetAutomaticDepositsEnabled() external {
    assertFalse(automaticSavingCircles.isAutomaticDepositsEnabled(alice));

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomaticDepositsToggled(alice, true);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    assertTrue(automaticSavingCircles.isAutomaticDepositsEnabled(alice));

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomaticDepositsToggled(alice, false);
    automaticSavingCircles.setAutomaticDepositsEnabled(false);

    assertFalse(automaticSavingCircles.isAutomaticDepositsEnabled(alice));
  }

  function test_SetAutomaticClaimsEnabled() external {
    assertFalse(automaticSavingCircles.isAutomaticClaimsEnabled(baseCircleId, alice));

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomaticClaimsToggled(baseCircleId, alice, true);
    automaticSavingCircles.setAutomaticClaimsEnabled(baseCircleId, true);

    assertTrue(automaticSavingCircles.isAutomaticClaimsEnabled(baseCircleId, alice));

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomaticClaimsToggled(baseCircleId, alice, false);
    automaticSavingCircles.setAutomaticClaimsEnabled(baseCircleId, false);

    assertFalse(automaticSavingCircles.isAutomaticClaimsEnabled(baseCircleId, alice));
  }

  function test_SetAutomationExecutor() external {
    address newExecutor = makeAddr('newExecutor');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomationExecutorUpdated(gelatoExecutor, newExecutor);
    automaticSavingCircles.setAutomationExecutor(newExecutor);

    assertEq(automaticSavingCircles.automationExecutor(), newExecutor);
  }

  function test_SetAutomationExecutor_WhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
    automaticSavingCircles.setAutomationExecutor(makeAddr('newExecutor'));
  }

  function test_CheckerPayload_DepositsForEligibleMembersAcrossAllCircles() external {
    uint256 secondCircleId = _createStartedCircle();
    uint256 totalRequiredPerMember = DEPOSIT_AMOUNT * 2;

    _fundEnableAndApprove(alice, totalRequiredPerMember);
    _fundEnableAndApprove(bob, totalRequiredPerMember);
    _fundEnableAndApprove(carol, totalRequiredPerMember);

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.depositChecker();
    assertTrue(canExec);

    vm.prank(gelatoExecutor);
    (bool success,) = address(automaticSavingCircles).call(execPayload);
    assertTrue(success);

    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, bob), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, carol), DEPOSIT_AMOUNT);

    assertEq(savingCircles.balances(secondCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(secondCircleId, bob), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(secondCircleId, carol), DEPOSIT_AMOUNT);
  }

  function test_GetEligibleAutomatedDeposits_ReturnsOnlyEligibleTargets() external {
    uint256 unstartedCircleId = _createUnstartedCircle();

    _fundEnableAndApprove(alice, DEPOSIT_AMOUNT);

    vm.prank(bob);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    (uint256[] memory circleIds, address[] memory targetMembers) = automaticSavingCircles.getEligibleAutomatedDeposits();

    assertEq(circleIds.length, 1);
    assertEq(targetMembers.length, 1);
    assertEq(circleIds[0], baseCircleId);
    assertEq(targetMembers[0], alice);

    assertFalse(circleIds[0] == unstartedCircleId);
  }

  function test_CheckerPayload_SkipsIneligibleMembersAndUnstartedCircles() external {
    uint256 unstartedCircleId = _createUnstartedCircle();

    _fundEnableAndApprove(alice, DEPOSIT_AMOUNT * 2);

    token.mint(bob, DEPOSIT_AMOUNT);
    vm.prank(bob);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(carol);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(carol);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.depositChecker();
    assertTrue(canExec);

    vm.prank(gelatoExecutor);
    (bool success,) = address(automaticSavingCircles).call(execPayload);
    assertTrue(success);

    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, bob), 0);
    assertEq(savingCircles.balances(baseCircleId, carol), 0);

    assertEq(savingCircles.balances(unstartedCircleId, alice), 0);
    assertEq(savingCircles.balances(unstartedCircleId, bob), 0);
    assertEq(savingCircles.balances(unstartedCircleId, carol), 0);
  }

  function test_BatchExecuteAutomatedDeposits_CompletesPartialDeposit() external {
    uint256 partialAmount = DEPOSIT_AMOUNT / 2;
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.startPrank(alice);
    token.approve(address(savingCircles), partialAmount);
    savingCircles.depositFor(baseCircleId, partialAmount, alice);
    vm.stopPrank();

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), partialAmount);

    (uint256[] memory circleIds, address[] memory targetMembers) = automaticSavingCircles.getEligibleAutomatedDeposits();

    vm.prank(gelatoExecutor);
    automaticSavingCircles.batchExecuteAutomatedDeposits(circleIds, targetMembers);

    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
  }

  function test_BatchExecuteAutomatedDeposits_DepositsForProvidedTargets() external {
    uint256 secondCircleId = _createStartedCircle();
    uint256 totalRequiredPerMember = DEPOSIT_AMOUNT * 2;

    _fundEnableAndApprove(alice, totalRequiredPerMember);
    _fundEnableAndApprove(bob, totalRequiredPerMember);
    _fundEnableAndApprove(carol, totalRequiredPerMember);

    (uint256[] memory circleIds, address[] memory targetMembers) = automaticSavingCircles.getEligibleAutomatedDeposits();

    vm.prank(gelatoExecutor);
    automaticSavingCircles.batchExecuteAutomatedDeposits(circleIds, targetMembers);

    assertEq(circleIds.length, 6);
    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, bob), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, carol), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(secondCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(secondCircleId, bob), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(secondCircleId, carol), DEPOSIT_AMOUNT);
  }

  function test_BatchExecuteAutomatedDeposits_ContinuesWhenOneTargetFails() external {
    _fundEnableAndApprove(alice, DEPOSIT_AMOUNT);

    vm.prank(bob);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    uint256[] memory circleIds = new uint256[](2);
    address[] memory targetMembers = new address[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;
    targetMembers[0] = alice;
    targetMembers[1] = bob;

    vm.prank(gelatoExecutor);
    automaticSavingCircles.batchExecuteAutomatedDeposits(circleIds, targetMembers);

    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, bob), 0);
  }

  function test_BatchExecuteAutomatedDeposits_RevertsOnMismatchedArrays() external {
    uint256[] memory circleIds = new uint256[](1);
    address[] memory targetMembers = new address[](0);
    circleIds[0] = baseCircleId;

    vm.prank(gelatoExecutor);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.ArrayLengthMismatch.selector));
    automaticSavingCircles.batchExecuteAutomatedDeposits(circleIds, targetMembers);
  }

  function test_BatchExecuteAutomatedDeposits_WhenCallerIsNotAutomationExecutor() external {
    uint256[] memory circleIds = new uint256[](0);
    address[] memory targetMembers = new address[](0);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.OnlyAutomationExecutor.selector));
    automaticSavingCircles.batchExecuteAutomatedDeposits(circleIds, targetMembers);
  }

  function test_ExecuteAutomatedDepositTarget_WhenCallerIsNotSelf() external {
    vm.prank(alice);
    vm.expectRevert(AutomaticSavingCircles.OnlySelf.selector);
    automaticSavingCircles.executeAutomatedDepositTarget(baseCircleId, alice);
  }

  function test_ExecuteAutomatedClaimTarget_WhenCallerIsNotSelf() external {
    vm.prank(alice);
    vm.expectRevert(AutomaticSavingCircles.OnlySelf.selector);
    automaticSavingCircles.executeAutomatedClaimTarget(baseCircleId, alice);
  }

  function test_Checker_ReturnsTrueAndExecPayloadWhenAnyEligibleMemberExists() external {
    _fundEnableAndApprove(alice, DEPOSIT_AMOUNT);
    (uint256[] memory circleIds, address[] memory targetMembers) = automaticSavingCircles.getEligibleAutomatedDeposits();

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.depositChecker();

    assertTrue(canExec);
    assertEq(
      execPayload, abi.encodeCall(IAutomaticSavingCircles.batchExecuteAutomatedDeposits, (circleIds, targetMembers))
    );
  }

  function test_Checker_ReturnsFalseWhenAutomationExecutorUnset() external {
    _fundEnableAndApprove(alice, DEPOSIT_AMOUNT);

    vm.prank(owner);
    automaticSavingCircles.setAutomationExecutor(address(0));

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.depositChecker();

    assertFalse(canExec);
    assertEq(execPayload, bytes(''));
  }

  function test_Checker_ReturnsFalseWhenNoEligibleMembersExist() external view {
    (bool canExec, bytes memory execPayload) = automaticSavingCircles.depositChecker();

    assertFalse(canExec);
    assertEq(execPayload, bytes(''));
  }

  function test_Checker_ReturnsFalseWhenOnlyUnstartedCirclesHaveEligibleMembers() external {
    _depositBaseCircleForAlice();
    _createUnstartedCircle();

    token.mint(alice, DEPOSIT_AMOUNT * 2);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT * 2);

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.depositChecker();

    assertFalse(canExec);
    assertEq(execPayload, bytes(''));
  }

  function test_GetEligibleAutomatedDeposits_SkipsDecommissionedCircles() external {
    uint256 decommissionedCircleId = _createStartedCircleWithInterval(1 seconds);

    vm.warp(block.timestamp + 2 seconds);
    vm.prank(alice);
    savingCircles.decommission(decommissionedCircleId);

    _fundEnableAndApprove(alice, DEPOSIT_AMOUNT);

    (uint256[] memory circleIds, address[] memory targetMembers) = automaticSavingCircles.getEligibleAutomatedDeposits();

    assertEq(circleIds.length, 1);
    assertEq(targetMembers.length, 1);
    assertEq(circleIds[0], baseCircleId);
    assertEq(targetMembers[0], alice);
  }

  function test_GetEligibleAutomatedClaims_ReturnsOnlyWhenAllMembersDepositedAndRoundTimePassed() external {
    _depositRound(baseCircleId);
    _enableAutomaticClaim(baseCircleId, alice);

    (uint256[] memory circleIdsBefore, address[] memory targetMembersBefore) =
      automaticSavingCircles.getEligibleAutomatedClaims();
    assertEq(circleIdsBefore.length, 0);
    assertEq(targetMembersBefore.length, 0);

    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    vm.warp(circle.effectiveCircleStartTime + DEPOSIT_INTERVAL);

    (uint256[] memory circleIdsAfter, address[] memory targetMembersAfter) =
      automaticSavingCircles.getEligibleAutomatedClaims();

    assertEq(circleIdsAfter.length, 1);
    assertEq(targetMembersAfter.length, 1);
    assertEq(circleIdsAfter[0], baseCircleId);
    assertEq(targetMembersAfter[0], alice);
  }

  function test_GetEligibleAutomatedClaims_ReturnsFalseWhenRoundTimePassedButDepositsIncomplete() external {
    _enableAutomaticClaim(baseCircleId, alice);

    token.mint(alice, DEPOSIT_AMOUNT);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    vm.warp(circle.effectiveCircleStartTime + DEPOSIT_INTERVAL);

    (uint256[] memory circleIds, address[] memory targetMembers) = automaticSavingCircles.getEligibleAutomatedClaims();

    assertEq(circleIds.length, 0);
    assertEq(targetMembers.length, 0);
  }

  function test_GetEligibleAutomatedClaims_ReturnsOnlyEnabledCircleForMember() external {
    uint256 secondCircleId = _createStartedCircle();
    _depositRound(baseCircleId);
    _depositRound(secondCircleId);
    _enableAutomaticClaim(baseCircleId, alice);

    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    vm.warp(circle.effectiveCircleStartTime + DEPOSIT_INTERVAL);

    (uint256[] memory circleIds, address[] memory targetMembers) = automaticSavingCircles.getEligibleAutomatedClaims();

    assertEq(circleIds.length, 1);
    assertEq(targetMembers.length, 1);
    assertEq(circleIds[0], baseCircleId);
    assertEq(targetMembers[0], alice);
  }

  function test_ClaimCheckerPayload_ClaimsForEligibleMembersAcrossAllCircles() external {
    uint256 secondCircleId = _createStartedCircle();
    _depositRound(baseCircleId);
    _depositRound(secondCircleId);
    _enableAutomaticClaim(baseCircleId, alice);
    _enableAutomaticClaim(secondCircleId, alice);

    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    vm.warp(circle.effectiveCircleStartTime + DEPOSIT_INTERVAL);

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.claimChecker();
    assertTrue(canExec);

    assertFalse(savingCircles.hasClaimed(baseCircleId, alice));
    assertFalse(savingCircles.hasClaimed(secondCircleId, alice));
    assertEq(token.balanceOf(alice), 0);

    vm.prank(gelatoExecutor);
    (bool success,) = address(automaticSavingCircles).call(execPayload);
    assertTrue(success);

    assertTrue(savingCircles.hasClaimed(baseCircleId, alice));
    assertTrue(savingCircles.hasClaimed(secondCircleId, alice));
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT * members.length * 2);
  }

  function test_ClaimChecker_ReturnsFalseWhenAutomationExecutorUnset() external {
    _depositRound(baseCircleId);
    _enableAutomaticClaim(baseCircleId, alice);

    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    vm.warp(circle.effectiveCircleStartTime + DEPOSIT_INTERVAL);

    vm.prank(owner);
    automaticSavingCircles.setAutomationExecutor(address(0));

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.claimChecker();

    assertFalse(canExec);
    assertEq(execPayload, bytes(''));
  }

  function test_ClaimChecker_ReturnsFalseWhenNoEligibleClaimsExist() external view {
    (bool canExec, bytes memory execPayload) = automaticSavingCircles.claimChecker();

    assertFalse(canExec);
    assertEq(execPayload, bytes(''));
  }

  function test_BatchExecuteAutomatedClaims_WhenCallerIsNotAutomationExecutor() external {
    uint256[] memory circleIds = new uint256[](0);
    address[] memory targetMembers = new address[](0);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.OnlyAutomationExecutor.selector));
    automaticSavingCircles.batchExecuteAutomatedClaims(circleIds, targetMembers);
  }

  function test_BatchExecuteAutomatedClaims_ContinuesWhenOneTargetFails() external {
    _depositRound(baseCircleId);
    _enableAutomaticClaim(baseCircleId, bob);
    _enableAutomaticClaim(baseCircleId, alice);

    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    vm.warp(circle.effectiveCircleStartTime + DEPOSIT_INTERVAL);

    uint256[] memory circleIds = new uint256[](2);
    address[] memory targetMembers = new address[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;
    targetMembers[0] = bob;
    targetMembers[1] = alice;

    vm.prank(gelatoExecutor);
    vm.expectEmit(true, true, false, true, address(automaticSavingCircles));
    emit IAutomaticSavingCircles.AutomatedClaimFailed(
      baseCircleId, bob, abi.encodeWithSelector(ISavingCircles.NotWithdrawable.selector)
    );
    automaticSavingCircles.batchExecuteAutomatedClaims(circleIds, targetMembers);

    assertFalse(savingCircles.hasClaimed(baseCircleId, bob));
    assertTrue(savingCircles.hasClaimed(baseCircleId, alice));
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT * members.length);
  }

  function test_BatchExecuteAutomatedClaims_DoesNotClaimForMemberWithoutOptIn() external {
    _depositRound(baseCircleId);

    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    vm.warp(circle.effectiveCircleStartTime + DEPOSIT_INTERVAL);

    uint256[] memory circleIds = new uint256[](1);
    address[] memory targetMembers = new address[](1);
    circleIds[0] = baseCircleId;
    targetMembers[0] = alice;

    vm.prank(gelatoExecutor);
    vm.expectEmit(true, true, false, true, address(automaticSavingCircles));
    emit IAutomaticSavingCircles.AutomatedClaimFailed(
      baseCircleId, alice, abi.encodeWithSelector(IAutomaticSavingCircles.AutomaticClaimsNotEnabled.selector)
    );
    automaticSavingCircles.batchExecuteAutomatedClaims(circleIds, targetMembers);

    assertFalse(savingCircles.hasClaimed(baseCircleId, alice));
  }

  function test_BatchExecuteAutomatedClaims_RevertsOnMismatchedArrays() external {
    uint256[] memory circleIds = new uint256[](1);
    address[] memory targetMembers = new address[](0);
    circleIds[0] = baseCircleId;

    vm.prank(gelatoExecutor);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.ArrayLengthMismatch.selector));
    automaticSavingCircles.batchExecuteAutomatedClaims(circleIds, targetMembers);
  }

  function _fundEnableAndApprove(address _member, uint256 _amount) internal {
    token.mint(_member, _amount);

    vm.prank(_member);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(_member);
    token.approve(address(automaticSavingCircles), _amount);
  }

  function _enableAutomaticClaim(uint256 _circleId, address _member) internal {
    vm.prank(_member);
    automaticSavingCircles.setAutomaticClaimsEnabled(_circleId, true);
  }

  function _createStartedCircle() internal returns (uint256) {
    ISavingCircles.Circle memory circle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));
    return _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);
  }

  function _createStartedCircleWithInterval(uint256 _depositInterval) internal returns (uint256) {
    ISavingCircles.Circle memory circle = _defaultCircle(alice, DEPOSIT_AMOUNT, _depositInterval, address(token));
    return _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);
  }

  function _createUnstartedCircle() internal returns (uint256) {
    ISavingCircles.Circle memory circle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));
    return _createCircle(savingCircles, circle, members, _alicePrivateKey);
  }

  function _depositRound(uint256 _circleId) internal {
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(_circleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }
  }

  function _depositBaseCircleForAlice() internal {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.depositFor(baseCircleId, DEPOSIT_AMOUNT, alice);
    vm.stopPrank();
  }
}
