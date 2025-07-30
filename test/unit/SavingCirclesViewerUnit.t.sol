// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

import {SavingCircles} from 'src/contracts/SavingCircles.sol';
import {SavingCirclesViewer} from 'src/contracts/SavingCirclesViewer.sol';
import {ISavingCircles} from 'src/interfaces/ISavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

contract SavingCirclesViewerUnit is Test {
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

  // Test data
  uint256 public baseCircleId;
  address[] public members;
  ISavingCircles.Circle public baseCircle;

  function setUp() external {
    // Setup test addresses
    owner = makeAddr('owner');
    alice = makeAddr('alice');
    bob = makeAddr('bob');
    carol = makeAddr('carol');

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
    baseCircle = ISavingCircles.Circle({
      owner: owner,
      members: members,
      currentIndex: BASE_CURRENT_INDEX,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: MAX_DEPOSITS
    });

    // Create an initial test circle
    vm.prank(alice);
    baseCircleId = savingCircles.create(baseCircle);
  }

  /**
   * @notice Ensures getTotalBalance sums a member's balances across multiple circles
   */
  function test_GetTotalBalanceAggregatesAcrossCircles() external {
    // Create a second circle with the same parameters but a different owner
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = bob;
    vm.prank(bob);
    uint256 secondCircleId = savingCircles.create(secondCircle);

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
    vm.prank(bob);
    uint256 secondCircleId = savingCircles.create(secondCircle);

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
    assertEq(userData.financialSummary.ownedCirclesCount, 0);
    assertEq(userData.financialSummary.pendingWithdrawals, 0);
    assertEq(userData.financialSummary.upcomingDeposits, 1);

    // Verify membership status
    assertEq(userData.membershipStatus.allCircleIds.length, 2);
    assertEq(userData.membershipStatus.allCircleIds[0], baseCircleId);
    assertEq(userData.membershipStatus.allCircleIds[1], secondCircleId);
    assertEq(userData.membershipStatus.activeCircleIds.length, 2);
    assertEq(userData.membershipStatus.ownedCircleIds.length, 0);

    // Verify circle data
    assertEq(userData.circleData.length, 2);

    // First circle data
    assertEq(userData.circleData[0].circleId, baseCircleId);
    assertEq(userData.circleData[0].userBalance, DEPOSIT_AMOUNT);
    assertTrue(userData.circleData[0].isMember);
    assertFalse(userData.circleData[0].isOwner);
    assertTrue(userData.circleData[0].isCurrentWithdrawer);
    assertFalse(userData.circleData[0].canWithdraw);
    assertEq(userData.circleData[0].completedRounds, 0);
    assertEq(userData.circleData[0].totalRounds, MAX_DEPOSITS);

    // Second circle data
    assertEq(userData.circleData[1].circleId, secondCircleId);
    assertEq(userData.circleData[1].userBalance, DEPOSIT_AMOUNT / 2);
    assertTrue(userData.circleData[1].isMember);
    assertFalse(userData.circleData[1].isOwner);
    assertTrue(userData.circleData[1].isCurrentWithdrawer);
    assertFalse(userData.circleData[1].canWithdraw);
  }

  function test_GetComprehensiveUserDataForCircleOwner() external {
    // Get comprehensive data for the circle owner
    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(owner);

    // Verify financial summary shows ownership
    assertEq(userData.financialSummary.ownedCirclesCount, 1);
    assertEq(userData.financialSummary.activeCirclesCount, 1);

    // Verify membership status
    assertEq(userData.membershipStatus.ownedCircleIds.length, 1);
    assertEq(userData.membershipStatus.ownedCircleIds[0], baseCircleId);

    // Verify circle data shows ownership
    assertTrue(userData.circleData[0].isOwner);
    assertFalse(userData.circleData[0].isMember);
    assertFalse(userData.circleData[0].isCurrentWithdrawer);
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

    // Move time past first round to enable withdrawal
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Get comprehensive user data for alice (first withdrawer)
    SavingCirclesViewer.ComprehensiveUserData memory userData = savingCirclesViewer.getComprehensiveUserData(alice);

    // Verify withdrawal status
    assertEq(userData.financialSummary.pendingWithdrawals, 1);
    assertTrue(userData.circleData[0].canWithdraw);
    assertTrue(userData.circleData[0].isCurrentWithdrawer);
    assertEq(userData.membershipStatus.withdrawableCircleIds.length, 1);
    assertEq(userData.membershipStatus.withdrawableCircleIds[0], baseCircleId);
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
    vm.prank(bob);
    uint256 secondCircleId = savingCircles.create(secondCircle);

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
}
