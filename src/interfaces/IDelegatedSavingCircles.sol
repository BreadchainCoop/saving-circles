// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IDelegatedSavingCircles
 * @notice Interface for the SavingCircles delegated deposits extension contract
 * @dev This extension enables delegated ERC20 allowance-based deposits and batch operations
 */
interface IDelegatedSavingCircles {
  /**
   * @notice A struct representing a record for automations
   * @param circleId The ID of the circle
   * @param member The address of the member
   */
  struct AutomationRecord {
    uint256 circleId;
    address member;
  }

  /**
   * @notice Emitted when a member enables or disables delegated deposits
   * @param member The address of the member
   * @param enabled Whether delegated deposits are enabled
   */
  event DelegatedDepositsToggled(address indexed member, bool indexed enabled);

  /**
   * @notice Emitted when a member enables or disables automations
   * @param member The address of the member
   * @param enabled Whether automations are enabled
   */
  event AutomationsToggled(address indexed member, bool indexed enabled);

  /**
   * @notice Thrown when a member has insufficient allowance for delegated deposit
   */
  error InsufficientAllowance();

  /**
   * @notice Thrown when array lengths don't match in batch operations
   */
  error ArrayLengthMismatch();

  /**
   * @notice Thrown when delegated deposits are not enabled for a member
   */
  error DelegatedDepositsNotEnabled();

  /**
   * @notice Enable or disable delegated deposits for the caller
   * @param enabled Whether to enable delegated deposits
   */
  function setDelegatedDepositsEnabled(bool enabled) external;

  /**
   * @notice Enable or disable automations for the caller
   * @param enabled Whether to enable automations
   */
  function setAutomationEnabled(bool enabled) external;

  /**
   * @notice Deposit funds for a member if they have sufficient allowance
   * @param circleId The ID of the circle
   * @param member The address of the member to deposit for
   * @dev Reverts if member hasn't opted in, has insufficient allowance, or deposit is invalid
   */
  function depositIfAllowed(uint256 circleId, address member) external;

  /**
   * @notice Batch deposit for multiple members across multiple circles
   * @param circleIds Array of circle IDs
   * @param members Array of member addresses
   * @dev Arrays must be same length. All deposits must succeed or entire transaction reverts
   */
  function batchDepositIfAllowed(uint256[] calldata circleIds, address[] calldata members) external;

  /**
   * @notice Check if delegated deposits are enabled for a member
   * @param member The address to check
   * @return Whether Delegated deposits are enabled
   */
  function isDelegatedDepositsEnabled(address member) external view returns (bool);

  /**
   * @notice Check if automations are enabled for a member
   * @param member The address to check
   * @return Whether automations are enabled
   */
  function isAutomationEnabled(address member) external view returns (bool);

  /**
   * @notice Get addresses eligible for delegated deposits across all circles
   * @return circleIds Array of circle IDs with eligible members
   * @return members Array of eligible member addresses
   * @dev Returns parallel arrays where circleIds[i] and members[i] represent an eligible pair
   */
  function getAddressesForDeposit() external view returns (uint256[] memory circleIds, address[] memory members);

  /**
   * @notice Checker function for automated deposits
   * @return canExec Whether there are deposits to be made
   * @return execPayload The payload to execute deposits
   */
  function depositChecker() external view returns (bool canExec, bytes memory execPayload);

  /**
   * @notice Checker function for automated withdrawals
   * @return canExec Whether there are withdrawals to be made
   * @return execPayload The payload to execute withdrawals
   */
  function withdrawalChecker() external view returns (bool canExec, bytes memory execPayload);

  /**
   * @notice Execute automated deposits for multiple members across multiple circles
   * @param records Array of AutomationRecord structs specifying circle IDs and member addresses
   */
  function autoDeposit(AutomationRecord[] calldata records) external;

  /**
   * @notice Execute automated withdrawals for multiple members across multiple circles
   * @param records Array of AutomationRecord structs specifying circle IDs and member addresses
   */
  function autoWithdrawal(AutomationRecord[] calldata records) external;
}
