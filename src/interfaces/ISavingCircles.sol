// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISavingCircles {
  /**
   * @notice An enum representing the state of a circle
   * @dev NotStarted = 0, Active = 1, DepositInProgress = 2, DepositComplete = 3, Expired = 4, Decommissioned = 5, MissedDeposit = 6
   *      - NotStarted:       Circle is created but has not been started by the owner yet.
   *      - Active:           Circle is running; the first deposit round is open and no issues have been detected.
   *      - DepositInProgress: The current round's deposit window is open and not all members have completed their deposits.
   *      - DepositComplete:  All members have deposited the full amount for the current round; the round recipient may now withdraw.
   *      - Expired:          All rounds have concluded and every member has had their turn to receive the pot.
   *      - Decommissioned:   The circle was forcefully shut down (owner set to address(0)). All remaining funds have
   *                          been returned to depositors. No further interaction is possible.
   *      - MissedDeposit:    A previous round's deposit window closed without all members depositing in full.
   *                          Deposits and withdrawals are blocked; only `decommission()` can be called to recover funds.
   */
  enum CircleState {
    NotStarted,
    Active,
    DepositInProgress,
    DepositComplete,
    Expired,
    Decommissioned,
    MissedDeposit
  }

  /**
   * @notice An enum representing the state of a round
   * @dev NotStarted = 0, DepositInProgress = 1, Claimable = 2, Claimed = 3
   */
  enum RoundState {
    NotStarted,
    DepositInProgress,
    Claimable,
    Claimed
  }

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
    uint256 currentIndex;
    uint256 depositAmount;
    address token;
    uint256 depositInterval;
    uint256 effectiveCircleStartTime;
    uint256 circleEnd;
  }

  // =======================
  // EVENTS
  // =======================

  /**
   * @notice Emitted when a circle is created
   * @param id The ID of the circle
   * @param token The token of the circle
   * @param depositAmount The deposit amount of the circle
   * @param depositInterval The deposit interval of the circle
   */
  event CircleCreated(uint256 indexed id, address token, uint256 depositAmount, uint256 depositInterval);

  /**
   * @notice Emitted when a circle is decommissioned
   * @dev Emitted after all recoverable funds have been returned to depositors and the circle struct has been deleted.
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
   * @notice Emitted when an invite is successfully redeemed
   * @param id The ID of the circle
   * @param redeemer The address of the redeemer
   */
  event InviteRedeemed(uint256 indexed id, address indexed redeemer);
  /**
   * @notice Emitted when a saving circle is started
   * @param id The ID of the circle
   */
  event CircleStarted(uint256 indexed id);

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
   * @notice Thrown when the signer of an invite is invalid
   */
  error InvalidSigner();

  /**
   * @notice Thrown when the caller is already a member of the Circle
   */
  error AlreadyMember();

  /**
   * @notice Thrown when an invite nonce has already been used
   */
  error InviteAlreadyUsed();
  /**
   * @notice Thrown when the caller is not the owner of the Circle
   */
  error NotOwner();
  /**
   * @notice Thrown when the circle is already active
   */
  error AlreadyActive();
  /**
   * @notice Thrown when the circle is not active
   */
  error NotActive();
  /**
   * @notice Thrown when a previous round ended with incomplete deposits, blocking deposits and withdrawals until decommission
   * @dev A round is considered timed-out when `block.timestamp >= roundEndTime(prevRound)` and not all members
   *      deposited the full amount in that round. The only valid action from this state is calling `decommission()`.
   */
  error CircleTimedOut();

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
   * @notice Start a circle
   * @param id The ID of the circle
   */
  function start(uint256 id) external;

  /**
   * @notice Deposit funds into a circle for the calling member
   * @dev Deposits can be made incrementally (partial deposits) within the current round's window,
   *      as long as the cumulative amount does not exceed `depositAmount`.
   *      Reverts with `CircleTimedOut` if a previous round's window has passed without all members depositing in full —
   *      indicating a missed-deposit situation. Call `decommission()` first to recover funds before any new activity.
   *      Reverts with `CircleExpired` once all rounds have elapsed.
   * @param id The ID of the circle
   * @param value The amount of funds to deposit (cumulative per round must equal `depositAmount`)
   */
  function deposit(uint256 id, uint256 value) external;

  /**
   * @notice Deposit funds into a circle on behalf of a member
   * @dev Identical deposit rules apply as in `deposit()`. The caller pays the tokens but they are credited to `member`.
   *      Reverts with `CircleTimedOut` if a missed-deposit situation is detected (see `deposit()`).
   * @param id The ID of the circle
   * @param value The amount of funds to deposit
   * @param member The address of the member to credit the deposit to
   */
  function depositFor(uint256 id, uint256 value, address member) external;

  /**
   * @notice Withdraw the rotating pot for the calling member
   * @dev The caller must be a member of the circle. Withdrawal is only permitted when:
   *      1. The circle is active.
   *      2. The current round's index matches the caller's position in the member list.
   *      3. All members have deposited the full `depositAmount` for that round.
   *      4. The circle is not in a missed-deposit / decommissionable state.
   *      The withdrawal amount equals `depositAmount * numberOfMembers`.
   *      Each member may only claim once; subsequent calls revert with `NotWithdrawable`.
   *      If the caller is the last member to claim, the circle is automatically marked inactive.
   * @param id The ID of the circle
   */
  function withdraw(uint256 id) external;

  /**
   * @notice Withdraw the rotating pot on behalf of a member
   * @dev Same rules apply as in `withdraw()`. The caller must be a member of the circle, but the
   *      funds are sent to `member`. This is useful for automating payouts when the designated
   *      recipient cannot call the contract directly.
   * @param id The ID of the circle
   * @param member The address of the member to receive the withdrawal
   */
  function withdrawFor(uint256 id, address member) external;

  /**
   * @notice Decommission a circle after a missed-deposit event, returning all funds to depositors
   * @dev Any member of the circle may call this function once the conditions for decommissioning are met:
   *      1. The circle is active.
   *      2. A previous round's deposit window has passed (`block.timestamp >= roundEndTime(prevRound)`).
   *      3. Not all members completed their deposit in that previous round.
   *
   *      Decommission flow:
   *      - Sets `isActive[id]` to false, preventing further deposits and withdrawals.
   *      - Iterates over every member-round combination that has not yet been claimed and refunds each
   *        depositor their exact `roundDeposits[id][round][member]` amount directly in the same transaction.
   *      - Deletes the `circles[id]` storage entry, setting `owner` to `address(0)` — this is the canonical
   *        indicator that a circle is decommissioned (checked by `isDecommissioned()`).
   *      - Emits `CircleDecommissioned`.
   *
   *      After decommission the circle ID is permanently inactive: `getCircle()` and most view functions
   *      will revert with `NotCommissioned` for that ID.
   *
   * @param id The ID of the circle to decommission
   */
  function decommission(uint256 id) external;

  /**
   * @notice Redeems an invite signed by the Circle owner
   * @param id The ID of the Circle
   * @param nonce Unique nonce for the invite
   * @param signature The owner's EIP-712 signature
   */
  function redeemInvite(uint256 id, uint256 nonce, bytes calldata signature) external;

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
   * @notice Get the members of a circle
   * @param id The ID of the circle
   * @return members The members of the circle
   */
  function getCircleMembers(uint256 id) external view returns (address[] memory members);

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
   * @notice Check if a circle is decommissionable
   * @param id The ID of the circle
   * @return decommissionable Whether the circle is decommissionable
   */
  function isDecommissionable(uint256 id) external view returns (bool decommissionable);

  /**
   * @notice Check whether at least one member in a circle can currently claim a withdrawal
   * @param id The ID of the circle
   * @return withdrawable Whether any member in the circle is currently withdrawable
   */
  function isWithdrawable(uint256 id) external view returns (bool withdrawable);

  /**
   * @notice Check if a specific member is eligible to claim their withdrawal from a circle
   * @param id The ID of the circle
   * @param member The member to check
   * @return withdrawable Whether the member is withdrawable
   */
  function isMemberWithdrawable(uint256 id, address member) external view returns (bool withdrawable);

  /**
   * @notice Get the address of the withdrawable by
   * @param id The ID of the circle
   * @return currentRoundWithdrawer The address of the current round withdrawer
   */
  function currentRoundWithdrawer(uint256 id) external view returns (address currentRoundWithdrawer);

  /**
   * @notice Get the current state of a circle
   * @param id The ID of the circle
   * @return state The current state of the circle
   */
  function circleState(uint256 id) external view returns (CircleState state);

  /**
   * @notice Get the current round of a circle
   * @param id The ID of the circle
   * @return state The current round's state of the circle
   */
  function roundState(uint256 id) external view returns (RoundState state);

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
