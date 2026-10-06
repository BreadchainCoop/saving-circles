// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IMicroloans} from 'interfaces/IMicroloans.sol';

using SafeERC20 for IERC20;

/**
 * @title Microloans
 * @notice Step-up microloans: a lender funds a zero-interest loan plus an optional grant, the named
 *         borrower accepts the exact terms and receives the loan, and the grant unlocks once the
 *         loan is repaid in full. Escrowed funds can earn yield in an allowlisted ERC-4626 vault;
 *         all yield belongs to the lender. See docs/microloans.md for the design rationale.
 * @author Breadchain Collective
 */
contract Microloans is IMicroloans, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  /// @inheritdoc IMicroloans
  uint256 public nextId;

  mapping(address token => bool status) internal _allowedTokens;
  mapping(address vault => bool status) internal _allowedVaults;
  mapping(uint256 id => LoanTerms terms) internal _terms;
  mapping(uint256 id => LoanStatus status) internal _status;
  mapping(address lender => uint256[] ids) internal _lenderLoans;
  mapping(address borrower => uint256[] ids) internal _borrowerLoans;

  /// @dev Requires the loan exists
  modifier onlyExisting(uint256 _id) {
    if (_id >= nextId) revert LoanNotFound();
    _;
  }

  /// @dev Requires the caller is the lender of the loan
  modifier onlyLender(uint256 _id) {
    if (_id >= nextId) revert LoanNotFound();
    if (msg.sender != _status[_id].lender) revert NotLender();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IMicroloans
  function initialize(address _owner) external override initializer {
    __Ownable_init(_owner);
    __ReentrancyGuard_init();
  }

  // =======================
  // ADMIN
  // =======================

  /// @inheritdoc IMicroloans
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    _allowedTokens[_token] = _allowed;
    emit TokenAllowed(_token, _allowed);
  }

  /// @inheritdoc IMicroloans
  function setVaultAllowed(address _vault, bool _allowed) external override onlyOwner {
    _allowedVaults[_vault] = _allowed;
    emit VaultAllowed(_vault, _allowed);
  }

  // =======================
  // LENDER
  // =======================

  /// @inheritdoc IMicroloans
  function create(
    LoanTerms calldata _loanTerms,
    address _borrower
  ) external override nonReentrant returns (uint256 _id) {
    if (!_allowedTokens[_loanTerms.token]) revert TokenNotAllowed();
    if (
      _loanTerms.vault != address(0)
        && (!_allowedVaults[_loanTerms.vault] || IERC4626(_loanTerms.vault).asset() != _loanTerms.token)
    ) revert InvalidVault();
    if (_loanTerms.principal == 0) revert InvalidPrincipal();
    if (_loanTerms.acceptBy <= block.timestamp) revert InvalidAcceptBy();
    if (_loanTerms.repaymentPeriod == 0) revert InvalidRepaymentPeriod();
    if (_borrower == msg.sender) revert InvalidBorrower();

    _id = nextId++;
    _terms[_id] = _loanTerms;
    _status[_id].lender = msg.sender;
    _lenderLoans[msg.sender].push(_id);
    if (_borrower != address(0)) {
      _status[_id].borrower = _borrower;
      _borrowerLoans[_borrower].push(_id);
    }

    uint256 _total = _loanTerms.principal + _loanTerms.grant;
    IERC20(_loanTerms.token).safeTransferFrom(msg.sender, address(this), _total);
    _escrow(_id, _total);

    emit LoanCreated(_id, msg.sender, _borrower, _loanTerms);
  }

  /// @inheritdoc IMicroloans
  function setBorrower(uint256 _id, address _borrower) external override onlyLender(_id) {
    if (_state(_id) != LoanState.Offered) revert InvalidState();
    if (_status[_id].borrower != address(0)) revert BorrowerAlreadySet();
    if (_borrower == address(0) || _borrower == msg.sender) revert InvalidBorrower();

    _status[_id].borrower = _borrower;
    _borrowerLoans[_borrower].push(_id);

    emit BorrowerSet(_id, _borrower);
  }

  /// @inheritdoc IMicroloans
  function cancel(uint256 _id) external override nonReentrant onlyLender(_id) {
    LoanState _s = _state(_id);
    if (_s != LoanState.Offered && _s != LoanState.Expired) revert InvalidState();

    _status[_id].cancelled = true;
    uint256 _refunded = _releaseAll(_id, msg.sender);

    emit LoanCancelled(_id, _refunded);
  }

  /// @inheritdoc IMicroloans
  function reclaimGrant(uint256 _id) external override nonReentrant onlyLender(_id) {
    if (_state(_id) != LoanState.Overdue || _terms[_id].grant == 0) revert InvalidState();

    _status[_id].grantReclaimed = true;
    uint256 _amount = _releaseAll(_id, msg.sender);

    emit GrantReclaimed(_id, _amount);
  }

  /// @inheritdoc IMicroloans
  function extendRepayBy(uint256 _id, uint256 _newRepayBy) external override onlyLender(_id) {
    LoanState _s = _state(_id);
    if (_s != LoanState.Active && _s != LoanState.Overdue) revert InvalidState();
    if (_newRepayBy <= _status[_id].repayBy) revert InvalidRepaymentPeriod();

    _status[_id].repayBy = _newRepayBy;

    emit RepayByExtended(_id, _newRepayBy);
  }

  /// @inheritdoc IMicroloans
  function collect(uint256 _id) external override nonReentrant onlyExisting(_id) {
    LoanStatus storage _st = _status[_id];
    uint256 _amount = _st.lenderOwed;
    if (_amount == 0) revert NothingToCollect();

    _st.lenderOwed = 0;
    IERC20(_terms[_id].token).safeTransfer(_st.lender, _amount);

    emit LenderCollected(_id, _st.lender, _amount);
  }

  // =======================
  // BORROWER
  // =======================

  /// @inheritdoc IMicroloans
  function accept(uint256 _id, bytes32 _termsHash) external override nonReentrant onlyExisting(_id) {
    LoanStatus storage _st = _status[_id];
    LoanTerms storage _t = _terms[_id];
    if (msg.sender != _st.borrower) revert NotBorrower();
    if (_state(_id) != LoanState.Offered) revert InvalidState();
    if (_termsHash != _t.termsHash) revert TermsMismatch();

    _st.acceptedAt = block.timestamp;
    _st.repayBy = block.timestamp + _t.repaymentPeriod;

    uint256 _disbursed = _release(_id, _t.principal, msg.sender);
    _st.disbursed = _disbursed;

    // Nothing left to escrow: credit any yield earned while the offer was open to the lender.
    if (_t.grant == 0) _creditRemainingToLender(_id);

    emit LoanAccepted(_id, msg.sender, _disbursed, _st.repayBy);
  }

  /// @inheritdoc IMicroloans
  function repay(uint256 _id, uint256 _amount) external override nonReentrant onlyExisting(_id) {
    if (_amount == 0) revert InvalidAmount();
    LoanStatus storage _st = _status[_id];
    if (_st.acceptedAt == 0 || _st.repaid >= _st.disbursed) revert InvalidState();

    uint256 _owed = _st.disbursed - _st.repaid;
    uint256 _applied = _amount < _owed ? _amount : _owed;
    _st.repaid += _applied;
    _st.lenderOwed += _applied;

    IERC20(_terms[_id].token).safeTransferFrom(msg.sender, address(this), _applied);

    emit Repaid(_id, msg.sender, _applied, _st.repaid);
  }

  /// @inheritdoc IMicroloans
  function releaseGrant(uint256 _id) external override nonReentrant onlyExisting(_id) {
    if (_state(_id) != LoanState.Repaid) revert InvalidState();

    LoanStatus storage _st = _status[_id];
    _st.grantPaid = true;
    uint256 _paid = _release(_id, _terms[_id].grant, _st.borrower);
    _creditRemainingToLender(_id);

    emit GrantReleased(_id, _st.borrower, _paid);
  }

  // =======================
  // VIEWS
  // =======================

  /// @inheritdoc IMicroloans
  function getLoan(uint256 _id)
    external
    view
    override
    onlyExisting(_id)
    returns (LoanTerms memory _loanTerms, LoanStatus memory _loanStatus)
  {
    _loanTerms = _terms[_id];
    _loanStatus = _status[_id];
  }

  /// @inheritdoc IMicroloans
  function loanState(uint256 _id) external view override onlyExisting(_id) returns (LoanState _s) {
    _s = _state(_id);
  }

  /// @inheritdoc IMicroloans
  function outstanding(uint256 _id) external view override onlyExisting(_id) returns (uint256 _amount) {
    _amount = _status[_id].disbursed - _status[_id].repaid;
  }

  /// @inheritdoc IMicroloans
  function escrowValue(uint256 _id) external view override onlyExisting(_id) returns (uint256 _amount) {
    address _vault = _terms[_id].vault;
    uint256 _held = _status[_id].held;
    _amount = _vault == address(0) ? _held : IERC4626(_vault).convertToAssets(_held);
  }

  /// @inheritdoc IMicroloans
  function getLenderLoans(address _lender) external view override returns (uint256[] memory _ids) {
    _ids = _lenderLoans[_lender];
  }

  /// @inheritdoc IMicroloans
  function getBorrowerLoans(address _borrower) external view override returns (uint256[] memory _ids) {
    _ids = _borrowerLoans[_borrower];
  }

  /// @inheritdoc IMicroloans
  function isTokenAllowed(address _token) external view override returns (bool _allowed) {
    _allowed = _allowedTokens[_token];
  }

  /// @inheritdoc IMicroloans
  function isVaultAllowed(address _vault) external view override returns (bool _allowed) {
    _allowed = _allowedVaults[_vault];
  }

  // =======================
  // INTERNAL
  // =======================

  /// @dev Put tokens already held by this contract into the loan's escrow (vault or plain balance).
  function _escrow(uint256 _id, uint256 _amount) internal {
    address _vault = _terms[_id].vault;
    if (_vault == address(0)) {
      _status[_id].held += _amount;
      return;
    }
    IERC20(_terms[_id].token).forceApprove(_vault, _amount);
    _status[_id].held += IERC4626(_vault).deposit(_amount, address(this));
  }

  /**
   * @dev Pay up to `_amount` tokens out of the loan's escrow to `_to`. If the vault cannot cover
   *      the full amount (it lost value), everything left in escrow is paid instead.
   * @return _paid The tokens actually paid.
   */
  function _release(uint256 _id, uint256 _amount, address _to) internal returns (uint256 _paid) {
    LoanStatus storage _st = _status[_id];
    address _vault = _terms[_id].vault;
    if (_vault == address(0)) {
      _paid = _amount <= _st.held ? _amount : _st.held;
      _st.held -= _paid;
      IERC20(_terms[_id].token).safeTransfer(_to, _paid);
      return _paid;
    }
    if (IERC4626(_vault).previewWithdraw(_amount) <= _st.held) {
      _st.held -= IERC4626(_vault).withdraw(_amount, _to, address(this));
      _paid = _amount;
    } else {
      uint256 _shares = _st.held;
      _st.held = 0;
      _paid = IERC4626(_vault).redeem(_shares, _to, address(this));
    }
  }

  /// @dev Pay the loan's entire escrow, including yield, to `_to`.
  function _releaseAll(uint256 _id, address _to) internal returns (uint256 _paid) {
    LoanStatus storage _st = _status[_id];
    uint256 _held = _st.held;
    _st.held = 0;
    address _vault = _terms[_id].vault;
    if (_vault == address(0)) {
      if (_held > 0 && _to != address(this)) IERC20(_terms[_id].token).safeTransfer(_to, _held);
      return _held;
    }
    if (_held > 0) _paid = IERC4626(_vault).redeem(_held, _to, address(this));
  }

  /// @dev Convert whatever is left in escrow (yield and rounding dust) into a lender credit.
  function _creditRemainingToLender(uint256 _id) internal {
    uint256 _amount = _releaseAll(_id, address(this));
    if (_amount == 0) return;
    _status[_id].lenderOwed += _amount;
    emit YieldCredited(_id, _amount);
  }

  /**
   * @dev Derive the lifecycle state. Order matters: cancellation and pre-acceptance first, then the
   *      grant outcome, then repayment, then the deadline.
   */
  function _state(uint256 _id) internal view returns (LoanState _s) {
    LoanStatus storage _st = _status[_id];
    if (_st.cancelled) return LoanState.Cancelled;
    if (_st.acceptedAt == 0) {
      return block.timestamp < _terms[_id].acceptBy ? LoanState.Offered : LoanState.Expired;
    }
    if (_st.grantReclaimed) return LoanState.Defaulted;
    if (_st.repaid >= _st.disbursed) {
      return (_st.grantPaid || _terms[_id].grant == 0) ? LoanState.Completed : LoanState.Repaid;
    }
    return block.timestamp < _st.repayBy ? LoanState.Active : LoanState.Overdue;
  }
}
