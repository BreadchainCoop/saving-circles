// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {ISavingCircles} from 'src/interfaces/ISavingCircles.sol';

abstract contract SavingCirclesTestBase is Test {
  function _defaultCircle(
    address _owner,
    uint256 _depositAmount,
    uint256 _depositInterval,
    address _token
  ) internal pure returns (ISavingCircles.Circle memory _circle) {
    _circle = ISavingCircles.Circle({
      owner: _owner,
      currentIndex: 0,
      depositAmount: _depositAmount,
      token: _token,
      depositInterval: _depositInterval,
      effectiveCircleStartTime: 0,
      circleEnd: 0
    });
  }

  function _signInvite(
    address _savingCircles,
    uint256 _circleId,
    uint256 _nonce,
    uint256 _signerKey
  ) internal view returns (bytes memory) {
    bytes32 inviteTypehash = 0xd86e498a74dbfe863d870d4811dddab9c7f3922d6c0d6656504984bd9a8607a3;
    bytes32 structHash = keccak256(abi.encode(inviteTypehash, _circleId, _nonce));
    bytes32 eip712DomainTypehash = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 inviteDomainNameHash = 0xf50d3e48fa87e894899f86eba14c57c836bc6ffddd68251a158269ffdadc0cb1;
    bytes32 inviteDomainVersionHash = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    bytes32 domainSeparator = keccak256(
      abi.encode(eip712DomainTypehash, inviteDomainNameHash, inviteDomainVersionHash, block.chainid, _savingCircles)
    );

    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function _addMembers(
    ISavingCircles _savingCircles,
    uint256 _circleId,
    address _owner,
    uint256 _ownerKey,
    address[] memory _members
  ) internal {
    uint256 nonce = 1;
    for (uint256 i = 0; i < _members.length; i++) {
      address member = _members[i];
      if (member == _owner) continue;

      bytes memory signature = _signInvite(address(_savingCircles), _circleId, nonce, _ownerKey);
      vm.prank(member);
      _savingCircles.redeemInvite(_circleId, nonce, signature);
      nonce++;
    }
  }

  function _createCircle(
    ISavingCircles _savingCircles,
    ISavingCircles.Circle memory _circle,
    address[] memory _members,
    uint256 _ownerKey
  ) internal returns (uint256 _id) {
    vm.prank(_circle.owner);
    _id = _savingCircles.create(_circle);

    _addMembers(_savingCircles, _id, _circle.owner, _ownerKey, _members);
  }

  function _createCircleWithMembers(
    ISavingCircles _savingCircles,
    ISavingCircles.Circle memory _circle,
    address[] memory _members,
    uint256 _ownerKey
  ) internal returns (uint256 _id) {
    _id = _createCircle(_savingCircles, _circle, _members, _ownerKey);
    vm.prank(_circle.owner);
    _savingCircles.start(_id);
  }
}
