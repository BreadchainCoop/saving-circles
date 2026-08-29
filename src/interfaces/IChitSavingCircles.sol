// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IChitSavingCircles — Variant D, "the foremanless chit"
 * @notice Interface for a permissionless, capital-efficient rotating savings and credit
 *         association (ROSCA) that allocates each round's pot by a sealed-bid reverse auction
 *         and secures it with prize-time, two-tier collateral.
 * @dev This is the "Variant D" design of docs/collateralized-permissionless-circles.md, the
 *      on-chain compilation of the Indian chit fund (Chit Funds Act, 1982). It removes the
 *      baseline {ISavingCircles} trust bound *and* the ~4x over-collateralization of the
 *      fixed-rotation collateral variants, while paying patient members an endogenous interest
 *      rate. A circle runs a single cycle of `numSlots` rounds; every member deposits the
 *      per-round amount `m` every round, and exactly one member is *prized* (wins the pot) per
 *      round, so after `n` rounds everyone has won once.
 *
 *      ## The mechanism, in one screen
 *
 *      Each round `j` (0-indexed) proceeds in two phases inside the round window:
 *        1. *Commit* — members deposit `m` and submit a sealed bid `H(discount, salt)`.
 *        2. *Reveal* — members reveal `(discount, salt)`; the highest revealed discount wins.
 *      After the round closes, anyone calls {award} to settle it (rounds settle strictly in
 *      order). Sealed bids make the auction robust to an adversarial block scheduler: an
 *      open-outcry on-chain auction would hand the sequencer a last-look (censor rivals, snipe
 *      with `d+epsilon`). If nobody bids, the round falls back to fixed rotation (`d = 0`),
 *      so a rotation ROSCA is D's degenerate case.
 *
 *      ## Prize-time two-tier security (the safety core, "Theorem D3")
 *
 *      Only a member who has *already won* can steal — she has taken the pot and still owes her
 *      remaining `(n-1-j)*m` of deposits. So collateral is demanded *only at prize time* and
 *      *only for the exact residual*. At award the winner's bid `d` is **withheld as first-loss
 *      security** rather than paid out, and she locks the remainder in cash:
 *
 *          withheld = d           coll = (n-1-j)*m - d           withheld + coll = residual
 *
 *      A bigger bid means a smaller cash lock; you can never bid away more than you owe
 *      (`d <= (n-1-j)*m`). The invariant `withheld + coll == residual` is preserved every round
 *      (both fall by `m` per settled deposit), so every future pot is made whole against *any*
 *      set of prized defaulters. A would-be thief who bids high merely pre-pays her own
 *      first-loss cover: her realizable theft is `0` whatever she bids.
 *
 *      ## Dividends = endogenous interest ("D6")
 *
 *      As a prized member makes each on-time deposit, a slice of her withheld bid is released
 *      pro-rata to the other members (a credit they can {claim}), and the matching slice of her
 *      cash lock is returned to her. Over her remaining rounds an honest winner pays out exactly
 *      her bid `d` — her interest — and recovers her whole cash lock. Patient members who win
 *      late with low bids are net receivers of interest; impatient early winners pay it.
 *
 *      ## Non-prized default and churn
 *
 *      A member who has *not* won owes nothing she has not already lent; her default is not a
 *      credit event, only a coordination one. She posts a one-round membership `bond` of `m` at
 *      join; a missed deposit is covered from that bond and she is flagged defaulted, freeing
 *      her slot for permissionless {substitute} — a successor posts a fresh bond and assumes the
 *      slot (the Act's ss.28-30). If a defaulted slot is never substituted the circle can no
 *      longer complete a round; anyone may then {abort}, which unwinds every member to net-zero
 *      on principal (deposits + bond back, unrealized prizes clawed back), so no honest member
 *      loses. See {abort}.
 *
 *      ## Scope of this implementation (v1)
 *
 *      This ships the auction, prize-time two-tier security, dividends, prized-default cover,
 *      no-bid rotation fallback, defaulted-slot substitution, and a net-zero abort valve, on a
 *      cohort that is fixed at {start}. Same-asset collateral means net credit is `<= 0` (the
 *      "trilemma" of the spec, Prop. 5.4): this is a commitment-savings + mutual-insurance +
 *      interest-market device, not a lender. Continuous resize and heterogeneous / surety
 *      collateral are documented extension points. The auction must NOT be combined with the
 *      under-collateralized Variant C (adverse selection, spec ss.5.5).
 */
interface IChitSavingCircles {
  /**
   * @notice Lifecycle state of a circle.
   * @dev Open = accepting members, not yet started.
   *      Active = started; the single cycle of `n` rounds is running.
   *      Ended = all `n` rounds have been awarded; members may reclaim bonds and claim balances.
   *      Aborted = a defaulted slot stalled the circle; everyone unwound to net-zero on principal.
   */
  enum CircleState {
    Open,
    Active,
    Ended,
    Aborted
  }

  /**
   * @notice The commit/reveal phase within the current round.
   */
  enum Phase {
    Commit,
    Reveal
  }

  /**
   * @notice Immutable parameters of a circle.
   * @param token The ERC20 token used for deposits, collateral, bonds and payouts.
   * @param depositAmount The per-round deposit amount `m`.
   * @param numSlots The number of member slots `n`; also the number of rounds in the cycle.
   * @param roundDuration The duration of a single round, in seconds.
   * @param revealDuration The length of the reveal phase at the end of each round, in seconds
   *        (`0 < revealDuration < roundDuration`). The commit/deposit phase is the remainder.
   * @param startTime The timestamp at which the circle started (0 until started).
   */
  struct Circle {
    address token;
    uint256 depositAmount;
    uint256 numSlots;
    uint256 roundDuration;
    uint256 revealDuration;
    uint256 startTime;
  }

  // =======================
  // EVENTS
  // =======================

  /// @notice Emitted when a token is allowed or disallowed by the admin.
  event TokenAllowed(address indexed token, bool indexed allowed);

  /// @notice Emitted when a new circle is created.
  event CircleCreated(
    uint256 indexed id,
    address indexed token,
    uint256 depositAmount,
    uint256 numSlots,
    uint256 roundDuration,
    uint256 revealDuration
  );

  /// @notice Emitted when a member claims a slot in a circle (via {join} or {substitute}).
  event MemberJoined(uint256 indexed id, address indexed member, uint256 slot);

  /// @notice Emitted when a circle starts (all slots filled).
  event CircleStarted(uint256 indexed id, uint256 startTime);

  /// @notice Emitted when a member deposits into a round.
  event Deposited(uint256 indexed id, address indexed member, uint256 round, uint256 amount);

  /// @notice Emitted when a member submits a sealed bid commitment for a round.
  event BidCommitted(uint256 indexed id, address indexed member, uint256 round);

  /// @notice Emitted when a member reveals their bid for a round.
  event BidRevealed(uint256 indexed id, address indexed member, uint256 round, uint256 discount);

  /**
   * @notice Emitted when a round's pot is awarded.
   * @param winner The prized member.
   * @param round The round index.
   * @param discount The winning bid, withheld as first-loss security.
   * @param cash The immediate cash paid to the winner's claimable balance (`(round+1)*m`).
   * @param collateral The winner's cash lock (`residual - discount`).
   */
  event Awarded(
    uint256 indexed id, address indexed winner, uint256 round, uint256 discount, uint256 cash, uint256 collateral
  );

  /// @notice Emitted when a prized member's missed deposit is covered from her own security.
  event Covered(uint256 indexed id, address indexed member, uint256 round, uint256 amount);

  /// @notice Emitted when a non-prized member's missed deposit is covered from her bond.
  event BondCovered(uint256 indexed id, address indexed member, uint256 round, uint256 amount);

  /// @notice Emitted when a member is flagged defaulted (her bond was consumed by a cover).
  event MemberDefaulted(uint256 indexed id, address indexed member);

  /**
   * @notice Emitted when a prized member's on-time deposit releases part of her security.
   * @param collReturned The cash lock returned to the member.
   * @param dividend The withheld slice distributed to the other members as interest.
   */
  event SecurityReleased(
    uint256 indexed id, address indexed member, uint256 round, uint256 collReturned, uint256 dividend
  );

  /// @notice Emitted when a defaulted slot is taken over by a successor.
  event MemberSubstituted(uint256 indexed id, address indexed oldMember, address indexed newMember, uint256 slot);

  /// @notice Emitted when a member withdraws their claimable balance.
  event Claimed(uint256 indexed id, address indexed member, uint256 amount);

  /// @notice Emitted when a member reclaims their membership bond after the circle ends.
  event BondReclaimed(uint256 indexed id, address indexed member, uint256 amount);

  /// @notice Emitted when a stalled circle is aborted and unwound.
  event CircleAborted(uint256 indexed id);

  /// @notice Emitted for each member's net-zero refund during an abort.
  event Refunded(uint256 indexed id, address indexed member, uint256 amount);

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
  /// @notice Thrown when the subject is not a member.
  error NotMember();
  /// @notice Thrown when starting a circle that is not yet full.
  error CircleNotFull();
  /// @notice Thrown when acting on a circle in the wrong lifecycle state.
  error WrongState();
  /// @notice Thrown when committing/revealing in the wrong phase of the round.
  error WrongPhase();
  /// @notice Thrown when a deposit would exceed the per-round amount `m`.
  error ExceedsDepositAmount();
  /// @notice Thrown when a bidder is not current (has not fully deposited the round).
  error NotCurrent();
  /// @notice Thrown when a member has already committed a bid for the round.
  error AlreadyCommitted();
  /// @notice Thrown when revealing without a matching commitment.
  error InvalidReveal();
  /// @notice Thrown when a member who has already won attempts to bid.
  error AlreadyPrized();
  /// @notice Thrown when a defaulted member attempts to act where disallowed.
  error MemberIsDefaulted();
  /// @notice Thrown when a bid exceeds the residual cap `(n-1-round)*m`.
  error BidTooHigh();
  /// @notice Thrown when awarding a round whose window has not closed yet.
  error RoundNotClosed();
  /// @notice Thrown when a round cannot be made whole (a defaulted slot with no substitute).
  error NotAwardable();
  /// @notice Thrown when no eligible member remains to receive a round's pot.
  error NoEligibleWinner();
  /// @notice Thrown when aborting a circle that is not actually stalled.
  error NotStuck();
  /// @notice Thrown when there is nothing to claim or reclaim.
  error NothingToClaim();
  /// @notice Thrown when substituting a slot that is not a defaulted, non-prized member.
  error NotSubstitutable();

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
   * @param numSlots The number of slots `n` (>= 2).
   * @param roundDuration The round duration in seconds (> 0).
   * @param revealDuration The reveal-phase length in seconds (`0 < revealDuration < roundDuration`).
   * @return id The id of the new circle.
   */
  function createCircle(
    address token,
    uint256 depositAmount,
    uint256 numSlots,
    uint256 roundDuration,
    uint256 revealDuration
  ) external returns (uint256 id);

  /**
   * @notice Permissionlessly join an open circle, taking the next free slot, posting the
   *         one-round membership bond `m`.
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
   * @notice Submit a sealed bid for the current round during its commit phase.
   * @dev `commitment` MUST equal `keccak256(abi.encode(discount, salt, msg.sender, id, round))`.
   *      The caller must be a non-prized, non-defaulted member who has fully deposited the round.
   * @param id The circle id.
   * @param commitment The sealed bid hash.
   */
  function commitBid(uint256 id, bytes32 commitment) external;

  /**
   * @notice Reveal a previously committed bid during the current round's reveal phase.
   * @param id The circle id.
   * @param discount The bid discount `d`, capped at the residual `(n-1-round)*m`.
   * @param salt The salt used in the commitment.
   */
  function revealBid(uint256 id, uint256 discount, bytes32 salt) external;

  /**
   * @notice Settle the next unawarded round (its window must have closed). Callable by anyone.
   * @dev Rounds settle strictly in order. Completes the pot by covering non-depositors from
   *      their own security (prized) or bond (non-prized), allocates the pot to the winning
   *      bidder (or the rotation fallback), sets the winner's two-tier security, and releases
   *      matured security of earlier winners as dividends.
   * @param id The circle id.
   */
  function award(uint256 id) external;

  /**
   * @notice Withdraw the caller's accrued claimable balance (prize cash, returned collateral,
   *         and dividends).
   * @param id The circle id.
   */
  function claim(uint256 id) external;

  /**
   * @notice Take over a defaulted, non-prized member's slot, posting a fresh membership bond.
   * @dev This is the chit's ss.28-30 substitution: the successor assumes the slot and its future
   *      deposit schedule and prize eligibility; the defaulter's forfeited stake keeps the past
   *      pots whole, so no other member is affected.
   * @param id The circle id.
   * @param oldMember The defaulted member to replace.
   */
  function substitute(uint256 id, address oldMember) external;

  /**
   * @notice Reclaim the caller's membership bond once the circle has ended.
   * @param id The circle id.
   */
  function reclaimBond(uint256 id) external;

  /**
   * @notice Abort a circle that can no longer complete a round (a defaulted slot with no
   *         substitute), refunding every member to net-zero on principal.
   * @dev Callable by anyone, only when stalled. Each member receives
   *      `deposits + bondsPosted - amountsWithdrawn` (>= 0); unrealized prizes are clawed back.
   *      Because every prized member's remaining obligation is fully secured (`withheld + coll ==
   *      residual`), this exactly drains the circle's funds and no honest member loses principal.
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

  /// @notice Returns the current round index (0-based); may exceed `numSlots` once the cycle ends.
  function currentRound(uint256 id) external view returns (uint256 round);

  /// @notice Returns the commit/reveal phase of the current round.
  function currentPhase(uint256 id) external view returns (Phase phase);

  /// @notice Returns the index of the next round awaiting award (equals the count already awarded).
  function awardedCount(uint256 id) external view returns (uint256 count);

  /// @notice Returns the residual cap on a bid for `round`, i.e. `(numSlots - 1 - round) * m`.
  function bidCap(uint256 id, uint256 round) external view returns (uint256 cap);

  /// @notice Returns a member's remaining cash collateral lock.
  function collateralOf(uint256 id, address member) external view returns (uint256 amount);

  /// @notice Returns a member's remaining withheld bid (first-loss security).
  function withheldOf(uint256 id, address member) external view returns (uint256 amount);

  /// @notice Returns a member's remaining membership bond.
  function bondOf(uint256 id, address member) external view returns (uint256 amount);

  /// @notice Returns a member's claimable balance (prize cash + returned collateral + dividends).
  function claimableOf(uint256 id, address member) external view returns (uint256 amount);

  /// @notice Returns a member's outstanding deposit obligation for the rest of the cycle.
  function residualOf(uint256 id, address member) external view returns (uint256 amount);

  /// @notice Returns whether a member has already won (is prized).
  function isPrized(uint256 id, address member) external view returns (bool prized);

  /// @notice Returns whether a member is flagged defaulted.
  function isDefaulted(uint256 id, address member) external view returns (bool defaulted);

  /// @notice Returns whether the next unawarded round can currently be made whole.
  function isAwardable(uint256 id) external view returns (bool awardable);
}
