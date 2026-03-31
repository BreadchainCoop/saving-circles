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
 * @dev This contract exposes a Gelato-only automated deposit sweep across every circle
 */
contract AutomaticSavingCircles is IAutomaticSavingCircles, Ownable, ReentrancyGuard {
  /// @notice The main SavingCircles contract
  ISavingCircles public immutable SAVING_CIRCLES;

  /// @notice Dedicated Gelato msg.sender allowed to execute automated deposit sweeps
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
  function executeAutomatedDeposits() external override nonReentrant onlyAutomationExecutor {
    uint256 circleCount = SAVING_CIRCLES.nextId();

    for (uint256 circleId = 0; circleId < circleCount; circleId++) {
      _executeAutomatedDepositsForCircle(circleId);
    }
  }

  /// @inheritdoc IAutomaticSavingCircles
  function isAutomaticDepositsEnabled(address _member) external view override returns (bool) {
    return automaticDepositsEnabled[_member];
  }

  /// @inheritdoc IAutomaticSavingCircles
  function checker() external view override returns (bool canExec, bytes memory execPayload) {
    execPayload = abi.encodeCall(IAutomaticSavingCircles.executeAutomatedDeposits, ());
    if (automationExecutor == address(0)) return (false, execPayload);

    uint256 circleCount = SAVING_CIRCLES.nextId();
    for (uint256 circleId = 0; circleId < circleCount; circleId++) {
      if (_canExecuteAutomatedDepositsForCircle(circleId)) {
        return (true, execPayload);
      }
    }
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

  function _executeAutomatedDepositsForCircle(uint256 _circleId) internal {
    try SAVING_CIRCLES.getCircle(_circleId) returns (ISavingCircles.Circle memory _circle) {
      try SAVING_CIRCLES.getMemberBalances(_circleId) returns (address[] memory members, uint256[] memory balances) {
        if (!_isCircleEligibleForAutomation(_circleId, _circle, members.length)) return;

        IERC20 token = IERC20(_circle.token);
        for (uint256 i = 0; i < members.length; i++) {
          address member = members[i];
          uint256 currentBalance = balances[i];
          if (!_isEligibleForAutomatedDeposit(_circle, member, currentBalance)) continue;

          uint256 requiredAmount = _circle.depositAmount - currentBalance;

          token.safeTransferFrom(member, address(this), requiredAmount);
          token.forceApprove(address(SAVING_CIRCLES), requiredAmount);
          SAVING_CIRCLES.depositFor(_circleId, requiredAmount, member);
        }
      } catch {}
    } catch {}
  }

  function _canExecuteAutomatedDepositsForCircle(uint256 _circleId) internal view returns (bool) {
    try SAVING_CIRCLES.getCircle(_circleId) returns (ISavingCircles.Circle memory _circle) {
      try SAVING_CIRCLES.getMemberBalances(_circleId) returns (address[] memory members, uint256[] memory balances) {
        if (!_isCircleEligibleForAutomation(_circleId, _circle, members.length)) return false;

        for (uint256 i = 0; i < members.length; i++) {
          if (_isEligibleForAutomatedDeposit(_circle, members[i], balances[i])) {
            return true;
          }
        }
      } catch {}
    } catch {}

    return false;
  }

  function _isCircleEligibleForAutomation(
    uint256 _circleId,
    ISavingCircles.Circle memory _circle,
    uint256 _memberCount
  ) internal view returns (bool) {
    if (_circle.effectiveCircleStartTime == 0) return false;
    if (block.timestamp < _circle.effectiveCircleStartTime) return false;
    if (SAVING_CIRCLES.isDecommissionable(_circleId)) return false;
    if (_currentRoundIndex(_circle) >= _memberCount) return false;

    return true;
  }
}
