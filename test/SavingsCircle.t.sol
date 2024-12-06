// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SavingsCircle} from '../src/contracts/SavingsCircle.sol';
import {ISavingsCircle} from '../src/interfaces/ISavingsCircle.sol';
import {MockERC20} from './mocks/MockERC20.sol';

import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test, console} from 'forge-std/Test.sol';

contract SavingsCircleTest is Test {
  SavingsCircle public implementation;
  SavingsCircle public circle;
  MockERC20 public token;
  ProxyAdmin public proxyAdmin;
  TransparentUpgradeableProxy public proxy;

  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public owner = makeAddr('owner');
  address[] public members;

  uint256 public constant DEPOSIT_AMOUNT = 1000e18;
  uint256 public constant DEPOSIT_INTERVAL = 7 days;
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant BASE_MAX_DEPOSITS = 1000;
  bytes32 public constant BASE_CIRCLE_ID = keccak256(abi.encodePacked('Test Circle'));

  ISavingsCircle.Circle public baseCircle;

  function setUp() public {
    vm.startPrank(owner);
    // Deploy implementation
    implementation = new SavingsCircle();

    // Deploy ProxyAdmin
    proxyAdmin = new ProxyAdmin(owner);

    // Deploy proxy
    bytes memory initData = abi.encodeWithSelector(SavingsCircle.initialize.selector);

    proxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

    // Get interface for proxy
    circle = SavingsCircle(address(proxy));

    token = new MockERC20('Test Token', 'TEST');
    circle.allowlistToken(address(token));
    vm.stopPrank();

    // Setup test accounts
    vm.startPrank(alice);
    token.mint(alice, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(bob);
    token.mint(bob, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(carol);
    token.mint(carol, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    vm.stopPrank();

    // Setup base circle parameters
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    baseCircle = ISavingsCircle.Circle({
      owner: alice,
      name: 'Test Circle',
      members: members,
      currentIndex: BASE_CURRENT_INDEX,
      circleStart: block.timestamp,
      tokenAddress: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: BASE_MAX_DEPOSITS
    });
  }

  function test_AllowlistToken() public {
    address newToken = makeAddr('newToken');
    vm.prank(owner);
    circle.allowlistToken(newToken);
    assertTrue(circle.isTokenAllowlisted(newToken));
  }

  function test_DenylistToken() public {
    vm.startPrank(owner);
    circle.allowlistToken(address(token));
    circle.denylistToken(address(token));
    vm.stopPrank();
    assertFalse(circle.isTokenAllowlisted(address(token)));
  }

  function testFail_NonOwnerAllowlist() public {
    vm.prank(alice);
    circle.allowlistToken(address(token));
  }

  function testFail_CreateCircleWithUnAllowlistedToken() public {
    address badToken = makeAddr('badToken');
    baseCircle.tokenAddress = badToken;
    vm.prank(alice);
    circle.addCircle(baseCircle);
  }

  function test_deposit() public {
    // deposit
    vm.prank(alice);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    (, uint256[] memory balances) = circle.balancesForCircle(BASE_CIRCLE_ID);
    assertEq(balances[0], DEPOSIT_AMOUNT);
  }

  function test_DepositFor() public {
    // Bob deposits for Alice
    vm.prank(bob);
    circle.depositFor(BASE_CIRCLE_ID, alice, DEPOSIT_AMOUNT);

    (, uint256[] memory balances) = circle.balancesForCircle(BASE_CIRCLE_ID);
    assertEq(balances[0], DEPOSIT_AMOUNT);
  }

  function test_WithdrawWithInterval() public {
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
    vm.expectRevert(ISavingsCircle.NotWithdrawable.selector);
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
    vm.expectRevert(ISavingsCircle.CircleNotFound.selector);
    circle.circleInfo(BASE_CIRCLE_ID);
  }

  function testFail_NonOwnerDecommission() public {
    // Try to decommission as non-owner
    vm.prank(bob);
    circle.decommissionCircle(BASE_CIRCLE_ID);
  }

  function testFail_WithdrawNotEnoughContributions() public {
    // Only two members deposit
    vm.prank(alice);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(BASE_CIRCLE_ID, DEPOSIT_AMOUNT);

    // Try to withdraw
    vm.prank(alice);
    circle.withdraw(BASE_CIRCLE_ID);
  }

  // // Withdraw function branching tests
  // function test_WithdrawBranchingTree() public {
  //     // Branch 1: Circle doesn't exist
  //     bytes32 nonExistentCircle = keccak256(abi.encodePacked("Non Existent"));
  //     vm.prank(alice);
  //     vm.expectRevert(ISavingsCircle.CircleNotFound.selector);
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
  //     vm.expectRevert(ISavingsCircle.NotWithdrawable.selector);
  //     circle.withdraw(hashedName);

  //     // Branch 3: Not all members contributed
  //     vm.prank(alice);
  //     circle.deposit(hashedName, DEPOSIT_AMOUNT);
  //     vm.prank(bob);
  //     circle.deposit(hashedName, DEPOSIT_AMOUNT);
  //     // Carol hasn't contributed
  //     vm.prank(alice);
  //     vm.expectRevert(ISavingsCircle.NotWithdrawable.selector);
  //     circle.withdraw(hashedName);

  //     // Branch 4: Wrong member trying to withdraw
  //     vm.prank(carol);
  //     circle.deposit(hashedName, DEPOSIT_AMOUNT);
  //     vm.prank(bob);
  //     vm.expectRevert(ISavingsCircle.NotWithdrawable.selector);
  //     circle.withdraw(hashedName);

  //     // Branch 5: Successful withdrawal
  //     vm.prank(alice);
  //     circle.withdraw(hashedName);

  //     // Branch 6: Second withdrawal before interval
  //     vm.prank(bob);
  //     vm.expectRevert(ISavingsCircle.NotWithdrawable.selector);
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
  //     vm.expectRevert(ISavingsCircle.NotWithdrawable.selector); // Should fail as no new deposits made
  //     circle.withdraw(hashedName);
  // }
}
