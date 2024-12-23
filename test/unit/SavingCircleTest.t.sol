// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ISavingsCircle, SavingsCircle} from 'contracts/SavingsCircle.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingsCircleTest is Test {
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;
  uint256 public constant CIRCLE_DURATION = 30 days;

  SavingsCircle public savingcircles;
  IERC20 public token;

  // Test addresses
  address public owner;
  address public alice;
  address public bob;
  address public carol;
  address public immutable STRANGER = makeAddr('stranger');

  // Test data
  bytes32 public baseCircleId;
  address[] public members;
  ISavingsCircle.Circle public baseCircle;

  function setUp() external {
    // Setup test addresses
    owner = makeAddr('owner');
    alice = makeAddr('alice');
    bob = makeAddr('bob');
    carol = makeAddr('carol');
    token = IERC20(makeAddr('token'));

    // Setup test data
    members = new address[](4);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;
    members[3] = owner;
    baseCircleId = keccak256(abi.encodePacked('Test Circle'));

    // Setup savingcircles parameters
    baseCircle = ISavingsCircle.Circle({
      owner: owner,
      name: 'Test Circle',
      members: members,
      currentIndex: 0,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: 1000
    });

    // Deploy and initialize the contract
    vm.startPrank(owner);
    SavingsCircle implementation = new SavingsCircle();
    ProxyAdmin proxyAdmin = new ProxyAdmin(owner);
    bytes memory initData = abi.encodeWithSelector(SavingsCircle.initialize.selector, owner);
    TransparentUpgradeableProxy proxy =
      new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);
    savingcircles = SavingsCircle(address(proxy));
    savingcircles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    // Create initial test savingcircles
    vm.prank(alice);
    savingcircles.addCircle(baseCircle);
  }

  function test_SetTokenAllowedWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    savingcircles.setTokenAllowed(address(0x1), true);
  }

  function test_SetTokenAllowedWhenCallerIsOwner() external {
    address newToken = makeAddr('newToken');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.TokenAllowed(newToken, true);
    savingcircles.setTokenAllowed(newToken, true);

    assertTrue(savingcircles.isTokenAllowed(newToken));
  }

  function test_SetTokenNotAllowedWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    savingcircles.setTokenAllowed(address(token), false);
  }

  function test_SetTokenNotAllowedWhenCallerIsOwner() external {
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.TokenAllowed(address(token), false);
    savingcircles.setTokenAllowed(address(token), false);

    assertFalse(savingcircles.isTokenAllowed(address(token)));
  }

  function test_DepositWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingcircles.deposit(nonExistentCircleId, DEPOSIT_AMOUNT);
  }

  function test_DepositWhenMemberHasAlreadyDeposited() external {
    // First deposit
    vm.startPrank(STRANGER);
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
    savingcircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Second deposit attempt
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.AlreadyDeposited.selector));
    savingcircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
  }

  function test_DepositWhenParametersAreValid() external {
    vm.startPrank(STRANGER);

    // Mock token transfer
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    // Expect deposit event
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.DepositMade(baseCircleId, alice, DEPOSIT_AMOUNT);

    savingcircles.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Verify deposit was recorded
    uint256 balance = savingcircles.circleBalances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);

    vm.stopPrank();
  }

  function test_DepositWhenDepositPeriodHasPassed() external {
    // Move time past deposit period
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidDeposit.selector));
    savingcircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
  }

  function test_WithdrawWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingcircles.withdraw(nonExistentCircleId);
  }

  function test_WithdrawWhenUserIsNotACircleMember() external {
    address nonMember = makeAddr('nonMember');

    vm.prank(nonMember);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.NotMember.selector));
    savingcircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenPayoutRoundHasNotEnded() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.NotWithdrawable.selector));
    savingcircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenUserHasAlreadyClaimed() external {
    // Complete deposits
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    vm.startPrank(alice);
    savingcircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Move time past round
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // First withdrawal
    vm.prank(alice);
    savingcircles.withdraw(baseCircleId);

    // Second withdrawal attempt
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.NotWithdrawable.selector));
    savingcircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenParametersAreValid() external {
    // Complete deposits
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    vm.startPrank(alice);
    savingcircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Move time past round
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Mock token transfer for withdrawal
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.WithdrawalMade(baseCircleId, alice, DEPOSIT_AMOUNT);
    savingcircles.withdraw(baseCircleId);

    // Verify withdrawal was recorded
    bool hasWithdrawn = savingcircles.circleWithdrawable(baseCircleId);
    assertFalse(hasWithdrawn);
  }

  function test_CircleInfoWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingcircles.circle(nonExistentCircleId);
  }

  function test_CircleInfoWhenCircleExists() external {
    ISavingsCircle.Circle memory _circle = savingcircles.circle(baseCircleId);

    assertEq(_circle.name, 'Test Circle');
    assertEq(_circle.members.length, members.length);
    assertEq(_circle.token, address(token));
    assertEq(_circle.depositAmount, DEPOSIT_AMOUNT);
    assertEq(_circle.depositInterval, DEPOSIT_INTERVAL);
  }

  function test_DecommissionWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    savingcircles.decommissionCircle(baseCircleId);
  }

  function test_DecommissionWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingcircles.decommissionCircle(nonExistentCircleId);
  }

  function test_DecommissionWhenParametersAreValid() external {
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.CircleDecommissioned(baseCircleId);
    savingcircles.decommissionCircle(baseCircleId);
    address[] memory emptyMembers = savingcircles.circleMembers(baseCircleId);
    assertEq(emptyMembers.length, 0);
  }

  function test_AddCircleWhenCircleNameAlreadyExists() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleExists.selector));
    savingcircles.addCircle(baseCircle);
  }

  function test_AddCircleWhenTokenIsNotWhitelisted() external {
    address nonWhitelistedToken = makeAddr('nonWhitelistedToken');
    ISavingsCircle.Circle memory invalidParams = baseCircle;
    invalidParams.token = nonWhitelistedToken;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidToken.selector));
    savingcircles.addCircle(invalidParams);
  }

  function test_AddCircleWhenIntervalIsZero() external {
    ISavingsCircle.Circle memory invalidParams = baseCircle;
    invalidParams.depositInterval = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidInterval.selector));
    savingcircles.addCircle(invalidParams);
  }

  function test_AddCircleWhenDepositAmountIsZero() external {
    ISavingsCircle.Circle memory invalidParams = baseCircle;
    invalidParams.depositAmount = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidDeposit.selector));
    savingcircles.addCircle(invalidParams);
  }

  function test_AddCircleWhenMembersCountIsLessThanTwo() external {
    address[] memory singleMember = new address[](1);
    singleMember[0] = alice;

    ISavingsCircle.Circle memory invalidParams = baseCircle;
    invalidParams.members = singleMember;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidMembers.selector));
    savingcircles.addCircle(invalidParams);
  }
}
