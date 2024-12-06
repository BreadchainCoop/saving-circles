// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISavingsCircle {
  struct Circle {
    address owner;
    string name;
    address[] members;
    uint256 currentIndex;
    uint256 depositAmount;
    address tokenAddress;
    uint256 depositInterval;
    uint256 circleStart;
    uint256 maxDeposits;
  }

  event CircleCreated(
    bytes32 indexed circleIdentifier,
    string name,
    address[] members,
    address tokenAddress,
    uint256 depositAmount,
    uint256 depositInterval
  );
  event DepositMade(bytes32 indexed circleIdentifier, address indexed contributor, uint256 amount);
  event WithdrawalMade(bytes32 indexed circleIdentifier, address indexed withdrawer, uint256 amount);
  event TokenAllowlisted(address indexed token);
  event TokenDenylisted(address indexed token);
  event CircleDecommissioned(bytes32 indexed circleIdentifier);

  error InvalidToken();
  error InvalidInterval();
  error InvalidDeposit();
  error InvalidMembers();
  error CircleNotFound();
  error NotMember();
  error NotOwner();
  error NotWithdrawable();
  error CircleExists();
  error AlreadyDeposited();
  error InvalidStart();
  error InvalidIndex();
  // External functions (state-changing)

  function initialize() external;
  function allowlistToken(address token) external;
  function denylistToken(address token) external;
  function addCircle(Circle memory circle) external;
  function deposit(bytes32 circleIdentifier, uint256 value) external;
  function depositFor(bytes32 circleIdentifier, address member, uint256 value) external;
  function withdraw(bytes32 circleIdentifier) external;
  function decommissionCircle(bytes32 circleIdentifier) external;

  // External view functions
  function isTokenAllowlisted(address token) external view returns (bool);
  function circleInfo(bytes32 circleIdentifier)
    external
    view
    returns (
      string memory name,
      address[] memory members,
      address tokenAddress,
      uint256 depositAmount,
      uint256 depositInterval,
      uint256 circleStart,
      uint256 numWithdrawals,
      uint256 currentIndex
    );
  function balancesForCircle(bytes32 circleIdentifier) external view returns (address[] memory, uint256[] memory);
  function circleWithdrawable(bytes32 circleIdentifier) external view returns (bool);
  function circleMembers(bytes32 circleIdentifier) external view returns (address[] memory);
  function withdrawable(bytes32 circleIdentifier, address member) external view returns (bool);
}
