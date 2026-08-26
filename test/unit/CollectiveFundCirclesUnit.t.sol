// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

import {CollectiveFundCircles} from 'src/contracts/CollectiveFundCircles.sol';
import {ICollectiveFundCircles} from 'src/interfaces/ICollectiveFundCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

/**
 * @notice Unit tests for {CollectiveFundCircles} — the Logos white-label communal fund.
 * @dev Self-contained: deploys its own TransparentUpgradeableProxy in setUp. Fixture
 *      `baseFundId` = fund(token, orga, 'Logos Quito', 7 days, 6_000 bps) with alice + bob
 *      joined via EIP-712 invites, so electorate = 3 and requiredYes = ceil(1.8) = 2.
 */
contract CollectiveFundCirclesUnit is Test {
  CollectiveFundCircles public collective;
  MockERC20 public token;

  address public owner; // contract admin (token allowlist)
  address public orga; // fund organizer
  address public alice;
  address public bob;
  address public carol;
  address public dave; // never a baseFund member
  address public recipient;

  uint256 internal _orgaKey;
  uint256 internal _aliceKey;

  uint256 public constant VOTING_PERIOD = 7 days;
  uint256 public constant THRESHOLD_BPS = 6000;
  uint256 public constant START_BAL = 1000 ether;
  uint256 public constant DEPOSIT = 100 ether;
  string public constant FUND_NAME = 'Logos Quito';
  string public constant DESCRIPTION = 'venue deposit';

  uint256 public baseFundId;
  uint256 internal _nextNonce;

  function setUp() public {
    (owner,) = makeAddrAndKey('owner');
    (orga, _orgaKey) = makeAddrAndKey('orga');
    (alice, _aliceKey) = makeAddrAndKey('alice');
    (bob,) = makeAddrAndKey('bob');
    (carol,) = makeAddrAndKey('carol');
    (dave,) = makeAddrAndKey('dave');
    (recipient,) = makeAddrAndKey('recipient');

    vm.startPrank(owner);
    collective = CollectiveFundCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new CollectiveFundCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(CollectiveFundCircles.initialize.selector, owner)
        )
      )
    );
    token = new MockERC20('Test', 'TST');
    collective.setTokenAllowed(address(token), true);
    vm.stopPrank();

    address[5] memory actors = [orga, alice, bob, carol, dave];
    for (uint256 i = 0; i < actors.length; i++) {
      token.mint(actors[i], START_BAL);
      vm.prank(actors[i]);
      token.approve(address(collective), type(uint256).max);
    }

    baseFundId = collective.create(address(token), orga, FUND_NAME, VOTING_PERIOD, THRESHOLD_BPS);
    _join(baseFundId, alice);
    _join(baseFundId, bob);
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// @dev EIP-712 invite signature (domain 'StacksInvite' v1) with this contract as verifyingContract.
  function _signInvite(
    address _verifyingContract,
    uint256 _fundId,
    uint256 _nonce,
    uint256 _signerKey
  ) internal view returns (bytes memory) {
    bytes32 inviteTypehash = keccak256('Invite(uint256 id,uint256 nonce)');
    bytes32 structHash = keccak256(abi.encode(inviteTypehash, _fundId, _nonce));
    bytes32 eip712DomainTypehash =
      keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
    bytes32 domainSeparator = keccak256(
      abi.encode(eip712DomainTypehash, keccak256('StacksInvite'), keccak256('1'), block.chainid, _verifyingContract)
    );
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @dev Join `_member` to fund `_id` with an orga-signed invite and a fresh nonce.
  function _join(uint256 _id, address _member) internal {
    uint256 nonce = _nextNonce++;
    bytes memory signature = _signInvite(address(collective), _id, nonce, _orgaKey);
    vm.prank(_member);
    collective.redeemInvite(_id, nonce, signature);
  }

  function _deposit(uint256 _id, address _member, uint256 _amount) internal {
    vm.prank(_member);
    collective.deposit(_id, _amount);
  }

  /// @dev Propose in baseFund as orga (auto-yes) and vote yes as alice -> requiredYes 2 reached.
  function _passProposal(uint256 _amount) internal returns (uint256 proposalId) {
    vm.prank(orga);
    proposalId = collective.propose(baseFundId, recipient, _amount, DESCRIPTION);
    vm.prank(alice);
    collective.vote(baseFundId, proposalId, true);
  }

  /// @dev Fund the base pool, pass a proposal for `_amount` and execute it.
  function _fundPassAndExecute(uint256 _depositAmount, uint256 _proposalAmount) internal returns (uint256 proposalId) {
    _deposit(baseFundId, alice, _depositAmount);
    proposalId = _passProposal(_proposalAmount);
    collective.execute(baseFundId, proposalId);
  }

  // ==========================================================================
  // initialize / admin
  // ==========================================================================

  function test_InitializeSetsOwner() public view {
    assertEq(collective.owner(), owner);
  }

  function test_InitializeRevertsWhenCalledTwice() public {
    vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
    collective.initialize(alice);
  }

  function test_InitializeFreshProxyAndImplementationLockdown() public {
    // A fresh proxy initializes normally.
    CollectiveFundCircles fresh = CollectiveFundCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new CollectiveFundCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(CollectiveFundCircles.initialize.selector, alice)
        )
      )
    );
    assertEq(fresh.owner(), alice);

    // The bare implementation has initializers disabled by its constructor.
    CollectiveFundCircles implementation = new CollectiveFundCircles();
    vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
    implementation.initialize(alice);
  }

  function test_SetTokenAllowedWhenCallerIsOwner() public {
    address newToken = makeAddr('newToken');
    vm.prank(owner);
    collective.setTokenAllowed(newToken, true);
    assertTrue(collective.isTokenAllowed(newToken));

    vm.prank(owner);
    collective.setTokenAllowed(newToken, false);
    assertFalse(collective.isTokenAllowed(newToken));
  }

  function test_SetTokenAllowedWhenCallerIsNotOwner() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    collective.setTokenAllowed(address(token), false);
  }

  function test_SetTokenAllowedEmitsEvent() public {
    address newToken = makeAddr('anotherToken');
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.TokenAllowed(newToken, true);
    collective.setTokenAllowed(newToken, true);
  }

  // ==========================================================================
  // create
  // ==========================================================================

  function test_CreateFundWithValidParameters() public {
    uint256 expectedId = collective.nextId();

    vm.prank(dave); // permissionless
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.FundCreated(expectedId, orga, address(token), 'Logos Cell', 3 days, 5000);
    uint256 id = collective.create(address(token), orga, 'Logos Cell', 3 days, 5000);

    assertEq(id, expectedId);

    ICollectiveFundCircles.Fund memory fund = collective.getFund(id);
    assertEq(fund.owner, orga);
    assertEq(fund.token, address(token));
    assertEq(fund.votingPeriod, 3 days);
    assertEq(fund.approvalThresholdBps, 5000);
    assertEq(fund.totalShares, 0);
    assertEq(fund.poolBalance, 0);
    assertEq(fund.proposalCount, 0);
    assertEq(fund.name, 'Logos Cell');

    // The fund owner auto-joins at index 0.
    assertTrue(collective.isMember(id, orga));
    assertEq(collective.memberIndex(id, orga), 0);
    address[] memory members = collective.getFundMembers(id);
    assertEq(members.length, 1);
    assertEq(members[0], orga);

    uint256[] memory orgaFunds = collective.getMemberFunds(orga);
    assertEq(orgaFunds[orgaFunds.length - 1], id);
  }

  function test_CreateFundIncrementsNextId() public {
    uint256 before = collective.nextId();
    uint256 id = collective.create(address(token), orga, FUND_NAME, VOTING_PERIOD, THRESHOLD_BPS);
    assertEq(id, before);
    assertEq(collective.nextId(), before + 1);
  }

  function test_CreateFundRevertsWhenTokenNotAllowed() public {
    MockERC20 other = new MockERC20('Other', 'OTH');
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.TokenNotAllowed.selector));
    collective.create(address(other), orga, FUND_NAME, VOTING_PERIOD, THRESHOLD_BPS);
  }

  function test_CreateFundRevertsWhenOwnerIsZero() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidFundOwner.selector));
    collective.create(address(token), address(0), FUND_NAME, VOTING_PERIOD, THRESHOLD_BPS);
  }

  function test_CreateFundRevertsWhenNameEmpty() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidName.selector));
    collective.create(address(token), orga, '', VOTING_PERIOD, THRESHOLD_BPS);
  }

  function test_CreateFundRevertsWhenVotingPeriodZero() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidVotingPeriod.selector));
    collective.create(address(token), orga, FUND_NAME, 0, THRESHOLD_BPS);
  }

  function test_CreateFundRevertsWhenVotingPeriodExceedsMax() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidVotingPeriod.selector));
    collective.create(address(token), orga, FUND_NAME, 365 days + 1, THRESHOLD_BPS);
  }

  function test_CreateFundRevertsWhenThresholdZero() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidThreshold.selector));
    collective.create(address(token), orga, FUND_NAME, VOTING_PERIOD, 0);
  }

  function test_CreateFundRevertsWhenThresholdAboveMaxBps() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidThreshold.selector));
    collective.create(address(token), orga, FUND_NAME, VOTING_PERIOD, 10_001);
  }

  // ==========================================================================
  // redeemInvite
  // ==========================================================================

  function test_RedeemInviteWithValidSignature() public {
    uint256 nonce = 777;
    bytes memory signature = _signInvite(address(collective), baseFundId, nonce, _orgaKey);

    vm.prank(carol);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.InviteRedeemed(baseFundId, carol);
    collective.redeemInvite(baseFundId, nonce, signature);

    assertTrue(collective.isMember(baseFundId, carol));
    assertEq(collective.memberIndex(baseFundId, carol), 3);
    assertTrue(collective.usedNonces(baseFundId, nonce));

    address[] memory members = collective.getFundMembers(baseFundId);
    assertEq(members.length, 4);
    assertEq(members[3], carol);

    uint256[] memory carolFunds = collective.getMemberFunds(carol);
    assertEq(carolFunds.length, 1);
    assertEq(carolFunds[0], baseFundId);
  }

  function test_RedeemInviteRevertsWhenFundNotFound() public {
    bytes memory signature = _signInvite(address(collective), 999, 0, _orgaKey);
    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.redeemInvite(999, 0, signature);
  }

  function test_RedeemInviteRevertsWhenNonceAlreadyUsed() public {
    uint256 nonce = 42_000;
    bytes memory signature = _signInvite(address(collective), baseFundId, nonce, _orgaKey);
    vm.prank(carol);
    collective.redeemInvite(baseFundId, nonce, signature);

    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InviteAlreadyUsed.selector));
    collective.redeemInvite(baseFundId, nonce, signature);
  }

  function test_RedeemInviteRevertsWhenAlreadyMember() public {
    uint256 nonce = 43_000;
    bytes memory signature = _signInvite(address(collective), baseFundId, nonce, _orgaKey);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.AlreadyMember.selector));
    collective.redeemInvite(baseFundId, nonce, signature);
  }

  function test_RedeemInviteRevertsWhenSignerIsNotFundOwner() public {
    uint256 nonce = 44_000;
    bytes memory signature = _signInvite(address(collective), baseFundId, nonce, _aliceKey);
    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidSigner.selector));
    collective.redeemInvite(baseFundId, nonce, signature);
  }

  function test_RedeemInviteSucceedsAfterProposalsExist() public {
    vm.prank(orga);
    collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    // Funds are perpetual: invites redeem at any time, even with proposals in flight.
    _join(baseFundId, carol);
    assertTrue(collective.isMember(baseFundId, carol));
  }

  // ==========================================================================
  // deposit
  // ==========================================================================

  function test_DepositMintsSharesOneToOne() public {
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.FundsDeposited(baseFundId, alice, DEPOSIT);
    collective.deposit(baseFundId, DEPOSIT);

    assertEq(collective.sharesOf(baseFundId, alice), DEPOSIT);
    ICollectiveFundCircles.Fund memory fund = collective.getFund(baseFundId);
    assertEq(fund.totalShares, DEPOSIT);
    assertEq(fund.poolBalance, DEPOSIT);
    assertEq(token.balanceOf(address(collective)), DEPOSIT);
    assertEq(token.balanceOf(alice), START_BAL - DEPOSIT);
  }

  function test_DepositRevertsWhenNotMember() public {
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.NotMember.selector));
    collective.deposit(baseFundId, DEPOSIT);
  }

  function test_DepositRevertsWhenZeroAmount() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidAmount.selector));
    collective.deposit(baseFundId, 0);
  }

  function test_DepositRevertsWhenFundNotFound() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.deposit(999, DEPOSIT);
  }

  function test_DepositAfterDisbursementStillMintsOneToOne() public {
    // alice deposits 100, community spends 50 -> pool 50, shares 100.
    _fundPassAndExecute(DEPOSIT, DEPOSIT / 2);

    // bob's late deposit still mints 1:1 ...
    _deposit(baseFundId, bob, DEPOSIT);
    assertEq(collective.sharesOf(baseFundId, bob), DEPOSIT);

    // ... so he immediately shares the past dilution equally per contributed token:
    // previewWithdraw = 100 * 150 / 200 = 75 < 100.
    assertEq(collective.previewWithdraw(baseFundId, bob), 75 ether);
    assertLt(collective.previewWithdraw(baseFundId, bob), DEPOSIT);
  }

  // ==========================================================================
  // donate
  // ==========================================================================

  function test_DonateIncreasesPoolWithoutMintingShares() public {
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.FundsDonated(baseFundId, alice, DEPOSIT);
    collective.donate(baseFundId, DEPOSIT);

    ICollectiveFundCircles.Fund memory fund = collective.getFund(baseFundId);
    assertEq(fund.poolBalance, DEPOSIT);
    assertEq(fund.totalShares, 0);
    assertEq(collective.sharesOf(baseFundId, alice), 0);
  }

  function test_DonateByNonMember() public {
    vm.prank(dave);
    collective.donate(baseFundId, DEPOSIT);
    assertEq(collective.getFund(baseFundId).poolBalance, DEPOSIT);
    assertEq(token.balanceOf(dave), START_BAL - DEPOSIT);
  }

  function test_DonateRevertsWhenZeroAmount() public {
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidAmount.selector));
    collective.donate(baseFundId, 0);
  }

  function test_DonateRevertsWhenFundNotFound() public {
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.donate(999, DEPOSIT);
  }

  function test_DonateWithZeroTotalSharesIsSpendableByProposal() public {
    // No shares exist, only a donation.
    vm.prank(dave);
    collective.donate(baseFundId, DEPOSIT);

    uint256 proposalId = _passProposal(60 ether);
    collective.execute(baseFundId, proposalId);

    assertEq(token.balanceOf(recipient), 60 ether);
    assertEq(collective.getFund(baseFundId).poolBalance, 40 ether);
  }

  // ==========================================================================
  // withdraw
  // ==========================================================================

  function test_WithdrawFullBalanceAtParityBeforeAnyDisbursement() public {
    _deposit(baseFundId, alice, DEPOSIT);

    vm.prank(alice);
    collective.withdraw(baseFundId, DEPOSIT);

    assertEq(token.balanceOf(alice), START_BAL);
    assertEq(collective.sharesOf(baseFundId, alice), 0);
    ICollectiveFundCircles.Fund memory fund = collective.getFund(baseFundId);
    assertEq(fund.totalShares, 0);
    assertEq(fund.poolBalance, 0);
  }

  function test_WithdrawPartialShares() public {
    _deposit(baseFundId, alice, DEPOSIT);

    vm.prank(alice);
    collective.withdraw(baseFundId, 40 ether);

    assertEq(token.balanceOf(alice), START_BAL - 60 ether);
    assertEq(collective.sharesOf(baseFundId, alice), 60 ether);
    assertEq(collective.getFund(baseFundId).poolBalance, 60 ether);
    assertEq(collective.getFund(baseFundId).totalShares, 60 ether);
  }

  function test_WithdrawProRataAfterDisbursement() public {
    // alice 100 + bob 100 -> pool 200; disburse 50 -> pool 150, shares 200.
    _deposit(baseFundId, alice, DEPOSIT);
    _deposit(baseFundId, bob, DEPOSIT);
    uint256 proposalId = _passProposal(50 ether);
    collective.execute(baseFundId, proposalId);

    // alice burns all 100 shares: floor(100 * 150 / 200) = 75.
    vm.prank(alice);
    collective.withdraw(baseFundId, DEPOSIT);

    assertEq(token.balanceOf(alice), START_BAL - DEPOSIT + 75 ether);
    ICollectiveFundCircles.Fund memory fund = collective.getFund(baseFundId);
    assertEq(fund.poolBalance, 75 ether);
    assertEq(fund.totalShares, DEPOSIT);
  }

  function test_WithdrawRoundsDownAndLeavesDustInPool() public {
    // Wei-level amounts: pool 199, shares 200; 3 shares -> floor(3 * 199 / 200) = 2 (not 2.985).
    _deposit(baseFundId, alice, 100);
    _deposit(baseFundId, bob, 100);
    uint256 proposalId = _passProposal(1);
    collective.execute(baseFundId, proposalId);

    uint256 balanceBefore = token.balanceOf(alice);
    vm.prank(alice);
    collective.withdraw(baseFundId, 3);

    assertEq(token.balanceOf(alice) - balanceBefore, 2);
    // The 0.985 wei of dust stays in the pool for remaining shareholders.
    assertEq(collective.getFund(baseFundId).poolBalance, 197);
    assertEq(collective.getFund(baseFundId).totalShares, 197);
  }

  function test_WithdrawLastMemberSweepsExactPoolBalance() public {
    // pool 167, shares 200 after a 33-wei disbursement.
    _deposit(baseFundId, alice, 100);
    _deposit(baseFundId, bob, 100);
    uint256 proposalId = _passProposal(33);
    collective.execute(baseFundId, proposalId);

    vm.prank(alice);
    collective.withdraw(baseFundId, 100); // floor(100 * 167 / 200) = 83 -> pool 84, shares 100

    vm.prank(bob);
    collective.withdraw(baseFundId, 100); // last out: 100 * 84 / 100 = 84 exactly

    ICollectiveFundCircles.Fund memory fund = collective.getFund(baseFundId);
    assertEq(fund.poolBalance, 0);
    assertEq(fund.totalShares, 0);
    assertEq(token.balanceOf(address(collective)), 0); // nothing stranded
  }

  function test_WithdrawZeroValueSharesWhenPoolEmpty() public {
    // Fully spent fund: pool 0, shares 100.
    _fundPassAndExecute(DEPOSIT, DEPOSIT);
    assertEq(collective.getFund(baseFundId).poolBalance, 0);

    // Share-base reset: burning worthless shares proceeds and pays 0.
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.FundsWithdrawn(baseFundId, alice, DEPOSIT, 0);
    collective.withdraw(baseFundId, DEPOSIT);

    assertEq(collective.sharesOf(baseFundId, alice), 0);
    assertEq(collective.getFund(baseFundId).totalShares, 0);
    assertEq(token.balanceOf(alice), START_BAL - DEPOSIT);
  }

  function test_WithdrawRevertsWhenZeroShares() public {
    _deposit(baseFundId, alice, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidAmount.selector));
    collective.withdraw(baseFundId, 0);
  }

  function test_WithdrawRevertsWhenInsufficientShares() public {
    _deposit(baseFundId, alice, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InsufficientShares.selector));
    collective.withdraw(baseFundId, DEPOSIT + 1);
  }

  function test_WithdrawRevertsWhenNotMember() public {
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.NotMember.selector));
    collective.withdraw(baseFundId, 1);
  }

  function test_WithdrawRevertsWhenFundNotFound() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.withdraw(999, 1);
  }

  function test_WithdrawEmitsEvent() public {
    _deposit(baseFundId, alice, DEPOSIT);
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.FundsWithdrawn(baseFundId, alice, 40 ether, 40 ether);
    collective.withdraw(baseFundId, 40 ether);
  }

  function test_WithdrawNotBlockedByPassedProposal() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);

    // Rage-quit is never blocked by a passed proposal.
    vm.prank(alice);
    collective.withdraw(baseFundId, DEPOSIT);
    assertEq(token.balanceOf(alice), START_BAL);

    // The proposal stays Passed but is no longer executable.
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);
    assertFalse(collective.isExecutable(baseFundId, proposalId));
  }

  // ==========================================================================
  // setFundName
  // ==========================================================================

  function test_SetFundNameByFundOwner() public {
    vm.prank(orga);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.FundNameUpdated(baseFundId, 'Logos Uio');
    collective.setFundName(baseFundId, 'Logos Uio');

    assertEq(collective.getFund(baseFundId).name, 'Logos Uio');
  }

  function test_SetFundNameRevertsWhenNotFundOwner() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.NotFundOwner.selector));
    collective.setFundName(baseFundId, 'Logos Uio');
  }

  function test_SetFundNameRevertsWhenEmpty() public {
    vm.prank(orga);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidName.selector));
    collective.setFundName(baseFundId, '');
  }

  function test_SetFundNameRevertsWhenFundNotFound() public {
    vm.prank(orga);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.setFundName(999, 'Logos Uio');
  }

  // ==========================================================================
  // propose
  // ==========================================================================

  function test_ProposeSnapshotsElectorateAndRequiredYes() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    ICollectiveFundCircles.Proposal memory proposal = collective.getProposal(baseFundId, proposalId);
    assertEq(proposal.proposer, orga);
    assertEq(proposal.recipient, recipient);
    assertEq(proposal.amount, DEPOSIT);
    assertEq(proposal.createdAt, block.timestamp);
    assertEq(proposal.electorate, 3);
    assertEq(proposal.requiredYes, 2); // ceil(3 * 6_000 / 10_000) = ceil(1.8) = 2
    assertEq(proposal.noVotes, 0);
    assertFalse(proposal.executed);
    assertEq(proposal.description, DESCRIPTION);
  }

  function test_ProposeRequiredYesRoundsUp() public {
    // 3 members @ 5_000 bps -> ceil(1.5) = 2 (true majority).
    uint256 fund3 = collective.create(address(token), orga, FUND_NAME, VOTING_PERIOD, 5000);
    _join(fund3, alice);
    _join(fund3, bob);
    vm.prank(orga);
    uint256 p3 = collective.propose(fund3, recipient, 1, DESCRIPTION);
    assertEq(collective.getProposal(fund3, p3).requiredYes, 2);

    // 5 members @ 5_000 bps -> ceil(2.5) = 3 (true majority).
    uint256 fund5 = collective.create(address(token), orga, FUND_NAME, VOTING_PERIOD, 5000);
    _join(fund5, alice);
    _join(fund5, bob);
    _join(fund5, carol);
    _join(fund5, dave);
    vm.prank(orga);
    uint256 p5 = collective.propose(fund5, recipient, 1, DESCRIPTION);
    assertEq(collective.getProposal(fund5, p5).requiredYes, 3);

    // 4 members @ 10_000 bps -> 4 (unanimity of the snapshot).
    uint256 fund4 = collective.create(address(token), orga, FUND_NAME, VOTING_PERIOD, 10_000);
    _join(fund4, alice);
    _join(fund4, bob);
    _join(fund4, carol);
    vm.prank(orga);
    uint256 p4 = collective.propose(fund4, recipient, 1, DESCRIPTION);
    assertEq(collective.getProposal(fund4, p4).requiredYes, 4);
  }

  function test_ProposeAutoVotesYesForProposer() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    assertEq(collective.getProposal(baseFundId, proposalId).yesVotes, 1);
    assertTrue(collective.hasVoted(baseFundId, proposalId, orga));
  }

  function test_ProposeSingleMemberFundPassesImmediately() public {
    uint256 soloFund = collective.create(address(token), orga, 'Solo', VOTING_PERIOD, THRESHOLD_BPS);

    vm.prank(orga);
    uint256 proposalId = collective.propose(soloFund, recipient, 1, DESCRIPTION);

    ICollectiveFundCircles.Proposal memory proposal = collective.getProposal(soloFund, proposalId);
    assertEq(proposal.requiredYes, 1);
    assertTrue(collective.proposalState(soloFund, proposalId) == ICollectiveFundCircles.ProposalState.Passed);
  }

  function test_ProposeDoesNotReserveOrCheckPoolBalance() public {
    // Pool is empty; a proposal for 1_000 ether is still accepted (checked at execute only).
    assertEq(collective.getFund(baseFundId).poolBalance, 0);
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, 1000 ether, DESCRIPTION);
    assertEq(collective.getProposal(baseFundId, proposalId).amount, 1000 ether);
  }

  function test_ProposeIncrementsProposalCount() public {
    assertEq(collective.getFund(baseFundId).proposalCount, 0);

    vm.prank(orga);
    uint256 first = collective.propose(baseFundId, recipient, 1, DESCRIPTION);
    vm.prank(alice);
    uint256 second = collective.propose(baseFundId, recipient, 2, DESCRIPTION);

    assertEq(first, 0);
    assertEq(second, 1);
    assertEq(collective.getFund(baseFundId).proposalCount, 2);
  }

  function test_ProposeRevertsWhenNotMember() public {
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.NotMember.selector));
    collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);
  }

  function test_ProposeRevertsWhenRecipientIsZero() public {
    vm.prank(orga);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidRecipient.selector));
    collective.propose(baseFundId, address(0), DEPOSIT, DESCRIPTION);
  }

  function test_ProposeRevertsWhenRecipientIsContract() public {
    vm.prank(orga);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidRecipient.selector));
    collective.propose(baseFundId, address(collective), DEPOSIT, DESCRIPTION);
  }

  function test_ProposeRevertsWhenAmountZero() public {
    vm.prank(orga);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InvalidAmount.selector));
    collective.propose(baseFundId, recipient, 0, DESCRIPTION);
  }

  function test_ProposeRevertsWhenFundNotFound() public {
    vm.prank(orga);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.propose(999, recipient, DEPOSIT, DESCRIPTION);
  }

  function test_ProposeEmitsEvent() public {
    vm.prank(orga);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.ProposalCreated(baseFundId, 0, orga, recipient, DEPOSIT, DESCRIPTION);
    collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);
  }

  // ==========================================================================
  // vote
  // ==========================================================================

  function test_VoteYesIncrementsYesVotes() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.VoteCast(baseFundId, proposalId, alice, true);
    collective.vote(baseFundId, proposalId, true);

    ICollectiveFundCircles.Proposal memory proposal = collective.getProposal(baseFundId, proposalId);
    assertEq(proposal.yesVotes, 2);
    assertEq(proposal.noVotes, 0);
    assertTrue(collective.hasVoted(baseFundId, proposalId, alice));
  }

  function test_VoteNoIncrementsNoVotes() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.VoteCast(baseFundId, proposalId, alice, false);
    collective.vote(baseFundId, proposalId, false);

    ICollectiveFundCircles.Proposal memory proposal = collective.getProposal(baseFundId, proposalId);
    assertEq(proposal.yesVotes, 1);
    assertEq(proposal.noVotes, 1);
  }

  function test_VoteReachingThresholdMakesProposalPassed() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Active);

    vm.prank(alice);
    collective.vote(baseFundId, proposalId, true); // yesVotes == requiredYes == 2

    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);
  }

  function test_VoteRevertsWhenAlreadyVoted() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    // The proposer's auto-yes counts as their ballot.
    vm.prank(orga);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.AlreadyVoted.selector));
    collective.vote(baseFundId, proposalId, true);

    vm.prank(alice);
    collective.vote(baseFundId, proposalId, false);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.AlreadyVoted.selector));
    collective.vote(baseFundId, proposalId, true);
  }

  function test_VoteRevertsWhenNotMember() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.NotMember.selector));
    collective.vote(baseFundId, proposalId, true);
  }

  function test_VoteRevertsWhenMemberJoinedAfterSnapshot() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    _join(baseFundId, carol); // memberIndex 3 >= electorate 3

    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.NotEligible.selector));
    collective.vote(baseFundId, proposalId, true);
  }

  function test_VoteAtVoteDeadlineBoundary() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;

    vm.warp(createdAt + VOTING_PERIOD); // inclusive boundary
    vm.prank(alice);
    collective.vote(baseFundId, proposalId, true);
    assertEq(collective.getProposal(baseFundId, proposalId).yesVotes, 2);
  }

  function test_VoteRevertsAfterVotingDeadline() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;

    vm.warp(createdAt + VOTING_PERIOD + 1);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.VotingClosed.selector));
    collective.vote(baseFundId, proposalId, true);
  }

  function test_VoteRevertsWhenProposalExecuted() public {
    uint256 proposalId = _fundPassAndExecute(DEPOSIT, DEPOSIT / 2);

    // Still inside the voting window, but the proposal has executed.
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.VotingClosed.selector));
    collective.vote(baseFundId, proposalId, false);
  }

  function test_VoteRevertsWhenProposalNotFound() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.ProposalNotFound.selector));
    collective.vote(baseFundId, 0, true);
  }

  function test_VoteRevertsWhenFundNotFound() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.vote(999, 0, true);
  }

  function test_VoteAllowedOnPassedProposalWithinWindow() public {
    uint256 proposalId = _passProposal(DEPOSIT);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);

    // Harmless signaling: bob may still vote no on a Passed proposal within the window.
    vm.prank(bob);
    collective.vote(baseFundId, proposalId, false);

    assertEq(collective.getProposal(baseFundId, proposalId).noVotes, 1);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);
  }

  // ==========================================================================
  // execute
  // ==========================================================================

  function test_ExecuteTransfersAmountAndMarksExecuted() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(60 ether);

    vm.expectEmit(true, true, true, true);
    emit ICollectiveFundCircles.ProposalExecuted(baseFundId, proposalId, recipient, 60 ether);
    collective.execute(baseFundId, proposalId);

    assertEq(token.balanceOf(recipient), 60 ether);
    assertEq(collective.getFund(baseFundId).poolBalance, 40 ether);
    assertTrue(collective.getProposal(baseFundId, proposalId).executed);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Executed);
  }

  function test_ExecuteEarlyOnceThresholdReachedBeforeVoteDeadline() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);

    // No warp: we are well before the vote deadline, yet the proposal already executes.
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;
    assertLt(block.timestamp, createdAt + VOTING_PERIOD);

    collective.execute(baseFundId, proposalId);
    assertTrue(collective.getProposal(baseFundId, proposalId).executed);
  }

  function test_ExecuteByNonMemberIsPermissionless() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);

    vm.prank(dave);
    collective.execute(baseFundId, proposalId);
    assertEq(token.balanceOf(recipient), DEPOSIT);
  }

  function test_ExecuteRevertsWhenThresholdNotReached() public {
    _deposit(baseFundId, alice, DEPOSIT);
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION); // 1 yes < 2

    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.ProposalNotPassed.selector));
    collective.execute(baseFundId, proposalId);
  }

  function test_ExecuteRevertsWhenAlreadyExecuted() public {
    uint256 proposalId = _fundPassAndExecute(DEPOSIT, DEPOSIT / 2);

    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.ProposalAlreadyExecuted.selector));
    collective.execute(baseFundId, proposalId);
  }

  function test_ExecuteRevertsAfterExecutionDeadline() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;

    vm.warp(createdAt + 2 * VOTING_PERIOD + 1);
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.ProposalExpired.selector));
    collective.execute(baseFundId, proposalId);
  }

  function test_ExecuteRevertsWhenPoolInsufficient() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);

    // alice rage-quits between pass and execute, draining the pool.
    vm.prank(alice);
    collective.withdraw(baseFundId, DEPOSIT);

    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.InsufficientPoolBalance.selector));
    collective.execute(baseFundId, proposalId);
  }

  function test_ExecuteSucceedsAfterPoolRefilledWithinWindow() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);
    vm.prank(alice);
    collective.withdraw(baseFundId, DEPOSIT);

    // Top-up re-enables the still-Passed proposal within its window.
    _deposit(baseFundId, bob, DEPOSIT);
    collective.execute(baseFundId, proposalId);

    assertEq(token.balanceOf(recipient), DEPOSIT);
    assertTrue(collective.getProposal(baseFundId, proposalId).executed);
  }

  function test_ExecuteRevertsWhenProposalNotFound() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.ProposalNotFound.selector));
    collective.execute(baseFundId, 0);
  }

  function test_ExecuteRevertsWhenFundNotFound() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.execute(999, 0);
  }

  function test_ExecuteAtExecutionDeadlineBoundary() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;

    vm.warp(createdAt + 2 * VOTING_PERIOD); // inclusive boundary
    collective.execute(baseFundId, proposalId);
    assertTrue(collective.getProposal(baseFundId, proposalId).executed);
  }

  // ==========================================================================
  // proposalState / isExecutable / views
  // ==========================================================================

  function test_ProposalStateActiveWhileVotingOpen() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Active);
  }

  function test_ProposalStatePassedWithinExecutionWindow() public {
    uint256 proposalId = _passProposal(DEPOSIT);
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;

    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);

    // Still Passed after the vote deadline, while inside the execution window.
    vm.warp(createdAt + VOTING_PERIOD + 1);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);
  }

  function test_ProposalStateExecuted() public {
    uint256 proposalId = _fundPassAndExecute(DEPOSIT, DEPOSIT);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Executed);
  }

  function test_ProposalStateDefeatedAfterDeadlineWithoutThreshold() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;

    vm.warp(createdAt + VOTING_PERIOD + 1);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Defeated);
  }

  function test_ProposalStateDefeatedEarlyWhenThresholdUnreachable() public {
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION);

    // electorate 3, requiredYes 2, yes 1. After two no-votes: 3 - 2 = 1 < 2 -> unreachable.
    vm.prank(alice);
    collective.vote(baseFundId, proposalId, false);
    vm.prank(bob);
    collective.vote(baseFundId, proposalId, false);

    // Defeated before the deadline.
    assertLt(block.timestamp, collective.getProposal(baseFundId, proposalId).createdAt + VOTING_PERIOD);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Defeated);
  }

  function test_ProposalStateExpiredWhenPassedButUnexecuted() public {
    uint256 proposalId = _passProposal(DEPOSIT);
    uint256 createdAt = collective.getProposal(baseFundId, proposalId).createdAt;

    vm.warp(createdAt + 2 * VOTING_PERIOD + 1);
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Expired);
  }

  function test_ProposalStateRevertsWhenProposalNotFound() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.ProposalNotFound.selector));
    collective.proposalState(baseFundId, 0);
  }

  function test_IsExecutableFalseWhenPoolInsufficient() public {
    uint256 proposalId = _passProposal(DEPOSIT); // pool is empty
    assertTrue(collective.proposalState(baseFundId, proposalId) == ICollectiveFundCircles.ProposalState.Passed);
    assertFalse(collective.isExecutable(baseFundId, proposalId));
  }

  function test_IsExecutableTrueWhenPassedAndFunded() public {
    _deposit(baseFundId, alice, DEPOSIT);
    uint256 proposalId = _passProposal(DEPOSIT);
    assertTrue(collective.isExecutable(baseFundId, proposalId));
  }

  function test_IsExecutableFalseWhenNotPassedOrMissing() public {
    _deposit(baseFundId, alice, DEPOSIT);
    vm.prank(orga);
    uint256 proposalId = collective.propose(baseFundId, recipient, DEPOSIT, DESCRIPTION); // Active

    assertFalse(collective.isExecutable(baseFundId, proposalId)); // funded but not Passed
    assertFalse(collective.isExecutable(baseFundId, 99)); // nonexistent proposal
    assertFalse(collective.isExecutable(999, 0)); // nonexistent fund
  }

  function test_PreviewWithdrawReturnsZeroWhenTotalSharesZero() public {
    assertEq(collective.previewWithdraw(baseFundId, alice), 0);

    // Even with a donated pool, no shares means nothing is redeemable.
    vm.prank(dave);
    collective.donate(baseFundId, DEPOSIT);
    assertEq(collective.previewWithdraw(baseFundId, alice), 0);
  }

  function test_PreviewWithdrawMatchesWithdrawPayout() public {
    _deposit(baseFundId, alice, 100);
    _deposit(baseFundId, bob, 100);
    uint256 proposalId = _passProposal(33);
    collective.execute(baseFundId, proposalId);

    uint256 preview = collective.previewWithdraw(baseFundId, alice);
    uint256 balanceBefore = token.balanceOf(alice);

    vm.prank(alice);
    collective.withdraw(baseFundId, 100);

    assertEq(token.balanceOf(alice) - balanceBefore, preview);
  }

  function test_GetFundReturnsStoredFund() public view {
    ICollectiveFundCircles.Fund memory fund = collective.getFund(baseFundId);
    assertEq(fund.owner, orga);
    assertEq(fund.token, address(token));
    assertEq(fund.votingPeriod, VOTING_PERIOD);
    assertEq(fund.approvalThresholdBps, THRESHOLD_BPS);
    assertEq(fund.name, FUND_NAME);
  }

  function test_GetFundRevertsWhenNotFound() public {
    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.FundNotFound.selector));
    collective.getFund(999);
  }

  function test_GetFundsReturnsMultiple() public {
    uint256 secondId = collective.create(address(token), orga, 'Second', 1 days, 1);

    uint256[] memory ids = new uint256[](3);
    ids[0] = baseFundId;
    ids[1] = secondId;
    ids[2] = 999; // nonexistent -> zeroed entry

    ICollectiveFundCircles.Fund[] memory funds = collective.getFunds(ids);
    assertEq(funds.length, 3);
    assertEq(funds[0].name, FUND_NAME);
    assertEq(funds[1].name, 'Second');
    assertEq(funds[2].owner, address(0));
  }

  function test_GetFundMembersReturnsJoinOrder() public {
    address[] memory members = collective.getFundMembers(baseFundId);
    assertEq(members.length, 3);
    assertEq(members[0], orga);
    assertEq(members[1], alice);
    assertEq(members[2], bob);

    _join(baseFundId, carol);
    members = collective.getFundMembers(baseFundId);
    assertEq(members.length, 4);
    assertEq(members[3], carol);
  }

  function test_GetMemberFundsAndCheckMemberships() public {
    uint256 secondId = collective.create(address(token), orga, 'Second', 1 days, 1);
    _join(secondId, alice);

    uint256[] memory aliceFunds = collective.getMemberFunds(alice);
    assertEq(aliceFunds.length, 2);
    assertEq(aliceFunds[0], baseFundId);
    assertEq(aliceFunds[1], secondId);

    uint256[] memory ids = new uint256[](3);
    ids[0] = baseFundId;
    ids[1] = secondId;
    ids[2] = 999;

    bool[] memory aliceMemberships = collective.checkMemberships(alice, ids);
    assertTrue(aliceMemberships[0]);
    assertTrue(aliceMemberships[1]);
    assertFalse(aliceMemberships[2]);

    bool[] memory bobMemberships = collective.checkMemberships(bob, ids);
    assertTrue(bobMemberships[0]);
    assertFalse(bobMemberships[1]);
  }

  function test_GetProposalAndGetProposals() public {
    vm.prank(orga);
    collective.propose(baseFundId, recipient, 1 ether, 'first');
    vm.prank(alice);
    collective.propose(baseFundId, recipient, 2 ether, 'second');

    ICollectiveFundCircles.Proposal[] memory proposals = collective.getProposals(baseFundId);
    assertEq(proposals.length, 2);
    assertEq(proposals[0].amount, 1 ether);
    assertEq(proposals[0].proposer, orga);
    assertEq(proposals[1].amount, 2 ether);
    assertEq(proposals[1].proposer, alice);
    assertEq(proposals[1].description, 'second');

    ICollectiveFundCircles.Proposal memory single = collective.getProposal(baseFundId, 1);
    assertEq(single.amount, proposals[1].amount);
    assertEq(single.proposer, proposals[1].proposer);

    vm.expectRevert(abi.encodeWithSelector(ICollectiveFundCircles.ProposalNotFound.selector));
    collective.getProposal(baseFundId, 2);
  }

  // ==========================================================================
  // cross-cutting conservation (I1 / I2 / I3)
  // ==========================================================================

  function test_ConservationAcrossDepositDonateWithdrawExecute() public {
    // Second fund sharing the same token; alice belongs to both.
    uint256 fundB = collective.create(address(token), orga, 'Fund B', 3 days, 5000);
    _join(fundB, alice);

    // Fund A activity: 100 + 50 deposits, 25 donation, disburse 60, alice burns 30 shares.
    _deposit(baseFundId, alice, 100);
    _deposit(baseFundId, bob, 50);
    vm.prank(dave);
    collective.donate(baseFundId, 25); // pool A = 175, shares A = 150

    uint256 proposalId = _passProposal(60);
    collective.execute(baseFundId, proposalId); // pool A = 115

    vm.prank(alice);
    collective.withdraw(baseFundId, 30); // floor(30 * 115 / 150) = 23 -> pool A = 92

    // Fund B activity: 80 + 20 deposits, alice burns 20 shares at parity.
    _deposit(fundB, orga, 80);
    _deposit(fundB, alice, 20); // pool B = 100, shares B = 100
    vm.prank(alice);
    collective.withdraw(fundB, 20); // 20 * 100 / 100 = 20 -> pool B = 80

    ICollectiveFundCircles.Fund memory fundA_ = collective.getFund(baseFundId);
    ICollectiveFundCircles.Fund memory fundB_ = collective.getFund(fundB);

    // I1 — share conservation per fund.
    uint256 sharesA = collective.sharesOf(baseFundId, orga) + collective.sharesOf(baseFundId, alice)
      + collective.sharesOf(baseFundId, bob);
    assertEq(sharesA, fundA_.totalShares);
    assertEq(fundA_.totalShares, 120); // alice 70 + bob 50

    uint256 sharesB = collective.sharesOf(fundB, orga) + collective.sharesOf(fundB, alice);
    assertEq(sharesB, fundB_.totalShares);
    assertEq(fundB_.totalShares, 80);

    // I2 — pool conservation: deposits + donations - withdrawals - executed amounts.
    assertEq(fundA_.poolBalance, 100 + 50 + 25 - 60 - 23);
    assertEq(fundB_.poolBalance, 80 + 20 - 20);

    // I3 — singleton solvency, and no cross-fund bleed: fund A's disbursement and rage-quits
    // never touched fund B's accounting.
    assertEq(token.balanceOf(address(collective)), fundA_.poolBalance + fundB_.poolBalance);
  }
}
