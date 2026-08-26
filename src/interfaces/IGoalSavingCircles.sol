// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IGoalSavingCircles
 * @notice Interface for goal-based group savings: members deposit flexible amounts toward a
 *         target `goalAmount` before `deadline`. Funds are locked while funding (the commitment
 *         device). On success the pot is released to a beneficiary, or — when no beneficiary is
 *         set — each member reclaims exactly their own contributions. On failure or cancellation
 *         every member is refunded exactly what they deposited.
 * @dev No credit, no interest, no division: the contract only ever adds and subtracts exact
 *      deposit amounts, so conservation of value is an equality, not a bound. Membership uses
 *      the same EIP-712 'StacksInvite' domain as {ISavingCircles}.
 */
interface IGoalSavingCircles {
  /**
   * @notice Lifecycle state of a goal (derived, see goalState()).
   * @dev Funding = 0 accepting deposits, goal not yet reached, deadline not passed.
   *      Funded = 1 goal reached (latched); pot releasable (beneficiary set) or member
   *                contributions unlocked (no beneficiary). Deposits stay open until deadline.
   *      Failed = 2 deadline passed with the goal never reached; members withdraw refunds.
   *      Cancelled = 3 owner cancelled during Funding; members withdraw refunds. Terminal.
   *      Released = 4 pot paid out to the beneficiary. Terminal.
   */
  enum GoalState {
    Funding,
    Funded,
    Failed,
    Cancelled,
    Released
  }

  /**
   * @notice Immutable configuration of a goal, fixed at create().
   * @param owner The goal organizer: signs invites, may cancel during Funding.
   * @param token The allowlisted ERC20 all deposits and payouts use.
   * @param beneficiary Recipient of the whole pot on success; address(0) means no beneficiary —
   *        on success members individually reclaim their own contributions instead.
   * @param goalAmount The funding target in token units (> 0). Deposits may overshoot it.
   * @param deadline Unix timestamp; deposits are accepted strictly before it
   *        (block.timestamp < deadline). At/after the deadline an unmet goal is Failed.
   */
  struct Goal {
    address owner;
    address token;
    address beneficiary;
    uint256 goalAmount;
    uint256 deadline;
  }

  // =======================
  // EVENTS
  // =======================

  /**
   * @notice Emitted when a token is allowed or disallowed by the admin.
   * @param token The token address.
   * @param allowed Whether the token is now allowed.
   */
  event TokenAllowed(address indexed token, bool indexed allowed);

  /**
   * @notice Emitted when a goal is created.
   * @param id The id of the new goal.
   * @param owner The goal owner (the creator).
   * @param token The ERC20 token used by the goal.
   * @param goalAmount The funding target.
   * @param deadline The funding deadline timestamp.
   * @param beneficiary The pot recipient on success, or address(0) for commitment-savings mode.
   */
  event GoalCreated(
    uint256 indexed id, address indexed owner, address token, uint256 goalAmount, uint256 deadline, address beneficiary
  );

  /**
   * @notice Emitted when an invite is successfully redeemed and the redeemer becomes a member.
   * @param id The id of the goal.
   * @param redeemer The new member.
   */
  event InviteRedeemed(uint256 indexed id, address indexed redeemer);

  /**
   * @notice Emitted when a member's contribution is credited (deposit or depositFor).
   * @param id The id of the goal.
   * @param member The member credited with the contribution.
   * @param amount The amount deposited.
   */
  event FundsDeposited(uint256 indexed id, address indexed member, uint256 amount);

  /**
   * @notice Emitted once, the first time totalDeposited reaches goalAmount.
   * @param id The id of the goal.
   * @param totalDeposited The pot size at the moment the goal was reached.
   */
  event GoalReached(uint256 indexed id, uint256 totalDeposited);

  /**
   * @notice Emitted when a member reclaims their contribution (success without beneficiary,
   *         failure, or cancellation).
   * @param id The id of the goal.
   * @param member The member refunded.
   * @param amount The amount refunded (the member's whole contribution).
   */
  event FundsWithdrawn(uint256 indexed id, address indexed member, uint256 amount);

  /**
   * @notice Emitted when the pot is released to the beneficiary.
   * @param id The id of the goal.
   * @param beneficiary The recipient of the pot.
   * @param amount The whole pot paid out (goal target plus any overshoot).
   */
  event GoalReleased(uint256 indexed id, address indexed beneficiary, uint256 amount);

  /**
   * @notice Emitted when the owner cancels a goal during Funding.
   * @param id The id of the goal.
   */
  event GoalCancelled(uint256 indexed id);

  // =======================
  // ERRORS
  // =======================

  /// @notice Thrown when creating a goal with a token that is not allowlisted.
  error TokenNotAllowed();

  /// @notice Thrown when creating a goal with goalAmount == 0.
  error InvalidGoalAmount();

  /// @notice Thrown when creating a goal with deadline <= block.timestamp.
  error InvalidDeadline();

  /// @notice Thrown when the goal id does not exist.
  error GoalNotFound();

  /// @notice Thrown when a goal is not accepting deposits or new members
  ///         (cancelled, released, or block.timestamp >= deadline).
  error GoalNotOpen();

  /// @notice Thrown when the account is not a member of the goal.
  error NotMember();

  /// @notice Thrown when the caller is already a member of the goal.
  error AlreadyMember();

  /// @notice Thrown when an invite nonce has already been used for this goal.
  error InviteAlreadyUsed();

  /// @notice Thrown when the invite signature does not recover to the goal owner.
  error InvalidSigner();

  /// @notice Thrown when depositing zero tokens.
  error InvalidDeposit();

  /// @notice Thrown when the caller is not the goal owner.
  error NotOwner();

  /// @notice Thrown when cancel() is called in any state other than Funding.
  error NotCancellable();

  /// @notice Thrown when release() preconditions fail: goal not Funded, no beneficiary set,
  ///         or already released.
  error NotReleasable();

  /// @notice Thrown when withdraw() is called while contributions are still locked
  ///         (Funding, or Funded with a beneficiary set, or Released).
  error NotWithdrawable();

  /// @notice Thrown when the caller has no contribution to withdraw.
  error NothingToWithdraw();

  // =======================
  // FUNCTIONS
  // =======================

  /**
   * @notice Initialize the contract.
   * @param owner The admin (token allowlist manager).
   */
  function initialize(address owner) external;

  /**
   * @notice Allow or disallow an ERC20 token for new goals. Admin only.
   * @dev Allowlist changes never affect existing goals, which store their token. The admin must
   *      not allowlist fee-on-transfer or rebasing tokens: exact-amount accounting assumes
   *      standard ERC20 transfer semantics.
   * @param token The token address.
   * @param allowed Whether the token is allowed.
   */
  function setTokenAllowed(address token, bool allowed) external;

  /**
   * @notice Create a goal. The caller becomes the goal owner and its first member.
   * @param token Allowlisted ERC20 used for the goal.
   * @param goalAmount Funding target, must be > 0. Overshooting deposits are allowed.
   * @param deadline Unix timestamp, must be > block.timestamp. Deposits close at the deadline.
   * @param beneficiary Pot recipient on success, or address(0) for commitment-savings mode
   *        (members reclaim their own contributions on success).
   * @return id The id of the new goal.
   */
  function create(
    address token,
    uint256 goalAmount,
    uint256 deadline,
    address beneficiary
  ) external returns (uint256 id);

  /**
   * @notice Join a goal with an EIP-712 invite signed by the goal owner.
   * @dev Same 'StacksInvite' domain and Invite(uint256 id,uint256 nonce) typehash as
   *      SavingCircles. Redeemable whenever the goal is open (Funding, or Funded before the
   *      deadline), so latecomers can still help overshoot.
   * @param id The id of the goal.
   * @param nonce Unique invite nonce.
   * @param signature The goal owner's EIP-712 signature over (id, nonce).
   */
  function redeemInvite(uint256 id, uint256 nonce, bytes calldata signature) external;

  /**
   * @notice Deposit tokens toward the goal. Any amount, any number of times, while the goal is
   *         open. Overshooting goalAmount is allowed.
   * @param id The id of the goal.
   * @param value The amount to deposit (> 0).
   */
  function deposit(uint256 id, uint256 value) external;

  /**
   * @notice Deposit on behalf of a member: tokens are pulled from the caller, the contribution
   *         (and any later refund right) is credited to `member`.
   * @param id The id of the goal.
   * @param member The member to credit; must already be a member.
   * @param value The amount to deposit (> 0).
   */
  function depositFor(uint256 id, address member, uint256 value) external;

  /**
   * @notice Withdraw the caller's entire contribution. Available when the goal is Failed,
   *         Cancelled, or Funded with no beneficiary. Full-balance only.
   * @param id The id of the goal.
   */
  function withdraw(uint256 id) external;

  /**
   * @notice Release the whole pot (including overshoot) to the beneficiary. Permissionless once
   *         the goal is Funded and a beneficiary is set; no time limit.
   * @param id The id of the goal.
   */
  function release(uint256 id) external;

  /**
   * @notice Cancel a goal during Funding. Goal owner only. Unlocks full refunds for everyone.
   * @param id The id of the goal.
   */
  function cancel(uint256 id) external;

  // =======================
  // VIEWS
  // =======================

  /**
   * @notice Get a goal's configuration.
   * @param id The id of the goal.
   * @return goal The goal config. Reverts with GoalNotFound for unknown ids.
   */
  function getGoal(uint256 id) external view returns (Goal memory goal);

  /**
   * @notice Get the derived lifecycle state of a goal (precedence:
   *         Cancelled > Released > Funded > Failed > Funding).
   * @param id The id of the goal.
   * @return state The goal state. Reverts with GoalNotFound for unknown ids.
   */
  function goalState(uint256 id) external view returns (GoalState state);

  /**
   * @notice Get the members of a goal (owner first, then invite-redemption order).
   * @param id The id of the goal.
   * @return members The member addresses.
   */
  function getGoalMembers(uint256 id) external view returns (address[] memory members);

  /**
   * @notice Get all goal ids an address is a member of.
   * @param member The member address.
   * @return ids The goal ids.
   */
  function getMemberGoals(address member) external view returns (uint256[] memory ids);

  /**
   * @notice Get members and their current locked contributions, aligned by index.
   * @param id The id of the goal.
   * @return members The member addresses.
   * @return amounts Each member's current contribution.
   */
  function getMemberContributions(uint256 id) external view returns (address[] memory members, uint256[] memory amounts);

  /**
   * @notice Check if a token is allowed.
   * @param token The token address.
   * @return allowed Whether the token is allowed.
   */
  function isTokenAllowed(address token) external view returns (bool allowed);

  /**
   * @notice Next id that will be assigned to a new goal.
   * @return nextId The next goal id.
   */
  function nextId() external view returns (uint256 nextId);

  /**
   * @notice Current escrowed pot of a goal.
   * @param id The id of the goal.
   * @return amount The live escrow: sum of inflows minus sum of outflows for the goal.
   */
  function totalDeposited(uint256 id) external view returns (uint256 amount);

  /**
   * @notice Current locked contribution of a member in a goal.
   * @param id The id of the goal.
   * @param member The member address.
   * @return amount The member's current contribution.
   */
  function contributions(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Whether an address is a member of a goal.
   * @param id The id of the goal.
   * @param member The address to check.
   * @return status Whether the address is a member.
   */
  function isMember(uint256 id, address member) external view returns (bool status);

  /**
   * @notice Whether the goal ever reached goalAmount (one-way latch).
   * @param id The id of the goal.
   * @return reached Whether the goal was ever reached.
   */
  function goalReached(uint256 id) external view returns (bool reached);

  /**
   * @notice Whether the goal was cancelled by its owner.
   * @param id The id of the goal.
   * @return status Whether the goal was cancelled.
   */
  function cancelled(uint256 id) external view returns (bool status);

  /**
   * @notice Whether the pot was released to the beneficiary.
   * @param id The id of the goal.
   * @return status Whether the pot was released.
   */
  function released(uint256 id) external view returns (bool status);

  /**
   * @notice Whether an invite nonce has been used for a goal.
   * @param id The id of the goal.
   * @param nonce The invite nonce.
   * @return used Whether the nonce has been used.
   */
  function usedNonces(uint256 id, uint256 nonce) external view returns (bool used);
}
