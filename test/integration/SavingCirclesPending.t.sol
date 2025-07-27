// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {IntegrationBase} from 'test/integration/IntegrationBase.sol';

contract SavingCirclesPendingIntegration is IntegrationBase {
  string constant ALICE_EMAIL = "alice@example.com";
  string constant BOB_EMAIL = "bob@example.com";
  string constant CAROL_EMAIL = "carol@example.com";

  string[] public memberEmails;
  ISavingCircles.PendingCircle public pendingCircle;

  function setUp() public override {
    super.setUp();
    
    // Setup member emails
    memberEmails.push(ALICE_EMAIL);
    memberEmails.push(BOB_EMAIL);
    memberEmails.push(CAROL_EMAIL);

    // Setup pending circle
    pendingCircle = ISavingCircles.PendingCircle({
      ownerEmail: ALICE_EMAIL,
      memberEmails: memberEmails,
      depositAmount: DEPOSIT_AMOUNT,
      token: address(token),
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: BASE_MAX_DEPOSITS,
      isActive: false
    });
  }

  function test_EndToEndOffChainToOnChainFlow() public {
    // Step 1: Enable token
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    // Step 2: Create pending circle with emails
    uint256 pendingId = circle.createPendingCircle(pendingCircle);
    
    // Verify pending circle was created
    ISavingCircles.PendingCircle memory retrievedPending = circle.getPendingCircle(pendingId);
    assertEq(retrievedPending.ownerEmail, ALICE_EMAIL);
    assertTrue(retrievedPending.isActive);

    // Step 3: Map emails to wallet addresses (simulating user onboarding)
    circle.mapEmailToAddress(ALICE_EMAIL, alice);
    circle.mapEmailToAddress(BOB_EMAIL, bob);
    circle.mapEmailToAddress(CAROL_EMAIL, carol);

    // Verify mappings
    assertEq(circle.getAddressFromEmail(ALICE_EMAIL), alice);
    assertEq(circle.getAddressFromEmail(BOB_EMAIL), bob);
    assertEq(circle.getAddressFromEmail(CAROL_EMAIL), carol);

    // Step 4: Migrate pending circle to active on-chain circle
    uint256 circleStart = block.timestamp + 1 days;
    uint256 circleId = circle.migratePendingCircle(pendingId, circleStart);

    // Verify on-chain circle was created
    ISavingCircles.Circle memory activeCircle = circle.getCircle(circleId);
    assertEq(activeCircle.owner, alice);
    assertEq(activeCircle.members.length, 3);
    assertEq(activeCircle.circleStart, circleStart);

    // Step 5: Verify pending circle is now inactive
    vm.expectRevert(ISavingCircles.PendingCircleNotFound.selector);
    circle.getPendingCircle(pendingId);

    // Step 6: Verify the on-chain circle functions normally
    // Fast forward to circle start
    vm.warp(circleStart);

    // Members can now deposit
    vm.prank(alice);
    circle.deposit(circleId, DEPOSIT_AMOUNT);

    vm.prank(bob);
    circle.deposit(circleId, DEPOSIT_AMOUNT);

    vm.prank(carol);
    circle.deposit(circleId, DEPOSIT_AMOUNT);

    // Verify deposits
    (address[] memory circleMembers, uint256[] memory memberBalances) = circle.getMemberBalances(circleId);
    assertEq(memberBalances[0], DEPOSIT_AMOUNT); // alice
    assertEq(memberBalances[1], DEPOSIT_AMOUNT); // bob
    assertEq(memberBalances[2], DEPOSIT_AMOUNT); // carol

    // First member should be able to withdraw
    assertTrue(circle.isWithdrawable(circleId));
    assertEq(circle.withdrawableBy(circleId), alice);

    vm.prank(alice);
    circle.withdraw(circleId);

    // Verify withdrawal
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT * 3 + DEPOSIT_AMOUNT * 7); // Initial + withdrawal
  }

  function test_EmitCorrectEvents() public {
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    // Test PendingCircleCreated event
    vm.expectEmit(true, false, false, true);
    emit ISavingCircles.PendingCircleCreated(
      0, // first pending circle ID
      ALICE_EMAIL,
      memberEmails,
      address(token),
      DEPOSIT_AMOUNT,
      DEPOSIT_INTERVAL
    );
    uint256 pendingId = circle.createPendingCircle(pendingCircle);

    // Test EmailMapped events
    vm.expectEmit(true, true, false, true);
    emit ISavingCircles.EmailMapped(ALICE_EMAIL, alice);
    circle.mapEmailToAddress(ALICE_EMAIL, alice);

    circle.mapEmailToAddress(BOB_EMAIL, bob);
    circle.mapEmailToAddress(CAROL_EMAIL, carol);

    // Test CircleMigrated event
    uint256 circleStart = block.timestamp + 1 days;
    vm.expectEmit(true, true, false, true);
    emit ISavingCircles.CircleMigrated(pendingId, 0); // first circle ID will be 0
    circle.migratePendingCircle(pendingId, circleStart);
  }
}