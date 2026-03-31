// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AutomaticSavingCircles} from '../../src/contracts/AutomaticSavingCircles.sol';
import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {IAutomaticSavingCircles} from '../../src/interfaces/IAutomaticSavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {SavingCirclesTestBase} from '../utils/SavingCirclesTestBase.t.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

contract AutomaticSavingCirclesUnit is SavingCirclesTestBase {
  SavingCircles public savingCircles;
  AutomaticSavingCircles public automaticSavingCircles;
  MockERC20 public token;
  ProxyAdmin public proxyAdmin;

  address public owner = makeAddr('owner');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public carol = makeAddr('carol');
  address public gelatoExecutor = makeAddr('gelatoExecutor');
  uint256 internal _ownerPrivateKey;
  uint256 internal _alicePrivateKey;
  uint256 internal _bobPrivateKey;
  uint256 internal _carolPrivateKey;

  uint256 public constant DEPOSIT_AMOUNT = 1 ether;
  uint256 public constant DEPOSIT_INTERVAL = 1 weeks;

  uint256 public baseCircleId;
  ISavingCircles.Circle public baseCircle;
  address[] public members;

  function setUp() external {
    token = new MockERC20('Test Token', 'TEST');

    (owner, _ownerPrivateKey) = makeAddrAndKey('owner');
    (alice, _alicePrivateKey) = makeAddrAndKey('alice');
    (bob, _bobPrivateKey) = makeAddrAndKey('bob');
    (carol, _carolPrivateKey) = makeAddrAndKey('carol');

    proxyAdmin = new ProxyAdmin(owner);
    SavingCircles implementation = new SavingCircles();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation), address(proxyAdmin), abi.encodeWithSelector(SavingCircles.initialize.selector, owner)
    );
    savingCircles = SavingCircles(address(proxy));

    automaticSavingCircles = new AutomaticSavingCircles(address(savingCircles), owner);

    vm.prank(owner);
    automaticSavingCircles.setAutomationExecutor(gelatoExecutor);

    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;

    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);

    baseCircle = _defaultCircle(alice, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL, address(token));
    baseCircleId = _createCircleWithMembers(savingCircles, baseCircle, members, _alicePrivateKey);
  }

  function test_SetAutomaticDepositsEnabled() external {
    assertFalse(automaticSavingCircles.isAutomaticDepositsEnabled(alice));

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomaticDepositsToggled(alice, true);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    assertTrue(automaticSavingCircles.isAutomaticDepositsEnabled(alice));

    vm.prank(alice);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomaticDepositsToggled(alice, false);
    automaticSavingCircles.setAutomaticDepositsEnabled(false);

    assertFalse(automaticSavingCircles.isAutomaticDepositsEnabled(alice));
  }

  function test_SetAutomationExecutor() external {
    address newExecutor = makeAddr('newExecutor');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit IAutomaticSavingCircles.AutomationExecutorUpdated(gelatoExecutor, newExecutor);
    automaticSavingCircles.setAutomationExecutor(newExecutor);

    assertEq(automaticSavingCircles.automationExecutor(), newExecutor);
  }

  function test_SetAutomationExecutor_WhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
    automaticSavingCircles.setAutomationExecutor(makeAddr('newExecutor'));
  }

  function test_ExecuteAutomatedDeposit_WithSufficientAllowance() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    vm.prank(gelatoExecutor);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, DEPOSIT_AMOUNT);
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, alice);

    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
  }

  function test_ExecuteAutomatedDeposit_WhenCallerIsNotAutomationExecutor() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.OnlyAutomationExecutor.selector));
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, alice);
  }

  function test_ExecuteAutomatedDeposit_NotOptedIn() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    vm.prank(gelatoExecutor);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.AutomaticDepositsNotEnabled.selector));
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, alice);
  }

  function test_ExecuteAutomatedDeposit_WithInsufficientAllowance() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT / 2);

    vm.prank(gelatoExecutor);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.InsufficientAllowance.selector));
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, alice);
  }

  function test_ExecuteAutomatedDeposit_WithInsufficientBalance() external {
    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    vm.prank(gelatoExecutor);
    vm.expectRevert(abi.encodeWithSelector(IAutomaticSavingCircles.InsufficientBalance.selector));
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, alice);
  }

  function test_ExecuteAutomatedDeposit_WhenAlreadyDeposited() external {
    token.mint(alice, DEPOSIT_AMOUNT * 2);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.startPrank(alice);
    token.approve(address(savingCircles), DEPOSIT_AMOUNT);
    savingCircles.depositFor(baseCircleId, DEPOSIT_AMOUNT, alice);
    vm.stopPrank();

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    vm.prank(gelatoExecutor);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.AlreadyDeposited.selector));
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, alice);
  }

  function test_ExecuteAutomatedDeposit_PartialDeposit() external {
    uint256 partialAmount = DEPOSIT_AMOUNT / 2;
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.startPrank(alice);
    token.approve(address(savingCircles), partialAmount);
    savingCircles.depositFor(baseCircleId, partialAmount, alice);
    vm.stopPrank();

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), partialAmount);

    vm.prank(gelatoExecutor);
    vm.expectEmit(true, true, true, true);
    emit ISavingCircles.FundsDeposited(baseCircleId, alice, partialAmount);
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, alice);

    assertEq(savingCircles.balances(baseCircleId, alice), DEPOSIT_AMOUNT);
  }

  function test_ExecuteAutomatedDeposit_NotMember() external {
    address nonMember = makeAddr('nonMember');
    token.mint(nonMember, DEPOSIT_AMOUNT);

    vm.startPrank(nonMember);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);
    vm.stopPrank();

    vm.prank(gelatoExecutor);
    vm.expectRevert(abi.encodeWithSelector(ISavingCircles.NotMember.selector));
    automaticSavingCircles.executeAutomatedDeposit(baseCircleId, nonMember);
  }

  function test_Checker_ReturnsTrueAndExecPayloadWhenEligible() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.checker(baseCircleId, alice);

    assertTrue(canExec);
    assertEq(execPayload, abi.encodeCall(IAutomaticSavingCircles.executeAutomatedDeposit, (baseCircleId, alice)));
  }

  function test_Checker_ReturnsFalseWhenAutomationExecutorUnset() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    vm.prank(owner);
    automaticSavingCircles.setAutomationExecutor(address(0));

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.checker(baseCircleId, alice);

    assertFalse(canExec);
    assertEq(execPayload, abi.encodeCall(IAutomaticSavingCircles.executeAutomatedDeposit, (baseCircleId, alice)));
  }

  function test_Checker_ReturnsFalseWhenCircleNotStarted() external {
    uint256 unstartedCircleId = _createCircle(savingCircles, baseCircle, members, _alicePrivateKey);

    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.checker(unstartedCircleId, alice);

    assertFalse(canExec);
    assertEq(execPayload, abi.encodeCall(IAutomaticSavingCircles.executeAutomatedDeposit, (unstartedCircleId, alice)));
  }

  function test_Checker_ReturnsFalseWhenInsufficientBalance() external {
    vm.prank(alice);
    automaticSavingCircles.setAutomaticDepositsEnabled(true);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    (bool canExec,) = automaticSavingCircles.checker(baseCircleId, alice);

    assertFalse(canExec);
  }

  function test_Checker_ReturnsFalseWhenNotOptedIn() external {
    token.mint(alice, DEPOSIT_AMOUNT);

    vm.prank(alice);
    token.approve(address(automaticSavingCircles), DEPOSIT_AMOUNT);

    (bool canExec,) = automaticSavingCircles.checker(baseCircleId, alice);

    assertFalse(canExec);
  }

  function test_Checker_ReturnsFalseForMissingCircleWithoutReverting() external view {
    uint256 missingCircleId = type(uint256).max;

    (bool canExec, bytes memory execPayload) = automaticSavingCircles.checker(missingCircleId, alice);

    assertFalse(canExec);
    assertEq(execPayload, abi.encodeCall(IAutomaticSavingCircles.executeAutomatedDeposit, (missingCircleId, alice)));
  }
}
