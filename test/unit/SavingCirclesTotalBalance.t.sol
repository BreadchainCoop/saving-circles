// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {MockERC20} from '../mocks/MockERC20.sol';
import {ISavingCircles, SavingCircles} from 'contracts/SavingCircles.sol';

/**
 * @title SavingCirclesTotalBalanceTest
 * @notice Unit tests for the `getTotalBalance` function on SavingCircles
 */
contract SavingCirclesTotalBalanceTest is Test {
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 days;
  uint256 public constant MAX_DEPOSITS = 1000;

  SavingCircles public savingCircles;
  MockERC20 public token;

  // Test addresses
  address public owner;
  address public alice;
  address public bob;
  address public carol;
  address public immutable STRANGER = makeAddr('stranger');

  // Base circle data
  uint256 public baseCircleId;
  address[] public members;
  ISavingCircles.Circle public baseCircle;

  function setUp() external {
    // Setup addresses
    owner = makeAddr('owner');
    alice = makeAddr('alice');
    bob = makeAddr('bob');
    carol = makeAddr('carol');

    // Deploy SavingCircles behind proxy
    vm.startPrank(owner);
    savingCircles = SavingCircles(
      address(
        new TransparentUpgradeableProxy(
          address(new SavingCircles()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
        )
      )
    );

    // Deploy and whitelist mock ERC20 token
    token = new MockERC20('Test Token', 'TEST');
    savingCircles.setTokenAllowed(address(token), true);
    vm.stopPrank();

    // Configure members array
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    // Prepare base circle struct
    baseCircle = ISavingCircles.Circle({
      owner: owner,
      members: members,
      currentIndex: BASE_CURRENT_INDEX,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: MAX_DEPOSITS
    });

    // Create the first circle
    vm.prank(alice);
    baseCircleId = savingCircles.create(baseCircle);
  }

  /**
   * @notice Ensures getTotalBalance sums a member's balances across multiple circles
   */
  function test_GetTotalBalanceAggregatesAcrossCircles() external {
    // Create a second circle with same parameters but different owner
    ISavingCircles.Circle memory secondCircle = baseCircle;
    secondCircle.owner = bob;
    vm.prank(bob);
    uint256 secondCircleId = savingCircles.create(secondCircle);

    // Prepare deposits: full amount in first circle, half in second
    uint256 firstDeposit = DEPOSIT_AMOUNT;
    uint256 secondDeposit = DEPOSIT_AMOUNT / 2;

    // Mint and approve tokens for Alice
    token.mint(alice, firstDeposit + secondDeposit);
    vm.startPrank(alice);
    token.approve(address(savingCircles), firstDeposit + secondDeposit);

    // Perform deposits
    savingCircles.deposit(baseCircleId, firstDeposit);
    savingCircles.deposit(secondCircleId, secondDeposit);
    vm.stopPrank();

    // Expected total balance across both circles
    uint256 expectedTotal = firstDeposit + secondDeposit;

    uint256 totalBalance = savingCircles.getTotalBalance(alice);
    assertEq(totalBalance, expectedTotal, 'Total balance mismatch');
  }

  /**
   * @notice Ensures getTotalBalance returns zero when member has no balances
   */
  function test_GetTotalBalanceWhenNoDeposits() external {
    uint256 totalBalance = savingCircles.getTotalBalance(STRANGER);
    assertEq(totalBalance, 0, 'Total balance for non-member should be zero');
  }
}
