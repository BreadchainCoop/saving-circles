// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Common} from 'script/Common.sol';

import {SavingCircles} from 'contracts/SavingCircles.sol';
import {ISavingCircles} from 'interfaces/ISavingCircles.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';
import {SavingCirclesTestBase} from 'test/utils/SavingCirclesTestBase.t.sol';

// solhint-disable-next-line
import 'script/Registry.sol';

contract IntegrationBase is Common, SavingCirclesTestBase {
  SavingCircles public circle;
  MockERC20 public token;

  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public owner = makeAddr('owner');
  uint256 internal alicePrivateKey;
  uint256 internal bobPrivateKey;
  uint256 internal carolPrivateKey;
  uint256 internal ownerPrivateKey;
  address[] public members;

  ISavingCircles.Circle public baseCircle;
  uint256 public baseCircleId;
  uint256 public baseCircleStart;

  uint256 public constant DEPOSIT_AMOUNT = 1000e18;
  uint256 public constant DEPOSIT_INTERVAL = 7 days;
  uint256 public constant BASE_CURRENT_INDEX = 0;
  uint256 public constant BASE_MAX_DEPOSITS = 1000;

  function setUp() public virtual override {
    super.setUp();

    (owner, ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, alicePrivateKey) = makeAddrAndKey('alice');
    (bob, bobPrivateKey) = makeAddrAndKey('bob');
    (carol, carolPrivateKey) = makeAddrAndKey('carol');

    vm.startPrank(owner);
    circle = SavingCircles(address(_deployContracts(owner)));
    token = new MockERC20('Test Token', 'TEST');
    vm.stopPrank();

    _setUpAccounts();

    baseCircle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));
  }

  function createBaseCircle() public {
    vm.prank(owner);
    circle.setTokenAllowed(address(token), true);

    baseCircleId = _createCircleWithMembers(circle, baseCircle, members, alicePrivateKey);
    baseCircleStart = circle.getCircle(baseCircleId).effectiveCircleStartTime;
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
