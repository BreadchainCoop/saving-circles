// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';
import {ECDSA} from '@openzeppelin/utils/cryptography/ECDSA.sol';

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
contract SavingCircles is ISavingCircles, ReentrancyGuard, OwnableUpgradeable {
  uint256 public constant MINIMUM_MEMBERS = 2;

  uint256 public nextId;
  mapping(uint256 id => Circle circle) public circles;
  mapping(uint256 id => mapping(address token => uint256 balance)) public balances;
  mapping(uint256 id => mapping(address member => bool status)) public isMember;
  mapping(address member => uint256[] ids) public memberCircles;
  mapping(address token => bool status) public allowedTokens;
  mapping(uint256 id => mapping(uint256 nonce => bool used)) public usedNonces;
  mapping(uint256 id => bool active) public isActive;

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
  constructor() {
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
  function create(Circle memory _circle) external override returns (uint256 _id) {
    _id = nextId++;

    if (circles[_id].owner != address(0)) revert AlreadyExists();
    if (!allowedTokens[_circle.token]) revert TokenNotAllowed();
    if (_circle.depositInterval == 0) revert InvalidDepositInterval();
    if (_circle.depositAmount == 0) revert InvalidDepositAmount();
    if (_circle.currentIndex != 0) revert InvalidCurrentIndex();
    if (_circle.owner == address(0)) revert InvalidOwner();

    circles[_id] = _circle;
    for (uint256 i = 0; i < _circle.members.length; i++) {
      address member = _circle.members[i];
      if (member == address(0)) revert InvalidMemberAddress();
      if (isMember[_id][member]) revert AlreadyMember();

      isMember[_id][member] = true;
      memberCircles[member].push(_id);
    }
    isMember[_id][_circle.owner] = true;
    memberCircles[_circle.owner].push(_id);

    emit CircleCreated(_id, _circle.token, _circle.depositAmount, _circle.depositInterval);

    return _id;
  }

  function start(uint256 _id) external override nonReentrant onlyCommissioned(_id) {
    Circle storage _circle = circles[_id];
    if (isActive[_id]) revert AlreadyActive();
    if (msg.sender != circles[_id].owner) revert NotOwner();
    if (_circle.members.length < MINIMUM_MEMBERS) revert InvalidMemberCount();

    _circle.circleStart = block.timestamp;
    // Prevent overflow in circleEnd = circleStart + (depositInterval * members.length)
    {
      uint256 len = _circle.members.length;
      uint256 maxDelta = type(uint256).max - _circle.circleStart;
      if (_circle.depositInterval > maxDelta / len) revert InvalidDepositInterval();
    }
    _circle.circleEnd = _circle.circleStart + (_circle.depositInterval * _circle.members.length);
    circles[_id] = _circle;
    isActive[_id] = true;
    emit CircleStarted(_id);
  }

  /// @inheritdoc ISavingCircles
  function deposit(uint256 _id, uint256 _value) external override nonReentrant {
    if (!isActive[_id]) revert NotActive();
    _deposit(_id, _value, msg.sender);
  }

  /// @inheritdoc ISavingCircles
  function depositFor(uint256 _id, uint256 _value, address _member) external override nonReentrant {
    if (!isActive[_id]) revert NotActive();
    _deposit(_id, _value, _member);
  }

  /// @inheritdoc ISavingCircles
  function withdraw(uint256 _id) external override nonReentrant {
    if (!isActive[_id]) revert NotActive();
    _withdraw(_id, msg.sender);
  }

  /// @inheritdoc ISavingCircles
  function withdrawFor(uint256 _id, address _member) external override nonReentrant {
    if (!isActive[_id]) revert NotActive();
    _withdraw(_id, _member);
  }

  /// @inheritdoc ISavingCircles
  function decommission(uint256 _id) external override nonReentrant {
    if (!isActive[_id]) revert NotActive();
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
    isMember[_id][msg.sender] = true;
    memberCircles[msg.sender].push(_id);
    _circle.members.push(msg.sender);

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
    if (!isActive[_id]) revert NotActive();

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
  function isWithdrawable(uint256 _id) public view override returns (bool) {
    if (!isActive[_id]) revert NotActive();
    return _withdrawable(_id);
  }

  /// @inheritdoc ISavingCircles
  function withdrawableBy(uint256 _id) public view override onlyCommissioned(_id) returns (address) {
    if (!isActive[_id]) revert NotActive();
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
    if (_circle.currentIndex >= _circle.members.length) revert NotWithdrawable();

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
    // Check if the entire circle has expired (all rounds completed)
    if (block.timestamp >= _circle.circleEnd) {
      revert CircleExpired();
    }
    // Check if current deposit window is closed
    if (block.timestamp >= circles[_id].circleStart + (circles[_id].depositInterval * (circles[_id].currentIndex + 1)))
    {
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
   * @dev Return if a specified circle is decommissioned by checking if an owner is set
   */
  function _isDecommissioned(Circle memory _circle) internal pure returns (bool) {
    return _circle.owner == address(0);
  }

  /**
   * @dev Computes the EIP-712 hash for an invite
   * @notice _inviteTypehash is keccak256('Invite(uint256 id,uint256 nonce)')
   * @notice _eip712DomainTypehash is keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
   * @notice Domain name is 'StacksInvite' and version is '1'
   */
  function _hashInvite(uint256 _id, uint256 _nonce) private view returns (bytes32) {
    bytes32 _inviteTypehash = 0xd86e498a74dbfe863d870d4811dddab9c7f3922d6c0d6656504984bd9a8607a3;
    bytes32 _structHash = keccak256(abi.encode(_inviteTypehash, _id, _nonce));
    bytes32 _eip712DomainTypehash = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 _inviteDomainNameHash = 0xf50d3e48fa87e894899f86eba14c57c836bc6ffddd68251a158269ffdadc0cb1;
    bytes32 _inviteDomainVersionHash = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    bytes32 _domainSeparator = keccak256(
      abi.encode(_eip712DomainTypehash, _inviteDomainNameHash, _inviteDomainVersionHash, block.chainid, address(this))
    );

    return keccak256(abi.encodePacked('\x19\x01', _domainSeparator, _structHash));
  }
}
