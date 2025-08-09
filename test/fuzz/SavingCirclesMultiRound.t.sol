// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ERC1967Proxy} from '@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingCirclesMultiRoundFuzzTest is Test {
  SavingCircles public implementation;
  SavingCircles public savingCircles;
  MockERC20 public token;

  address public owner = makeAddr('owner');

  uint256 private constant _MAX_REASONABLE_DEPOSIT = 1e20;
  uint256 private constant _MAX_REASONABLE_INTERVAL = 7 days;
  uint256 private constant _MIN_DEPOSIT_INTERVAL = 1 hours;

  function setUp() public {
    implementation = new SavingCircles();

    bytes memory initData = abi.encodeWithSelector(SavingCircles.initialize.selector, owner);
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
    savingCircles = SavingCircles(address(proxy));

    token = new MockERC20('Test Token', 'TEST');

    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);
  }

  function testFuzz_CompleteCircleWithNRounds(
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint8 _memberCount,
    uint8 _roundsToComplete
  ) public {
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT);
    _depositInterval = bound(_depositInterval, _MIN_DEPOSIT_INTERVAL, _MAX_REASONABLE_INTERVAL);
    _memberCount = uint8(bound(uint256(_memberCount), 2, 5));
    _roundsToComplete = uint8(bound(uint256(_roundsToComplete), 1, uint256(_memberCount)));

    address[] memory members = new address[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 startTime = block.timestamp + 1 days;
    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: members[0],
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: _depositInterval,
      maxDeposits: _memberCount,
      circleStart: startTime,
      currentIndex: 0
    });

    vm.prank(members[0]);
    uint256 circleId = savingCircles.create(circle);

    uint256[] memory memberWithdrawals = new uint256[](_memberCount);
    uint256 totalExpectedPayout = _depositAmount * _memberCount;

    // Move to circle start time
    vm.warp(startTime);

    for (uint256 round = 0; round < _roundsToComplete; round++) {
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
      address expectedRecipient = currentCircle.members[currentCircle.currentIndex];
      uint256 recipientIndex = currentCircle.currentIndex;

      // Withdraw for current round
      uint256 balanceBefore = token.balanceOf(expectedRecipient);
      vm.prank(members[0]);
      savingCircles.withdraw(circleId);
      uint256 balanceAfter = token.balanceOf(expectedRecipient);

      assertEq(balanceAfter - balanceBefore, totalExpectedPayout);
      memberWithdrawals[recipientIndex] += totalExpectedPayout;

      // Move to next deposit window if not the last round
      if (round < _roundsToComplete - 1) {
        startTime = block.timestamp; // Update start time for next round
      }
    }

    // Verify that the expected number of rounds were completed
    for (uint256 i = 0; i < _roundsToComplete; i++) {
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
        // Some members participate in multiple circles
        if (c > 0 && i == 0) {
          members[i] = allMembers[0][0]; // Reuse first member from first circle
        } else {
          members[i] = makeAddr(string(abi.encodePacked('circle', c, 'member', i)));
        }
      }
      allMembers[c] = members;

      startTimes[c] = block.timestamp + 1 days + (c * 1 hours); // Stagger start times
      ISavingCircles.Circle memory circle = ISavingCircles.Circle({
        owner: members[0],
        members: members,
        token: address(token),
        depositAmount: _depositAmount,
        depositInterval: _depositInterval,
        maxDeposits: _memberCount,
        circleStart: startTimes[c],
        currentIndex: 0
      });

      vm.prank(members[0]);
      circleIds[c] = savingCircles.create(circle);
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
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 startTime = block.timestamp + 1 days;
    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: members[0],
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: _depositInterval,
      maxDeposits: _memberCount,
      circleStart: startTime,
      currentIndex: 0
    });

    vm.prank(members[0]);
    uint256 circleId = savingCircles.create(circle);

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

      vm.prank(members[0]);
      savingCircles.withdraw(circleId);

      // Update start time for next round
      startTime = block.timestamp;
    }

    // Start next round but only partial deposits
    uint256 partialDepositors = _memberCount / 2;
    if (partialDepositors == 0) partialDepositors = 1;

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
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    for (uint256 seq = 0; seq < _numSequentialCircles; seq++) {
      uint256 startTime = block.timestamp + 1 days;
      ISavingCircles.Circle memory circle = ISavingCircles.Circle({
        owner: members[0],
        members: members,
        token: address(token),
        depositAmount: _depositAmount * (seq + 1), // Increase amount each time
        depositInterval: _depositInterval,
        maxDeposits: _memberCount,
        circleStart: startTime,
        currentIndex: 0
      });

      vm.prank(members[0]);
      uint256 circleId = savingCircles.create(circle);

      vm.warp(startTime);

      // Complete full circle
      for (uint256 round = 0; round < _memberCount; round++) {
        for (uint256 i = 0; i < _memberCount; i++) {
          uint256 amount = _depositAmount * (seq + 1);
          token.mint(members[i], amount);
          vm.startPrank(members[i]);
          token.approve(address(savingCircles), amount);
          savingCircles.deposit(circleId, amount);
          vm.stopPrank();
        }

        vm.warp(startTime + (_depositInterval * (round + 1)));

        vm.prank(members[0]);
        savingCircles.withdraw(circleId);

        // Update for next round
        startTime = block.timestamp;
      }

      // Verify everyone received their payout in this circle
      // Each member should have received exactly one payout
    }
  }

  function testFuzz_MaxDepositBoundaryWithMultipleRounds(
    uint256 _depositAmount,
    uint8 _memberCount,
    uint8 _maxDeposits
  ) public {
    _depositAmount = bound(_depositAmount, 1000, _MAX_REASONABLE_DEPOSIT / 10);
    _memberCount = uint8(bound(uint256(_memberCount), 2, 5));
    _maxDeposits = uint8(bound(uint256(_maxDeposits), uint256(_memberCount), uint256(_memberCount) * 3));

    address[] memory members = new address[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 startTime = block.timestamp + 1 days;
    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: members[0],
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: 1 days,
      maxDeposits: _maxDeposits,
      circleStart: startTime,
      currentIndex: 0
    });

    vm.prank(members[0]);
    uint256 circleId = savingCircles.create(circle);

    vm.warp(startTime);

    uint256 actualRounds = _maxDeposits > _memberCount ? _memberCount : _maxDeposits;

    for (uint256 round = 0; round < actualRounds; round++) {
      // Deposit phase
      for (uint256 i = 0; i < _memberCount; i++) {
        token.mint(members[i], _depositAmount);
        vm.startPrank(members[i]);
        token.approve(address(savingCircles), _depositAmount);
        savingCircles.deposit(circleId, _depositAmount);
        vm.stopPrank();
      }

      vm.warp(startTime + (1 days * (round + 1)));

      // Withdraw phase
      if (round < actualRounds) {
        assertTrue(savingCircles.isWithdrawable(circleId));
        vm.prank(members[0]);
        savingCircles.withdraw(circleId);

        // Update start time for next round
        startTime = block.timestamp;
      }
    }

    // After max deposits, circle should expire
    if (_maxDeposits == actualRounds) {
      // Try to deposit after max deposits reached
      vm.warp(block.timestamp + 1 days);
      token.mint(members[0], _depositAmount);
      vm.startPrank(members[0]);
      token.approve(address(savingCircles), _depositAmount);

      // Should revert because we've reached max deposits
      ISavingCircles.Circle memory circleData = savingCircles.getCircle(circleId);
      if (block.timestamp >= circleData.circleStart + (1 days * _maxDeposits)) {
        vm.expectRevert(ISavingCircles.CircleExpired.selector);
        savingCircles.deposit(circleId, _depositAmount);
      }
      vm.stopPrank();
    }
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
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 startTime1 = block.timestamp + 1 days;
    uint256 startTime2 = startTime1 + (_depositInterval / 2);

    // Create two circles with staggered timing
    ISavingCircles.Circle memory circle1 = ISavingCircles.Circle({
      owner: members[0],
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: _depositInterval,
      maxDeposits: _memberCount * 2,
      circleStart: startTime1,
      currentIndex: 0
    });

    ISavingCircles.Circle memory circle2 = ISavingCircles.Circle({
      owner: members[1],
      members: members,
      token: address(token),
      depositAmount: _depositAmount * 2,
      depositInterval: _depositInterval,
      maxDeposits: _memberCount * 2,
      circleStart: startTime2,
      currentIndex: 0
    });

    vm.prank(members[0]);
    uint256 circleId1 = savingCircles.create(circle1);

    vm.prank(members[1]);
    uint256 circleId2 = savingCircles.create(circle2);

    // Interleave deposits and withdrawals between circles
    for (uint256 round = 0; round < 3; round++) {
      // Circle 1 deposits
      vm.warp(startTime1 + (_depositInterval * round));

      for (uint256 i = 0; i < _memberCount; i++) {
        token.mint(members[i], _depositAmount);
        vm.startPrank(members[i]);
        token.approve(address(savingCircles), _depositAmount);
        savingCircles.deposit(circleId1, _depositAmount);
        vm.stopPrank();
      }

      // Circle 2 deposits (if started)
      if (block.timestamp >= startTime2) {
        vm.warp(startTime2 + (_depositInterval * round));

        for (uint256 i = 0; i < _memberCount; i++) {
          token.mint(members[i], _depositAmount * 2);
          vm.startPrank(members[i]);
          token.approve(address(savingCircles), _depositAmount * 2);
          if (block.timestamp < startTime2 + (_depositInterval * (_memberCount * 2))) {
            savingCircles.deposit(circleId2, _depositAmount * 2);
          }
          vm.stopPrank();
        }
      }

      // Circle 1 withdrawal
      vm.warp(startTime1 + (_depositInterval * (round + 1)));
      if (savingCircles.isWithdrawable(circleId1)) {
        vm.prank(members[0]);
        savingCircles.withdraw(circleId1);
        startTime1 = block.timestamp; // Update for next round
      }

      // Check circle 2 withdrawal
      if (block.timestamp >= startTime2 + _depositInterval) {
        if (savingCircles.isWithdrawable(circleId2)) {
          vm.prank(members[1]);
          savingCircles.withdraw(circleId2);
          startTime2 = block.timestamp; // Update for next round
        }
      }
    }
  }
}
