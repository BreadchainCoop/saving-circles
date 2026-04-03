// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SavingCircles} from 'contracts/SavingCircles.sol';

import {ISavingCircles} from 'interfaces/ISavingCircles.sol';
import {ISavingCirclesViewer} from 'interfaces/ISavingCirclesViewer.sol';

/**
 * @title Saving Circles Viewer
 * @notice Contract for viewing the state of the Saving Circles contract
 * @dev This contract is used exclusively to view the state of the Saving Circles contract
 * @dev This contract does not modify or interact with the Saving Circles contract
 * @author Breadchain Collective
 * @author @RonTuretzky
 * @author bagelface.eth
 * @author exo404
 * @author valeriooconte
 */
contract SavingCirclesViewer is ISavingCirclesViewer {
  SavingCircles public immutable SAVING_CIRCLES;

  constructor(address _savingCircles) {
    SAVING_CIRCLES = SavingCircles(_savingCircles);
  }

  /// @inheritdoc ISavingCirclesViewer
  function isTokenAllowed(address _token) external view override returns (bool) {
    return SAVING_CIRCLES.allowedTokens(_token);
  }

  /// @inheritdoc ISavingCirclesViewer
  function checkMemberships(
    address _member,
    uint256[] calldata _ids
  ) external view override returns (bool[] memory _statuses) {
    _statuses = new bool[](_ids.length);

    for (uint256 i = 0; i < _ids.length; i++) {
      _statuses[i] = SAVING_CIRCLES.isMember(_ids[i], _member);
    }

    return _statuses;
  }

  /// @inheritdoc ISavingCirclesViewer
  function getComprehensiveUserData(address _user)
    external
    view
    override
    returns (ComprehensiveUserData memory userData)
  {
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

  /// @inheritdoc ISavingCirclesViewer
  function getUserFinancialSummary(address _user) external view override returns (UserFinancialSummary memory summary) {
    uint256[] memory userCircleIds = _getAllUserCircleIds(_user);
    return _getUserFinancialSummary(_user, userCircleIds);
  }

  /// @inheritdoc ISavingCirclesViewer
  function getUserMembershipStatus(address _user) external view override returns (UserMembershipStatus memory status) {
    uint256[] memory userCircleIds = _getAllUserCircleIds(_user);
    return _getUserMembershipStatus(_user, userCircleIds);
  }

  /// @inheritdoc ISavingCirclesViewer
  function getUserCircleData(
    address _user,
    uint256 _circleId
  ) external view override returns (UserCircleData memory circleData) {
    return _getUserCircleData(_user, _circleId);
  }

  /// @inheritdoc ISavingCirclesViewer
  function getUserCirclesData(
    address _user,
    uint256[] calldata _circleIds
  ) external view override returns (UserCircleData[] memory circleDataArray) {
    circleDataArray = new UserCircleData[](_circleIds.length);
    for (uint256 i = 0; i < _circleIds.length; i++) {
      circleDataArray[i] = _getUserCircleData(_user, _circleIds[i]);
    }
    return circleDataArray;
  }

  /// @inheritdoc ISavingCirclesViewer
  function getTotalBalance(address _member) external view override returns (uint256 _totalBalance) {
    return _getTotalBalance(_member);
  }

  /// @inheritdoc ISavingCirclesViewer
  function getCirclesState(uint256[] calldata _circleIds) external view override returns (CircleState[] memory states) {
    states = new CircleState[](_circleIds.length);
    for (uint256 i = 0; i < _circleIds.length; i++) {
      uint256 circleId = _circleIds[i];
      states[i].circleId = circleId;

      ISavingCircles.Circle memory circle = _getCircle(circleId);
      if (circle.owner == address(0)) {
        states[i].circleState = ISavingCircles.CircleState.Decommissioned;
        states[i].roundState = ISavingCircles.RoundState.NotStarted;
      } else {
        ISavingCircles.CircleState circleState = SAVING_CIRCLES.circleState(circleId);
        states[i].circleState = circleState;
        states[i].roundState = circleState == ISavingCircles.CircleState.Decommissioned
          ? ISavingCircles.RoundState.NotStarted
          : SAVING_CIRCLES.roundState(circleId);
      }
    }
    return states;
  }

  function _getTotalBalance(address _member) internal view returns (uint256 _totalBalance) {
    uint256[] memory _ids = SAVING_CIRCLES.getMemberCircles(_member);

    for (uint256 i = 0; i < _ids.length; i++) {
      _totalBalance += _memberBalance(_ids[i], _member);
    }

    return _totalBalance;
  }

  function _getAllUserCircleIds(address _user) internal view returns (uint256[] memory) {
    uint256[] memory memberCircleIds = SAVING_CIRCLES.getMemberCircles(_user);
    uint256[] memory ownedOnlyCircleIds = _getOwnedOnlyCircleIds(_user, memberCircleIds);

    return _combineCircleIdArrays(memberCircleIds, ownedOnlyCircleIds);
  }

  function _getOwnedOnlyCircleIds(
    address _user,
    uint256[] memory memberCircleIds
  ) internal view returns (uint256[] memory) {
    uint256 ownedCirclesCount = _countOwnedOnlyCircles(_user, memberCircleIds);
    uint256[] memory ownedOnlyIds = new uint256[](ownedCirclesCount);

    uint256 currentIndex = 0;
    for (uint256 i = 0; i < SAVING_CIRCLES.nextId(); i++) {
      if (_getCircleOwner(i) == _user && !_isInArray(i, memberCircleIds)) {
        ownedOnlyIds[currentIndex] = i;
        currentIndex++;
      }
    }

    return ownedOnlyIds;
  }

  function _countOwnedOnlyCircles(
    address _user,
    uint256[] memory memberCircleIds
  ) internal view returns (uint256 count) {
    for (uint256 i = 0; i < SAVING_CIRCLES.nextId(); i++) {
      if (_getCircleOwner(i) == _user && !_isInArray(i, memberCircleIds)) {
        count++;
      }
    }
  }

  function _getUserFinancialSummary(
    address _user,
    uint256[] memory _circleIds
  ) internal view returns (UserFinancialSummary memory summary) {
    summary.totalBalance = _getTotalBalance(_user);

    for (uint256 i = 0; i < _circleIds.length; i++) {
      uint256 circleId = _circleIds[i];
      UserCircleData memory circleData = _getUserCircleData(_user, circleId);

      if (!circleData.isDecommissioned) {
        if (!circleData.isExpired) {
          summary.activeCirclesCount++;
        }

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
    uint256 decommissionableCount = 0;

    for (uint256 i = 0; i < _circleIds.length; i++) {
      UserCircleData memory circleData = _getUserCircleData(_user, _circleIds[i]);

      if (circleData.isDecommissioned) {
        decommissionedCount++;
      } else {
        if (circleData.isDecommissionable) decommissionableCount++;
        if (circleData.isExpired) {
          expiredCount++;
        } else {
          activeCount++;
          if (circleData.isOwner) ownedCount++;
          if (circleData.canWithdraw) withdrawableCount++;
        }
      }
    }

    status.activeCircleIds = new uint256[](activeCount);
    status.ownedCircleIds = new uint256[](ownedCount);
    status.withdrawableCircleIds = new uint256[](withdrawableCount);
    status.expiredCircleIds = new uint256[](expiredCount);
    status.decommissionedCircleIds = new uint256[](decommissionedCount);
    status.decommissionableCircleIds = new uint256[](decommissionableCount);

    status = _populateStatusArrays(status, _user, _circleIds);
  }

  function _populateStatusArrays(
    UserMembershipStatus memory status,
    address _user,
    uint256[] memory _circleIds
  ) internal view returns (UserMembershipStatus memory) {
    uint256 activeIndex = 0;
    uint256 ownedIndex = 0;
    uint256 withdrawableIndex = 0;
    uint256 expiredIndex = 0;
    uint256 decommissionedIndex = 0;
    uint256 decommissionableIndex = 0;

    for (uint256 i = 0; i < _circleIds.length; i++) {
      uint256 circleId = _circleIds[i];
      UserCircleData memory circleData = _getUserCircleData(_user, circleId);

      if (!circleData.isDecommissioned && circleData.isDecommissionable) {
        status.decommissionableCircleIds[decommissionableIndex++] = circleId;
      }

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
    return status;
  }

  function _getUserCircleData(
    address _user,
    uint256 _circleId
  ) internal view returns (UserCircleData memory circleData) {
    circleData.circleId = _circleId;

    ISavingCircles.Circle memory circle = _getCircle(_circleId);
    if (circle.owner == address(0)) {
      circleData.isDecommissioned = true;
      return circleData;
    }

    circleData.circleInfo = circle;
    circleData.isOwner = (circle.owner == _user);
    circleData.isMember = SAVING_CIRCLES.isMember(_circleId, _user);

    if (SAVING_CIRCLES.circleState(_circleId) == ISavingCircles.CircleState.Decommissioned) {
      circleData.isDecommissioned = true;
      circleData.completedRounds = circle.currentIndex;
      circleData.totalRounds = SAVING_CIRCLES.getCircleMembers(_circleId).length;
      return circleData;
    }

    circleData.isDecommissioned = false;
    circleData.isDecommissionable = SAVING_CIRCLES.isDecommissionable(_circleId);

    _setUserBalanceData(circleData, _user, _circleId);
    _setUserPermissions(circleData, _user, circle, _circleId);
    _setCircleTimingData(circleData, circle);
    _setDepositProgress(circleData, _circleId, circle);
  }

  function _setUserBalanceData(UserCircleData memory circleData, address _user, uint256 _circleId) internal view {
    (address[] memory members, uint256[] memory memberBalances) = SAVING_CIRCLES.getMemberBalances(_circleId);

    for (uint256 i = 0; i < members.length; i++) {
      if (members[i] == _user) {
        circleData.userBalance = memberBalances[i];
        circleData.isMember = true;
      }
      circleData.totalPoolBalance += memberBalances[i];
    }
  }

  function _setUserPermissions(
    UserCircleData memory circleData,
    address _user,
    ISavingCircles.Circle memory circle,
    uint256 _circleId
  ) internal view {
    circleData.isOwner = (circle.owner == _user);

    address currentWithdrawer = SAVING_CIRCLES.currentRoundWithdrawer(_circleId);
    circleData.currentWithdrawer = currentWithdrawer;
    circleData.isCurrentWithdrawer = (currentWithdrawer == _user);
    circleData.canWithdraw = SAVING_CIRCLES.isMemberWithdrawable(_circleId, _user);
  }

  function _setCircleTimingData(UserCircleData memory circleData, ISavingCircles.Circle memory circle) internal view {
    uint256 currentPeriodEnd = circle.effectiveCircleStartTime + (circle.depositInterval * (circle.currentIndex + 1));
    circleData.nextWithdrawTime = circle.effectiveCircleStartTime + (circle.depositInterval * circle.currentIndex);
    circleData.depositWindowEnd = currentPeriodEnd;

    circleData.isExpired = (block.timestamp >= circle.circleEnd);

    circleData.completedRounds = circle.currentIndex;
    address[] memory circleMembers = SAVING_CIRCLES.getCircleMembers(circleData.circleId);
    circleData.totalRounds = circleMembers.length;
  }

  function _setDepositProgress(
    UserCircleData memory circleData,
    uint256 _circleId,
    ISavingCircles.Circle memory circle
  ) internal view {
    (, uint256[] memory memberBalances) = SAVING_CIRCLES.getMemberBalances(_circleId);

    uint256 membersWithFullDeposits = 0;
    for (uint256 i = 0; i < memberBalances.length; i++) {
      if (memberBalances[i] >= circle.depositAmount) {
        membersWithFullDeposits++;
      }
    }
    circleData.remainingDepositsNeeded = memberBalances.length - membersWithFullDeposits;
  }

  function _memberBalance(uint256 _circleId, address _member) internal view returns (uint256) {
    if (_getCircleOwner(_circleId) == address(0)) {
      return 0;
    }

    if (SAVING_CIRCLES.circleState(_circleId) == ISavingCircles.CircleState.Decommissioned) {
      return 0;
    }

    (address[] memory members, uint256[] memory balances) = SAVING_CIRCLES.getMemberBalances(_circleId);
    for (uint256 i = 0; i < members.length; i++) {
      if (members[i] == _member) {
        return balances[i];
      }
    }
    return 0;
  }

  function _getCircleOwner(uint256 _circleId) internal view returns (address owner) {
    (owner,,,,,,) = SAVING_CIRCLES.circles(_circleId);
  }

  function _getCircle(uint256 _circleId) internal view returns (ISavingCircles.Circle memory circle) {
    uint256[] memory ids = new uint256[](1);
    ids[0] = _circleId;

    ISavingCircles.Circle[] memory circles = SAVING_CIRCLES.getCircles(ids);
    return circles[0];
  }

  function _isInArray(uint256 value, uint256[] memory array) internal pure returns (bool) {
    for (uint256 i = 0; i < array.length; i++) {
      if (array[i] == value) {
        return true;
      }
    }
    return false;
  }

  function _combineCircleIdArrays(
    uint256[] memory array1,
    uint256[] memory array2
  ) internal pure returns (uint256[] memory) {
    uint256[] memory combined = new uint256[](array1.length + array2.length);

    for (uint256 i = 0; i < array1.length; i++) {
      combined[i] = array1[i];
    }

    for (uint256 i = 0; i < array2.length; i++) {
      combined[array1.length + i] = array2[i];
    }

    return combined;
  }
}
