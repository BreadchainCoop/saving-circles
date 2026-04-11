// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAutomaticSavingCircles} from '../interfaces/IAutomaticSavingCircles.sol';
import {ISavingCircles} from '../interfaces/ISavingCircles.sol';

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

using SafeERC20 for IERC20;

/**
 * @title AutomaticSavingCircles
 * @notice Extension contract for automatic deposits in SavingCircles
 * @dev This contract exposes Gelato-friendly target selection and batch execution for automated deposits
 */
contract AutomaticSavingCircles is IAutomaticSavingCircles, Ownable, ReentrancyGuard {
  /// @notice The main SavingCircles contract
  ISavingCircles public immutable SAVING_CIRCLES;

  /// @notice Dedicated Gelato msg.sender allowed to execute automated deposit batches
  address public automationExecutor;

  /// @notice Mapping to track which members have enabled automatic deposits
  mapping(address member => bool enabled) public automaticDepositsEnabled;

  /// @notice Thrown when an internal execution trampoline is called externally
  error OnlySelf();

  /// @dev Restricts batch execution to the configured automation executor
  modifier onlyAutomationExecutor() {
    if (msg.sender != automationExecutor) revert OnlyAutomationExecutor();
    _;
  }

  /// @dev Restricts the execution trampoline to self-calls only
  modifier onlySelf() {
    if (msg.sender != address(this)) revert OnlySelf();
    _;
  }

  /**
   * @notice Constructor
   * @param _savingCircles Address of the main SavingCircles contract
   * @param _owner Owner of the automatic deposits extension
   */
  constructor(address _savingCircles, address _owner) Ownable(_owner) {
    SAVING_CIRCLES = ISavingCircles(_savingCircles);
  }

  /// @inheritdoc IAutomaticSavingCircles
  function setAutomaticDepositsEnabled(bool _enabled) external override {
    automaticDepositsEnabled[msg.sender] = _enabled;
    emit AutomaticDepositsToggled(msg.sender, _enabled);
  }

  /// @inheritdoc IAutomaticSavingCircles
  function setAutomationExecutor(address _automationExecutor) external override onlyOwner {
    address previousExecutor = automationExecutor;
    automationExecutor = _automationExecutor;
    emit AutomationExecutorUpdated(previousExecutor, _automationExecutor);
  }

  /**
   * @dev External trampoline used to isolate single-target failures with try/catch during batch execution
   * @param _circleId Circle to process
   * @param _member Member to deposit for
   */
  function executeAutomatedDepositTarget(uint256 _circleId, address _member) external onlySelf {
    _executeAutomatedDepositTarget(_circleId, _member);
  }

  /// @inheritdoc IAutomaticSavingCircles
  function batchExecuteAutomatedDeposits(
    uint256[] calldata _circleIds,
    address[] calldata _members
  ) external override nonReentrant onlyAutomationExecutor {
    if (_circleIds.length != _members.length) revert ArrayLengthMismatch();

    for (uint256 i = 0; i < _circleIds.length; i++) {
      try this.executeAutomatedDepositTarget(_circleIds[i], _members[i]) {}
      catch (bytes memory reason) {
        emit AutomatedDepositFailed(_circleIds[i], _members[i], reason);
      }
    }
  }

  /// @inheritdoc IAutomaticSavingCircles
  function isAutomaticDepositsEnabled(address _member) external view override returns (bool) {
    return automaticDepositsEnabled[_member];
  }

  /// @inheritdoc IAutomaticSavingCircles
  function checker() external view override returns (bool canExec, bytes memory execPayload) {
    uint256[] memory circleIds;
    address[] memory members;

    if (automationExecutor != address(0)) {
      (circleIds, members) = getEligibleAutomatedDeposits();
      canExec = circleIds.length > 0;
    } else {
      circleIds = new uint256[](0);
      members = new address[](0);
    }

    execPayload = abi.encodeCall(IAutomaticSavingCircles.batchExecuteAutomatedDeposits, (circleIds, members));
  }

  /// @inheritdoc IAutomaticSavingCircles
  function getEligibleAutomatedDeposits()
    public
    view
    override
    returns (uint256[] memory circleIds, address[] memory members)
  {
    uint256 circleCount = SAVING_CIRCLES.nextId();
    uint256 eligibleCount = 0;

    for (uint256 circleId = 0; circleId < circleCount; circleId++) {
      eligibleCount += _countEligibleAutomatedDepositsForCircle(circleId);
    }

    circleIds = new uint256[](eligibleCount);
    members = new address[](eligibleCount);

    uint256 index = 0;
    for (uint256 circleId = 0; circleId < circleCount; circleId++) {
      index = _populateEligibleAutomatedDepositsForCircle(circleId, circleIds, members, index);
    }
  }

  /**
   * @dev Executes a single automated deposit target after re-validating all onchain constraints
   * @param _circleId Circle to process
   * @param _member Member to deposit for
   */
  function _executeAutomatedDepositTarget(uint256 _circleId, address _member) internal {
    ISavingCircles.Circle memory _circle = SAVING_CIRCLES.getCircle(_circleId);
    (address[] memory members, uint256[] memory balances) = SAVING_CIRCLES.getMemberBalances(_circleId);

    if (!_isCircleEligibleForAutomation(_circleId, _circle, members.length)) {
      if (!SAVING_CIRCLES.isActive(_circleId)) revert ISavingCircles.NotActive();
      if (SAVING_CIRCLES.isDecommissionable(_circleId)) revert ISavingCircles.CircleTimedOut();
      if (block.timestamp < _circle.effectiveCircleStartTime) revert ISavingCircles.DepositBeforeCircleStart();
      revert ISavingCircles.CircleNotStarted();
    }

    (bool isMember, uint256 currentBalance) = _getMemberBalance(members, balances, _member);
    if (!isMember) revert ISavingCircles.NotMember();
    if (!automaticDepositsEnabled[_member]) revert AutomaticDepositsNotEnabled();
    if (currentBalance >= _circle.depositAmount) revert ISavingCircles.AlreadyDeposited();

    uint256 requiredAmount = _circle.depositAmount - currentBalance;
    IERC20 token = IERC20(_circle.token);

    if (token.allowance(_member, address(this)) < requiredAmount) revert InsufficientAllowance();
    if (token.balanceOf(_member) < requiredAmount) revert InsufficientBalance();

    token.safeTransferFrom(_member, address(this), requiredAmount);
    token.forceApprove(address(SAVING_CIRCLES), requiredAmount);
    SAVING_CIRCLES.depositFor(_circleId, requiredAmount, _member);
  }

  /**
   * @dev Returns the current round index for a circle using the live block timestamp
   * @param _circle Circle configuration to evaluate
   * @return The zero-based round index
   */
  function _currentRoundIndex(ISavingCircles.Circle memory _circle) internal view returns (uint256) {
    if (
      _circle.depositInterval == 0 || _circle.effectiveCircleStartTime == 0
        || block.timestamp < _circle.effectiveCircleStartTime
    ) {
      return 0;
    }

    return (block.timestamp - _circle.effectiveCircleStartTime) / _circle.depositInterval;
  }

  /**
   * @dev Returns whether a member currently satisfies the offchain selection criteria for automated deposit
   * @param _circle Circle configuration to evaluate
   * @param _member Member being checked
   * @param _currentBalance Amount already deposited by the member in the active round
   * @return Whether the member can be included in the automation payload
   */
  function _isEligibleForAutomatedDeposit(
    ISavingCircles.Circle memory _circle,
    address _member,
    uint256 _currentBalance
  ) internal view returns (bool) {
    if (!automaticDepositsEnabled[_member]) return false;
    if (_currentBalance >= _circle.depositAmount) return false;

    uint256 requiredAmount = _circle.depositAmount - _currentBalance;
    IERC20 token = IERC20(_circle.token);

    return token.allowance(_member, address(this)) >= requiredAmount && token.balanceOf(_member) >= requiredAmount;
  }

  /**
   * @dev Counts how many members in a circle are currently eligible for automated deposit
   * @param _circleId Circle to inspect
   * @return eligibleCount Number of eligible member targets found
   */
  function _countEligibleAutomatedDepositsForCircle(uint256 _circleId) internal view returns (uint256 eligibleCount) {
    try SAVING_CIRCLES.getCircle(_circleId) returns (ISavingCircles.Circle memory _circle) {
      if (!SAVING_CIRCLES.isActive(_circleId)) return 0;
      (address[] memory members, uint256[] memory balances) = SAVING_CIRCLES.getMemberBalances(_circleId);
      if (!_isCircleEligibleForAutomation(_circleId, _circle, members.length)) return 0;

      for (uint256 i = 0; i < members.length; i++) {
        if (_isEligibleForAutomatedDeposit(_circle, members[i], balances[i])) {
          eligibleCount++;
        }
      }
    } catch {
      return 0;
    }
  }

  /**
   * @dev Appends the eligible targets for a circle into the output arrays used by the selector
   * @param _circleId Circle to inspect
   * @param _circleIds Output array of eligible circle IDs
   * @param _members Output array of eligible members
   * @param _index Current write index in the output arrays
   * @return nextIndex Updated write index after appending any eligible targets
   */
  function _populateEligibleAutomatedDepositsForCircle(
    uint256 _circleId,
    uint256[] memory _circleIds,
    address[] memory _members,
    uint256 _index
  ) internal view returns (uint256 nextIndex) {
    nextIndex = _index;

    try SAVING_CIRCLES.getCircle(_circleId) returns (ISavingCircles.Circle memory _circle) {
      if (!SAVING_CIRCLES.isActive(_circleId)) return nextIndex;
      (address[] memory members, uint256[] memory balances) = SAVING_CIRCLES.getMemberBalances(_circleId);
      if (!_isCircleEligibleForAutomation(_circleId, _circle, members.length)) return nextIndex;

      for (uint256 i = 0; i < members.length; i++) {
        if (!_isEligibleForAutomatedDeposit(_circle, members[i], balances[i])) continue;

        _circleIds[nextIndex] = _circleId;
        _members[nextIndex] = members[i];
        nextIndex++;
      }
    } catch {
      return nextIndex;
    }
  }

  /**
   * @dev Returns whether a circle is in a state where automation can process deposits
   * @param _circleId Circle identifier
   * @param _circle Circle configuration to evaluate
   * @param _memberCount Number of members in the circle
   * @return Whether automated deposits may be attempted for this circle
   */
  function _isCircleEligibleForAutomation(
    uint256 _circleId,
    ISavingCircles.Circle memory _circle,
    uint256 _memberCount
  ) internal view returns (bool) {
    if (!SAVING_CIRCLES.isActive(_circleId)) return false;
    if (_circle.effectiveCircleStartTime == 0) return false;
    if (block.timestamp < _circle.effectiveCircleStartTime) return false;
    if (SAVING_CIRCLES.isDecommissionable(_circleId)) return false;
    if (_currentRoundIndex(_circle) >= _memberCount) return false;

    return true;
  }

  /**
   * @dev Looks up whether a member belongs to the supplied balances snapshot and returns their current balance
   * @param _members Snapshot of circle members
   * @param _balances Snapshot of current round balances aligned with `_members`
   * @param _member Member being searched for
   * @return isMember Whether the member was found in the snapshot
   * @return currentBalance Current round balance for the member
   */
  function _getMemberBalance(
    address[] memory _members,
    uint256[] memory _balances,
    address _member
  ) internal pure returns (bool isMember, uint256 currentBalance) {
    for (uint256 i = 0; i < _members.length; i++) {
      if (_members[i] != _member) continue;
      return (true, _balances[i]);
    }
  }
}
