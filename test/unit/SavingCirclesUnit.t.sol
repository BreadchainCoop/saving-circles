// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {MockERC20} from '../mocks/MockERC20.sol';
import {ISavingCircles, SavingCircles} from 'contracts/SavingCircles.sol';

/* solhint-disable func-name-mixedcase */

contract SavingCirclesUnit is Test {
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;
  uint256 public constant CIRCLE_DURATION = 30 days;

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
      currentIndex: 0,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: 1000
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
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidDeposit.selector));
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
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidDeposit.selector));
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
  }

  function test_WithdrawWhenCircleDoesNotExist() external {
    uint256 nonExistentCircleId = uint256(keccak256(abi.encodePacked('Non Existent Circle')));

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.withdrawable(nonExistentCircleId);

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
    (, uint256[] memory balances) = savingCircles.memberBalances(baseCircleId);
    for (uint256 i = 0; i < balances.length; i++) {
      assertEq(balances[i], 0);
    }

    // Verify current index moved to next member
    ISavingCircles.Circle memory circle = savingCircles.circle(baseCircleId);
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
    (, uint256[] memory balances) = savingCircles.memberBalances(baseCircleId);
    for (uint256 i = 0; i < balances.length; i++) {
      assertEq(balances[i], 0);
    }

    // Verify current index moved to next member
    ISavingCircles.Circle memory circle = savingCircles.circle(baseCircleId);
    assertEq(circle.currentIndex, 1);
  }

  function test_CircleInfoWhenCircleDoesNotExist() external {
    uint256 nonExistentCircleId = uint256(keccak256(abi.encodePacked('Non Existent Circle')));

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.circle(nonExistentCircleId);
  }

  function test_CircleInfoWhenCircleAlreadyExists() external {
    ISavingCircles.Circle memory _circle = savingCircles.circle(baseCircleId);

    assertEq(_circle.members.length, members.length);
    assertEq(_circle.token, address(token));
    assertEq(_circle.depositAmount, DEPOSIT_AMOUNT);
    assertEq(_circle.depositInterval, DEPOSIT_INTERVAL);
  }

  function test_DecommissionWhenOwner() external {
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.CircleDecommissioned(baseCircleId);
    savingCircles.decommission(baseCircleId);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.circle(baseCircleId);
  }

  function test_DecommissionWhenNotMember() external {
    vm.prank(makeAddr('stranger'));
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    savingCircles.decommission(baseCircleId);
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
    savingCircles.circle(baseCircleId);

    // Verify alice got her deposit back
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT);
  }

  function test_CreateWhenTokenIsNotWhitelisted() external {
    address _notAllowedToken = makeAddr('notAllowedToken');

    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.token = _notAllowedToken;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidCircle.selector));
    savingCircles.create(_invalidCircle);
  }

  function test_CreateWhenIntervalIsZero() external {
    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.depositInterval = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidCircle.selector));
    savingCircles.create(_invalidCircle);
  }

  function test_CreateWhenDepositAmountIsZero() external {
    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.depositAmount = 0;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidCircle.selector));
    savingCircles.create(_invalidCircle);
  }

  function test_CreateWhenMembersCountIsLessThanTwo() external {
    address[] memory _oneMember = new address[](1);
    _oneMember[0] = alice;

    ISavingCircles.Circle memory _invalidCircle = baseCircle;
    _invalidCircle.members = _oneMember;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidCircle.selector));
    savingCircles.create(_invalidCircle);
  }
}
