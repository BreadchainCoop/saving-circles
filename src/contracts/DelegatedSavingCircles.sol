// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDelegatedSavingCircles} from '../interfaces/IDelegatedSavingCircles.sol';
import {ISavingCircles} from '../interfaces/ISavingCircles.sol';
import {SavingCircles} from './SavingCircles.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';

/**
 * @title DelegatedSavingCircles
 * @notice Extension contract for delegated deposits in SavingCircles
 * @dev This contract enables delegated ERC20 allowance-based deposits and batch operations
 */
contract DelegatedSavingCircles is IDelegatedSavingCircles, SavingCircles {
  /// @notice The main SavingCircles contract
  ISavingCircles public immutable SAVING_CIRCLES;

  /// @notice Mapping to track which members have enabled delegated deposits
  mapping(address member => bool enabled) public delegatedDepositsEnabled;

  /**
   * @notice Constructor
   * @param _savingCircles Address of the main SavingCircles contract
   */
  constructor(address _savingCircles) {
    SAVING_CIRCLES = ISavingCircles(_savingCircles);
  }

  /// @inheritdoc IDelegatedSavingCircles
  function setDelegatedDepositsEnabled(bool _enabled) external override {
    delegatedDepositsEnabled[msg.sender] = _enabled;
    emit DelegatedDepositsToggled(msg.sender, _enabled);
  }

  /// @inheritdoc IDelegatedSavingCircles
  function depositIfAllowed(uint256 _circleId, address _member) external override nonReentrant {
    _depositIfAllowed(_circleId, _member);
  }

  /// @inheritdoc IDelegatedSavingCircles
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

  /// @inheritdoc IDelegatedSavingCircles
  function isDelegatedDepositsEnabled(address _member) external view override returns (bool) {
    return delegatedDepositsEnabled[_member];
  }

  /// @inheritdoc IDelegatedSavingCircles
  function getAddressesForDeposit()
    external
    view
    override
    returns (uint256[] memory circleIds, address[] memory members)
  {
    // First, count eligible members across all circles
    uint256 eligibleCount = 0;
    uint256 nextId = SAVING_CIRCLES.nextId();

    for (uint256 id = 0; id < nextId; id++) {
      // Skip if circle doesn't exist or is decommissioned
      try SAVING_CIRCLES.getCircle(id) returns (ISavingCircles.Circle memory _circle) {
        // Check if we're in a valid deposit window
        if (block.timestamp < _circle.circleStart) continue;

        uint256 depositWindowEnd = _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1));
        if (block.timestamp >= depositWindowEnd) continue;

        uint256 circleEnd = _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits);
        if (block.timestamp >= circleEnd) continue;

        for (uint256 j = 0; j < _circle.members.length; j++) {
          address member = _circle.members[j];
          if (!delegatedDepositsEnabled[member]) continue; // Skip if not opted in

          uint256 currentBalance = SAVING_CIRCLES.balances(id, member);
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
      try SAVING_CIRCLES.getCircle(id) returns (ISavingCircles.Circle memory _circle) {
        // Check if we're in a valid deposit window
        if (block.timestamp < _circle.circleStart) continue;

        uint256 depositWindowEnd = _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1));
        if (block.timestamp >= depositWindowEnd) continue;

        uint256 circleEnd = _circle.circleStart + (_circle.depositInterval * _circle.maxDeposits);
        if (block.timestamp >= circleEnd) continue;

        for (uint256 j = 0; j < _circle.members.length; j++) {
          address member = _circle.members[j];
          if (!delegatedDepositsEnabled[member]) continue; // Skip if not opted in

          uint256 currentBalance = SAVING_CIRCLES.balances(id, member);
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
   * @dev Internal function to handle delegated deposits
   * @param _circleId Circle ID
   * @param _member Member address to deposit for
   */
  function _depositIfAllowed(uint256 _circleId, address _member) internal {
    // Check if delegated deposits are enabled for this member
    if (!delegatedDepositsEnabled[_member]) revert DelegatedDepositsNotEnabled();

    // Get circle information
    ISavingCircles.Circle memory _circle = SAVING_CIRCLES.getCircle(_circleId);

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
    uint256 currentBalance = SAVING_CIRCLES.balances(_circleId, _member);
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
    IERC20(_circle.token).approve(address(SAVING_CIRCLES), requiredAmount);

    // Call depositFor on the main contract
    SAVING_CIRCLES.depositFor(_circleId, requiredAmount, _member);
  }
}
