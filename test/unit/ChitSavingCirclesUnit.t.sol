// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

import {ChitSavingCircles} from 'src/contracts/ChitSavingCircles.sol';
import {IChitSavingCircles} from 'src/interfaces/IChitSavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

/**
 * @notice Unit tests for {ChitSavingCircles} (Variant D — the foremanless chit).
 * @dev Scenario constants: n = 3 slots, m = 1e18 per round, round = 1 day, reveal = last 6h.
 *      Slots: alice = 0, bob = 1, carol = 2 (dave is a spare for substitution).
 *      Each round: deposit + commit in the first 18h, reveal in the last 6h, then {award}
 *      after the round closes. Rounds settle strictly in order.
 */
contract ChitSavingCirclesUnit is Test {
  ChitSavingCircles public circles;
  MockERC20 public token;

  address public owner = makeAddr('owner');
  address public stranger = makeAddr('stranger');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public dave = makeAddr('dave');
  address public eve = makeAddr('eve');

  uint256 public constant M = 1e18; // per-round deposit
  uint256 public constant N = 3; // slots
  uint256 public constant RD = 1 days; // round duration
  uint256 public constant REVEAL = 6 hours; // reveal phase length
  uint256 public constant POT = N * M; // 3e18
  uint256 public constant START_BAL = 100e18;

  bytes32 public constant SALT = keccak256('salt');

  uint256 public id;
  uint256 public start;

  function setUp() public {
    vm.startPrank(owner);
    circles = ChitSavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new ChitSavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(ChitSavingCircles.initialize.selector, owner)
        )
      )
    );
    token = new MockERC20('Test', 'TST');
    circles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    address[5] memory ms = [alice, bob, carol, dave, eve];
    for (uint256 i = 0; i < ms.length; i++) {
      token.mint(ms[i], START_BAL);
      vm.prank(ms[i]);
      token.approve(address(circles), type(uint256).max);
    }
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// @dev A stranger creates the circle, alice/bob/carol join and it is started.
  function _createAndStart() internal {
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, N, RD, REVEAL);

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

  function _commitPhase(uint256 r) internal {
    vm.warp(start + r * RD + 1);
  }

  function _revealPhase(uint256 r) internal {
    vm.warp(start + r * RD + (RD - REVEAL) + 1);
  }

  function _close(uint256 r) internal {
    vm.warp(start + (r + 1) * RD + 1);
  }

  function _deposit(address who) internal {
    vm.prank(who);
    circles.deposit(id, M);
  }

  function _commit(address who, uint256 r, uint256 d) internal {
    bytes32 h = keccak256(abi.encode(d, SALT, who, id, r));
    vm.prank(who);
    circles.commitBid(id, h);
  }

  function _reveal(address who, uint256 d) internal {
    vm.prank(who);
    circles.revealBid(id, d, SALT);
  }

  /// @dev Sum of everything the contract still owes members; must equal its token balance.
  function _heldFor(address who) internal view returns (uint256) {
    return circles.claimableOf(id, who) + circles.collateralOf(id, who) + circles.withheldOf(id, who)
      + circles.bondOf(id, who);
  }

  function _assertConserved() internal view {
    uint256 held = _heldFor(alice) + _heldFor(bob) + _heldFor(carol) + _heldFor(dave);
    // Plus any deposits sitting in a not-yet-awarded round pot are already inside the contract;
    // this coarse check asserts the contract never holds less than it owes as security/claims.
    assertGe(token.balanceOf(address(circles)), held, 'contract cannot back its obligations');
  }

  // ==========================================================================
  // Happy path — pure rotation (no bids), everyone ends net-zero
  // ==========================================================================

  function test_HappyPath_RotationNoBids_NetZeroForAll() public {
    _createAndStart();

    for (uint256 r = 0; r < N; r++) {
      _commitPhase(r);
      _deposit(alice);
      _deposit(bob);
      _deposit(carol);
      _close(r);
      circles.award(id); // no bids → rotation: slot r wins round r

      // The round-r winner is the slot-r member; its exact residual is locked as coll.
      address winner = circles.getMembers(id)[r];
      assertTrue(circles.isPrized(id, winner), 'winner prized');
      assertEq(
        circles.collateralOf(id, winner) + circles.withheldOf(id, winner), (N - 1 - r) * M, 'two-tier == residual'
      );
      _assertConserved();
    }

    assertTrue(circles.circleState(id) == IChitSavingCircles.CircleState.Ended);

    // Everyone claims prize + released collateral and reclaims their bond → back to start.
    address[3] memory ms = [alice, bob, carol];
    for (uint256 i = 0; i < ms.length; i++) {
      assertEq(circles.claimableOf(id, ms[i]), POT, 'each got a whole pot back over the cycle');
      vm.startPrank(ms[i]);
      circles.claim(id);
      circles.reclaimBond(id);
      vm.stopPrank();
      assertEq(token.balanceOf(ms[i]), START_BAL, 'net zero');
    }
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
  }

  function test_MinimalCircle_TwoMembers_FullLifecycleDrains() public {
    // n == MINIMUM_SLOTS exercises the division edges (dividend split by n-1 == 1, last-round
    // residual == 0).
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, 2, RD, REVEAL);
    vm.prank(alice);
    circles.join(id);
    vm.prank(bob);
    circles.join(id);
    vm.prank(stranger);
    circles.start(id);
    start = circles.getCircle(id).startTime;

    for (uint256 r = 0; r < 2; r++) {
      _commitPhase(r);
      _deposit(alice);
      _deposit(bob);
      _close(r);
      circles.award(id);
    }

    assertTrue(circles.circleState(id) == IChitSavingCircles.CircleState.Ended);
    address[2] memory ms = [alice, bob];
    for (uint256 i = 0; i < ms.length; i++) {
      vm.startPrank(ms[i]);
      circles.claim(id);
      circles.reclaimBond(id);
      vm.stopPrank();
      assertEq(token.balanceOf(ms[i]), START_BAL, 'net zero');
    }
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
  }

  // ==========================================================================
  // Auction + dividends — the winning bid is paid out as interest to the rest
  // ==========================================================================

  function test_Auction_BidBecomesDividendInterest() public {
    _createAndStart();

    // Round 0: alice bids the whole residual (2m); bob/carol do not bid. alice wins.
    _commitPhase(0);
    _deposit(alice);
    _deposit(bob);
    _deposit(carol);
    _commit(alice, 0, 2 * M);
    _revealPhase(0);
    _reveal(alice, 2 * M);
    _close(0);
    circles.award(id);

    assertTrue(circles.isPrized(id, alice), 'alice won');
    assertEq(circles.withheldOf(id, alice), 2 * M, 'entire bid withheld as first-loss');
    assertEq(circles.collateralOf(id, alice), 0, 'a max bid needs zero cash lock');
    assertEq(circles.residualOf(id, alice), 2 * M, 'residual == withheld + coll');

    // Rounds 1 & 2: rotation (bob then carol). alice keeps depositing, paying out her bid as
    // dividends. bob/carol split alice's 2m bid equally over the two releases → 1m each.
    for (uint256 r = 1; r < N; r++) {
      _commitPhase(r);
      _deposit(alice);
      _deposit(bob);
      _deposit(carol);
      _close(r);
      circles.award(id);
      _assertConserved();
    }

    // Settle everyone.
    address[3] memory ms = [alice, bob, carol];
    for (uint256 i = 0; i < ms.length; i++) {
      vm.startPrank(ms[i]);
      circles.claim(id);
      circles.reclaimBond(id);
      vm.stopPrank();
    }

    // alice paid 2m of interest; bob and carol earned 1m each. Interest is zero-sum.
    assertEq(token.balanceOf(alice), START_BAL - 2 * M, 'impatient bidder pays interest');
    assertEq(token.balanceOf(bob), START_BAL + M, 'patient member earns interest');
    assertEq(token.balanceOf(carol), START_BAL + M, 'patient member earns interest');
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
  }

  // ==========================================================================
  // D3 — a prized member who bids high and then defaults steals nothing
  // ==========================================================================

  function test_PrizedDefault_TheftIsZero_HonestMembersWhole() public {
    _createAndStart();

    // Round 0: alice bids the max (2m) and wins, then never deposits again.
    _commitPhase(0);
    _deposit(alice);
    _deposit(bob);
    _deposit(carol);
    _commit(alice, 0, 2 * M);
    _revealPhase(0);
    _reveal(alice, 2 * M);
    _close(0);
    circles.award(id);
    assertEq(circles.withheldOf(id, alice), 2 * M);

    // Rounds 1 & 2: alice defaults on every deposit; bob and carol pay honestly.
    for (uint256 r = 1; r < N; r++) {
      _commitPhase(r);
      _deposit(bob);
      _deposit(carol);
      // alice deposits nothing
      _close(r);
      circles.award(id); // alice's miss is covered from her own withheld first-loss
      _assertConserved();
    }

    // alice's security was entirely consumed covering her own defaults.
    assertEq(circles.withheldOf(id, alice), 0, 'withheld drained by self-cover');
    assertEq(circles.collateralOf(id, alice), 0, 'no cash lock left');

    // Every winner still received a full pot; honest members lose nothing.
    address[3] memory ms = [alice, bob, carol];
    for (uint256 i = 0; i < ms.length; i++) {
      if (circles.claimableOf(id, ms[i]) > 0) {
        vm.prank(ms[i]);
        circles.claim(id);
      }
      vm.prank(ms[i]);
      circles.reclaimBond(id);
    }

    // alice took her 1m prize (== her single deposit) and forfeited nothing extra → net zero.
    assertEq(token.balanceOf(alice), START_BAL, 'defaulter net zero: theft is zero');
    // bob and carol received full pots and are whole (no bids placed by them → no interest here).
    assertEq(token.balanceOf(bob), START_BAL, 'honest member whole');
    assertEq(token.balanceOf(carol), START_BAL, 'honest member whole');
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
  }

  // ==========================================================================
  // Substitution — a defaulted non-prized slot is taken over, circle completes
  // ==========================================================================

  function test_Substitution_DefaultedSlotTakenOver_CircleCompletes() public {
    _createAndStart();

    // Round 0: carol (slot 2) never deposits → covered from her bond, flagged defaulted.
    _commitPhase(0);
    _deposit(alice);
    _deposit(bob);
    _close(0);
    circles.award(id); // rotation → alice (slot 0) wins; carol defaulted
    assertTrue(circles.isDefaulted(id, carol), 'carol defaulted');

    // dave permissionlessly substitutes into carol's slot, posting a fresh bond.
    vm.prank(dave);
    circles.substitute(id, carol);
    assertEq(circles.getMembers(id)[2], dave, 'dave took slot 2');
    assertFalse(circles.isDefaulted(id, dave));

    // Rounds 1 & 2 proceed with dave in the cohort; bob then dave win.
    for (uint256 r = 1; r < N; r++) {
      _commitPhase(r);
      _deposit(alice);
      _deposit(bob);
      _deposit(dave);
      _close(r);
      circles.award(id);
    }

    assertTrue(circles.circleState(id) == IChitSavingCircles.CircleState.Ended, 'circle completed');

    // Honest alice and bob are made whole; the defaulter carol forfeited only her own bond.
    address[3] memory finishers = [alice, bob, dave];
    for (uint256 i = 0; i < finishers.length; i++) {
      vm.startPrank(finishers[i]);
      circles.claim(id);
      circles.reclaimBond(id);
      vm.stopPrank();
    }
    assertEq(token.balanceOf(alice), START_BAL, 'alice whole');
    assertEq(token.balanceOf(bob), START_BAL, 'bob whole');
    assertEq(token.balanceOf(carol), START_BAL - M, 'defaulter forfeits exactly her bond');
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
  }

  // ==========================================================================
  // Abort — an un-substituted default stalls the circle; everyone unwinds net-zero
  // ==========================================================================

  function test_Abort_StalledCircle_UnwindsEveryoneToNetZero() public {
    _createAndStart();

    // Round 0: carol defaults (covered from bond), alice wins.
    _commitPhase(0);
    _deposit(alice);
    _deposit(bob);
    _close(0);
    circles.award(id);
    assertTrue(circles.isDefaulted(id, carol));

    // Round 1: nobody substitutes carol; alice and bob deposit, carol cannot be covered again.
    _commitPhase(1);
    _deposit(alice);
    _deposit(bob);
    _close(1);
    assertFalse(circles.isAwardable(id), 'round 1 cannot be made whole');
    vm.expectRevert(IChitSavingCircles.NotAwardable.selector);
    circles.award(id);

    // Anyone aborts; the net-zero unwind returns every member to their starting balance.
    vm.prank(stranger);
    circles.abort(id);

    assertTrue(circles.circleState(id) == IChitSavingCircles.CircleState.Aborted);
    assertEq(token.balanceOf(alice), START_BAL, 'alice net zero');
    assertEq(token.balanceOf(bob), START_BAL, 'bob net zero');
    assertEq(token.balanceOf(carol), START_BAL, 'carol net zero');
    assertEq(token.balanceOf(address(circles)), 0, 'contract drained');
  }

  function test_CannotAbortAHealthyCircle() public {
    _createAndStart();
    _commitPhase(0);
    _deposit(alice);
    _deposit(bob);
    _deposit(carol);
    _close(0);
    vm.prank(stranger);
    vm.expectRevert(IChitSavingCircles.NotStuck.selector);
    circles.abort(id);
  }

  /// @dev Regression: a member substituted out before the circle stalls must still be refunded on
  ///      abort, or their forfeited bond is stranded and the contract cannot fully drain.
  function test_Abort_AfterSubstitution_DrainsToZero() public {
    // 4-member circle: dave defaults and is substituted by eve, who then also defaults with no
    // successor, stalling the circle.
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, 4, RD, REVEAL);
    address[4] memory core = [alice, bob, carol, dave];
    for (uint256 i = 0; i < core.length; i++) {
      vm.prank(core[i]);
      circles.join(id);
    }
    vm.prank(stranger);
    circles.start(id);
    start = circles.getCircle(id).startTime;

    // Round 0: dave (slot 3) defaults → covered from his bond, flagged defaulted; alice wins.
    _commitPhase(0);
    _deposit(alice);
    _deposit(bob);
    _deposit(carol);
    _close(0);
    circles.award(id);
    assertTrue(circles.isDefaulted(id, dave), 'dave defaulted');

    // eve substitutes dave, then herself defaults in round 1.
    vm.prank(eve);
    circles.substitute(id, dave);

    _commitPhase(1);
    _deposit(alice);
    _deposit(bob);
    _deposit(carol);
    _close(1);
    circles.award(id); // bob wins; eve covered from her bond, defaulted
    assertTrue(circles.isDefaulted(id, eve), 'eve defaulted');

    // Round 2 cannot be completed (eve un-substituted) → stall → abort.
    _commitPhase(2);
    _deposit(alice);
    _deposit(bob);
    _deposit(carol);
    _close(2);
    vm.expectRevert(IChitSavingCircles.NotAwardable.selector);
    circles.award(id);

    vm.prank(stranger);
    circles.abort(id);

    // Everyone — including the substituted-out defaulter dave — unwinds to net-zero, and no bond
    // is stranded: the contract drains completely.
    assertEq(token.balanceOf(alice), START_BAL, 'alice net zero');
    assertEq(token.balanceOf(bob), START_BAL, 'bob net zero');
    assertEq(token.balanceOf(carol), START_BAL, 'carol net zero');
    assertEq(token.balanceOf(dave), START_BAL, 'substituted-out defaulter refunded');
    assertEq(token.balanceOf(eve), START_BAL, 'substitute defaulter refunded');
    assertEq(token.balanceOf(address(circles)), 0, 'contract fully drained');
  }

  // ==========================================================================
  // Sealed-bid mechanics & guards
  // ==========================================================================

  function test_Reveal_MustMatchCommitment() public {
    _createAndStart();
    _commitPhase(0);
    _deposit(alice);
    _commit(alice, 0, M); // committed to discount = m
    _revealPhase(0);
    vm.prank(alice);
    vm.expectRevert(IChitSavingCircles.InvalidReveal.selector);
    circles.revealBid(id, 2 * M, SALT); // reveals a different discount
  }

  function test_Commit_WrongPhaseReverts() public {
    _createAndStart();
    _commitPhase(0);
    _deposit(alice);
    _revealPhase(0); // now in reveal phase
    vm.prank(alice);
    vm.expectRevert(IChitSavingCircles.WrongPhase.selector);
    circles.commitBid(id, keccak256('x'));
  }

  function test_Reveal_BidAboveResidualCapReverts() public {
    _createAndStart();
    _commitPhase(0);
    _deposit(alice);
    _commit(alice, 0, 3 * M); // cap for round 0 is (n-1)*m = 2m
    _revealPhase(0);
    vm.prank(alice);
    vm.expectRevert(IChitSavingCircles.BidTooHigh.selector);
    circles.revealBid(id, 3 * M, SALT);
  }

  function test_Reveal_RequiresCurrentDeposit() public {
    _createAndStart();
    _commitPhase(0);
    _commit(alice, 0, M); // committed without depositing
    _revealPhase(0);
    vm.prank(alice);
    vm.expectRevert(IChitSavingCircles.NotCurrent.selector);
    circles.revealBid(id, M, SALT);
  }

  function test_Award_RevertsBeforeRoundCloses() public {
    _createAndStart();
    _commitPhase(0);
    _deposit(alice);
    _deposit(bob);
    _deposit(carol);
    // still inside round 0
    vm.expectRevert(IChitSavingCircles.RoundNotClosed.selector);
    circles.award(id);
  }

  // ==========================================================================
  // Permissionless membership & parameter guards
  // ==========================================================================

  function test_Permissionless_AnyoneCreatesJoinsStarts() public {
    _createAndStart();
    address[] memory ms = circles.getMembers(id);
    assertEq(ms.length, N);
    assertEq(ms[0], alice);
    assertEq(ms[2], carol);
    assertTrue(circles.circleState(id) == IChitSavingCircles.CircleState.Active);
    // Each member's bond is posted at join.
    assertEq(circles.bondOf(id, alice), M);
  }

  function test_CannotJoinTwice() public {
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, N, RD, REVEAL);
    vm.prank(alice);
    circles.join(id);
    vm.prank(alice);
    vm.expectRevert(IChitSavingCircles.AlreadyMember.selector);
    circles.join(id);
  }

  function test_CannotStartUntilFull() public {
    vm.prank(stranger);
    id = circles.createCircle(address(token), M, N, RD, REVEAL);
    vm.prank(alice);
    circles.join(id);
    vm.prank(stranger);
    vm.expectRevert(IChitSavingCircles.CircleNotFull.selector);
    circles.start(id);
  }

  function test_RejectsDisallowedToken() public {
    MockERC20 other = new MockERC20('Other', 'OTH');
    vm.prank(stranger);
    vm.expectRevert(IChitSavingCircles.TokenNotAllowed.selector);
    circles.createCircle(address(other), M, N, RD, REVEAL);
  }

  function test_RejectsBadParameters() public {
    vm.startPrank(stranger);
    vm.expectRevert(IChitSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), 0, N, RD, REVEAL); // zero deposit
    vm.expectRevert(IChitSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), M, 1, RD, REVEAL); // below MINIMUM_SLOTS
    vm.expectRevert(IChitSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), M, N, 0, REVEAL); // zero round
    vm.expectRevert(IChitSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), M, N, RD, 0); // zero reveal window
    vm.expectRevert(IChitSavingCircles.InvalidParameters.selector);
    circles.createCircle(address(token), M, N, RD, RD); // reveal >= round
    vm.stopPrank();
  }
}
