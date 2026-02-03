// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {EIP712Upgradeable} from '@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {ISavingCircles} from 'interfaces/ISavingCircles.sol';

using SafeERC20 for IERC20;

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
  mapping(uint256 id => mapping(address member => bool claimed)) public hasClaimed;
  mapping(uint256 id => mapping(address member => uint256 round)) private _lastDepositRound;
  mapping(uint256 id => mapping(uint256 round => mapping(address member => uint256 amount))) public roundDeposits;
  mapping(uint256 id => mapping(address member => uint256 indexPlusOne)) private _memberIndexPlusOne;

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
    _memberIndexPlusOne[_id][owner] = circleMembers[_id].length;

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
    uint256 len = members.length;

    isActive[_id] = false;

    // Refund all deposits in rounds whose payout hasn't happened yet (recipient not claimed)
    for (uint256 r = 0; r < len; r++) {
      address recipient = members[r];
      if (hasClaimed[_id][recipient]) continue; // round already paid out

      for (uint256 i = 0; i < len; i++) {
        address member = members[i];
        uint256 amount = roundDeposits[_id][r][member];
        if (amount == 0) continue;

        roundDeposits[_id][r][member] = 0;

        IERC20(token).safeTransfer(member, amount);
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
    _memberIndexPlusOne[_id][msg.sender] = circleMembers[_id].length;

    emit InviteRedeemed(_id, msg.sender);
  }

  /// @inheritdoc ISavingCircles
  function getCircle(uint256 _id) external view override onlyCommissioned(_id) returns (Circle memory _circle) {
    _circle = circles[_id];
    _circle.currentIndex = _currentRoundIndex(_circle);
  }

  /// @inheritdoc ISavingCircles
  function getCircles(uint256[] calldata _ids) external view returns (Circle[] memory _circles) {
    _circles = new Circle[](_ids.length);

    for (uint256 i = 0; i < _ids.length; i++) {
      _circles[i] = circles[_ids[i]];
      _circles[i].currentIndex = _currentRoundIndex(_circles[i]);
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

    uint256 currentRound = _currentRoundIndex(_circle);
    _balances = new uint256[](circleMembers[_id].length);
    for (uint256 i = 0; i < circleMembers[_id].length; i++) {
      address member = circleMembers[_id][i];
      if (_lastDepositRound[_id][member] == currentRound) {
        _balances[i] = balances[_id][member];
      } else {
        _balances[i] = 0;
      }
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
    Circle memory _circle = circles[_id];
    uint256 currentRound = _currentRoundIndex(_circle);
    if (currentRound >= circleMembers[_id].length) return false;
    address member = circleMembers[_id][currentRound];
    return _claimable(_id, member);
  }

  /// @inheritdoc ISavingCircles
  function withdrawableBy(uint256 _id) public view override onlyCommissioned(_id) returns (address) {
    if (!isActive[_id]) return address(0);
    Circle memory _circle = circles[_id];

    uint256 currentRound = _currentRoundIndex(_circle);
    if (currentRound >= circleMembers[_id].length) return address(0);
    return circleMembers[_id][currentRound];
  }

  /**
   * @dev Make a withdrawal from a specified circle
   *      Permissionless: anyone can trigger the payout for the member whose turn it is to withdraw
   *      A withdrawal must be made by a member of the circle, even if it is for another member.
   */
  function _withdraw(uint256 _id, address _member) internal onlyMember(_id, msg.sender) {
    Circle storage _circle = circles[_id];

    if (!_claimable(_id, _member)) revert NotWithdrawable();

    uint256 _withdrawAmount = _circle.depositAmount * (circleMembers[_id].length);

    hasClaimed[_id][_member] = true;

    IERC20(_circle.token).safeTransfer(_member, _withdrawAmount);

    emit FundsWithdrawn(_id, _member, _withdrawAmount);

    if (_allMembersClaimed(_id)) {
      isActive[_id] = false;
    }
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
    uint256 currentRound = _currentRoundIndex(_circle);
    if (currentRound >= circleMembers[_id].length) {
      revert CircleExpired();
    }

    if (currentRound > 0) {
      uint256 prev = currentRound - 1;
      if (
        block.timestamp >= _roundEndTime(_circle, prev)
          && !_allMembersDepositedForRound(_id, prev, _circle.depositAmount)
      ) {
        revert CircleStuck();
      }
    }

    uint256 depositedSoFar = roundDeposits[_id][currentRound][_member];
    if (depositedSoFar + _value > _circle.depositAmount) revert ExceedsDepositAmount();

    uint256 newTotal = depositedSoFar + _value;
    roundDeposits[_id][currentRound][_member] = newTotal;

    _lastDepositRound[_id][_member] = currentRound;
    balances[_id][_member] = newTotal;

    IERC20(_circle.token).safeTransferFrom(msg.sender, address(this), _value);

    emit FundsDeposited(_id, _member, _value);
  }

  /**
   * @dev Return if a specified member can claim from a circle
   *      Claim eligibility is determined by the time-based round index.
   */
  function _claimable(uint256 _id, address _member) internal view onlyCommissioned(_id) returns (bool) {
    Circle memory _circle = circles[_id];
    if (hasClaimed[_id][_member]) return false;
    if (_isDecommissionable(_id)) return false;

    uint256 currentRound = _currentRoundIndex(_circle);
    (uint256 memberIndex, bool found) = _memberIndex(_id, _member);
    if (!found || currentRound < memberIndex) return false;

    return _allMembersDepositedForRound(_id, memberIndex, _circle.depositAmount);
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
   *      and some members must have incomplete deposits for the current round.
   */
  function _isDecommissionable(uint256 _id) internal view returns (bool) {
    Circle memory _circle = circles[_id];
    uint256 len = circleMembers[_id].length;
    if (len == 0) return false;

    uint256 currentRound = _currentRoundIndex(_circle);

    if (currentRound == 0) return false;

    uint256 checkRound = currentRound - 1;

    if (checkRound >= len) checkRound = len - 1;
    if (block.timestamp < _roundEndTime(_circle, checkRound)) return false;
    return !_allMembersDepositedForRound(_id, checkRound, _circle.depositAmount);
  }

  function _roundEndTime(Circle memory _circle, uint256 round) internal pure returns (uint256) {
    return _circle.effectiveCircleStartTime + (_circle.depositInterval * (round + 1));
  }
  function _currentRoundIndex(Circle memory _circle) internal view returns (uint256) {
    if (
      _circle.depositInterval == 0 || _circle.effectiveCircleStartTime == 0
        || block.timestamp < _circle.effectiveCircleStartTime
    ) {
      return 0;
    }

    return (block.timestamp - _circle.effectiveCircleStartTime) / _circle.depositInterval;
  }

  function _allMembersDepositedForRound(
    uint256 _id,
    uint256 _round,
    uint256 _depositAmount
  ) internal view returns (bool) {
    address[] memory members = circleMembers[_id];
    for (uint256 i = 0; i < members.length; i++) {
      address member = members[i];
      if (roundDeposits[_id][_round][member] < _depositAmount) {
        return false;
      }
    }
    return true;
  }

  function _memberIndex(uint256 _id, address _member) internal view returns (uint256, bool found) {
    uint256 indexPlusOne = _memberIndexPlusOne[_id][_member];
    if (indexPlusOne == 0) return (0, false);
    return (indexPlusOne - 1, true);
  }

  function _allMembersClaimed(uint256 _id) internal view returns (bool) {
    address[] memory members = circleMembers[_id];
    for (uint256 i = 0; i < members.length; i++) {
      if (!hasClaimed[_id][members[i]]) {
        return false;
      }
    }
    return true;
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
