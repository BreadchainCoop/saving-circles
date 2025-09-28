// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

contract DelegatedSavingCirclesUnit is Test {
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

  uint256 public baseCircleId;
  ISavingCircles.Circle public baseCircle;
  address[] public members;

  function setUp() external {
    // Deploy token
    token = new MockERC20('Test Token', 'TEST');

    // Deploy SavingCircles contract with integrated delegation features
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

    // Create a base circle for testing
    baseCircle = ISavingCircles.Circle({
      owner: owner,
      members: members,
      currentIndex: 0,
      depositAmount: DEPOSIT_AMOUNT,
      token: address(token),
      depositInterval: DEPOSIT_INTERVAL,
      circleStart: block.timestamp,
      maxDeposits: MAX_DEPOSITS
    });

    vm.prank(owner);
    baseCircleId = savingCircles.create(baseCircle);
  }

  function test_SetDelegatedDepositsEnabled() external {
    // Check initial state is disabled
    assertFalse(savingCircles.delegatedDepositsEnabled(alice));

    // Alice enables delegated deposits
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.DelegatedDepositsToggled(alice, true);
    savingCircles.setDelegatedDepositsEnabled(true);

    // Verify it's enabled
    assertTrue(savingCircles.delegatedDepositsEnabled(alice));

    // Alice disables delegated deposits
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.DelegatedDepositsToggled(alice, false);
    savingCircles.setDelegatedDepositsEnabled(false);

    // Verify it's disabled
    assertFalse(savingCircles.delegatedDepositsEnabled(alice));
  }

  function test_DepositIfAllowed_WithSufficientAllowance() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to delegated deposits
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);

    // Alice approves the savingCircles contract
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Anyone can call depositIfAllowed for alice
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);
    savingCircles.depositIfAllowed(baseCircleId, alice);

    // Verify deposit was recorded
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositIfAllowed_NotOptedIn() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice approves but does NOT opt in
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Should revert because alice hasn't opted in
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.DelegatedDepositsNotEnabled.selector));
    savingCircles.depositIfAllowed(baseCircleId, alice);
  }

  function test_DepositIfAllowed_WithInsufficientAllowance() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to delegated deposits
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);

    // Alice approves less than required amount
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT / 2);

    // Call should revert with InsufficientAllowance
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InsufficientAllowance.selector));
    savingCircles.depositIfAllowed(baseCircleId, alice);
  }

  function test_DepositIfAllowed_WhenAlreadyDeposited() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT * 2);

    // Alice opts in to delegated deposits
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);

    // Alice makes a regular deposit first
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.depositFor(baseCircleId, DEPOSIT_AMOUNT, alice);
    vm.stopPrank();

    // Approve for another deposit attempt
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Call depositIfAllowed - should revert with AlreadyDeposited
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyDeposited.selector));
    savingCircles.depositIfAllowed(baseCircleId, alice);
  }

  function test_DepositIfAllowed_EmitsDelegatedDepositMadeEvent() external {
    // Setup
    token.mint(alice, DEPOSIT_AMOUNT);
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Expect both events
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.DelegatedDepositMade(baseCircleId, alice, bob, DEPOSIT_AMOUNT);
    savingCircles.depositIfAllowed(baseCircleId, alice);
  }

  function test_GetAddressesForDeposit_AllEligible() external {
    // Mint tokens to all members
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.mint(carol, DEPOSIT_AMOUNT);

    // All members opt in and approve
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    vm.prank(bob);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(bob);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    vm.prank(carol);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(carol);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Get eligible addresses
    address[] memory eligible = savingCircles.getAddressesForDeposit(baseCircleId);
    assertEq(eligible.length, 3);
    assertEq(eligible[0], alice);
    assertEq(eligible[1], bob);
    assertEq(eligible[2], carol);
  }

  function test_GetAddressesForDeposit_PartiallyEligible() external {
    // Mint tokens to alice and bob
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);

    // Only alice opts in and approves
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Bob opts in but doesn't approve
    vm.prank(bob);
    savingCircles.setDelegatedDepositsEnabled(true);

    // Carol doesn't opt in

    // Get eligible addresses - only alice should be eligible
    address[] memory eligible = savingCircles.getAddressesForDeposit(baseCircleId);
    assertEq(eligible.length, 1);
    assertEq(eligible[0], alice);
  }

  function test_GetAddressesForDeposit_OutsideDepositWindow() external {
    // Setup approvals
    token.mint(alice, DEPOSIT_AMOUNT);
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Warp to outside the deposit window
    vm.warp(block.timestamp + DEPOSIT_INTERVAL + 1);

    // Should return empty array
    address[] memory eligible = savingCircles.getAddressesForDeposit(baseCircleId);
    assertEq(eligible.length, 0);
  }

  function test_BatchDepositIfAllowed_Success() external {
    // Mint tokens
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);

    // Both members opt in and approve
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    vm.prank(bob);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(bob);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Setup arrays
    uint256[] memory circleIds = new uint256[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;

    address[] memory membersArray = new address[](2);
    membersArray[0] = alice;
    membersArray[1] = bob;

    // Perform batch deposit
    savingCircles.batchDepositIfAllowed(circleIds, membersArray);

    // Verify deposits
    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, bob), DEPOSIT_AMOUNT);
  }

  function test_BatchDepositIfAllowed_MismatchedArrays() external {
    uint256[] memory circleIds = new uint256[](2);
    address[] memory membersArray = new address[](1);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.ArrayLengthMismatch.selector));
    savingCircles.batchDepositIfAllowed(circleIds, membersArray);
  }

  function test_BatchDepositIfAllowed_PartialFailure() external {
    // Mint tokens only to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in and approves
    vm.prank(alice);
    savingCircles.setDelegatedDepositsEnabled(true);
    vm.prank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);

    // Bob opts in but has no tokens
    vm.prank(bob);
    savingCircles.setDelegatedDepositsEnabled(true);

    uint256[] memory circleIds = new uint256[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;

    address[] memory membersArray = new address[](2);
    membersArray[0] = alice;
    membersArray[1] = bob; // This will fail due to insufficient allowance

    // The batch should fail when bob's deposit fails
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InsufficientAllowance.selector));
    savingCircles.batchDepositIfAllowed(circleIds, membersArray);

    // Verify alice's deposit was not made due to revert
    assertEq(savingCircles.balances(baseCircleId, alice), 0);
  }
}
