// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISavingCircles} from 'interfaces/ISavingCircles.sol';

interface ISavingCirclesViewer {
  /**
   * @notice Data structure for comprehensive user circle information
   * @param circleId The ID of the circle
   * @param circleInfo The circle information
   * @param userBalance The user's current balance in the circle
   * @param isMember Whether the user is a member of the circle
   * @param isOwner Whether the user owns the circle
   * @param isCurrentWithdrawer Whether the user is the current withdrawer
   * @param canWithdraw Whether the user can currently withdraw
   * @param isExpired Whether the circle has expired
   * @param isDecommissioned Whether the circle has been decommissioned
   * @param isDecommissionable Whether the circle can be decommissioned
   * @param nextWithdrawTime When the next withdrawal can occur
   * @param depositWindowEnd When the current deposit window ends
   * @param totalPoolBalance Total balance of all members in the circle
   * @param remainingDepositsNeeded Number of members who still need to complete deposits
   * @param completedRounds Number of withdrawal rounds completed
   * @param totalRounds Total number of withdrawal rounds
   * @param currentWithdrawer The address of the current withdrawer
   */
  struct UserCircleData {
    uint256 circleId;
    ISavingCircles.Circle circleInfo;
    uint256 userBalance;
    bool isMember;
    bool isOwner;
    bool isCurrentWithdrawer;
    bool canWithdraw;
    bool isExpired;
    bool isDecommissioned;
    bool isDecommissionable;
    uint256 nextWithdrawTime;
    uint256 depositWindowEnd;
    uint256 totalPoolBalance;
    uint256 remainingDepositsNeeded;
    uint256 completedRounds;
    uint256 totalRounds;
    address currentWithdrawer;
  }

  /**
   * @notice Financial summary data for a user across all circles
   * @param totalBalance Total balance across all circles
   * @param totalDeposited Total amount deposited by the user
   * @param totalWithdrawn Total amount withdrawn by the user
   * @param activeCirclesCount Number of active circles the user is involved in
   * @param ownedCirclesCount Number of circles owned by the user
   * @param completedCirclesCount Number of completed circles
   * @param pendingWithdrawals Number of circles with pending withdrawals
   * @param upcomingDeposits Number of circles requiring deposits
   */
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

  /**
   * @notice Membership status data for a user's circle involvement
   * @param allCircleIds All circle IDs the user is associated with
   * @param activeCircleIds Active circle IDs
   * @param ownedCircleIds Circle IDs owned by the user
   * @param withdrawableCircleIds Circle IDs where user can withdraw
   * @param expiredCircleIds Circle IDs that have expired
   * @param decommissionedCircleIds Circle IDs that have been decommissioned
   * @param decommissionableCircleIds Circle IDs that can be decommissioned
   */
  struct UserMembershipStatus {
    uint256[] allCircleIds;
    uint256[] activeCircleIds;
    uint256[] ownedCircleIds;
    uint256[] withdrawableCircleIds;
    uint256[] expiredCircleIds;
    uint256[] decommissionedCircleIds;
    uint256[] decommissionableCircleIds;
  }

  /**
   * @notice Comprehensive user data combining all user information
   * @param userAddress The user's address
   * @param financialSummary Financial summary data
   * @param membershipStatus Membership status data
   * @param circleData Array of detailed circle data
   * @param timestamp Timestamp when data was generated
   * @param blockNumber Block number when data was generated
   */
  struct ComprehensiveUserData {
    address userAddress;
    UserFinancialSummary financialSummary;
    UserMembershipStatus membershipStatus;
    UserCircleData[] circleData;
    uint256 timestamp;
    uint256 blockNumber;
  }

  struct CircleState {
    uint256 circleId;
    uint8 circleState;
    uint8 roundState;
  }

  /**
   * @notice Check if a token is allowed
   * @param _token The token address
   * @return allowed Whether the token is allowed
   */
  function isTokenAllowed(address _token) external view returns (bool);

  /**
   * @notice Check if a member is a member of a circle
   * @param _member The member address
   * @param _ids The circle IDs
   * @return _statuses The membership statuses
   */
  function checkMemberships(address _member, uint256[] calldata _ids) external view returns (bool[] memory _statuses);

  /**
   * @notice Get comprehensive user data
   * @param _user The user address
   * @return userData The comprehensive user data
   */
  function getComprehensiveUserData(address _user) external view returns (ComprehensiveUserData memory userData);

  /**
   * @notice Get user financial summary
   * @param _user The user address
   * @return summary The user financial summary
   */
  function getUserFinancialSummary(address _user) external view returns (UserFinancialSummary memory summary);

  /**
   * @notice Get user membership status
   * @param _user The user address
   * @return status The user membership status
   */
  function getUserMembershipStatus(address _user) external view returns (UserMembershipStatus memory status);

  /**
   * @notice Get user circle data
   * @param _user The user address
   * @param _circleId The circle ID
   * @return circleData The user circle data
   */
  function getUserCircleData(address _user, uint256 _circleId) external view returns (UserCircleData memory circleData);

  /**
   * @notice Get user circles data
   * @param _user The user address
   * @param _circleIds The circle IDs
   * @return circleDataArray The user circles data
   */
  function getUserCirclesData(
    address _user,
    uint256[] calldata _circleIds
  ) external view returns (UserCircleData[] memory circleDataArray);

  /**
   * @notice Get total balance across all circles for a user
   * @param _member The member address
   * @return _totalBalance The total balance across all circles
   */
  function getTotalBalance(address _member) external view returns (uint256 _totalBalance);

  /**
   * @notice Get the current state of a circle
   * @param _circleIds The circle IDs
   * @return states An array of CircleState structs containing the state of each circle
   */
  function getCirclesState(uint256[] calldata _circleIds) external view returns (CircleState[] memory states);
}
