// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test, Vm} from 'forge-std/Test.sol';

import {GoalSavingCircles} from 'src/contracts/GoalSavingCircles.sol';
import {IGoalSavingCircles} from 'src/interfaces/IGoalSavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

/**
 * @notice Unit tests for {GoalSavingCircles}.
 * @dev Actors: owner is the registry admin, alice is the goal owner (signs invites), bob and
 *      carol are invited members, dave is a stranger with tokens (depositFor payer).
 */
contract GoalSavingCirclesUnit is Test {
  GoalSavingCircles public goalCircles;
  MockERC20 public token;

  uint256 public constant GOAL_AMOUNT = 10 ether;
  uint256 public constant DURATION = 30 days;
  uint256 public constant START_BAL = 1000 ether;

  address public owner;
  address public alice;
  uint256 internal _alicePrivateKey;
  address public bob;
  uint256 internal _bobPrivateKey;
  address public carol;
  address public dave;
  address public beneficiary;

  function setUp() public {
    owner = makeAddr('owner');
    (alice, _alicePrivateKey) = makeAddrAndKey('alice');
    (bob, _bobPrivateKey) = makeAddrAndKey('bob');
    carol = makeAddr('carol');
    dave = makeAddr('dave');
    beneficiary = makeAddr('beneficiary');

    vm.startPrank(owner);
    goalCircles = GoalSavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new GoalSavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(GoalSavingCircles.initialize.selector, owner)
        )
      )
    );
    token = new MockERC20('Test', 'TST');
    goalCircles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    address[4] memory holders = [alice, bob, carol, dave];
    for (uint256 i = 0; i < holders.length; i++) {
      token.mint(holders[i], START_BAL);
      vm.prank(holders[i]);
      token.approve(address(goalCircles), type(uint256).max);
    }
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// @dev EIP-712 'StacksInvite' v1 signature over Invite(uint256 id,uint256 nonce), with the
  ///      goal contract as verifyingContract.
  function _signGoalInvite(uint256 _id, uint256 _nonce, uint256 _signerKey) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(keccak256('Invite(uint256 id,uint256 nonce)'), _id, _nonce));
    bytes32 domainSeparator = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256(bytes('StacksInvite')),
        keccak256(bytes('1')),
        block.chainid,
        address(goalCircles)
      )
    );
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @dev alice creates a goal for GOAL_AMOUNT due in DURATION.
  function _createGoal(address _beneficiary) internal returns (uint256 _id) {
    vm.prank(alice);
    _id = goalCircles.create(address(token), GOAL_AMOUNT, block.timestamp + DURATION, _beneficiary);
  }

  /// @dev `_member` redeems an alice-signed invite for goal `_id`.
  function _join(uint256 _id, address _member, uint256 _nonce) internal {
    bytes memory signature = _signGoalInvite(_id, _nonce, _alicePrivateKey);
    vm.prank(_member);
    goalCircles.redeemInvite(_id, _nonce, signature);
  }

  /// @dev alice creates a goal and invites bob and carol.
  function _createGoalWithMembers(address _beneficiary) internal returns (uint256 _id) {
    _id = _createGoal(_beneficiary);
    _join(_id, bob, 1);
    _join(_id, carol, 2);
  }

  function _deposit(uint256 _id, address _who, uint256 _value) internal {
    vm.prank(_who);
    goalCircles.deposit(_id, _value);
  }

  /// @dev Assert no GoalReached event is present in the recorded logs.
  function _assertNoGoalReached(Vm.Log[] memory _logs) internal pure {
    for (uint256 i = 0; i < _logs.length; i++) {
      assertTrue(_logs[i].topics[0] != keccak256('GoalReached(uint256,uint256)'), 'unexpected GoalReached');
    }
  }

  // ==========================================================================
  // Initialization & admin
  // ==========================================================================

  function test_InitializeSetsAdminOwner() public view {
    assertEq(goalCircles.owner(), owner);
  }

  function test_InitializeWhenCalledTwice() public {
    vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
    goalCircles.initialize(alice);
  }

  function test_ImplementationConstructorDisablesInitializers() public {
    GoalSavingCircles implementation = new GoalSavingCircles();
    vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
    implementation.initialize(owner);
  }

  function test_SetTokenAllowedWhenCallerIsOwner() public {
    address newToken = makeAddr('newToken');

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.TokenAllowed(newToken, true);
    vm.prank(owner);
    goalCircles.setTokenAllowed(newToken, true);

    assertTrue(goalCircles.isTokenAllowed(newToken));
  }

  function test_SetTokenAllowedWhenCallerIsNotOwner() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    goalCircles.setTokenAllowed(address(token), false);
  }

  function test_SetTokenAllowedWhenDisallowingToken() public {
    uint256 id = _createGoal(beneficiary);

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.TokenAllowed(address(token), false);
    vm.prank(owner);
    goalCircles.setTokenAllowed(address(token), false);
    assertFalse(goalCircles.isTokenAllowed(address(token)));

    // The existing goal keeps working: deposits still accepted.
    _deposit(id, alice, 1 ether);
    assertEq(goalCircles.totalDeposited(id), 1 ether);

    // But new goals with the disallowed token are rejected.
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.TokenNotAllowed.selector));
    goalCircles.create(address(token), GOAL_AMOUNT, block.timestamp + DURATION, beneficiary);
  }

  // ==========================================================================
  // create
  // ==========================================================================

  function test_CreateGoalWithValidParameters() public {
    uint256 deadline = block.timestamp + DURATION;

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.GoalCreated(0, alice, address(token), GOAL_AMOUNT, deadline, beneficiary);
    vm.prank(alice);
    uint256 id = goalCircles.create(address(token), GOAL_AMOUNT, deadline, beneficiary);

    assertEq(id, 0);
    IGoalSavingCircles.Goal memory goal = goalCircles.getGoal(id);
    assertEq(goal.owner, alice);
    assertEq(goal.token, address(token));
    assertEq(goal.beneficiary, beneficiary);
    assertEq(goal.goalAmount, GOAL_AMOUNT);
    assertEq(goal.deadline, deadline);

    assertTrue(goalCircles.isMember(id, alice));
    address[] memory members = goalCircles.getGoalMembers(id);
    assertEq(members.length, 1);
    assertEq(members[0], alice);
    uint256[] memory ids = goalCircles.getMemberGoals(alice);
    assertEq(ids.length, 1);
    assertEq(ids[0], id);
  }

  function test_CreateGoalIncrementsNextId() public {
    uint256 first = _createGoal(beneficiary);
    uint256 second = _createGoal(address(0));

    assertEq(first, 0);
    assertEq(second, 1);
    assertEq(goalCircles.nextId(), 2);
  }

  function test_CreateGoalWhenTokenNotAllowed() public {
    MockERC20 otherToken = new MockERC20('Other', 'OTH');
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.TokenNotAllowed.selector));
    goalCircles.create(address(otherToken), GOAL_AMOUNT, block.timestamp + DURATION, beneficiary);
  }

  function test_CreateGoalWhenGoalAmountIsZero() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.InvalidGoalAmount.selector));
    goalCircles.create(address(token), 0, block.timestamp + DURATION, beneficiary);
  }

  function test_CreateGoalWhenDeadlineNotInFuture() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.InvalidDeadline.selector));
    goalCircles.create(address(token), GOAL_AMOUNT, block.timestamp, beneficiary);
  }

  function test_CreateGoalWithZeroBeneficiary() public {
    uint256 id = _createGoal(address(0));
    assertEq(goalCircles.getGoal(id).beneficiary, address(0));
  }

  // ==========================================================================
  // redeemInvite
  // ==========================================================================

  function test_RedeemInviteWithValidSignature() public {
    uint256 id = _createGoal(beneficiary);
    bytes memory signature = _signGoalInvite(id, 1, _alicePrivateKey);

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.InviteRedeemed(id, bob);
    vm.prank(bob);
    goalCircles.redeemInvite(id, 1, signature);

    assertTrue(goalCircles.isMember(id, bob));
    assertTrue(goalCircles.usedNonces(id, 1));
    address[] memory members = goalCircles.getGoalMembers(id);
    assertEq(members.length, 2);
    assertEq(members[1], bob);
    uint256[] memory ids = goalCircles.getMemberGoals(bob);
    assertEq(ids.length, 1);
    assertEq(ids[0], id);
  }

  function test_RedeemInviteWhenSignerIsNotGoalOwner() public {
    uint256 id = _createGoal(beneficiary);
    bytes memory signature = _signGoalInvite(id, 1, _bobPrivateKey);

    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.InvalidSigner.selector));
    goalCircles.redeemInvite(id, 1, signature);
  }

  function test_RedeemInviteWhenNonceAlreadyUsed() public {
    uint256 id = _createGoal(beneficiary);
    _join(id, bob, 1);

    bytes memory signature = _signGoalInvite(id, 1, _alicePrivateKey);
    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.InviteAlreadyUsed.selector));
    goalCircles.redeemInvite(id, 1, signature);
  }

  function test_RedeemInviteWhenAlreadyMember() public {
    uint256 id = _createGoal(beneficiary);
    _join(id, bob, 1);

    bytes memory signature = _signGoalInvite(id, 2, _alicePrivateKey);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.AlreadyMember.selector));
    goalCircles.redeemInvite(id, 2, signature);
  }

  function test_RedeemInviteWhenGoalDoesNotExist() public {
    bytes memory signature = _signGoalInvite(999, 1, _alicePrivateKey);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotFound.selector));
    goalCircles.redeemInvite(999, 1, signature);
  }

  function test_RedeemInviteWhenDeadlinePassed() public {
    uint256 id = _createGoal(beneficiary);
    bytes memory signature = _signGoalInvite(id, 1, _alicePrivateKey);

    vm.warp(block.timestamp + DURATION);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotOpen.selector));
    goalCircles.redeemInvite(id, 1, signature);
  }

  function test_RedeemInviteWhenCancelled() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(alice);
    goalCircles.cancel(id);

    bytes memory signature = _signGoalInvite(id, 1, _alicePrivateKey);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotOpen.selector));
    goalCircles.redeemInvite(id, 1, signature);
  }

  function test_RedeemInviteWhenReleased() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    goalCircles.release(id);

    bytes memory signature = _signGoalInvite(id, 1, _alicePrivateKey);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotOpen.selector));
    goalCircles.redeemInvite(id, 1, signature);
  }

  function test_RedeemInviteAfterGoalReachedBeforeDeadline() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    assertTrue(goalCircles.goalReached(id));

    _join(id, bob, 1);
    assertTrue(goalCircles.isMember(id, bob));
  }

  function test_RedeemInviteNonceIsScopedPerGoal() public {
    uint256 first = _createGoal(beneficiary);
    uint256 second = _createGoal(address(0));

    _join(first, bob, 7);
    _join(second, bob, 7);

    assertTrue(goalCircles.usedNonces(first, 7));
    assertTrue(goalCircles.usedNonces(second, 7));
    assertTrue(goalCircles.isMember(first, bob));
    assertTrue(goalCircles.isMember(second, bob));
  }

  // ==========================================================================
  // deposit / depositFor
  // ==========================================================================

  function test_DepositWhenCallerIsMember() public {
    uint256 id = _createGoalWithMembers(beneficiary);

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.FundsDeposited(id, bob, 1 ether);
    _deposit(id, bob, 1 ether);

    assertEq(goalCircles.contributions(id, bob), 1 ether);
    assertEq(goalCircles.totalDeposited(id), 1 ether);
    assertEq(token.balanceOf(address(goalCircles)), 1 ether);
    assertEq(token.balanceOf(bob), START_BAL - 1 ether);
  }

  function test_DepositWhenCallerIsNotMember() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotMember.selector));
    goalCircles.deposit(id, 1 ether);
  }

  function test_DepositWhenValueIsZero() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.InvalidDeposit.selector));
    goalCircles.deposit(id, 0);
  }

  function test_DepositMultipleTimesAccumulates() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, 1 ether);
    _deposit(id, alice, 2 ether);
    _deposit(id, alice, 3 ether);

    assertEq(goalCircles.contributions(id, alice), 6 ether);
    assertEq(goalCircles.totalDeposited(id), 6 ether);
  }

  function test_DepositWhenGoalDoesNotExist() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotFound.selector));
    goalCircles.deposit(999, 1 ether);
  }

  function test_DepositWhenDeadlinePassed() public {
    uint256 id = _createGoal(beneficiary);
    vm.warp(block.timestamp + DURATION + 1);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotOpen.selector));
    goalCircles.deposit(id, 1 ether);
  }

  function test_DepositAtExactDeadlineTimestamp() public {
    uint256 deadline = block.timestamp + DURATION;
    uint256 id = _createGoal(beneficiary);
    vm.warp(deadline);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotOpen.selector));
    goalCircles.deposit(id, 1 ether);
  }

  function test_DepositWhenCancelled() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(alice);
    goalCircles.cancel(id);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotOpen.selector));
    goalCircles.deposit(id, 1 ether);
  }

  function test_DepositWhenReleased() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    goalCircles.release(id);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotOpen.selector));
    goalCircles.deposit(id, 1 ether);
  }

  function test_DepositCrossingGoalEmitsGoalReachedOnce() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT - 1 ether);

    // The crossing deposit emits GoalReached (with the pot size) then FundsDeposited.
    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.GoalReached(id, GOAL_AMOUNT + 1 ether);
    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.FundsDeposited(id, bob, 2 ether);
    _deposit(id, bob, 2 ether);
    assertTrue(goalCircles.goalReached(id));

    // A later deposit emits no second GoalReached.
    vm.recordLogs();
    _deposit(id, carol, 1 ether);
    _assertNoGoalReached(vm.getRecordedLogs());
  }

  function test_DepositOvershootAllowed() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT + 5 ether);

    assertEq(goalCircles.totalDeposited(id), GOAL_AMOUNT + 5 ether);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funded);
  }

  function test_DepositAfterGoalReachedBeforeDeadline() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);

    _deposit(id, bob, 1 ether);
    assertEq(goalCircles.totalDeposited(id), GOAL_AMOUNT + 1 ether);
  }

  function test_DepositForCreditsMemberAndPullsFromCaller() public {
    uint256 id = _createGoalWithMembers(beneficiary);

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.FundsDeposited(id, bob, 3 ether);
    vm.prank(dave);
    goalCircles.depositFor(id, bob, 3 ether);

    assertEq(token.balanceOf(dave), START_BAL - 3 ether);
    assertEq(token.balanceOf(bob), START_BAL);
    assertEq(goalCircles.contributions(id, bob), 3 ether);
    assertEq(goalCircles.contributions(id, dave), 0);
    assertEq(goalCircles.totalDeposited(id), 3 ether);
  }

  function test_DepositForWhenTargetIsNotMember() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotMember.selector));
    goalCircles.depositFor(id, bob, 1 ether);
  }

  // ==========================================================================
  // withdraw
  // ==========================================================================

  function test_WithdrawWhenGoalFailed() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    _deposit(id, bob, 4 ether);
    vm.warp(block.timestamp + DURATION);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Failed);

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.FundsWithdrawn(id, bob, 4 ether);
    vm.prank(bob);
    goalCircles.withdraw(id);

    assertEq(goalCircles.contributions(id, bob), 0);
    assertEq(goalCircles.totalDeposited(id), 0);
    assertEq(token.balanceOf(bob), START_BAL);
  }

  function test_WithdrawWhenGoalCancelled() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    _deposit(id, carol, 2 ether);
    vm.prank(alice);
    goalCircles.cancel(id);

    vm.prank(carol);
    goalCircles.withdraw(id);

    assertEq(goalCircles.contributions(id, carol), 0);
    assertEq(token.balanceOf(carol), START_BAL);
  }

  function test_WithdrawWhenFundedWithoutBeneficiary() public {
    uint256 id = _createGoalWithMembers(address(0));
    _deposit(id, alice, GOAL_AMOUNT);
    _deposit(id, bob, 1 ether);

    vm.prank(bob);
    goalCircles.withdraw(id);

    assertEq(token.balanceOf(bob), START_BAL);
    assertEq(goalCircles.totalDeposited(id), GOAL_AMOUNT);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funded);
  }

  function test_WithdrawWhenFundedWithBeneficiary() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotWithdrawable.selector));
    goalCircles.withdraw(id);
  }

  function test_WithdrawWhenFunding() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, 1 ether);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotWithdrawable.selector));
    goalCircles.withdraw(id);
  }

  function test_WithdrawWhenReleased() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    goalCircles.release(id);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotWithdrawable.selector));
    goalCircles.withdraw(id);
  }

  function test_WithdrawWhenGoalDoesNotExist() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotFound.selector));
    goalCircles.withdraw(999);
  }

  function test_WithdrawWhenNothingToWithdraw() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    vm.warp(block.timestamp + DURATION);

    // Member with a zero contribution.
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NothingToWithdraw.selector));
    goalCircles.withdraw(id);

    // Non-members always have zero contribution too.
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NothingToWithdraw.selector));
    goalCircles.withdraw(id);
  }

  function test_WithdrawTwiceReverts() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, 1 ether);
    vm.warp(block.timestamp + DURATION);

    vm.prank(alice);
    goalCircles.withdraw(id);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NothingToWithdraw.selector));
    goalCircles.withdraw(id);
  }

  function test_WithdrawByAllMembersDrainsPot() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    _deposit(id, alice, 1 ether);
    _deposit(id, bob, 2 ether);
    _deposit(id, carol, 3 ether);
    vm.warp(block.timestamp + DURATION);

    address[3] memory members = [alice, bob, carol];
    for (uint256 i = 0; i < members.length; i++) {
      vm.prank(members[i]);
      goalCircles.withdraw(id);
      assertEq(token.balanceOf(members[i]), START_BAL);
    }

    assertEq(goalCircles.totalDeposited(id), 0);
    assertEq(token.balanceOf(address(goalCircles)), 0);
  }

  function test_WithdrawThenRedepositWhileFundedWithoutBeneficiary() public {
    uint256 id = _createGoal(address(0));
    _deposit(id, alice, GOAL_AMOUNT);
    assertTrue(goalCircles.goalReached(id));

    vm.prank(alice);
    goalCircles.withdraw(id);
    assertEq(goalCircles.totalDeposited(id), 0);
    assertTrue(goalCircles.goalReached(id)); // latch persists below goalAmount

    _deposit(id, alice, 1 ether);
    assertEq(goalCircles.contributions(id, alice), 1 ether);
    assertEq(goalCircles.totalDeposited(id), 1 ether);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funded);
  }

  // ==========================================================================
  // release
  // ==========================================================================

  function test_ReleaseWhenFundedWithBeneficiary() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT + 2 ether); // overshoot travels with the pot

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.GoalReleased(id, beneficiary, GOAL_AMOUNT + 2 ether);
    goalCircles.release(id);

    assertTrue(goalCircles.released(id));
    assertEq(goalCircles.totalDeposited(id), 0);
    assertEq(token.balanceOf(beneficiary), GOAL_AMOUNT + 2 ether);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Released);
    // Contributions persist as historical receipts.
    assertEq(goalCircles.contributions(id, alice), GOAL_AMOUNT + 2 ether);
  }

  function test_ReleaseByNonMember() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);

    vm.prank(dave);
    goalCircles.release(id);
    assertEq(token.balanceOf(beneficiary), GOAL_AMOUNT);
  }

  function test_ReleaseAfterDeadlineWhenFunded() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    vm.warp(block.timestamp + DURATION + 365 days);

    goalCircles.release(id);
    assertEq(token.balanceOf(beneficiary), GOAL_AMOUNT);
  }

  function test_ReleaseWhenFunding() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, 1 ether);

    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotReleasable.selector));
    goalCircles.release(id);
  }

  function test_ReleaseWhenFailed() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, 1 ether);
    vm.warp(block.timestamp + DURATION);

    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotReleasable.selector));
    goalCircles.release(id);
  }

  function test_ReleaseWhenCancelled() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(alice);
    goalCircles.cancel(id);

    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotReleasable.selector));
    goalCircles.release(id);
  }

  function test_ReleaseWhenBeneficiaryIsZero() public {
    uint256 id = _createGoal(address(0));
    _deposit(id, alice, GOAL_AMOUNT);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funded);

    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotReleasable.selector));
    goalCircles.release(id);
  }

  function test_ReleaseTwiceReverts() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    goalCircles.release(id);

    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotReleasable.selector));
    goalCircles.release(id);
  }

  function test_ReleaseWhenGoalDoesNotExist() public {
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotFound.selector));
    goalCircles.release(999);
  }

  // ==========================================================================
  // cancel
  // ==========================================================================

  function test_CancelWhenCallerIsGoalOwnerDuringFunding() public {
    uint256 id = _createGoal(beneficiary);

    vm.expectEmit(true, true, true, true);
    emit IGoalSavingCircles.GoalCancelled(id);
    vm.prank(alice);
    goalCircles.cancel(id);

    assertTrue(goalCircles.cancelled(id));
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Cancelled);
  }

  function test_CancelWhenCallerIsNotGoalOwner() public {
    uint256 id = _createGoalWithMembers(beneficiary);

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotOwner.selector));
    goalCircles.cancel(id);

    // The registry admin is not the goal owner either.
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotOwner.selector));
    goalCircles.cancel(id);
  }

  function test_CancelWhenFunded() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotCancellable.selector));
    goalCircles.cancel(id);
  }

  function test_CancelWhenFailed() public {
    uint256 id = _createGoal(beneficiary);
    vm.warp(block.timestamp + DURATION);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotCancellable.selector));
    goalCircles.cancel(id);
  }

  function test_CancelWhenAlreadyCancelled() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(alice);
    goalCircles.cancel(id);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.NotCancellable.selector));
    goalCircles.cancel(id);
  }

  function test_CancelWhenGoalDoesNotExist() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotFound.selector));
    goalCircles.cancel(999);
  }

  function test_CancelThenWithdrawRefundsEveryMemberExactly() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    _deposit(id, alice, 1 ether);
    _deposit(id, bob, 2 ether);
    _deposit(id, carol, 3 ether);

    vm.prank(alice);
    goalCircles.cancel(id);

    address[3] memory members = [alice, bob, carol];
    for (uint256 i = 0; i < members.length; i++) {
      vm.prank(members[i]);
      goalCircles.withdraw(id);
      assertEq(token.balanceOf(members[i]), START_BAL);
    }
    assertEq(token.balanceOf(address(goalCircles)), 0);
  }

  // ==========================================================================
  // goalState & views
  // ==========================================================================

  function test_GoalStateWhenFunding() public {
    uint256 id = _createGoal(beneficiary);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funding);
  }

  function test_GoalStateWhenFunded() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funded);
  }

  function test_GoalStateWhenFailedAfterDeadline() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, 1 ether);
    vm.warp(block.timestamp + DURATION + 1);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Failed);
  }

  function test_GoalStateAtExactDeadlineIsFailed() public {
    uint256 deadline = block.timestamp + DURATION;
    uint256 id = _createGoal(beneficiary);
    vm.warp(deadline);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Failed);
  }

  function test_GoalStateWhenCancelled() public {
    uint256 id = _createGoal(beneficiary);
    vm.prank(alice);
    goalCircles.cancel(id);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Cancelled);
  }

  function test_GoalStateWhenReleased() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    goalCircles.release(id);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Released);
  }

  function test_GoalStateFundedPersistsAfterDeadline() public {
    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT);
    vm.warp(block.timestamp + DURATION + 365 days);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funded);
  }

  function test_GoalStateFundedPersistsAfterWithdrawalsBelowGoal() public {
    uint256 id = _createGoal(address(0));
    _deposit(id, alice, GOAL_AMOUNT);

    vm.prank(alice);
    goalCircles.withdraw(id);

    assertEq(goalCircles.totalDeposited(id), 0);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Funded);
  }

  function test_GoalStateWhenGoalDoesNotExist() public {
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotFound.selector));
    goalCircles.goalState(999);
  }

  function test_GetGoalReturnsConfig() public {
    uint256 deadline = block.timestamp + DURATION;
    uint256 id = _createGoal(beneficiary);

    IGoalSavingCircles.Goal memory goal = goalCircles.getGoal(id);
    assertEq(goal.owner, alice);
    assertEq(goal.token, address(token));
    assertEq(goal.beneficiary, beneficiary);
    assertEq(goal.goalAmount, GOAL_AMOUNT);
    assertEq(goal.deadline, deadline);
  }

  function test_GetGoalWhenGoalDoesNotExist() public {
    vm.expectRevert(abi.encodeWithSelector(IGoalSavingCircles.GoalNotFound.selector));
    goalCircles.getGoal(999);
  }

  function test_GetGoalMembersReturnsRoster() public {
    uint256 id = _createGoalWithMembers(beneficiary);

    address[] memory members = goalCircles.getGoalMembers(id);
    assertEq(members.length, 3);
    assertEq(members[0], alice); // owner first
    assertEq(members[1], bob); // then invite-redemption order
    assertEq(members[2], carol);
  }

  function test_GetMemberGoalsReturnsIds() public {
    uint256 first = _createGoal(beneficiary);
    uint256 second = _createGoal(address(0));
    _join(first, bob, 1);
    _join(second, bob, 1);

    uint256[] memory bobIds = goalCircles.getMemberGoals(bob);
    assertEq(bobIds.length, 2);
    assertEq(bobIds[0], first);
    assertEq(bobIds[1], second);

    uint256[] memory aliceIds = goalCircles.getMemberGoals(alice);
    assertEq(aliceIds.length, 2);
  }

  function test_GetMemberContributionsAlignedArrays() public {
    uint256 id = _createGoalWithMembers(beneficiary);
    _deposit(id, alice, 1 ether);
    _deposit(id, bob, 2 ether);

    (address[] memory members, uint256[] memory amounts) = goalCircles.getMemberContributions(id);
    assertEq(members.length, 3);
    assertEq(amounts.length, 3);
    assertEq(members[0], alice);
    assertEq(amounts[0], 1 ether);
    assertEq(members[1], bob);
    assertEq(amounts[1], 2 ether);
    assertEq(members[2], carol);
    assertEq(amounts[2], 0);
  }

  function test_IsTokenAllowedReflectsAllowlist() public {
    assertTrue(goalCircles.isTokenAllowed(address(token)));
    assertFalse(goalCircles.isTokenAllowed(makeAddr('unknownToken')));

    vm.prank(owner);
    goalCircles.setTokenAllowed(address(token), false);
    assertFalse(goalCircles.isTokenAllowed(address(token)));
  }

  // ==========================================================================
  // Fuzz
  // ==========================================================================

  function testFuzz_DepositWithdrawConservation(uint256[] memory _amounts) public {
    vm.assume(_amounts.length > 0);

    // A goal too big to ever reach, so the deadline forces Failed.
    vm.prank(alice);
    uint256 id = goalCircles.create(address(token), 1e36, block.timestamp + DURATION, beneficiary);
    _join(id, bob, 1);
    _join(id, carol, 2);

    address[3] memory members = [alice, bob, carol];
    uint256 count = _amounts.length < 8 ? _amounts.length : 8;
    for (uint256 i = 0; i < count; i++) {
      uint256 amount = bound(_amounts[i], 1, 100 ether);
      _deposit(id, members[i % 3], amount);
    }

    vm.warp(block.timestamp + DURATION);
    assertTrue(goalCircles.goalState(id) == IGoalSavingCircles.GoalState.Failed);

    for (uint256 i = 0; i < members.length; i++) {
      if (goalCircles.contributions(id, members[i]) > 0) {
        vm.prank(members[i]);
        goalCircles.withdraw(id);
      }
      assertEq(token.balanceOf(members[i]), START_BAL, 'member made whole');
    }

    assertEq(goalCircles.totalDeposited(id), 0);
    assertEq(token.balanceOf(address(goalCircles)), 0, 'contract drained');
  }

  function testFuzz_ReleasePaysExactPot(uint256 _overshoot) public {
    _overshoot = bound(_overshoot, 0, 500 ether);

    uint256 id = _createGoal(beneficiary);
    _deposit(id, alice, GOAL_AMOUNT + _overshoot);

    uint256 pot = goalCircles.totalDeposited(id);
    assertEq(pot, GOAL_AMOUNT + _overshoot);

    goalCircles.release(id);

    assertEq(token.balanceOf(beneficiary), pot, 'beneficiary paid the exact pot');
    assertEq(goalCircles.totalDeposited(id), 0);
    assertEq(token.balanceOf(address(goalCircles)), 0);
  }
}
