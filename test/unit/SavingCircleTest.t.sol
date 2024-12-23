// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {MockERC20} from '../mocks/MockERC20.sol';
import {ISavingsCircle, SavingsCircle} from 'contracts/SavingsCircle.sol';

/* solhint-disable func-name-mixedcase */

contract SavingsCircleTest is Test {
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;
  uint256 public constant CIRCLE_DURATION = 30 days;

  SavingsCircle public savingsCircle;
  MockERC20 public token;

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

    // Deploy and initialize the contract
    vm.startPrank(owner);
    savingsCircle = SavingsCircle(
      address(
        new TransparentUpgradeableProxy(
          address(new SavingsCircle()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(SavingsCircle.initialize.selector, owner)
        )
      )
    );

    token = new MockERC20('Test Token', 'TEST');
    savingsCircle.setTokenAllowed(address(token), true);
    vm.stopPrank();

    // Setup test data
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;
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

    // Create an initial test circle
    vm.prank(alice);
    savingsCircle.addCircle(baseCircle);
  }

  function test_SetTokenAllowedWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    savingsCircle.setTokenAllowed(address(0x1), true);
  }

  function test_SetTokenAllowedWhenCallerIsOwner() external {
    address newToken = makeAddr('newToken');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.TokenAllowed(newToken, true);
    savingsCircle.setTokenAllowed(newToken, true);

    assertTrue(savingsCircle.isTokenAllowed(newToken));
  }

  function test_SetTokenNotAllowedWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    savingsCircle.setTokenAllowed(address(token), false);
  }

  function test_SetTokenNotAllowedWhenCallerIsOwner() external {
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.TokenAllowed(address(token), false);
    savingsCircle.setTokenAllowed(address(token), false);

    assertFalse(savingsCircle.isTokenAllowed(address(token)));
  }

  function test_DepositWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingsCircle.deposit(nonExistentCircleId, DEPOSIT_AMOUNT);
  }

  function test_DepositWhenMemberHasAlreadyDeposited() external {
    // Mint tokens to alice for deposit
    token.mint(alice, DEPOSIT_AMOUNT * 2);

    // Mock token approval
    vm.startPrank(alice);
    token.approve(address(savingsCircle), DEPOSIT_AMOUNT * 2);

    // First deposit
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Second deposit attempt should fail since member has already deposited max amount
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidDeposit.selector));
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();
  }

  function test_DepositWhenParametersAreValid() external {
    vm.startPrank(alice);

    // Mock token transfer
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    // Expect deposit event
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.DepositMade(baseCircleId, alice, DEPOSIT_AMOUNT);

    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);

    // Verify deposit was recorded
    uint256 balance = savingsCircle.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);

    vm.stopPrank();
  }

  function test_DepositWhenDepositPeriodHasPassed() external {
    // Move time past deposit period
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidDeposit.selector));
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
  }

  function test_WithdrawWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingsCircle.withdraw(nonExistentCircleId);
  }

  function test_WithdrawWhenUserIsNotACircleMember() external {
    address nonMember = makeAddr('nonMember');

    vm.prank(nonMember);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.NotWithdrawable.selector));
    savingsCircle.withdraw(baseCircleId);
  }

  function test_WithdrawWhenPayoutRoundHasNotEnded() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.NotWithdrawable.selector));
    savingsCircle.withdraw(baseCircleId);
  }

  function test_WithdrawWhenUserHasAlreadyClaimed() external {
    // Complete deposits
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    vm.startPrank(alice);
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Move time past round
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Mock token transfer for withdrawal
    vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

    // First withdrawal
    vm.prank(alice);
    savingsCircle.withdraw(baseCircleId);

    // Second withdrawal attempt should fail since currentIndex has moved to next member
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.NotWithdrawable.selector));
    savingsCircle.withdraw(baseCircleId);
  }

  function test_WithdrawWhenParametersAreValid() external {
    // Complete deposits from all members
    vm.startPrank(alice);
    token.mint(alice, DEPOSIT_AMOUNT);
    token.approve(address(savingsCircle), DEPOSIT_AMOUNT);
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.approve(address(savingsCircle), DEPOSIT_AMOUNT);
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    token.mint(carol, DEPOSIT_AMOUNT);
    token.approve(address(savingsCircle), DEPOSIT_AMOUNT);
    savingsCircle.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Move time past first round
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Mint tokens to contract to enable withdrawal
    uint256 withdrawAmount = DEPOSIT_AMOUNT * members.length;

    // First member (alice) should be able to withdraw
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.WithdrawalMade(baseCircleId, alice, withdrawAmount);
    savingsCircle.withdraw(baseCircleId);

    // Verify alice received the tokens
    assertEq(token.balanceOf(alice), withdrawAmount);

    // Verify all member balances were reset
    (, uint256[] memory balances) = savingsCircle.balancesForCircle(baseCircleId);
    for (uint256 i = 0; i < balances.length; i++) {
      assertEq(balances[i], 0);
    }

    // Verify current index moved to next member
    ISavingsCircle.Circle memory circle = savingsCircle.circle(baseCircleId);
    assertEq(circle.currentIndex, 1);
  }

  function test_CircleInfoWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingsCircle.circle(nonExistentCircleId);
  }

  function test_CircleInfoWhenCircleExists() external {
    ISavingsCircle.Circle memory _circle = savingsCircle.circle(baseCircleId);

    assertEq(_circle.name, 'Test Circle');
    assertEq(_circle.members.length, members.length);
    assertEq(_circle.token, address(token));
    assertEq(_circle.depositAmount, DEPOSIT_AMOUNT);
    assertEq(_circle.depositInterval, DEPOSIT_INTERVAL);
  }

  function test_DecommissionWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.NotOwner.selector));
    savingsCircle.decommissionCircle(baseCircleId);
  }

  function test_DecommissionWhenCircleDoesNotExist() external {
    bytes32 nonExistentCircleId = keccak256(abi.encodePacked('Non Existent Circle'));

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleNotFound.selector));
    savingsCircle.decommissionCircle(nonExistentCircleId);
  }

  function test_DecommissionWhenParametersAreValid() external {
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.CircleDecommissioned(baseCircleId);
    savingsCircle.decommissionCircle(baseCircleId);
    address[] memory emptyMembers = savingsCircle.circleMembers(baseCircleId);
    assertEq(emptyMembers.length, 0);
  }

  function test_AddCircleWhenCircleNameAlreadyExists() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleExists.selector));
    savingsCircle.addCircle(baseCircle);
  }

  function test_AddCircleWhenTokenIsNotWhitelisted() external {
    address _notAllowedToken = makeAddr('notAllowedToken');

    ISavingsCircle.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.name = 'Invalid Circle';
    _invalidCircle.token = _notAllowedToken;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidToken.selector));
    savingsCircle.addCircle(_invalidCircle);
  }

  function test_AddCircleWhenIntervalIsZero() external {
    ISavingsCircle.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.name = 'Invalid Circle';
    _invalidCircle.depositInterval = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidInterval.selector));
    savingsCircle.addCircle(_invalidCircle);
  }

  function test_AddCircleWhenDepositAmountIsZero() external {
    ISavingsCircle.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.name = 'Invalid Circle';
    _invalidCircle.depositAmount = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidDeposit.selector));
    savingsCircle.addCircle(_invalidCircle);
  }

  function test_AddCircleWhenMembersCountIsLessThanTwo() external {
    address[] memory _oneMember = new address[](1);
    _oneMember[0] = alice;

    ISavingsCircle.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.name = 'Invalid Circle';
    _invalidCircle.members = _oneMember;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidMembers.selector));
    savingsCircle.addCircle(_invalidCircle);
  }
}
