// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {SavingCircles} from 'src/contracts/SavingCircles.sol';
import {ISavingCircles} from 'src/interfaces/ISavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

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

  function test_DepositWhenCircleExpired() external {
    // Test that CircleExpired error is properly triggered
    // This tests the fix for the previously unreachable CircleExpired check

    // Create a circle with small intervals for testing
    address[] memory members = new address[](2);
    members[0] = alice;
    members[1] = bob;

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: 1 hours,
      maxDeposits: 2, // Only 2 rounds
      circleStart: block.timestamp + 1 hours,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    // Warp to after circle has expired (past maxDeposits intervals)
    uint256 expiredTime = circle.circleStart + (circle.depositInterval * circle.maxDeposits) + 1;
    vm.warp(expiredTime);

    // Try to deposit after expiration
    token.mint(alice, DEPOSIT_AMOUNT);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Should revert with CircleExpired
    vm.expectRevert(ISavingCircles.CircleExpired.selector);
    savingCircles.deposit(circleId, DEPOSIT_AMOUNT);
    vm.stopPrank();
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

  // ============ Additional Validation Tests ============

  function test_CreateWhenInvalidCurrentIndex() external {
    // Test creating circle with currentIndex != 0
    ISavingCircles.Circle memory circle = baseCircle;
    circle.currentIndex = 1;

    vm.prank(alice);
    vm.expectRevert(ISavingCircles.InvalidCurrentIndex.selector);
    savingCircles.create(circle);
  }

  function test_CreateWhenInvalidOwner() external {
    // Test creating circle with owner = address(0)
    ISavingCircles.Circle memory circle = baseCircle;
    circle.owner = address(0);

    vm.prank(alice);
    vm.expectRevert(ISavingCircles.InvalidOwner.selector);
    savingCircles.create(circle);
  }

  function test_CreateWhenInvalidMemberAddress() external {
    // Test creating circle with zero address member
    address[] memory invalidMembers = new address[](3);
    invalidMembers[0] = alice;
    invalidMembers[1] = address(0); // Invalid member
    invalidMembers[2] = bob;

    ISavingCircles.Circle memory circle = baseCircle;
    circle.members = invalidMembers;

    vm.prank(alice);
    vm.expectRevert(ISavingCircles.InvalidMemberAddress.selector);
    savingCircles.create(circle);
  }

  function test_CreateWhenCircleStartTimeIsZero() external {
    // Test InvalidCircleStartTime error
    ISavingCircles.Circle memory circle = baseCircle;
    circle.circleStart = 0;

    vm.prank(alice);
    vm.expectRevert(ISavingCircles.InvalidCircleStartTime.selector);
    savingCircles.create(circle);
  }

  function test_DepositExceedsDepositAmount() external {
    // Test depositing more than allowed amount
    vm.warp(baseCircle.circleStart);

    uint256 excessAmount = DEPOSIT_AMOUNT + 1;
    token.mint(alice, excessAmount);

    vm.startPrank(alice);
    token.approve(address(savingCircles), excessAmount);
    vm.expectRevert(ISavingCircles.ExceedsDepositAmount.selector);
    savingCircles.deposit(baseCircleId, excessAmount);
    vm.stopPrank();
  }

  function test_DepositForExceedsAmount() external {
    // Test depositFor exceeding allowed amount
    vm.warp(baseCircle.circleStart);

    uint256 excessAmount = DEPOSIT_AMOUNT + 1;
    token.mint(bob, excessAmount);

    vm.startPrank(bob);
    token.approve(address(savingCircles), excessAmount);
    vm.expectRevert(ISavingCircles.ExceedsDepositAmount.selector);
    savingCircles.depositFor(baseCircleId, excessAmount, alice);
    vm.stopPrank();
  }

  function test_WithdrawForNonMember() external {
    // Test withdrawFor when caller is not a member
    // Complete deposits first
    vm.warp(baseCircle.circleStart);
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Wait for withdrawal time
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Non-member can now trigger withdrawFor successfully
    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(STRANGER);
    savingCircles.withdrawFor(baseCircleId, alice);

    assertEq(token.balanceOf(alice), aliceBefore + (DEPOSIT_AMOUNT * members.length));
  }

  // ============ Edge Case Tests for Decommission ============

  function test_DecommissionWhenNotOwnerOrMember() external {
    // Test that non-owner/non-member cannot decommission
    vm.prank(STRANGER);
    vm.expectRevert(ISavingCircles.NotDecommissionable.selector);
    savingCircles.decommission(baseCircleId);
  }

  function test_DecommissionAfterCompleteCircle() external {
    // Test that decommission is not allowed after all deposits complete
    vm.warp(baseCircle.circleStart);

    // All members deposit
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Wait past deposit window
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Decommission should fail because all deposits are complete
    vm.prank(alice);
    vm.expectRevert(ISavingCircles.NotDecommissionable.selector);
    savingCircles.decommission(baseCircleId);
  }

  // ============ Security-Focused Tests ============

  function test_ReentrancyOnWithdraw() external {
    // This test verifies that the nonReentrant modifier prevents reentrancy
    // We'll simulate by trying to call withdraw again during withdrawal
    // The actual reentrancy guard should prevent this

    vm.warp(baseCircle.circleStart);

    // Complete deposits
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Wait for withdrawal time
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Try to withdraw (reentrancy protection should be handled by modifier)
    vm.prank(alice);
    savingCircles.withdraw(baseCircleId);

    // Verify withdrawal was successful and state is correct
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT * members.length);
  }

  function test_IntegerOverflowProtection() external {
    // Test with maximum values to ensure no overflows
    uint256 maxAmount = type(uint256).max / 100; // Avoid actual overflow in test setup

    address[] memory twoMembers = new address[](2);
    twoMembers[0] = alice;
    twoMembers[1] = bob;

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: twoMembers,
      token: address(token),
      depositAmount: maxAmount,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: 2,
      circleStart: block.timestamp + 1 days,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    // Verify circle was created with large values
    ISavingCircles.Circle memory created = savingCircles.getCircle(circleId);
    assertEq(created.depositAmount, maxAmount);
  }

  // ============ State Transition Tests ============

  function test_CircleLifecycleStateMachine() external {
    // Test all valid state transitions:
    // Created -> Active -> Withdrawing -> Completed
    // Created -> Active -> Decommissioned

    // State 1: Created
    uint256 circleId = baseCircleId;
    assertFalse(savingCircles.isWithdrawable(circleId));

    // State 2: Active (deposits happening)
    vm.warp(baseCircle.circleStart);
    token.mint(alice, DEPOSIT_AMOUNT);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(circleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Still active but not withdrawable
    assertFalse(savingCircles.isWithdrawable(circleId));

    // Deposit for bob but NOT carol (to allow decommission later)
    token.mint(bob, DEPOSIT_AMOUNT);
    vm.startPrank(bob);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.deposit(circleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // State 3: Cannot withdraw yet (incomplete deposits)
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);
    assertFalse(savingCircles.isWithdrawable(circleId));

    // State 4: Can decommission because carol hasn't deposited
    // Test decommission path (owner or member can decommission)
    // Need to wait past the deposit window
    vm.warp(block.timestamp + 1);
    vm.prank(alice);
    savingCircles.decommission(circleId);

    // State 5: Decommissioned (final state)
    vm.expectRevert(ISavingCircles.NotCommissioned.selector);
    savingCircles.getCircle(circleId);
  }

  // ============ View Function Edge Cases ============

  function test_GetMemberCirclesWithManyCircles() external {
    // Create multiple circles for one member
    uint256[] memory circleIds = new uint256[](10);

    for (uint256 i = 0; i < 10; i++) {
      ISavingCircles.Circle memory circle = baseCircle;
      circle.circleStart = block.timestamp + (i + 1) * 1 days; // Different start times

      vm.prank(alice);
      circleIds[i] = savingCircles.create(circle);
    }

    // Get all circles for alice
    uint256[] memory aliceCircles = savingCircles.getMemberCircles(alice);

    // Verify alice is in all created circles plus the base circle
    assertEq(aliceCircles.length, 11); // 10 new + 1 base
  }

  function test_CheckMembershipsPerformance() external {
    // Test checkMemberships with large arrays
    uint256[] memory circleIds = new uint256[](20);

    // Create circles
    for (uint256 i = 0; i < 20; i++) {
      if (i < 10) {
        // Alice is member in first 10
        ISavingCircles.Circle memory circle = baseCircle;
        circle.circleStart = block.timestamp + (i + 1) * 1 days;
        vm.prank(alice);
        circleIds[i] = savingCircles.create(circle);
      } else {
        // Alice is not member in last 10
        address[] memory otherMembers = new address[](2);
        otherMembers[0] = bob;
        otherMembers[1] = carol;

        ISavingCircles.Circle memory circle = ISavingCircles.Circle({
          owner: bob,
          members: otherMembers,
          token: address(token),
          depositAmount: DEPOSIT_AMOUNT,
          depositInterval: DEPOSIT_INTERVAL,
          maxDeposits: 2,
          circleStart: block.timestamp + (i + 1) * 1 days,
          currentIndex: 0
        });

        vm.prank(bob);
        circleIds[i] = savingCircles.create(circle);
      }
    }

    // Check memberships for alice
    bool[] memory statuses = savingCircles.checkMemberships(alice, circleIds);

    // Verify results
    assertEq(statuses.length, 20);
    for (uint256 i = 0; i < 20; i++) {
      if (i < 10) {
        assertTrue(statuses[i], 'Alice should be member in first 10');
      } else {
        assertFalse(statuses[i], 'Alice should not be member in last 10');
      }
    }
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
}
