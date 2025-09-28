// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ERC1967Proxy} from '@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingCirclesFuzzTest is Test {
  SavingCircles public implementation;
  SavingCircles public savingCircles;
  MockERC20 public token;

  address public owner = makeAddr('owner');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public charlie = makeAddr('charlie');

  uint256 private constant _MAX_REASONABLE_DEPOSIT = 1e24;
  uint256 private constant _MAX_REASONABLE_INTERVAL = 365 days;
  uint256 private constant _MIN_DEPOSIT_INTERVAL = 1;

  function setUp() public {
    implementation = new SavingCircles();

    bytes memory initData = abi.encodeWithSelector(SavingCircles.initialize.selector, owner);
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
    savingCircles = SavingCircles(address(proxy));

    token = new MockERC20('Test Token', 'TEST');

    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);
  }

  function testFuzz_CreateCircle_ValidParameters(
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint256 _maxDeposits,
    uint256 _circleStart,
    uint8 _memberCount
  ) public {
    _depositAmount = bound(_depositAmount, 1, _MAX_REASONABLE_DEPOSIT);
    _depositInterval = bound(_depositInterval, _MIN_DEPOSIT_INTERVAL, _MAX_REASONABLE_INTERVAL);
    _maxDeposits = bound(_maxDeposits, 1, 100);
    _circleStart = bound(_circleStart, block.timestamp + 1, block.timestamp + 365 days);
    _memberCount = uint8(bound(_memberCount, 2, 10));

    address[] memory members = new address[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: _depositInterval,
      maxDeposits: _maxDeposits,
      circleStart: _circleStart,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    ISavingCircles.Circle memory retrievedCircle = savingCircles.getCircle(circleId);
    assertEq(retrievedCircle.owner, alice);
    assertEq(retrievedCircle.depositAmount, _depositAmount);
    assertEq(retrievedCircle.depositInterval, _depositInterval);
    assertEq(retrievedCircle.maxDeposits, _maxDeposits);
    assertEq(retrievedCircle.circleStart, _circleStart);
    assertEq(retrievedCircle.members.length, _memberCount);
  }

  function testFuzz_Deposit_PartialDeposits(uint256 _totalDeposit, uint8 _numDeposits) public {
    _totalDeposit = bound(_totalDeposit, 100, _MAX_REASONABLE_DEPOSIT);
    _numDeposits = uint8(bound(_numDeposits, 1, 10));

    address[] memory members = new address[](2);
    members[0] = alice;
    members[1] = bob;

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: _totalDeposit,
      depositInterval: 1 days,
      maxDeposits: 2,
      circleStart: block.timestamp,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    token.mint(alice, _totalDeposit);
    vm.startPrank(alice);
    token.approve(address(savingCircles), _totalDeposit);

    uint256 depositedAmount = 0;
    uint256[] memory depositAmounts = new uint256[](_numDeposits);

    for (uint256 i = 0; i < _numDeposits; i++) {
      uint256 remainingAmount = _totalDeposit - depositedAmount;
      if (remainingAmount == 0) break;

      uint256 depositChunk = i == _numDeposits - 1 ? remainingAmount : remainingAmount / (_numDeposits - i);

      depositAmounts[i] = depositChunk;

      if (depositedAmount + depositChunk <= _totalDeposit) {
        savingCircles.deposit(circleId, depositChunk);
        depositedAmount += depositChunk;
      }
    }

    vm.stopPrank();

    assertEq(savingCircles.balances(circleId, alice), depositedAmount);
    assertLe(depositedAmount, _totalDeposit);
  }

  function testFuzz_WithdrawableBy(uint8 _memberCount, uint256 _currentIndex) public {
    _memberCount = uint8(bound(uint256(_memberCount), 2, 10));
    _currentIndex = bound(_currentIndex, 0, uint256(_memberCount) - 1);

    address[] memory members = new address[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    // Create a circle
    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: 1000,
      depositInterval: 1 days,
      maxDeposits: _memberCount,
      circleStart: block.timestamp + 1 days,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    // Move to start time
    vm.warp(block.timestamp + 1 days);

    // Simulate deposits and withdrawals to reach desired currentIndex
    for (uint256 round = 0; round < _currentIndex; round++) {
      // All members deposit
      for (uint256 i = 0; i < _memberCount; i++) {
        token.mint(members[i], 1000);
        vm.startPrank(members[i]);
        token.approve(address(savingCircles), 1000);
        savingCircles.deposit(circleId, 1000);
        vm.stopPrank();
      }

      // Wait for withdrawal time
      vm.warp(block.timestamp + 1 days);

      // Withdraw
      address expectedWithdrawer = savingCircles.withdrawableBy(circleId);
      assertEq(expectedWithdrawer, members[round % _memberCount]);

      vm.prank(expectedWithdrawer);
      savingCircles.withdraw(circleId);
    }
  }

  function testFuzz_Withdraw_AfterAllDeposits(uint256 _depositAmount, uint8 _memberCount) public {
    _depositAmount = bound(_depositAmount, 100, _MAX_REASONABLE_DEPOSIT / 10);
    _memberCount = uint8(bound(_memberCount, 2, 5));

    address[] memory members = new address[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: 1 days,
      maxDeposits: _memberCount,
      circleStart: block.timestamp,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    for (uint256 i = 0; i < _memberCount; i++) {
      token.mint(members[i], _depositAmount);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), _depositAmount);
      savingCircles.deposit(circleId, _depositAmount);
      vm.stopPrank();
    }

    vm.warp(block.timestamp + 1 days);

    address withdrawer = members[0];
    uint256 expectedWithdrawal = _depositAmount * _memberCount;
    uint256 balanceBefore = token.balanceOf(withdrawer);

    vm.prank(withdrawer);
    savingCircles.withdraw(circleId);

    uint256 balanceAfter = token.balanceOf(withdrawer);
    assertEq(balanceAfter - balanceBefore, expectedWithdrawal);
  }

  function testFuzz_Decommission_WithIncompleteDeposits(
    uint256 _depositAmount,
    uint8 _completeMembers,
    uint8 _incompleteMembers
  ) public {
    _depositAmount = bound(_depositAmount, 100, _MAX_REASONABLE_DEPOSIT / 10);
    _completeMembers = uint8(bound(_completeMembers, 1, 5));
    _incompleteMembers = uint8(bound(_incompleteMembers, 1, 5));

    uint8 totalMembers = _completeMembers + _incompleteMembers;
    if (totalMembers < 2) {
      _completeMembers = 1;
      _incompleteMembers = 1;
      totalMembers = 2;
    }

    address[] memory members = new address[](totalMembers);
    for (uint256 i = 0; i < totalMembers; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: 1 days,
      maxDeposits: totalMembers,
      circleStart: block.timestamp,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    for (uint256 i = 0; i < _completeMembers; i++) {
      token.mint(members[i], _depositAmount);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), _depositAmount);
      savingCircles.deposit(circleId, _depositAmount);
      vm.stopPrank();
    }

    for (uint256 i = _completeMembers; i < totalMembers; i++) {
      uint256 partialAmount = _depositAmount / 2;
      token.mint(members[i], partialAmount);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), partialAmount);
      savingCircles.deposit(circleId, partialAmount);
      vm.stopPrank();
    }

    vm.warp(block.timestamp + 2 days);

    vm.prank(alice);
    savingCircles.decommission(circleId);

    for (uint256 i = 0; i < _completeMembers; i++) {
      assertEq(token.balanceOf(members[i]), _depositAmount);
    }

    for (uint256 i = _completeMembers; i < totalMembers; i++) {
      assertEq(token.balanceOf(members[i]), _depositAmount / 2);
    }

    vm.expectRevert(ISavingCircles.NotCommissioned.selector);
    savingCircles.getCircle(circleId);
  }

  function testFuzz_InvalidCircleCreation_ZeroValues(
    uint256 _depositAmount,
    uint256 _depositInterval,
    uint256 _maxDeposits
  ) public {
    address[] memory members = new address[](2);
    members[0] = alice;
    members[1] = bob;

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: _depositInterval,
      maxDeposits: _maxDeposits,
      circleStart: block.timestamp + 1,
      currentIndex: 0
    });

    vm.startPrank(alice);

    if (_depositAmount == 0 || _depositInterval == 0 || _maxDeposits == 0) {
      // The contract checks in order: depositInterval, depositAmount, maxDeposits
      // Multiple conditions could be zero, so we need to check which error is thrown first
      if (_depositInterval == 0) {
        vm.expectRevert(ISavingCircles.InvalidDepositInterval.selector);
      } else if (_depositAmount == 0) {
        vm.expectRevert(ISavingCircles.InvalidDepositAmount.selector);
      } else {
        vm.expectRevert(ISavingCircles.InvalidMaxDeposits.selector);
      }
      savingCircles.create(circle);
    } else {
      uint256 circleId = savingCircles.create(circle);
      assertGe(circleId, 0);
    }

    vm.stopPrank();
  }

  function testFuzz_DepositTiming(uint256 _depositInterval, uint256 _timeOffset) public {
    _depositInterval = bound(_depositInterval, 1 hours, 30 days);
    _timeOffset = bound(_timeOffset, 0, _depositInterval * 2);

    address[] memory members = new address[](2);
    members[0] = alice;
    members[1] = bob;

    uint256 depositAmount = 1000;
    uint256 circleStart = block.timestamp + 1 days;

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      token: address(token),
      depositAmount: depositAmount,
      depositInterval: _depositInterval,
      maxDeposits: 2,
      circleStart: circleStart,
      currentIndex: 0
    });

    vm.prank(alice);
    uint256 circleId = savingCircles.create(circle);

    token.mint(alice, depositAmount);
    vm.startPrank(alice);
    token.approve(address(savingCircles), depositAmount);

    if (block.timestamp < circleStart && _timeOffset < circleStart - block.timestamp) {
      vm.expectRevert(ISavingCircles.DepositBeforeCircleStart.selector);
      savingCircles.deposit(circleId, depositAmount);
    } else {
      vm.warp(block.timestamp + _timeOffset);

      if (block.timestamp >= circleStart + _depositInterval) {
        vm.expectRevert(ISavingCircles.DepositWindowClosed.selector);
        savingCircles.deposit(circleId, depositAmount);
      } else if (block.timestamp >= circleStart) {
        savingCircles.deposit(circleId, depositAmount);
        assertEq(savingCircles.balances(circleId, alice), depositAmount);
      }
    }

    vm.stopPrank();
  }

  // ============ Advanced Fuzz Tests ============

  function testFuzz_DepositForDifferentMembers(
    uint256 _depositAmount,
    uint8 _memberCount,
    uint8 _depositorIndex,
    uint8 _targetMemberIndex
  ) public {
    // Test depositFor functionality with various member combinations
    _memberCount = uint8(bound(uint256(_memberCount), 2, 10));
    _depositorIndex = uint8(bound(uint256(_depositorIndex), 0, uint256(_memberCount) - 1));
    _targetMemberIndex = uint8(bound(uint256(_targetMemberIndex), 0, uint256(_memberCount) - 1));
    _depositAmount = bound(_depositAmount, 100, 1e18);

    // Create members and circle
    address[] memory members = new address[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: members[0],
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: 1 days,
      maxDeposits: _memberCount,
      circleStart: block.timestamp + 1 hours,
      currentIndex: 0
    });

    vm.prank(members[0]);
    uint256 circleId = savingCircles.create(circle);

    vm.warp(circle.circleStart);

    // Depositor deposits for target member
    address depositor = members[_depositorIndex];
    address targetMember = members[_targetMemberIndex];

    token.mint(depositor, _depositAmount);
    vm.startPrank(depositor);
    token.approve(address(savingCircles), _depositAmount);
    savingCircles.depositFor(circleId, _depositAmount, targetMember);
    vm.stopPrank();

    // Verify the deposit was credited to target member
    assertEq(savingCircles.balances(circleId, targetMember), _depositAmount);
    // Depositor should have 0 balance unless they are the target member
    if (depositor != targetMember) {
      assertEq(savingCircles.balances(circleId, depositor), 0);
    }
  }

  function testFuzz_RaceConditionDeposits(uint256 _depositAmount, uint8 _memberCount, uint256 _timeDelta) public {
    // Test deposits happening at the edge of deposit windows
    _memberCount = uint8(bound(uint256(_memberCount), 2, 5));
    _depositAmount = bound(_depositAmount, 100, 1e18);
    _timeDelta = bound(_timeDelta, 0, 1 hours);

    address[] memory members = new address[](_memberCount);
    for (uint256 i = 0; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 depositInterval = 1 days;
    uint256 startTime = block.timestamp + 1 hours;

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: members[0],
      members: members,
      token: address(token),
      depositAmount: _depositAmount,
      depositInterval: depositInterval,
      maxDeposits: _memberCount,
      circleStart: startTime,
      currentIndex: 0
    });

    vm.prank(members[0]);
    uint256 circleId = savingCircles.create(circle);

    // Warp to near the end of deposit window
    uint256 nearWindowClose = startTime + depositInterval - _timeDelta;
    vm.warp(nearWindowClose);

    // Try to deposit for all members rapidly
    for (uint256 i = 0; i < _memberCount; i++) {
      token.mint(members[i], _depositAmount);
      vm.startPrank(members[i]);
      token.approve(address(savingCircles), _depositAmount);

      // Check if we're still in valid deposit window
      if (block.timestamp < startTime + depositInterval) {
        savingCircles.deposit(circleId, _depositAmount);
        assertEq(savingCircles.balances(circleId, members[i]), _depositAmount);
      } else {
        vm.expectRevert(ISavingCircles.DepositWindowClosed.selector);
        savingCircles.deposit(circleId, _depositAmount);
      }
      vm.stopPrank();

      // Simulate time passing between deposits
      vm.warp(block.timestamp + _timeDelta / _memberCount);
    }
  }
}
