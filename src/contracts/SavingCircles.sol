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
    public
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
  function isWithdrawable(uint256 _id) public view override returns (bool) {
    return _withdrawable(_id);
  }

  /// @inheritdoc ISavingCircles
  function withdrawableBy(uint256 _id) public view override onlyCommissioned(_id) returns (address) {
    Circle memory _circle = circles[_id];

    return _circle.members[_circle.currentIndex];
  }

  /// @inheritdoc ISavingCircles
  function getTotalBalance(address _member) public view override returns (uint256 _totalBalance) {
    uint256[] storage _ids = memberCircles[_member];

    for (uint256 i = 0; i < _ids.length; i++) {
      _totalBalance += balances[_ids[i]][_member];
    }

    return _totalBalance;
  }

  struct UserCircleData {
    uint256 circleId;
    Circle circleInfo;
    uint256 userBalance;
    bool isMember;
    bool isOwner;
    bool isCurrentWithdrawer;
    bool canWithdraw;
    uint256 nextWithdrawTime;
    uint256 depositWindowEnd;
    bool isExpired;
    bool isDecommissioned;
    uint256 totalPoolBalance;
    uint256 remainingDepositsNeeded;
    uint256 completedRounds;
    uint256 totalRounds;
  }

  struct UserFinancialSummary {
    uint256 totalBalance;
    uint256 totalDeposited;
    uint256 totalWithdrawn;
    uint256 activeCirclesCount;
    uint256 ownedCirclesCount;
    uint256 completedCirclesCount;
    uint256 pendingWithdrawals;
    uint256 upcomingDeposits;
  }

  struct UserMembershipStatus {
    uint256[] allCircleIds;
    uint256[] activeCircleIds;
    uint256[] ownedCircleIds;
    uint256[] withdrawableCircleIds;
    uint256[] expiredCircleIds;
    uint256[] decommissionedCircleIds;
  }

  struct ComprehensiveUserData {
    address userAddress;
    UserFinancialSummary financialSummary;
    UserMembershipStatus membershipStatus;
    UserCircleData[] circleData;
    uint256 timestamp;
    uint256 blockNumber;
  }

  function getComprehensiveUserData(address _user) external view returns (ComprehensiveUserData memory userData) {
    userData.userAddress = _user;
    userData.timestamp = block.timestamp;
    userData.blockNumber = block.number;

    uint256[] memory userCircleIds = _getAllUserCircleIds(_user);
    userData.circleData = new UserCircleData[](userCircleIds.length);

    userData.membershipStatus = _getUserMembershipStatus(_user, userCircleIds);
    userData.financialSummary = _getUserFinancialSummary(_user, userCircleIds);

    for (uint256 i = 0; i < userCircleIds.length; i++) {
      userData.circleData[i] = _getUserCircleData(_user, userCircleIds[i]);
    }

    return userData;
  }

  function getUserFinancialSummary(address _user) external view returns (UserFinancialSummary memory summary) {
    uint256[] memory userCircleIds = _getAllUserCircleIds(_user);
    return _getUserFinancialSummary(_user, userCircleIds);
  }

  function getUserMembershipStatus(address _user) external view returns (UserMembershipStatus memory status) {
    uint256[] memory userCircleIds = _getAllUserCircleIds(_user);
    return _getUserMembershipStatus(_user, userCircleIds);
  }

  function getUserCircleData(address _user, uint256 _circleId) external view returns (UserCircleData memory circleData) {
    return _getUserCircleData(_user, _circleId);
  }

  function getUserCirclesData(
    address _user,
    uint256[] calldata _circleIds
  ) external view returns (UserCircleData[] memory circleDataArray) {
    circleDataArray = new UserCircleData[](_circleIds.length);
    for (uint256 i = 0; i < _circleIds.length; i++) {
      circleDataArray[i] = _getUserCircleData(_user, _circleIds[i]);
    }
    return circleDataArray;
  }

  function _getAllUserCircleIds(address _user) internal view returns (uint256[] memory) {
    uint256[] memory memberCircleIds = memberCircles[_user];

    // Count owned circles that are not already in memberCircles
    uint256 ownedCirclesCount = 0;
    for (uint256 i = 0; i < nextId; i++) {
      if (circles[i].owner == _user) {
        bool isAlreadyMember = false;
        for (uint256 j = 0; j < memberCircleIds.length; j++) {
          if (memberCircleIds[j] == i) {
            isAlreadyMember = true;
            break;
          }
        }
        if (!isAlreadyMember) {
          ownedCirclesCount++;
        }
      }
    }

    // Create array with all circle IDs
    uint256[] memory allCircleIds = new uint256[](memberCircleIds.length + ownedCirclesCount);

    // Add member circles
    for (uint256 i = 0; i < memberCircleIds.length; i++) {
      allCircleIds[i] = memberCircleIds[i];
    }

    // Add owned circles that are not already included
    uint256 currentIndex = memberCircleIds.length;
    for (uint256 i = 0; i < nextId; i++) {
      if (circles[i].owner == _user) {
        bool isAlreadyMember = false;
        for (uint256 j = 0; j < memberCircleIds.length; j++) {
          if (memberCircleIds[j] == i) {
            isAlreadyMember = true;
            break;
          }
        }
        if (!isAlreadyMember) {
          allCircleIds[currentIndex] = i;
          currentIndex++;
        }
      }
    }

    return allCircleIds;
  }

  function _getUserFinancialSummary(
    address _user,
    uint256[] memory _circleIds
  ) internal view returns (UserFinancialSummary memory summary) {
    summary.totalBalance = getTotalBalance(_user);

    for (uint256 i = 0; i < _circleIds.length; i++) {
      uint256 circleId = _circleIds[i];
      UserCircleData memory circleData = _getUserCircleData(_user, circleId);

      if (!circleData.isDecommissioned) {
        summary.activeCirclesCount++;

        if (circleData.isOwner) {
          summary.ownedCirclesCount++;
        }

        if (circleData.canWithdraw) {
          summary.pendingWithdrawals++;
        }

        if (circleData.userBalance < circleData.circleInfo.depositAmount && !circleData.isExpired) {
          summary.upcomingDeposits++;
        }

        summary.totalDeposited += circleData.userBalance;
      } else {
        summary.completedCirclesCount++;
      }
    }
  }

  function _getUserMembershipStatus(
    address _user,
    uint256[] memory _circleIds
  ) internal view returns (UserMembershipStatus memory status) {
    status.allCircleIds = _circleIds;

    uint256 activeCount = 0;
    uint256 ownedCount = 0;
    uint256 withdrawableCount = 0;
    uint256 expiredCount = 0;
    uint256 decommissionedCount = 0;

    for (uint256 i = 0; i < _circleIds.length; i++) {
      uint256 circleId = _circleIds[i];
      UserCircleData memory circleData = _getUserCircleData(_user, circleId);

      if (circleData.isDecommissioned) {
        decommissionedCount++;
      } else if (circleData.isExpired) {
        expiredCount++;
      } else {
        activeCount++;
        if (circleData.isOwner) {
          ownedCount++;
        }
        if (circleData.canWithdraw) {
          withdrawableCount++;
        }
      }
    }

    status.activeCircleIds = new uint256[](activeCount);
    status.ownedCircleIds = new uint256[](ownedCount);
    status.withdrawableCircleIds = new uint256[](withdrawableCount);
    status.expiredCircleIds = new uint256[](expiredCount);
    status.decommissionedCircleIds = new uint256[](decommissionedCount);

    uint256 activeIndex = 0;
    uint256 ownedIndex = 0;
    uint256 withdrawableIndex = 0;
    uint256 expiredIndex = 0;
    uint256 decommissionedIndex = 0;

    for (uint256 i = 0; i < _circleIds.length; i++) {
      uint256 circleId = _circleIds[i];
      UserCircleData memory circleData = _getUserCircleData(_user, circleId);

      if (circleData.isDecommissioned) {
        status.decommissionedCircleIds[decommissionedIndex++] = circleId;
      } else if (circleData.isExpired) {
        status.expiredCircleIds[expiredIndex++] = circleId;
      } else {
        status.activeCircleIds[activeIndex++] = circleId;
        if (circleData.isOwner) {
          status.ownedCircleIds[ownedIndex++] = circleId;
        }
        if (circleData.canWithdraw) {
          status.withdrawableCircleIds[withdrawableIndex++] = circleId;
        }
      }
    }
  }

  function _getUserCircleData(
    address _user,
    uint256 _circleId
  ) internal view returns (UserCircleData memory circleData) {
    circleData.circleId = _circleId;

    Circle memory circle = circles[_circleId];
    if (_isDecommissioned(circle)) {
      circleData.isDecommissioned = true;
      return circleData;
    }

    circleData.circleInfo = circle;
    circleData.isDecommissioned = false;

    (address[] memory members, uint256[] memory memberBalances) = getMemberBalances(_circleId);

    for (uint256 i = 0; i < members.length; i++) {
      if (members[i] == _user) {
        circleData.userBalance = memberBalances[i];
        circleData.isMember = true;
      }
      circleData.totalPoolBalance += memberBalances[i];
    }

    circleData.isOwner = (circle.owner == _user);

    address currentWithdrawer = withdrawableBy(_circleId);
    circleData.isCurrentWithdrawer = (currentWithdrawer == _user);

    circleData.canWithdraw = circleData.isCurrentWithdrawer && isWithdrawable(_circleId);

    uint256 currentPeriodEnd = circle.circleStart + (circle.depositInterval * (circle.currentIndex + 1));
    circleData.nextWithdrawTime = circle.circleStart + (circle.depositInterval * circle.currentIndex);
    circleData.depositWindowEnd = currentPeriodEnd;

    uint256 circleEndTime = circle.circleStart + (circle.depositInterval * circle.maxDeposits);
    circleData.isExpired = (block.timestamp >= circleEndTime);

    circleData.completedRounds = circle.currentIndex;
    circleData.totalRounds = circle.maxDeposits;

    uint256 membersWithFullDeposits = 0;
    for (uint256 i = 0; i < memberBalances.length; i++) {
      if (memberBalances[i] >= circle.depositAmount) {
        membersWithFullDeposits++;
      }
    }
    circleData.remainingDepositsNeeded = members.length - membersWithFullDeposits;
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
