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
 * @notice Extension contract for automated deposits and claims in SavingCircles
 * @dev This contract exposes Chainlink-compatible claim automation and batch deposit execution helpers
 */
contract AutomaticSavingCircles is IAutomaticSavingCircles, Ownable, ReentrancyGuard {
  /// @notice The main SavingCircles contract
  ISavingCircles public immutable SAVING_CIRCLES;

  /// @notice Dedicated automation `msg.sender` allowed to execute automated batches
  address public automationExecutor;

  /// @notice Mapping to track which members have enabled automatic deposits in each circle
  mapping(uint256 circleId => mapping(address member => bool enabled)) public automaticDepositsEnabled;

  /// @notice Mapping to track which members have enabled automatic claims in each circle
  mapping(uint256 circleId => mapping(address member => bool enabled)) public automaticClaimsEnabled;

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
  function setAutomaticDepositsEnabled(uint256 _circleId, bool _enabled) external override {
    automaticDepositsEnabled[_circleId][msg.sender] = _enabled;
    emit AutomaticDepositsToggled(_circleId, msg.sender, _enabled);
  }

  /// @inheritdoc IAutomaticSavingCircles
  function setAutomaticClaimsEnabled(uint256 _circleId, bool _enabled) external override {
    automaticClaimsEnabled[_circleId][msg.sender] = _enabled;
    emit AutomaticClaimsToggled(_circleId, msg.sender, _enabled);
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

  /**
   * @dev External trampoline used to isolate single-target failures with try/catch during batch claim execution
   * @param _circleId Circle to process
   * @param _member Member to claim for
   */
  function executeAutomatedClaimTarget(uint256 _circleId, address _member) external onlySelf {
    _executeAutomatedClaimTarget(_circleId, _member);
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
  function batchExecuteAutomatedClaims(
    uint256[] calldata _circleIds,
    address[] calldata _members
  ) external override nonReentrant onlyAutomationExecutor {
    _batchExecuteAutomatedClaims(_circleIds, _members);
  }

  /// @inheritdoc IAutomaticSavingCircles
  function performUpkeep(bytes calldata _performData) external override nonReentrant onlyAutomationExecutor {
    if (
      _performData.length < 4
        || bytes4(_performData[0:4]) != IAutomaticSavingCircles.batchExecuteAutomatedClaims.selector
    ) {
      revert InvalidPerformData();
    }

    (uint256[] memory circleIds, address[] memory members) = abi.decode(_performData[4:], (uint256[], address[]));
    _batchExecuteAutomatedClaims(circleIds, members);
  }

  /// @inheritdoc IAutomaticSavingCircles
  function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
    return _claimChecker();
  }

  /// @inheritdoc IAutomaticSavingCircles
  function isAutomaticDepositsEnabled(uint256 _circleId, address _member) external view override returns (bool) {
    return automaticDepositsEnabled[_circleId][_member];
  }

  /// @inheritdoc IAutomaticSavingCircles
  function isAutomaticClaimsEnabled(uint256 _circleId, address _member) external view override returns (bool) {
    return automaticClaimsEnabled[_circleId][_member];
  }

  /// @inheritdoc IAutomaticSavingCircles
  function depositChecker() external view override returns (bool canExec, bytes memory execPayload) {
    (uint256[] memory circleIds, address[] memory members) = getEligibleAutomatedDeposits();
    canExec = _automationCanExecute(circleIds);
    if (!canExec) return (false, bytes(''));

    execPayload = abi.encodeCall(IAutomaticSavingCircles.batchExecuteAutomatedDeposits, (circleIds, members));
  }

  /// @inheritdoc IAutomaticSavingCircles
  function claimChecker() external view override returns (bool canExec, bytes memory execPayload) {
    return _claimChecker();
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

  /// @inheritdoc IAutomaticSavingCircles
  function getEligibleAutomatedClaims()
    public
    view
    override
    returns (uint256[] memory circleIds, address[] memory members)
  {
    uint256 circleCount = SAVING_CIRCLES.nextId();
    uint256 eligibleCount = 0;

    for (uint256 circleId = 0; circleId < circleCount; circleId++) {
      eligibleCount += _countEligibleAutomatedClaimsForCircle(circleId);
    }

    circleIds = new uint256[](eligibleCount);
    members = new address[](eligibleCount);

    uint256 index = 0;
    for (uint256 circleId = 0; circleId < circleCount; circleId++) {
      index = _appendEligibleAutomatedClaimsForCircle(circleId, circleIds, members, index);
    }
  }

  /**
   * @dev Executes automated claims for a set of targets, continuing past individual target failures
   * @param _circleIds Circle IDs to process
   * @param _members Members to process for each circle ID
   */
  function _batchExecuteAutomatedClaims(uint256[] memory _circleIds, address[] memory _members) internal {
    if (_circleIds.length != _members.length) revert ArrayLengthMismatch();

    for (uint256 i = 0; i < _circleIds.length; i++) {
      try this.executeAutomatedClaimTarget(_circleIds[i], _members[i]) {}
      catch (bytes memory reason) {
        emit AutomatedClaimFailed(_circleIds[i], _members[i], reason);
      }
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
    if (!automaticDepositsEnabled[_circleId][_member]) revert AutomaticDepositsNotEnabled();
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
   * @dev Executes a single automated claim target after re-validating all onchain constraints
   * @param _circleId Circle to process
   * @param _member Member to claim for
   */
  function _executeAutomatedClaimTarget(uint256 _circleId, address _member) internal {
    ISavingCircles.Circle memory _circle = SAVING_CIRCLES.getCircle(_circleId);
    // Check opt-in before fetching members while retaining the specific error for an invalid circle.
    if (!automaticClaimsEnabled[_circleId][_member]) revert AutomaticClaimsDisabled();

    address[] memory members = SAVING_CIRCLES.getCircleMembers(_circleId);
    (bool isMember, uint256 memberIndex) = _getMemberIndex(members, _member);

    if (!isMember) revert ISavingCircles.NotMember();
    if (!_isEligibleForAutomatedClaim(_circleId, _circle, _member, memberIndex)) {
      revert ISavingCircles.NotWithdrawable();
    }

    SAVING_CIRCLES.withdrawFor(_circleId, _member);
  }

  /**
   * @dev Returns whether automatic claims can execute and the calldata Chainlink should perform
   * @return canExec Whether automation can execute the claims
   * @return execPayload Encoded calldata for the automated claim execution
   */
  function _claimChecker() internal view returns (bool canExec, bytes memory execPayload) {
    (uint256[] memory circleIds, address[] memory members) = getEligibleAutomatedClaims();
    canExec = _automationCanExecute(circleIds);
    if (!canExec) return (false, bytes(''));

    execPayload = abi.encodeCall(IAutomaticSavingCircles.batchExecuteAutomatedClaims, (circleIds, members));
  }

  /**
   * @dev Returns whether automation can execute for the selected targets
   * @param _circleIds Circle IDs selected for automated execution
   * @return Whether an automation executor is configured and at least one target exists
   */
  function _automationCanExecute(uint256[] memory _circleIds) internal view returns (bool) {
    return automationExecutor != address(0) && _circleIds.length > 0;
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
   * @dev Returns the ending timestamp for a round
   * @param _circle Circle configuration to evaluate
   * @param _round Zero-based round index
   * @return Timestamp when the round's time condition has passed
   */
  function _roundEndTime(ISavingCircles.Circle memory _circle, uint256 _round) internal pure returns (uint256) {
    return _circle.effectiveCircleStartTime + (_circle.depositInterval * (_round + 1));
  }

  /**
   * @dev Returns whether a member currently satisfies the offchain selection criteria for automated deposit
   * @param _circleId Circle to inspect
   * @param _circle Circle configuration to evaluate
   * @param _member Member being checked
   * @param _currentBalance Amount already deposited by the member in the active round
   * @return Whether the member can be included in the automation payload
   */
  function _isEligibleForAutomatedDeposit(
    uint256 _circleId,
    ISavingCircles.Circle memory _circle,
    address _member,
    uint256 _currentBalance
  ) internal view returns (bool) {
    if (!automaticDepositsEnabled[_circleId][_member]) return false;
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
        if (_isEligibleForAutomatedDeposit(_circleId, _circle, members[i], balances[i])) {
          eligibleCount++;
        }
      }
    } catch {
      return 0;
    }
  }

  /**
   * @dev Counts how many members in a circle are currently eligible for automated claim
   * @param _circleId Circle to inspect
   * @return eligibleCount Number of eligible claim targets found
   */
  function _countEligibleAutomatedClaimsForCircle(uint256 _circleId) internal view returns (uint256 eligibleCount) {
    try SAVING_CIRCLES.getCircle(_circleId) returns (ISavingCircles.Circle memory _circle) {
      if (!SAVING_CIRCLES.isActive(_circleId)) return 0;
      if (SAVING_CIRCLES.isDecommissionable(_circleId)) return 0;

      address[] memory members = SAVING_CIRCLES.getCircleMembers(_circleId);
      for (uint256 i = 0; i < members.length; i++) {
        if (_isEligibleForAutomatedClaim(_circleId, _circle, members[i], i)) {
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
        if (!_isEligibleForAutomatedDeposit(_circleId, _circle, members[i], balances[i])) continue;

        _circleIds[nextIndex] = _circleId;
        _members[nextIndex] = members[i];
        nextIndex++;
      }
    } catch {
      return nextIndex;
    }
  }

  /**
   * @dev Appends the eligible claim targets for a circle into the output arrays used by the selector
   * @param _circleId Circle to inspect
   * @param _circleIds Output array of eligible circle IDs
   * @param _members Output array of eligible members
   * @param _index Current write index in the output arrays
   * @return nextIndex Updated write index after appending any eligible targets
   */
  function _appendEligibleAutomatedClaimsForCircle(
    uint256 _circleId,
    uint256[] memory _circleIds,
    address[] memory _members,
    uint256 _index
  ) internal view returns (uint256 nextIndex) {
    nextIndex = _index;

    try SAVING_CIRCLES.getCircle(_circleId) returns (ISavingCircles.Circle memory _circle) {
      if (!SAVING_CIRCLES.isActive(_circleId)) return nextIndex;
      if (SAVING_CIRCLES.isDecommissionable(_circleId)) return nextIndex;

      address[] memory members = SAVING_CIRCLES.getCircleMembers(_circleId);
      for (uint256 i = 0; i < members.length; i++) {
        if (!_isEligibleForAutomatedClaim(_circleId, _circle, members[i], i)) continue;

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
   * @dev Returns whether a member currently satisfies the automated claim criteria.
   *      Automation should only claim after every member deposited for the member's round and that round's time has passed.
   * @param _circleId Circle identifier
   * @param _circle Circle configuration to evaluate
   * @param _member Member being checked
   * @param _memberIndex The member's zero-based payout round
   * @return Whether the member can be included in the claim automation payload
   */
  function _isEligibleForAutomatedClaim(
    uint256 _circleId,
    ISavingCircles.Circle memory _circle,
    address _member,
    uint256 _memberIndex
  ) internal view returns (bool) {
    if (!automaticClaimsEnabled[_circleId][_member]) return false;
    if (!SAVING_CIRCLES.isActive(_circleId)) return false;
    if (_circle.effectiveCircleStartTime == 0) return false;
    if (SAVING_CIRCLES.isDecommissionable(_circleId)) return false;
    if (block.timestamp < _roundEndTime(_circle, _memberIndex)) return false;

    return SAVING_CIRCLES.isMemberWithdrawable(_circleId, _member);
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

  /**
   * @dev Looks up whether a member belongs to the supplied member snapshot and returns their index
   * @param _members Snapshot of circle members
   * @param _member Member being searched for
   * @return isMember Whether the member was found in the snapshot
   * @return memberIndex The member's zero-based index in the circle
   */
  function _getMemberIndex(
    address[] memory _members,
    address _member
  ) internal pure returns (bool isMember, uint256 memberIndex) {
    for (uint256 i = 0; i < _members.length; i++) {
      if (_members[i] != _member) continue;
      return (true, i);
    }
  }
}
