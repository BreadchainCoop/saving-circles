// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';

import {ISavingCircles} from '../interfaces/ISavingCircles.sol';

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
  mapping(address member => bool enabled) public automatedDepositsEnabled;

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
  function setAutomatedDepositsEnabled(bool _enabled) external override {
    automatedDepositsEnabled[msg.sender] = _enabled;
    emit AutomatedDepositsToggled(msg.sender, _enabled);
  }

  /// @inheritdoc ISavingCircles
  function depositIfAllowed(uint256 _id, address _member) external override nonReentrant {
    _depositIfAllowedWithRevert(_id, _member);
  }

  /// @inheritdoc ISavingCircles
  function batchDepositIfAllowed(uint256[] calldata _ids, address[] calldata _members) external override nonReentrant {
    // Validate array lengths match
    if (_ids.length != _members.length) revert ArrayLengthMismatch();

    for (uint256 i = 0; i < _ids.length; i++) {
      // Try to deposit, skip on failure
      _tryDepositIfAllowed(_ids[i], _members[i]);
    }
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
  function checkMemberships(address _member, uint256[] calldata _ids) external view returns (bool[] memory _statuses) {
    _statuses = new bool[](_ids.length);

    for (uint256 i = 0; i < _ids.length; i++) {
      _statuses[i] = isMember[_ids[i]][_member];
    }

    return _statuses;
  }

  /// @inheritdoc ISavingCircles
  function isTokenAllowed(address _token) external view override returns (bool) {
    return allowedTokens[_token];
  }

  /// @inheritdoc ISavingCircles
  function isWithdrawable(uint256 _id) external view override returns (bool) {
    return _withdrawable(_id);
  }

  /// @inheritdoc ISavingCircles
  function withdrawableBy(uint256 _id) external view override onlyCommissioned(_id) returns (address) {
    Circle memory _circle = circles[_id];

    return _circle.members[_circle.currentIndex];
  }

  /// @inheritdoc ISavingCircles
  function isAutomatedDepositsEnabled(address _member) external view override returns (bool) {
    return automatedDepositsEnabled[_member];
  }

  /// @inheritdoc ISavingCircles
  function getEligibleAddressesForDeposit()
    external
    view
    override
    returns (uint256[] memory circleIds, address[] memory members)
  {
    // First, count eligible members across all circles
    uint256 eligibleCount = 0;
    for (uint256 id = 0; id < nextId; id++) {
      Circle memory _circle = circles[id];
      if (_isDecommissioned(_circle)) continue;

      // Check if we're in a valid deposit window
      if (block.timestamp < _circle.circleStart) continue;
      if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1))) continue;
      if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits)) continue;

      for (uint256 j = 0; j < _circle.members.length; j++) {
        address member = _circle.members[j];
        if (!automatedDepositsEnabled[member]) continue; // Skip if not opted in

        uint256 currentBalance = balances[id][member];
        if (currentBalance >= _circle.depositAmount) continue; // Already deposited

        uint256 requiredAmount = _circle.depositAmount - currentBalance;
        uint256 allowance = IERC20(_circle.token).allowance(member, address(this));
        if (allowance >= requiredAmount) {
          eligibleCount++;
        }
      }
    }

    // Allocate arrays
    circleIds = new uint256[](eligibleCount);
    members = new address[](eligibleCount);

    // Fill arrays
    uint256 index = 0;
    for (uint256 id = 0; id < nextId; id++) {
      Circle memory _circle = circles[id];
      if (_isDecommissioned(_circle)) continue;

      // Check if we're in a valid deposit window
      if (block.timestamp < _circle.circleStart) continue;
      if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1))) continue;
      if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits)) continue;

      for (uint256 j = 0; j < _circle.members.length; j++) {
        address member = _circle.members[j];
        if (!automatedDepositsEnabled[member]) continue; // Skip if not opted in

        uint256 currentBalance = balances[id][member];
        if (currentBalance >= _circle.depositAmount) continue; // Already deposited

        uint256 requiredAmount = _circle.depositAmount - currentBalance;
        uint256 allowance = IERC20(_circle.token).allowance(member, address(this));
        if (allowance >= requiredAmount) {
          circleIds[index] = id;
          members[index] = member;
          index++;
        }
      }
    }

    return (circleIds, members);
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
   * @dev Internal function for depositIfAllowed that reverts on errors
   */
  function _depositIfAllowedWithRevert(uint256 _id, address _member) internal {
    (bool success,,) = _performDepositIfAllowed(_id, _member);
    if (!success) {
      // Revert with appropriate error based on the reason
      Circle memory _circle = circles[_id];
      if (_isDecommissioned(_circle)) revert NotCommissioned();
      if (!isMember[_id][_member]) revert NotMember();
      if (!automatedDepositsEnabled[_member]) revert AutomatedDepositsNotEnabled();

      uint256 currentBalance = balances[_id][_member];
      if (currentBalance < _circle.depositAmount) {
        uint256 requiredAmount = _circle.depositAmount - currentBalance;
        uint256 allowance = IERC20(_circle.token).allowance(_member, address(this));
        if (allowance < requiredAmount) revert InsufficientAllowance();

        if (block.timestamp < _circle.circleStart) {
          revert DepositBeforeCircleStart();
        }
        if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1))) {
          revert DepositWindowClosed();
        }
        if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits)) {
          revert CircleExpired();
        }
      }
    }
  }

  /**
   * @dev Internal function that attempts deposit but doesn't revert on failure
   */
  function _tryDepositIfAllowed(uint256 _id, address _member) internal {
    _performDepositIfAllowed(_id, _member);
  }

  /**
   * @dev Core logic for automated deposits, returns success status and details
   * @param _id Circle ID
   * @param _member Member address to deposit for
   * @return success Whether the deposit was successful
   * @return amountDeposited Amount actually deposited (0 if failed or already deposited)
   * @return alreadyDeposited True if member has already made their full deposit
   */
  function _performDepositIfAllowed(
    uint256 _id,
    address _member
  ) internal returns (bool success, uint256 amountDeposited, bool alreadyDeposited) {
    Circle memory _circle = circles[_id];

    // Check basic requirements
    if (_isDecommissioned(_circle)) return (false, 0, false);
    if (!isMember[_id][_member]) return (false, 0, false);
    if (!automatedDepositsEnabled[_member]) return (false, 0, false);

    // Calculate the remaining deposit amount needed
    uint256 currentBalance = balances[_id][_member];
    if (currentBalance >= _circle.depositAmount) return (true, 0, true); // Already deposited
    uint256 requiredAmount = _circle.depositAmount - currentBalance;

    // Check allowance
    uint256 allowance = IERC20(_circle.token).allowance(_member, address(this));
    if (allowance < requiredAmount) return (false, 0, false);

    // Check deposit window validity
    if (block.timestamp < _circle.circleStart) return (false, 0, false);
    if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1))) {
      return (false, 0, false);
    }
    if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits)) {
      return (false, 0, false);
    }

    // Update balance
    balances[_id][_member] = balances[_id][_member] + requiredAmount;

    // Transfer tokens from member to contract
    bool transferSuccess = IERC20(_circle.token).transferFrom(_member, address(this), requiredAmount);
    if (transferSuccess) {
      emit FundsDeposited(_id, _member, requiredAmount);
      return (true, requiredAmount, false);
    } else {
      // Revert balance update if transfer failed
      balances[_id][_member] = balances[_id][_member] - requiredAmount;
      return (false, 0, false);
    }
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
}
