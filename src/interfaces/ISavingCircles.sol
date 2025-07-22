// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISavingCircles {
  // =======================
  // STRUCT DEFINITIONS
  // =======================

  /**
   * @notice A struct representing a saving circle
   * @param owner The owner of the circle
   * @param members The members of the circle
   * @param currentIndex The current index of the circle
   * @param depositAmount The deposit amount of the circle
   * @param token The token of the circle
   * @param depositInterval The deposit interval of the circle
   * @param circleStart The start time of the circle
   * @param maxDeposits The maximum number of deposits for the circle
   */
  struct Circle {
    address owner;
    address[] members;
    uint256 currentIndex;
    uint256 depositAmount;
    address token;
    uint256 depositInterval;
    uint256 circleStart;
    uint256 maxDeposits;
  }

  /**
   * @notice Data structure for comprehensive user circle information
   * @param circleId The ID of the circle
   * @param circleInfo The circle information
   * @param userBalance The user's current balance in the circle
   * @param isMember Whether the user is a member of the circle
   * @param isOwner Whether the user owns the circle
   * @param isCurrentWithdrawer Whether the user is the current withdrawer
   * @param canWithdraw Whether the user can currently withdraw
   * @param nextWithdrawTime When the next withdrawal can occur
   * @param depositWindowEnd When the current deposit window ends
   * @param isExpired Whether the circle has expired
   * @param isDecommissioned Whether the circle has been decommissioned
   * @param totalPoolBalance Total balance of all members in the circle
   * @param remainingDepositsNeeded Number of members who still need to complete deposits
   * @param completedRounds Number of withdrawal rounds completed
   * @param totalRounds Total number of withdrawal rounds
   */
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
   */
  struct UserMembershipStatus {
    uint256[] allCircleIds;
    uint256[] activeCircleIds;
    uint256[] ownedCircleIds;
    uint256[] withdrawableCircleIds;
    uint256[] expiredCircleIds;
    uint256[] decommissionedCircleIds;
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

  // =======================
  // EVENTS
  // =======================

  /**
   * @notice Emitted when a circle is created
   * @param id The ID of the circle
   * @param members The members of the circle
   * @param token The token of the circle
   * @param depositAmount The deposit amount of the circle
   * @param depositInterval The deposit interval of the circle
   */
  event CircleCreated(
    uint256 indexed id, address[] members, address token, uint256 depositAmount, uint256 depositInterval
  );

  /**
   * @notice Emitted when a circle is decommissioned
   * @param id The ID of the circle
   */
  event CircleDecommissioned(uint256 indexed id);

  /**
   * @notice Emitted when a member deposits funds into a circle
   * @param id The ID of the circle
   * @param member The address of the member
   * @param amount The amount of funds deposited
   */
  event FundsDeposited(uint256 indexed id, address indexed member, uint256 amount);

  /**
   * @notice Emitted when a member withdraws funds from a circle
   * @param id The ID of the circle
   * @param member The address of the member
   * @param amount The amount of funds withdrawn
   */
  event FundsWithdrawn(uint256 indexed id, address indexed member, uint256 amount);

  /**
   * @notice Emitted when a token is allowed
   * @param token The address of the token
   * @param allowed Whether the token is allowed
   */
  event TokenAllowed(address indexed token, bool indexed allowed);

  /**
   * @notice Thrown when a member attempts to redundantly deposit funds into a circle
   */
  error AlreadyDeposited();

  /**
   * @notice Thrown when a circle already exists
   */
  error AlreadyExists();

  /**
   * @notice Thrown when a deposit is invalid
   */
  error InvalidDeposit();

  /**
   * @notice Thrown when a circle is invalid
   */
  error InvalidCircle();

  /**
   * @notice Thrown when a circle is not commissioned
   */
  error NotCommissioned();

  /**
   * @notice Thrown when a member is not a member of a circle
   */
  error NotMember();

  /**
   * @notice Thrown when a circle is not decommissionable
   */
  error NotDecommissionable();

  /**
   * @notice Thrown when a circle is not withdrawable
   */
  error NotWithdrawable();

  /**
   * @notice Thrown when a transfer fails
   */
  error TransferFailed();

  /**
   * @notice Thrown when a deposit window is closed
   */
  error DepositWindowClosed();

  /**
   * @notice Thrown when a circle has expired
   */
  error CircleExpired();

  /**
   * @notice Thrown when a deposit amount is exceeded
   */
  error ExceedsDepositAmount();

  /**
   * @notice Thrown when a deposit is made before the circle starts
   */
  error DepositBeforeCircleStart();

  /**
   * @notice Thrown when a token is not allowed
   */
  error TokenNotAllowed();

  /**
   * @notice Thrown when a deposit interval is invalid
   */
  error InvalidDepositInterval();

  /**
   * @notice Thrown when a deposit amount is invalid
   */
  error InvalidDepositAmount();

  /**
   * @notice Thrown when a max deposits is invalid
   */
  error InvalidMaxDeposits();

  /**
   * @notice Thrown when a circle start time is invalid
   */
  error InvalidCircleStartTime();

  /**
   * @notice Thrown when a current index is invalid
   */
  error InvalidCurrentIndex();

  /**
   * @notice Thrown when a owner is invalid
   */
  error InvalidOwner();

  /**
   * @notice Thrown when a member count is invalid
   */
  error InvalidMemberCount();

  /**
   * @notice Thrown when a member address is invalid
   */
  error InvalidMemberAddress();

  /**
   * @notice Initialize the contract
   * @param owner The owner of the contract
   */
  function initialize(address owner) external;

  /**
   * @notice Set a token allowed
   * @param token The address of the token
   * @param allowed Whether the token is allowed
   */
  function setTokenAllowed(address token, bool allowed) external;

  /**
   * @notice Create a circle
   * @param circle The circle
   * @return id The ID of the circle
   */
  function create(Circle memory circle) external returns (uint256);

  /**
   * @notice Deposit funds into a circle
   * @param id The ID of the circle
   * @param value The amount of funds to deposit
   */
  function deposit(uint256 id, uint256 value) external;

  /**
   * @notice Deposit funds into a circle for a member
   * @param id The ID of the circle
   * @param value The amount of funds to deposit
   * @param member The address of the member
   */
  function depositFor(uint256 id, uint256 value, address member) external;

  /**
   * @notice Withdraw funds from a circle
   * @param id The ID of the circle
   */
  function withdraw(uint256 id) external;

  /**
   * @notice Withdraw funds from a circle for a member
   * @param id The ID of the circle
   * @param member The address of the member
   */
  function withdrawFor(uint256 id, address member) external;

  /**
   * @notice Decommission a circle
   * @param id The ID of the circle
   */
  function decommission(uint256 id) external;

  /**
   * @notice Get a single circle
   * @param id The ID of the circle
   * @return circle The circle
   */
  function getCircle(uint256 id) external view returns (Circle memory circle);

  /**
   * @notice Get multiple circles
   * @param ids The IDs of the circles
   * @return circles The circles
   */
  function getCircles(uint256[] calldata ids) external view returns (Circle[] memory circles);

  /**
   * @notice Get all circles for a member
   * @param member The address of the member
   * @return circles The circles
   */
  function getMemberCircles(address member) external view returns (uint256[] memory circles);

  /**
   * @notice Get the balances of the members of a circle
   * @param id The ID of the circle
   * @return members The members of the circle
   * @return balances The balances of the members of the circle
   */
  function getMemberBalances(uint256 id) external view returns (address[] memory members, uint256[] memory balances);

  /**
   * @notice Check if a member is a member of a circle
   * @param member The address of the member
   * @param ids The IDs of the circles
   * @return memberships The memberships of the member
   */
  function checkMemberships(address member, uint256[] calldata ids) external view returns (bool[] memory memberships);

  /**
   * @notice Check if a token is allowed
   * @param token The address of the token
   * @return allowed Whether the token is allowed
   */
  function isTokenAllowed(address token) external view returns (bool allowed);

  /**
   * @notice Check if a circle is withdrawable
   * @param id The ID of the circle
   * @return withdrawable Whether the circle is withdrawable
   */
  function isWithdrawable(uint256 id) external view returns (bool withdrawable);

  /**
   * @notice Get the address of the withdrawable by
   * @param id The ID of the circle
   * @return withdrawableBy The address of the withdrawable by
   */
  function withdrawableBy(uint256 id) external view returns (address withdrawableBy);

  /**
   * @notice Get the total balance for a member across all circles they have joined
   * @param member The address of the member
   * @return totalBalance The sum of the member's balances across all circles
   */
  function getTotalBalance(address member) external view returns (uint256 totalBalance);
}
