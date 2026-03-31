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
   * @notice Thrown when a non-Gelato caller attempts an automated execution
   */
  error OnlyAutomationExecutor();

  /**
   * @notice Enable or disable automatic deposits for the caller across every circle they belong to
   * @param enabled Whether to enable automatic deposits
   */
  function setAutomaticDepositsEnabled(bool enabled) external;

  /**
   * @notice Configure the Gelato dedicated msg.sender allowed to execute automated deposits
   * @param automationExecutor The dedicated Gelato executor address for this network
   */
  function setAutomationExecutor(address automationExecutor) external;

  /**
   * @notice Gelato automation entrypoint for automatic deposits across every active circle
   */
  function executeAutomatedDeposits() external;

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
   * @notice Gelato resolver-style checker for automatic deposits across every circle
   * @return canExec Whether Gelato should execute the sweep
   * @return execPayload Encoded calldata for the automated deposit execution
   */
  function checker() external view returns (bool canExec, bytes memory execPayload);
}
