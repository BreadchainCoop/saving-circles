// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IMicroloans
 * @notice Interface for step-up microloans: a lender offers a zero-interest loan to a named borrower
 *         and escrows an optional follow-on grant that unlocks once the loan is repaid in full.
 *         The lender funds everything at create(), the borrower accepts the exact terms on-chain,
 *         repays in any amounts, and the grant releases to the borrower as soon as cumulative
 *         repayments reach the principal. If the borrower is late, the lender may reclaim the
 *         grant; the principal remains owed and can still be repaid.
 * @dev While money waits in escrow (the principal before acceptance, the grant until it is paid
 *      or reclaimed) it can sit in an admin-allowlisted ERC-4626 vault, such as a wrapped Aave
 *      v3 position, so it earns yield. All yield belongs to the lender. A loan's vault is fixed
 *      at create().
 */
interface IMicroloans {
  /**
   * @notice Lifecycle state of a loan (derived, see loanState()).
   * @dev Offered = 0 funded and waiting for the borrower to accept, before acceptBy.
   *      Expired = 1 not accepted by acceptBy; the lender can cancel for a full refund.
   *      Cancelled = 2 the lender withdrew the offer before acceptance. Terminal.
   *      Active = 3 accepted, principal not fully repaid, before repayBy.
   *      Overdue = 4 accepted, principal not fully repaid, at/after repayBy; the lender may
   *                 reclaim the grant, and the borrower may still repay and claim it until then.
   *      Repaid = 5 principal fully repaid; the grant is waiting to be released to the borrower.
   *      Completed = 6 principal repaid and the grant (if any) paid to the borrower. Terminal.
   *      Defaulted = 7 the lender reclaimed the grant while the loan was Overdue. Terminal for the
   *                   grant; any remaining principal can still be repaid.
   */
  enum LoanState {
    Offered,
    Expired,
    Cancelled,
    Active,
    Overdue,
    Repaid,
    Completed,
    Defaulted
  }

  /**
   * @notice Immutable terms of a loan, fixed at create().
   * @param token The allowlisted ERC20 used for every transfer (e.g. USDT on Celo).
   * @param vault An allowlisted ERC-4626 vault whose asset is `token`, holding escrowed funds so
   *        they earn yield; address(0) keeps escrow as plain token balance.
   * @param principal The amount lent to the borrower on acceptance (> 0).
   * @param grant The amount released to the borrower once the principal is repaid; 0 makes this a
   *        plain zero-interest microloan.
   * @param acceptBy Unix timestamp; the borrower must accept strictly before it.
   * @param repaymentPeriod Seconds after acceptance until the loan becomes Overdue (> 0).
   * @param termsHash Hash of the off-chain agreement (e.g. an IPFS document) the borrower signs
   *        up to by passing the same hash to accept(). May be zero if no document is used.
   */
  struct LoanTerms {
    address token;
    address vault;
    uint256 principal;
    uint256 grant;
    uint256 acceptBy;
    uint256 repaymentPeriod;
    bytes32 termsHash;
  }

  /**
   * @notice Mutable bookkeeping of a loan.
   * @param lender The creator and funder of the loan.
   * @param borrower The only address that can accept; may be set after create() if left empty.
   * @param acceptedAt Acceptance timestamp, 0 until accepted.
   * @param repayBy Timestamp at which an unpaid loan becomes Overdue, 0 until accepted. The lender
   *        may push it later with extendRepayBy().
   * @param disbursed Tokens actually paid to the borrower on acceptance. Equals principal unless
   *        the vault lost value, in which case the borrower only owes what they received.
   * @param repaid Cumulative principal repaid (never exceeds disbursed).
   * @param held Escrow held for this loan: vault shares when a vault is set, otherwise tokens.
   * @param lenderOwed Tokens credited to the lender (repayments and yield) not yet collected.
   * @param cancelled Whether the lender cancelled before acceptance.
   * @param grantPaid Whether the grant was released to the borrower.
   * @param grantReclaimed Whether the lender reclaimed the grant after the loan went Overdue.
   */
  struct LoanStatus {
    address lender;
    address borrower;
    uint256 acceptedAt;
    uint256 repayBy;
    uint256 disbursed;
    uint256 repaid;
    uint256 held;
    uint256 lenderOwed;
    bool cancelled;
    bool grantPaid;
    bool grantReclaimed;
  }

  // =======================
  // EVENTS
  // =======================

  /**
   * @notice Emitted when the admin allows or disallows a token for new loans.
   * @param token The token address.
   * @param allowed Whether the token is now allowed.
   */
  event TokenAllowed(address indexed token, bool indexed allowed);

  /**
   * @notice Emitted when the admin allows or disallows an ERC-4626 vault for new loans.
   * @param vault The vault address.
   * @param allowed Whether the vault is now allowed.
   */
  event VaultAllowed(address indexed vault, bool indexed allowed);

  /**
   * @notice Emitted when a lender creates and funds a loan offer.
   * @param id The new loan id.
   * @param lender The lender.
   * @param borrower The named borrower, or address(0) if it will be set later.
   * @param terms The loan terms.
   */
  event LoanCreated(uint256 indexed id, address indexed lender, address indexed borrower, LoanTerms terms);

  /**
   * @notice Emitted when the lender names the borrower of an offer created without one.
   * @param id The loan id.
   * @param borrower The borrower.
   */
  event BorrowerSet(uint256 indexed id, address indexed borrower);

  /**
   * @notice Emitted when the lender cancels an offer and is refunded.
   * @param id The loan id.
   * @param refunded Tokens returned to the lender, including any yield.
   */
  event LoanCancelled(uint256 indexed id, uint256 refunded);

  /**
   * @notice Emitted when the borrower accepts the terms and receives the principal.
   * @param id The loan id.
   * @param borrower The borrower.
   * @param disbursed Tokens paid to the borrower.
   * @param repayBy The timestamp at which the loan becomes Overdue.
   */
  event LoanAccepted(uint256 indexed id, address indexed borrower, uint256 disbursed, uint256 repayBy);

  /**
   * @notice Emitted when principal is repaid.
   * @param id The loan id.
   * @param payer The address that paid (the borrower or anyone on their behalf).
   * @param amount Tokens applied to the principal.
   * @param totalRepaid Cumulative principal repaid after this payment.
   */
  event Repaid(uint256 indexed id, address indexed payer, uint256 amount, uint256 totalRepaid);

  /**
   * @notice Emitted when the grant is released to the borrower.
   * @param id The loan id.
   * @param borrower The borrower.
   * @param amount Tokens paid to the borrower.
   */
  event GrantReleased(uint256 indexed id, address indexed borrower, uint256 amount);

  /**
   * @notice Emitted when the lender reclaims the grant of an Overdue loan.
   * @param id The loan id.
   * @param amount Tokens returned to the lender, including any yield.
   */
  event GrantReclaimed(uint256 indexed id, uint256 amount);

  /**
   * @notice Emitted when the lender moves the repayment deadline later.
   * @param id The loan id.
   * @param repayBy The new deadline.
   */
  event RepayByExtended(uint256 indexed id, uint256 repayBy);

  /**
   * @notice Emitted when yield earned on escrow is credited to the lender.
   * @param id The loan id.
   * @param amount Tokens credited.
   */
  event YieldCredited(uint256 indexed id, uint256 amount);

  /**
   * @notice Emitted when the lender's credited repayments and yield are paid out.
   * @param id The loan id.
   * @param lender The lender.
   * @param amount Tokens paid.
   */
  event LenderCollected(uint256 indexed id, address indexed lender, uint256 amount);

  // =======================
  // ERRORS
  // =======================

  /// @notice Thrown when a token is not allowlisted
  error TokenNotAllowed();

  /// @notice Thrown when a vault is not allowlisted or its asset is not the loan token
  error InvalidVault();

  /// @notice Thrown when the principal is zero
  error InvalidPrincipal();

  /// @notice Thrown when acceptBy is not in the future
  error InvalidAcceptBy();

  /// @notice Thrown when the repayment period is zero, or an extension does not move repayBy later
  error InvalidRepaymentPeriod();

  /// @notice Thrown when a borrower address is zero or the lender itself
  error InvalidBorrower();

  /// @notice Thrown when the borrower is already set
  error BorrowerAlreadySet();

  /// @notice Thrown when a loan id does not exist
  error LoanNotFound();

  /// @notice Thrown when the caller is not the lender
  error NotLender();

  /// @notice Thrown when the caller is not the borrower
  error NotBorrower();

  /// @notice Thrown when the passed terms hash does not match the loan
  error TermsMismatch();

  /// @notice Thrown when the loan is not in a state that allows the action
  error InvalidState();

  /// @notice Thrown when a repayment amount is zero
  error InvalidAmount();

  /// @notice Thrown when there is nothing to collect
  error NothingToCollect();

  // =======================
  // ADMIN
  // =======================

  /**
   * @notice Initialize the contract behind its proxy.
   * @param owner The admin that manages the token and vault allowlists.
   */
  function initialize(address owner) external;

  /**
   * @notice Allow or disallow a token for new loans.
   * @dev Fee-on-transfer and rebasing tokens must never be allowed. Existing loans are unaffected.
   * @param token The token.
   * @param allowed Whether to allow it.
   */
  function setTokenAllowed(address token, bool allowed) external;

  /**
   * @notice Allow or disallow an ERC-4626 vault for new loans.
   * @dev Only vaults that do not charge withdrawal fees should be allowed. Existing loans keep
   *      the vault they were created with.
   * @param vault The vault.
   * @param allowed Whether to allow it.
   */
  function setVaultAllowed(address vault, bool allowed) external;

  // =======================
  // LENDER
  // =======================

  /**
   * @notice Create a loan offer, pulling principal + grant from the caller, who becomes the lender.
   * @param terms The loan terms.
   * @param borrower The borrower who may accept, or address(0) to name them later with setBorrower().
   * @return id The new loan id.
   */
  function create(LoanTerms calldata terms, address borrower) external returns (uint256 id);

  /**
   * @notice Name the borrower of an offer created without one.
   * @param id The loan id.
   * @param borrower The borrower.
   */
  function setBorrower(uint256 id, address borrower) external;

  /**
   * @notice Cancel an offer that has not been accepted (Offered or Expired), refunding the lender.
   * @param id The loan id.
   */
  function cancel(uint256 id) external;

  /**
   * @notice Reclaim the grant of an Overdue loan. The principal stays owed.
   * @param id The loan id.
   */
  function reclaimGrant(uint256 id) external;

  /**
   * @notice Move the repayment deadline later, e.g. to give the borrower more time.
   * @param id The loan id.
   * @param newRepayBy The new deadline; must be later than the current one.
   */
  function extendRepayBy(uint256 id, uint256 newRepayBy) external;

  /**
   * @notice Pay the lender all credited repayments and yield. Callable by anyone.
   * @param id The loan id.
   */
  function collect(uint256 id) external;

  // =======================
  // BORROWER
  // =======================

  /**
   * @notice Accept the loan terms and receive the principal.
   * @param id The loan id.
   * @param termsHash Must equal the loan's termsHash, proving which agreement was accepted.
   */
  function accept(uint256 id, bytes32 termsHash) external;

  /**
   * @notice Repay principal. Callable by anyone on the borrower's behalf. Payments above the
   *         outstanding amount are capped, so only what is owed is pulled.
   * @param id The loan id.
   * @param amount The maximum amount to repay.
   */
  function repay(uint256 id, uint256 amount) external;

  /**
   * @notice Release the grant to the borrower once the principal is fully repaid. Callable by
   *         anyone; the grant always goes to the borrower.
   * @param id The loan id.
   */
  function releaseGrant(uint256 id) external;

  // =======================
  // VIEWS
  // =======================

  /**
   * @notice Get the next id that will be assigned.
   * @return nextId The next id.
   */
  function nextId() external view returns (uint256 nextId);

  /**
   * @notice Get a loan's terms and status.
   * @param id The loan id.
   * @return terms The immutable terms.
   * @return status The mutable status.
   */
  function getLoan(uint256 id) external view returns (LoanTerms memory terms, LoanStatus memory status);

  /**
   * @notice Get the derived lifecycle state of a loan.
   * @param id The loan id.
   * @return state The state.
   */
  function loanState(uint256 id) external view returns (LoanState state);

  /**
   * @notice Get the principal still owed: disbursed minus repaid (0 before acceptance).
   * @param id The loan id.
   * @return amount The outstanding principal.
   */
  function outstanding(uint256 id) external view returns (uint256 amount);

  /**
   * @notice Get the current token value of this loan's escrow, including unrealized yield.
   * @param id The loan id.
   * @return amount The escrow value in tokens.
   */
  function escrowValue(uint256 id) external view returns (uint256 amount);

  /**
   * @notice Get all loan ids created by a lender.
   * @param lender The lender.
   * @return ids The loan ids.
   */
  function getLenderLoans(address lender) external view returns (uint256[] memory ids);

  /**
   * @notice Get all loan ids naming a borrower.
   * @param borrower The borrower.
   * @return ids The loan ids.
   */
  function getBorrowerLoans(address borrower) external view returns (uint256[] memory ids);

  /**
   * @notice Check whether a token is allowed for new loans.
   * @param token The token.
   * @return allowed Whether it is allowed.
   */
  function isTokenAllowed(address token) external view returns (bool allowed);

  /**
   * @notice Check whether a vault is allowed for new loans.
   * @param vault The vault.
   * @return allowed Whether it is allowed.
   */
  function isVaultAllowed(address vault) external view returns (bool allowed);
}
