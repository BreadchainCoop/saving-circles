// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {EIP712Upgradeable} from '@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {IGoalSavingCircles} from 'interfaces/IGoalSavingCircles.sol';

using SafeERC20 for IERC20;

/**
 * @title Goal Saving Circles
 * @notice Goal-based group savings: members deposit flexible amounts toward a target before a
 *         deadline. Funds are locked while funding (the commitment device). On success the pot
 *         is released to a beneficiary, or — with no beneficiary — each member reclaims exactly
 *         their own contributions. On failure or cancellation everyone is refunded in full.
 * @dev All accounting is exact addition/subtraction of caller-supplied amounts: no division, no
 *      interest, no credit. See docs/goal-saving-circles.md for the design rationale.
 * @author Breadchain Collective
 */
contract GoalSavingCircles is IGoalSavingCircles, ReentrancyGuardUpgradeable, OwnableUpgradeable, EIP712Upgradeable {
  string private constant _EIP712_NAME = 'StacksInvite';
  string private constant _EIP712_VERSION = '1';
  bytes32 private constant _INVITE_TYPEHASH = keccak256('Invite(uint256 id,uint256 nonce)');

  /// @inheritdoc IGoalSavingCircles
  uint256 public nextId;
  mapping(address token => bool status) public allowedTokens;
  mapping(uint256 id => Goal goal) public goals;
  /// @inheritdoc IGoalSavingCircles
  mapping(uint256 id => uint256 amount) public totalDeposited;
  /// @inheritdoc IGoalSavingCircles
  mapping(uint256 id => mapping(address member => uint256 amount)) public contributions;
  /// @inheritdoc IGoalSavingCircles
  mapping(uint256 id => mapping(address member => bool status)) public isMember;
  mapping(uint256 id => address[] members) public goalMembers;
  mapping(address member => uint256[] ids) public memberGoals;
  /// @inheritdoc IGoalSavingCircles
  mapping(uint256 id => mapping(uint256 nonce => bool used)) public usedNonces;
  /// @inheritdoc IGoalSavingCircles
  mapping(uint256 id => bool status) public goalReached;
  /// @inheritdoc IGoalSavingCircles
  mapping(uint256 id => bool status) public cancelled;
  /// @inheritdoc IGoalSavingCircles
  mapping(uint256 id => bool status) public released;

  /// @dev Requires the goal exists
  modifier onlyExisting(uint256 _id) {
    if (!_exists(_id)) revert GoalNotFound();
    _;
  }

  /// @dev Requires the goal is open for deposits and joins: not cancelled, not released, and
  ///      strictly before the deadline. Does NOT check goalReached — overshoot is allowed.
  modifier onlyOpen(uint256 _id) {
    if (cancelled[_id] || released[_id] || block.timestamp >= goals[_id].deadline) revert GoalNotOpen();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IGoalSavingCircles
  function initialize(address _owner) external override initializer {
    __EIP712_init(_EIP712_NAME, _EIP712_VERSION);
    __Ownable_init(_owner);
    __ReentrancyGuard_init();
  }

  /// @inheritdoc IGoalSavingCircles
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    allowedTokens[_token] = _allowed;

    emit TokenAllowed(_token, _allowed);
  }

  /// @inheritdoc IGoalSavingCircles
  function create(
    address _token,
    uint256 _goalAmount,
    uint256 _deadline,
    address _beneficiary
  ) external override returns (uint256 _id) {
    if (!allowedTokens[_token]) revert TokenNotAllowed();
    if (_goalAmount == 0) revert InvalidGoalAmount();
    if (_deadline <= block.timestamp) revert InvalidDeadline();

    _id = nextId++;

    goals[_id] =
      Goal({owner: msg.sender, token: _token, beneficiary: _beneficiary, goalAmount: _goalAmount, deadline: _deadline});
    _addMember(_id, msg.sender);

    emit GoalCreated(_id, msg.sender, _token, _goalAmount, _deadline, _beneficiary);
  }

  /// @inheritdoc IGoalSavingCircles
  function redeemInvite(
    uint256 _id,
    uint256 _nonce,
    bytes calldata _signature
  ) external override nonReentrant onlyExisting(_id) onlyOpen(_id) {
    if (usedNonces[_id][_nonce]) revert InviteAlreadyUsed();
    if (isMember[_id][msg.sender]) revert AlreadyMember();

    bytes32 _digest = _hashInvite(_id, _nonce);
    address _signer = ECDSA.recover(_digest, _signature);
    if (_signer != goals[_id].owner) revert InvalidSigner();

    usedNonces[_id][_nonce] = true;
    _addMember(_id, msg.sender);

    emit InviteRedeemed(_id, msg.sender);
  }

  /// @inheritdoc IGoalSavingCircles
  function deposit(uint256 _id, uint256 _value) external override nonReentrant {
    _deposit(_id, msg.sender, _value);
  }

  /// @inheritdoc IGoalSavingCircles
  function depositFor(uint256 _id, address _member, uint256 _value) external override nonReentrant {
    _deposit(_id, _member, _value);
  }

  /// @inheritdoc IGoalSavingCircles
  function withdraw(uint256 _id) external override nonReentrant {
    GoalState _state = goalState(_id);
    bool _refundable = _state == GoalState.Failed || _state == GoalState.Cancelled
      || (_state == GoalState.Funded && goals[_id].beneficiary == address(0));
    if (!_refundable) revert NotWithdrawable();

    uint256 _amount = contributions[_id][msg.sender];
    if (_amount == 0) revert NothingToWithdraw();

    contributions[_id][msg.sender] = 0;
    totalDeposited[_id] -= _amount;

    IERC20(goals[_id].token).safeTransfer(msg.sender, _amount);

    emit FundsWithdrawn(_id, msg.sender, _amount);
  }

  /// @inheritdoc IGoalSavingCircles
  function release(uint256 _id) external override nonReentrant {
    address _beneficiary = goals[_id].beneficiary;
    if (goalState(_id) != GoalState.Funded || _beneficiary == address(0)) revert NotReleasable();

    released[_id] = true;
    uint256 _amount = totalDeposited[_id];
    totalDeposited[_id] = 0;

    IERC20(goals[_id].token).safeTransfer(_beneficiary, _amount);

    emit GoalReleased(_id, _beneficiary, _amount);
  }

  /// @inheritdoc IGoalSavingCircles
  function cancel(uint256 _id) external override nonReentrant onlyExisting(_id) {
    if (msg.sender != goals[_id].owner) revert NotOwner();
    if (goalState(_id) != GoalState.Funding) revert NotCancellable();

    cancelled[_id] = true;

    emit GoalCancelled(_id);
  }

  /// @inheritdoc IGoalSavingCircles
  function getGoal(uint256 _id) external view override onlyExisting(_id) returns (Goal memory _goal) {
    _goal = goals[_id];
  }

  /// @inheritdoc IGoalSavingCircles
  function getGoalMembers(uint256 _id) external view override returns (address[] memory _members) {
    _members = goalMembers[_id];
  }

  /// @inheritdoc IGoalSavingCircles
  function getMemberGoals(address _member) external view override returns (uint256[] memory _ids) {
    _ids = memberGoals[_member];
  }

  /// @inheritdoc IGoalSavingCircles
  function getMemberContributions(uint256 _id)
    external
    view
    override
    returns (address[] memory _members, uint256[] memory _amounts)
  {
    _members = goalMembers[_id];
    _amounts = new uint256[](_members.length);

    for (uint256 _i = 0; _i < _members.length; _i++) {
      _amounts[_i] = contributions[_id][_members[_i]];
    }
  }

  /// @inheritdoc IGoalSavingCircles
  function isTokenAllowed(address _token) external view override returns (bool _allowed) {
    _allowed = allowedTokens[_token];
  }

  /// @inheritdoc IGoalSavingCircles
  function goalState(uint256 _id) public view override onlyExisting(_id) returns (GoalState _state) {
    if (cancelled[_id]) return GoalState.Cancelled;
    if (released[_id]) return GoalState.Released;
    if (goalReached[_id]) return GoalState.Funded;
    if (block.timestamp >= goals[_id].deadline) return GoalState.Failed;
    return GoalState.Funding;
  }

  /**
   * @dev Credit a deposit to `_member`, pulling the tokens from `msg.sender`. Latches
   *      `goalReached` (and emits {GoalReached} exactly once) when the pot first meets the goal.
   * @param _id The id of the goal.
   * @param _member The member to credit.
   * @param _value The amount to deposit.
   */
  function _deposit(uint256 _id, address _member, uint256 _value) internal onlyExisting(_id) onlyOpen(_id) {
    if (!isMember[_id][_member]) revert NotMember();
    if (_value == 0) revert InvalidDeposit();

    contributions[_id][_member] += _value;
    totalDeposited[_id] += _value;

    if (!goalReached[_id] && totalDeposited[_id] >= goals[_id].goalAmount) {
      goalReached[_id] = true;
      emit GoalReached(_id, totalDeposited[_id]);
    }

    IERC20(goals[_id].token).safeTransferFrom(msg.sender, address(this), _value);

    emit FundsDeposited(_id, _member, _value);
  }

  /**
   * @dev Add `_member` to the goal roster: flag, member list, and reverse index.
   * @param _id The id of the goal.
   * @param _member The member to add.
   */
  function _addMember(uint256 _id, address _member) internal {
    isMember[_id][_member] = true;
    goalMembers[_id].push(_member);
    memberGoals[_member].push(_id);
  }

  /**
   * @dev Return whether a goal exists (goals[id].owner is set at create and never cleared).
   * @param _id The id of the goal.
   * @return _existing Whether the goal exists.
   */
  function _exists(uint256 _id) internal view returns (bool _existing) {
    _existing = goals[_id].owner != address(0);
  }

  /**
   * @dev Computes the EIP-712 hash for an invite
   * @notice _INVITE_TYPEHASH is keccak256('Invite(uint256 id,uint256 nonce)')
   */
  function _hashInvite(uint256 _id, uint256 _nonce) private view returns (bytes32 _digest) {
    bytes32 _structHash = keccak256(abi.encode(_INVITE_TYPEHASH, _id, _nonce));
    _digest = _hashTypedDataV4(_structHash);
  }
}
