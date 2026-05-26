// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IAutomaticSavingCircles
 * @notice Interface for the SavingCircles automation extension contract
 * @dev This extension is intended for Gelato-driven automated deposits and claims
 */
interface IAutomaticSavingCircles {
  /**
   * @notice Emitted when a member enables or disables automatic deposits
   * @param member The address of the member
   * @param enabled Whether automatic deposits are enabled
   */
  event AutomaticDepositsToggled(address indexed member, bool indexed enabled);

  /**
   * @notice Emitted when a member enables or disables automatic claims for a circle
   * @param circleId The circle configured by the member
   * @param member The address of the member
   * @param enabled Whether automatic claims are enabled
   */
  event AutomaticClaimsToggled(uint256 indexed circleId, address indexed member, bool indexed enabled);

  /**
   * @notice Emitted when the Gelato automation executor is updated
   * @param previousExecutor The previous dedicated executor
   * @param newExecutor The new dedicated executor
   */
  event AutomationExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);

  /**
   * @notice Emitted when an automated deposit target fails during batch execution
   * @param circleId The circle that failed
   * @param member The member that failed
   * @param reason The raw revert data returned by the failed execution
   */
  event AutomatedDepositFailed(uint256 indexed circleId, address indexed member, bytes reason);

  /**
   * @notice Emitted when an automated claim target fails during batch execution
   * @param circleId The circle that failed
   * @param member The member that failed
   * @param reason The raw revert data returned by the failed execution
   */
  event AutomatedClaimFailed(uint256 indexed circleId, address indexed member, bytes reason);

  /**
   * @notice Thrown when a non-Gelato caller attempts an automated execution
   */
  error OnlyAutomationExecutor();

  /**
   * @notice Thrown when automatic deposits have not been enabled for a member
   */
  error AutomaticDepositsNotEnabled();

  /**
   * @notice Thrown when automatic claims have not been enabled for a member in a circle
   */
  error AutomaticClaimsDisabled();

  /**
   * @notice Thrown when batch execution inputs have mismatched array lengths
   */
  error ArrayLengthMismatch();

  /**
   * @notice Thrown when a member has not approved enough tokens for automation
   */
  error InsufficientAllowance();

  /**
   * @notice Thrown when a member does not hold enough tokens for automation
   */
  error InsufficientBalance();

  /**
   * @notice Enable or disable automatic deposits for the caller across every circle they belong to
   * @param enabled Whether to enable automatic deposits
   */
  function setAutomaticDepositsEnabled(bool enabled) external;

  /**
   * @notice Enable or disable automatic claims for the caller for one circle
   * @param circleId The circle to configure
   * @param enabled Whether to enable automatic claims
   */
  function setAutomaticClaimsEnabled(uint256 circleId, bool enabled) external;

  /**
   * @notice Configure the Gelato dedicated msg.sender allowed to execute automated batches
   * @param automationExecutor The dedicated Gelato executor address for this network
   */
  function setAutomationExecutor(address automationExecutor) external;

  /**
   * @notice Execute automated deposits for precomputed targets
   * @param circleIds Circle IDs to process
   * @param members Members to process for each circle ID
   */
  function batchExecuteAutomatedDeposits(uint256[] calldata circleIds, address[] calldata members) external;

  /**
   * @notice Execute automated claims for precomputed targets
   * @param circleIds Circle IDs to process
   * @param members Members to process for each circle ID
   */
  function batchExecuteAutomatedClaims(uint256[] calldata circleIds, address[] calldata members) external;

  /**
   * @notice The configured Gelato dedicated msg.sender
   * @return The automation executor address
   */
  function automationExecutor() external view returns (address);

  /**
   * @notice Check if automatic deposits are enabled for a member
   * @param member The address to check
   * @return Whether automatic deposits are enabled
   */
  function isAutomaticDepositsEnabled(address member) external view returns (bool);

  /**
   * @notice Check if automatic claims are enabled for a member in a circle
   * @param circleId The circle to check
   * @param member The address to check
   * @return Whether automatic claims are enabled
   */
  function isAutomaticClaimsEnabled(uint256 circleId, address member) external view returns (bool);

  /**
   * @notice Return every member/circle pair currently eligible for automated deposit
   * @return circleIds Circle IDs with pending automated deposits
   * @return members Members eligible for automated deposits in each circle
   */
  function getEligibleAutomatedDeposits() external view returns (uint256[] memory circleIds, address[] memory members);

  /**
   * @notice Return every member/circle pair currently eligible for automated claim
   * @return circleIds Circle IDs with pending automated claims
   * @return members Members eligible to claim in each circle
   */
  function getEligibleAutomatedClaims() external view returns (uint256[] memory circleIds, address[] memory members);

  /**
   * @notice Gelato resolver-style checker for automatic deposits across every circle
   * @return canExec Whether Gelato should execute the sweep
   * @return execPayload Encoded calldata for the automated deposit execution
   */
  function depositChecker() external view returns (bool canExec, bytes memory execPayload);

  /**
   * @notice Gelato resolver-style checker for automatic claims across every circle
   * @return canExec Whether Gelato can execute the claims
   * @return execPayload Encoded calldata for the automated claim execution
   */
  function claimChecker() external view returns (bool canExec, bytes memory execPayload);
}
