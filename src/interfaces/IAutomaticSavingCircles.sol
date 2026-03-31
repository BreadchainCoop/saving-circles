// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IAutomaticSavingCircles
 * @notice Interface for the SavingCircles automatic deposits extension contract
 * @dev This extension is intended for Gelato-driven automated deposits only
 */
interface IAutomaticSavingCircles {
  /**
   * @notice Emitted when a member enables or disables automatic deposits
   * @param member The address of the member
   * @param enabled Whether automatic deposits are enabled
   */
  event AutomaticDepositsToggled(address indexed member, bool indexed enabled);

  /**
   * @notice Emitted when the Gelato automation executor is updated
   * @param previousExecutor The previous dedicated executor
   * @param newExecutor The new dedicated executor
   */
  event AutomationExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);

  /**
   * @notice Thrown when a member has insufficient allowance for automatic deposit
   */
  error InsufficientAllowance();

  /**
   * @notice Thrown when a member has insufficient token balance for automatic deposit
   */
  error InsufficientBalance();

  /**
   * @notice Thrown when a non-Gelato caller attempts an automated execution
   */
  error OnlyAutomationExecutor();

  /**
   * @notice Thrown when automatic deposits are not enabled for a member
   */
  error AutomaticDepositsNotEnabled();

  /**
   * @notice Enable or disable automatic deposits for the caller
   * @param enabled Whether to enable automatic deposits
   */
  function setAutomaticDepositsEnabled(bool enabled) external;

  /**
   * @notice Configure the Gelato dedicated msg.sender allowed to execute automated deposits
   * @param automationExecutor The dedicated Gelato executor address for this network
   */
  function setAutomationExecutor(address automationExecutor) external;

  /**
   * @notice Gelato automation entrypoint for automatic deposits
   * @param circleId The ID of the circle
   * @param member The address of the member to deposit for
   */
  function executeAutomatedDeposit(uint256 circleId, address member) external;

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
   * @notice Gelato resolver-style checker for automated deposits
   * @param circleId The ID of the circle
   * @param member The address of the member to deposit for
   * @return canExec Whether Gelato should execute the deposit
   * @return execPayload Encoded calldata for the automated deposit execution
   */
  function checker(uint256 circleId, address member) external view returns (bool canExec, bytes memory execPayload);
}
