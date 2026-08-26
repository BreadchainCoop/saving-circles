// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ICollectiveFundCircles
 * @notice A communal savings pot: members deposit flexible amounts, may rage-quit anytime for a
 *         pro-rata share of the remaining pool, and spend the pool collectively via
 *         one-member-one-vote disbursement proposals with a snapshotted electorate.
 * @dev Singleton registry: many funds per contract keyed by uint256 id. White-label friendly —
 *      each fund stores its display name on-chain; a frontend resolves a fund from `?f=<id>`
 *      with a single getFund call. Membership is by fund-owner-signed EIP-712 invite
 *      (domain 'StacksInvite', identical to SavingCircles). Principal-spending by design:
 *      an executed proposal dilutes every shareholder pro-rata (see withdraw).
 */
interface ICollectiveFundCircles {
  /**
   * @notice Lifecycle state of a disbursement proposal (pure function of storage + time).
   * @dev Active = 0 (voting open, threshold not yet reached, still mathematically reachable),
   *      Defeated = 1 (voting closed without reaching threshold, or threshold unreachable),
   *      Passed = 2 (threshold reached, executable, execution window open),
   *      Executed = 3 (funds transferred),
   *      Expired = 4 (threshold reached but nobody executed before the execution deadline).
   */
  enum ProposalState {
    Active,
    Defeated,
    Passed,
    Executed,
    Expired
  }

  /**
   * @notice A collective fund.
   * @param owner The fund organizer: signs invites and may rename the fund
   * @param token The allowlisted ERC20 the fund saves and spends
   * @param votingPeriod Seconds each proposal accepts votes
   * @param approvalThresholdBps Yes-votes required, in basis points of the snapshotted electorate
   * @param totalShares Sum of all member shares (shares mint 1:1 with deposited tokens)
   * @param poolBalance Tokens currently held by this fund (internal accounting)
   * @param proposalCount Number of proposals ever created for this fund
   * @param name On-chain display name for white-label frontends
   */
  struct Fund {
    address owner;
    address token;
    uint256 votingPeriod;
    uint256 approvalThresholdBps;
    uint256 totalShares;
    uint256 poolBalance;
    uint256 proposalCount;
    string name;
  }

  /**
   * @notice A disbursement proposal.
   * @param proposer The member who created the proposal (auto-votes yes)
   * @param recipient The address that receives the funds on execution
   * @param amount The token amount to transfer on execution (checked against poolBalance at
   *        execute time only — proposals do NOT reserve funds)
   * @param createdAt Creation timestamp; voting closes at createdAt + votingPeriod, execution
   *        closes at createdAt + 2 * votingPeriod
   * @param electorate Member count snapshotted at creation (members joining later cannot vote)
   * @param requiredYes Snapshotted ceil(electorate * approvalThresholdBps / 10_000), always >= 1
   * @param yesVotes Yes votes cast
   * @param noVotes No votes cast
   * @param executed Whether the disbursement has been executed
   * @param description Human-readable rationale, stored on-chain for backend-free frontends
   */
  struct Proposal {
    address proposer;
    address recipient;
    uint256 amount;
    uint256 createdAt;
    uint256 electorate;
    uint256 requiredYes;
    uint256 yesVotes;
    uint256 noVotes;
    bool executed;
    string description;
  }

  // =======================
  // EVENTS
  // =======================

  /**
   * @notice Emitted when a token is allowed or disallowed by the contract owner
   * @param token The address of the token
   * @param allowed Whether the token is allowed
   */
  event TokenAllowed(address indexed token, bool indexed allowed);

  /**
   * @notice Emitted when a fund is created
   * @param id The ID of the fund
   * @param owner The fund organizer
   * @param token The fund's token
   * @param name The fund's display name
   * @param votingPeriod The proposal voting period in seconds
   * @param approvalThresholdBps The approval threshold in basis points of the electorate
   */
  event FundCreated(
    uint256 indexed id,
    address indexed owner,
    address indexed token,
    string name,
    uint256 votingPeriod,
    uint256 approvalThresholdBps
  );

  /**
   * @notice Emitted when an invite is successfully redeemed (identical shape to SavingCircles)
   * @param id The ID of the fund
   * @param redeemer The new member
   */
  event InviteRedeemed(uint256 indexed id, address indexed redeemer);

  /**
   * @notice Emitted when a member deposits into a fund (shares minted 1:1 with amount)
   * @param id The ID of the fund
   * @param member The depositing member
   * @param amount The token amount deposited (== shares minted)
   */
  event FundsDeposited(uint256 indexed id, address indexed member, uint256 amount);

  /**
   * @notice Emitted when anyone donates to a fund (no shares minted)
   * @param id The ID of the fund
   * @param donor The donor
   * @param amount The token amount donated
   */
  event FundsDonated(uint256 indexed id, address indexed donor, uint256 amount);

  /**
   * @notice Emitted when a member burns shares for their pro-rata payout
   * @param id The ID of the fund
   * @param member The withdrawing member
   * @param shares The shares burned
   * @param amount The tokens paid out (floor(shares * poolBalance / totalShares))
   */
  event FundsWithdrawn(uint256 indexed id, address indexed member, uint256 shares, uint256 amount);

  /**
   * @notice Emitted when the fund owner renames the fund
   * @param id The ID of the fund
   * @param name The new display name
   */
  event FundNameUpdated(uint256 indexed id, string name);

  /**
   * @notice Emitted when a proposal is created
   * @param id The ID of the fund
   * @param proposalId The per-fund proposal ID
   * @param proposer The proposing member
   * @param recipient The disbursement recipient
   * @param amount The disbursement amount
   * @param description The proposal rationale
   */
  event ProposalCreated(
    uint256 indexed id,
    uint256 indexed proposalId,
    address indexed proposer,
    address recipient,
    uint256 amount,
    string description
  );

  /**
   * @notice Emitted when a member casts a vote
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   * @param voter The voting member
   * @param support True for yes, false for no
   */
  event VoteCast(uint256 indexed id, uint256 indexed proposalId, address indexed voter, bool support);

  /**
   * @notice Emitted when a passed proposal is executed
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   * @param recipient The recipient paid
   * @param amount The amount transferred
   */
  event ProposalExecuted(uint256 indexed id, uint256 indexed proposalId, address recipient, uint256 amount);

  // =======================
  // ERRORS
  // =======================

  /// @notice Thrown when a token is not on the allowlist
  error TokenNotAllowed();
  /// @notice Thrown when acting on a fund id that does not exist
  error FundNotFound();
  /// @notice Thrown when creating a fund with a zero owner address
  error InvalidFundOwner();
  /// @notice Thrown when a fund name is empty
  error InvalidName();
  /// @notice Thrown when the voting period is zero or exceeds MAX_VOTING_PERIOD
  error InvalidVotingPeriod();
  /// @notice Thrown when the approval threshold is zero or exceeds MAX_BPS
  error InvalidThreshold();
  /// @notice Thrown when the caller/subject is not a member of the fund
  error NotMember();
  /// @notice Thrown when the caller is already a member of the fund
  error AlreadyMember();
  /// @notice Thrown when an invite nonce has already been used
  error InviteAlreadyUsed();
  /// @notice Thrown when the signer of an invite is not the fund owner
  error InvalidSigner();
  /// @notice Thrown when the caller is not the fund owner
  error NotFundOwner();
  /// @notice Thrown when a token or share amount is zero
  error InvalidAmount();
  /// @notice Thrown when a member tries to burn more shares than they hold
  error InsufficientShares();
  /// @notice Thrown when a proposal recipient is the zero address or the contract itself
  error InvalidRecipient();
  /// @notice Thrown when acting on a proposal id that does not exist
  error ProposalNotFound();
  /// @notice Thrown when voting after the voting deadline or on an executed proposal
  error VotingClosed();
  /// @notice Thrown when a voter joined after the proposal's electorate snapshot
  error NotEligible();
  /// @notice Thrown when a member votes twice on the same proposal
  error AlreadyVoted();
  /// @notice Thrown when executing a proposal that has not reached its threshold
  error ProposalNotPassed();
  /// @notice Thrown when executing an already-executed proposal
  error ProposalAlreadyExecuted();
  /// @notice Thrown when executing after the execution deadline
  error ProposalExpired();
  /// @notice Thrown when the fund's pool cannot cover the proposal amount at execution time
  error InsufficientPoolBalance();

  // =======================
  // FUNCTIONS
  // =======================

  /**
   * @notice Initialize the upgradeable contract
   * @param owner The contract admin (manages the token allowlist)
   */
  function initialize(address owner) external;

  /**
   * @notice Allow or disallow a token for new funds
   * @dev Owner-only. The allowlist is the control for weird-decimals / fee-on-transfer /
   *      rebasing tokens, which are out of scope by policy; it gates creation of new funds only.
   * @param token The address of the token
   * @param allowed Whether the token is allowed
   */
  function setTokenAllowed(address token, bool allowed) external;

  /**
   * @notice Create a fund. Permissionless; `fundOwner` becomes the first member (index 0).
   * @param token The allowlisted ERC20 the fund uses
   * @param fundOwner The organizer who signs invites and may rename the fund
   * @param name The on-chain display name (non-empty)
   * @param votingPeriod Proposal voting window in seconds (0 < x <= MAX_VOTING_PERIOD)
   * @param approvalThresholdBps Approval threshold in bps of the electorate (0 < x <= 10_000)
   * @return id The ID of the new fund
   */
  function create(
    address token,
    address fundOwner,
    string calldata name,
    uint256 votingPeriod,
    uint256 approvalThresholdBps
  ) external returns (uint256 id);

  /**
   * @notice Join a fund by redeeming an invite signed by the fund owner
   * @dev EIP-712 domain 'StacksInvite' v1, typehash Invite(uint256 id,uint256 nonce) —
   *      byte-identical flow to SavingCircles.redeemInvite. Redeemable at any time in the
   *      fund's life (funds are perpetual; there is no start/active gate).
   * @param id The ID of the fund
   * @param nonce Unique nonce for the invite
   * @param signature The fund owner's EIP-712 signature
   */
  function redeemInvite(uint256 id, uint256 nonce, bytes calldata signature) external;

  /**
   * @notice Deposit tokens into the fund; mints shares 1:1 with the amount
   * @dev Member-only. If the fund has previously disbursed (poolBalance < totalShares), a new
   *      deposit is immediately worth less than 1:1 on withdrawal — dilution is shared equally
   *      per contributed token, not by timing. See withdraw.
   * @param id The ID of the fund
   * @param amount The token amount to deposit (> 0)
   */
  function deposit(uint256 id, uint256 amount) external;

  /**
   * @notice Donate tokens to the fund without receiving shares (open to anyone)
   * @dev Donations raise poolBalance only; they accrue pro-rata to current shareholders and are
   *      spendable by proposals. ERC20s sent directly to the contract are NOT credited.
   * @param id The ID of the fund
   * @param amount The token amount to donate (> 0)
   */
  function donate(uint256 id, uint256 amount) external;

  /**
   * @notice Rage-quit: burn shares for a pro-rata slice of the current pool, anytime
   * @dev Pays floor(shares * poolBalance / totalShares). After disbursements this is < 1 token
   *      per share — pro-rata-at-time-of-withdrawal semantics; the contract makes no promise of
   *      1:1 redemption, only of the pro-rata share of what remains. Burning zero-value shares
   *      when poolBalance == 0 is permitted (share-base reset). No lock, no delay: rage-quit
   *      freedom is the trust anchor; an approved proposal does NOT reserve funds against it.
   * @param id The ID of the fund
   * @param shares The shares to burn (> 0, <= sharesOf(id, msg.sender))
   */
  function withdraw(uint256 id, uint256 shares) external;

  /**
   * @notice Propose a disbursement from the fund's pool
   * @dev Member-only. Snapshots electorate = current member count and
   *      requiredYes = ceil(electorate * approvalThresholdBps / 10_000). The proposer
   *      automatically votes yes (a single-member fund passes instantly). The amount is NOT
   *      checked against poolBalance here and is NOT reserved.
   * @param id The ID of the fund
   * @param recipient The address to pay (non-zero, not this contract)
   * @param amount The token amount to pay (> 0)
   * @param description Human-readable rationale, stored on-chain
   * @return proposalId The per-fund ID of the new proposal
   */
  function propose(
    uint256 id,
    address recipient,
    uint256 amount,
    string calldata description
  ) external returns (uint256 proposalId);

  /**
   * @notice Cast a one-member-one-vote ballot on a proposal
   * @dev Eligible voters are members whose memberIndex < proposal.electorate (the creation-time
   *      snapshot). Voting is open until createdAt + votingPeriod and while unexecuted; no
   *      recasting. No-votes never block execution (threshold counts yes-votes only) but enable
   *      early mathematical defeat detection in proposalState.
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   * @param support True for yes, false for no
   */
  function vote(uint256 id, uint256 proposalId, bool support) external;

  /**
   * @notice Execute a passed proposal: transfer amount to recipient. Callable by ANYONE.
   * @dev Executable as soon as yesVotes >= requiredYes (early execution — no need to wait out
   *      the voting window) and until createdAt + 2 * votingPeriod. Reverts with
   *      InsufficientPoolBalance if rage-quits (or prior proposals) drained the pool below the
   *      amount; the proposal stays Passed and may execute later within the window if the pool
   *      refills.
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   */
  function execute(uint256 id, uint256 proposalId) external;

  /**
   * @notice Update the fund's on-chain display name (fund owner only)
   * @param id The ID of the fund
   * @param name The new display name (non-empty)
   */
  function setFundName(uint256 id, string calldata name) external;

  // =======================
  // VIEWS
  // =======================

  /**
   * @notice Get a fund's full config and accounting (the one-call `?f=<id>` resolver)
   * @param id The ID of the fund
   * @return fund The fund
   */
  function getFund(uint256 id) external view returns (Fund memory fund);

  /**
   * @notice Get multiple funds
   * @param ids The fund IDs
   * @return result The funds (zeroed entries for nonexistent ids)
   */
  function getFunds(uint256[] calldata ids) external view returns (Fund[] memory result);

  /**
   * @notice Get the ordered member list of a fund
   * @param id The ID of the fund
   * @return members The members in join order
   */
  function getFundMembers(uint256 id) external view returns (address[] memory members);

  /**
   * @notice Get all fund IDs an address is a member of
   * @param member The address
   * @return ids The fund IDs
   */
  function getMemberFunds(address member) external view returns (uint256[] memory ids);

  /**
   * @notice Check memberships across funds (parity with SavingCircles for app-stacks)
   * @param member The address
   * @param ids The fund IDs to check
   * @return memberships Whether the address is a member of each fund
   */
  function checkMemberships(address member, uint256[] calldata ids) external view returns (bool[] memory memberships);

  /**
   * @notice Get a proposal
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   * @return proposal The proposal
   */
  function getProposal(uint256 id, uint256 proposalId) external view returns (Proposal memory proposal);

  /**
   * @notice Get all proposals of a fund
   * @param id The ID of the fund
   * @return result The proposals in creation order
   */
  function getProposals(uint256 id) external view returns (Proposal[] memory result);

  /**
   * @notice Compute the lifecycle state of a proposal (see ProposalState)
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   * @return state The proposal state
   */
  function proposalState(uint256 id, uint256 proposalId) external view returns (ProposalState state);

  /**
   * @notice Whether execute would currently succeed (readiness gate for keepers/frontends)
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   * @return executable True iff state is Passed AND poolBalance >= amount
   */
  function isExecutable(uint256 id, uint256 proposalId) external view returns (bool executable);

  /**
   * @notice A member's current redeemable value if they burned all their shares now
   * @dev floor(sharesOf * poolBalance / totalShares); 0 when totalShares == 0
   * @param id The ID of the fund
   * @param member The member
   * @return amount The redeemable token amount
   */
  function previewWithdraw(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Get the next ID that will be assigned to a new fund
   * @return id The next fund ID
   */
  function nextId() external view returns (uint256 id);

  /**
   * @notice Check if a token is allowed
   * @param token The address of the token
   * @return allowed Whether the token is allowed
   */
  function isTokenAllowed(address token) external view returns (bool allowed);

  /**
   * @notice Whether an address is a member of a fund
   * @param id The ID of the fund
   * @param member The address
   * @return status Whether the address is a member
   */
  function isMember(uint256 id, address member) external view returns (bool status);

  /**
   * @notice A member's share balance in a fund
   * @param id The ID of the fund
   * @param member The member
   * @return shares The member's shares
   */
  function sharesOf(uint256 id, address member) external view returns (uint256 shares);

  /**
   * @notice A member's index in the fund's append-only member list
   * @param id The ID of the fund
   * @param member The member
   * @return index The member's index (fund owner is index 0)
   */
  function memberIndex(uint256 id, address member) external view returns (uint256 index);

  /**
   * @notice Whether a voter has voted on a proposal
   * @param id The ID of the fund
   * @param proposalId The proposal ID
   * @param voter The voter
   * @return voted Whether the voter has voted
   */
  function hasVoted(uint256 id, uint256 proposalId, address voter) external view returns (bool voted);

  /**
   * @notice Whether an invite nonce has been consumed for a fund
   * @param id The ID of the fund
   * @param nonce The invite nonce
   * @return used Whether the nonce has been used
   */
  function usedNonces(uint256 id, uint256 nonce) external view returns (bool used);
}
