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
  mapping(address actor => uint256 key) public actorKeys;
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
      (address actor, uint256 key) = makeAddrAndKey(string(abi.encodePacked('actor', i)));
      actors.push(actor);
      isActor[actor] = true;
      actorKeys[actor] = key;
    }
  }

  function createCircle(
    uint256 memberCountSeed,
    uint256 depositAmount,
    uint256 depositInterval,
    uint256 circleStartOffset,
    uint256 _actorSeed // solhint-disable-line no-unused-vars
  ) public useActor(_actorSeed) {
    uint256 memberCount = bound(memberCountSeed, 2, 5);
    depositAmount = bound(depositAmount, 100, 1e18);
    depositInterval = bound(depositInterval, 1 hours, 7 days);
    circleStartOffset = bound(circleStartOffset, 1, 30 days);

    address[] memory members = new address[](memberCount);
    for (uint256 i = 0; i < memberCount; i++) {
      members[i] = actors[i % actors.length];
    }

    ISavingCircles.Circle memory circle = ISavingCircles.Circle({
      owner: msg.sender,
      currentIndex: 0,
      depositAmount: depositAmount,
      token: address(token),
      depositInterval: depositInterval,
      effectiveCircleStartTime: 0,
      circleEnd: 0
    });

    try savingCircles.create(circle) returns (uint256 circleId) {
      _addMembers(circleId, msg.sender, actorKeys[msg.sender], members);
      uint256 startAt = currentTime + circleStartOffset;
      if (block.timestamp < startAt) vm.warp(startAt);
      try savingCircles.start(circleId) {
        activeCircles.push(circleId);
        isActive[circleId] = true;
      } catch {}
    } catch {}
  }

  // solhint-disable-next-line no-unused-vars
  function deposit(uint256 circleIndexSeed, uint256 amount, uint256 _actorSeed) public useActor(_actorSeed) {
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
    uint256 _actorSeed // solhint-disable-line no-unused-vars
  ) public useActor(_actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      address[] memory members = savingCircles.getCircleMembers(circleId);
      if (members.length == 0) return;

      uint256 memberIndex = memberIndexSeed % members.length;
      address member = members[memberIndex];

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

  // solhint-disable-next-line no-unused-vars
  function withdraw(uint256 circleIndexSeed, uint256 _actorSeed) public useActor(_actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      address[] memory members = savingCircles.getCircleMembers(circleId);
      if (!savingCircles.isMember(circleId, msg.sender)) return;

      uint256 balanceBefore = token.balanceOf(msg.sender);

      try savingCircles.withdraw(circleId) {
        uint256 balanceAfter = token.balanceOf(msg.sender);
        uint256 withdrawnAmount = balanceAfter - balanceBefore;
        uint256 expectedWithdrawal = circle.depositAmount * members.length;
        totalWithdrawn += withdrawnAmount;
        totalDeposits -= withdrawnAmount;
        expectedWithdrawals += expectedWithdrawal;
      } catch {}
    } catch {}
  }

  function withdrawFor(
    uint256 circleIndexSeed,
    uint256 memberIndexSeed,
    uint256 _actorSeed // solhint-disable-line no-unused-vars
  ) public useActor(_actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      address[] memory members = savingCircles.getCircleMembers(circleId);
      if (!savingCircles.isMember(circleId, msg.sender)) return;
      if (members.length == 0) return;

      uint256 memberIndex = memberIndexSeed % members.length;
      address member = members[memberIndex];

      uint256 balanceBefore = token.balanceOf(member);

      try savingCircles.withdrawFor(circleId, member) {
        uint256 balanceAfter = token.balanceOf(member);
        uint256 withdrawnAmount = balanceAfter - balanceBefore;
        totalWithdrawn += withdrawnAmount;
        expectedWithdrawals += withdrawnAmount;
        totalDeposits -= withdrawnAmount;
      } catch {}
    } catch {}
  }

  // solhint-disable-next-line no-unused-vars
  function decommission(uint256 circleIndexSeed, uint256 _actorSeed) public useActor(_actorSeed) {
    if (activeCircles.length == 0) return;

    uint256 circleIndex = circleIndexSeed % activeCircles.length;
    uint256 circleId = activeCircles[circleIndex];

    if (!isActive[circleId]) return;

    try savingCircles.getCircle(circleId) returns (ISavingCircles.Circle memory circle) {
      address[] memory members = savingCircles.getCircleMembers(circleId);
      uint256 totalRefunded = 0;
      for (uint256 i = 0; i < members.length; i++) {
        totalRefunded += savingCircles.balances(circleId, members[i]);
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

  function _signInvite(uint256 _circleId, uint256 _nonce, uint256 _signerKey) internal view returns (bytes memory) {
    bytes32 inviteTypehash = 0xd86e498a74dbfe863d870d4811dddab9c7f3922d6c0d6656504984bd9a8607a3;
    bytes32 structHash = keccak256(abi.encode(inviteTypehash, _circleId, _nonce));
    bytes32 eip712DomainTypehash = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 inviteDomainNameHash = 0xf50d3e48fa87e894899f86eba14c57c836bc6ffddd68251a158269ffdadc0cb1;
    bytes32 inviteDomainVersionHash = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    bytes32 domainSeparator = keccak256(
      abi.encode(
        eip712DomainTypehash, inviteDomainNameHash, inviteDomainVersionHash, block.chainid, address(savingCircles)
      )
    );

    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function _addMembers(uint256 _circleId, address _owner, uint256 _ownerKey, address[] memory _members) internal {
    uint256 nonce = 1;
    for (uint256 i = 0; i < _members.length; i++) {
      address member = _members[i];
      if (member == _owner) continue;

      bytes memory signature = _signInvite(_circleId, nonce, _ownerKey);
      vm.prank(member);
      savingCircles.redeemInvite(_circleId, nonce, signature);
      nonce++;
    }
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
