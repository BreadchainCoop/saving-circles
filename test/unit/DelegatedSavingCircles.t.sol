// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DelegatedSavingCircles} from '../../src/contracts/DelegatedSavingCircles.sol';
import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {IDelegatedSavingCircles} from '../../src/interfaces/IDelegatedSavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {SavingCirclesTestBase} from '../utils/SavingCirclesTestBase.t.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

contract DelegatedSavingCirclesUnit is SavingCirclesTestBase {
  SavingCircles public savingCircles;
  DelegatedSavingCircles public delegatedSavingCircles;
  MockERC20 public token;
  ProxyAdmin public proxyAdmin;

  address public owner = makeAddr('owner');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  uint256 internal ownerPrivateKey;
  uint256 internal alicePrivateKey;
  uint256 internal bobPrivateKey;
  uint256 internal carolPrivateKey;

  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 weeks;
  uint256 public constant MAX_DEPOSITS = 3;

  uint256 public baseCircleId;
  ISavingCircles.Circle public baseCircle;
  address[] public members;

  function setUp() external {
    // Deploy token
    token = new MockERC20('Test Token', 'TEST');

    (owner, ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, alicePrivateKey) = makeAddrAndKey('alice');
    (bob, bobPrivateKey) = makeAddrAndKey('bob');
    (carol, carolPrivateKey) = makeAddrAndKey('carol');

    // Deploy main SavingCircles contract
    proxyAdmin = new ProxyAdmin(owner);
    SavingCircles implementation = new SavingCircles();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation), address(proxyAdmin), abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
    );
    savingCircles = SavingCircles(address(proxy));

    // Deploy delegated deposits extension
    delegatedSavingCircles = new DelegatedSavingCircles(address(savingCircles));

    // Setup members
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    // Allow token
    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);

    // Create base circle
    baseCircle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));

    baseCircleId = _createCircleWithMembers(savingCircles, baseCircle, members, alicePrivateKey);
  }

  function test_SetDelegatedDepositsEnabled() external {
    // Check initial state is disabled
    assertFalse(delegatedSavingCircles.isDelegatedDepositsEnabled(alice));

    // Alice enables delegated deposits
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IDelegatedSavingCircles.DelegatedDepositsToggled(alice, true);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);

    // Verify it's enabled
    assertTrue(delegatedSavingCircles.isDelegatedDepositsEnabled(alice));

    // Alice disables delegated deposits
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IDelegatedSavingCircles.DelegatedDepositsToggled(alice, false);
    delegatedSavingCircles.setDelegatedDepositsEnabled(false);

    // Verify it's disabled
    assertFalse(delegatedSavingCircles.isDelegatedDepositsEnabled(alice));
  }

  function test_DepositIfAllowed_WithSufficientAllowance() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to delegated deposits
    vm.prank(alice);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);

    // Alice approves the extension contract (not main contract)
    vm.prank(alice);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);

    // Anyone can call depositIfAllowed for alice
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);
    delegatedSavingCircles.depositIfAllowed(baseCircleId, alice);

    // Verify deposit was recorded in main contract
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositIfAllowed_NotOptedIn() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice approves but does NOT opt in
    vm.prank(alice);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);

    // Should revert because alice hasn't opted in
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IDelegatedSavingCircles.DelegatedDepositsNotEnabled.selector));
    delegatedSavingCircles.depositIfAllowed(baseCircleId, alice);
  }

  function test_DepositIfAllowed_WithInsufficientAllowance() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to delegated deposits
    vm.prank(alice);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);

    // Alice approves less than required amount
    vm.prank(alice);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT / 2);

    // Call should revert with InsufficientAllowance
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IDelegatedSavingCircles.InsufficientAllowance.selector));
    delegatedSavingCircles.depositIfAllowed(baseCircleId, alice);
  }

  function test_DepositIfAllowed_WhenAlreadyDeposited() external {
    // Mint tokens to alice
    token.mint(alice, DEPOSIT_AMOUNT * 2);

    // Alice opts in to delegated deposits
    vm.prank(alice);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);

    // Alice makes a regular deposit first directly to main contract
    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.depositFor(baseCircleId, DEPOSIT_AMOUNT, alice);
    vm.stopPrank();

    // Approve extension for another deposit attempt
    vm.prank(alice);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);

    // Call depositIfAllowed - should revert with AlreadyDeposited
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyDeposited.selector));
    delegatedSavingCircles.depositIfAllowed(baseCircleId, alice);

    // Balance should remain the same
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositIfAllowed_PartialDeposit() external {
    // Alice makes a partial deposit first
    uint256 partialAmount = DEPOSIT_AMOUNT / 2;
    token.mint(alice, DEPOSIT_AMOUNT);

    // Alice opts in to delegated deposits
    vm.prank(alice);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);

    // Make partial deposit directly to main contract
    vm.startPrank(alice);
    token.approve(address(savingCircles), partialAmount);
    savingCircles.depositFor(baseCircleId, partialAmount, alice);
    vm.stopPrank();

    // Approve extension for remaining amount
    vm.prank(alice);
    token.approve(address(delegatedSavingCircles), partialAmount);

    // Now call depositIfAllowed to complete the deposit
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, partialAmount);
    delegatedSavingCircles.depositIfAllowed(baseCircleId, alice);

    // Verify full deposit amount
    uint256 balance = savingCircles.balances(baseCircleId, alice);
    assertEq(balance, DEPOSIT_AMOUNT);
  }

  function test_DepositIfAllowed_NotMember() external {
    address nonMember = makeAddr('nonMember');
    token.mint(nonMember, DEPOSIT_AMOUNT);

    // Non-member opts in and approves
    vm.startPrank(nonMember);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    delegatedSavingCircles.depositIfAllowed(baseCircleId, nonMember);
  }

  function test_BatchDepositIfAllowed() external {
    // Setup tokens and approvals for all members
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.mint(carol, DEPOSIT_AMOUNT);

    // All users opt in and approve full amount to extension
    vm.startPrank(alice);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(bob);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.startPrank(carol);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);
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
    delegatedSavingCircles.batchDepositIfAllowed(circleIds, membersToDeposit);

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
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Bob opts in but only approves partial amount
    vm.startPrank(bob);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT / 2);
    vm.stopPrank();

    // Batch deposit - should fail on bob's insufficient allowance
    uint256[] memory circleIds = new uint256[](2);
    circleIds[0] = baseCircleId;
    circleIds[1] = baseCircleId;

    address[] memory membersToDeposit = new address[](2);
    membersToDeposit[0] = alice;
    membersToDeposit[1] = bob;

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(IDelegatedSavingCircles.InsufficientAllowance.selector));
    delegatedSavingCircles.batchDepositIfAllowed(circleIds, membersToDeposit);

    // Verify no deposits went through (all-or-nothing)
    assertEq(savingCircles.balances(baseCircleId, alice), 0);
    assertEq(savingCircles.balances(baseCircleId, bob), 0);
  }

  function test_GetAddressesForDeposit() external {
    // Setup: Alice opts in and approves, Bob opts in but doesn't approve, Carol doesn't opt in
    token.mint(alice, DEPOSIT_AMOUNT);
    token.mint(bob, DEPOSIT_AMOUNT);
    token.mint(carol, DEPOSIT_AMOUNT);

    // Alice opts in and approves
    vm.startPrank(alice);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);
    vm.stopPrank();

    // Bob opts in but doesn't approve
    vm.prank(bob);
    delegatedSavingCircles.setDelegatedDepositsEnabled(true);

    // Carol approves but doesn't opt in
    vm.prank(carol);
    token.approve(address(delegatedSavingCircles), DEPOSIT_AMOUNT);

    // Get eligible addresses
    (uint256[] memory circleIds, address[] memory eligibleMembers) = delegatedSavingCircles.getAddressesForDeposit();

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
    vm.expectRevert(abi.encodeWithSelector(IDelegatedSavingCircles.ArrayLengthMismatch.selector));
    delegatedSavingCircles.batchDepositIfAllowed(circleIds, membersToDeposit);
  }
}
