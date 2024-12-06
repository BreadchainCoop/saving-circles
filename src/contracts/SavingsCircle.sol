// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISavingsCircle} from '../interfaces/ISavingsCircle.sol';
import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';

contract SavingsCircle is ISavingsCircle, ReentrancyGuard, OwnableUpgradeable {
  mapping(bytes32 circleIdentifier => Circle circle) public circles;
  mapping(bytes32 circleIdentifier => mapping(address => uint256)) public circleBalances;
  mapping(address token => bool status) public allowlistedTokens;
  mapping(bytes32 circleIdentifier => mapping(address member => bool status)) public isMember;

  modifier validDeposit(bytes32 circleIdentifier, uint256 value, address member) {
    if (
      block.timestamp
        >= circles[circleIdentifier].circleStart
          + (circles[circleIdentifier].depositInterval * circles[circleIdentifier].currentIndex)
        || block.timestamp
          >= circles[circleIdentifier].circleStart
            + (circles[circleIdentifier].depositInterval * circles[circleIdentifier].maxDeposits)
        || circleBalances[circleIdentifier][member] + value >= circles[circleIdentifier].depositAmount
    ) revert InvalidDeposit();
    _;
  }
  /// @custom:oz-upgrades-unsafe-allow constructor

  constructor() {
    _disableInitializers();
  }

  function initialize() external override initializer {
    __Ownable_init_unchained(msg.sender);
  }

  function addCircle(Circle memory circle) external override {
    bytes32 circleIdentifier = keccak256(abi.encodePacked(circle.name));
    if (circles[circleIdentifier].members.length != 0) revert CircleExists();
    if (!allowlistedTokens[circle.tokenAddress]) revert InvalidToken();
    if (circle.depositInterval == 0) revert InvalidInterval();
    if (circle.depositAmount == 0) revert InvalidDeposit();
    if (circle.members.length < 2) revert InvalidMembers();
    if (circle.maxDeposits == 0) revert InvalidDeposit();
    if (circle.circleStart == 0) revert InvalidStart();
    if (circle.currentIndex != 0) revert InvalidIndex();

    circles[circleIdentifier] = circle;
    Circle storage newCircle = circles[circleIdentifier];
    for (uint256 i = 0; i < newCircle.members.length; i++) {
      isMember[circleIdentifier][newCircle.members[i]] = true;
    }

    emit CircleCreated(
      circleIdentifier, circle.name, circle.members, circle.tokenAddress, circle.depositAmount, circle.depositInterval
    );
  }

  function allowlistToken(address token) external override onlyOwner {
    allowlistedTokens[token] = true;
    emit TokenAllowlisted(token);
  }

  function denylistToken(address token) external override onlyOwner {
    allowlistedTokens[token] = false;
    emit TokenDenylisted(token);
  }

  function deposit(
    bytes32 circleIdentifier,
    uint256 value
  ) external override nonReentrant validDeposit(circleIdentifier, value, msg.sender) {
    if (!isMember[circleIdentifier][msg.sender]) revert NotMember();
    _deposit(circleIdentifier, msg.sender, value);
  }

  function depositFor(
    bytes32 circleIdentifier,
    address member,
    uint256 value
  ) external override nonReentrant validDeposit(circleIdentifier, value, member) {
    _deposit(circleIdentifier, member, value);
  }

  function withdraw(bytes32 circleIdentifier) external override nonReentrant {
    if (!circleWithdrawable(circleIdentifier)) revert NotWithdrawable();
    Circle storage circle = circles[circleIdentifier];
    if (circle.members.length == 0) revert CircleNotFound();
    if (circle.members[circle.currentIndex] != msg.sender) revert NotWithdrawable();

    uint256 withdrawAmount = circle.depositAmount * (circle.members.length);

    for (uint256 i = 0; i < circle.members.length; i++) {
      circleBalances[circleIdentifier][circle.members[i]] = 0;
    }

    circle.currentIndex = (circle.currentIndex + 1) % circle.members.length;
    IERC20(circle.tokenAddress).transfer(msg.sender, withdrawAmount);
    emit WithdrawalMade(circleIdentifier, msg.sender, withdrawAmount);
  }

  function decommissionCircle(bytes32 circleIdentifier) external override onlyOwner {
    Circle storage circle = circles[circleIdentifier];
    if (circle.members.length == 0) revert CircleNotFound();
    if (circle.owner != msg.sender) revert NotOwner();

    // Return all deposits to members
    for (uint256 i = 0; i < circle.members.length; i++) {
      address member = circle.members[i];
      uint256 balance = circleBalances[circleIdentifier][member];
      if (balance > 0) {
        circleBalances[circleIdentifier][member] = 0;
        IERC20(circle.tokenAddress).transfer(member, balance);
      }
    }

    delete circles[circleIdentifier];
    emit CircleDecommissioned(circleIdentifier);
  }

  function isTokenAllowlisted(address token) external view override returns (bool) {
    return allowlistedTokens[token];
  }

  function circleMembers(bytes32 circleIdentifier) external view override returns (address[] memory) {
    return circles[circleIdentifier].members;
  }

  function circleInfo(bytes32 circleIdentifier)
    external
    view
    override
    returns (
      string memory name,
      address[] memory members,
      address tokenAddress,
      uint256 depositAmount,
      uint256 depositInterval,
      uint256 circleStart,
      uint256 numWithdrawals,
      uint256 currentIndex
    )
  {
    Circle storage circle = circles[circleIdentifier];
    if (circle.members.length == 0) revert CircleNotFound();
    return (
      circle.name,
      circle.members,
      circle.tokenAddress,
      circle.depositAmount,
      circle.depositInterval,
      circle.circleStart,
      circle.currentIndex,
      circle.maxDeposits
    );
  }

  function balancesForCircle(bytes32 circleIdentifier)
    external
    view
    override
    returns (address[] memory, uint256[] memory)
  {
    Circle storage circle = circles[circleIdentifier];
    if (circle.members.length == 0) revert CircleNotFound();

    uint256[] memory balances = new uint256[](circle.members.length);
    for (uint256 i = 0; i < circle.members.length; i++) {
      balances[i] = circleBalances[circleIdentifier][circle.members[i]];
    }

    return (circle.members, balances);
  }

  function withdrawable(bytes32 circleIdentifier, address member) external view override returns (bool) {
    if (!isMember[circleIdentifier][member]) revert NotMember();
    Circle storage circle = circles[circleIdentifier];
    if (circle.members.length == 0) revert CircleNotFound();
    uint256 currentIndex = circle.currentIndex;
    return circle.members[currentIndex] == member;
  }

  function circleWithdrawable(bytes32 hashedName) public view override returns (bool) {
    Circle storage circle = circles[hashedName];
    if (circle.members.length == 0) revert CircleNotFound();

    // Check if enough time has passed since circle start for current withdrawal
    if (block.timestamp < circle.circleStart + (circle.depositInterval * circle.currentIndex)) {
      return false;
    }

    // Check if all members have made their initial deposit
    for (uint256 i = 0; i < circle.members.length; i++) {
      if (circleBalances[hashedName][circle.members[i]] < circle.depositAmount) {
        return false;
      }
    }

    return true;
  }

  function _deposit(bytes32 circleIdentifier, address member, uint256 value) internal {
    Circle storage circle = circles[circleIdentifier];
    if (circle.members.length == 0) revert CircleNotFound();
    if (!isMember[circleIdentifier][member]) revert NotMember();

    IERC20(circle.tokenAddress).transferFrom(msg.sender, address(this), value);

    circleBalances[circleIdentifier][member] = circleBalances[circleIdentifier][member] + value;
    emit DepositMade(circleIdentifier, member, value);
  }
}
