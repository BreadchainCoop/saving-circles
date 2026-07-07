// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IAccumulatingSavingCircles
 * @notice Interface for an Accumulating Savings and Credit Association (ASCA): members deposit
 *         flexible amounts into a shared pool, earn a credit line proportional to their own
 *         savings, borrow against it, and repay within a fixed number of periods with optional
 *         simple interest. Interest is streamed pro-rata to savers via a MasterChef-style
 *         per-share accumulator. Loans are always fully self-collateralized by the borrower's
 *         own savings (borrowLimitBps <= 10_000), so no honest member can lose principal.
 */
interface IAccumulatingSavingCircles {
  // =======================
  // STRUCTS
  // =======================

  /**
   * @notice Configuration and lifecycle of a fund.
   * @param owner The fund organizer: signs EIP-712 invites and may deactivate the fund.
   * @param token The ERC20 token of the fund (must be allowlisted at creation).
   * @param borrowLimitBps Credit line in basis points of a member's savings; <= 10_000 (100%).
   * @param interestRateBps Simple interest per whole period on outstanding principal, in bps; <= 10_000.
   * @param repaymentPeriods Number of periods after which a loan is due; in [1, 1_000]. Interest
   *        accrual is capped at this many periods.
   * @param periodLength Seconds per period; in [1, 365 days].
   * @param deactivated Whether the organizer has irreversibly frozen deposits, borrows and invites.
   */
  struct Fund {
    address owner;
    address token;
    uint256 borrowLimitBps;
    uint256 interestRateBps;
    uint256 repaymentPeriods;
    uint256 periodLength;
    bool deactivated;
  }

  /**
   * @notice A member's single open loan position.
   * @param principal Outstanding principal; 0 means no open loan.
   * @param interestOwed Accrued, unpaid interest as of the last accrual checkpoint.
   * @param periodsAccrued Whole periods already accounted in interestOwed (capped at repaymentPeriods).
   * @param startTime Timestamp of the borrow; due date = startTime + repaymentPeriods * periodLength.
   */
  struct Loan {
    uint256 principal;
    uint256 interestOwed;
    uint256 periodsAccrued;
    uint256 startTime;
  }

  // =======================
  // EVENTS
  // =======================

  /// @notice Emitted when a token is allowed or disallowed by the contract owner.
  event TokenAllowed(address indexed token, bool indexed allowed);

  /**
   * @notice Emitted when a fund is created.
   * @param id The fund id.
   * @param owner The organizer (msg.sender at create).
   * @param token The fund token.
   * @param borrowLimitBps The credit-line percentage in bps.
   * @param interestRateBps The per-period simple interest rate in bps.
   * @param repaymentPeriods The loan tenor in periods.
   * @param periodLength Seconds per period.
   */
  event FundCreated(
    uint256 indexed id,
    address indexed owner,
    address indexed token,
    uint256 borrowLimitBps,
    uint256 interestRateBps,
    uint256 repaymentPeriods,
    uint256 periodLength
  );

  /// @notice Emitted when an invite is redeemed and the redeemer becomes a member.
  event InviteRedeemed(uint256 indexed id, address indexed redeemer);

  /// @notice Emitted when savings are deposited for a member.
  event SavingsDeposited(uint256 indexed id, address indexed member, uint256 amount);

  /// @notice Emitted when a member withdraws savings.
  event SavingsWithdrawn(uint256 indexed id, address indexed member, uint256 amount);

  /**
   * @notice Emitted when a member opens a loan.
   * @param id The fund id.
   * @param member The borrower.
   * @param amount The principal borrowed.
   * @param dueDate Timestamp after which the loan is liquidatable.
   */
  event Borrowed(uint256 indexed id, address indexed member, uint256 amount, uint256 dueDate);

  /**
   * @notice Emitted when a member repays; interest is settled before principal.
   * @param id The fund id.
   * @param member The borrower.
   * @param interestPaid Portion of the payment applied to accrued interest.
   * @param principalPaid Portion of the payment applied to principal.
   */
  event Repaid(uint256 indexed id, address indexed member, uint256 interestPaid, uint256 principalPaid);

  /**
   * @notice Emitted when received or seized interest is distributed to savers via the accumulator.
   * @param id The fund id.
   * @param amount The interest amount distributed (floor-rounded dust stays in the pool).
   */
  event InterestDistributed(uint256 indexed id, uint256 amount);

  /// @notice Emitted when a member claims their settled + pending interest.
  event InterestClaimed(uint256 indexed id, address indexed member, uint256 amount);

  /**
   * @notice Emitted when an overdue loan is liquidated by seizing the borrower's savings.
   * @param id The fund id.
   * @param member The liquidated borrower.
   * @param principalSeized Savings seized to extinguish the principal (always == principal).
   * @param interestSeized Savings seized and distributed to savers as interest (may be < interestOwed).
   */
  event Liquidated(uint256 indexed id, address indexed member, uint256 principalSeized, uint256 interestSeized);

  /// @notice Emitted when the organizer deactivates a fund.
  event FundDeactivated(uint256 indexed id);

  // =======================
  // ERRORS
  // =======================

  /// @notice Thrown when the token is not on the allowlist.
  error TokenNotAllowed();
  /// @notice Thrown when a fund creation parameter is out of range.
  error InvalidParameters();
  /// @notice Thrown when acting on a fund id that does not exist.
  error FundNotFound();
  /// @notice Thrown when depositing, borrowing or joining a deactivated fund.
  error FundNotActive();
  /// @notice Thrown when a fund-owner-only action is called by someone else.
  error NotFundOwner();
  /// @notice Thrown when the subject is not a member of the fund.
  error NotMember();
  /// @notice Thrown when the caller is already a member of the fund.
  error AlreadyMember();
  /// @notice Thrown when an invite signature does not recover to the fund owner.
  error InvalidSigner();
  /// @notice Thrown when an invite nonce has already been used.
  error InviteAlreadyUsed();
  /// @notice Thrown when an amount parameter is zero.
  error ZeroAmount();
  /// @notice Thrown when a withdrawal exceeds the member's savings.
  error InsufficientSavings();
  /// @notice Thrown when the pool does not hold enough cash for the transfer.
  error InsufficientLiquidity();
  /// @notice Thrown when a borrow would exceed the member's credit line.
  error ExceedsCreditLine();
  /// @notice Thrown when borrowing while a loan is still open.
  error OutstandingLoan();
  /// @notice Thrown when repaying or liquidating with no open loan.
  error NoActiveLoan();
  /// @notice Thrown when a withdrawal would leave the debt under-collateralized.
  error InsufficientCollateral();
  /// @notice Thrown when liquidating a loan that is not overdue.
  error NotLiquidatable();
  /// @notice Thrown when claiming interest with nothing to claim.
  error NothingToClaim();

  // =======================
  // ADMIN
  // =======================

  /**
   * @notice Initialize the upgradeable contract.
   * @param owner The contract admin that manages the token allowlist.
   */
  function initialize(address owner) external;

  /**
   * @notice Allow or disallow a token for use in new funds.
   * @dev Weird tokens (fee-on-transfer, rebasing, non-standard decimals, ERC777 hooks) are out of
   *      scope by policy: this allowlist is the control.
   * @param token The token address.
   * @param allowed Whether the token is allowed.
   */
  function setTokenAllowed(address token, bool allowed) external;

  // =======================
  // LIFECYCLE
  // =======================

  /**
   * @notice Create a fund. The caller becomes the fund owner (organizer) and its first member.
   * @param token The ERC20 token (must be allowlisted).
   * @param borrowLimitBps Credit line in bps of a member's savings (0..10_000; 0 = savings-only fund).
   * @param interestRateBps Simple interest per period in bps (0..10_000).
   * @param repaymentPeriods Loan tenor in periods (1..1_000).
   * @param periodLength Seconds per period (1..365 days).
   * @return id The id of the new fund.
   */
  function create(
    address token,
    uint256 borrowLimitBps,
    uint256 interestRateBps,
    uint256 repaymentPeriods,
    uint256 periodLength
  ) external returns (uint256 id);

  /**
   * @notice Join a fund by redeeming an EIP-712 invite signed by the fund owner.
   * @dev Same 'StacksInvite' domain and Invite(uint256 id,uint256 nonce) typehash as SavingCircles.
   *      Joining is allowed any time while the fund is active (continuous membership).
   * @param id The fund id.
   * @param nonce Unique invite nonce.
   * @param signature The fund owner's EIP-712 signature.
   */
  function redeemInvite(uint256 id, uint256 nonce, bytes calldata signature) external;

  /**
   * @notice Irreversibly deactivate a fund: blocks deposit/depositFor/borrow/redeemInvite.
   *         withdraw, repay, claimInterest and liquidate remain available so everyone can exit.
   * @dev Only the fund owner.
   * @param id The fund id.
   */
  function deactivate(uint256 id) external;

  // =======================
  // SAVINGS
  // =======================

  /**
   * @notice Deposit any amount of savings for the caller.
   * @param id The fund id.
   * @param amount The amount to deposit (> 0).
   */
  function deposit(uint256 id, uint256 amount) external;

  /**
   * @notice Deposit savings for another member, funded by the caller.
   * @param id The fund id.
   * @param member The member to credit (must be a member).
   * @param amount The amount to deposit (> 0).
   */
  function depositFor(uint256 id, address member, uint256 amount) external;

  /**
   * @notice Withdraw savings. Reverts if the remaining savings would no longer collateralize the
   *         caller's outstanding debt (principal + accrued interest) at borrowLimitBps, or if the
   *         pool lacks cash.
   * @param id The fund id.
   * @param amount The amount to withdraw (> 0).
   */
  function withdraw(uint256 id, uint256 amount) external;

  /**
   * @notice Claim all of the caller's settled and pending interest.
   * @dev Reverts with InsufficientLiquidity if the pool cash is currently lent out; liquidity is
   *      guaranteed to return by repayment or permissionless liquidation at the due date.
   * @param id The fund id.
   */
  function claimInterest(uint256 id) external;

  // =======================
  // CREDIT
  // =======================

  /**
   * @notice Open a loan. Only one loan may be open at a time; the previous loan must be fully
   *         repaid (or liquidated) first. amount must satisfy
   *         amount * 10_000 <= borrowLimitBps * savings, and the pool must hold the cash.
   * @param id The fund id.
   * @param amount The principal to borrow (> 0).
   */
  function borrow(uint256 id, uint256 amount) external;

  /**
   * @notice Repay the caller's loan. Payment settles accrued interest first, then principal; any
   *         amount above the total debt is not pulled. Interest received is immediately
   *         distributed pro-rata to savers via the accumulator.
   * @dev Interest accrues per whole elapsed period only: a loan repaid within its first period
   *      owes zero interest.
   * @param id The fund id.
   * @param amount The maximum amount to pay (> 0).
   */
  function repay(uint256 id, uint256 amount) external;

  /**
   * @notice Liquidate an overdue loan by seizing the borrower's savings. Permissionless.
   * @dev Overdue = block.timestamp >= startTime + repaymentPeriods * periodLength and principal > 0.
   *      Seizes exactly principal (always covered) plus min(interestOwed, remaining savings) of
   *      interest, which is distributed to savers; if no savings shares would remain in the fund,
   *      the interest portion is not seized. Moves no tokens (pure ledger reallocation).
   * @param id The fund id.
   * @param member The borrower to liquidate.
   */
  function liquidate(uint256 id, address member) external;

  // =======================
  // VIEWS
  // =======================

  /**
   * @notice Returns whether a token is allowed.
   * @param token The token address.
   * @return allowed Whether the token is allowed.
   */
  function isTokenAllowed(address token) external view returns (bool allowed);

  /**
   * @notice Returns the id that will be assigned to the next fund.
   * @return id The next fund id.
   */
  function nextId() external view returns (uint256 id);

  /**
   * @notice Returns a fund's configuration and lifecycle flag.
   * @dev Reverts with FundNotFound for nonexistent ids.
   * @param id The fund id.
   * @return fund The fund.
   */
  function getFund(uint256 id) external view returns (Fund memory fund);

  /**
   * @notice Returns the ordered member roster of a fund.
   * @param id The fund id.
   * @return members The roster (append-only; members are never removed).
   */
  function getFundMembers(uint256 id) external view returns (address[] memory members);

  /**
   * @notice Returns every fund id an address has joined.
   * @param member The member address.
   * @return ids The fund ids.
   */
  function getMemberFunds(address member) external view returns (uint256[] memory ids);

  /**
   * @notice Returns the fund's aggregate balances.
   * @param id The fund id.
   * @return totalSavings_ Sum of all members' savings.
   * @return totalBorrowed_ Sum of all outstanding loan principal.
   * @return poolCash_ The fund's internal cash ledger.
   */
  function getFundBalances(uint256 id)
    external
    view
    returns (uint256 totalSavings_, uint256 totalBorrowed_, uint256 poolCash_);

  /**
   * @notice Returns a member's loan with interest accrued up to now (capped at repaymentPeriods).
   * @param id The fund id.
   * @param member The member.
   * @return loan The loan (principal == 0 means none).
   * @return dueDate The due date (0 if no loan).
   */
  function getLoan(uint256 id, address member) external view returns (Loan memory loan, uint256 dueDate);

  /**
   * @notice Returns a member's credit line: borrowLimitBps * savings / 10_000 (floor).
   * @param id The fund id.
   * @param member The member.
   * @return amount The credit line.
   */
  function creditLineOf(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Returns the largest amount the member could borrow right now:
   *         0 if a loan is open or the fund is deactivated, else min(creditLine, poolCash).
   * @param id The fund id.
   * @param member The member.
   * @return amount The maximum borrowable amount.
   */
  function maxBorrowableOf(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Returns a member's unclaimed interest: interestCredit + unsettled accumulator share.
   * @param id The fund id.
   * @param member The member.
   * @return amount The unclaimed interest.
   */
  function pendingInterestOf(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Returns a member's total withdrawable value: savings + pendingInterest (before
   *         collateral and liquidity guards).
   * @param id The fund id.
   * @param member The member.
   * @return amount The total withdrawable value.
   */
  function withdrawableOf(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Returns whether a member's loan is currently liquidatable.
   * @param id The fund id.
   * @param member The member.
   * @return liquidatable Whether the loan is overdue and open.
   */
  function isLiquidatable(uint256 id, address member) external view returns (bool liquidatable);

  // =======================
  // PUBLIC STORAGE GETTERS
  // =======================

  /**
   * @notice Returns a member's savings principal in a fund (collateral base and accumulator shares).
   * @param id The fund id.
   * @param member The member.
   * @return amount The savings amount.
   */
  function savings(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Returns interest already settled to a member (claimable via claimInterest), not yet transferred.
   * @param id The fund id.
   * @param member The member.
   * @return amount The settled interest credit.
   */
  function interestCredit(uint256 id, address member) external view returns (uint256 amount);

  /**
   * @notice Returns the sum of all members' savings in a fund (the accumulator share supply).
   * @param id The fund id.
   * @return amount The total savings.
   */
  function totalSavings(uint256 id) external view returns (uint256 amount);

  /**
   * @notice Returns the sum of all outstanding loan principal in a fund.
   * @param id The fund id.
   * @return amount The total borrowed principal.
   */
  function totalBorrowed(uint256 id) external view returns (uint256 amount);

  /**
   * @notice Returns the fund's internal cash ledger: tokens received minus tokens sent for the fund.
   * @param id The fund id.
   * @return amount The pool cash.
   */
  function poolCash(uint256 id) external view returns (uint256 amount);

  /**
   * @notice Returns the cumulative distributed interest per savings share, scaled by 1e18.
   * @param id The fund id.
   * @return acc The accumulator value (monotone non-decreasing).
   */
  function accInterestPerShare(uint256 id) external view returns (uint256 acc);

  /**
   * @notice Returns whether an address is a member of a fund.
   * @param id The fund id.
   * @param member The address.
   * @return status Whether the address is a member.
   */
  function isMember(uint256 id, address member) external view returns (bool status);

  /**
   * @notice Returns whether an EIP-712 invite nonce has been spent for a fund.
   * @param id The fund id.
   * @param nonce The invite nonce.
   * @return used Whether the nonce has been used.
   */
  function usedNonces(uint256 id, uint256 nonce) external view returns (bool used);

  /**
   * @notice Returns whether a token is on the admin allowlist.
   * @param token The token address.
   * @return allowed Whether the token is allowed.
   */
  function allowedTokens(address token) external view returns (bool allowed);
}
