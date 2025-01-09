// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {Common} from 'script/Common.sol';

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

// solhint-disable-next-line
import 'script/Registry.sol';

contract IntegrationBase is Common, Test {
  SavingCircles public circle;
  MockERC20 public token;

  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public owner = makeAddr('owner');
  address[] public members;

  ISavingCircles.Circle public baseCircle;
  uint256 public baseCircleId;

  uint256 public constant DEPOSIT_AMOUNT = 1000e18;
  uint256 public constant DEPOSIT_INTERVAL = 7 days;
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant BASE_MAX_DEPOSITS = 1000;

  function setUp() public virtual override {
    super.setUp();

    vm.startPrank(owner);
    circle = SavingCircles(address(_deployContracts(owner)));
    token = new MockERC20('Test Token', 'TEST');
    vm.stopPrank();

    _setUpAccounts();

    baseCircle = ISavingCircles.Circle({
      owner: alice,
      members: members,
      currentIndex: BASE_CURRENT_INDEX,
      circleStart: block.timestamp,
      token: address(token),
      depositAmount: DEPOSIT_AMOUNT,
      depositInterval: DEPOSIT_INTERVAL,
      maxDeposits: BASE_MAX_DEPOSITS
    });
  }

  function createBaseCircle() public {
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    vm.prank(alice);
    baseCircleId = circle.create(baseCircle);
  }

  function _setUpAccounts() internal {
    vm.startPrank(alice);
    token.mint(alice, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(alice);
    vm.stopPrank();

    vm.startPrank(bob);
    token.mint(bob, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(bob);
    vm.stopPrank();

    vm.startPrank(carol);
    token.mint(carol, DEPOSIT_AMOUNT * 10);
    token.approve(address(circle), type(uint256).max);
    members.push(carol);
    vm.stopPrank();
  }
}
