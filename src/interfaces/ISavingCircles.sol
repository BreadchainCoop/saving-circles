// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISavingCircles {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  struct Circle {
    address owner;
    address[] members;
    uint256 currentIndex;
    uint256 depositAmount;
    address token;
    uint256 depositInterval;
    uint256 circleStart;
    uint256 maxDeposits;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  event CircleCreated(
    uint256 indexed id, address[] members, address token, uint256 depositAmount, uint256 depositInterval
  );
  event CircleDecommissioned(uint256 indexed id);
  event FundsDeposited(uint256 indexed id, address indexed member, uint256 amount);
  event FundsWithdrawn(uint256 indexed id, address indexed member, uint256 amount);
  event TokenAllowed(address indexed token, bool indexed allowed);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  error AlreadyDeposited();
  error AlreadyExists();
  error InvalidDeposit();
  error InvalidCircle();
  error NotCommissioned();
  error NotMember();
  error NotDecommissionable();
  error NotWithdrawable();
  error TransferFailed();

  /*///////////////////////////////////////////////////////////////
                            VIEW
  //////////////////////////////////////////////////////////////*/

  function initialize(address owner) external;
  function setTokenAllowed(address token, bool allowed) external;
  function create(Circle memory circle) external returns (uint256);
  function deposit(uint256 id, uint256 value) external;
  function depositFor(uint256 id, uint256 value, address member) external;
  function withdraw(uint256 id) external;
  function withdrawFor(uint256 id, address member) external;
  function decommission(uint256 id) external;

  /*///////////////////////////////////////////////////////////////
                            VIEW
  //////////////////////////////////////////////////////////////*/

  function circle(uint256 id) external view returns (Circle memory);
  function isTokenAllowed(address token) external view returns (bool);
  function memberBalances(uint256 id) external view returns (address[] memory, uint256[] memory);
  function withdrawable(uint256 id) external view returns (bool);
  function withdrawableBy(uint256 id) external view returns (address);
}
