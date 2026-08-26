// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {StdStorage, Test, stdStorage} from 'forge-std/Test.sol';

import {AccumulatingSavingCircles} from 'src/contracts/AccumulatingSavingCircles.sol';
import {IAccumulatingSavingCircles} from 'src/interfaces/IAccumulatingSavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';

/**
 * @notice Unit tests for {AccumulatingSavingCircles}.
 * @dev Base fixture: alice organizes fund 0 (100% credit line, 5%/period simple interest, due
 *      after 4 periods of 1 week) and invites bob and carol. All actors hold START_BAL tokens and
 *      have approved the contract.
 *
 *      Reachability note: the internal ledger provably keeps `poolCash >= ` every member
 *      entitlement in all reachable states (spec invariants I2/I3), so the defensive
 *      InsufficientLiquidity guards cannot be triggered through the public API alone. Tests that
 *      exercise those branches lower `poolCash` directly via stdstore to simulate a hypothetical
 *      accounting shortfall.
 */
contract AccumulatingSavingCirclesUnit is Test {
  using stdStorage for StdStorage;

  AccumulatingSavingCircles public asca;
  MockERC20 public token;

  address public owner;
  address public alice;
  address public bob;
  address public carol;
  address public dave;
  address public stranger;

  uint256 internal _ownerKey;
  uint256 internal _aliceKey;
  uint256 internal _bobKey;
  uint256 internal _carolKey;

  uint256 public constant BORROW_LIMIT_BPS = 10_000;
  uint256 public constant INTEREST_RATE_BPS = 500;
  uint256 public constant REPAYMENT_PERIODS = 4;
  uint256 public constant PERIOD_LENGTH = 1 weeks;
  uint256 public constant DEPOSIT = 100 ether;
  uint256 public constant START_BAL = 1_000_000 ether;
  /// @dev All tests start (and all loans open) at this timestamp. Warps use absolute times
  ///      anchored here because via-ir CSE can cache `block.timestamp` reads within a test.
  uint256 public constant START_TIME = 365 days;

  uint256 public fundId;

  function setUp() public {
    (owner, _ownerKey) = makeAddrAndKey('owner');
    (alice, _aliceKey) = makeAddrAndKey('alice');
    (bob, _bobKey) = makeAddrAndKey('bob');
    (carol, _carolKey) = makeAddrAndKey('carol');
    dave = makeAddr('dave');
    stranger = makeAddr('stranger');

    vm.warp(START_TIME);

    vm.startPrank(owner);
    asca = AccumulatingSavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new AccumulatingSavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(AccumulatingSavingCircles.initialize.selector, owner)
        )
      )
    );
    token = new MockERC20('Test', 'TST');
    asca.setTokenAllowed(address(token), true);
    vm.stopPrank();

    address[4] memory _actors = [alice, bob, carol, dave];
    for (uint256 _i = 0; _i < _actors.length; _i++) {
      token.mint(_actors[_i], START_BAL);
      vm.prank(_actors[_i]);
      token.approve(address(asca), type(uint256).max);
    }

    vm.prank(alice);
    fundId = asca.create(address(token), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);
    _join(bob, 1);
    _join(carol, 2);
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// @dev Builds an EIP-712 StacksInvite signature for this contract as verifying contract.
  function _signInvite(uint256 _id, uint256 _nonce, uint256 _signerKey) internal view returns (bytes memory) {
    bytes32 _inviteTypehash = keccak256('Invite(uint256 id,uint256 nonce)');
    bytes32 _structHash = keccak256(abi.encode(_inviteTypehash, _id, _nonce));
    bytes32 _domainSeparator = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256(bytes('StacksInvite')),
        keccak256(bytes('1')),
        block.chainid,
        address(asca)
      )
    );
    bytes32 _digest = keccak256(abi.encodePacked('\x19\x01', _domainSeparator, _structHash));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_signerKey, _digest);
    return abi.encodePacked(_r, _s, _v);
  }

  function _join(address _who, uint256 _nonce) internal {
    bytes memory _signature = _signInvite(fundId, _nonce, _aliceKey);
    vm.prank(_who);
    asca.redeemInvite(fundId, _nonce, _signature);
  }

  function _depositAs(address _who, uint256 _amount) internal {
    vm.prank(_who);
    asca.deposit(fundId, _amount);
  }

  function _borrowAs(address _who, uint256 _amount) internal {
    vm.prank(_who);
    asca.borrow(fundId, _amount);
  }

  function _repayAs(address _who, uint256 _amount) internal {
    vm.prank(_who);
    asca.repay(fundId, _amount);
  }

  /// @dev alice saves `_depositAmount` and borrows `_borrowAmount`; returns the loan's due date.
  function _setupLoan(uint256 _depositAmount, uint256 _borrowAmount) internal returns (uint256 _dueDate) {
    _depositAs(alice, _depositAmount);
    _borrowAs(alice, _borrowAmount);
    _dueDate = block.timestamp + REPAYMENT_PERIODS * PERIOD_LENGTH;
  }

  /// @dev alice and bob save 100 each; alice borrows 100 and fully repays 105 after one period,
  ///      distributing 5 ether of interest over 200 shares => 2.5 ether pending each.
  function _setupDistribution() internal {
    _depositAs(alice, DEPOSIT);
    _depositAs(bob, DEPOSIT);
    _borrowAs(alice, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH);
    _repayAs(alice, 105 ether);
  }

  /// @dev Forces the fund's internal cash ledger to `_value` to reach the defensive liquidity guards.
  function _forcePoolCash(uint256 _id, uint256 _value) internal {
    stdstore.target(address(asca)).sig(asca.poolCash.selector).with_key(_id).checked_write(_value);
  }

  // ==========================================================================
  // Initialization & admin
  // ==========================================================================

  function test_InitializeSetsOwner() public {
    assertEq(asca.owner(), owner);

    // A fresh proxy deployment initializes with the given owner.
    AccumulatingSavingCircles _fresh = AccumulatingSavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new AccumulatingSavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(AccumulatingSavingCircles.initialize.selector, alice)
        )
      )
    );
    assertEq(_fresh.owner(), alice);
  }

  function test_InitializeRevertsWhenCalledTwice() public {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    asca.initialize(alice);
  }

  function test_SetTokenAllowedWhenCallerIsOwner() public {
    address _newToken = makeAddr('newToken');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.TokenAllowed(_newToken, true);
    asca.setTokenAllowed(_newToken, true);

    assertTrue(asca.allowedTokens(_newToken));
    assertTrue(asca.isTokenAllowed(_newToken));

    vm.prank(owner);
    asca.setTokenAllowed(_newToken, false);
    assertFalse(asca.isTokenAllowed(_newToken));
  }

  function test_SetTokenAllowedWhenCallerIsNotOwner() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    asca.setTokenAllowed(makeAddr('newToken'), true);
  }

  // ==========================================================================
  // Create
  // ==========================================================================

  function test_CreateFundWithValidParameters() public {
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.FundCreated(1, bob, address(token), 5000, 300, REPAYMENT_PERIODS, PERIOD_LENGTH);
    uint256 _id = asca.create(address(token), 5000, 300, REPAYMENT_PERIODS, PERIOD_LENGTH);

    assertEq(_id, 1);
    IAccumulatingSavingCircles.Fund memory _fund = asca.getFund(_id);
    assertEq(_fund.owner, bob);
    assertEq(_fund.token, address(token));
    assertEq(_fund.borrowLimitBps, 5000);
    assertEq(_fund.interestRateBps, 300);
    assertEq(_fund.repaymentPeriods, REPAYMENT_PERIODS);
    assertEq(_fund.periodLength, PERIOD_LENGTH);
    assertFalse(_fund.deactivated);

    assertTrue(asca.isMember(_id, bob));
    address[] memory _fundMembers = asca.getFundMembers(_id);
    assertEq(_fundMembers.length, 1);
    assertEq(_fundMembers[0], bob);
    uint256[] memory _bobFunds = asca.getMemberFunds(bob);
    assertEq(_bobFunds.length, 2);
    assertEq(_bobFunds[0], fundId);
    assertEq(_bobFunds[1], _id);
  }

  function test_CreateFundIncrementsNextId() public {
    assertEq(asca.nextId(), 1);
    vm.prank(bob);
    asca.create(address(token), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);
    assertEq(asca.nextId(), 2);
  }

  function test_CreateFundWhenTokenNotAllowed() public {
    MockERC20 _other = new MockERC20('Other', 'OTH');
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.TokenNotAllowed.selector));
    asca.create(address(_other), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);
  }

  function test_CreateFundWhenBorrowLimitExceedsMax() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InvalidParameters.selector));
    asca.create(address(token), 10_001, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);
  }

  function test_CreateFundWhenInterestRateExceedsMax() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InvalidParameters.selector));
    asca.create(address(token), BORROW_LIMIT_BPS, 10_001, REPAYMENT_PERIODS, PERIOD_LENGTH);
  }

  function test_CreateFundWhenRepaymentPeriodsZero() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InvalidParameters.selector));
    asca.create(address(token), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, 0, PERIOD_LENGTH);
  }

  function test_CreateFundWhenRepaymentPeriodsExceedsMax() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InvalidParameters.selector));
    asca.create(address(token), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, 1001, PERIOD_LENGTH);
  }

  function test_CreateFundWhenPeriodLengthZero() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InvalidParameters.selector));
    asca.create(address(token), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, REPAYMENT_PERIODS, 0);
  }

  function test_CreateFundWhenPeriodLengthExceedsMax() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InvalidParameters.selector));
    asca.create(address(token), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, REPAYMENT_PERIODS, 365 days + 1);
  }

  function test_CreateFundWithZeroBorrowLimitAllowed() public {
    vm.prank(alice);
    uint256 _id = asca.create(address(token), 0, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);
    assertEq(asca.getFund(_id).borrowLimitBps, 0);

    // A savings-only fund: every borrow reverts.
    vm.startPrank(alice);
    asca.deposit(_id, DEPOSIT);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.ExceedsCreditLine.selector));
    asca.borrow(_id, 1);
    vm.stopPrank();
  }

  // ==========================================================================
  // Invites
  // ==========================================================================

  function test_RedeemInviteWithValidSignature() public {
    bytes memory _signature = _signInvite(fundId, 7, _aliceKey);

    vm.prank(dave);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.InviteRedeemed(fundId, dave);
    asca.redeemInvite(fundId, 7, _signature);

    assertTrue(asca.isMember(fundId, dave));
    assertTrue(asca.usedNonces(fundId, 7));
    address[] memory _fundMembers = asca.getFundMembers(fundId);
    assertEq(_fundMembers.length, 4);
    assertEq(_fundMembers[3], dave);
    uint256[] memory _daveFunds = asca.getMemberFunds(dave);
    assertEq(_daveFunds.length, 1);
    assertEq(_daveFunds[0], fundId);
  }

  function test_RedeemInviteWhenSignerIsNotFundOwner() public {
    bytes memory _signature = _signInvite(fundId, 7, _bobKey);
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InvalidSigner.selector));
    asca.redeemInvite(fundId, 7, _signature);
  }

  function test_RedeemInviteWhenNonceAlreadyUsed() public {
    _join(dave, 7);
    bytes memory _signature = _signInvite(fundId, 7, _aliceKey);
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InviteAlreadyUsed.selector));
    asca.redeemInvite(fundId, 7, _signature);
  }

  function test_RedeemInviteWhenAlreadyMember() public {
    bytes memory _signature = _signInvite(fundId, 7, _aliceKey);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.AlreadyMember.selector));
    asca.redeemInvite(fundId, 7, _signature);
  }

  function test_RedeemInviteWhenFundNotFound() public {
    bytes memory _signature = _signInvite(99, 7, _aliceKey);
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotFound.selector));
    asca.redeemInvite(99, 7, _signature);
  }

  function test_RedeemInviteWhenFundDeactivated() public {
    vm.prank(alice);
    asca.deactivate(fundId);

    bytes memory _signature = _signInvite(fundId, 7, _aliceKey);
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.redeemInvite(fundId, 7, _signature);
  }

  // ==========================================================================
  // Deposit
  // ==========================================================================

  function test_DepositIncreasesSavingsTotalsAndPoolCash() public {
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.SavingsDeposited(fundId, alice, DEPOSIT);
    asca.deposit(fundId, DEPOSIT);

    assertEq(asca.savings(fundId, alice), DEPOSIT);
    assertEq(asca.totalSavings(fundId), DEPOSIT);
    assertEq(asca.poolCash(fundId), DEPOSIT);
    assertEq(token.balanceOf(address(asca)), DEPOSIT);
    assertEq(token.balanceOf(alice), START_BAL - DEPOSIT);

    (uint256 _totalSavings, uint256 _totalBorrowed, uint256 _poolCash) = asca.getFundBalances(fundId);
    assertEq(_totalSavings, DEPOSIT);
    assertEq(_totalBorrowed, 0);
    assertEq(_poolCash, DEPOSIT);
  }

  function test_DepositWhenAmountIsZero() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.ZeroAmount.selector));
    asca.deposit(fundId, 0);
  }

  function test_DepositWhenCallerIsNotMember() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NotMember.selector));
    asca.deposit(fundId, DEPOSIT);
  }

  function test_DepositWhenFundNotFound() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotFound.selector));
    asca.deposit(99, DEPOSIT);
  }

  function test_DepositWhenFundDeactivated() public {
    vm.prank(alice);
    asca.deactivate(fundId);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.deposit(fundId, DEPOSIT);
  }

  function test_DepositSettlesPendingInterestBeforeBalanceChange() public {
    // alice is the sole saver, borrows against herself and pays 5 ether of interest.
    _depositAs(alice, DEPOSIT);
    _borrowAs(alice, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH);
    _repayAs(alice, 105 ether);
    assertEq(asca.pendingInterestOf(fundId, alice), 5 ether);

    // Depositing more settles the pending amount and re-checkpoints without inflating it.
    _depositAs(alice, 50 ether);
    assertEq(asca.interestCredit(fundId, alice), 5 ether);
    assertEq(asca.pendingInterestOf(fundId, alice), 5 ether);
  }

  function test_DepositForCreditsMemberAndPullsFromCaller() public {
    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.SavingsDeposited(fundId, carol, 40 ether);
    asca.depositFor(fundId, carol, 40 ether);

    assertEq(asca.savings(fundId, carol), 40 ether);
    assertEq(asca.savings(fundId, bob), 0);
    assertEq(token.balanceOf(bob), START_BAL - 40 ether);
    assertEq(token.balanceOf(carol), START_BAL);
  }

  function test_DepositForWhenTargetIsNotMember() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NotMember.selector));
    asca.depositFor(fundId, stranger, 40 ether);
  }

  // ==========================================================================
  // Withdraw
  // ==========================================================================

  function test_WithdrawFullSavingsWhenNoDebt() public {
    _depositAs(alice, DEPOSIT);

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.SavingsWithdrawn(fundId, alice, DEPOSIT);
    asca.withdraw(fundId, DEPOSIT);

    assertEq(asca.savings(fundId, alice), 0);
    assertEq(asca.totalSavings(fundId), 0);
    assertEq(asca.poolCash(fundId), 0);
    assertEq(token.balanceOf(alice), START_BAL);
  }

  function test_WithdrawWhenAmountIsZero() public {
    _depositAs(alice, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.ZeroAmount.selector));
    asca.withdraw(fundId, 0);
  }

  function test_WithdrawWhenCallerIsNotMember() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NotMember.selector));
    asca.withdraw(fundId, 1);
  }

  function test_WithdrawWhenAmountExceedsSavings() public {
    _depositAs(alice, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InsufficientSavings.selector));
    asca.withdraw(fundId, DEPOSIT + 1);
  }

  function test_WithdrawWhenPoolCashInsufficient() public {
    _depositAs(alice, DEPOSIT);
    _forcePoolCash(fundId, DEPOSIT - 1);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InsufficientLiquidity.selector));
    asca.withdraw(fundId, DEPOSIT);
  }

  function test_WithdrawWhenRemainingSavingsWouldNotCollateralizeDebt() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InsufficientCollateral.selector));
    asca.withdraw(fundId, 1);
  }

  function test_WithdrawGuardCountsAccruedInterestAsDebt() public {
    _setupLoan(110 ether, DEPOSIT);

    // Pre-accrual: debt is 100, remaining savings after a 5 withdraw is 105 >= 100.
    vm.prank(alice);
    asca.withdraw(fundId, 5 ether);

    // After one period the debt is 105; the same withdraw would leave 100 < 105.
    vm.warp(START_TIME + PERIOD_LENGTH);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InsufficientCollateral.selector));
    asca.withdraw(fundId, 5 ether);
  }

  function test_WithdrawSettlesPendingInterest() public {
    _setupDistribution();

    vm.prank(bob);
    asca.withdraw(fundId, 50 ether);

    assertEq(asca.interestCredit(fundId, bob), 2.5 ether);
    assertEq(asca.pendingInterestOf(fundId, bob), 2.5 ether);
  }

  function test_WithdrawAllowedWhenFundDeactivated() public {
    _depositAs(alice, DEPOSIT);
    vm.prank(alice);
    asca.deactivate(fundId);

    vm.prank(alice);
    asca.withdraw(fundId, DEPOSIT);
    assertEq(token.balanceOf(alice), START_BAL);
  }

  // ==========================================================================
  // Borrow
  // ==========================================================================

  function test_BorrowTransfersCashAndOpensLoan() public {
    _depositAs(alice, DEPOSIT);
    uint256 _dueDate = block.timestamp + REPAYMENT_PERIODS * PERIOD_LENGTH;

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Borrowed(fundId, alice, 60 ether, _dueDate);
    asca.borrow(fundId, 60 ether);

    (IAccumulatingSavingCircles.Loan memory _loan, uint256 _returnedDueDate) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, 60 ether);
    assertEq(_loan.interestOwed, 0);
    assertEq(_loan.periodsAccrued, 0);
    assertEq(_loan.startTime, block.timestamp);
    assertEq(_returnedDueDate, _dueDate);

    assertEq(asca.totalBorrowed(fundId), 60 ether);
    assertEq(asca.poolCash(fundId), 40 ether);
    assertEq(token.balanceOf(alice), START_BAL - DEPOSIT + 60 ether);
  }

  function test_BorrowWhenAmountIsZero() public {
    _depositAs(alice, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.ZeroAmount.selector));
    asca.borrow(fundId, 0);
  }

  function test_BorrowWhenCallerIsNotMember() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NotMember.selector));
    asca.borrow(fundId, 1 ether);
  }

  function test_BorrowWhenFundDeactivated() public {
    _depositAs(alice, DEPOSIT);
    vm.prank(alice);
    asca.deactivate(fundId);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.borrow(fundId, 1 ether);
  }

  function test_BorrowWhenLoanOutstanding() public {
    _setupLoan(DEPOSIT, 10 ether);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.OutstandingLoan.selector));
    asca.borrow(fundId, 10 ether);
  }

  function test_BorrowWhenAmountExceedsCreditLine() public {
    _depositAs(alice, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.ExceedsCreditLine.selector));
    asca.borrow(fundId, DEPOSIT + 1);
  }

  function test_BorrowWhenPoolCashInsufficient() public {
    _depositAs(alice, DEPOSIT);
    _forcePoolCash(fundId, 10 ether);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InsufficientLiquidity.selector));
    asca.borrow(fundId, 50 ether);
  }

  function test_BorrowFullCreditLineAtMaxBps() public {
    _depositAs(alice, DEPOSIT);
    vm.prank(alice);
    asca.borrow(fundId, DEPOSIT);

    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, DEPOSIT);
  }

  function test_BorrowCreditLineRoundsDown() public {
    vm.prank(alice);
    uint256 _id = asca.create(address(token), 5000, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);

    vm.startPrank(alice);
    asca.deposit(_id, 101); // credit line = 101 * 5000 / 10_000 = 50 (floored from 50.5)
    assertEq(asca.creditLineOf(_id, alice), 50);

    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.ExceedsCreditLine.selector));
    asca.borrow(_id, 51);

    asca.borrow(_id, 50);
    vm.stopPrank();

    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(_id, alice);
    assertEq(_loan.principal, 50);
  }

  function test_BorrowAgainAfterFullRepay() public {
    _setupLoan(DEPOSIT, 50 ether);
    _repayAs(alice, 50 ether); // same period => zero interest

    vm.prank(alice);
    asca.borrow(fundId, 60 ether);
    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, 60 ether);
  }

  // ==========================================================================
  // Interest accrual
  // ==========================================================================

  function test_InterestIsZeroBeforeFirstFullPeriod() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH - 1);

    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.interestOwed, 0);

    // Repaying within the first period pays zero interest.
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Repaid(fundId, alice, 0, DEPOSIT);
    asca.repay(fundId, DEPOSIT);
  }

  function test_InterestAccruesPerWholeElapsedPeriod() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + 3 * PERIOD_LENGTH);

    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.interestOwed, DEPOSIT * INTEREST_RATE_BPS * 3 / 10_000); // 15 ether
    assertEq(_loan.periodsAccrued, 3);
  }

  function test_InterestAccrualCapsAtRepaymentPeriods() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + 10 * PERIOD_LENGTH);

    uint256 _cappedInterest = DEPOSIT * INTEREST_RATE_BPS * REPAYMENT_PERIODS / 10_000; // 20 ether
    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.interestOwed, _cappedInterest);
    assertEq(_loan.periodsAccrued, REPAYMENT_PERIODS);

    // The storage accrual path is capped too: a full repay pulls exactly principal + capped interest.
    uint256 _balanceBefore = token.balanceOf(alice);
    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Repaid(fundId, alice, _cappedInterest, DEPOSIT);
    asca.repay(fundId, 200 ether);
    assertEq(_balanceBefore - token.balanceOf(alice), DEPOSIT + _cappedInterest);
  }

  function test_InterestAccruesOnReducedPrincipalAfterPartialRepay() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH);
    _repayAs(alice, 55 ether); // 5 interest + 50 principal, checkpointed at period 1

    vm.warp(START_TIME + 2 * PERIOD_LENGTH); // period 2
    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, 50 ether);
    assertEq(_loan.interestOwed, 50 ether * INTEREST_RATE_BPS / 10_000); // 2.5 ether on the reduced principal
  }

  // ==========================================================================
  // Repay
  // ==========================================================================

  function test_RepayWhenAmountIsZero() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.ZeroAmount.selector));
    asca.repay(fundId, 0);
  }

  function test_RepayWhenNoActiveLoan() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NoActiveLoan.selector));
    asca.repay(fundId, 1 ether);
  }

  function test_RepayAppliesInterestBeforePrincipal() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH); // 5 ether of interest owed

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Repaid(fundId, alice, 5 ether, 25 ether);
    asca.repay(fundId, 30 ether);

    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, 75 ether);
    assertEq(_loan.interestOwed, 0);
  }

  function test_RepayPartialInterestOnlyLeavesPrincipalUntouched() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH);

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Repaid(fundId, alice, 3 ether, 0);
    asca.repay(fundId, 3 ether);

    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, DEPOSIT);
    assertEq(_loan.interestOwed, 2 ether);
    assertEq(asca.totalBorrowed(fundId), DEPOSIT);
  }

  function test_RepayFullClosesLoan() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH);
    _repayAs(alice, 105 ether);

    (IAccumulatingSavingCircles.Loan memory _loan, uint256 _dueDate) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, 0);
    assertEq(_loan.interestOwed, 0);
    assertEq(_loan.startTime, 0);
    assertEq(_dueDate, 0);
    assertEq(asca.totalBorrowed(fundId), 0);
    assertEq(asca.poolCash(fundId), 105 ether);
  }

  function test_RepayOverpaymentPullsOnlyTotalDebt() public {
    _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + PERIOD_LENGTH);

    uint256 _balanceBefore = token.balanceOf(alice);
    _repayAs(alice, 1000 ether);
    assertEq(_balanceBefore - token.balanceOf(alice), 105 ether);
  }

  function test_RepayDistributesInterestToSaversProRata() public {
    _depositAs(alice, 100 ether);
    _depositAs(bob, 300 ether);
    _borrowAs(alice, 100 ether);
    vm.warp(START_TIME + PERIOD_LENGTH);

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.InterestDistributed(fundId, 5 ether);
    asca.repay(fundId, 105 ether);

    // acc = 5e18 * 1e18 / 400e18; alice holds 1/4 of the shares, bob 3/4.
    assertEq(asca.pendingInterestOf(fundId, alice), 1.25 ether);
    assertEq(asca.pendingInterestOf(fundId, bob), 3.75 ether);
  }

  // ==========================================================================
  // Accumulator & claims
  // ==========================================================================

  function test_PendingInterestProRataBySavings() public {
    _setupDistribution();
    assertEq(asca.pendingInterestOf(fundId, alice), 2.5 ether);
    assertEq(asca.pendingInterestOf(fundId, bob), 2.5 ether);
    assertEq(asca.pendingInterestOf(fundId, carol), 0);
  }

  function test_DepositAfterDistributionEarnsNoPastInterest() public {
    _setupDistribution();

    _depositAs(carol, DEPOSIT);
    assertEq(asca.pendingInterestOf(fundId, carol), 0);

    // carol does share in the next distribution (5 ether over 300 shares).
    _borrowAs(alice, DEPOSIT);
    vm.warp(START_TIME + 2 * PERIOD_LENGTH);
    _repayAs(alice, 105 ether);
    uint256 _acc = uint256(5 ether) * 1e18 / 300 ether;
    assertEq(asca.pendingInterestOf(fundId, carol), DEPOSIT * _acc / 1e18);
  }

  function test_BorrowerSavingsKeepEarningWhileBorrowed() public {
    _depositAs(alice, 100 ether);
    _depositAs(bob, 300 ether);
    _borrowAs(alice, 100 ether);
    vm.warp(START_TIME + PERIOD_LENGTH);
    _repayAs(alice, 105 ether);

    // alice's savings stayed shares while borrowed: she earns 1/4 of her own interest payment.
    assertEq(asca.pendingInterestOf(fundId, alice), 1.25 ether);
  }

  function test_InterestDistributionRoundsDownAndDustStaysInPool() public {
    _depositAs(alice, 1 ether);
    _depositAs(bob, 2 ether);
    _borrowAs(alice, 1 ether);
    vm.warp(START_TIME + PERIOD_LENGTH);
    _repayAs(alice, 2 ether); // pulls 1.05 ether; distributes 0.05 ether over 3 ether of shares

    uint256 _alicePending = asca.pendingInterestOf(fundId, alice);
    uint256 _bobPending = asca.pendingInterestOf(fundId, bob);
    assertLe(_alicePending + _bobPending, 0.05 ether);
    assertEq(0.05 ether - (_alicePending + _bobPending), 2); // 2 wei of dust

    vm.prank(alice);
    asca.claimInterest(fundId);
    vm.prank(bob);
    asca.claimInterest(fundId);

    // The dust stays in poolCash as an untracked surplus; the contract can back all claims.
    assertEq(asca.poolCash(fundId), asca.totalSavings(fundId) + 2);
    assertEq(token.balanceOf(address(asca)), asca.poolCash(fundId));
  }

  function test_ClaimInterestTransfersAndResetsCredit() public {
    _setupDistribution();
    uint256 _poolCashBefore = asca.poolCash(fundId);

    vm.prank(bob);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.InterestClaimed(fundId, bob, 2.5 ether);
    asca.claimInterest(fundId);

    assertEq(asca.poolCash(fundId), _poolCashBefore - 2.5 ether);
    assertEq(asca.pendingInterestOf(fundId, bob), 0);
    assertEq(token.balanceOf(bob), START_BAL - DEPOSIT + 2.5 ether);

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NothingToClaim.selector));
    asca.claimInterest(fundId);
  }

  function test_ClaimInterestWhenNothingToClaim() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NothingToClaim.selector));
    asca.claimInterest(fundId);
  }

  function test_ClaimInterestWhenPoolCashInsufficient() public {
    _setupDistribution();
    _forcePoolCash(fundId, 1);

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.InsufficientLiquidity.selector));
    asca.claimInterest(fundId);
  }

  // ==========================================================================
  // Liquidate
  // ==========================================================================

  function test_LiquidateWhenLoanNotOverdue() public {
    uint256 _dueDate = _setupLoan(DEPOSIT, DEPOSIT);

    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NotLiquidatable.selector));
    asca.liquidate(fundId, alice);

    vm.warp(_dueDate - 1);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NotLiquidatable.selector));
    asca.liquidate(fundId, alice);
  }

  function test_LiquidateWhenNoActiveLoan() public {
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NoActiveLoan.selector));
    asca.liquidate(fundId, bob);
  }

  function test_LiquidateAtDueDateSeizesPrincipalAndInterest() public {
    _depositAs(bob, 100 ether);
    uint256 _dueDate = _setupLoan(150 ether, 100 ether);
    vm.warp(_dueDate); // 20 ether of interest owed, frozen at the cap

    uint256 _contractBalanceBefore = token.balanceOf(address(asca));
    uint256 _poolCashBefore = asca.poolCash(fundId);

    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.InterestDistributed(fundId, 20 ether);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Liquidated(fundId, alice, 100 ether, 20 ether);
    asca.liquidate(fundId, alice);

    // Pure ledger reallocation: no tokens moved, poolCash untouched.
    assertEq(token.balanceOf(address(asca)), _contractBalanceBefore);
    assertEq(asca.poolCash(fundId), _poolCashBefore);

    assertEq(asca.savings(fundId, alice), 30 ether);
    assertEq(asca.totalSavings(fundId), 130 ether);
    assertEq(asca.totalBorrowed(fundId), 0);

    (IAccumulatingSavingCircles.Loan memory _loan, uint256 _returnedDueDate) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, 0);
    assertEq(_returnedDueDate, 0);
    assertFalse(asca.isLiquidatable(fundId, alice));
  }

  function test_LiquidateIsPermissionless() public {
    uint256 _dueDate = _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(_dueDate);

    vm.prank(stranger);
    asca.liquidate(fundId, alice);
    assertEq(asca.totalBorrowed(fundId), 0);
  }

  function test_LiquidateWithInterestShortfallSeizesOnlyAvailableSavings() public {
    _depositAs(bob, 100 ether);
    uint256 _dueDate = _setupLoan(105 ether, 100 ether);
    vm.warp(_dueDate); // interest owed is 20 ether but only 5 ether of savings remain above principal

    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Liquidated(fundId, alice, 100 ether, 5 ether);
    asca.liquidate(fundId, alice);

    assertEq(asca.savings(fundId, alice), 0);
    assertEq(asca.totalSavings(fundId), 100 ether);
  }

  function test_LiquidateSoleSaverSkipsInterestSeizure() public {
    // alice is the only saver: seizing her interest would leave zero shares to distribute to.
    uint256 _dueDate = _setupLoan(110 ether, 100 ether);
    vm.warp(_dueDate);

    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.Liquidated(fundId, alice, 100 ether, 0);
    asca.liquidate(fundId, alice);

    assertEq(asca.savings(fundId, alice), 10 ether);
    assertEq(asca.totalSavings(fundId), 10 ether);
    assertEq(asca.accInterestPerShare(fundId), 0);
  }

  function test_LiquidateDistributesSeizedInterestToRemainingSavers() public {
    _depositAs(bob, 100 ether);
    uint256 _dueDate = _setupLoan(150 ether, 100 ether);
    vm.warp(_dueDate);

    asca.liquidate(fundId, alice);

    // 20 ether distributed over the 130 ether of shares left after the seizure; alice's own
    // remaining 30 ether of savings still count as shares.
    uint256 _acc = uint256(20 ether) * 1e18 / 130 ether;
    assertEq(asca.accInterestPerShare(fundId), _acc);
    assertEq(asca.pendingInterestOf(fundId, bob), 100 ether * _acc / 1e18);
    assertEq(asca.pendingInterestOf(fundId, alice), 30 ether * _acc / 1e18);
  }

  function test_LiquidateRestoresPoolLiquidityForWithdrawals() public {
    // Liquidity crunch: alice borrows her whole savings, so poolCash exactly equals bob's claim.
    _depositAs(bob, DEPOSIT);
    uint256 _dueDate = _setupLoan(DEPOSIT, DEPOSIT);
    assertEq(asca.poolCash(fundId), DEPOSIT);

    // alice defaults; permissionless liquidation extinguishes the receivable at the due date.
    vm.warp(_dueDate);
    asca.liquidate(fundId, alice);
    assertEq(asca.totalBorrowed(fundId), 0);

    // bob can exit in full and the fund drains exactly.
    vm.prank(bob);
    asca.withdraw(fundId, DEPOSIT);
    assertEq(token.balanceOf(bob), START_BAL);
    assertEq(asca.poolCash(fundId), 0);
    assertEq(asca.totalSavings(fundId), 0);
  }

  function test_LiquidateAllowedWhenFundDeactivated() public {
    uint256 _dueDate = _setupLoan(DEPOSIT, DEPOSIT);
    vm.prank(alice);
    asca.deactivate(fundId);

    vm.warp(_dueDate);
    asca.liquidate(fundId, alice);
    assertEq(asca.totalBorrowed(fundId), 0);
  }

  function test_BorrowAfterLiquidationWithFreshSavings() public {
    uint256 _dueDate = _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(_dueDate);
    asca.liquidate(fundId, alice);
    assertEq(asca.savings(fundId, alice), 0);

    _depositAs(alice, 50 ether);
    vm.prank(alice);
    asca.borrow(fundId, 25 ether);

    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, 25 ether);
  }

  // ==========================================================================
  // Deactivate
  // ==========================================================================

  function test_DeactivateWhenCallerIsNotFundOwner() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.NotFundOwner.selector));
    asca.deactivate(fundId);
  }

  function test_DeactivateWhenAlreadyDeactivated() public {
    vm.startPrank(alice);
    asca.deactivate(fundId);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.deactivate(fundId);
    vm.stopPrank();
  }

  function test_DeactivateBlocksDepositBorrowAndInvitesButAllowsExits() public {
    _depositAs(alice, DEPOSIT);
    _borrowAs(alice, 50 ether);
    vm.warp(START_TIME + PERIOD_LENGTH); // 2.5 ether of interest owed

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAccumulatingSavingCircles.FundDeactivated(fundId);
    asca.deactivate(fundId);
    assertTrue(asca.getFund(fundId).deactivated);

    // Frozen: deposit / depositFor / borrow / redeemInvite.
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.deposit(fundId, 1 ether);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.depositFor(fundId, alice, 1 ether);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.borrow(fundId, 1 ether);
    bytes memory _signature = _signInvite(fundId, 7, _aliceKey);
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotActive.selector));
    asca.redeemInvite(fundId, 7, _signature);

    // Open: repay, claimInterest, withdraw.
    _repayAs(alice, 52.5 ether);
    vm.startPrank(alice);
    asca.claimInterest(fundId); // 2.5 ether, alice is the sole saver
    asca.withdraw(fundId, DEPOSIT);
    vm.stopPrank();

    assertEq(asca.poolCash(fundId), 0);
    assertEq(token.balanceOf(alice), START_BAL);
  }

  // ==========================================================================
  // Views
  // ==========================================================================

  function test_GetFundWhenFundNotFound() public {
    vm.expectRevert(abi.encodeWithSelector(IAccumulatingSavingCircles.FundNotFound.selector));
    asca.getFund(99);
  }

  function test_GetLoanReflectsLiveAccrualAndDueDate() public {
    uint256 _dueDate = _setupLoan(DEPOSIT, DEPOSIT);
    vm.warp(START_TIME + 2 * PERIOD_LENGTH);

    (IAccumulatingSavingCircles.Loan memory _loan, uint256 _returnedDueDate) = asca.getLoan(fundId, alice);
    assertEq(_loan.principal, DEPOSIT);
    assertEq(_loan.interestOwed, 10 ether); // 2 whole periods at 5%
    assertEq(_loan.periodsAccrued, 2);
    assertEq(_returnedDueDate, _dueDate);
  }

  function test_CreditLineOfFloors() public {
    vm.prank(alice);
    uint256 _id = asca.create(address(token), 2500, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);

    vm.prank(alice);
    asca.deposit(_id, 7);
    assertEq(asca.creditLineOf(_id, alice), 1); // floor(7 * 2500 / 10_000) = floor(1.75)
  }

  function test_MaxBorrowableOfIsMinOfCreditLineAndPoolCashAndZeroWhenLoanOpenOrDeactivated() public {
    _depositAs(alice, DEPOSIT);
    assertEq(asca.maxBorrowableOf(fundId, alice), DEPOSIT); // creditLine == poolCash

    // poolCash below the credit line bounds the result.
    _forcePoolCash(fundId, 30 ether);
    assertEq(asca.maxBorrowableOf(fundId, alice), 30 ether);
    _forcePoolCash(fundId, DEPOSIT);

    // Zero while a loan is open.
    _borrowAs(alice, 40 ether);
    assertEq(asca.maxBorrowableOf(fundId, alice), 0);
    _repayAs(alice, 40 ether);
    assertEq(asca.maxBorrowableOf(fundId, alice), DEPOSIT);

    // Zero once deactivated.
    vm.prank(alice);
    asca.deactivate(fundId);
    assertEq(asca.maxBorrowableOf(fundId, alice), 0);
  }

  function test_WithdrawableOfEqualsSavingsPlusPendingInterest() public {
    _setupDistribution();
    assertEq(asca.withdrawableOf(fundId, bob), DEPOSIT + 2.5 ether);
    assertEq(asca.withdrawableOf(fundId, carol), 0);
  }

  function test_IsLiquidatableBranches() public {
    assertFalse(asca.isLiquidatable(fundId, alice)); // no loan

    uint256 _dueDate = _setupLoan(DEPOSIT, DEPOSIT);
    assertFalse(asca.isLiquidatable(fundId, alice)); // not due yet

    vm.warp(_dueDate);
    assertTrue(asca.isLiquidatable(fundId, alice)); // due
  }

  function test_GetFundMembersAndGetMemberFunds() public {
    address[] memory _fundMembers = asca.getFundMembers(fundId);
    assertEq(_fundMembers.length, 3);
    assertEq(_fundMembers[0], alice);
    assertEq(_fundMembers[1], bob);
    assertEq(_fundMembers[2], carol);

    vm.prank(alice);
    uint256 _id = asca.create(address(token), BORROW_LIMIT_BPS, INTEREST_RATE_BPS, REPAYMENT_PERIODS, PERIOD_LENGTH);
    uint256[] memory _aliceFunds = asca.getMemberFunds(alice);
    assertEq(_aliceFunds.length, 2);
    assertEq(_aliceFunds[0], fundId);
    assertEq(_aliceFunds[1], _id);
  }

  // ==========================================================================
  // Conservation
  // ==========================================================================

  function test_ConservationAcrossFullLifecycle() public {
    _depositAs(alice, 100 ether);
    _depositAs(bob, 200 ether);
    _borrowAs(alice, 100 ether);
    vm.warp(START_TIME + 2 * PERIOD_LENGTH);
    _repayAs(alice, 110 ether); // 10 ether of interest over 300 ether of shares

    vm.prank(alice);
    asca.claimInterest(fundId);
    vm.prank(bob);
    asca.claimInterest(fundId);
    vm.prank(alice);
    asca.withdraw(fundId, 100 ether);
    vm.prank(bob);
    asca.withdraw(fundId, 200 ether);

    // Everyone exited: only floor-rounding dust remains, fully backed by tokens.
    uint256 _acc = uint256(10 ether) * 1e18 / 300 ether;
    uint256 _dust = 10 ether - (100 ether * _acc / 1e18 + 200 ether * _acc / 1e18);
    assertEq(asca.totalSavings(fundId), 0);
    assertEq(asca.totalBorrowed(fundId), 0);
    assertEq(asca.poolCash(fundId), _dust);
    assertEq(token.balanceOf(address(asca)), _dust);
    assertEq(token.balanceOf(alice), START_BAL - 10 ether + 100 ether * _acc / 1e18);
    assertEq(token.balanceOf(bob), START_BAL + 200 ether * _acc / 1e18);
  }

  // ==========================================================================
  // Fuzz
  // ==========================================================================

  function testFuzz_InterestAccrualMatchesFormula(uint256 _principal, uint256 _elapsedPeriods) public {
    _principal = bound(_principal, 1, 1_000_000 ether);
    _elapsedPeriods = bound(_elapsedPeriods, 0, 3 * REPAYMENT_PERIODS);

    token.mint(alice, _principal);
    vm.startPrank(alice);
    asca.deposit(fundId, _principal);
    asca.borrow(fundId, _principal);
    vm.stopPrank();

    vm.warp(START_TIME + _elapsedPeriods * PERIOD_LENGTH);

    uint256 _cappedPeriods = _elapsedPeriods < REPAYMENT_PERIODS ? _elapsedPeriods : REPAYMENT_PERIODS;
    (IAccumulatingSavingCircles.Loan memory _loan,) = asca.getLoan(fundId, alice);
    assertEq(_loan.interestOwed, _principal * INTEREST_RATE_BPS * _cappedPeriods / 10_000);
    assertEq(_loan.periodsAccrued, _cappedPeriods);
  }

  function testFuzz_DepositWithdrawRoundTrip(uint256 _amount) public {
    _amount = bound(_amount, 1, START_BAL);

    vm.startPrank(alice);
    asca.deposit(fundId, _amount);
    asca.withdraw(fundId, _amount);
    vm.stopPrank();

    assertEq(token.balanceOf(alice), START_BAL);
    assertEq(asca.savings(fundId, alice), 0);
    assertEq(asca.totalSavings(fundId), 0);
    assertEq(asca.poolCash(fundId), 0);
  }
}
