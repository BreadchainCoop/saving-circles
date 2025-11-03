// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';

import {ISavingCircles} from 'interfaces/ISavingCircles.sol';
import {IntegrationBase} from 'test/integration/IntegrationBase.sol';

contract SavingCirclesIntegration is IntegrationBase {
  function setUp() public override {
    super.setUp();
  }

  function test_SetTokenAllowed() public {
    // Check initial state
    assertFalse(circle.isTokenAllowed(address(token)));

    // Test enabling token
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);
    assertTrue(circle.isTokenAllowed(address(token)));

    // Test disabling token
    vm.prank(owner);
    circle.setTokenAllowed(address(token), false);
    assertFalse(circle.isTokenAllowed(address(token)));

    // Test enabling multiple tokens
    address newToken = makeAddr('newToken');
    vm.startPrank(owner);
    circle.setTokenAllowed(address(token), true);
    circle.setTokenAllowed(newToken, true);
    vm.stopPrank();

    assertTrue(circle.isTokenAllowed(address(token)));
    assertTrue(circle.isTokenAllowed(newToken));

    // Test emitted events
    vm.prank(owner);
    vm.expectEmit(true, true, false, true);
    emit ISavingCircles.TokenAllowed(address(token), false);
    circle.setTokenAllowed(address(token), false);
  }

  function test_RevertWhen_NonOwnerAllowlistsToken() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob));
    circle.setTokenAllowed(address(token), true);
  }

  function test_RevertWhen_CreatingCircleWithUnallowlistedToken() public {
    address badToken = makeAddr('badToken');
    baseCircle.token = badToken;
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.TokenNotAllowed.selector));
    circle.create(baseCircle);
  }

  function test_Deposit() public {
    createBaseCircle();

    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    (, uint256[] memory balances) = circle.getMemberBalances(baseCircleId);
    assertEq(balances[0], DEPOSIT_AMOUNT);
  }

  function test_DepositFor() public {
    createBaseCircle();

    // Bob deposits for Alice
    vm.prank(bob);
    circle.depositFor(baseCircleId, DEPOSIT_AMOUNT, alice);

    (, uint256[] memory balances) = circle.getMemberBalances(baseCircleId);
    assertEq(balances[0], DEPOSIT_AMOUNT);
  }

  function test_WithdrawWithInterval() public {
    createBaseCircle();

    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.prank(carol);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // First member withdraws
    uint256 balanceBefore = token.balanceOf(alice);
    vm.prank(alice);
    circle.withdraw(baseCircleId);
    uint256 balanceAfter = token.balanceOf(alice);

    // Alice should receive DEPOSIT_AMOUNT * 3 (from Bob and Carol)
    assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT * 3);

    // Try to withdraw before interval
    vm.prank(bob);
    vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
    circle.withdraw(baseCircleId);

    // Wait for interval (need to wait for index 1's interval)
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);
    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.prank(bob);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.prank(carol);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Bob should be able to withdraw
    vm.prank(bob);
    circle.withdraw(baseCircleId);
  }

  function test_WithdrawForWithInterval() public {
    createBaseCircle();

    // Initial deposits from all members
    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.prank(carol);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Bob tries to withdraw for Alice (who is first in line)
    uint256 balanceBefore = token.balanceOf(alice);
    vm.prank(bob);
    circle.withdrawFor(baseCircleId, alice);
    uint256 balanceAfter = token.balanceOf(alice);

    // Alice should receive DEPOSIT_AMOUNT * 3 (from all members)
    assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT * 3);

    // Try to withdraw for Bob before interval
    vm.prank(alice);
    vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
    circle.withdrawFor(baseCircleId, bob);

    // Wait for interval (need to wait for index 1's interval)
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // New round of deposits
    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.prank(bob);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.prank(carol);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Alice withdraws for Bob (who is now next in line)
    balanceBefore = token.balanceOf(bob);
    vm.prank(alice);
    circle.withdrawFor(baseCircleId, bob);
    balanceAfter = token.balanceOf(bob);

    // Bob should receive DEPOSIT_AMOUNT * 3
    assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT * 3);
  }

  function test_DecommissionCircle() public {
    createBaseCircle();

    // Members deposit
    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Get initial balances
    uint256 aliceBalanceBefore = token.balanceOf(alice);
    uint256 bobBalanceBefore = token.balanceOf(bob);

    // Wait until after deposit interval
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Decommission circle
    vm.prank(alice);
    circle.decommission(baseCircleId);

    // Check balances returned
    assertEq(token.balanceOf(alice) - aliceBalanceBefore, DEPOSIT_AMOUNT);
    assertEq(token.balanceOf(bob) - bobBalanceBefore, DEPOSIT_AMOUNT);

    // Check circle deleted
    vm.expectRevert(ISavingCircles.NotCommissioned.selector);
    circle.getCircle(baseCircleId);
  }

  function test_MemberDecommissionWhenIncompleteDeposits() public {
    createBaseCircle();

    // Only Alice deposits
    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Get initial balance
    uint256 aliceBalanceBefore = token.balanceOf(alice);

    // Wait until after deposit interval
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Alice should be able to decommission since not all members deposited
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.CircleDecommissioned(baseCircleId);
    circle.decommission(baseCircleId);

    // Check Alice got her deposit back
    assertEq(token.balanceOf(alice) - aliceBalanceBefore, DEPOSIT_AMOUNT);

    // Check circle was deleted
    vm.expectRevert(ISavingCircles.NotCommissioned.selector);
    circle.getCircle(baseCircleId);
  }

  function test_RevertWhen_NotEnoughContributions() public {
    createBaseCircle();

    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.prank(alice);
    vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
    circle.withdraw(baseCircleId);
  }

  // // Withdraw function branching tests
  // function test_WithdrawBranchingTree() public {
  //     // Branch 1: Circle doesn't exist
  //     bytes32 nonExistentCircle = keccak256(abi.encodePacked("Non Existent"));
  //     vm.prank(alice);
  //     vm.expectRevert(ISavingCircles.NotCommissioned.selector);
  //     circle.withdraw(nonExistentCircle);

  //     // Setup circle for remaining tests
  //     address[] memory members = new address[](3);
  //     members[0] = alice;
  //     members[1] = bob;
  //     members[2] = carol;

  //     vm.prank(alice);
  //     circle.create("Test Circle", members, address(token), DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);
  //     bytes32 hashedName = keccak256(abi.encodePacked("Test Circle"));

  //     // Branch 2: Not enough time passed
  //     vm.prank(alice);
  //     vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
  //     circle.withdraw(hashedName);

  //     // Branch 3: Not all members contributed
  //     vm.prank(alice);
  //     circle.deposit(hashedName, DEPOSIT_AMOUNT);
  //     vm.prank(bob);
  //     circle.deposit(hashedName, DEPOSIT_AMOUNT);
  //     // Carol hasn't contributed
  //     vm.prank(alice);
  //     vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
  //     circle.withdraw(hashedName);

  //     // Branch 4: Wrong member trying to withdraw
  //     vm.prank(carol);
  //     circle.deposit(hashedName, DEPOSIT_AMOUNT);
  //     vm.prank(bob);
  //     vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
  //     circle.withdraw(hashedName);

  //     // Branch 5: Successful withdrawal
  //     vm.prank(alice);
  //     circle.withdraw(hashedName);

  //     // Branch 6: Second withdrawal before interval
  //     vm.prank(bob);
  //     vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
  //     circle.withdraw(hashedName);

  //     // Branch 7: Second withdrawal after interval
  //     vm.warp(block.timestamp + DEPOSIT_INTERVAL);
  //     vm.prank(bob);
  //     circle.withdraw(hashedName);

  //     // Branch 8: Full circle completion
  //     vm.warp(block.timestamp + DEPOSIT_INTERVAL);
  //     vm.prank(carol);
  //     circle.withdraw(hashedName);

  //     // Branch 9: Circle wraps around
  //     vm.warp(block.timestamp + DEPOSIT_INTERVAL);
  //     vm.prank(alice);
  //     vm.expectRevert(ISavingCircles.NotWithdrawable.selector); // Should fail as no new deposits made
  //     circle.withdraw(hashedName);
  // }

  // ============ Complex Scenario Integration Tests ============

  function test_MultipleCirclesWithOverlappingMembers() external {
    // Test members participating in multiple circles simultaneously
    // Verify balance tracking and withdrawal rights

    // First allow the token
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    address[] memory sharedMembers = new address[](3);
    sharedMembers[0] = alice;
    sharedMembers[1] = bob;
    sharedMembers[2] = carol;

    // Create first circle with alice, bob, carol
    ISavingCircles.Circle memory circle1 = ISavingCircles.Circle({
      owner: alice,
      members: sharedMembers,
      token: address(token),
      depositAmount: 1 ether,
      depositInterval: 1 days,
      circleStart: block.timestamp + 1 hours,
      currentIndex: 0
    });

    // Create second circle with alice, bob, and a new member
    address dave = makeAddr('dave');
    address[] memory mixedMembers = new address[](3);
    mixedMembers[0] = alice;
    mixedMembers[1] = bob;
    mixedMembers[2] = dave;

    ISavingCircles.Circle memory circle2 = ISavingCircles.Circle({
      owner: bob,
      members: mixedMembers,
      token: address(token),
      depositAmount: 2 ether,
      depositInterval: 2 days,
      circleStart: block.timestamp + 2 hours,
      currentIndex: 0
    });

    // Create circles
    vm.prank(alice);
    uint256 circleId1 = circle.create(circle1);

    vm.prank(bob);
    uint256 circleId2 = circle.create(circle2);

    // Verify members are in correct circles
    assertTrue(circle.isMember(circleId1, alice));
    assertTrue(circle.isMember(circleId1, bob));
    assertTrue(circle.isMember(circleId1, carol));
    assertFalse(circle.isMember(circleId1, dave));

    assertTrue(circle.isMember(circleId2, alice));
    assertTrue(circle.isMember(circleId2, bob));
    assertFalse(circle.isMember(circleId2, carol));
    assertTrue(circle.isMember(circleId2, dave));

    // Test deposits in both circles
    // Get actual circle start times
    ISavingCircles.Circle memory c1 = circle.getCircle(circleId1);
    ISavingCircles.Circle memory c2 = circle.getCircle(circleId2);

    // Warp to circle 1 start time
    vm.warp(c1.circleStart);

    // Alice deposits in circle 1
    deal(address(token), alice, 3 ether);
    vm.startPrank(alice);
    token.approve(address(circle), 3 ether);
    circle.deposit(circleId1, 1 ether);
    vm.stopPrank();

    // Bob deposits in circle 1
    deal(address(token), bob, 3 ether);
    vm.startPrank(bob);
    token.approve(address(circle), 3 ether);
    circle.deposit(circleId1, 1 ether);
    vm.stopPrank();

    // Warp to circle 2 start time
    vm.warp(c2.circleStart);

    // Alice deposits in circle 2
    vm.startPrank(alice);
    circle.deposit(circleId2, 2 ether);
    vm.stopPrank();

    // Verify balances are tracked separately
    assertEq(circle.balances(circleId1, alice), 1 ether);
    assertEq(circle.balances(circleId2, alice), 2 ether);
    assertEq(circle.balances(circleId1, bob), 1 ether);
    assertEq(circle.balances(circleId2, bob), 0);
  }

  function test_CircleWithMaxMembers() external {
    // Test with large number of members (20)
    // Verify gas costs remain reasonable

    // First allow the token
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    uint256 memberCount = 20;
    address[] memory largeGroup = new address[](memberCount);

    for (uint256 i = 0; i < memberCount; i++) {
      largeGroup[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory largeCircle = ISavingCircles.Circle({
      owner: largeGroup[0],
      members: largeGroup,
      token: address(token),
      depositAmount: 0.1 ether,
      depositInterval: 1 days,
      circleStart: block.timestamp + 1 hours,
      currentIndex: 0
    });

    // Create the circle
    vm.prank(largeGroup[0]);
    uint256 circleId = circle.create(largeCircle);

    // Verify circle was created
    ISavingCircles.Circle memory created = circle.getCircle(circleId);
    assertEq(created.members.length, memberCount);

    // Test deposit from multiple members
    vm.warp(block.timestamp + 1 hours);

    for (uint256 i = 0; i < 5; i++) {
      // Test with first 5 members
      deal(address(token), largeGroup[i], 0.1 ether);
      vm.startPrank(largeGroup[i]);
      token.approve(address(circle), 0.1 ether);
      circle.deposit(circleId, 0.1 ether);
      vm.stopPrank();
    }

    // Verify all deposits recorded
    for (uint256 i = 0; i < 5; i++) {
      assertEq(circle.balances(circleId, largeGroup[i]), 0.1 ether);
    }
  }
}
