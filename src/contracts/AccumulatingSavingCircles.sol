// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {EIP712Upgradeable} from '@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {IAccumulatingSavingCircles} from 'interfaces/IAccumulatingSavingCircles.sol';

using SafeERC20 for IERC20;

/**
 * @title Accumulating Saving Circles
 * @notice An Accumulating Savings and Credit Association (ASCA) registry: members deposit flexible
 *         amounts into a shared pool, earn a credit line proportional to their own savings, borrow
 *         against it, and repay within a fixed number of periods with optional simple interest that
 *         streams pro-rata to savers via a MasterChef-style per-share accumulator.
 * @dev Safety rests on full self-collateralization: `borrowLimitBps <= 10_000` implies
 *      `principal <= savings` for every open loan, preserved by the withdraw collateral guard
 *      (which counts accrued interest as debt) and cleared by permissionless {liquidate} at the
 *      due date, so a defaulter can only ever burn their own savings, never another member's
 *      principal. All accounting uses the internal `poolCash` ledger, never `token.balanceOf`,
 *      so donations and multi-fund interactions cannot corrupt state. Interest accrues lazily per
 *      whole elapsed period, capped at `repaymentPeriods` periods, so a borrower's liability is
 *      bounded at borrow time and the liquidation seizure is deterministic.
 * @author Breadchain Collective
 * @author @RonTuretzky
 */
contract AccumulatingSavingCircles is
  IAccumulatingSavingCircles,
  ReentrancyGuardUpgradeable,
  OwnableUpgradeable,
  EIP712Upgradeable
{
  /// @notice Basis-point denominator.
  uint256 public constant MAX_BPS = 10_000;
  /// @notice Sanity cap on a fund's repayment periods; bounds interest and due-date math.
  uint256 public constant MAX_REPAYMENT_PERIODS = 1000;
  /// @notice Sanity cap on a fund's period length; bounds due-date math.
  uint256 public constant MAX_PERIOD_LENGTH = 365 days;
  /// @dev Accumulator scaling factor.
  uint256 internal constant _ACC_PRECISION = 1e18;
  string private constant _EIP712_NAME = 'StacksInvite';
  string private constant _EIP712_VERSION = '1';
  bytes32 private constant _INVITE_TYPEHASH = keccak256('Invite(uint256 id,uint256 nonce)');

  /// @notice Next fund id to be assigned (funds are keyed 0..nextId-1).
  uint256 public nextId;

  /// @notice Admin token allowlist (checked at create only).
  mapping(address token => bool allowed) public allowedTokens;

  /// @dev Fund configuration + lifecycle flag. fund.owner == address(0) <=> fund does not exist.
  mapping(uint256 id => Fund fund) internal _funds;

  /// @dev Ordered member roster (append-only; members are never removed).
  mapping(uint256 id => address[] members) internal _members;

  /// @notice Membership flag.
  mapping(uint256 id => mapping(address member => bool status)) public isMember;

  /// @dev Reverse index: every fund an address has ever joined (append-only).
  mapping(address member => uint256[] ids) internal _memberFunds;

  /// @notice Spent EIP-712 invite nonces, per fund.
  mapping(uint256 id => mapping(uint256 nonce => bool used)) public usedNonces;

  /// @notice Member's savings principal in the fund (the collateral base and the accumulator shares).
  mapping(uint256 id => mapping(address member => uint256 amount)) public savings;

  /// @dev MasterChef reward debt: savings[id][m] * accInterestPerShare[id] / 1e18 at last checkpoint.
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _rewardDebt;

  /// @notice Interest already settled to the member (claimable via claimInterest), not yet transferred.
  mapping(uint256 id => mapping(address member => uint256 amount)) public interestCredit;

  /// @dev Member's open loan. principal == 0 <=> no loan (all other fields are then stale/zero).
  mapping(uint256 id => mapping(address member => Loan loan)) internal _loans;

  /// @notice Sum of all members' savings (the accumulator share supply).
  mapping(uint256 id => uint256 amount) public totalSavings;

  /// @notice Sum of all outstanding loan principal.
  mapping(uint256 id => uint256 amount) public totalBorrowed;

  /// @notice Fund's internal cash ledger: tokens received minus tokens sent for this fund.
  ///         Never read token.balanceOf for logic (donation-proof, multi-fund-safe).
  mapping(uint256 id => uint256 amount) public poolCash;

  /// @notice Cumulative distributed interest per savings share, scaled by 1e18. Monotone non-decreasing.
  mapping(uint256 id => uint256 acc) public accInterestPerShare;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function initialize(address _owner) external override initializer {
    __EIP712_init(_EIP712_NAME, _EIP712_VERSION);
    __Ownable_init(_owner);
    __ReentrancyGuard_init();
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    allowedTokens[_token] = _allowed;

    emit TokenAllowed(_token, _allowed);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function create(
    address _token,
    uint256 _borrowLimitBps,
    uint256 _interestRateBps,
    uint256 _repaymentPeriods,
    uint256 _periodLength
  ) external override returns (uint256 _id) {
    if (!allowedTokens[_token]) revert TokenNotAllowed();
    if (_borrowLimitBps > MAX_BPS || _interestRateBps > MAX_BPS) revert InvalidParameters();
    if (_repaymentPeriods == 0 || _repaymentPeriods > MAX_REPAYMENT_PERIODS) revert InvalidParameters();
    if (_periodLength == 0 || _periodLength > MAX_PERIOD_LENGTH) revert InvalidParameters();

    _id = nextId++;

    _funds[_id] = Fund({
      owner: msg.sender,
      token: _token,
      borrowLimitBps: _borrowLimitBps,
      interestRateBps: _interestRateBps,
      repaymentPeriods: _repaymentPeriods,
      periodLength: _periodLength,
      deactivated: false
    });

    isMember[_id][msg.sender] = true;
    _members[_id].push(msg.sender);
    _memberFunds[msg.sender].push(_id);

    emit FundCreated(_id, msg.sender, _token, _borrowLimitBps, _interestRateBps, _repaymentPeriods, _periodLength);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function redeemInvite(uint256 _id, uint256 _nonce, bytes calldata _signature) external override nonReentrant {
    Fund storage _fund = _existingFund(_id);
    if (_fund.deactivated) revert FundNotActive();
    if (usedNonces[_id][_nonce]) revert InviteAlreadyUsed();
    if (isMember[_id][msg.sender]) revert AlreadyMember();

    address _signer = ECDSA.recover(_hashInvite(_id, _nonce), _signature);
    if (_signer != _fund.owner) revert InvalidSigner();

    usedNonces[_id][_nonce] = true;
    isMember[_id][msg.sender] = true;
    _members[_id].push(msg.sender);
    _memberFunds[msg.sender].push(_id);

    emit InviteRedeemed(_id, msg.sender);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function deactivate(uint256 _id) external override {
    Fund storage _fund = _existingFund(_id);
    if (msg.sender != _fund.owner) revert NotFundOwner();
    if (_fund.deactivated) revert FundNotActive();

    _fund.deactivated = true;

    emit FundDeactivated(_id);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function deposit(uint256 _id, uint256 _amount) external override nonReentrant {
    _deposit(_id, msg.sender, _amount);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function depositFor(uint256 _id, address _member, uint256 _amount) external override nonReentrant {
    _deposit(_id, _member, _amount);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function withdraw(uint256 _id, uint256 _amount) external override nonReentrant {
    Fund storage _fund = _existingFund(_id);
    if (_amount == 0) revert ZeroAmount();
    if (!isMember[_id][msg.sender]) revert NotMember();

    uint256 _memberSavings = savings[_id][msg.sender];
    if (_amount > _memberSavings) revert InsufficientSavings();

    Loan storage _loan = _loans[_id][msg.sender];
    if (_loan.principal != 0) {
      _accrue(_id, msg.sender);
      uint256 _debt = _loan.principal + _loan.interestOwed;
      if (_debt * MAX_BPS > _fund.borrowLimitBps * (_memberSavings - _amount)) revert InsufficientCollateral();
    }
    if (poolCash[_id] < _amount) revert InsufficientLiquidity();

    _settle(_id, msg.sender);
    savings[_id][msg.sender] = _memberSavings - _amount;
    totalSavings[_id] -= _amount;
    poolCash[_id] -= _amount;
    _checkpoint(_id, msg.sender);

    IERC20(_fund.token).safeTransfer(msg.sender, _amount);

    emit SavingsWithdrawn(_id, msg.sender, _amount);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function claimInterest(uint256 _id) external override nonReentrant {
    Fund storage _fund = _existingFund(_id);

    uint256 _amount = _pendingInterestOf(_id, msg.sender);
    if (_amount == 0) revert NothingToClaim();
    if (poolCash[_id] < _amount) revert InsufficientLiquidity();

    interestCredit[_id][msg.sender] = 0;
    _checkpoint(_id, msg.sender);
    poolCash[_id] -= _amount;

    IERC20(_fund.token).safeTransfer(msg.sender, _amount);

    emit InterestClaimed(_id, msg.sender, _amount);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function borrow(uint256 _id, uint256 _amount) external override nonReentrant {
    Fund storage _fund = _existingFund(_id);
    if (_fund.deactivated) revert FundNotActive();
    if (_amount == 0) revert ZeroAmount();
    if (!isMember[_id][msg.sender]) revert NotMember();

    Loan storage _loan = _loans[_id][msg.sender];
    if (_loan.principal != 0) revert OutstandingLoan();
    if (_amount * MAX_BPS > _fund.borrowLimitBps * savings[_id][msg.sender]) revert ExceedsCreditLine();
    if (poolCash[_id] < _amount) revert InsufficientLiquidity();

    _loan.principal = _amount;
    _loan.interestOwed = 0;
    _loan.periodsAccrued = 0;
    _loan.startTime = block.timestamp;

    totalBorrowed[_id] += _amount;
    poolCash[_id] -= _amount;

    uint256 _dueDate = block.timestamp + _fund.repaymentPeriods * _fund.periodLength;

    IERC20(_fund.token).safeTransfer(msg.sender, _amount);

    emit Borrowed(_id, msg.sender, _amount, _dueDate);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function repay(uint256 _id, uint256 _amount) external override nonReentrant {
    Fund storage _fund = _existingFund(_id);
    if (_amount == 0) revert ZeroAmount();

    Loan storage _loan = _loans[_id][msg.sender];
    if (_loan.principal == 0) revert NoActiveLoan();

    _accrue(_id, msg.sender);

    uint256 _totalDebt = _loan.interestOwed + _loan.principal;
    uint256 _pay = _amount < _totalDebt ? _amount : _totalDebt;
    uint256 _interestPart = _pay < _loan.interestOwed ? _pay : _loan.interestOwed;
    uint256 _principalPart = _pay - _interestPart;

    _loan.interestOwed -= _interestPart;
    _loan.principal -= _principalPart;
    totalBorrowed[_id] -= _principalPart;
    poolCash[_id] += _pay;

    // Interest is retired before principal, so a fully repaid loan owes nothing and can be deleted.
    if (_loan.principal == 0) delete _loans[_id][msg.sender];

    _distributeInterest(_id, _interestPart);

    IERC20(_fund.token).safeTransferFrom(msg.sender, address(this), _pay);

    emit Repaid(_id, msg.sender, _interestPart, _principalPart);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function liquidate(uint256 _id, address _member) external override nonReentrant {
    Fund storage _fund = _existingFund(_id);

    Loan storage _loan = _loans[_id][_member];
    if (_loan.principal == 0) revert NoActiveLoan();
    if (block.timestamp < _loan.startTime + _fund.repaymentPeriods * _fund.periodLength) revert NotLiquidatable();

    _accrue(_id, _member); // capped at repaymentPeriods => frozen at the due date
    _settle(_id, _member); // bank the member's own pending interest first

    uint256 _seizedPrincipal = _loan.principal; // savings >= principal guaranteed (invariant I2)
    uint256 _remaining = savings[_id][_member] - _seizedPrincipal;
    uint256 _seizedInterest = _loan.interestOwed < _remaining ? _loan.interestOwed : _remaining;
    // If seizing interest would leave no savings shares in the fund, there is nobody to
    // distribute it to; leave it as the defaulter's savings instead of burning it.
    if (totalSavings[_id] - _seizedPrincipal - _seizedInterest == 0) _seizedInterest = 0;

    savings[_id][_member] -= _seizedPrincipal + _seizedInterest;
    totalSavings[_id] -= _seizedPrincipal + _seizedInterest;
    totalBorrowed[_id] -= _seizedPrincipal;
    _checkpoint(_id, _member);
    delete _loans[_id][_member];

    _distributeInterest(_id, _seizedInterest);

    emit Liquidated(_id, _member, _seizedPrincipal, _seizedInterest);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function isTokenAllowed(address _token) external view override returns (bool _allowed) {
    return allowedTokens[_token];
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function getFund(uint256 _id) external view override returns (Fund memory _fund) {
    return _existingFund(_id);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function getFundMembers(uint256 _id) external view override returns (address[] memory _fundMembers) {
    return _members[_id];
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function getMemberFunds(address _member) external view override returns (uint256[] memory _ids) {
    return _memberFunds[_member];
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function getFundBalances(uint256 _id)
    external
    view
    override
    returns (uint256 totalSavings_, uint256 totalBorrowed_, uint256 poolCash_)
  {
    return (totalSavings[_id], totalBorrowed[_id], poolCash[_id]);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function getLoan(uint256 _id, address _member) external view override returns (Loan memory _loan, uint256 _dueDate) {
    _loan = _loans[_id][_member];
    if (_loan.principal == 0) return (_loan, 0);

    Fund storage _fund = _funds[_id];
    uint256 _elapsed = (block.timestamp - _loan.startTime) / _fund.periodLength;
    uint256 _periods = _elapsed < _fund.repaymentPeriods ? _elapsed : _fund.repaymentPeriods;
    _loan.interestOwed += _loan.principal * _fund.interestRateBps * (_periods - _loan.periodsAccrued) / MAX_BPS;
    _loan.periodsAccrued = _periods;
    _dueDate = _loan.startTime + _fund.repaymentPeriods * _fund.periodLength;
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function creditLineOf(uint256 _id, address _member) external view override returns (uint256 _amount) {
    return _funds[_id].borrowLimitBps * savings[_id][_member] / MAX_BPS;
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function maxBorrowableOf(uint256 _id, address _member) external view override returns (uint256 _amount) {
    Fund storage _fund = _funds[_id];
    if (_fund.deactivated || _loans[_id][_member].principal != 0) return 0;

    uint256 _creditLine = _fund.borrowLimitBps * savings[_id][_member] / MAX_BPS;
    uint256 _cash = poolCash[_id];
    return _creditLine < _cash ? _creditLine : _cash;
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function pendingInterestOf(uint256 _id, address _member) external view override returns (uint256 _amount) {
    return _pendingInterestOf(_id, _member);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function withdrawableOf(uint256 _id, address _member) external view override returns (uint256 _amount) {
    return savings[_id][_member] + _pendingInterestOf(_id, _member);
  }

  /// @inheritdoc IAccumulatingSavingCircles
  function isLiquidatable(uint256 _id, address _member) external view override returns (bool _liquidatable) {
    Loan storage _loan = _loans[_id][_member];
    if (_loan.principal == 0) return false;

    Fund storage _fund = _funds[_id];
    return block.timestamp >= _loan.startTime + _fund.repaymentPeriods * _fund.periodLength;
  }

  /**
   * @dev Deposit `_amount` of savings for `_member`, funded by msg.sender. Settles the member's
   *      pending interest before the share balance changes so past distributions are not diluted.
   * @param _id The fund id.
   * @param _member The member to credit.
   * @param _amount The amount to deposit.
   */
  function _deposit(uint256 _id, address _member, uint256 _amount) internal {
    Fund storage _fund = _existingFund(_id);
    if (_fund.deactivated) revert FundNotActive();
    if (_amount == 0) revert ZeroAmount();
    if (!isMember[_id][_member]) revert NotMember();

    _settle(_id, _member);
    savings[_id][_member] += _amount;
    totalSavings[_id] += _amount;
    poolCash[_id] += _amount;
    _checkpoint(_id, _member);

    IERC20(_fund.token).safeTransferFrom(msg.sender, address(this), _amount);

    emit SavingsDeposited(_id, _member, _amount);
  }

  /**
   * @dev Lazily checkpoint a loan's simple interest: accrue `principal * rateBps / MAX_BPS` per
   *      whole elapsed period (floor), capped at `repaymentPeriods` periods so accrual stops at
   *      the due date. Zero whole periods elapsed means zero interest.
   * @param _id The fund id.
   * @param _member The borrower.
   */
  function _accrue(uint256 _id, address _member) internal {
    Loan storage _loan = _loans[_id][_member];
    Fund storage _fund = _funds[_id];

    uint256 _elapsed = (block.timestamp - _loan.startTime) / _fund.periodLength;
    uint256 _periods = _elapsed < _fund.repaymentPeriods ? _elapsed : _fund.repaymentPeriods;
    if (_periods > _loan.periodsAccrued) {
      _loan.interestOwed += _loan.principal * _fund.interestRateBps * (_periods - _loan.periodsAccrued) / MAX_BPS;
      _loan.periodsAccrued = _periods;
    }
  }

  /**
   * @dev Bank a member's unsettled accumulator share into `interestCredit`. MUST be called before
   *      any change to `savings[_id][_member]`; the caller MUST call {_checkpoint} afterwards.
   * @param _id The fund id.
   * @param _member The member.
   */
  function _settle(uint256 _id, address _member) internal {
    uint256 _pending = savings[_id][_member] * accInterestPerShare[_id] / _ACC_PRECISION - _rewardDebt[_id][_member];
    if (_pending != 0) interestCredit[_id][_member] += _pending;
  }

  /**
   * @dev Re-anchor a member's reward debt to their current savings and the current accumulator.
   * @param _id The fund id.
   * @param _member The member.
   */
  function _checkpoint(uint256 _id, address _member) internal {
    _rewardDebt[_id][_member] = savings[_id][_member] * accInterestPerShare[_id] / _ACC_PRECISION;
  }

  /**
   * @dev Distribute `_amount` of realized interest pro-rata to savers by bumping the accumulator.
   *      Floor rounding leaves sub-wei-per-share dust in `poolCash` as an untracked surplus, so
   *      assets >= liabilities is preserved. Callers guarantee `totalSavings[_id] > 0` when
   *      `_amount > 0`.
   * @param _id The fund id.
   * @param _amount The interest amount to distribute.
   */
  function _distributeInterest(uint256 _id, uint256 _amount) internal {
    if (_amount == 0) return;
    accInterestPerShare[_id] += _amount * _ACC_PRECISION / totalSavings[_id];

    emit InterestDistributed(_id, _amount);
  }

  /**
   * @dev A member's unclaimed interest: settled credit plus the unsettled accumulator share.
   * @param _id The fund id.
   * @param _member The member.
   * @return _amount The unclaimed interest.
   */
  function _pendingInterestOf(uint256 _id, address _member) internal view returns (uint256 _amount) {
    return interestCredit[_id][_member] + savings[_id][_member] * accInterestPerShare[_id] / _ACC_PRECISION
      - _rewardDebt[_id][_member];
  }

  /**
   * @dev Fetch a fund, reverting with FundNotFound if it does not exist.
   * @param _id The fund id.
   * @return _fund The fund storage pointer.
   */
  function _existingFund(uint256 _id) internal view returns (Fund storage _fund) {
    _fund = _funds[_id];
    if (_fund.owner == address(0)) revert FundNotFound();
  }

  /**
   * @dev Computes the EIP-712 hash for an invite
   * @notice _INVITE_TYPEHASH is keccak256('Invite(uint256 id,uint256 nonce)')
   */
  function _hashInvite(uint256 _id, uint256 _nonce) private view returns (bytes32) {
    bytes32 _structHash = keccak256(abi.encode(_INVITE_TYPEHASH, _id, _nonce));
    return _hashTypedDataV4(_structHash);
  }
}
