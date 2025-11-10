// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISavingCircles {
  /**
   * @notice A struct representing a saving circle
   * @param owner The owner of the circle
   * @param members The members of the circle
   * @param currentIndex The current index of the circle
   * @param depositAmount The deposit amount of the circle
   * @param token The token of the circle
   * @param depositInterval The deposit interval of the circle
   * @param circleStart The start time of the circle
   * @param circleEnd The end time of the circle
   */
  struct Circle {
    address owner;
    address[] members;
    uint256 currentIndex;
    uint256 depositAmount;
    address token;
    uint256 depositInterval;
    uint256 circleStart;
    uint256 circleEnd;
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
   * @notice Check if a circle is decommissioned
   * @param circle The circle
   * @return decommissioned Whether the circle is decommissioned
   */
  function isDecommissioned(Circle memory circle) external view returns (bool decommissioned);

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
   * @notice Get the next ID that will be assigned to a new circle
   * @return nextId The next ID
   */
  function nextId() external view returns (uint256 nextId);

  /**
   * @notice Get balance for a member in a circle
   * @param id The ID of the circle
   * @param member The address of the member
   * @return balance The balance
   */
  function balances(uint256 id, address member) external view returns (uint256 balance);
}
