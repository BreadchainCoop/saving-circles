// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

import {CollateralSavingCircles} from 'src/contracts/CollateralSavingCircles.sol';
import {ICollateralSavingCircles} from 'src/interfaces/ICollateralSavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

/**
 * @notice Unit tests for {CollateralSavingCircles}.
 * @dev Scenario constants: n = 3 slots, m = 1e18 per round, round = 1 day.
 *      Cycle 0 = rounds 0..2 (collateral), cycle 1 = rounds 3..5 (payouts), circle ends at round 6.
 *      Slots: alice=0 (payout round 3), bob=1 (payout round 4), carol=2 (payout round 5).
 */
contract CollateralSavingCirclesUnit is Test {
  CollateralSavingCircles public circles;
  MockERC20 public token;

  address public owner = makeAddr('owner');
  address public stranger = makeAddr('stranger');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');

  uint256 public constant M = 1e18; // per-round deposit
  uint256 public constant N = 3; // slots
  uint256 public constant D = 1 days; // round duration
  uint256 public constant POT = N * M; // 3e18
  uint256 public constant COLLATERAL = N * M; // 3e18

  uint256 public id;
  uint256 public start;

  function setUp() public {
    vm.startPrank(owner);
    circles = CollateralSavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new CollateralSavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(CollateralSavingCircles.initialize.selector, owner)
        )
      )
    );
    token = new MockERC20('Test', 'TST');
    circles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    address[3] memory ms = [alice, bob, carol];
    for (uint256 i = 0; i < ms.length; i++) {
      token.mint(ms[i], 100e18);
      vm.prank(ms[i]);
      token.approve(address(circles), type(uint256).max);
    }
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// @dev Anyone (a stranger) creates the circle, the three members join, and it is started.
  function _createAndStart() internal {
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, D, N);

    vm.prank(alice);
    circles.join(id);
    vm.prank(bob);
    circles.join(id);
    vm.prank(carol);
    circles.join(id);

    vm.prank(stranger);
    circles.start(id);
    start = circles.getCircle(id).startTime;
  }

  /// @dev Warp to a point safely inside round `r`.
  function _enterRound(uint256 r) internal {
    vm.warp(start + r * D + 1);
  }

  function _depositAll(uint256 r) internal {
    _enterRound(r);
    vm.prank(alice);
    circles.deposit(id, M);
    vm.prank(bob);
    circles.deposit(id, M);
    vm.prank(carol);
    circles.deposit(id, M);
  }

  // --------------------------------------------------------------------------
  // Happy path
  // --------------------------------------------------------------------------

  function test_HappyPath_CollateralThenPayoutsThenReclaim() public {
    _createAndStart();

    // Cycle 0: everyone deposits, collateral accrues, nobody may withdraw.
    _depositAll(0);
    _depositAll(1);
    _depositAll(2);

    assertEq(circles.collateralOf(id, alice), COLLATERAL);
    assertEq(circles.collateralOf(id, bob), COLLATERAL);
    assertEq(circles.collateralOf(id, carol), COLLATERAL);
    assertTrue(circles.isFullyCollateralized(id));

    // Cycle 1: everyone deposits into the pots.
    _depositAll(3);
    _depositAll(4);
    _depositAll(5);

    // Payouts mature one round after the recipient's round; warp to the end.
    vm.warp(start + 6 * D + 1);

    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    circles.withdraw(id);
    assertEq(token.balanceOf(alice) - aliceBefore, POT);

    // Anyone can trigger a member's payout.
    uint256 bobBefore = token.balanceOf(bob);
    vm.prank(stranger);
    circles.withdrawFor(id, bob);
    assertEq(token.balanceOf(bob) - bobBefore, POT);

    uint256 carolBefore = token.balanceOf(carol);
    vm.prank(carol);
    circles.withdraw(id);
    assertEq(token.balanceOf(carol) - carolBefore, POT);

    // Everyone reclaims their intact collateral: net position is exactly zero.
    address[3] memory ms = [alice, bob, carol];
    for (uint256 i = 0; i < ms.length; i++) {
      vm.prank(ms[i]);
      circles.reclaimCollateral(id);
      assertEq(token.balanceOf(ms[i]), 100e18); // back to starting balance
    }
    assertEq(token.balanceOf(address(circles)), 0);
  }

  function test_CannotWithdrawDuringCollateralCycle() public {
    _createAndStart();
    _depositAll(0);
    _depositAll(1);
    _depositAll(2);

    // Still cycle 0 boundary — no payout round has matured.
    _enterRound(2);
    vm.prank(alice);
    vm.expectRevert(ICollateralSavingCircles.NotWithdrawable.selector);
    circles.withdraw(id);
  }

  // --------------------------------------------------------------------------
  // Safety: a defaulter's own collateral covers the shortfall; honest members are whole.
  // --------------------------------------------------------------------------

  function test_TotalDefaulter_RecipientsMadeWhole_HonestMembersLoseNothing() public {
    _createAndStart();

    // Cycle 0: everyone fully collateralizes (required to enter payouts).
    _depositAll(0);
    _depositAll(1);
    _depositAll(2);

    // Cycle 1: bob defaults on every deposit; alice and carol pay honestly.
    for (uint256 r = 3; r <= 5; r++) {
      _enterRound(r);
      vm.prank(alice);
      circles.deposit(id, M);
      vm.prank(carol);
      circles.deposit(id, M);
      // bob deposits nothing
    }

    vm.warp(start + 6 * D + 1);

    // Every recipient — including bob on his own round — still receives the full pot.
    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    circles.withdraw(id);
    assertEq(token.balanceOf(alice) - aliceBefore, POT, 'alice pot');

    uint256 bobBefore = token.balanceOf(bob);
    vm.prank(bob);
    circles.withdraw(id);
    assertEq(token.balanceOf(bob) - bobBefore, POT, 'bob pot');

    uint256 carolBefore = token.balanceOf(carol);
    vm.prank(carol);
    circles.withdraw(id);
    assertEq(token.balanceOf(carol) - carolBefore, POT, 'carol pot');

    // Bob's collateral was fully consumed covering his 3 missed deposits.
    assertEq(circles.collateralOf(id, bob), 0, 'bob collateral slashed to zero');

    // Honest members reclaim full collateral and end net-zero.
    vm.prank(alice);
    circles.reclaimCollateral(id);
    vm.prank(carol);
    circles.reclaimCollateral(id);
    assertEq(token.balanceOf(alice), 100e18, 'alice net zero');
    assertEq(token.balanceOf(carol), 100e18, 'carol net zero');

    // Bob has nothing left to reclaim; he paid his obligations out of collateral.
    vm.prank(bob);
    vm.expectRevert(ICollateralSavingCircles.NothingToReclaim.selector);
    circles.reclaimCollateral(id);

    // Bob is also net-zero: he defaulted 3e18 of deposits but forfeited 3e18 of collateral.
    assertEq(token.balanceOf(bob), 100e18, 'bob net zero');
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
  }

  function test_PartialDefault_SlashesOnlyTheDefaulter() public {
    _createAndStart();
    _depositAll(0);
    _depositAll(1);
    _depositAll(2);

    // bob misses only round 3 (alice's payout round); pays rounds 4 and 5.
    _enterRound(3);
    vm.prank(alice);
    circles.deposit(id, M);
    vm.prank(carol);
    circles.deposit(id, M);
    _depositAll(4);
    _depositAll(5);

    vm.warp(start + 6 * D + 1);

    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    circles.withdraw(id);
    assertEq(token.balanceOf(alice) - aliceBefore, POT, 'alice still whole');

    // Only bob's collateral is reduced, by exactly the one missed deposit.
    assertEq(circles.collateralOf(id, bob), COLLATERAL - M, 'bob slashed 1 deposit');
    assertEq(circles.collateralOf(id, alice), COLLATERAL, 'alice untouched');
    assertEq(circles.collateralOf(id, carol), COLLATERAL, 'carol untouched');
  }

  // --------------------------------------------------------------------------
  // Abort: an incomplete collateral cycle unwinds safely, refunding everyone.
  // --------------------------------------------------------------------------

  function test_Abort_RefundsEveryoneWhenCollateralCycleIncomplete() public {
    _createAndStart();

    // alice and bob complete collateral; carol skips round 2.
    _depositAll(0);
    _depositAll(1);
    _enterRound(2);
    vm.prank(alice);
    circles.deposit(id, M);
    vm.prank(bob);
    circles.deposit(id, M);
    // carol does not deposit round 2

    // Enter the payout cycle window: circle is under-collateralized.
    _enterRound(3);
    assertFalse(circles.isFullyCollateralized(id));

    // Payout-cycle deposits are blocked while under-collateralized.
    vm.prank(alice);
    vm.expectRevert(ICollateralSavingCircles.NotFullyCollateralized.selector);
    circles.deposit(id, M);

    // Anyone can abort; everyone is refunded exactly what they put in.
    vm.prank(stranger);
    circles.abort(id);

    assertEq(token.balanceOf(alice), 100e18, 'alice refunded');
    assertEq(token.balanceOf(bob), 100e18, 'bob refunded');
    assertEq(token.balanceOf(carol), 100e18, 'carol refunded');
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
    assertTrue(circles.circleState(id) == ICollateralSavingCircles.CircleState.Aborted);
  }

  function test_CannotAbortWhenFullyCollateralized() public {
    _createAndStart();
    _depositAll(0);
    _depositAll(1);
    _depositAll(2);
    _enterRound(3);

    vm.prank(stranger);
    vm.expectRevert(ICollateralSavingCircles.NotAbortable.selector);
    circles.abort(id);
  }

  // --------------------------------------------------------------------------
  // Permissionless membership & basic guards
  // --------------------------------------------------------------------------

  function test_Permissionless_AnyoneCreatesJoinsStarts() public {
    _createAndStart();
    address[] memory ms = circles.getMembers(id);
    assertEq(ms.length, N);
    assertEq(ms[0], alice);
    assertEq(ms[2], carol);
    assertTrue(circles.circleState(id) == ICollateralSavingCircles.CircleState.CollateralCycle);
  }

  function test_CannotJoinTwice() public {
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, D, N);
    vm.prank(alice);
    circles.join(id);
    vm.prank(alice);
    vm.expectRevert(ICollateralSavingCircles.AlreadyMember.selector);
    circles.join(id);
  }

  function test_CannotStartUntilFull() public {
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, D, N);
    vm.prank(alice);
    circles.join(id);
    vm.prank(stranger);
    vm.expectRevert(ICollateralSavingCircles.CircleNotFull.selector);
    circles.start(id);
  }

  function test_RejectsDisallowedToken() public {
    MockERC20 other = new MockERC20('Other', 'OTH');
    vm.prank(stranger);
    vm.expectRevert(ICollateralSavingCircles.TokenNotAllowed.selector);
    circles.createCircle(address(other), M, D, N);
  }

  function test_RejectsBadParameters() public {
    vm.startPrank(stranger);
    vm.expectRevert(ICollateralSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), 0, D, N);
    vm.expectRevert(ICollateralSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), M, 0, N);
    vm.expectRevert(ICollateralSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), M, D, 1); // below MINIMUM_SLOTS
    vm.stopPrank();
  }
}
