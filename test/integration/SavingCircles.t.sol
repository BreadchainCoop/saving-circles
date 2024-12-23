// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/* solhint-disable func-name-mixedcase */

contract SavingCirclesIntegration is Test {
  SavingCircles public circle;
  MockERC20 public token;

  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public owner = makeAddr('owner');
  address[] public members;

  string public constant BASE_CIRCLE_NAME = 'Test Circle';
  uint256 public constant DEPOSIT_AMOUNT = 1000e18;
  uint256 public constant DEPOSIT_INTERVAL = 7 days;
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant BASE_MAX_DEPOSITS = 1000;
  bytes32 public constant BASE_CIRCLE_ID = keccak256(abi.encodePacked(BASE_CIRCLE_NAME));

  ISavingCircles.Circle public baseCircle;

  function setUp() public {
    vm.startPrank(owner);
    circle = SavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new SavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
        )
      )
    );

    token = new MockERC20('Test Token', 'TEST');
    vm.stopPrank();

    // Setup test accounts
    vm.startPrank(alice);
    token.mint(alice, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(alice);
    vm.stopPrank();

    vm.startPrank(bob);
    token.mint(bob, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(bob);
    vm.stopPrank();

    vm.startPrank(carol);
    token.mint(carol, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(carol);
    vm.stopPrank();

    baseCircle = ISavingCircles.Circle({
      owner: alice,
      name: BASE_CIRCLE_NAME,
      members: members,
      currentIndex: BASE_CURRENT_INDEX,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: BASE_MAX_DEPOSITS
    });
  }

  function createBaseCircle() public {
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    vm.prank(alice);
    circle.addCircle(baseCircle);
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
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidToken.selector));
    circle.addCircle(baseCircle);
  }

  function test_Deposit() public {
    createBaseCircle();

    vm.prank(alice);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    (, uint256[] memory balances) = circle.balancesForCircle(BASE_CIRCLE_ID);
    assertEq(balances[0], DEPOSIT_AMOUNT);
  }

  function test_DepositFor() public {
    createBaseCircle();

    // Bob deposits for Alice
    vm.prank(bob);
    circle.depositFor(BASE_CIRCLE_ID, alice, DEPOSIT_AMOUNT);

    (, uint256[] memory balances) = circle.balancesForCircle(BASE_CIRCLE_ID);
    assertEq(balances[0], DEPOSIT_AMOUNT);
  }

  function test_WithdrawWithInterval() public {
    createBaseCircle();

    vm.prank(alice);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    vm.prank(carol);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    // First member withdraws
    uint256 balanceBefore = token.balanceOf(alice);
    vm.prank(alice);
    circle.withdraw(BASE_CIRCLE_ID);
    uint256 balanceAfter = token.balanceOf(alice);

    // Alice should receive DEPOSIT_AMOUNT * 3 (from Bob and Carol)
    assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT * 3);

    // Try to withdraw before interval
    vm.prank(bob);
    vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
    circle.withdraw(BASE_CIRCLE_ID);

    // Wait for interval (need to wait for index 1's interval)
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);
    vm.prank(alice);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);
    vm.prank(bob);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);
    vm.prank(carol);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    // Bob should be able to withdraw
    vm.prank(bob);
    circle.withdraw(BASE_CIRCLE_ID);
  }

  function test_DecommissionCircle() public {
    createBaseCircle();

    // Members deposit
    vm.prank(alice);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    // Get initial balances
    uint256 aliceBalanceBefore = token.balanceOf(alice);
    uint256 bobBalanceBefore = token.balanceOf(bob);

    // Decommission circle
    vm.prank(alice);
    circle.decommissionCircle(BASE_CIRCLE_ID);

    // Check balances returned
    assertEq(token.balanceOf(alice) - aliceBalanceBefore, DEPOSIT_AMOUNT);
    assertEq(token.balanceOf(bob) - bobBalanceBefore, DEPOSIT_AMOUNT);

    // Check circle deleted
    vm.expectRevert(ISavingCircles.CircleNotFound.selector);
    circle.circle(BASE_CIRCLE_ID);
  }

  function test_RevertWhen_NonOwnerDecommissions() public {
    createBaseCircle();

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotOwner.selector));
    circle.decommissionCircle(BASE_CIRCLE_ID);
  }

  function test_RevertWhen_NotEnoughContributions() public {
    createBaseCircle();

    vm.prank(alice);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    vm.prank(alice);
    vm.expectRevert(ISavingCircles.NotWithdrawable.selector);
    circle.withdraw(BASE_CIRCLE_ID);
  }

  // // Withdraw function branching tests
  // function test_WithdrawBranchingTree() public {
  //     // Branch 1: Circle doesn't exist
  //     bytes32 nonExistentCircle = keccak256(abi.encodePacked("Non Existent"));
  //     vm.prank(alice);
  //     vm.expectRevert(ISavingCircles.CircleNotFound.selector);
  //     circle.withdraw(nonExistentCircle);

  //     // Setup circle for remaining tests
  //     address[] memory members = new address[](3);
  //     members[0] = alice;
  //     members[1] = bob;
  //     members[2] = carol;

  //     vm.prank(alice);
  //     circle.addCircle("Test Circle", members, address(token), DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);
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
