// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingCirclesUnit is Test {
  SavingCircles public savingCircles;
  MockERC20 public token;
  ProxyAdmin public proxyAdmin;

  address public owner = makeAddr('owner');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');

  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 weeks;
  uint256 public constant MAX_DEPOSITS = 3;
  uint256 public constant INTERVAL = 1 weeks;

  uint256 public baseCircleId;
  ISavingCircles.Circle public baseCircle;
  address[] public members;

  function setUp() external {
    // Deploy token
    token = new MockERC20('Test Token', 'TEST');

    // Deploy SavingCircles
    proxyAdmin = new ProxyAdmin(owner);
    SavingCircles implementation = new SavingCircles();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation), address(proxyAdmin), abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
    );
    savingCircles = SavingCircles(address(proxy));

    // Setup members
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    // Allow token
    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);

    // Create base circle
    baseCircle = ISavingCircles.Circle({
      owner: owner,
      members: members,
      currentIndex: 0,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: MAX_DEPOSITS
    });

    vm.prank(owner);
    baseCircleId = savingCircles.create(baseCircle);
  }

  function test_CreateWhenParametersAreValid() external {
    // Create a new circle
    address[] memory newMembers = new address[](2);
    newMembers[0] = alice;
    newMembers[1] = bob;

    ISavingCircles.Circle memory newCircle = ISavingCircles.Circle({
      owner: carol,
      members: newMembers,
      currentIndex: 0,
      circleStart: block.timestamp + 1 days,
      token: address(token),
      depositAmount: 2 ether,
      depositInterval: 2 weeks,
      maxDeposits: 4
    });

    vm.prank(carol);
    uint256 newCircleId = savingCircles.create(newCircle);

    // Verify circle was created
    ISavingCircles.Circle memory createdCircle = savingCircles.getCircle(newCircleId);
    assertEq(createdCircle.owner, carol);
    assertEq(createdCircle.members.length, 2);
    assertEq(createdCircle.depositAmount, 2 ether);
  }

  function test_CreateWhenMembersCountIsLessThanTwo() external {
    address[] memory invalidMembers = new address[](1);
    invalidMembers[0] = alice;

    ISavingCircles.Circle memory invalidCircle = ISavingCircles.Circle({
      owner: carol,
      members: invalidMembers,
      currentIndex: 0,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: MAX_DEPOSITS
    });

    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidMemberCount.selector));
    savingCircles.create(invalidCircle);
  }

  function test_CreateWhenDepositAmountIsZero() external {
    ISavingCircles.Circle memory invalidCircle = baseCircle;
    invalidCircle.depositAmount = 0;

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidDepositAmount.selector));
    savingCircles.create(invalidCircle);
  }

  function test_CreateWhenIntervalIsZero() external {
    ISavingCircles.Circle memory invalidCircle = baseCircle;
    invalidCircle.depositInterval = 0;

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidDepositInterval.selector));
    savingCircles.create(invalidCircle);
  }

  function test_CreateWhenTokenIsNotWhitelisted() external {
    MockERC20 unauthorizedToken = new MockERC20('Unauthorized', 'UNAUTH');
    ISavingCircles.Circle memory invalidCircle = baseCircle;
    invalidCircle.token = address(unauthorizedToken);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.TokenNotAllowed.selector));
    savingCircles.create(invalidCircle);
  }

  function test_DepositWhenParametersAreValid() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();

    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositWhenMemberHasAlreadyDeposited() external {
    token.mint(alice, DEPOSIT_AMOUNT * 2);

    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT * 2);
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.ExceedsDepositAmount.selector));
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();
  }

  function test_DepositWhenDepositPeriodHasPassed() external {
    // Move time past deposit window
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    token.mint(alice, DEPOSIT_AMOUNT);
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.DepositWindowClosed.selector));
    savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
    vm.stopPrank();
  }

  function test_DepositWhenCircleDoesNotExist() external {
    uint256 nonExistentId = 999;
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.deposit(nonExistentId, DEPOSIT_AMOUNT);
    vm.stopPrank();
  }

  function test_WithdrawWhenParametersAreValid() external {
    // All members deposit
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Move time to allow withdrawal
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Alice (first member) can withdraw
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsWithdrawn(baseCircleId, alice, DEPOSIT_AMOUNT * members.length);
    savingCircles.withdraw(baseCircleId);

    // Check alice received funds
    uint256 aliceTokenBalance = token.balanceOf(alice);
    assertEq(aliceTokenBalance, DEPOSIT_AMOUNT * members.length);
  }

  function test_WithdrawForWhenParametersAreValid() external {
    // All members deposit
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Move time to allow withdrawal
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Bob can withdraw for alice (first member)
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsWithdrawn(baseCircleId, alice, DEPOSIT_AMOUNT * members.length);
    savingCircles.withdrawFor(baseCircleId, alice);

    // Check alice received funds
    uint256 aliceTokenBalance = token.balanceOf(alice);
    assertEq(aliceTokenBalance, DEPOSIT_AMOUNT * members.length);
  }

  function test_WithdrawWhenAllMembersHaveDeposited() external {
    // All members deposit
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Withdraw is allowed immediately after all deposits
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsWithdrawn(baseCircleId, alice, DEPOSIT_AMOUNT * members.length);
    savingCircles.withdraw(baseCircleId);

    // Check alice received funds
    uint256 aliceTokenBalance = token.balanceOf(alice);
    assertEq(aliceTokenBalance, DEPOSIT_AMOUNT * members.length);
  }

  function test_WithdrawWhenUserHasAlreadyClaimed() external {
    // All members deposit for first round
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Move time and alice withdraws
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);
    vm.prank(alice);
    savingCircles.withdraw(baseCircleId);

    // All members deposit for second round
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], DEPOSIT_AMOUNT);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(baseCircleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Move time - now it's bob's turn
    vm.warp(block.timestamp + DEPOSIT_INTERVAL);

    // Alice tries to withdraw again (not her turn)
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotWithdrawable.selector));
    savingCircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenUserIsNotACircleMember() external {
    address stranger = makeAddr('stranger');

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    savingCircles.withdraw(baseCircleId);
  }

  function test_WithdrawWhenCircleDoesNotExist() external {
    uint256 nonExistentId = 999;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.withdraw(nonExistentId);
  }

  function test_CircleInfoWhenCircleDoesNotExist() external {
    uint256 nonExistentId = 999;

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.getCircle(nonExistentId);
  }

  function test_CircleInfoWhenCircleAlreadyExists() external {
    ISavingCircles.Circle memory circle = savingCircles.getCircle(baseCircleId);

    assertEq(circle.owner, owner);
    assertEq(circle.members.length, 3);
    assertEq(circle.depositAmount, DEPOSIT_AMOUNT);
    assertEq(circle.depositInterval, DEPOSIT_INTERVAL);
    assertEq(circle.maxDeposits, MAX_DEPOSITS);
  }

  function test_DecommissionWhenOwner() external {
    // Create a circle owned by alice
    ISavingCircles.Circle memory aliceCircle = baseCircle;
    aliceCircle.owner = alice;

    vm.prank(alice);
    uint256 aliceCircleId = savingCircles.create(aliceCircle);

    // Move time past the deposit window to allow decommission
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Alice can decommission her own circle
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.CircleDecommissioned(aliceCircleId);
    savingCircles.decommission(aliceCircleId);

    // Circle should be decommissioned
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    savingCircles.getCircle(aliceCircleId);
  }

  function test_DecommissionWhenMemberAndIncompleteDeposits() external {
    // Move time past deposit window with incomplete deposits
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Any member can decommission when deposits are incomplete after window
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.CircleDecommissioned(baseCircleId);
    savingCircles.decommission(baseCircleId);
  }

  function test_SetTokenAllowedWhenCallerIsOwner() external {
    MockERC20 newToken = new MockERC20('New Token', 'NEW');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.TokenAllowed(address(newToken), true);
    savingCircles.setTokenAllowed(address(newToken), true);

    assertTrue(savingCircles.isTokenAllowed(address(newToken)));
  }

  function test_SetTokenAllowedWhenCallerIsNotOwner() external {
    MockERC20 newToken = new MockERC20('New Token', 'NEW');

    vm.prank(alice);
    vm.expectRevert();
    savingCircles.setTokenAllowed(address(newToken), true);
  }

  function test_SetTokenNotAllowedWhenCallerIsOwner() external {
    // First allow the token
    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);
    assertTrue(savingCircles.isTokenAllowed(address(token)));

    // Then disallow it
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.TokenAllowed(address(token), false);
    savingCircles.setTokenAllowed(address(token), false);

    assertFalse(savingCircles.isTokenAllowed(address(token)));
  }

  function test_SetTokenNotAllowedWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert();
    savingCircles.setTokenAllowed(address(token), false);
  }

  function test_GetCircles() external {
    // Create additional circles
    ISavingCircles.Circle memory circle2 = baseCircle;
    circle2.owner = alice;

    ISavingCircles.Circle memory circle3 = baseCircle;
    circle3.owner = bob;

    vm.prank(alice);
    uint256 circleId2 = savingCircles.create(circle2);

    vm.prank(bob);
    uint256 circleId3 = savingCircles.create(circle3);

    // Get multiple circles
    uint256[] memory ids = new uint256[](3);
    ids[0] = baseCircleId;
    ids[1] = circleId2;
    ids[2] = circleId3;

    ISavingCircles.Circle[] memory circles = savingCircles.getCircles(ids);

    assertEq(circles.length, 3);
    assertEq(circles[0].owner, owner);
    assertEq(circles[1].owner, alice);
    assertEq(circles[2].owner, bob);
  }

  function test_GetCirclesWhenCircleDoesNotExist() external {
    uint256[] memory ids = new uint256[](2);
    ids[0] = baseCircleId;
    ids[1] = 999; // Non-existent

    ISavingCircles.Circle[] memory circles = savingCircles.getCircles(ids);

    assertEq(circles.length, 2);
    assertEq(circles[0].owner, owner);
    assertEq(circles[1].owner, address(0)); // Decommissioned/non-existent
  }

  function test_GetMemberCircles() external {
    // Create additional circles with alice as member
    address[] memory aliceMembers = new address[](2);
    aliceMembers[0] = alice;
    aliceMembers[1] = bob;

    ISavingCircles.Circle memory circle2 = ISavingCircles.Circle({
      owner: carol,
      members: aliceMembers,
      currentIndex: 0,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: MAX_DEPOSITS
    });

    vm.prank(carol);
    uint256 circleId2 = savingCircles.create(circle2);

    // Get alice's circles
    uint256[] memory aliceCircles = savingCircles.getMemberCircles(alice);

    assertEq(aliceCircles.length, 2);
    assertEq(aliceCircles[0], baseCircleId);
    assertEq(aliceCircles[1], circleId2);
  }

  function test_CheckMemberships() external {
    // Create another circle without alice
    address[] memory otherMembers = new address[](2);
    otherMembers[0] = bob;
    otherMembers[1] = carol;

    ISavingCircles.Circle memory secondCircle = ISavingCircles.Circle({
      owner: owner,
      members: otherMembers,
      currentIndex: 0,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: MAX_DEPOSITS
    });

    vm.prank(owner);
    uint256 secondCircleId = savingCircles.create(secondCircle);

    // Check alice's memberships
    uint256[] memory circleIds = new uint256[](3);
    circleIds[0] = baseCircleId;
    circleIds[1] = secondCircleId;
    circleIds[2] = 999; // Non-existent

    bool[] memory statuses = savingCircles.checkMemberships(alice, circleIds);

    assertEq(statuses.length, 3);
    assertTrue(statuses[0]); // Alice is in baseCircle
    assertFalse(statuses[1]); // Alice is not in secondCircle
    assertFalse(statuses[2]); // Circle doesn't exist

    // Check stranger's memberships
    address stranger = makeAddr('stranger');
    bool[] memory strangerStatuses = savingCircles.checkMemberships(stranger, circleIds);

    assertEq(strangerStatuses.length, 3);
    assertFalse(strangerStatuses[0]); // Not in baseCircle
    assertFalse(strangerStatuses[1]); // Not in secondCircle
    assertFalse(strangerStatuses[2]); // Not in non-existent circle
  }
}
