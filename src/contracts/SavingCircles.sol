// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';

import {ISavingCircles} from '../interfaces/ISavingCircles.sol';

/**
 * @title Saving Circles
 * @notice TODO
 * @author Breadchain Collective
 * @author @RonTuretzky
 * @author @bagelface
 */
contract SavingCircles is ISavingCircles, ReentrancyGuard, OwnableUpgradeable {
  uint256 public constant MINIMUM_MEMBERS = 2;

  mapping(bytes32 id => Circle circle) public circles;
  mapping(address token => bool status) public allowedTokens;
  mapping(bytes32 id => mapping(address token => uint256 balance)) public balances;
  mapping(bytes32 id => mapping(address member => bool status)) public isMember;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _owner) external override initializer {
    __Ownable_init_unchained(_owner);
  }

  /**
   * @notice Commission a new saving circle
   * @param _circle A new saving circle
   */
  function addCircle(Circle memory _circle) external override {
    bytes32 _id = keccak256(abi.encodePacked(_circle.name));

    if (circles[_id].owner != address(0)) revert AlreadyExists();
    if (
      !allowedTokens[_circle.token] || _circle.depositInterval == 0 || _circle.depositAmount == 0
        || _circle.maxDeposits == 0 || _circle.circleStart == 0 || _circle.currentIndex != 0
        || _circle.owner == address(0) || _circle.members.length < MINIMUM_MEMBERS
    ) revert InvalidCircle();

    for (uint256 i = 0; i < _circle.members.length; i++) {
      address _member = _circle.members[i];
      if (_member == address(0)) revert InvalidCircle();
      isMember[_id][_member] = true;
    }
    circles[_id] = _circle;

    emit CircleCreated(
      _id, _circle.name, _circle.members, _circle.token, _circle.depositAmount, _circle.depositInterval
    );
  }

  /**
   * @notice Make a deposit into a specified circle
   * @param _id Identifier of the circle
   * @param _value Amount of the token to deposit
   */
  function deposit(bytes32 _id, uint256 _value) external override nonReentrant {
    _deposit(_id, msg.sender, _value);
  }

  /**
   * @notice Make a deposit on behalf of another member
   * @param _id Identifier of the circle
   * @param _member Address to make a deposit for
   * @param _value Amount of the token to deposit
   */
  function depositFor(bytes32 _id, address _member, uint256 _value) external override nonReentrant {
    _deposit(_id, _member, _value);
  }

  /**
   * @notice Make a withdrawal from a specified circle
   * @param _id Identifier of the circle
   */
  function withdraw(bytes32 _id) external override nonReentrant {
    Circle storage _circle = circles[_id];

    if (!_withdrawable(_id)) revert NotWithdrawable();
    if (_circle.members[_circle.currentIndex] != msg.sender) revert NotWithdrawable();

    uint256 _withdrawAmount = _circle.depositAmount * (_circle.members.length);

    for (uint256 i = 0; i < _circle.members.length; i++) {
      balances[_id][_circle.members[i]] = 0;
    }

    _circle.currentIndex = (_circle.currentIndex + 1) % _circle.members.length;
    bool success = IERC20(_circle.token).transfer(msg.sender, _withdrawAmount);
    if (!success) revert TransferFailed();

    emit WithdrawalMade(_id, msg.sender, _withdrawAmount);
  }

  /**
   * @notice Set if a token can be used for saving circles
   * @param _token Token to update the status of
   * @param _allowed Can be used for saving circles
   */
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    allowedTokens[_token] = _allowed;

    emit TokenAllowed(_token, _allowed);
  }

  /**
   * @notice Decommission an existing saving circle
   * @dev Returns all deposits to members
   * @param _id Identifier of the circle
   */
  function decommissionCircle(bytes32 _id) external override {
    Circle storage _circle = circles[_id];

    if (_circle.owner != msg.sender) revert NotOwner();

    for (uint256 i = 0; i < _circle.members.length; i++) {
      address _member = _circle.members[i];
      uint256 _balance = balances[_id][_member];
      if (_balance > 0) {
        balances[_id][_member] = 0;
        IERC20(_circle.token).transfer(_member, _balance);
      }
    }

    delete circles[_id];

    emit CircleDecommissioned(_id);
  }

  /**
   * @notice Return if a token is allowed to be used for saving circles
   * @param _token Address of a token
   * @return bool Token allowed
   */
  function isTokenAllowed(address _token) external view override returns (bool) {
    return allowedTokens[_token];
  }

  /**
   * @notice Return the info of a specified saving circle
   * @param _id Identifier of the circle
   * @return _circle Saving circle
   */
  function circle(bytes32 _id) external view override returns (Circle memory _circle) {
    _circle = circles[_id];

    if (_isDecommissioned(_circle)) revert NotCommissioned();

    return _circle;
  }

  /**
   * @notice TODO
   * @param _id TODO
   */
  function balancesForCircle(bytes32 _id)
    external
    view
    override
    returns (address[] memory _members, uint256[] memory _balances)
  {
    Circle memory _circle = circles[_id];

    if (_isDecommissioned(_circle)) revert NotCommissioned();

    _balances = new uint256[](_circle.members.length);
    for (uint256 i = 0; i < _circle.members.length; i++) {
      _balances[i] = balances[_id][_circle.members[i]];
    }

    return (_circle.members, _balances);
  }

  /**
   * @notice TODO
   * @param _id TODO
   * @param _member TODO
   */
  function withdrawableBy(bytes32 _id, address _member) external view override returns (bool) {
    Circle memory _circle = circles[_id];

    if (_isDecommissioned(_circle)) revert NotCommissioned();
    if (!isMember[_id][_member]) revert NotMember();

    return _circle.members[_circle.currentIndex] == _member;
  }

  /**
   * @notice TODO
   * @param _id TODO
   */
  function withdrawable(bytes32 _id) external view override returns (bool) {
    return _withdrawable(_id);
  }

  function _deposit(bytes32 _id, address _member, uint256 _value) internal {
    Circle memory _circle = circles[_id];

    if (_isDecommissioned(_circle)) revert NotCommissioned();
    if (!isMember[_id][_member]) revert NotMember();
    if (
      block.timestamp < circles[_id].circleStart
        || block.timestamp >= circles[_id].circleStart + (circles[_id].depositInterval * (circles[_id].currentIndex + 1))
        || block.timestamp >= circles[_id].circleStart + (circles[_id].depositInterval * circles[_id].maxDeposits)
        || balances[_id][_member] + _value > circles[_id].depositAmount
    ) revert InvalidDeposit();

    balances[_id][_member] = balances[_id][_member] + _value;

    bool success = IERC20(_circle.token).transferFrom(msg.sender, address(this), _value);
    if (!success) revert TransferFailed();

    emit DepositMade(_id, _member, _value);
  }

  function _withdrawable(bytes32 _id) internal view returns (bool) {
    Circle memory _circle = circles[_id];

    if (_isDecommissioned(_circle)) revert NotCommissioned();

    // Check if enough time has passed since circle start for current withdrawal
    if (block.timestamp < _circle.circleStart + (_circle.depositInterval * _circle.currentIndex)) {
      return false;
    }

    // Check if all members have made their initial deposit
    for (uint256 i = 0; i < _circle.members.length; i++) {
      if (balances[_id][_circle.members[i]] < _circle.depositAmount) {
        return false;
      }
    }

    return true;
  }

  function _isDecommissioned(Circle memory _circle) internal pure returns (bool) {
    return _circle.owner == address(0);
  }
}
