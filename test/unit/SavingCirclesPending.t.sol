// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {MockERC20} from '../mocks/MockERC20.sol';
import {ISavingCircles, SavingCircles} from 'contracts/SavingCircles.sol';

contract SavingCirclesPendingUnit is Test {
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;
  uint256 public constant MAX_DEPOSITS = 30;

  SavingCircles public savingCircles;
  MockERC20 public token;

  // Test addresses
  address public owner;
  address public alice;
  address public bob;
  address public carol;

  // Test emails
  string constant ALICE_EMAIL = "alice@example.com";
  string constant BOB_EMAIL = "bob@example.com";
  string constant CAROL_EMAIL = "carol@example.com";

  // Test data
  string[] public memberEmails;
  ISavingCircles.PendingCircle public basePendingCircle;

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

    // Deploy and setup token
    token = new MockERC20('Test Token', 'TEST');
    savingCircles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    // Setup member emails
    memberEmails.push(ALICE_EMAIL);
    memberEmails.push(BOB_EMAIL);
    memberEmails.push(CAROL_EMAIL);

    // Setup base pending circle
    basePendingCircle = ISavingCircles.PendingCircle({
      ownerEmail: ALICE_EMAIL,
      memberEmails: memberEmails,
      depositAmount: DEPOSIT_AMOUNT,
      token: address(token),
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: MAX_DEPOSITS,
      isActive: false // Will be set to true by the contract
    });
  }

  function test_CreatePendingCircle() public {
    uint256 pendingId = savingCircles.createPendingCircle(basePendingCircle);
    
    ISavingCircles.PendingCircle memory retrievedCircle = savingCircles.getPendingCircle(pendingId);
    
    assertEq(retrievedCircle.ownerEmail, ALICE_EMAIL);
    assertEq(retrievedCircle.memberEmails.length, 3);
    assertEq(retrievedCircle.memberEmails[0], ALICE_EMAIL);
    assertEq(retrievedCircle.memberEmails[1], BOB_EMAIL);
    assertEq(retrievedCircle.memberEmails[2], CAROL_EMAIL);
    assertEq(retrievedCircle.depositAmount, DEPOSIT_AMOUNT);
    assertEq(retrievedCircle.token, address(token));
    assertEq(retrievedCircle.depositInterval, DEPOSIT_INTERVAL);
    assertEq(retrievedCircle.maxDeposits, MAX_DEPOSITS);
    assertTrue(retrievedCircle.isActive);
  }

  function test_MapEmailToAddress() public {
    // Map emails to addresses
    savingCircles.mapEmailToAddress(ALICE_EMAIL, alice);
    savingCircles.mapEmailToAddress(BOB_EMAIL, bob);
    savingCircles.mapEmailToAddress(CAROL_EMAIL, carol);
    
    // Check mappings
    assertEq(savingCircles.getAddressFromEmail(ALICE_EMAIL), alice);
    assertEq(savingCircles.getAddressFromEmail(BOB_EMAIL), bob);
    assertEq(savingCircles.getAddressFromEmail(CAROL_EMAIL), carol);
  }

  function test_MigratePendingCircle() public {
    // Create pending circle
    uint256 pendingId = savingCircles.createPendingCircle(basePendingCircle);
    
    // Map emails to addresses
    savingCircles.mapEmailToAddress(ALICE_EMAIL, alice);
    savingCircles.mapEmailToAddress(BOB_EMAIL, bob);
    savingCircles.mapEmailToAddress(CAROL_EMAIL, carol);
    
    // Migrate to on-chain circle
    uint256 circleStart = block.timestamp + 1 days;
    uint256 circleId = savingCircles.migratePendingCircle(pendingId, circleStart);
    
    // Verify the on-chain circle was created correctly
    ISavingCircles.Circle memory circle = savingCircles.getCircle(circleId);
    
    assertEq(circle.owner, alice);
    assertEq(circle.members.length, 3);
    assertEq(circle.members[0], alice);
    assertEq(circle.members[1], bob);
    assertEq(circle.members[2], carol);
    assertEq(circle.currentIndex, 0);
    assertEq(circle.depositAmount, DEPOSIT_AMOUNT);
    assertEq(circle.token, address(token));
    assertEq(circle.depositInterval, DEPOSIT_INTERVAL);
    assertEq(circle.circleStart, circleStart);
    assertEq(circle.maxDeposits, MAX_DEPOSITS);
  }

  function test_RevertWhen_CreatePendingCircleWithInvalidToken() public {
    MockERC20 invalidToken = new MockERC20('Invalid', 'INV');
    basePendingCircle.token = address(invalidToken);
    
    vm.expectRevert(ISavingCircles.TokenNotAllowed.selector);
    savingCircles.createPendingCircle(basePendingCircle);
  }

  function test_RevertWhen_CreatePendingCircleWithInvalidEmail() public {
    basePendingCircle.ownerEmail = "";
    
    vm.expectRevert(ISavingCircles.InvalidEmail.selector);
    savingCircles.createPendingCircle(basePendingCircle);
  }

  function test_RevertWhen_MigrateWithUnmappedEmail() public {
    // Create pending circle
    uint256 pendingId = savingCircles.createPendingCircle(basePendingCircle);
    
    // Only map some emails (missing carol)
    savingCircles.mapEmailToAddress(ALICE_EMAIL, alice);
    savingCircles.mapEmailToAddress(BOB_EMAIL, bob);
    
    // Try to migrate - should fail because carol's email is not mapped
    uint256 circleStart = block.timestamp + 1 days;
    vm.expectRevert(ISavingCircles.EmailNotMapped.selector);
    savingCircles.migratePendingCircle(pendingId, circleStart);
  }

  function test_RevertWhen_GetInactivePendingCircle() public {
    // Create and migrate a pending circle
    uint256 pendingId = savingCircles.createPendingCircle(basePendingCircle);
    
    savingCircles.mapEmailToAddress(ALICE_EMAIL, alice);
    savingCircles.mapEmailToAddress(BOB_EMAIL, bob);
    savingCircles.mapEmailToAddress(CAROL_EMAIL, carol);
    
    uint256 circleStart = block.timestamp + 1 days;
    savingCircles.migratePendingCircle(pendingId, circleStart);
    
    // Try to get the pending circle after migration - should fail
    vm.expectRevert(ISavingCircles.PendingCircleNotFound.selector);
    savingCircles.getPendingCircle(pendingId);
  }
}