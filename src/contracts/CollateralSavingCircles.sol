// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {ICollateralSavingCircles} from 'interfaces/ICollateralSavingCircles.sol';

using SafeERC20 for IERC20;

/**
 * @title Collateral Saving Circles
 * @notice A permissionless, collateralized rotating savings and credit association (ROSCA).
 * @dev See {ICollateralSavingCircles} and docs/collateralized-permissionless-circles.md for the
 *      formal model. In one line: members prepay a whole pot of collateral by completing a
 *      first "collateral cycle" without withdrawing, which fully secures the second "payout
 *      cycle" against defaults and thereby lets membership be opened permissionlessly.
 * @author Breadchain Collective
 */
contract CollateralSavingCircles is ICollateralSavingCircles, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  uint256 public constant MINIMUM_SLOTS = 2;

  uint256 internal _nextId;

  mapping(address token => bool allowed) internal _allowedTokens;
  mapping(uint256 id => Circle circle) internal _circles;
  mapping(uint256 id => address[] members) internal _members;
  mapping(uint256 id => mapping(address member => bool isMember)) internal _isMember;
  mapping(uint256 id => mapping(address member => uint256 slot)) internal _memberSlot;
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _collateral;
  // Latched true once a member's collateral reaches the requirement during cycle 0; stays true
  // afterwards even as the live `_collateral` balance is slashed to cover payout-cycle defaults.
  mapping(uint256 id => mapping(address member => bool complete)) internal _collateralComplete;
  mapping(uint256 id => mapping(uint256 round => mapping(address member => uint256 amount))) internal _roundDeposit;
  mapping(uint256 id => mapping(uint256 round => uint256 amount)) internal _roundPot;
  mapping(uint256 id => mapping(uint256 round => bool claimed)) internal _claimed;
  mapping(uint256 id => bool aborted) internal _aborted;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc ICollateralSavingCircles
  function initialize(address owner) external override initializer {
    __Ownable_init(owner);
    __ReentrancyGuard_init();
  }

  /// @inheritdoc ICollateralSavingCircles
  function setTokenAllowed(address token, bool allowed) external override onlyOwner {
    _allowedTokens[token] = allowed;
    emit TokenAllowed(token, allowed);
  }

  /// @inheritdoc ICollateralSavingCircles
  function createCircle(
    address token,
    uint256 depositAmount,
    uint256 roundDuration,
    uint256 numSlots
  ) external override returns (uint256 id) {
    if (!_allowedTokens[token]) revert TokenNotAllowed();
    if (depositAmount == 0 || roundDuration == 0 || numSlots < MINIMUM_SLOTS) revert InvalidParameters();

    id = _nextId++;
    _circles[id] = Circle({
      token: token, depositAmount: depositAmount, roundDuration: roundDuration, numSlots: numSlots, startTime: 0
    });

    emit CircleCreated(id, token, depositAmount, roundDuration, numSlots);
  }

  /// @inheritdoc ICollateralSavingCircles
  function join(uint256 id) external override {
    Circle storage circle = _existing(id);
    if (circle.startTime != 0) revert CircleNotOpen();
    if (_members[id].length >= circle.numSlots) revert CircleNotOpen();
    if (_isMember[id][msg.sender]) revert AlreadyMember();

    uint256 slot = _members[id].length;
    _members[id].push(msg.sender);
    _isMember[id][msg.sender] = true;
    _memberSlot[id][msg.sender] = slot;

    emit MemberJoined(id, msg.sender, slot);
  }

  /// @inheritdoc ICollateralSavingCircles
  function start(uint256 id) external override {
    Circle storage circle = _existing(id);
    if (circle.startTime != 0) revert WrongState();
    if (_members[id].length != circle.numSlots) revert CircleNotFull();

    circle.startTime = block.timestamp;
    emit CircleStarted(id, block.timestamp);
  }

  /// @inheritdoc ICollateralSavingCircles
  function deposit(uint256 id, uint256 value) external override nonReentrant {
    _deposit(id, msg.sender, value);
  }

  /// @inheritdoc ICollateralSavingCircles
  function depositFor(uint256 id, address member, uint256 value) external override nonReentrant {
    _deposit(id, member, value);
  }

  /// @inheritdoc ICollateralSavingCircles
  function withdraw(uint256 id) external override nonReentrant {
    _withdraw(id, msg.sender);
  }

  /// @inheritdoc ICollateralSavingCircles
  function withdrawFor(uint256 id, address member) external override nonReentrant {
    _withdraw(id, member);
  }

  /// @inheritdoc ICollateralSavingCircles
  function reclaimCollateral(uint256 id) external override nonReentrant {
    Circle storage circle = _existing(id);
    if (_aborted[id]) revert WrongState();
    if (_round(circle) < 2 * circle.numSlots) revert WrongState();
    if (!_isFullyCollateralized(id)) revert WrongState();
    if (!_isMember[id][msg.sender]) revert NotMember();

    uint256 amount = _collateral[id][msg.sender];
    if (amount == 0) revert NothingToReclaim();

    _collateral[id][msg.sender] = 0;
    IERC20(circle.token).safeTransfer(msg.sender, amount);

    emit CollateralReclaimed(id, msg.sender, amount);
  }

  /// @inheritdoc ICollateralSavingCircles
  function abort(uint256 id) external override nonReentrant {
    Circle storage circle = _existing(id);
    if (_aborted[id]) revert WrongState();
    // Only abortable once the collateral cycle has fully elapsed and it came up short.
    if (circle.startTime == 0 || _round(circle) < circle.numSlots) revert NotAbortable();
    if (_isFullyCollateralized(id)) revert NotAbortable();

    _aborted[id] = true;

    // No payout-cycle funds can exist (payout deposits require full collateralization), so
    // refunding each member's accrued collateral returns every token the contract holds for
    // this circle.
    address[] memory members = _members[id];
    address token = circle.token;
    for (uint256 i = 0; i < members.length; i++) {
      uint256 amount = _collateral[id][members[i]];
      if (amount == 0) continue;
      _collateral[id][members[i]] = 0;
      IERC20(token).safeTransfer(members[i], amount);
    }

    emit CircleAborted(id);
  }

  // =======================
  // VIEWS
  // =======================

  /// @inheritdoc ICollateralSavingCircles
  function isTokenAllowed(address token) external view override returns (bool) {
    return _allowedTokens[token];
  }

  /// @inheritdoc ICollateralSavingCircles
  function nextId() external view override returns (uint256) {
    return _nextId;
  }

  /// @inheritdoc ICollateralSavingCircles
  function getCircle(uint256 id) external view override returns (Circle memory) {
    return _existingView(id);
  }

  /// @inheritdoc ICollateralSavingCircles
  function getMembers(uint256 id) external view override returns (address[] memory) {
    _existingView(id);
    return _members[id];
  }

  /// @inheritdoc ICollateralSavingCircles
  function circleState(uint256 id) external view override returns (CircleState) {
    Circle memory circle = _existingView(id);
    if (_aborted[id]) return CircleState.Aborted;
    if (circle.startTime == 0) return CircleState.Open;

    uint256 round = _round(circle);
    if (round < circle.numSlots) return CircleState.CollateralCycle;
    if (round < 2 * circle.numSlots) return CircleState.PayoutCycle;
    return CircleState.Ended;
  }

  /// @inheritdoc ICollateralSavingCircles
  function currentRound(uint256 id) external view override returns (uint256) {
    return _round(_existingView(id));
  }

  /// @inheritdoc ICollateralSavingCircles
  function collateralRequirement(uint256 id) external view override returns (uint256) {
    Circle memory circle = _existingView(id);
    return circle.numSlots * circle.depositAmount;
  }

  /// @inheritdoc ICollateralSavingCircles
  function collateralOf(uint256 id, address member) external view override returns (uint256) {
    return _collateral[id][member];
  }

  /// @inheritdoc ICollateralSavingCircles
  function isFullyCollateralized(uint256 id) external view override returns (bool) {
    _existingView(id);
    return _isFullyCollateralized(id);
  }

  /// @inheritdoc ICollateralSavingCircles
  function recipientOf(uint256 id, uint256 round) external view override returns (address) {
    Circle memory circle = _existingView(id);
    if (_members[id].length != circle.numSlots) return address(0);
    return _members[id][round % circle.numSlots];
  }

  /// @inheritdoc ICollateralSavingCircles
  function withdrawableAmount(uint256 id, address member) external view override returns (uint256) {
    Circle memory circle = _existingView(id);
    if (_aborted[id] || !_isMember[id][member] || !_isFullyCollateralized(id)) return 0;

    uint256 payoutRound = circle.numSlots + _memberSlot[id][member];
    if (_round(circle) <= payoutRound || _claimed[id][payoutRound]) return 0;
    return circle.numSlots * circle.depositAmount;
  }

  // =======================
  // INTERNAL
  // =======================

  function _deposit(uint256 id, address member, uint256 value) internal {
    Circle storage circle = _existing(id);
    if (circle.startTime == 0 || _aborted[id]) revert WrongState();
    if (!_isMember[id][member]) revert NotMember();
    if (value == 0) revert InvalidParameters();

    uint256 round = _round(circle);
    if (round >= 2 * circle.numSlots) revert WrongState(); // circle ended

    uint256 newTotal = _roundDeposit[id][round][member] + value;
    if (newTotal > circle.depositAmount) revert ExceedsDepositAmount();
    _roundDeposit[id][round][member] = newTotal;

    if (round < circle.numSlots) {
      // Collateral cycle: deposits accrue to the member's locked collateral.
      uint256 balance = _collateral[id][member] + value;
      _collateral[id][member] = balance;
      if (balance >= circle.numSlots * circle.depositAmount) {
        _collateralComplete[id][member] = true;
      }
      emit CollateralDeposited(id, member, value);
    } else {
      // Payout cycle: only permitted once the whole circle is collateralized, so that every
      // possible default in this cycle is fully backed.
      if (!_isFullyCollateralized(id)) revert NotFullyCollateralized();
      _roundPot[id][round] += value;
      emit FundsDeposited(id, member, round, value);
    }

    IERC20(circle.token).safeTransferFrom(msg.sender, address(this), value);
  }

  function _withdraw(uint256 id, address member) internal {
    Circle storage circle = _existing(id);
    if (_aborted[id]) revert WrongState();
    if (!_isMember[id][member]) revert NotMember();
    if (!_isFullyCollateralized(id)) revert NotWithdrawable();

    uint256 n = circle.numSlots;
    uint256 m = circle.depositAmount;
    uint256 payoutRound = n + _memberSlot[id][member];

    // Claimable only once the round's deposit window has fully elapsed, so that any
    // non-depositor is unambiguously delinquent and can be covered from collateral.
    if (_round(circle) <= payoutRound) revert NotWithdrawable();
    if (_claimed[id][payoutRound]) revert NotWithdrawable();

    _claimed[id][payoutRound] = true;

    uint256 pot = _roundPot[id][payoutRound];
    _roundPot[id][payoutRound] = 0;

    // Cover any shortfall by slashing the missing amount from each delinquent member's own
    // collateral. The total slashed against any member across the payout cycle is at most its
    // n deposit obligations = n*m = its collateral, so this can never underflow.
    address[] memory members = _members[id];
    for (uint256 i = 0; i < members.length; i++) {
      address x = members[i];
      uint256 deposited = _roundDeposit[id][payoutRound][x];
      if (deposited < m) {
        uint256 missing = m - deposited;
        _collateral[id][x] -= missing;
        pot += missing;
        emit CollateralSlashed(id, x, payoutRound, missing);
      }
    }

    // pot now equals n*m exactly.
    IERC20(circle.token).safeTransfer(member, pot);
    emit FundsWithdrawn(id, member, payoutRound, pot);
  }

  /// @dev True once every member has completed its full collateral commitment during cycle 0.
  ///      Uses the latched `_collateralComplete` flag rather than the live balance, so it stays
  ///      true while collateral is drawn down to cover defaults in the payout cycle.
  function _isFullyCollateralized(uint256 id) internal view returns (bool) {
    address[] memory members = _members[id];
    if (members.length != _circles[id].numSlots) return false;
    for (uint256 i = 0; i < members.length; i++) {
      if (!_collateralComplete[id][members[i]]) return false;
    }
    return true;
  }

  function _round(Circle memory circle) internal view returns (uint256) {
    if (circle.startTime == 0 || block.timestamp < circle.startTime) return 0;
    return (block.timestamp - circle.startTime) / circle.roundDuration;
  }

  function _existing(uint256 id) internal view returns (Circle storage circle) {
    circle = _circles[id];
    if (circle.token == address(0)) revert CircleNotFound();
  }

  function _existingView(uint256 id) internal view returns (Circle memory circle) {
    circle = _circles[id];
    if (circle.token == address(0)) revert CircleNotFound();
  }
}
