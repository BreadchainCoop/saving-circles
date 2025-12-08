// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {Common} from 'script/Common.sol';

import {SavingCircles} from 'contracts/SavingCircles.sol';
import {ISavingCircles} from 'interfaces/ISavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

// solhint-disable-next-line
import 'script/Registry.sol';

contract IntegrationBase is Common, Test {
  SavingCircles public circle;
  MockERC20 public token;

  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public owner = makeAddr('owner');
  uint256 internal alicePrivateKey;
  uint256 internal bobPrivateKey;
  uint256 internal carolPrivateKey;
  uint256 internal ownerPrivateKey;
  address[] public members;

  ISavingCircles.Circle public baseCircle;
  uint256 public baseCircleId;
  uint256 public baseCircleStart;

  uint256 public constant DEPOSIT_AMOUNT = 1000e18;
  uint256 public constant DEPOSIT_INTERVAL = 7 days;
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant BASE_MAX_DEPOSITS = 1000;

  function setUp() public virtual override {
    super.setUp();

    (owner, ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, alicePrivateKey) = makeAddrAndKey('alice');
    (bob, bobPrivateKey) = makeAddrAndKey('bob');
    (carol, carolPrivateKey) = makeAddrAndKey('carol');

    vm.startPrank(owner);
    circle = SavingCircles(address(_deployContracts(owner)));
    token = new MockERC20('Test Token', 'TEST');
    vm.stopPrank();

    _setUpAccounts();

    baseCircle = ISavingCircles.Circle({
      owner: alice,
      currentIndex: BASE_CURRENT_INDEX,
      depositAmount: DEPOSIT_AMOUNT,
      token: address(token),
      depositInterval: DEPOSIT_INTERVAL,
      effectiveCircleStartTime: 0,
      circleEnd: 0
    });
  }

  function createBaseCircle() public {
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    baseCircleId = _createCircleWithMembers(baseCircle, members, alicePrivateKey);
    baseCircleStart = circle.getCircle(baseCircleId).effectiveCircleStartTime;
  }

  function _setUpAccounts() internal {
    vm.startPrank(alice);
    token.mint(alice, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(alice);
    vm.stopPrank();

    vm.startPrank(bob);
    token.mint(bob, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(bob);
    vm.stopPrank();

    vm.startPrank(carol);
    token.mint(carol, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(carol);
    vm.stopPrank();
  }

  function _createCircleWithMembers(
    ISavingCircles.Circle memory _circle,
    address[] memory _members,
    uint256 _ownerKey
  ) internal returns (uint256 _id) {
    _id = _createCircle(_circle, _members, _ownerKey);
    vm.prank(_circle.owner);
    circle.start(_id);
  }

  function _createCircle(
    ISavingCircles.Circle memory _circle,
    address[] memory _members,
    uint256 _ownerKey
  ) internal returns (uint256 _id) {
    vm.prank(_circle.owner);
    _id = circle.create(_circle);

    _addMembers(_id, _circle.owner, _ownerKey, _members);
  }

  function _addMembers(uint256 _circleId, address _owner, uint256 _ownerKey, address[] memory _members) internal {
    uint256 nonce = 1;
    for (uint256 i = 0; i < _members.length; i++) {
      address member = _members[i];
      if (member == _owner) continue;

      bytes memory signature = _signInvite(_circleId, nonce, _ownerKey);
      vm.prank(member);
      circle.redeemInvite(_circleId, nonce, signature);
      nonce++;
    }
  }

  function _signInvite(uint256 _circleId, uint256 _nonce, uint256 _signerKey) internal view returns (bytes memory) {
    bytes32 inviteTypehash = 0xd86e498a74dbfe863d870d4811dddab9c7f3922d6c0d6656504984bd9a8607a3;
    bytes32 structHash = keccak256(abi.encode(inviteTypehash, _circleId, _nonce));
    bytes32 eip712DomainTypehash = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 inviteDomainNameHash = 0xf50d3e48fa87e894899f86eba14c57c836bc6ffddd68251a158269ffdadc0cb1;
    bytes32 inviteDomainVersionHash = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    bytes32 domainSeparator = keccak256(
      abi.encode(eip712DomainTypehash, inviteDomainNameHash, inviteDomainVersionHash, block.chainid, address(circle))
    );

    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function _defaultCircle(
    address _owner,
    uint256 _depositAmount,
    uint256 _depositInterval
  ) internal view returns (ISavingCircles.Circle memory _circle) {
    _circle = ISavingCircles.Circle({
      owner: _owner,
      currentIndex: BASE_CURRENT_INDEX,
      depositAmount: _depositAmount,
      token: address(token),
      depositInterval: _depositInterval,
      effectiveCircleStartTime: 0,
      circleEnd: 0
    });
  }
}
