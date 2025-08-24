// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {SavingCirclesAutomatedDeposits} from '../../src/contracts/SavingCirclesAutomatedDeposits.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {ISavingCirclesAutomatedDeposits} from '../../src/interfaces/ISavingCirclesAutomatedDeposits.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingCirclesAutomatedDepositsUnit is Test {
  SavingCircles public savingCircles;
  SavingCirclesAutomatedDeposits public automatedDeposits;
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

    // Deploy main SavingCircles contract
    proxyAdmin = new ProxyAdmin(owner);
    SavingCircles implementation = new SavingCircles();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation), address(proxyAdmin), abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
    );
    savingCircles = SavingCircles(address(proxy));

    // Deploy automated deposits extension
    automatedDeposits = new SavingCirclesAutomatedDeposits(address(savingCircles));

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

  function test_SetAutomatedDepositsEnabled() external {
    // Check initial state is disabled
    assertFalse(automatedDeposits.isAutomatedDepositsEnabled(alice));

    // Alice enables automated deposits
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCirclesAutomatedDeposits.AutomatedDepositsToggled(alice, true);
    automatedDeposits.setAutomatedDepositsEnabled(true);

    // Verify it's enabled
    assertTrue(automatedDeposits.isAutomatedDepositsEnabled(alice));

    // Alice disables automated deposits
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ISavingCirclesAutomatedDeposits.AutomatedDepositsToggled(alice, false);
    automatedDeposits.setAutomatedDepositsEnabled(false);

    // Verify it's disabled
    assertFalse(automatedDeposits.isAutomatedDepositsEnabled(alice));
  }

  function test_DepositIfAllowed_WithSufficientAllowance() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to automated deposits
    vm.prank(alice);
    automatedDeposits.setAutomatedDepositsEnabled(true);

    // Alice approves the extension contract (not main contract)
    vm.prank(alice);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);

    // Anyone can call depositIfAllowed for alice
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);
    automatedDeposits.depositIfAllowed(baseCircleId, alice);

    // Verify deposit was recorded in main contract
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositIfAllowed_NotOptedIn() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice approves but does NOT opt in
    vm.prank(alice);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);

    // Should revert because alice hasn't opted in
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCirclesAutomatedDeposits.AutomatedDepositsNotEnabled.selector));
    automatedDeposits.depositIfAllowed(baseCircleId, alice);
  }

  function test_DepositIfAllowed_WithInsufficientAllowance() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to automated deposits
    vm.prank(alice);
    automatedDeposits.setAutomatedDepositsEnabled(true);

    // Alice approves less than required amount
    vm.prank(alice);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT / 2);

    // Call should revert with InsufficientAllowance
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCirclesAutomatedDeposits.InsufficientAllowance.selector));
    automatedDeposits.depositIfAllowed(baseCircleId, alice);
  }

  function test_DepositIfAllowed_WhenAlreadyDeposited() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT * 2);

    // Alice opts in to automated deposits
    vm.prank(alice);
    automatedDeposits.setAutomatedDepositsEnabled(true);

    // Alice makes a regular deposit first directly to main contract
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.depositFor(baseCircleId, DEPOSIT_AMOUNT, alice);
    vm.stopPrank();

    // Approve extension for another deposit attempt
    vm.prank(alice);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);

    // Call depositIfAllowed - should revert with AlreadyDeposited
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyDeposited.selector));
    automatedDeposits.depositIfAllowed(baseCircleId, alice);

    // Balance should remain the same
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositIfAllowed_PartialDeposit() external {
    // Alice makes a partial deposit first
    uint256 partialAmount = DEPOSIT_AMOUNT / 2;
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to automated deposits
    vm.prank(alice);
    automatedDeposits.setAutomatedDepositsEnabled(true);

    // Make partial deposit directly to main contract
    vm.startPrank(alice);
    token.approve(address(savingCircles), partialAmount);
    savingCircles.depositFor(baseCircleId, partialAmount, alice);
    vm.stopPrank();

    // Approve extension for remaining amount
    vm.prank(alice);
    token.approve(address(automatedDeposits), partialAmount);

    // Now call depositIfAllowed to complete the deposit
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, partialAmount);
    automatedDeposits.depositIfAllowed(baseCircleId, alice);

    // Verify full deposit amount
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositIfAllowed_NotMember() external {
    address nonMember = makeAddr('nonMember');
    token.mint(nonMember, DEPOSIT_AMOUNT);

    // Non-member opts in and approves
    vm.startPrank(nonMember);
    automatedDeposits.setAutomatedDepositsEnabled(true);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    automatedDeposits.depositIfAllowed(baseCircleId, nonMember);
  }

  function test_BatchDepositIfAllowed() external {
    // Setup tokens and approvals for all members
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.mint(carol, DEPOSIT_AMOUNT);

    // All users opt in and approve full amount to extension
    vm.startPrank(alice);
    automatedDeposits.setAutomatedDepositsEnabled(true);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    automatedDeposits.setAutomatedDepositsEnabled(true);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    automatedDeposits.setAutomatedDepositsEnabled(true);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Batch deposit - same circle for all members
    uint256[] memory circleIds = new uint256[](3);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;
    circleIds[2] = baseCircleId;

    address[] memory membersToDeposit = new address[](3);
    membersToDeposit[0] = alice;
    membersToDeposit[1] = bob;
    membersToDeposit[2] = carol;

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, bob, DEPOSIT_AMOUNT);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, carol, DEPOSIT_AMOUNT);
    automatedDeposits.batchDepositIfAllowed(circleIds, membersToDeposit);

    // Verify all deposits succeeded
    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, bob), DEPOSIT_AMOUNT);
    assertEq(savingCircles.balances(baseCircleId, carol), DEPOSIT_AMOUNT);
  }

  function test_BatchDepositIfAllowed_FailsOnInsufficientAllowance() external {
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);

    // Alice opts in and approves full amount
    vm.startPrank(alice);
    automatedDeposits.setAutomatedDepositsEnabled(true);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Bob opts in but only approves partial amount
    vm.startPrank(bob);
    automatedDeposits.setAutomatedDepositsEnabled(true);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT / 2);
    vm.stopPrank();

    // Batch deposit - should fail on bob's insufficient allowance
    uint256[] memory circleIds = new uint256[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;

    address[] memory membersToDeposit = new address[](2);
    membersToDeposit[0] = alice;
    membersToDeposit[1] = bob;

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ISavingCirclesAutomatedDeposits.InsufficientAllowance.selector));
    automatedDeposits.batchDepositIfAllowed(circleIds, membersToDeposit);

    // Verify no deposits went through (all-or-nothing)
    assertEq(savingCircles.balances(baseCircleId, alice), 0);
    assertEq(savingCircles.balances(baseCircleId, bob), 0);
  }

  function test_GetEligibleAddressesForDeposit() external {
    // Setup: Alice opts in and approves, Bob opts in but doesn't approve, Carol doesn't opt in
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.mint(carol, DEPOSIT_AMOUNT);

    // Alice opts in and approves
    vm.startPrank(alice);
    automatedDeposits.setAutomatedDepositsEnabled(true);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Bob opts in but doesn't approve
    vm.prank(bob);
    automatedDeposits.setAutomatedDepositsEnabled(true);

    // Carol approves but doesn't opt in
    vm.prank(carol);
    token.approve(address(automatedDeposits), DEPOSIT_AMOUNT);

    // Get eligible addresses
    (uint256[] memory circleIds, address[] memory eligibleMembers) = automatedDeposits.getEligibleAddressesForDeposit();

    // Only alice should be eligible (opted in AND has allowance)
    assertEq(eligibleMembers.length, 1);
    assertEq(circleIds.length, 1);
    assertEq(eligibleMembers[0], alice);
    assertEq(circleIds[0], baseCircleId);
  }

  function test_BatchDepositIfAllowed_ArrayLengthMismatch() external {
    uint256[] memory circleIds = new uint256[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;

    address[] memory membersToDeposit = new address[](3);
    membersToDeposit[0] = alice;
    membersToDeposit[1] = bob;
    membersToDeposit[2] = carol;

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ISavingCirclesAutomatedDeposits.ArrayLengthMismatch.selector));
    automatedDeposits.batchDepositIfAllowed(circleIds, membersToDeposit);
  }
}
