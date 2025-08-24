// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISavingCircles} from '../interfaces/ISavingCircles.sol';
import {ISavingCirclesAutomatedDeposits} from '../interfaces/ISavingCirclesAutomatedDeposits.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';

/**
 * @title SavingCirclesAutomatedDeposits
 * @notice Extension contract for automated deposits in SavingCircles
 * @dev This contract enables automated ERC20 allowance-based deposits and batch operations
 */
contract SavingCirclesAutomatedDeposits is ISavingCirclesAutomatedDeposits, ReentrancyGuard {
  /// @notice The main SavingCircles contract
  ISavingCircles public immutable savingCircles;

  /// @notice Mapping to track which members have enabled automated deposits
  mapping(address member => bool enabled) public automatedDepositsEnabled;

  /**
   * @notice Constructor
   * @param _savingCircles Address of the main SavingCircles contract
   */
  constructor(address _savingCircles) {
    savingCircles = ISavingCircles(_savingCircles);
  }

  /// @inheritdoc ISavingCirclesAutomatedDeposits
  function setAutomatedDepositsEnabled(bool _enabled) external override {
    automatedDepositsEnabled[msg.sender] = _enabled;
    emit AutomatedDepositsToggled(msg.sender, _enabled);
  }

  /// @inheritdoc ISavingCirclesAutomatedDeposits
  function isAutomatedDepositsEnabled(address _member) external view override returns (bool) {
    return automatedDepositsEnabled[_member];
  }

  /// @inheritdoc ISavingCirclesAutomatedDeposits
  function depositIfAllowed(uint256 _circleId, address _member) external override nonReentrant {
    _depositIfAllowed(_circleId, _member);
  }

  /// @inheritdoc ISavingCirclesAutomatedDeposits
  function batchDepositIfAllowed(
    uint256[] calldata _circleIds,
    address[] calldata _members
  ) external override nonReentrant {
    // Validate array lengths match
    if (_circleIds.length != _members.length) revert ArrayLengthMismatch();

    for (uint256 i = 0; i < _circleIds.length; i++) {
      _depositIfAllowed(_circleIds[i], _members[i]);
    }
  }

  /// @inheritdoc ISavingCirclesAutomatedDeposits
  function getEligibleAddressesForDeposit()
    external
    view
    override
    returns (uint256[] memory circleIds, address[] memory members)
  {
    // First, count eligible members across all circles
    uint256 eligibleCount = 0;
    uint256 nextId = savingCircles.nextId();

    for (uint256 id = 0; id < nextId; id++) {
      // Skip if circle doesn't exist or is decommissioned
      try savingCircles.getCircle(id) returns (ISavingCircles.Circle memory _circle) {
        // Check if we're in a valid deposit window
        if (block.timestamp < _circle.circleStart) continue;

        uint256 depositWindowEnd = _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1));
        if (block.timestamp >= depositWindowEnd) continue;

        uint256 circleEnd = _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits);
        if (block.timestamp >= circleEnd) continue;

        for (uint256 j = 0; j < _circle.members.length; j++) {
          address member = _circle.members[j];
          if (!automatedDepositsEnabled[member]) continue; // Skip if not opted in

          uint256 currentBalance = savingCircles.balances(id, member);
          if (currentBalance >= _circle.depositAmount) continue; // Already deposited

          uint256 requiredAmount = _circle.depositAmount - currentBalance;
          uint256 allowance = IERC20(_circle.token).allowance(member, address(this));
          if (allowance >= requiredAmount) {
            eligibleCount++;
          }
        }
      } catch {
        // Circle doesn't exist or is decommissioned, skip it
        continue;
      }
    }

    // Allocate arrays
    circleIds = new uint256[](eligibleCount);
    members = new address[](eligibleCount);

    // Fill arrays
    uint256 index = 0;
    for (uint256 id = 0; id < nextId; id++) {
      try savingCircles.getCircle(id) returns (ISavingCircles.Circle memory _circle) {
        // Check if we're in a valid deposit window
        if (block.timestamp < _circle.circleStart) continue;

        uint256 depositWindowEnd = _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1));
        if (block.timestamp >= depositWindowEnd) continue;

        uint256 circleEnd = _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits);
        if (block.timestamp >= circleEnd) continue;

        for (uint256 j = 0; j < _circle.members.length; j++) {
          address member = _circle.members[j];
          if (!automatedDepositsEnabled[member]) continue; // Skip if not opted in

          uint256 currentBalance = savingCircles.balances(id, member);
          if (currentBalance >= _circle.depositAmount) continue; // Already deposited

          uint256 requiredAmount = _circle.depositAmount - currentBalance;
          uint256 allowance = IERC20(_circle.token).allowance(member, address(this));
          if (allowance >= requiredAmount) {
            circleIds[index] = id;
            members[index] = member;
            index++;
          }
        }
      } catch {
        continue;
      }
    }

    return (circleIds, members);
  }

  /**
   * @dev Internal function to handle automated deposits
   * @param _circleId Circle ID
   * @param _member Member address to deposit for
   */
  function _depositIfAllowed(uint256 _circleId, address _member) internal {
    // Check if automated deposits are enabled for this member
    if (!automatedDepositsEnabled[_member]) revert AutomatedDepositsNotEnabled();

    // Get circle information
    ISavingCircles.Circle memory _circle = savingCircles.getCircle(_circleId);

    // Check if member is part of the circle
    bool isMember = false;
    for (uint256 i = 0; i < _circle.members.length; i++) {
      if (_circle.members[i] == _member) {
        isMember = true;
        break;
      }
    }
    if (!isMember) revert ISavingCircles.NotMember();

    // Calculate the remaining deposit amount needed
    uint256 currentBalance = savingCircles.balances(_circleId, _member);
    if (currentBalance >= _circle.depositAmount) revert ISavingCircles.AlreadyDeposited();
    uint256 requiredAmount = _circle.depositAmount - currentBalance;

    // Check allowance (member must approve this extension contract)
    uint256 allowance = IERC20(_circle.token).allowance(_member, address(this));
    if (allowance < requiredAmount) revert InsufficientAllowance();

    // Check deposit window validity
    if (block.timestamp < _circle.circleStart) {
      revert ISavingCircles.DepositBeforeCircleStart();
    }
    // Check if current deposit window has closed (each window lasts depositInterval)
    if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1))) {
      revert ISavingCircles.DepositWindowClosed();
    }
    // Check if all deposit periods have passed (maxDeposits * depositInterval = total circle duration)
    if (block.timestamp >= _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits)) {
      revert ISavingCircles.CircleExpired();
    }

    // Transfer tokens from member to this contract
    bool transferSuccess = IERC20(_circle.token).transferFrom(_member, address(this), requiredAmount);
    if (!transferSuccess) revert ISavingCircles.TransferFailed();

    // Approve the main contract to spend the tokens
    IERC20(_circle.token).approve(address(savingCircles), requiredAmount);

    // Call depositFor on the main contract
    savingCircles.depositFor(_circleId, requiredAmount, _member);
  }
}
