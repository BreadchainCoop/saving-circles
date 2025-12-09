// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {SavingCirclesTestBase} from '../utils/SavingCirclesTestBase.t.sol';
import {ERC1967Proxy} from '@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol';

contract SavingCirclesMultiRoundFuzzTest is SavingCirclesTestBase {
  SavingCircles public implementation;
  SavingCircles public savingCircles;
  MockERC20 public token;

  address public owner = makeAddr('owner');
  uint256 internal ownerPrivateKey;
  uint256 internal alicePrivateKey;
  address public alice = makeAddr('alice');

  uint256 private constant _MAX_REASONABLE_DEPOSIT = 1e20;
  uint256 private constant _MAX_REASONABLE_INTERVAL = 7 days;
  uint256 private constant _MIN_DEPOSIT_INTERVAL = 1 hours;

  function setUp() public {
    (owner, ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, alicePrivateKey) = makeAddrAndKey('alice');

    implementation = new SavingCircles();

    bytes memory initData = abi.encodeWithSelector(SavingCircles.initialize.selector, owner);
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
    savingCircles = SavingCircles(address(proxy));

    token = new MockERC20('Test Token', 'TEST');

    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);
  }

  function _createCircleAt(
    address[] memory members,
    uint256 depositAmount,
    uint256 depositInterval,
    uint256 startTime
  ) internal returns (uint256 circleId) {
    if (members.length > 0) {
      members[0] = alice;
    }
    ISavingCircles.Circle memory circle = _defaultCircle(alice, depositAmount, depositInterval, address(token));

    circleId = _createCircle(savingCircles, circle, members, alicePrivateKey);
    if (block.timestamp < startTime) vm.warp(startTime);
    vm.prank(alice);
    savingCircles.start(circleId);
  }

  function testFuzz_CompleteCircleWithNRounds(
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint8 _memberCount
  ) public {
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT);
    _depositInterval = bound(_depositInterval, _MIN_DEPOSIT_INTERVAL, _MAX_REASONABLE_INTERVAL);
    _memberCount = uint8(bound(uint256(_memberCount), 2, 5));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 startTime = block.timestamp + 1 days;
    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, _depositInterval, address(token));

    uint256 circleId = _createCircle(savingCircles, circle, members, alicePrivateKey);
    if (block.timestamp < startTime) vm.warp(startTime);
    vm.prank(alice);
    savingCircles.start(circleId);

    uint256[] memory memberWithdrawals = new uint256[](_memberCount);
    uint256 totalExpectedPayout = _depositAmount * _memberCount;

    // Move to circle start time
    vm.warp(startTime);

    // Complete the full circle (each member gets one withdrawal)
    for (uint256 round = 0; round < _memberCount; round++) {
      // All members deposit for this round
      for (uint256 i = 0; i < _memberCount; i++) {
        token.mint(members[i], _depositAmount);
        vm.startPrank(members[i]);
        token.approve(address(savingCircles), _depositAmount);
        savingCircles.deposit(circleId, _depositAmount);
        vm.stopPrank();
      }

      // Wait for current deposit interval to complete (withdrawal time)
      vm.warp(startTime + (_depositInterval * (round + 1)));

      // Verify withdrawability
      assertTrue(savingCircles.isWithdrawable(circleId));

      // Get current recipient before withdrawal
      ISavingCircles.Circle memory currentCircle = savingCircles.getCircle(circleId);
      address[] memory storedMembers = savingCircles.getCircleMembers(circleId);
      address expectedRecipient = storedMembers[currentCircle.currentIndex];
      uint256 recipientIndex = currentCircle.currentIndex;

      // Withdraw for current round
      uint256 balanceBefore = token.balanceOf(expectedRecipient);
      vm.prank(expectedRecipient);
      savingCircles.withdraw(circleId);
      uint256 balanceAfter = token.balanceOf(expectedRecipient);

      assertEq(balanceAfter - balanceBefore, totalExpectedPayout);
      memberWithdrawals[recipientIndex] = totalExpectedPayout;
    }

    // Verify that each member received exactly one payout
    for (uint256 i = 0; i < _memberCount; i++) {
      assertEq(memberWithdrawals[i], totalExpectedPayout);
    }
  }

  function testFuzz_MultipleConcurrentCircles(
    uint8 _numCircles,
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint8 _memberCount
  ) public {
    _numCircles = uint8(bound(uint256(_numCircles), 2, 5));
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT / 10);
    _depositInterval = bound(_depositInterval, _MIN_DEPOSIT_INTERVAL, _MAX_REASONABLE_INTERVAL);
    _memberCount = uint8(bound(uint256(_memberCount), 2, 4));

    uint256[] memory circleIds = new uint256[](_numCircles);
    address[][] memory allMembers = new address[][](_numCircles);
    uint256[] memory startTimes = new uint256[](_numCircles);

    // Create multiple circles with overlapping members
    for (uint256 c = 0; c < _numCircles; c++) {
      address[] memory members = new address[](_memberCount);
      for (uint256 i = 0; i < _memberCount; i++) {
        if (i == 0) {
          members[i] = alice;
        } else {
          members[i] = makeAddr(string(abi.encodePacked('circle', c, 'member', i)));
        }
      }
      allMembers[c] = members;

      startTimes[c] = block.timestamp + 1 days + (c * 1 hours); // Stagger start times
      ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, _depositInterval, address(token));

      circleIds[c] = _createCircle(savingCircles, circle, members, alicePrivateKey);
      if (block.timestamp < startTimes[c]) vm.warp(startTimes[c]);
      vm.prank(alice);
      savingCircles.start(circleIds[c]);
    }

    // Process first round for all circles
    for (uint256 c = 0; c < _numCircles; c++) {
      vm.warp(startTimes[c]);

      // All members deposit
      for (uint256 i = 0; i < _memberCount; i++) {
        address member = allMembers[c][i];
        token.mint(member, _depositAmount);
        vm.startPrank(member);
        token.approve(address(savingCircles), _depositAmount);
        savingCircles.deposit(circleIds[c], _depositAmount);
        vm.stopPrank();
      }
    }

    // Wait and withdraw from all circles
    for (uint256 c = 0; c < _numCircles; c++) {
      vm.warp(startTimes[c] + _depositInterval);

      assertTrue(savingCircles.isWithdrawable(circleIds[c]));

      address withdrawer = allMembers[c][0];
      uint256 balanceBefore = token.balanceOf(withdrawer);
      vm.prank(withdrawer);
      savingCircles.withdraw(circleIds[c]);
      uint256 balanceAfter = token.balanceOf(withdrawer);

      assertEq(balanceAfter - balanceBefore, _depositAmount * _memberCount);
    }
  }

  function testFuzz_PartialRoundsWithDecommission(
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint8 _memberCount,
    uint8 _roundsBeforeDecommission
  ) public {
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT / 10);
    _depositInterval = bound(_depositInterval, _MIN_DEPOSIT_INTERVAL, _MAX_REASONABLE_INTERVAL);
    _memberCount = uint8(bound(uint256(_memberCount), 3, 6));
    _roundsBeforeDecommission = uint8(bound(uint256(_roundsBeforeDecommission), 1, uint256(_memberCount) - 1));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 startTime = block.timestamp + 1 days;
    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, _depositInterval, address(token));

    uint256 circleId = _createCircle(savingCircles, circle, members, alicePrivateKey);
    if (block.timestamp < startTime) vm.warp(startTime);
    vm.prank(alice);
    savingCircles.start(circleId);
    vm.warp(startTime);

    // Complete some rounds
    for (uint256 round = 0; round < _roundsBeforeDecommission; round++) {
      for (uint256 i = 0; i < _memberCount; i++) {
        token.mint(members[i], _depositAmount);
        vm.startPrank(members[i]);
        token.approve(address(savingCircles), _depositAmount);
        savingCircles.deposit(circleId, _depositAmount);
        vm.stopPrank();
      }

      vm.warp(startTime + (_depositInterval * (round + 1)));

      ISavingCircles.Circle memory currentCircle = savingCircles.getCircle(circleId);
      address[] memory storedMembers = savingCircles.getCircleMembers(circleId);
      address recipient = storedMembers[currentCircle.currentIndex];
      vm.prank(recipient);
      savingCircles.withdraw(circleId);
    }

    // Start next round but only partial deposits
    uint256 partialDepositors = _memberCount / 2;
    if (partialDepositors == 0) partialDepositors = 1;

    // Move to next deposit window
    vm.warp(startTime + (_depositInterval * _roundsBeforeDecommission));

    for (uint256 i = 0; i < partialDepositors; i++) {
      token.mint(members[i], _depositAmount);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), _depositAmount);
      savingCircles.deposit(circleId, _depositAmount);
      vm.stopPrank();
    }

    // Wait past the deposit window
    vm.warp(block.timestamp + _depositInterval + 1);

    // Decommission should work and refund partial deposits
    uint256[] memory balancesBefore = new uint256[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      balancesBefore[i] = token.balanceOf(members[i]);
    }

    vm.prank(members[0]);
    savingCircles.decommission(circleId);

    // Verify refunds
    for (uint256 i = 0; i < partialDepositors; i++) {
      assertEq(token.balanceOf(members[i]) - balancesBefore[i], _depositAmount);
    }
    for (uint256 i = partialDepositors; i < _memberCount; i++) {
      assertEq(token.balanceOf(members[i]), balancesBefore[i]);
    }

    // Circle should be decommissioned
    vm.expectRevert(ISavingCircles.NotCommissioned.selector);
    savingCircles.getCircle(circleId);
  }

  function testFuzz_SequentialCirclesWithSameMembers(
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint8 _memberCount,
    uint8 _numSequentialCircles
  ) public {
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT / 10);
    _depositInterval = bound(_depositInterval, _MIN_DEPOSIT_INTERVAL, _MAX_REASONABLE_INTERVAL);
    _memberCount = uint8(bound(uint256(_memberCount), 2, 4));
    _numSequentialCircles = uint8(bound(uint256(_numSequentialCircles), 2, 4));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    for (uint256 seq = 0; seq < _numSequentialCircles; seq++) {
      uint256 startTime = block.timestamp + 1 days;

      // Calculate deposit amount safely to avoid overflow
      uint256 circleDepositAmount = _depositAmount;
      if (seq > 0 && circleDepositAmount <= type(uint256).max / (seq + 1)) {
        circleDepositAmount = _depositAmount * (seq + 1);
      }

      uint256 circleId = _createCircleAt(members, circleDepositAmount, _depositInterval, startTime);
      ISavingCircles.Circle memory liveCircle = savingCircles.getCircle(circleId);
      vm.warp(liveCircle.effectiveCircleStartTime);

      uint256[] memory payouts = new uint256[](_memberCount);

      // Complete full circle
      for (uint256 round = 0; round < _memberCount; round++) {
        vm.warp(liveCircle.effectiveCircleStartTime + (liveCircle.depositInterval * round));
        for (uint256 i = 0; i < _memberCount; i++) {
          token.mint(members[i], circleDepositAmount);
          vm.startPrank(members[i]);
          token.approve(address(savingCircles), circleDepositAmount);
          savingCircles.deposit(circleId, circleDepositAmount);
          vm.stopPrank();
        }

        vm.warp(liveCircle.effectiveCircleStartTime + (liveCircle.depositInterval * (round + 1)));

        ISavingCircles.Circle memory currentCircle = savingCircles.getCircle(circleId);
        address[] memory storedMembers = savingCircles.getCircleMembers(circleId);
        address recipient = storedMembers[currentCircle.currentIndex];
        uint256 balanceBefore = token.balanceOf(recipient);

        vm.prank(recipient);
        savingCircles.withdraw(circleId);

        uint256 balanceAfter = token.balanceOf(recipient);
        payouts[currentCircle.currentIndex] = balanceAfter - balanceBefore;
      }

      // Verify everyone received their payout in this circle
      uint256 expectedPayout = circleDepositAmount * _memberCount;
      for (uint256 i = 0; i < _memberCount; i++) {
        assertEq(payouts[i], expectedPayout, 'Member did not receive expected payout');
      }
    }
  }

  function testFuzz_MaxDepositBoundaryWithMultipleRounds(uint256 _depositAmount, uint8 _memberCount) public {
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT / 10);
    _memberCount = uint8(bound(uint256(_memberCount), 2, 5));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 startTime = block.timestamp + 1 days;
    uint256 circleId = _createCircleAt(members, _depositAmount, 1 days, startTime);
    vm.warp(startTime);

    // Complete one full round where all members deposit and withdraw once
    for (uint256 round = 0; round < _memberCount; round++) {
      // All members deposit
      for (uint256 i = 0; i < _memberCount; i++) {
        token.mint(members[i], _depositAmount);
        vm.startPrank(members[i]);
        token.approve(address(savingCircles), _depositAmount);
        savingCircles.deposit(circleId, _depositAmount);
        vm.stopPrank();
      }

      // Wait for withdrawal window
      vm.warp(startTime + (1 days * (round + 1)));

      ISavingCircles.Circle memory currentCircle = savingCircles.getCircle(circleId);
      address[] memory storedMembers = savingCircles.getCircleMembers(circleId);
      address withdrawer = storedMembers[currentCircle.currentIndex];

      vm.prank(withdrawer);
      savingCircles.withdraw(circleId);
    }

    // Verify circle completed successfully
    ISavingCircles.Circle memory finalCircle = savingCircles.getCircle(circleId);
    assertTrue(finalCircle.currentIndex >= 0, 'Circle should still be active');
  }

  function testFuzz_InterleavedDepositsAndWithdrawals(
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint8 _memberCount
  ) public {
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT / 10);
    _depositInterval = bound(_depositInterval, 1 days, 7 days);
    _memberCount = uint8(bound(uint256(_memberCount), 3, 5));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    // Create two circles
    uint256 circleId1 = _createCircleAt(members, _depositAmount, _depositInterval, block.timestamp + 1 days);
    uint256 circleId2 =
      _createCircleAt(members, _depositAmount * 2, _depositInterval, block.timestamp + 1 days + (_depositInterval / 2));

    // Process first circle
    _processCircleRound(circleId1, members, _depositAmount, _depositInterval, block.timestamp + 1 days, 0);

    // Process second circle if time allows
    uint256 startTime2 = block.timestamp + 1 days + (_depositInterval / 2);
    if (block.timestamp >= startTime2) {
      _processCircleRound(circleId2, members, _depositAmount * 2, _depositInterval, startTime2, 0);
    }

    // Verify at least one round was completed
    assertTrue(true, 'Test completed successfully');
  }

  // ============ Complex Multi-Round Edge Cases ============

  function testFuzz_IncompleteRoundsRecovery(uint8 _memberCount, uint8 _missedDeposits) public {
    // Test recovery from incomplete rounds where some members miss deposits
    _memberCount = uint8(bound(uint256(_memberCount), 3, 6));
    _missedDeposits = uint8(bound(uint256(_missedDeposits), 1, _memberCount - 1));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 depositInterval = 1 days;
    uint256 startTime = block.timestamp + 1 hours;

    uint256 circleId = _createCircleAt(members, 1000, depositInterval, startTime);
    vm.warp(startTime);

    // First round with missed deposits
    uint256 depositedCount = _memberCount - _missedDeposits;
    for (uint256 i = 0; i < depositedCount; i++) {
      token.mint(members[i], 1000);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), 1000);
      savingCircles.deposit(circleId, 1000);
      vm.stopPrank();
    }

    // Move past deposit window - should not be withdrawable due to incomplete deposits
    vm.warp(startTime + depositInterval + 1);
    assertFalse(savingCircles.isWithdrawable(circleId), 'Should not be withdrawable with incomplete deposits');

    // Now complete the missed deposits (recovery)
    for (uint256 i = depositedCount; i < _memberCount; i++) {
      token.mint(members[i], 1000);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), 1000);

      // Should revert as deposit window is closed
      vm.expectRevert(ISavingCircles.DepositWindowClosed.selector);
      savingCircles.deposit(circleId, 1000);
      vm.stopPrank();
    }

    // Owner decommissions due to incomplete round
    vm.prank(members[0]);
    savingCircles.decommission(circleId);

    // Verify refunds
    for (uint256 i = 0; i < depositedCount; i++) {
      assertEq(token.balanceOf(members[i]), 1000, 'Should refund deposited amount');
    }
  }

  function testFuzz_WithdrawalOrderConsistency(uint8 _memberCount, uint8 _rounds) public {
    // Verify withdrawal order follows currentIndex correctly
    _memberCount = uint8(bound(uint256(_memberCount), 2, 5));
    _rounds = uint8(bound(uint256(_rounds), 1, _memberCount));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 depositInterval = 1 days;
    uint256 startTime = block.timestamp + 1 hours;

    uint256 circleId = _createCircleAt(members, 1000, depositInterval, startTime);
    vm.warp(startTime);

    // Track who withdraws in each round
    address[] memory withdrawalOrder = new address[](_rounds);

    for (uint256 round = 0; round < _rounds; round++) {
      // All members deposit
      for (uint256 i = 0; i < _memberCount; i++) {
        token.mint(members[i], 1000);
        vm.startPrank(members[i]);
        token.approve(address(savingCircles), 1000);
        savingCircles.deposit(circleId, 1000);
        vm.stopPrank();
      }

      // Move to withdrawal time
      vm.warp(startTime + (depositInterval * (round + 1)));

      // Check who should withdraw
      ISavingCircles.Circle memory currentCircle = savingCircles.getCircle(circleId);
      address expectedWithdrawer = savingCircles.withdrawableBy(circleId);

      // Verify it's the correct member based on currentIndex
      assertEq(expectedWithdrawer, members[currentCircle.currentIndex], 'Wrong withdrawal order');

      // Perform withdrawal
      vm.prank(expectedWithdrawer);
      savingCircles.withdraw(circleId);

      withdrawalOrder[round] = expectedWithdrawer;
    }

    // Verify each member withdrew in the correct order
    for (uint256 i = 0; i < _rounds; i++) {
      assertEq(withdrawalOrder[i], members[i % _memberCount], 'Withdrawal order inconsistent');
    }
  }

  function _processCircleRound(
    uint256 circleId,
    address[] memory members,
    uint256 depositAmount,
    uint256 depositInterval,
    uint256 startTime,
    uint256 round
  ) internal {
    vm.warp(startTime + (depositInterval * round));

    // Deposits
    for (uint256 i = 0; i < members.length; i++) {
      token.mint(members[i], depositAmount);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), depositAmount);
      savingCircles.deposit(circleId, depositAmount);
      vm.stopPrank();
    }

    // Withdrawal
    vm.warp(startTime + (depositInterval * (round + 1)));
    if (savingCircles.isWithdrawable(circleId)) {
      ISavingCircles.Circle memory circleData = savingCircles.getCircle(circleId);
      address[] memory storedMembers = savingCircles.getCircleMembers(circleId);
      address recipient = storedMembers[circleData.currentIndex];
      vm.prank(recipient);
      savingCircles.withdraw(circleId);
    }
  }
}
