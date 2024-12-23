// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISavingCircles {
  struct Circle {
    address owner;
    string name;
    address[] members;
    uint256 currentIndex;
    uint256 depositAmount;
    address token;
    uint256 depositInterval;
    uint256 circleStart;
    uint256 maxDeposits;
  }

  event CircleCreated(
    bytes32 indexed id, string name, address[] members, address token, uint256 depositAmount, uint256 depositInterval
  );
  event CircleDecommissioned(bytes32 indexed id);
  event DepositMade(bytes32 indexed id, address indexed contributor, uint256 amount);
  event WithdrawalMade(bytes32 indexed id, address indexed withdrawer, uint256 amount);
  event TokenAllowed(address indexed token, bool indexed allowed);

  error AlreadyDeposited();
  error AlreadyExists();
  error InvalidDeposit();
  error InvalidIndex();
  error InvalidInterval();
  error InvalidMembers();
  error InvalidStart();
  error InvalidToken();
  error NotCommissioned();
  error NotMember();
  error NotOwner();
  error NotWithdrawable();
  error TransferFailed();

  // External functions (state-changing)
  function initialize(address owner) external;
  function setTokenAllowed(address token, bool allowed) external;
  function addCircle(Circle memory circle) external;
  function deposit(bytes32 id, uint256 value) external;
  function depositFor(bytes32 id, address member, uint256 value) external;
  function withdraw(bytes32 id) external;
  function decommissionCircle(bytes32 id) external;

  // External view functions
  function circle(bytes32 id) external view returns (Circle memory);
  function isTokenAllowed(address token) external view returns (bool);
  function balancesForCircle(bytes32 id) external view returns (address[] memory, uint256[] memory);
  function circleWithdrawable(bytes32 id) external view returns (bool);
  function circleMembers(bytes32 id) external view returns (address[] memory);
  function withdrawable(bytes32 id, address member) external view returns (bool);
}
