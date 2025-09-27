// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';
import {ECDSA} from '@openzeppelin/utils/cryptography/ECDSA.sol';
import {EIP712} from '@openzeppelin/utils/cryptography/EIP712.sol';

import {ISavingCircles} from 'interfaces/ISavingCircles.sol';

/**
 * @title Saving Circles
 * @notice Simple implementation of a rotating savings and credit association (ROSCA) for ERC20 tokens
 * @author Breadchain Collective
 * @author @RonTuretzky
 * @author bagelface.eth
 * @author exo404
 * @author valeriooconte
 */
contract SavingCircles is ISavingCircles, ReentrancyGuard, OwnableUpgradeable, EIP712 {
  using ECDSA for bytes32;

  uint256 public constant MINIMUM_MEMBERS = 2;
  bytes32 private constant _DELEGATION_TYPEHASH =
    keccak256('SetDelegatedDeposits(address member,bool enabled,uint256 nonce,uint256 deadline)');

  uint256 public nextId;
  mapping(uint256 id => Circle circle) public circles;
  mapping(uint256 id => mapping(address token => uint256 balance)) public balances;
  mapping(uint256 id => mapping(address member => bool status)) public isMember;
  mapping(address member => uint256[] ids) public memberCircles;
  mapping(address token => bool status) public allowedTokens;

  // Delegated deposits functionality
  mapping(address member => bool enabled) public delegatedDepositsEnabled;
  mapping(address member => uint256 nonce) public nonces;

  /// @dev Requires circle is commissioned by checking if an owner is set
  modifier onlyCommissioned(uint256 _id) {
    if (_isDecommissioned(circles[_id])) revert NotCommissioned();
    _;
  }

  /// @dev Requires address is a member by checking the mapping
  modifier onlyMember(uint256 _id, address _member) {
    if (!isMember[_id][_member]) revert NotMember();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() EIP712('SavingCircles', '1') {
    _disableInitializers();
  }

  /// @inheritdoc ISavingCircles
  function initialize(address _owner) external override initializer {
    __Ownable_init_unchained(_owner);
  }

  /// @inheritdoc ISavingCircles
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    allowedTokens[_token] = _allowed;

    emit TokenAllowed(_token, _allowed);
  }

  /// @inheritdoc ISavingCircles
  function setDelegatedDepositsEnabled(bool _enabled) external override {
    delegatedDepositsEnabled[msg.sender] = _enabled;
    emit DelegatedDepositsToggled(msg.sender, _enabled);
  }

  /// @inheritdoc ISavingCircles
  function setDelegatedDepositsEnabledWithSig(
    address _member,
    bool _enabled,
    uint256 _nonce,
    uint256 _deadline,
    bytes calldata _signature
  ) external override {
    if (block.timestamp > _deadline) revert SignatureExpired();
    if (_nonce != nonces[_member]) revert InvalidNonce();

    bytes32 structHash = keccak256(abi.encode(_DELEGATION_TYPEHASH, _member, _enabled, _nonce, _deadline));

    bytes32 hash = _hashTypedDataV4(structHash);
    address signer = hash.recover(_signature);

    if (signer != _member) revert InvalidSignature();

    nonces[_member]++;
    delegatedDepositsEnabled[_member] = _enabled;
    emit DelegatedDepositsToggled(_member, _enabled);
  }

  /// @inheritdoc ISavingCircles
  function depositIfAllowed(uint256 _circleId, address _member) external override nonReentrant {
    _depositIfAllowed(_circleId, _member);
  }

  /// @inheritdoc ISavingCircles
  function batchDepositIfAllowed(
    uint256[] calldata _circleIds,
    address[] calldata _members
  ) external override nonReentrant {
    if (_circleIds.length != _members.length) revert ArrayLengthMismatch();

    for (uint256 i = 0; i < _circleIds.length; i++) {
      _depositIfAllowed(_circleIds[i], _members[i]);
    }

    emit BatchDepositCompleted(_circleIds.length);
  }

  /// @inheritdoc ISavingCircles
  function create(Circle memory _circle) external override returns (uint256 _id) {
    _id = nextId++;

    if (circles[_id].owner != address(0)) revert AlreadyExists();
    if (!allowedTokens[_circle.token]) revert TokenNotAllowed();
    if (_circle.depositInterval == 0) revert InvalidDepositInterval();
    if (_circle.depositAmount == 0) revert InvalidDepositAmount();
    if (_circle.maxDeposits == 0) revert InvalidMaxDeposits();
    if (_circle.circleStart == 0) revert InvalidCircleStartTime();
    if (_circle.currentIndex != 0) revert InvalidCurrentIndex();
    if (_circle.owner == address(0)) revert InvalidOwner();
    if (_circle.members.length < MINIMUM_MEMBERS) revert InvalidMemberCount();

    for (uint256 i = 0; i < _circle.members.length; i++) {
      address _member = _circle.members[i];
      if (_member == address(0)) revert InvalidMemberAddress();
      isMember[_id][_member] = true;
      memberCircles[_member].push(_id);
    }

    circles[_id] = _circle;

    emit CircleCreated(_id, _circle.members, _circle.token, _circle.depositAmount, _circle.depositInterval);

    return _id;
  }

  /// @inheritdoc ISavingCircles
  function deposit(uint256 _id, uint256 _value) external override nonReentrant {
    _deposit(_id, _value, msg.sender);
  }

  /// @inheritdoc ISavingCircles
  function depositFor(uint256 _id, uint256 _value, address _member) external override nonReentrant {
    _deposit(_id, _value, _member);
  }

  /// @inheritdoc ISavingCircles
  function withdraw(uint256 _id) external override nonReentrant {
    _withdraw(_id, msg.sender);
  }

  /// @inheritdoc ISavingCircles
  function withdrawFor(uint256 _id, address _member) external override nonReentrant {
    _withdraw(_id, _member);
  }

  /// @inheritdoc ISavingCircles
  function decommission(uint256 _id) external override nonReentrant {
    Circle storage _circle = circles[_id];

    if (block.timestamp <= _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1))) {
      revert NotDecommissionable();
    }

    bool hasIncompleteDeposits = false;
    for (uint256 i = 0; i < _circle.members.length; i++) {
      if (balances[_id][_circle.members[i]] < _circle.depositAmount) {
        hasIncompleteDeposits = true;
        break;
      }
    }
    if (!hasIncompleteDeposits) revert NotDecommissionable();

    // Return deposits to members
    for (uint256 i = 0; i < _circle.members.length; i++) {
      address _member = _circle.members[i];
      uint256 _balance = balances[_id][_member];

      if (_balance > 0) {
        balances[_id][_member] = 0;
        bool success = IERC20(_circle.token).transfer(_member, _balance);
        if (!success) revert TransferFailed();
      }
    }

    delete circles[_id];

    emit CircleDecommissioned(_id);
  }

  /// @inheritdoc ISavingCircles
  function getCircle(uint256 _id) external view override onlyCommissioned(_id) returns (Circle memory _circle) {
    _circle = circles[_id];
  }

  /// @inheritdoc ISavingCircles
  function getCircles(uint256[] calldata _ids) external view returns (Circle[] memory _circles) {
    _circles = new Circle[](_ids.length);

    for (uint256 i = 0; i < _ids.length; i++) {
      _circles[i] = circles[_ids[i]];
    }
  }

  /// @inheritdoc ISavingCircles
  function getMemberCircles(address _member) external view returns (uint256[] memory _ids) {
    return memberCircles[_member];
  }

  /// @inheritdoc ISavingCircles
  function isTokenAllowed(address _token) external view override returns (bool) {
    return allowedTokens[_token];
  }

  /// @inheritdoc ISavingCircles
  function checkMemberships(address _member, uint256[] calldata _ids) external view returns (bool[] memory _statuses) {
    _statuses = new bool[](_ids.length);

    for (uint256 i = 0; i < _ids.length; i++) {
      _statuses[i] = isMember[_ids[i]][_member];
    }

    return _statuses;
  }

  /// @inheritdoc ISavingCircles
  function getMemberBalances(uint256 _id)
    external
    view
    override
    returns (address[] memory _members, uint256[] memory _balances)
  {
    Circle memory _circle = circles[_id];

    if (_isDecommissioned(_circle)) revert NotCommissioned();

    _balances = new uint256[](_circle.members.length);
    for (uint256 i = 0; i < _circle.members.length; i++) {
      _balances[i] = balances[_id][_circle.members[i]];
    }

    return (_circle.members, _balances);
  }

  /// @inheritdoc ISavingCircles
  function isDecommissioned(Circle memory _circle) external view override returns (bool) {
    return _isDecommissioned(_circle);
  }

  /// @inheritdoc ISavingCircles
  function getAddressesForDeposit(uint256 _circleId)
    external
    view
    override
    returns (address[] memory _eligibleMembers)
  {
    Circle memory _circle = circles[_circleId];
    if (_isDecommissioned(_circle)) revert NotCommissioned();

    uint256 depositWindowStart = _circle.circleStart + (_circle.depositInterval * _circle.currentIndex);
    uint256 depositWindowEnd = depositWindowStart + _circle.depositInterval;

    if (block.timestamp < depositWindowStart || block.timestamp >= depositWindowEnd) {
      return new address[](0);
    }

    uint256 eligibleCount = 0;
    for (uint256 i = 0; i < _circle.members.length; i++) {
      address member = _circle.members[i];
      if (
        delegatedDepositsEnabled[member] && balances[_circleId][member] < _circle.depositAmount
          && _hasAllowance(member, _circle.token, _circle.depositAmount - balances[_circleId][member])
      ) {
        eligibleCount++;
      }
    }

    _eligibleMembers = new address[](eligibleCount);
    uint256 index = 0;
    for (uint256 i = 0; i < _circle.members.length; i++) {
      address member = _circle.members[i];
      if (
        delegatedDepositsEnabled[member] && balances[_circleId][member] < _circle.depositAmount
          && _hasAllowance(member, _circle.token, _circle.depositAmount - balances[_circleId][member])
      ) {
        _eligibleMembers[index++] = member;
      }
    }

    return _eligibleMembers;
  }

  /// @inheritdoc ISavingCircles
  function isWithdrawable(uint256 _id) public view override returns (bool) {
    return _withdrawable(_id);
  }

  /// @inheritdoc ISavingCircles
  function withdrawableBy(uint256 _id) public view override onlyCommissioned(_id) returns (address) {
    Circle memory _circle = circles[_id];

    return _circle.members[_circle.currentIndex];
  }

  /**
   * @dev Make a withdrawal from a specified circle
   *      A withdrawal must be made by a member of the circle, even if it is for another member.
   */
  function _withdraw(uint256 _id, address _member) internal onlyMember(_id, msg.sender) {
    Circle storage _circle = circles[_id];

    if (!_withdrawable(_id)) revert NotWithdrawable();
    if (_circle.members[_circle.currentIndex] != _member) revert NotWithdrawable();
    if (_circle.currentIndex >= _circle.maxDeposits) revert NotWithdrawable();

    uint256 _withdrawAmount = _circle.depositAmount * (_circle.members.length);

    for (uint256 i = 0; i < _circle.members.length; i++) {
      balances[_id][_circle.members[i]] = 0;
    }

    _circle.currentIndex = (_circle.currentIndex + 1) % _circle.members.length;
    bool success = IERC20(_circle.token).transfer(_member, _withdrawAmount);
    if (!success) revert TransferFailed();

    emit FundsWithdrawn(_id, _member, _withdrawAmount);
  }

  /**
   * @dev Make a deposit into a specified circle
   *      A deposit must be made in specific time window and can be made partially so long as the final balance equals
   *      the specified deposit amount for the circle.
   */
  function _deposit(
    uint256 _id,
    uint256 _value,
    address _member
  ) internal onlyCommissioned(_id) onlyMember(_id, _member) {
    Circle memory _circle = circles[_id];

    if (block.timestamp < circles[_id].circleStart) {
      revert DepositBeforeCircleStart();
    }
    if (block.timestamp >= circles[_id].circleStart + (circles[_id].depositInterval * (circles[_id].currentIndex + 1)))
    {
      revert DepositWindowClosed();
    }
    if (block.timestamp >= circles[_id].circleStart + (circles[_id].depositInterval * circles[_id].maxDeposits)) {
      revert CircleExpired();
    }
    if (balances[_id][_member] + _value > circles[_id].depositAmount) {
      revert ExceedsDepositAmount();
    }

    balances[_id][_member] = balances[_id][_member] + _value;

    bool success = IERC20(_circle.token).transferFrom(msg.sender, address(this), _value);
    if (!success) revert TransferFailed();

    emit FundsDeposited(_id, _member, _value);
  }

  /**
   * @dev Internal function to handle delegated deposits
   */
  function _depositIfAllowed(uint256 _circleId, address _member) internal {
    if (!delegatedDepositsEnabled[_member]) revert DelegatedDepositsNotEnabled();

    Circle memory _circle = circles[_circleId];
    if (_isDecommissioned(_circle)) revert NotCommissioned();
    if (!isMember[_circleId][_member]) revert NotMember();

    uint256 currentBalance = balances[_circleId][_member];
    if (currentBalance >= _circle.depositAmount) revert AlreadyDeposited();

    uint256 amountToDeposit = _circle.depositAmount - currentBalance;

    if (!_hasAllowance(_member, _circle.token, amountToDeposit)) {
      revert InsufficientAllowance();
    }

    balances[_circleId][_member] = _circle.depositAmount;

    bool success = IERC20(_circle.token).transferFrom(_member, address(this), amountToDeposit);
    if (!success) revert TransferFailed();

    emit FundsDeposited(_circleId, _member, amountToDeposit);
    emit DelegatedDepositMade(_circleId, _member, msg.sender, amountToDeposit);
  }

  /**
   * @dev Return if a specified circle is withdrawable
   *      To be considered withdrawable, enough time must have passed since the deposit interval started
   *      and all members must have made a deposit.
   */
  function _withdrawable(uint256 _id) internal view onlyCommissioned(_id) returns (bool) {
    Circle memory _circle = circles[_id];

    if (block.timestamp < _circle.circleStart + (_circle.depositInterval * _circle.currentIndex)) {
      return false;
    }

    for (uint256 i = 0; i < _circle.members.length; i++) {
      if (balances[_id][_circle.members[i]] < _circle.depositAmount) {
        return false;
      }
    }

    return true;
  }

  /**
   * @dev Check if member has sufficient allowance
   */
  function _hasAllowance(address _member, address _token, uint256 _amount) internal view returns (bool) {
    return IERC20(_token).allowance(_member, address(this)) >= _amount;
  }

  /**
   * @dev Return if a specified circle is decommissioned by checking if an owner is set
   */
  function _isDecommissioned(Circle memory _circle) internal pure returns (bool) {
    return _circle.owner == address(0);
  }
}
