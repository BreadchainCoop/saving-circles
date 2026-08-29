// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

import {SavingCircles} from 'src/contracts/SavingCircles.sol';
import {ISavingCircles} from 'src/interfaces/ISavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';
import {SavingCirclesTestBase} from 'test/utils/SavingCirclesTestBase.t.sol';

contract SavingCirclesAddMembers is SavingCirclesTestBase {
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;

  SavingCircles public savingCircles;
  MockERC20 public token;

  address public owner;
  address public alice;
  address public bob;
  address public carol;
  address public immutable STRANGER = makeAddr('stranger');
  uint256 internal _alicePrivateKey;

  uint256 public circleId;
  ISavingCircles.Circle public baseCircle;

  function setUp() external {
    owner = makeAddr('owner');
    (alice, _alicePrivateKey) = makeAddrAndKey('alice');
    bob = makeAddr('bob');
    carol = makeAddr('carol');

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

    token = new MockERC20('Test Token', 'TEST');
    savingCircles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    // A fresh, not-yet-started circle owned by alice
    baseCircle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));
    vm.prank(alice);
    circleId = savingCircles.create(baseCircle);
  }

  function _two(address _a, address _b) internal pure returns (address[] memory _members) {
    _members = new address[](2);
    _members[0] = _a;
    _members[1] = _b;
  }

  function _one(address _a) internal pure returns (address[] memory _members) {
    _members = new address[](1);
    _members[0] = _a;
  }

  function test_AddMembersWhenCalledByOwnerBeforeStart() external {
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.MemberAdded(circleId, bob);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.MemberAdded(circleId, carol);

    vm.prank(alice);
    savingCircles.addMembers(circleId, _two(bob, carol));

    assertTrue(savingCircles.isMember(circleId, bob));
    assertTrue(savingCircles.isMember(circleId, carol));

    address[] memory circleMembers = savingCircles.getCircleMembers(circleId);
    assertEq(circleMembers.length, 3);
    assertEq(circleMembers[0], alice);
    assertEq(circleMembers[1], bob);
    assertEq(circleMembers[2], carol);

    assertEq(savingCircles.memberIndex(circleId, bob), 1);
    assertEq(savingCircles.memberIndex(circleId, carol), 2);

    uint256[] memory bobCircles = savingCircles.getMemberCircles(bob);
    assertEq(bobCircles.length, 1);
    assertEq(bobCircles[0], circleId);
  }

  function test_AddMembersRevertWhenCallerIsNotCircleOwner() external {
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotOwner.selector));
    vm.prank(STRANGER);
    savingCircles.addMembers(circleId, _one(bob));

    // The protocol owner is not the circle owner either
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotOwner.selector));
    vm.prank(owner);
    savingCircles.addMembers(circleId, _one(bob));
  }

  function test_AddMembersRevertWhenCircleIsActive() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(bob));

    vm.prank(alice);
    savingCircles.start(circleId);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyActive.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(carol));
  }

  function test_AddMembersRevertWhenMembersIsEmpty() external {
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidMemberCount.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, new address[](0));
  }

  function test_AddMembersRevertWhenMemberIsZeroAddress() external {
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidMemberAddress.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(address(0)));
  }

  function test_AddMembersRevertWhenMemberAlreadyExists() external {
    // The owner is a member from create()
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyMember.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(alice));
  }

  function test_AddMembersRevertWhenMembersContainsDuplicates() external {
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyMember.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, _two(bob, bob));
  }

  function test_AddMembersRevertWhenExceedingMaxMembers() external {
    uint256 max = savingCircles.MAX_MEMBERS();

    // Owner already occupies one slot; filling to the cap succeeds
    address[] memory fill = new address[](max - 1);
    for (uint256 i = 0; i < fill.length; i++) {
      fill[i] = makeAddr(string(abi.encodePacked('member', i)));
    }
    vm.prank(alice);
    savingCircles.addMembers(circleId, fill);

    // One more goes over the cap
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidMemberCount.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(bob));
  }

  function test_AddMembersRevertWhenCircleDoesNotExist() external {
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    vm.prank(alice);
    savingCircles.addMembers(type(uint256).max, _one(bob));
  }

  function test_AddMembersRevertWhenCircleIsDecommissioned() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(bob));
    vm.prank(alice);
    savingCircles.start(circleId);

    // Miss round 0 entirely so the circle becomes decommissionable
    uint256 start = savingCircles.getCircle(circleId).effectiveCircleStartTime;
    vm.warp(start + (DEPOSIT_INTERVAL * 2));
    vm.prank(alice);
    savingCircles.decommission(circleId);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotCommissioned.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(carol));
  }

  function test_AddMembersCoexistsWithRedeemInvite() external {
    // bob joins via the signed-invite path
    bytes memory signature = _signInvite(address(savingCircles), circleId, 1, _alicePrivateKey);
    vm.prank(bob);
    savingCircles.redeemInvite(circleId, 1, signature);

    // carol is added directly by the owner
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(carol));

    address[] memory circleMembers = savingCircles.getCircleMembers(circleId);
    assertEq(circleMembers.length, 3);
    assertEq(savingCircles.memberIndex(circleId, bob), 1);
    assertEq(savingCircles.memberIndex(circleId, carol), 2);

    // A directly-added member cannot redeem an invite afterwards
    bytes memory signature2 = _signInvite(address(savingCircles), circleId, 2, _alicePrivateKey);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyMember.selector));
    vm.prank(carol);
    savingCircles.redeemInvite(circleId, 2, signature2);
  }

  function test_AddMembersFullLifecycle() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _two(bob, carol));
    vm.prank(alice);
    savingCircles.start(circleId);

    address[] memory circleMembers = savingCircles.getCircleMembers(circleId);

    // Everyone deposits for round 0
    for (uint256 i = 0; i < circleMembers.length; i++) {
      address member = circleMembers[i];
      token.mint(member, DEPOSIT_AMOUNT);
      vm.startPrank(member);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(circleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    // Round 0 payout goes to the first member (the owner)
    assertTrue(savingCircles.isMemberWithdrawable(circleId, alice));
    vm.prank(alice);
    savingCircles.withdraw(circleId);
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT * circleMembers.length);
  }

  function test_AddMembersRevertWhenCircleIsFinished() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(bob));
    vm.prank(alice);
    savingCircles.start(circleId);

    address[] memory circleMembers = savingCircles.getCircleMembers(circleId);

    // Complete the full circle: everyone deposits and claims each round
    for (uint256 round = 0; round < circleMembers.length; round++) {
      for (uint256 i = 0; i < circleMembers.length; i++) {
        address member = circleMembers[i];
        token.mint(member, DEPOSIT_AMOUNT);
        vm.startPrank(member);
        token.approve(address(savingCircles), DEPOSIT_AMOUNT);
        savingCircles.deposit(circleId, DEPOSIT_AMOUNT);
        vm.stopPrank();
      }
      vm.prank(circleMembers[round]);
      savingCircles.withdraw(circleId);
      if (round + 1 < circleMembers.length) {
        vm.warp(block.timestamp + DEPOSIT_INTERVAL);
      }
    }

    // isActive resets once everyone has claimed; the roster must stay closed
    assertFalse(savingCircles.isActive(circleId));
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyActive.selector));
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(carol));
  }

  function test_RedeemInviteRevertWhenExceedingMaxMembers() external {
    uint256 max = savingCircles.MAX_MEMBERS();

    address[] memory fill = new address[](max - 1);
    for (uint256 i = 0; i < fill.length; i++) {
      fill[i] = makeAddr(string(abi.encodePacked('capMember', i)));
    }
    vm.prank(alice);
    savingCircles.addMembers(circleId, fill);

    bytes memory signature = _signInvite(address(savingCircles), circleId, 1, _alicePrivateKey);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidMemberCount.selector));
    vm.prank(bob);
    savingCircles.redeemInvite(circleId, 1, signature);
  }

  function test_RemoveMemberByOwnerPreservesPayoutOrder() external {
    address dave = makeAddr('dave');
    address[] memory three = new address[](3);
    three[0] = bob;
    three[1] = carol;
    three[2] = dave;
    vm.prank(alice);
    savingCircles.addMembers(circleId, three);

    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.MemberRemoved(circleId, carol);
    vm.prank(alice);
    savingCircles.removeMember(circleId, carol);

    assertFalse(savingCircles.isMember(circleId, carol));
    assertEq(savingCircles.getMemberCircles(carol).length, 0);

    // Order preserved with the tail reindexed: alice, bob, dave
    address[] memory circleMembers = savingCircles.getCircleMembers(circleId);
    assertEq(circleMembers.length, 3);
    assertEq(circleMembers[0], alice);
    assertEq(circleMembers[1], bob);
    assertEq(circleMembers[2], dave);
    assertEq(savingCircles.memberIndex(circleId, dave), 2);

    // The removed member can be re-added later
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(carol));
    assertTrue(savingCircles.isMember(circleId, carol));
    assertEq(savingCircles.memberIndex(circleId, carol), 3);
  }

  function test_RemoveMemberByMemberThemselves() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(bob));

    // A pushed member can decline the membership without the owner
    vm.prank(bob);
    savingCircles.removeMember(circleId, bob);

    assertFalse(savingCircles.isMember(circleId, bob));
    assertEq(savingCircles.getMemberCircles(bob).length, 0);
  }

  function test_RemoveMemberRevertWhenCallerIsNeitherOwnerNorMember() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(bob));

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotOwner.selector));
    vm.prank(STRANGER);
    savingCircles.removeMember(circleId, bob);
  }

  function test_RemoveMemberRevertWhenRemovingOwner() external {
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.InvalidMemberAddress.selector));
    vm.prank(alice);
    savingCircles.removeMember(circleId, alice);
  }

  function test_RemoveMemberRevertWhenNotMember() external {
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    vm.prank(alice);
    savingCircles.removeMember(circleId, bob);
  }

  function test_RemoveMemberRevertWhenCircleIsActive() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _one(bob));
    vm.prank(alice);
    savingCircles.start(circleId);

    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyActive.selector));
    vm.prank(alice);
    savingCircles.removeMember(circleId, bob);
  }

  function test_RemoveMemberThenStartAndCompleteLifecycle() external {
    vm.prank(alice);
    savingCircles.addMembers(circleId, _two(bob, carol));
    vm.prank(alice);
    savingCircles.removeMember(circleId, bob);
    vm.prank(alice);
    savingCircles.start(circleId);

    address[] memory circleMembers = savingCircles.getCircleMembers(circleId);
    assertEq(circleMembers.length, 2);

    for (uint256 i = 0; i < circleMembers.length; i++) {
      address member = circleMembers[i];
      token.mint(member, DEPOSIT_AMOUNT);
      vm.startPrank(member);
      token.approve(address(savingCircles), DEPOSIT_AMOUNT);
      savingCircles.deposit(circleId, DEPOSIT_AMOUNT);
      vm.stopPrank();
    }

    assertTrue(savingCircles.isMemberWithdrawable(circleId, alice));
    vm.prank(alice);
    savingCircles.withdraw(circleId);
    assertEq(token.balanceOf(alice), DEPOSIT_AMOUNT * 2);
  }

  function test_AddMembersFuzz(uint8 _count) external {
    uint256 max = savingCircles.MAX_MEMBERS();
    uint256 count = bound(uint256(_count), 1, max - 1); // owner occupies one slot

    address[] memory newMembers = new address[](count);
    for (uint256 i = 0; i < count; i++) {
      newMembers[i] = makeAddr(string(abi.encodePacked('fuzzMember', i)));
    }

    vm.prank(alice);
    savingCircles.addMembers(circleId, newMembers);

    address[] memory circleMembers = savingCircles.getCircleMembers(circleId);
    assertEq(circleMembers.length, count + 1);

    for (uint256 i = 0; i < count; i++) {
      assertTrue(savingCircles.isMember(circleId, newMembers[i]));
      assertEq(savingCircles.memberIndex(circleId, newMembers[i]), i + 1);
    }
  }
}
