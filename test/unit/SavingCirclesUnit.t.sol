// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {MockERC20} from '../mocks/MockERC20.sol';
import {ISavingCircles, SavingCircles} from 'contracts/SavingCircles.sol';

contract SavingCirclesUnit is Test {
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;
  uint256 public constant CIRCLE_DURATION = 30 days;
  uint256 public constant MAX_DEPOSITS = 1000;

  SavingCircles public savingCircles;
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

    // Deploy and initialize the contract
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

    // Setup test data
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    // Setup savingcircles parameters
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

  function test_SetTokenAllowedWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    savingCircles.setTokenAllowed(address(0x1), true);
  }

  function test_SetTokenAllowedWhenCallerIsOwner() external {
    address newToken = makeAddr('newToken');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.TokenAllowed(newToken, true);
    savingCircles.setTokenAllowed(newToken, true);

    assertTrue(savingCircles.isTokenAllowed(newToken));
  }

  function test_SetTokenNotAllowedWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    savingCircles.setTokenAllowed(address(token), false);
  }

  function test_SetTokenNotAllowedWhenCallerIsOwner() external {
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.TokenAllowed(address(token), false);
    savingCircles.setTokenAllowed(address(token), false);

    assertFalse(savingCircles.isTokenAllowed(address(token)));
  }

  function test_DepositWhenCircleDoesNotExist() external {
    uint256 nonExistentCircleId = uint256(keccak256(abi.encodePacked('Non Existent Circle')));

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.deposit(nonExistentCircleId, DEPOSIT_AMOUNT);
  }

  function test_DepositWhenMemberHasAlreadyDeposited() external {
    // Mint tokens to alice for deposit
    token.mint(alice, DEPOSIT_AMOUNT * 2);

    // Mock token approval
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT * 2);

    // First deposit
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Second deposit attempt should fail since member has already deposited max amount
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.ExceedsDepositAmount.selector));
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();
  }

  function test_DepositWhenParametersAreValid() external {
    vm.startPrank(alice);

    // Mock token transfer
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    // Expect deposit event
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);

    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Verify deposit was recorded
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);

    vm.stopPrank();
  }

  function test_DepositWhenDepositPeriodHasPassed() external {
    // Move time past deposit period
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.DepositWindowClosed.selector));
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
  }

  function test_WithdrawWhenCircleDoesNotExist() external {
    uint256 nonExistentCircleId = uint256(keccak256(abi.encodePacked('Non Existent Circle')));

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.isWithdrawable(nonExistentCircleId);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    savingCircles.withdraw(nonExistentCircleId);
  }

  function test_WithdrawWhenUserIsNotACircleMember() external {
    address nonMember = makeAddr('nonMember');

    vm.prank(nonMember);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    savingCircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenPayoutRoundHasNotEnded() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotWithdrawable.selector));
    savingCircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenUserHasAlreadyClaimed() external {
    // Complete deposits
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    vm.startPrank(alice);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Move time past round
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Mock token transfer for withdrawal
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

    // First withdrawal
    vm.prank(alice);
    savingCircles.withdraw(baseCircleId);

    // Second withdrawal attempt should fail since currentIndex has moved to next member
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotWithdrawable.selector));
    savingCircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenParametersAreValid() external {
    // Complete deposits from all members
    vm.startPrank(alice);
    token.mint(alice, DEPOSIT_AMOUNT);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    token.mint(carol, DEPOSIT_AMOUNT);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Move time past first round
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Mint tokens to contract to enable withdrawal
    uint256 withdrawAmount = DEPOSIT_AMOUNT * members.length;

    // First member (alice) should be able to withdraw
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsWithdrawn(baseCircleId, alice, withdrawAmount);
    savingCircles.withdraw(baseCircleId);

    // Verify alice received the tokens
    assertEq(token.balanceOf(alice), withdrawAmount);

    // Verify all member balances were reset
    (, uint256[] memory balances) = savingCircles.getMemberBalances(baseCircleId);
    for (uint256 i = 0; i < balances.length; i++) {
      assertEq(balances[i], 0);
    }

    // Verify current index moved to next member
    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    assertEq(circle.currentIndex, 1);
  }

  function test_WithdrawForWhenParametersAreValid() external {
    // Complete deposits from all members
    vm.startPrank(alice);
    token.mint(alice, DEPOSIT_AMOUNT);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    token.mint(carol, DEPOSIT_AMOUNT);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Move time past first round
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    uint256 withdrawAmount = DEPOSIT_AMOUNT * members.length;

    // Bob should be able to withdraw for Alice (who is first in line)
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsWithdrawn(baseCircleId, alice, withdrawAmount);
    savingCircles.withdrawFor(baseCircleId, alice);

    // Verify alice received the tokens
    assertEq(token.balanceOf(alice), withdrawAmount);

    // Verify all member balances were reset
    (, uint256[] memory balances) = savingCircles.getMemberBalances(baseCircleId);
    for (uint256 i = 0; i < balances.length; i++) {
      assertEq(balances[i], 0);
    }

    // Verify current index moved to next member
    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);
    assertEq(circle.currentIndex, 1);
  }

  function test_CircleInfoWhenCircleDoesNotExist() external {
    uint256 nonExistentCircleId = uint256(keccak256(abi.encodePacked('Non Existent Circle')));

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.getCircle(nonExistentCircleId);
  }

  function test_CircleInfoWhenCircleAlreadyExists() external {
    ISavingCircles.Circle memory _circle = savingCircles.getCircle(baseCircleId);

    // Verify all circle properties match expected values
    assertEq(_circle.owner, owner);
    assertEq(_circle.currentIndex, BASE_CURRENT_INDEX);
    assertEq(_circle.circleStart, block.timestamp);
    assertEq(_circle.token, address(token));
    assertEq(_circle.depositAmount, DEPOSIT_AMOUNT);
    assertEq(_circle.depositInterval, DEPOSIT_INTERVAL);
    assertEq(_circle.maxDeposits, MAX_DEPOSITS);

    // Verify members array
    assertEq(_circle.members.length, members.length);
    for (uint256 i = 0; i < members.length; i++) {
      assertEq(_circle.members[i], members[i]);
    }

    // Verify initial balances are zero
    (, uint256[] memory balances) = savingCircles.getMemberBalances(baseCircleId);
    for (uint256 i = 0; i < balances.length; i++) {
      assertEq(balances[i], 0);
    }
  }

  function test_DecommissionWhenOwner() external {
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.CircleDecommissioned(baseCircleId);
    savingCircles.decommission(baseCircleId);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.getCircle(baseCircleId);
  }

  function test_DecommissionWhenMemberAndIncompleteDeposits() external {
    // Have alice deposit but not bob or carol
    token.mint(alice, DEPOSIT_AMOUNT);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Warp past deposit interval
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Member should be able to decommission since not all deposits were made
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.CircleDecommissioned(baseCircleId);
    savingCircles.decommission(baseCircleId);

    // Verify circle was deleted
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.getCircle(baseCircleId);

    // Verify alice got her deposit back
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT);
  }

  function test_CreateWhenTokenIsNotWhitelisted() external {
    address _notAllowedToken = makeAddr('notAllowedToken');

    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.token = _notAllowedToken;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.TokenNotAllowed.selector));
    savingCircles.create(_invalidCircle);
  }

  function test_CreateWhenIntervalIsZero() external {
    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.depositInterval = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidDepositInterval.selector));
    savingCircles.create(_invalidCircle);
  }

  function test_CreateWhenDepositAmountIsZero() external {
    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.depositAmount = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidDepositAmount.selector));
    savingCircles.create(_invalidCircle);
  }

  function test_CreateWhenMembersCountIsLessThanTwo() external {
    address[] memory _oneMember = new address[](1);
    _oneMember[0] = alice;

    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.members = _oneMember;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidMemberCount.selector));
    savingCircles.create(_invalidCircle);
  }

  function test_GetCircles() external {
    // Create a second circle
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = carol;
    vm.prank(carol);
    uint256 secondCircleId = savingCircles.create(secondCircle);

    // Create array of circle IDs to fetch
    uint256[] memory circleIds = new uint256[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = secondCircleId;

    // Get circles
    ISavingCircles.Circle[] memory circles = savingCircles.getCircles(circleIds);

    // Verify first circle
    assertEq(circles[0].owner, baseCircle.owner);
    assertEq(circles[0].members.length, baseCircle.members.length);
    assertEq(circles[0].currentIndex, baseCircle.currentIndex);
    assertEq(circles[0].circleStart, baseCircle.circleStart);
    assertEq(circles[0].token, baseCircle.token);
    assertEq(circles[0].depositAmount, baseCircle.depositAmount);
    assertEq(circles[0].depositInterval, baseCircle.depositInterval);
    assertEq(circles[0].maxDeposits, baseCircle.maxDeposits);

    // Verify second circle
    assertEq(circles[1].owner, secondCircle.owner);
    assertEq(circles[1].members.length, secondCircle.members.length);
    assertEq(circles[1].currentIndex, secondCircle.currentIndex);
    assertEq(circles[1].circleStart, secondCircle.circleStart);
    assertEq(circles[1].token, secondCircle.token);
    assertEq(circles[1].depositAmount, secondCircle.depositAmount);
    assertEq(circles[1].depositInterval, secondCircle.depositInterval);
    assertEq(circles[1].maxDeposits, secondCircle.maxDeposits);
  }

  function test_GetCirclesWhenCircleDoesNotExist() external {
    // Create array with non-existent circle ID
    uint256[] memory circleIds = new uint256[](1);
    circleIds[0] = 999;

    // Get circles
    ISavingCircles.Circle[] memory circles = savingCircles.getCircles(circleIds);

    // Verify returned circle is empty (owner address is 0)
    assertEq(circles[0].owner, address(0));
  }

  function test_GetMemberCircles() external {
    // Create a second circle that alice is also a member of
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = carol;
    vm.prank(carol);
    uint256 secondCircleId = savingCircles.create(secondCircle);

    // Get alice's circles
    uint256[] memory aliceCircles = savingCircles.getMemberCircles(alice);

    // Verify alice is in both circles
    assertEq(aliceCircles.length, 2);
    assertEq(aliceCircles[0], baseCircleId);
    assertEq(aliceCircles[1], secondCircleId);

    // Get bob's circles
    uint256[] memory bobCircles = savingCircles.getMemberCircles(bob);

    // Verify bob is in both circles
    assertEq(bobCircles.length, 2);
    assertEq(bobCircles[0], baseCircleId);
    assertEq(bobCircles[1], secondCircleId);

    // Get stranger's circles
    uint256[] memory strangerCircles = savingCircles.getMemberCircles(STRANGER);

    // Verify stranger is in no circles
    assertEq(strangerCircles.length, 0);
  }

  function test_CheckMemberships() external {
    // Create a second circle that alice is also a member of
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = carol;
    vm.prank(carol);
    uint256 secondCircleId = savingCircles.create(secondCircle);

    // Create array of circle IDs to check
    uint256[] memory circleIds = new uint256[](3);
    circleIds[0] = baseCircleId;
    circleIds[1] = secondCircleId;
    circleIds[2] = 999; // Non-existent circle

    // Check memberships for alice who is in both circles
    bool[] memory aliceStatuses = savingCircles.checkMemberships(alice, circleIds);
    assertEq(aliceStatuses.length, 3);
    assertTrue(aliceStatuses[0]); // In baseCircle
    assertTrue(aliceStatuses[1]); // In secondCircle
    assertFalse(aliceStatuses[2]); // Not in non-existent circle

    // Check memberships for stranger who is in no circles
    bool[] memory strangerStatuses = savingCircles.checkMemberships(STRANGER, circleIds);
    assertEq(strangerStatuses.length, 3);
    assertFalse(strangerStatuses[0]); // Not in baseCircle
    assertFalse(strangerStatuses[1]); // Not in secondCircle
    assertFalse(strangerStatuses[2]); // Not in non-existent circle
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

    uint256 totalBalance = savingCircles.getTotalBalance(alice);
    assertEq(totalBalance, expectedTotal, 'Total balance mismatch');
  }

  /**
   * @notice Ensures getTotalBalance returns zero when member has no balances
   */
  function test_GetTotalBalanceWhenNoDeposits() external {
    uint256 totalBalance = savingCircles.getTotalBalance(STRANGER);
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
    SavingCircles.ComprehensiveUserData memory userData = savingCircles.getComprehensiveUserData(alice);

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
    SavingCircles.ComprehensiveUserData memory userData = savingCircles.getComprehensiveUserData(owner);

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
    SavingCircles.ComprehensiveUserData memory userData = savingCircles.getComprehensiveUserData(alice);

    // Verify withdrawal status
    assertEq(userData.financialSummary.pendingWithdrawals, 1);
    assertTrue(userData.circleData[0].canWithdraw);
    assertTrue(userData.circleData[0].isCurrentWithdrawer);
    assertEq(userData.membershipStatus.withdrawableCircleIds.length, 1);
    assertEq(userData.membershipStatus.withdrawableCircleIds[0], baseCircleId);
  }

  function test_GetComprehensiveUserDataForNonMember() external {
    // Get comprehensive data for a non-member
    SavingCircles.ComprehensiveUserData memory userData = savingCircles.getComprehensiveUserData(STRANGER);

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
    SavingCircles.UserFinancialSummary memory summary = savingCircles.getUserFinancialSummary(alice);

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
    SavingCircles.UserFinancialSummary memory summary = savingCircles.getUserFinancialSummary(alice);

    // Verify upcoming deposits count
    assertEq(summary.upcomingDeposits, 1);
    assertEq(summary.totalDeposited, DEPOSIT_AMOUNT / 2);
  }
}
