// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICollateralSavingCircles
 * @notice Interface for a permissionless, collateralized rotating savings and credit
 *         association (ROSCA).
 * @dev This is a variant of {ISavingCircles} that removes the trust bound present in the
 *      baseline design. A circle runs exactly two cycles of `numSlots` rounds each:
 *
 *        - Cycle 0 (the *collateral cycle*, rounds `0 .. n-1`): every member deposits the
 *          per-round amount `m` but nobody withdraws. Each member's `n` deposits accumulate
 *          into a locked collateral balance of `n * m` (one whole pot). This is the
 *          "complete the first full circle without withdrawing" phase.
 *
 *        - Cycle 1 (the *payout cycle*, rounds `n .. 2n-1`): a normal ROSCA. Each round the
 *          member occupying the round's slot withdraws the full pot `n * m`. If any member
 *          fails to deposit for a round, the shortfall is drawn from *that member's own*
 *          locked collateral, so the recipient is always paid in full.
 *
 *      Because every member's collateral (`n * m`) is at least its maximum possible unmet
 *      obligation, an honest member never subsidizes another member's default, for any number
 *      of defaulters. This is what makes membership safe to open permissionlessly: there is no
 *      owner, no invite, and no frozen cohort. See docs/collateralized-permissionless-circles.md.
 */
interface ICollateralSavingCircles {
  /**
   * @notice Lifecycle state of a circle.
   * @dev Open = accepting members, not yet started.
   *      CollateralCycle = started, currently in cycle 0 (collateral accrual).
   *      PayoutCycle = in cycle 1 (withdrawals enabled).
   *      Ended = all `2n` rounds elapsed; members may reclaim remaining collateral.
   *      Aborted = collateral cycle finished under-collateralized; everyone refunded.
   */
  enum CircleState {
    Open,
    CollateralCycle,
    PayoutCycle,
    Ended,
    Aborted
  }

  /**
   * @notice Immutable parameters of a circle.
   * @param token The ERC20 token used for deposits, collateral and payouts.
   * @param depositAmount The per-round deposit amount `m`.
   * @param roundDuration The duration of a single round, in seconds.
   * @param numSlots The number of member slots `n`; also the number of rounds per cycle.
   * @param startTime The timestamp at which the circle started (0 until started).
   */
  struct Circle {
    address token;
    uint256 depositAmount;
    uint256 roundDuration;
    uint256 numSlots;
    uint256 startTime;
  }

  // =======================
  // EVENTS
  // =======================

  /// @notice Emitted when a token is allowed or disallowed by the admin.
  event TokenAllowed(address indexed token, bool indexed allowed);

  /// @notice Emitted when a new circle is created.
  event CircleCreated(
    uint256 indexed id, address indexed token, uint256 depositAmount, uint256 roundDuration, uint256 numSlots
  );

  /// @notice Emitted when a member claims a slot in a circle.
  event MemberJoined(uint256 indexed id, address indexed member, uint256 slot);

  /// @notice Emitted when a circle starts (all slots filled).
  event CircleStarted(uint256 indexed id, uint256 startTime);

  /// @notice Emitted when a member deposits into the collateral cycle.
  event CollateralDeposited(uint256 indexed id, address indexed member, uint256 amount);

  /// @notice Emitted when a member deposits into a payout round.
  event FundsDeposited(uint256 indexed id, address indexed member, uint256 round, uint256 amount);

  /// @notice Emitted when a member's collateral is slashed to cover a missed deposit.
  event CollateralSlashed(uint256 indexed id, address indexed member, uint256 round, uint256 amount);

  /// @notice Emitted when a member withdraws a payout pot.
  event FundsWithdrawn(uint256 indexed id, address indexed member, uint256 round, uint256 amount);

  /// @notice Emitted when a member reclaims their remaining collateral after the circle ends.
  event CollateralReclaimed(uint256 indexed id, address indexed member, uint256 amount);

  /// @notice Emitted when a circle is aborted for finishing the collateral cycle under-funded.
  event CircleAborted(uint256 indexed id);

  // =======================
  // ERRORS
  // =======================

  /// @notice Thrown when the token is not on the allow-list.
  error TokenNotAllowed();
  /// @notice Thrown when a circle parameter is invalid.
  error InvalidParameters();
  /// @notice Thrown when acting on a circle id that does not exist.
  error CircleNotFound();
  /// @notice Thrown when joining a circle that is full or already started.
  error CircleNotOpen();
  /// @notice Thrown when the caller is already a member.
  error AlreadyMember();
  /// @notice Thrown when the caller is not a member.
  error NotMember();
  /// @notice Thrown when starting a circle that is not yet full.
  error CircleNotFull();
  /// @notice Thrown when starting or acting on a circle in the wrong lifecycle state.
  error WrongState();
  /// @notice Thrown when a deposit would exceed the per-round amount.
  error ExceedsDepositAmount();
  /// @notice Thrown when a payout-cycle deposit is attempted while the circle is under-collateralized.
  error NotFullyCollateralized();
  /// @notice Thrown when a withdrawal is not (yet) claimable.
  error NotWithdrawable();
  /// @notice Thrown when there is nothing to reclaim.
  error NothingToReclaim();
  /// @notice Thrown when an abort is attempted on a circle that is fully collateralized or not past cycle 0.
  error NotAbortable();

  // =======================
  // ADMIN
  // =======================

  /**
   * @notice Initialize the upgradeable contract.
   * @param owner The admin that manages the token allow-list.
   */
  function initialize(address owner) external;

  /**
   * @notice Allow or disallow a token for use in circles.
   * @param token The token address.
   * @param allowed Whether the token is allowed.
   */
  function setTokenAllowed(address token, bool allowed) external;

  // =======================
  // CIRCLE LIFECYCLE
  // =======================

  /**
   * @notice Permissionlessly create a new circle. The caller does not become a member.
   * @param token The ERC20 token (must be allowed).
   * @param depositAmount The per-round deposit `m` (> 0).
   * @param roundDuration The round duration in seconds (> 0).
   * @param numSlots The number of slots `n` (>= 2).
   * @return id The id of the new circle.
   */
  function createCircle(
    address token,
    uint256 depositAmount,
    uint256 roundDuration,
    uint256 numSlots
  ) external returns (uint256 id);

  /**
   * @notice Permissionlessly join an open circle, taking the next free slot.
   * @param id The circle id.
   */
  function join(uint256 id) external;

  /**
   * @notice Permissionlessly start a circle once all slots are filled.
   * @param id The circle id.
   */
  function start(uint256 id) external;

  /**
   * @notice Deposit for the caller into the current round.
   * @dev In cycle 0 the value accrues to collateral; in cycle 1 it funds the round pot.
   * @param id The circle id.
   * @param value The amount to deposit (partial deposits accumulate toward `m`).
   */
  function deposit(uint256 id, uint256 value) external;

  /**
   * @notice Deposit for another member into the current round (funded by the caller).
   * @param id The circle id.
   * @param member The member to credit.
   * @param value The amount to deposit.
   */
  function depositFor(uint256 id, address member, uint256 value) external;

  /**
   * @notice Withdraw every matured, unclaimed payout pot owed to the caller.
   * @dev Anyone can trigger a member's payout via {withdrawFor}. Covering of any missed
   *      deposits from defaulters' collateral happens atomically here.
   * @param id The circle id.
   */
  function withdraw(uint256 id) external;

  /**
   * @notice Withdraw every matured, unclaimed payout pot owed to `member`.
   * @param id The circle id.
   * @param member The member to pay.
   */
  function withdrawFor(uint256 id, address member) external;

  /**
   * @notice Reclaim the caller's remaining collateral once the circle has ended.
   * @dev This is the permissionless "leave": no owner approval is required. A member's
   *      collateral only ever backed its own obligations, so returning it harms no one.
   * @param id The circle id.
   */
  function reclaimCollateral(uint256 id) external;

  /**
   * @notice Abort a circle whose collateral cycle finished under-funded, refunding everyone.
   * @dev Callable by anyone. Only possible before any payout can occur, so no member is harmed.
   * @param id The circle id.
   */
  function abort(uint256 id) external;

  // =======================
  // VIEWS
  // =======================

  /// @notice Returns whether a token is allowed.
  function isTokenAllowed(address token) external view returns (bool allowed);

  /// @notice Returns the id that will be assigned to the next created circle.
  function nextId() external view returns (uint256 id);

  /// @notice Returns the immutable parameters of a circle.
  function getCircle(uint256 id) external view returns (Circle memory circle);

  /// @notice Returns the ordered members (by slot) of a circle.
  function getMembers(uint256 id) external view returns (address[] memory members);

  /// @notice Returns the current lifecycle state of a circle.
  function circleState(uint256 id) external view returns (CircleState state);

  /// @notice Returns the current round index (0-based) of a circle; 0 before start.
  function currentRound(uint256 id) external view returns (uint256 round);

  /// @notice Returns the collateral required per member, `numSlots * depositAmount`.
  function collateralRequirement(uint256 id) external view returns (uint256 amount);

  /// @notice Returns a member's locked collateral balance.
  function collateralOf(uint256 id, address member) external view returns (uint256 amount);

  /// @notice Returns whether every member has completed its full collateral commitment.
  /// @dev Latched at the end of cycle 0; stays true as collateral is drawn down for defaults.
  function isFullyCollateralized(uint256 id) external view returns (bool fully);

  /// @notice Returns the recipient (slot occupant) for a given round.
  function recipientOf(uint256 id, uint256 round) external view returns (address recipient);

  /// @notice Returns the total, unclaimed payout currently withdrawable by a member.
  function withdrawableAmount(uint256 id, address member) external view returns (uint256 amount);
}
