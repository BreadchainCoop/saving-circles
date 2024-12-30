// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {IntegrationBase} from 'test/integration/IntegrationBase.sol';

/* solhint-disable func-name-mixedcase */

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
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidCircle.selector));
    circle.create(baseCircle);
  }

  function test_Deposit() public {
    createBaseCircle();

    vm.prank(alice);
    circle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    (, uint256[] memory balances) = circle.memberBalances(baseCircleId);
    assertEq(balances[0], DEPOSIT_AMOUNT);
  }

  function test_DepositFor() public {
    createBaseCircle();

    // Bob deposits for Alice
    vm.prank(bob);
    circle.depositFor(baseCircleId, DEPOSIT_AMOUNT, alice);

    (, uint256[] memory balances) = circle.memberBalances(baseCircleId);
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

    // Decommission circle
    vm.prank(alice);
    circle.decommission(baseCircleId);

    // Check balances returned
    assertEq(token.balanceOf(alice) - aliceBalanceBefore, DEPOSIT_AMOUNT);
    assertEq(token.balanceOf(bob) - bobBalanceBefore, DEPOSIT_AMOUNT);

    // Check circle deleted
    vm.expectRevert(ISavingCircles.NotCommissioned.selector);
    circle.circle(baseCircleId);
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
    circle.circle(baseCircleId);
  }

  function test_RevertWhen_NonMemberDecommissions() public {
    createBaseCircle();

    vm.prank(makeAddr('stranger'));
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    circle.decommission(baseCircleId);
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
}
