// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

import {SavingCircles} from 'src/contracts/SavingCircles.sol';
import {SavingCirclesViewer} from 'src/contracts/SavingCirclesViewer.sol';
import {ISavingCircles} from 'src/interfaces/ISavingCircles.sol';
import {ISavingCirclesViewer} from 'src/interfaces/ISavingCirclesViewer.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';
import {SavingCirclesTestBase} from 'test/utils/SavingCirclesTestBase.t.sol';

contract SavingCirclesViewerUnit is SavingCirclesTestBase {
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;
  uint256 public constant CIRCLE_DURATION = 30 days;
  uint256 public constant MAX_DEPOSITS = 1000;

  SavingCircles public savingCircles;
  SavingCirclesViewer public savingCirclesViewer;
  MockERC20 public token;

  // Test addresses
  address public owner;
  address public alice;
  address public bob;
  address public carol;
  address public immutable STRANGER = makeAddr('stranger');
  uint256 internal _ownerPrivateKey;
  uint256 internal _alicePrivateKey;
  uint256 internal _bobPrivateKey;
  uint256 internal _carolPrivateKey;

  // Test data
  uint256 public baseCircleId;
  uint256 public baseCircleStart;
  address[] public members;
  ISavingCircles.Circle public baseCircle;

  function setUp() external {
    // Setup test addresses
    (owner, _ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, _alicePrivateKey) = makeAddrAndKey('alice');
    (bob, _bobPrivateKey) = makeAddrAndKey('bob');
    (carol, _carolPrivateKey) = makeAddrAndKey('carol');

    // Deploy and initialize the SavingCircles contract
    vm.startPrank(owner);
    savingCircles = SavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new SavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
        )
      )
    );

    token = new MockERC20('Test Token', 'TEST');
    savingCircles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    // Deploy the SavingCirclesViewer contract
    savingCirclesViewer = new SavingCirclesViewer(address(savingCircles));

    // Setup test data
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    // Setup baseCircle parameters
    baseCircle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));

    // Create an initial test circle
    baseCircleId = _createCircleWithMembers(savingCircles, baseCircle, members, _alicePrivateKey);
    baseCircleStart = savingCircles.getCircle(baseCircleId).effectiveCircleStartTime;
  }

  /**
   * @notice Ensures getTotalBalance sums a member's balances across multiple circles
   */
  function test_GetTotalBalanceAggregatesAcrossCircles() external {
    // Create a second circle with the same parameters but a different owner
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = bob;
    uint256 secondCircleId = _createCircleWithMembers(savingCircles, secondCircle, members, _bobPrivateKey);

    // Prepare deposits: full amount in first circle, half in second
    uint256 firstDeposit = DEPOSIT_AMOUNT;
    uint256 secondDeposit = DEPOSIT_AMOUNT / 2;

    // Mint and approve tokens for Alice
    token.mint(alice, firstDeposit + secondDeposit);
    vm.startPrank(alice);
    token.approve(address(savingCircles), firstDeposit + secondDeposit);

    // Perform deposits
    savingCircles.deposit(baseCircleId, firstDeposit);
    savingCircles.deposit(secondCircleId, secondDeposit);
    vm.stopPrank();

    // Expected total balance across both circles
    uint256 expectedTotal = firstDeposit + secondDeposit;

    uint256 totalBalance = savingCirclesViewer.getTotalBalance(alice);
    assertEq(totalBalance, expectedTotal, 'Total balance mismatch');
  }

  /**
   * @notice Ensures getTotalBalance returns zero when member has no balances
   */
  function test_GetTotalBalanceWhenNoDeposits() external {
    uint256 totalBalance = savingCirclesViewer.getTotalBalance(STRANGER);
    assertEq(totalBalance, 0, 'Total balance for non-member should be zero');
  }

  function test_GetComprehensiveUserDataForUserWithMultipleCircles() external {
    // Create a second circle
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = bob;
    uint256 secondCircleId = _createCircleWithMembers(savingCircles, secondCircle, members, _bobPrivateKey);

    // Make deposits in both circles
    token.mint(alice, DEPOSIT_AMOUNT * 2);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT * 2);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    savingCircles.deposit(secondCircleId, DEPOSIT_AMOUNT / 2);
    vm.stopPrank();

    // Get comprehensive user data
    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(alice);

    // Verify basic user data
    assertEq(userData.userAddress, alice);
    assertEq(userData.timestamp, block.timestamp);
    assertEq(userData.blockNumber, block.number);

    // Verify financial summary
    assertEq(userData.financialSummary.totalBalance, DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    assertEq(userData.financialSummary.totalDeposited, DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    assertEq(userData.financialSummary.activeCirclesCount, 2);
    assertEq(userData.financialSummary.ownedCirclesCount, 1);
    assertEq(userData.financialSummary.pendingWithdrawals, 0);
    assertEq(userData.financialSummary.upcomingDeposits, 1);

    // Verify membership status
    assertEq(userData.membershipStatus.allCircleIds.length, 2);
    assertEq(userData.membershipStatus.allCircleIds[0], baseCircleId);
    assertEq(userData.membershipStatus.allCircleIds[1], secondCircleId);
    assertEq(userData.membershipStatus.activeCircleIds.length, 2);
    assertEq(userData.membershipStatus.ownedCircleIds.length, 1);
    assertEq(userData.membershipStatus.ownedCircleIds[0], baseCircleId);

    // Verify circle data
    assertEq(userData.circleData.length, 2);

    // First circle data
    assertEq(userData.circleData[0].circleId, baseCircleId);
    assertEq(userData.circleData[0].userBalance, DEPOSIT_AMOUNT);
    assertTrue(userData.circleData[0].isMember);
    assertTrue(userData.circleData[0].isOwner);
    assertTrue(userData.circleData[0].isCurrentWithdrawer);
    assertFalse(userData.circleData[0].canWithdraw);
    assertEq(userData.circleData[0].completedRounds, 0);
    assertEq(userData.circleData[0].totalRounds, members.length);

    // Second circle data
    assertEq(userData.circleData[1].circleId, secondCircleId);
    assertEq(userData.circleData[1].userBalance, DEPOSIT_AMOUNT / 2);
    assertTrue(userData.circleData[1].isMember);
    assertFalse(userData.circleData[1].isOwner);
    assertFalse(userData.circleData[1].isCurrentWithdrawer);
    assertFalse(userData.circleData[1].canWithdraw);
  }

  function test_GetComprehensiveUserDataForCircleOwner() external {
    // Get comprehensive data for the circle owner
    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(alice);

    // Verify financial summary shows ownership
    assertEq(userData.financialSummary.ownedCirclesCount, 1);
    assertEq(userData.financialSummary.activeCirclesCount, 1);

    // Verify membership status
    assertEq(userData.membershipStatus.ownedCircleIds.length, 1);
    assertEq(userData.membershipStatus.ownedCircleIds[0], baseCircleId);

    // Verify circle data shows ownership
    assertTrue(userData.circleData[0].isOwner);
    assertTrue(userData.circleData[0].isMember);
    assertTrue(userData.circleData[0].isCurrentWithdrawer);
    assertFalse(userData.circleData[0].isDecommissionable);
  }

  function test_GetComprehensiveUserDataWithWithdrawableCircle() external {
    // Complete deposits from all members
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.mint(carol, DEPOSIT_AMOUNT);

    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Get comprehensive user data for alice (first withdrawer)
    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(alice);

    // Verify withdrawal status
    assertEq(userData.financialSummary.pendingWithdrawals, 1);
    assertTrue(userData.circleData[0].canWithdraw);
    assertTrue(userData.circleData[0].isCurrentWithdrawer);
    assertEq(userData.membershipStatus.withdrawableCircleIds.length, 1);
    assertEq(userData.membershipStatus.withdrawableCircleIds[0], baseCircleId);
    assertFalse(userData.circleData[0].isDecommissionable);
  }

  function test_GetComprehensiveUserDataCanWithdrawForLateClaimablePastRoundMember() external {
    // Complete rounds 0 and 1 so alice (round 0) remains claimable at round 2.
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT * 2);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT * 2);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT); // round 0
      vm.stopPrank();
    }

    vm.warp(baseCircleStart + DEPOSIT_INTERVAL);
    for (uint256 i = 0; i < members.length; i++) {
      vm.startPrank(members[i]);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT); // round 1
      vm.stopPrank();
    }

    vm.warp(baseCircleStart + (DEPOSIT_INTERVAL * 2)); // round 2, current withdrawer is carol

    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(alice);

    assertFalse(userData.circleData[0].isCurrentWithdrawer);
    assertTrue(userData.circleData[0].canWithdraw);
    assertFalse(userData.circleData[0].isDecommissionable);
    assertEq(userData.financialSummary.pendingWithdrawals, 1);
    assertEq(userData.membershipStatus.withdrawableCircleIds.length, 1);
    assertEq(userData.membershipStatus.withdrawableCircleIds[0], baseCircleId);
  }

  function test_GetComprehensiveUserDataCanWithdrawFalseWhenLateClaimWouldBeDecommissionable() external {
    // Complete only round 0 and skip round 1 deposits.
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    vm.warp(baseCircleStart + (DEPOSIT_INTERVAL * 2)); // decommissionable due to incomplete round 1

    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(alice);

    assertTrue(userData.circleData[0].isDecommissionable);
    assertFalse(userData.circleData[0].canWithdraw);
    assertEq(userData.financialSummary.pendingWithdrawals, 0);
    assertEq(userData.membershipStatus.withdrawableCircleIds.length, 0);
  }

  function test_GetComprehensiveUserDataForNonMember() external {
    // Get comprehensive data for a non-member
    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(STRANGER);

    // Verify all counts are zero
    assertEq(userData.financialSummary.totalBalance, 0);
    assertEq(userData.financialSummary.activeCirclesCount, 0);
    assertEq(userData.financialSummary.ownedCirclesCount, 0);
    assertEq(userData.membershipStatus.allCircleIds.length, 0);
    assertEq(userData.circleData.length, 0);
  }

  function test_GetUserFinancialSummaryAccuracy() external {
    // Create multiple circles with different parameters
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = bob;
    secondCircle.depositAmount = DEPOSIT_AMOUNT * 2;
    uint256 secondCircleId = _createCircleWithMembers(savingCircles, secondCircle, members, _bobPrivateKey);

    // Make deposits
    token.mint(alice, DEPOSIT_AMOUNT * 3);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT * 3);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    savingCircles.deposit(secondCircleId, DEPOSIT_AMOUNT * 2);
    vm.stopPrank();

    // Get financial summary
    SavingCirclesViewer.UserFinancialSummary memory summary = savingCirclesViewer.getUserFinancialSummary(alice);

    // Verify calculations
    assertEq(summary.totalBalance, DEPOSIT_AMOUNT * 3);
    assertEq(summary.totalDeposited, DEPOSIT_AMOUNT * 3);
    assertEq(summary.activeCirclesCount, 2);
    assertEq(summary.upcomingDeposits, 0);
  }

  function test_GetUserFinancialSummaryWithPartialDeposit() external {
    // Make partial deposit
    token.mint(alice, DEPOSIT_AMOUNT / 2);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT / 2);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT / 2);
    vm.stopPrank();

    // Get financial summary
    SavingCirclesViewer.UserFinancialSummary memory summary = savingCirclesViewer.getUserFinancialSummary(alice);

    // Verify upcoming deposits count
    assertEq(summary.upcomingDeposits, 1);
    assertEq(summary.totalDeposited, DEPOSIT_AMOUNT / 2);
  }

  function test_DecommissionableCirclesIncludedInUserData() external {
    // Warp beyond the first deposit window without all deposits completed
    vm.warp(baseCircleStart + DEPOSIT_INTERVAL + 1);

    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(alice);

    assertTrue(userData.circleData[0].isDecommissionable);
    assertEq(userData.membershipStatus.decommissionableCircleIds.length, 1);
    assertEq(userData.membershipStatus.decommissionableCircleIds[0], baseCircleId);
  }

  function test_GetComprehensiveUserDataHandlesDecommissionedCircle() external {
    vm.warp(baseCircleStart + DEPOSIT_INTERVAL + 1);
    vm.prank(alice);
    savingCircles.decommission(baseCircleId);

    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(bob);

    assertEq(userData.membershipStatus.allCircleIds.length, 1);
    assertEq(userData.membershipStatus.decommissionedCircleIds.length, 1);
    assertEq(userData.membershipStatus.decommissionedCircleIds[0], baseCircleId);

    assertEq(userData.circleData.length, 1);
    assertTrue(userData.circleData[0].isDecommissioned);

    assertEq(userData.financialSummary.totalBalance, 0);
    assertEq(userData.financialSummary.activeCirclesCount, 0);
    assertEq(userData.financialSummary.completedCirclesCount, 1);
  }

  function test_GetCirclesStateHandlesDecommissionedCircle() external {
    vm.warp(baseCircleStart + DEPOSIT_INTERVAL + 1);
    vm.prank(alice);
    savingCircles.decommission(baseCircleId);

    uint256[] memory ids = new uint256[](1);
    ids[0] = baseCircleId;

    ISavingCirclesViewer.CircleState[] memory states = savingCirclesViewer.getCirclesState(ids);

    assertEq(states.length, 1);
    assertEq(states[0].circleId, baseCircleId);
    assertEq(uint256(states[0].circleState), uint256(ISavingCircles.CircleState.Decommissioned));
    assertEq(uint256(states[0].roundState), uint256(ISavingCircles.RoundState.NotStarted));
  }
}
