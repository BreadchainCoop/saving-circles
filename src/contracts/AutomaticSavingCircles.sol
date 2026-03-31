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
 * @dev This contract exposes a Gelato-only automated deposit path
 */

contract AutomaticSavingCircles is IAutomaticSavingCircles, Ownable, ReentrancyGuard {
  /// @notice The main SavingCircles contract
  ISavingCircles public immutable SAVING_CIRCLES;

  /// @notice Dedicated Gelato msg.sender allowed to execute automated deposits
  address public automationExecutor;

  /// @notice Mapping to track which members have enabled automatic deposits
  mapping(address member => bool enabled) public automaticDepositsEnabled;

  modifier onlyAutomationExecutor() {
    if (msg.sender != automationExecutor) revert OnlyAutomationExecutor();
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

  /// @inheritdoc IAutomaticSavingCircles
  function executeAutomatedDeposit(
    uint256 _circleId,
    address _member
  ) external override nonReentrant onlyAutomationExecutor {
    _executeAutomatedDeposit(_circleId, _member);
  }

  /// @inheritdoc IAutomaticSavingCircles
  function isAutomaticDepositsEnabled(address _member) external view override returns (bool) {
    return automaticDepositsEnabled[_member];
  }

  /// @inheritdoc IAutomaticSavingCircles
  function checker(
    uint256 _circleId,
    address _member
  ) external view override returns (bool canExec, bytes memory execPayload) {
    execPayload = abi.encodeCall(IAutomaticSavingCircles.executeAutomatedDeposit, (_circleId, _member));
    if (automationExecutor == address(0)) return (false, execPayload);
    canExec = _canExecuteAutomatedDeposit(_circleId, _member);
  }

  /**
   * @dev Internal function to handle automated deposits
   * @param _circleId Circle ID
   * @param _member Member address to deposit for
   */
  function _executeAutomatedDeposit(uint256 _circleId, address _member) internal {
    // Check if automatic deposits are enabled for this member
    if (!automaticDepositsEnabled[_member]) revert AutomaticDepositsNotEnabled();

    if (SAVING_CIRCLES.isDecommissionable(_circleId)) revert ISavingCircles.NotActive();

    // Get circle information
    ISavingCircles.Circle memory _circle = SAVING_CIRCLES.getCircle(_circleId);
    address[] memory circleMembers = SAVING_CIRCLES.getCircleMembers(_circleId);

    if (_circle.effectiveCircleStartTime == 0) revert ISavingCircles.NotActive();

    // Check if member is part of the circle
    bool isMember = false;
    for (uint256 i = 0; i < circleMembers.length; i++) {
      if (circleMembers[i] == _member) {
        isMember = true;
        break;
      }
    }
    if (!isMember) revert ISavingCircles.NotMember();

    // Calculate the remaining deposit amount needed
    uint256 currentBalance = _memberBalance(_circleId, _member);
    if (currentBalance >= _circle.depositAmount) revert ISavingCircles.AlreadyDeposited();
    uint256 requiredAmount = _circle.depositAmount - currentBalance;

    // Check allowance (member must approve this extension contract)
    uint256 allowance = IERC20(_circle.token).allowance(_member, address(this));
    if (allowance < requiredAmount) revert InsufficientAllowance();

    uint256 balance = IERC20(_circle.token).balanceOf(_member);
    if (balance < requiredAmount) revert InsufficientBalance();

    // Check deposit window validity
    if (block.timestamp < _circle.effectiveCircleStartTime) {
      revert ISavingCircles.DepositBeforeCircleStart();
    }
    // Check if all deposit periods have passed
    if (_currentRoundIndex(_circle) >= circleMembers.length) {
      revert ISavingCircles.CircleExpired();
    }

    // Transfer tokens from member to this contract
    IERC20(_circle.token).safeTransferFrom(_member, address(this), requiredAmount);

    // Approve the main contract to spend the tokens
    IERC20(_circle.token).forceApprove(address(SAVING_CIRCLES), requiredAmount);

    // Call depositFor on the main contract
    SAVING_CIRCLES.depositFor(_circleId, requiredAmount, _member);
  }

  function _currentRoundIndex(ISavingCircles.Circle memory _circle) internal view returns (uint256) {
    if (
      _circle.depositInterval == 0 || _circle.effectiveCircleStartTime == 0
        || block.timestamp < _circle.effectiveCircleStartTime
    ) {
      return 0;
    }

    return (block.timestamp - _circle.effectiveCircleStartTime) / _circle.depositInterval;
  }

  function _memberBalance(uint256 _circleId, address _member) internal view returns (uint256) {
    (address[] memory members, uint256[] memory balances) = SAVING_CIRCLES.getMemberBalances(_circleId);
    for (uint256 i = 0; i < members.length; i++) {
      if (members[i] == _member) {
        return balances[i];
      }
    }
    return 0;
  }

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

  function _canExecuteAutomatedDeposit(uint256 _circleId, address _member) internal view returns (bool) {
    try SAVING_CIRCLES.getCircle(_circleId) returns (ISavingCircles.Circle memory _circle) {
      if (_circle.effectiveCircleStartTime == 0) return false;
      if (block.timestamp < _circle.effectiveCircleStartTime) return false;
      if (SAVING_CIRCLES.isDecommissionable(_circleId)) return false;

      (address[] memory members, uint256[] memory balances) = SAVING_CIRCLES.getMemberBalances(_circleId);
      uint256 currentRound = _currentRoundIndex(_circle);
      if (currentRound >= members.length) return false;

      for (uint256 i = 0; i < members.length; i++) {
        if (members[i] == _member) {
          return _isEligibleForAutomatedDeposit(_circle, _member, balances[i]);
        }
      }

      return false;
    } catch {
      return false;
    }
  }
}
