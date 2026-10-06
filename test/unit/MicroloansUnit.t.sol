// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {Microloans} from 'src/contracts/Microloans.sol';
import {IMicroloans} from 'src/interfaces/IMicroloans.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';
import {MockERC4626} from 'test/mocks/MockERC4626.sol';

/// @dev 6-decimal token so the tests exercise the same units as USDT on Celo.
contract MockUSDT is MockERC20 {
  constructor() MockERC20('Tether USD', 'USDT') {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }
}

/**
 * @notice Unit tests for {Microloans}.
 * @dev Actors: owner is the registry admin, bread is the lender, coop is the borrower (the
 *      nonprofit), helper pays on the borrower's behalf, stranger has no role.
 */
contract MicroloansUnit is Test {
  Microloans public loans;
  MockUSDT public usdt;
  MockERC4626 public vault;

  uint256 public constant PRINCIPAL = 1000e6;
  uint256 public constant GRANT = 1000e6;
  uint256 public constant ACCEPT_WINDOW = 14 days;
  uint256 public constant PERIOD = 300 days;
  uint256 public constant START_BAL = 100_000e6;
  bytes32 public constant TERMS = keccak256('ipfs://loan-agreement');

  address public owner = makeAddr('owner');
  address public bread = makeAddr('bread');
  address public coop = makeAddr('coop');
  address public helper = makeAddr('helper');
  address public stranger = makeAddr('stranger');

  function setUp() public {
    vm.startPrank(owner);
    loans = Microloans(
      address(
        new TransparentUpgradeableProxy(
          address(new Microloans()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(Microloans.initialize.selector, owner)
        )
      )
    );
    usdt = new MockUSDT();
    vault = new MockERC4626(IERC20(address(usdt)));
    loans.setTokenAllowed(address(usdt), true);
    loans.setVaultAllowed(address(vault), true);
    vm.stopPrank();

    address[4] memory holders = [bread, coop, helper, stranger];
    for (uint256 i = 0; i < holders.length; i++) {
      usdt.mint(holders[i], START_BAL);
      vm.prank(holders[i]);
      usdt.approve(address(loans), type(uint256).max);
    }
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  function _terms(address _vault, uint256 _grant) internal view returns (IMicroloans.LoanTerms memory) {
    return IMicroloans.LoanTerms({
      token: address(usdt),
      vault: _vault,
      principal: PRINCIPAL,
      grant: _grant,
      acceptBy: block.timestamp + ACCEPT_WINDOW,
      repaymentPeriod: PERIOD,
      termsHash: TERMS
    });
  }

  function _create(address _vault, uint256 _grant) internal returns (uint256 _id) {
    vm.prank(bread);
    _id = loans.create(_terms(_vault, _grant), coop);
  }

  function _createAccepted(address _vault, uint256 _grant) internal returns (uint256 _id) {
    _id = _create(_vault, _grant);
    vm.prank(coop);
    loans.accept(_id, TERMS);
  }

  function _status(uint256 _id) internal view returns (IMicroloans.LoanStatus memory _st) {
    (, _st) = loans.getLoan(_id);
  }

  // --------------------------------------------------------------------------
  // Admin
  // --------------------------------------------------------------------------

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert();
    loans.initialize(stranger);
  }

  function test_setTokenAllowed_onlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
    loans.setTokenAllowed(address(usdt), false);
  }

  function test_setVaultAllowed_onlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
    loans.setVaultAllowed(address(vault), false);
  }

  function test_allowlists_emitAndToggle() public {
    vm.startPrank(owner);
    vm.expectEmit(true, true, false, false);
    emit IMicroloans.TokenAllowed(address(usdt), false);
    loans.setTokenAllowed(address(usdt), false);
    vm.expectEmit(true, true, false, false);
    emit IMicroloans.VaultAllowed(address(vault), false);
    loans.setVaultAllowed(address(vault), false);
    vm.stopPrank();
    assertFalse(loans.isTokenAllowed(address(usdt)));
    assertFalse(loans.isVaultAllowed(address(vault)));
  }

  // --------------------------------------------------------------------------
  // create
  // --------------------------------------------------------------------------

  function test_create_pullsPrincipalPlusGrant() public {
    uint256 _id = _create(address(0), GRANT);
    assertEq(_id, 0);
    assertEq(loans.nextId(), 1);
    assertEq(usdt.balanceOf(bread), START_BAL - PRINCIPAL - GRANT);
    assertEq(usdt.balanceOf(address(loans)), PRINCIPAL + GRANT);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Offered));
    assertEq(loans.escrowValue(_id), PRINCIPAL + GRANT);
    assertEq(loans.getLenderLoans(bread)[0], _id);
    assertEq(loans.getBorrowerLoans(coop)[0], _id);
    IMicroloans.LoanStatus memory _st = _status(_id);
    assertEq(_st.lender, bread);
    assertEq(_st.borrower, coop);
  }

  function test_create_depositsIntoVault() public {
    uint256 _id = _create(address(vault), GRANT);
    assertEq(usdt.balanceOf(address(loans)), 0);
    assertEq(vault.balanceOf(address(loans)), _status(_id).held);
    assertEq(loans.escrowValue(_id), PRINCIPAL + GRANT);
  }

  function test_create_emits() public {
    IMicroloans.LoanTerms memory _t = _terms(address(0), GRANT);
    vm.expectEmit(true, true, true, true);
    emit IMicroloans.LoanCreated(0, bread, coop, _t);
    vm.prank(bread);
    loans.create(_t, coop);
  }

  function test_create_revertsTokenNotAllowed() public {
    IMicroloans.LoanTerms memory _t = _terms(address(0), GRANT);
    _t.token = address(0xdead);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.TokenNotAllowed.selector);
    loans.create(_t, coop);
  }

  function test_create_revertsVaultNotAllowed() public {
    vm.prank(owner);
    loans.setVaultAllowed(address(vault), false);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidVault.selector);
    loans.create(_terms(address(vault), GRANT), coop);
  }

  function test_create_revertsVaultAssetMismatch() public {
    MockERC20 _other = new MockERC20('Other', 'OTH');
    MockERC4626 _otherVault = new MockERC4626(IERC20(address(_other)));
    vm.prank(owner);
    loans.setVaultAllowed(address(_otherVault), true);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidVault.selector);
    loans.create(_terms(address(_otherVault), GRANT), coop);
  }

  function test_create_revertsZeroPrincipal() public {
    IMicroloans.LoanTerms memory _t = _terms(address(0), GRANT);
    _t.principal = 0;
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidPrincipal.selector);
    loans.create(_t, coop);
  }

  function test_create_revertsAcceptByNotInFuture() public {
    IMicroloans.LoanTerms memory _t = _terms(address(0), GRANT);
    _t.acceptBy = block.timestamp;
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidAcceptBy.selector);
    loans.create(_t, coop);
  }

  function test_create_revertsZeroPeriod() public {
    IMicroloans.LoanTerms memory _t = _terms(address(0), GRANT);
    _t.repaymentPeriod = 0;
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidRepaymentPeriod.selector);
    loans.create(_t, coop);
  }

  function test_create_revertsSelfBorrower() public {
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidBorrower.selector);
    loans.create(_terms(address(0), GRANT), bread);
  }

  // --------------------------------------------------------------------------
  // setBorrower
  // --------------------------------------------------------------------------

  function test_setBorrower_namesBorrowerLater() public {
    vm.prank(bread);
    uint256 _id = loans.create(_terms(address(0), GRANT), address(0));
    assertEq(loans.getBorrowerLoans(coop).length, 0);

    vm.expectEmit(true, true, false, false);
    emit IMicroloans.BorrowerSet(_id, coop);
    vm.prank(bread);
    loans.setBorrower(_id, coop);

    assertEq(_status(_id).borrower, coop);
    assertEq(loans.getBorrowerLoans(coop)[0], _id);
    vm.prank(coop);
    loans.accept(_id, TERMS);
  }

  function test_setBorrower_reverts() public {
    vm.prank(bread);
    uint256 _id = loans.create(_terms(address(0), GRANT), address(0));

    vm.prank(stranger);
    vm.expectRevert(IMicroloans.NotLender.selector);
    loans.setBorrower(_id, coop);

    vm.startPrank(bread);
    vm.expectRevert(IMicroloans.InvalidBorrower.selector);
    loans.setBorrower(_id, address(0));
    vm.expectRevert(IMicroloans.InvalidBorrower.selector);
    loans.setBorrower(_id, bread);
    loans.setBorrower(_id, coop);
    vm.expectRevert(IMicroloans.BorrowerAlreadySet.selector);
    loans.setBorrower(_id, helper);
    vm.stopPrank();

    vm.expectRevert(IMicroloans.LoanNotFound.selector);
    loans.setBorrower(99, coop);
  }

  function test_setBorrower_revertsAfterExpiry() public {
    vm.prank(bread);
    uint256 _id = loans.create(_terms(address(0), GRANT), address(0));
    vm.warp(block.timestamp + ACCEPT_WINDOW);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.setBorrower(_id, coop);
  }

  // --------------------------------------------------------------------------
  // cancel
  // --------------------------------------------------------------------------

  function test_cancel_refundsOffered() public {
    uint256 _id = _create(address(0), GRANT);
    vm.expectEmit(true, false, false, true);
    emit IMicroloans.LoanCancelled(_id, PRINCIPAL + GRANT);
    vm.prank(bread);
    loans.cancel(_id);
    assertEq(usdt.balanceOf(bread), START_BAL);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Cancelled));
  }

  function test_cancel_refundsExpiredWithYield() public {
    uint256 _id = _create(address(vault), GRANT);
    vault.simulateYield(10e6);
    vm.warp(block.timestamp + ACCEPT_WINDOW);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Expired));
    vm.prank(bread);
    loans.cancel(_id);
    assertApproxEqAbs(usdt.balanceOf(bread), START_BAL + 10e6, 1);
    assertEq(vault.balanceOf(address(loans)), 0);
  }

  function test_cancel_reverts() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(stranger);
    vm.expectRevert(IMicroloans.NotLender.selector);
    loans.cancel(_id);

    vm.prank(coop);
    loans.accept(_id, TERMS);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.cancel(_id);
  }

  // --------------------------------------------------------------------------
  // accept
  // --------------------------------------------------------------------------

  function test_accept_disbursesPrincipal() public {
    uint256 _id = _create(address(0), GRANT);
    vm.expectEmit(true, true, false, true);
    emit IMicroloans.LoanAccepted(_id, coop, PRINCIPAL, block.timestamp + PERIOD);
    vm.prank(coop);
    loans.accept(_id, TERMS);

    assertEq(usdt.balanceOf(coop), START_BAL + PRINCIPAL);
    assertEq(loans.escrowValue(_id), GRANT);
    assertEq(loans.outstanding(_id), PRINCIPAL);
    IMicroloans.LoanStatus memory _st = _status(_id);
    assertEq(_st.acceptedAt, block.timestamp);
    assertEq(_st.repayBy, block.timestamp + PERIOD);
    assertEq(_st.disbursed, PRINCIPAL);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Active));
  }

  function test_accept_fromVaultKeepsGrantEarning() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    assertEq(usdt.balanceOf(coop), START_BAL + PRINCIPAL);
    assertApproxEqAbs(loans.escrowValue(_id), GRANT, 1);
    vault.simulateYield(50e6);
    assertGt(loans.escrowValue(_id), GRANT);
  }

  function test_accept_noGrantCreditsOfferYieldToLender() public {
    uint256 _id = _create(address(vault), 0);
    vault.simulateYield(5e6);
    vm.prank(coop);
    loans.accept(_id, TERMS);
    assertEq(usdt.balanceOf(coop), START_BAL + PRINCIPAL);
    assertEq(_status(_id).held, 0);
    assertApproxEqAbs(_status(_id).lenderOwed, 5e6, 1);
  }

  function test_accept_reverts() public {
    uint256 _id = _create(address(0), GRANT);

    vm.prank(stranger);
    vm.expectRevert(IMicroloans.NotBorrower.selector);
    loans.accept(_id, TERMS);

    vm.prank(coop);
    vm.expectRevert(IMicroloans.TermsMismatch.selector);
    loans.accept(_id, bytes32(0));

    vm.expectRevert(IMicroloans.LoanNotFound.selector);
    loans.accept(99, TERMS);

    vm.warp(block.timestamp + ACCEPT_WINDOW);
    vm.prank(coop);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.accept(_id, TERMS);
  }

  function test_accept_revertsTwice() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.accept(_id, TERMS);
  }

  function test_accept_revertsWhenCancelled() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(bread);
    loans.cancel(_id);
    vm.prank(coop);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.accept(_id, TERMS);
  }

  // --------------------------------------------------------------------------
  // repay
  // --------------------------------------------------------------------------

  function test_repay_installmentsUnlockGrant() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    for (uint256 i = 0; i < 9; i++) {
      vm.prank(coop);
      loans.repay(_id, 100e6);
    }
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Active));
    assertEq(loans.outstanding(_id), 100e6);

    vm.expectEmit(true, true, false, true);
    emit IMicroloans.Repaid(_id, coop, 100e6, PRINCIPAL);
    vm.prank(coop);
    loans.repay(_id, 100e6);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Repaid));
    assertEq(_status(_id).lenderOwed, PRINCIPAL);
  }

  function test_repay_capsAtOutstanding() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    loans.repay(_id, 5000e6);
    assertEq(_status(_id).repaid, PRINCIPAL);
    assertEq(usdt.balanceOf(coop), START_BAL);
  }

  function test_repay_byHelper() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(helper);
    loans.repay(_id, PRINCIPAL);
    assertEq(usdt.balanceOf(helper), START_BAL - PRINCIPAL);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Repaid));
  }

  function test_repay_reverts() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(coop);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.repay(_id, 1);

    vm.prank(coop);
    loans.accept(_id, TERMS);
    vm.prank(coop);
    vm.expectRevert(IMicroloans.InvalidAmount.selector);
    loans.repay(_id, 0);

    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);
    vm.prank(coop);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.repay(_id, 1);

    vm.expectRevert(IMicroloans.LoanNotFound.selector);
    loans.repay(99, 1);
  }

  function test_repay_lateStillUnlocksIfNotReclaimed() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.warp(block.timestamp + PERIOD + 30 days);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Overdue));
    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);
    loans.releaseGrant(_id);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Completed));
  }

  // --------------------------------------------------------------------------
  // releaseGrant
  // --------------------------------------------------------------------------

  function test_releaseGrant_paysBorrowerPermissionlessly() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);

    vm.expectEmit(true, true, false, true);
    emit IMicroloans.GrantReleased(_id, coop, GRANT);
    vm.prank(stranger);
    loans.releaseGrant(_id);

    assertEq(usdt.balanceOf(coop), START_BAL + GRANT);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Completed));
    assertEq(loans.escrowValue(_id), 0);
  }

  function test_releaseGrant_yieldGoesToLender() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    vault.simulateYield(40e6);
    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);
    loans.releaseGrant(_id);

    assertEq(usdt.balanceOf(coop), START_BAL + GRANT);
    uint256 _owed = _status(_id).lenderOwed;
    assertApproxEqAbs(_owed, PRINCIPAL + 40e6, 2);
    loans.collect(_id);
    assertApproxEqAbs(usdt.balanceOf(bread), START_BAL - PRINCIPAL - GRANT + PRINCIPAL + 40e6, 2);
    assertEq(vault.balanceOf(address(loans)), 0);
  }

  function test_releaseGrant_reverts() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.releaseGrant(_id);

    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);
    loans.releaseGrant(_id);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.releaseGrant(_id);
  }

  function test_noGrant_completesOnRepayment() public {
    uint256 _id = _createAccepted(address(0), 0);
    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Completed));
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.releaseGrant(_id);
  }

  // --------------------------------------------------------------------------
  // reclaimGrant / extendRepayBy
  // --------------------------------------------------------------------------

  function test_reclaimGrant_whenOverdue() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    vm.prank(coop);
    loans.repay(_id, 400e6);
    vault.simulateYield(20e6);
    vm.warp(block.timestamp + PERIOD);

    vm.prank(bread);
    loans.reclaimGrant(_id);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Defaulted));
    assertApproxEqAbs(usdt.balanceOf(bread), START_BAL - PRINCIPAL - GRANT + GRANT + 20e6, 2);

    // The principal is still owed and can be repaid after default, but the grant is gone.
    vm.prank(coop);
    loans.repay(_id, 600e6);
    assertEq(loans.outstanding(_id), 0);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Defaulted));
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.releaseGrant(_id);
    loans.collect(_id);
  }

  function test_reclaimGrant_reverts() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.reclaimGrant(_id);

    vm.warp(block.timestamp + PERIOD);
    vm.prank(stranger);
    vm.expectRevert(IMicroloans.NotLender.selector);
    loans.reclaimGrant(_id);

    uint256 _noGrant = _createAccepted(address(0), 0);
    vm.warp(block.timestamp + PERIOD);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.reclaimGrant(_noGrant);
  }

  function test_extendRepayBy_rescuesOverdueLoan() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    uint256 _repayBy = _status(_id).repayBy;
    vm.warp(_repayBy);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Overdue));

    vm.expectEmit(true, false, false, true);
    emit IMicroloans.RepayByExtended(_id, _repayBy + 60 days);
    vm.prank(bread);
    loans.extendRepayBy(_id, _repayBy + 60 days);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Active));

    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.reclaimGrant(_id);
  }

  function test_extendRepayBy_reverts() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidState.selector);
    loans.extendRepayBy(_id, block.timestamp + 1000 days);

    vm.prank(coop);
    loans.accept(_id, TERMS);
    uint256 _repayBy = _status(_id).repayBy;
    vm.prank(bread);
    vm.expectRevert(IMicroloans.InvalidRepaymentPeriod.selector);
    loans.extendRepayBy(_id, _repayBy);

    vm.prank(stranger);
    vm.expectRevert(IMicroloans.NotLender.selector);
    loans.extendRepayBy(_id, _repayBy + 1);
  }

  // --------------------------------------------------------------------------
  // collect
  // --------------------------------------------------------------------------

  function test_collect_paysLender() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    loans.repay(_id, 300e6);

    vm.expectEmit(true, true, false, true);
    emit IMicroloans.LenderCollected(_id, bread, 300e6);
    vm.prank(stranger);
    loans.collect(_id);
    assertEq(usdt.balanceOf(bread), START_BAL - PRINCIPAL - GRANT + 300e6);

    vm.expectRevert(IMicroloans.NothingToCollect.selector);
    loans.collect(_id);
  }

  // --------------------------------------------------------------------------
  // Vault loss
  // --------------------------------------------------------------------------

  function test_vaultLoss_borrowerOwesOnlyWhatWasDisbursed() public {
    uint256 _id = _create(address(vault), GRANT);
    vault.simulateLoss(1500e6);
    vm.prank(coop);
    loans.accept(_id, TERMS);

    uint256 _disbursed = _status(_id).disbursed;
    assertLt(_disbursed, PRINCIPAL);
    assertEq(loans.outstanding(_id), _disbursed);
    assertEq(_status(_id).held, 0);

    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);
    assertEq(_status(_id).repaid, _disbursed);
    loans.releaseGrant(_id);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Completed));
  }

  function test_vaultLoss_grantPaysWhatRemains() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    vault.simulateLoss(250e6);
    vm.prank(coop);
    loans.repay(_id, PRINCIPAL);
    uint256 _before = usdt.balanceOf(coop);
    loans.releaseGrant(_id);
    assertApproxEqAbs(usdt.balanceOf(coop) - _before, 750e6, 2);
    assertEq(vault.balanceOf(address(loans)), 0);
  }

  // --------------------------------------------------------------------------
  // Isolation and fuzz
  // --------------------------------------------------------------------------

  function test_twoLoansSameVault_noBleed() public {
    uint256 _a = _createAccepted(address(vault), GRANT);
    uint256 _b = _createAccepted(address(vault), GRANT);
    vault.simulateYield(100e6);
    vm.prank(coop);
    loans.repay(_a, PRINCIPAL);
    loans.releaseGrant(_a);

    assertEq(vault.balanceOf(address(loans)), _status(_b).held);
    assertApproxEqAbs(_status(_a).lenderOwed, PRINCIPAL + 50e6, 2);
    assertApproxEqAbs(loans.escrowValue(_b), GRANT + 50e6, 2);
  }

  function testFuzz_fullLifecycle_conservesFunds(
    uint256 _principal,
    uint256 _grant,
    uint256 _yield,
    uint8 _installments,
    bool _useVault
  ) public {
    _principal = bound(_principal, 1, 10_000e6);
    _grant = bound(_grant, 0, 10_000e6);
    _yield = bound(_yield, 0, 1000e6);
    _installments = uint8(bound(_installments, 1, 24));
    address _v = _useVault ? address(vault) : address(0);

    IMicroloans.LoanTerms memory _t = _terms(_v, _grant);
    _t.principal = _principal;
    vm.prank(bread);
    uint256 _id = loans.create(_t, coop);
    vm.prank(coop);
    loans.accept(_id, TERMS);
    // Yield only accrues while the grant sits in escrow; with no grant nothing stays in the vault.
    if (!_useVault || _grant == 0) _yield = 0;
    if (_yield > 0) vault.simulateYield(_yield);

    uint256 _step = _principal / _installments + 1;
    while (loans.outstanding(_id) > 0) {
      vm.prank(coop);
      loans.repay(_id, _step);
    }
    if (_grant > 0) loans.releaseGrant(_id);
    assertEq(uint256(loans.loanState(_id)), uint256(IMicroloans.LoanState.Completed));
    if (_status(_id).lenderOwed > 0) loans.collect(_id);

    assertEq(usdt.balanceOf(coop), START_BAL + _grant);
    // The lender gets back exactly the principal plus at most the simulated yield (part of it can
    // accrue to the vault's virtual shares when the escrow is tiny).
    uint256 _lenderGain = usdt.balanceOf(bread) + _grant - START_BAL;
    assertLe(_lenderGain, _yield);
    assertEq(usdt.balanceOf(address(loans)), 0);
    assertEq(vault.balanceOf(address(loans)), 0);
  }
}
