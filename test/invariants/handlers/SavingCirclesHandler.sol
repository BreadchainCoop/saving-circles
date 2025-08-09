// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SavingCircles} from '../../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingCirclesHandler is Test {
  SavingCircles public savingCircles;
  MockERC20 public token;

  uint256[] public activeCircles;
  uint256[] public decommissionedCircles;
  mapping(uint256 circleId => bool active) public isActive;
  mapping(uint256 circleId => bool decommissioned) public isDecommissioned;

  uint256 public totalDeposits;
  uint256 public totalWithdrawn;
  uint256 public expectedWithdrawals;

  address[] public actors;
  mapping(address actor => bool isActorBool) public isActor;

  uint256 public currentTime;

  modifier useActor(uint256 actorIndexSeed) {
    address actor = _getActor(actorIndexSeed);
    vm.startPrank(actor);
    _;
    vm.stopPrank();
  }

  constructor(SavingCircles _savingCircles, MockERC20 _token) {
    savingCircles = _savingCircles;
    token = _token;
    currentTime = block.timestamp;

    for (uint256 i = 0; i < 10; i++) {
      address actor = makeAddr(string(abi.encodePacked('actor', i)));
      actors.push(actor);
      isActor[actor] = true;
    }
  }

  function createCircle(
    uint256 memberCountSeed,
    uint256 depositAmount,
    uint256 depositInterval,
    uint256 maxDeposits,
    uint256 circleStartOffset,
    uint256 actorSeed
  ) public useActor(actorSeed) {
    uint256 memberCount = bound(memberCountSeed, 2, 5);
    depositAmount = bound(depositAmount, 100, 1e18);
    depositInterval = bound(depositInterval, 1 hours, 7 days);
    maxDeposits = bound(maxDeposits, memberCount, memberCount * 2);
    circleStartOffset = bound(circleStartOffset, 1, 30 days);

    address[] memory members = new address[](memberCount);
    for (uint256 i = 0; i < memberCount; i++) {
      members[i] = actors[i % actors.length];
    }

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: msg.sender,
      members: members,
      token: address(token),
      depositAmount: depositAmount,
      depositInterval: depositInterval,
      maxDeposits: maxDeposits,
      circleStart: currentTime + circleStartOffset,
      currentIndex: 0
    });

    try savingCircles.create(circle) returns (uint256 circleId) {
      activeCircles.push(circleId);
      isActive[circleId] = true;
    } catch {}
  }

  function deposit(uint256 circleIndexSeed, uint256 amount, uint256 actorSeed) public useActor(actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      if (!savingCircles.isMember(circleId, msg.sender)) return;

      uint256 currentBalance = savingCircles.balances(circleId, msg.sender);
      uint256 maxDeposit = circle.depositAmount > currentBalance ? circle.depositAmount - currentBalance : 0;

      amount = bound(amount, 0, maxDeposit);
      if (amount == 0) return;

      token.mint(msg.sender, amount);
      token.approve(address(savingCircles), amount);

      try savingCircles.deposit(circleId, amount) {
        totalDeposits += amount;
      } catch {}
    } catch {}
  }

  function depositFor(
    uint256 circleIndexSeed,
    uint256 memberIndexSeed,
    uint256 amount,
    uint256 actorSeed
  ) public useActor(actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      if (circle.members.length == 0) return;

      uint256 memberIndex = memberIndexSeed % circle.members.length;
      address member = circle.members[memberIndex];

      uint256 currentBalance = savingCircles.balances(circleId, member);
      uint256 maxDeposit = circle.depositAmount > currentBalance ? circle.depositAmount - currentBalance : 0;

      amount = bound(amount, 0, maxDeposit);
      if (amount == 0) return;

      token.mint(msg.sender, amount);
      token.approve(address(savingCircles), amount);

      try savingCircles.depositFor(circleId, amount, member) {
        totalDeposits += amount;
      } catch {}
    } catch {}
  }

  function withdraw(uint256 circleIndexSeed, uint256 actorSeed) public useActor(actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      if (!savingCircles.isMember(circleId, msg.sender)) return;

      uint256 balanceBefore = token.balanceOf(msg.sender);

      try savingCircles.withdraw(circleId) {
        uint256 balanceAfter = token.balanceOf(msg.sender);
        uint256 withdrawnAmount = balanceAfter - balanceBefore;
        totalWithdrawn += withdrawnAmount;
        expectedWithdrawals += circle.depositAmount * circle.members.length;
        totalDeposits -= circle.depositAmount * circle.members.length;
      } catch {}
    } catch {}
  }

  function withdrawFor(uint256 circleIndexSeed, uint256 memberIndexSeed, uint256 actorSeed) public useActor(actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      if (!savingCircles.isMember(circleId, msg.sender)) return;
      if (circle.members.length == 0) return;

      uint256 memberIndex = memberIndexSeed % circle.members.length;
      address member = circle.members[memberIndex];

      uint256 balanceBefore = token.balanceOf(member);

      try savingCircles.withdrawFor(circleId, member) {
        uint256 balanceAfter = token.balanceOf(member);
        uint256 withdrawnAmount = balanceAfter - balanceBefore;
        totalWithdrawn += withdrawnAmount;
        expectedWithdrawals += circle.depositAmount * circle.members.length;
        totalDeposits -= circle.depositAmount * circle.members.length;
      } catch {}
    } catch {}
  }

  function decommission(uint256 circleIndexSeed, uint256 actorSeed) public useActor(actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      uint256 totalRefunded = 0;
      for (uint256 i = 0; i < circle.members.length; i++) {
        totalRefunded += savingCircles.balances(circleId, circle.members[i]);
      }

      try savingCircles.decommission(circleId) {
        isActive[circleId] = false;
        isDecommissioned[circleId] = true;
        decommissionedCircles.push(circleId);

        for (uint256 i = 0; i < activeCircles.length; i++) {
          if (activeCircles[i] == circleId) {
            activeCircles[i] = activeCircles[activeCircles.length - 1];
            activeCircles.pop();
            break;
          }
        }

        totalDeposits -= totalRefunded;
      } catch {}
    } catch {}
  }

  function warpTime(uint256 timeDelta) public {
    timeDelta = bound(timeDelta, 0, 365 days);
    currentTime += timeDelta;
    vm.warp(currentTime);
  }

  function _getActor(uint256 actorIndexSeed) internal view returns (address) {
    return actors[actorIndexSeed % actors.length];
  }

  function getActiveCircles() public view returns (uint256[] memory) {
    return activeCircles;
  }

  function getDecommissionedCircles() public view returns (uint256[] memory) {
    return decommissionedCircles;
  }

  function getTotalDeposits() public view returns (uint256) {
    return totalDeposits;
  }

  function getTotalWithdrawn() public view returns (uint256) {
    return totalWithdrawn;
  }

  function getExpectedWithdrawals() public view returns (uint256) {
    return expectedWithdrawals;
  }
}
