// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {SavingCirclesTestBase} from '../utils/SavingCirclesTestBase.t.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

contract SavingCirclesFuzzTest is SavingCirclesTestBase {
  SavingCircles public implementation;
  SavingCircles public savingCircles;
  MockERC20 public token;

  address public owner = makeAddr('owner');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public charlie = makeAddr('charlie');
  uint256 internal _ownerPrivateKey;
  uint256 internal _alicePrivateKey;

  uint256 private constant _MAX_REASONABLE_DEPOSIT = 1e24;
  uint256 private constant _MAX_REASONABLE_INTERVAL = 365 days;
  uint256 private constant _MIN_DEPOSIT_INTERVAL = 1;

  function setUp() public {
    (owner, _ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, _alicePrivateKey) = makeAddrAndKey('alice');

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
    uint8 _memberCount
  ) public {
    _depositAmount = bound(_depositAmount, 1, _MAX_REASONABLE_DEPOSIT);
    _depositInterval = bound(_depositInterval, _MIN_DEPOSIT_INTERVAL, _MAX_REASONABLE_INTERVAL);
    _memberCount = uint8(bound(_memberCount, 2, 10));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, _depositInterval, address(token));

    uint256 circleId = _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);

    ISavingCircles.Circle memory retrievedCircle = savingCircles.getCircle(circleId);
    assertEq(retrievedCircle.owner, alice);
    assertEq(retrievedCircle.depositAmount, _depositAmount);
    assertEq(retrievedCircle.depositInterval, _depositInterval);
    assertEq(retrievedCircle.effectiveCircleStartTime, block.timestamp);
    assertEq(savingCircles.getCircleMembers(circleId).length, _memberCount);
  }

  function testFuzz_Deposit_PartialDeposits(uint256 _totalDeposit, uint8 _numDeposits) public {
    _totalDeposit = bound(_totalDeposit, 100, _MAX_REASONABLE_DEPOSIT);
    _numDeposits = uint8(bound(_numDeposits, 1, 10));

    address[] memory members = new address[](2);
    members[0] = alice;
    members[1] = bob;

    ISavingCircles.Circle memory circle = _defaultCircle(alice, _totalDeposit, 1 days, address(token));

    uint256 circleId = _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);

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

  function testFuzz_Withdraw_AfterAllDeposits(uint256 _depositAmount, uint8 _memberCount) public {
    _depositAmount = bound(_depositAmount, 100, _MAX_REASONABLE_DEPOSIT / 10);
    _memberCount = uint8(bound(_memberCount, 2, 5));

    address[] memory members = new address[](_memberCount);
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, 1 days, address(token));

    uint256 circleId = _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);

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
    members[0] = alice;
    for (uint256 i = 1; i < totalMembers; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, 1 days, address(token));

    uint256 circleId = _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);

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

  function testFuzz_InvalidCircleCreation_ZeroValues(uint256 _depositAmount, uint256 _depositInterval) public {
    _depositInterval = bound(_depositInterval, 0, _MAX_REASONABLE_INTERVAL);
    address[] memory members = new address[](2);
    members[0] = alice;
    members[1] = bob;

    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, _depositInterval, address(token));

    if (_depositAmount == 0 && _depositInterval == 0) {
      vm.prank(alice);
      vm.expectRevert(ISavingCircles.InvalidDepositInterval.selector);
      savingCircles.create(circle);
      return;
    }

    if (_depositAmount == 0) {
      vm.prank(alice);
      vm.expectRevert(ISavingCircles.InvalidDepositAmount.selector);
      savingCircles.create(circle);
      return;
    }

    if (_depositInterval == 0) {
      vm.prank(alice);
      vm.expectRevert(ISavingCircles.InvalidDepositInterval.selector);
      savingCircles.create(circle);
      return;
    }

    uint256 circleId = _createCircle(savingCircles, circle, members, _alicePrivateKey);
    vm.prank(alice);
    savingCircles.start(circleId);
  }

  function testFuzz_DepositTiming(uint256 _depositInterval, uint256 _timeOffset) public {
    _depositInterval = bound(_depositInterval, 1 hours, 30 days);
    _timeOffset = bound(_timeOffset, 0, _depositInterval * 2);

    address[] memory members = new address[](2);
    members[0] = alice;
    members[1] = bob;

    uint256 depositAmount = 1000;
    ISavingCircles.Circle memory circle = _defaultCircle(alice, depositAmount, _depositInterval, address(token));

    uint256 circleId = _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);

    token.mint(alice, depositAmount);
    vm.startPrank(alice);
    token.approve(address(savingCircles), depositAmount);

    uint256 startTime = savingCircles.getCircle(circleId).effectiveCircleStartTime;
    vm.warp(startTime + _timeOffset);

    uint256 maxDuration = _depositInterval * members.length;
    if (_timeOffset >= maxDuration) {
      vm.expectRevert(ISavingCircles.CircleExpired.selector);
      savingCircles.deposit(circleId, depositAmount);
    } else if (_timeOffset >= _depositInterval) {
      vm.expectRevert(ISavingCircles.DepositWindowClosed.selector);
      savingCircles.deposit(circleId, depositAmount);
    } else {
      savingCircles.deposit(circleId, depositAmount);
      assertEq(savingCircles.balances(circleId, alice), depositAmount);
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
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, 1 days, address(token));

    uint256 circleId = _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);

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
    members[0] = alice;
    for (uint256 i = 1; i < _memberCount; i++) {
      members[i] = makeAddr(string(abi.encodePacked('member', i)));
    }

    uint256 depositInterval = 1 days;
    uint256 startTime = block.timestamp;

    ISavingCircles.Circle memory circle = _defaultCircle(alice, _depositAmount, depositInterval, address(token));

    uint256 circleId = _createCircleWithMembers(savingCircles, circle, members, _alicePrivateKey);

    // Warp to near the end of deposit window
    uint256 nearWindowClose = startTime + depositInterval - _timeDelta - 1 hours;
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
