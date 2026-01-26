// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {EIP712Upgradeable} from '@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

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
contract SavingCircles is ISavingCircles, ReentrancyGuardUpgradeable, OwnableUpgradeable, EIP712Upgradeable {
  uint256 public constant MINIMUM_MEMBERS = 2;
  string private constant _EIP712_NAME = 'StacksInvite';
  string private constant _EIP712_VERSION = '1';
  bytes32 private constant _INVITE_TYPEHASH = keccak256('Invite(uint256 id,uint256 nonce)');

  uint256 public nextId;
  mapping(uint256 id => Circle circle) public circles;
  mapping(uint256 id => mapping(address token => uint256 balance)) public balances;
  mapping(uint256 id => mapping(address member => bool status)) public isMember;
  mapping(address member => uint256[] ids) public memberCircles;
  mapping(address token => bool status) public allowedTokens;
  mapping(uint256 id => mapping(uint256 nonce => bool used)) public usedNonces;
  mapping(uint256 id => bool active) public isActive;
  mapping(uint256 id => address[] members) public circleMembers;

  /// @dev Requires circle is commissioned by checking if an owner is set
  modifier onlyCommissioned(uint256 _id) {
    if (_isDecommissioned(circles[_id])) revert NotCommissioned();
    _;
  }

  /// @dev Requires circle is active by checking the mapping
  modifier onlyActive(uint256 _id) {
    if (!isActive[_id]) revert NotActive();
    _;
  }

  /// @dev Requires address is a member by checking the mapping
  modifier onlyMember(uint256 _id, address _member) {
    if (!isMember[_id][_member]) revert NotMember();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc ISavingCircles
  function initialize(address _owner) external override initializer {
    __EIP712_init(_EIP712_NAME, _EIP712_VERSION);
    __Ownable_init(_owner);
    __ReentrancyGuard_init();
  }

  /// @inheritdoc ISavingCircles
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    allowedTokens[_token] = _allowed;

    emit TokenAllowed(_token, _allowed);
  }

  /// @inheritdoc ISavingCircles
  function create(Circle calldata _circle) external override returns (uint256 _id) {
    _id = nextId++;

    if (circles[_id].owner != address(0)) revert AlreadyExists();
    if (!allowedTokens[_circle.token]) revert TokenNotAllowed();
    if (_circle.depositInterval == 0) revert InvalidDepositInterval();
    if (_circle.depositAmount == 0) revert InvalidDepositAmount();
    if (_circle.currentIndex != 0) revert InvalidCurrentIndex();
    if (_circle.owner == address(0)) revert InvalidOwner();
    if (_circle.effectiveCircleStartTime != 0) revert InvalidCircleStartTime();

    address owner = _circle.owner;
    isMember[_id][owner] = true;
    memberCircles[owner].push(_id);
    circleMembers[_id].push(owner);

    circles[_id] = _circle;
    emit CircleCreated(_id, _circle.token, _circle.depositAmount, _circle.depositInterval);

    return _id;
  }

  /// @inheritdoc ISavingCircles
  function start(uint256 _id) external override nonReentrant onlyCommissioned(_id) {
    Circle storage _circle = circles[_id];
    if (isActive[_id]) revert AlreadyActive();
    if (msg.sender != _circle.owner) revert NotOwner();

    if (circleMembers[_id].length < MINIMUM_MEMBERS) revert InvalidMemberCount();

    _circle.effectiveCircleStartTime = block.timestamp;

    uint256 len = circleMembers[_id].length;
    uint256 maxDelta = type(uint256).max - _circle.effectiveCircleStartTime;
    if (_circle.depositInterval > maxDelta / len) revert InvalidDepositInterval();
    _circle.circleEnd = _circle.effectiveCircleStartTime + (_circle.depositInterval * len);

    isActive[_id] = true;
    emit CircleStarted(_id);
  }

  /// @inheritdoc ISavingCircles
  function deposit(uint256 _id, uint256 _value) external override nonReentrant onlyActive(_id) {
    _deposit(_id, _value, msg.sender);
  }

  /// @inheritdoc ISavingCircles
  function depositFor(uint256 _id, uint256 _value, address _member) external override nonReentrant onlyActive(_id) {
    _deposit(_id, _value, _member);
  }

  /// @inheritdoc ISavingCircles
  function withdraw(uint256 _id) external override nonReentrant onlyMember(_id, msg.sender) onlyActive(_id) {
    _withdraw(_id, msg.sender);
  }

  /// @inheritdoc ISavingCircles
  function withdrawFor(uint256 _id, address _member) external override nonReentrant onlyActive(_id) {
    _withdraw(_id, _member);
  }

  /// @inheritdoc ISavingCircles
  function decommission(uint256 _id) external override nonReentrant onlyActive(_id) {
    if (!_isDecommissionable(_id)) revert NotDecommissionable();

    address token = circles[_id].token;
    address[] memory members = circleMembers[_id];
    isActive[_id] = false;

    // Return deposits to members
    for (uint256 i = 0; i < members.length; i++) {
      address _member = members[i];
      uint256 _balance = balances[_id][_member];

      if (_balance > 0) {
        balances[_id][_member] = 0;
        bool success = IERC20(token).transfer(_member, _balance);
        if (!success) revert TransferFailed();
      }
    }

    delete circles[_id];
    emit CircleDecommissioned(_id);
  }

  /// @inheritdoc ISavingCircles
  function redeemInvite(uint256 _id, uint256 _nonce, bytes calldata _signature) external override nonReentrant {
    Circle storage _circle = circles[_id];

    if (_circle.owner == address(0)) revert NotCommissioned();
    if (usedNonces[_id][_nonce]) revert InviteAlreadyUsed();
    if (isMember[_id][msg.sender]) revert AlreadyMember();
    if (isActive[_id]) revert AlreadyActive();

    bytes32 _digest = _hashInvite(_id, _nonce);
    address _signer = ECDSA.recover(_digest, _signature);

    if (_signer != _circle.owner) revert InvalidSigner();

    usedNonces[_id][_nonce] = true;

    // No max count validation, the owner issues a finite amount of invites
    isMember[_id][msg.sender] = true;
    memberCircles[msg.sender].push(_id);
    circleMembers[_id].push(msg.sender);

    emit InviteRedeemed(_id, msg.sender);
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

    _balances = new uint256[](circleMembers[_id].length);
    for (uint256 i = 0; i < circleMembers[_id].length; i++) {
      _balances[i] = balances[_id][circleMembers[_id][i]];
    }

    return (circleMembers[_id], _balances);
  }

  /// @inheritdoc ISavingCircles
  function getCircleMembers(uint256 _id) external view override returns (address[] memory members) {
    return circleMembers[_id];
  }

  function isDecommissionable(uint256 _id) external view override returns (bool) {
    return _isDecommissionable(_id);
  }

  /// @inheritdoc ISavingCircles
  function isDecommissioned(Circle calldata _circle) external pure override returns (bool) {
    return _isDecommissioned(_circle);
  }

  /// @inheritdoc ISavingCircles
  function isWithdrawable(uint256 _id) public view override returns (bool) {
    if (!isActive[_id]) return false;
    return _withdrawable(_id);
  }

  /// @inheritdoc ISavingCircles
  function withdrawableBy(uint256 _id) public view override onlyCommissioned(_id) returns (address) {
    if (!isActive[_id]) return address(0);
    Circle memory _circle = circles[_id];

    return circleMembers[_id][_circle.currentIndex];
  }

  /**
   * @dev Make a withdrawal from a specified circle
   *      Permissionless: anyone can trigger the payout for the member whose turn it is to withdraw
   *      A withdrawal must be made by a member of the circle, even if it is for another member.
   */
  function _withdraw(uint256 _id, address _member) internal onlyMember(_id, msg.sender) {
    Circle storage _circle = circles[_id];

    if (!_withdrawable(_id)) revert NotWithdrawable();
    if (circleMembers[_id][_circle.currentIndex] != _member) revert NotWithdrawable();
    if (_circle.currentIndex >= circleMembers[_id].length) revert NotWithdrawable();

    uint256 _withdrawAmount = _circle.depositAmount * (circleMembers[_id].length);

    for (uint256 i = 0; i < circleMembers[_id].length; i++) {
      balances[_id][circleMembers[_id][i]] = 0;
    }

    _circle.currentIndex = (_circle.currentIndex + 1) % circleMembers[_id].length;
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

    if (block.timestamp < circles[_id].effectiveCircleStartTime) {
      revert DepositBeforeCircleStart();
    }
    // Check if the entire circle has expired (all rounds completed)
    if (block.timestamp >= _circle.circleEnd) {
      revert CircleExpired();
    }
    // Check if current deposit window is closed
    if (
      block.timestamp
        >= circles[_id].effectiveCircleStartTime + (circles[_id].depositInterval * (circles[_id].currentIndex + 1))
    ) {
      revert DepositWindowClosed();
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
   * @dev Return if a specified circle is withdrawable
   *      To be considered withdrawable, enough time must have passed since the deposit interval started
   *      and all members must have made a deposit.
   */
  function _withdrawable(uint256 _id) internal view onlyCommissioned(_id) returns (bool) {
    Circle memory _circle = circles[_id];

    if (block.timestamp < _circle.effectiveCircleStartTime + (_circle.depositInterval * _circle.currentIndex)) {
      return false;
    }
    address[] memory members = circleMembers[_id];
    for (uint256 i = 0; i < members.length; i++) {
      if (balances[_id][members[i]] < _circle.depositAmount) {
        return false;
      }
    }

    return true;
  }

  /**
   * @dev Return if a specified circle is decommissioned by checking if an owner is set
   */
  function _isDecommissioned(Circle memory _circle) internal pure returns (bool) {
    return _circle.owner == address(0);
  }

  /**
   * @dev Return if a specified circle is decommissionable
   *      To be considered decommissionable, the circle must have passed its deposit window
   *      and all members must have made their deposits for the current round.
   */
  function _isDecommissionable(uint256 _id) internal view returns (bool) {
    Circle memory _circle = circles[_id];
    bool decommissionable = true;

    if (block.timestamp <= _circle.effectiveCircleStartTime + (_circle.depositInterval * (_circle.currentIndex + 1))) {
      decommissionable = false;
    }

    bool hasIncompleteDeposits = false;
    address[] memory members = circleMembers[_id];
    for (uint256 i = 0; i < members.length; i++) {
      if (balances[_id][members[i]] < _circle.depositAmount) {
        hasIncompleteDeposits = true;
        break;
      }
    }
    if (!hasIncompleteDeposits) decommissionable = false;

    return decommissionable;
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
