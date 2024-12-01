// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.23;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ISavingsCircle, SavingsCircle} from 'contracts/SavingsCircle.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingsCircleTest is Test {
  uint256 constant DEPOSIT_AMOUNT = 1 ether;
  uint256 constant DEPOSIT_INTERVAL = 1 days;

  // Test addresses
  address owner;
  address alice;
  address bob;
  address carol;
  IERC20 token;
  SavingsCircle circle;

  // Test data
  bytes32 baseCircleId;
  address[] members;

  function setUp() external {
    // Setup test addresses
    owner = makeAddr('owner');
    alice = makeAddr('alice');
    bob = makeAddr('bob');
    carol = makeAddr('carol');
    token = IERC20(makeAddr('token'));

    // Setup test data
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = carol;
    baseCircleId = keccak256(abi.encodePacked('Test Circle'));

    // Deploy and initialize the contract
    vm.startPrank(owner);
    SavingsCircle implementation = new SavingsCircle();
    ProxyAdmin proxyAdmin = new ProxyAdmin(owner);
    bytes memory initData = abi.encodeWithSelector(SavingsCircle.initialize.selector);
    TransparentUpgradeableProxy proxy =
      new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);
    circle = SavingsCircle(address(proxy));
    circle.allowlistToken(address(token));
    vm.stopPrank();

    // Create initial test circle
    vm.prank(alice);
    circle.addCircle('Test Circle', members, address(token), DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);
  }

  function test_AllowlistTokenWhenCallerIsNotOwner() external {
    // it reverts
  }

  function test_AllowlistTokenWhenCallerIsOwner() external {
    // it allowslists the token
    // it emits token allowedlisted event
  }

  function test_DenylistTokenWhenCallerIsNotOwner() external {
    // it reverts
  }

  function test_DenylistTokenWhenCallerIsOwner() external {
    // it denylists the token
    // it emits token deniedlisted event
  }

  function test_WhitelistTokenWhenCallerIsNotOwner() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
    circle.allowlistToken(address(0x1));
  }

  function test_WhitelistTokenWhenCallerIsOwner() external {
    address newToken = makeAddr('newToken');

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.TokenAllowlisted(newToken);
    circle.allowlistToken(newToken);

    assertTrue(circle.isTokenAllowlisted(newToken));
  }

  function test_AddCircleWhenCircleNameAlreadyExists() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.CircleExists.selector));
    circle.addCircle('Test Circle', members, address(token), DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);
  }

  function test_AddCircleWhenTokenIsNotWhitelisted() external {
    address nonWhitelistedToken = makeAddr('nonWhitelistedToken');
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidToken.selector));
    circle.addCircle('Test Circle 1', members, nonWhitelistedToken, DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);
  }

  function test_AddCircleWhenIntervalIsZero() external {
    // Create a new circle with zero interval
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidInterval.selector));
    circle.addCircle(
      'New Circle',
      members, // using the existing members array from setUp
      address(token),
      DEPOSIT_AMOUNT,
      0 // zero interval
    );
  }

  function test_AddCircleWhenDepositAmountIsZero() external {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidDeposit.selector));
    circle.addCircle(
      'New Circle',
      members,
      address(token),
      0, // zero deposit amount
      DEPOSIT_INTERVAL
    );
  }

  function test_AddCircleWhenMembersCountIsLessThanTwo() external {
    // Create array with only one member
    address[] memory singleMember = new address[](1);
    singleMember[0] = alice;

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ISavingsCircle.InvalidMembers.selector));
    circle.addCircle('New Circle', singleMember, address(token), DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);
  }

  function test_AddCircleWhenParametersAreValid() external {
    string memory circleName = 'New Valid Circle';
    bytes32 circleId = keccak256(abi.encodePacked(circleName));

    vm.prank(alice);

    // Test event emission
    vm.expectEmit(true, true, true, true);
    emit ISavingsCircle.CircleCreated(circleId, circleName, members, address(token), DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);

    circle.addCircle(circleName, members, address(token), DEPOSIT_AMOUNT, DEPOSIT_INTERVAL);

    // Verify circle data is stored correctly
    (
      string memory storedName,
      address[] memory storedMembers,
      address storedToken,
      uint256 storedDeposit,
      uint256 storedInterval,
      , // skip other return values
      ,
    ) = circle.circleInfo(circleId);

    assertEq(storedName, circleName);
    assertEq(storedMembers.length, members.length);
    assertEq(storedToken, address(token));
    assertEq(storedDeposit, DEPOSIT_AMOUNT);
    assertEq(storedInterval, DEPOSIT_INTERVAL);

    // Verify memberships are updated
    assertTrue(circle.isMember(circleId, alice));
    assertTrue(circle.isMember(circleId, bob));
    assertTrue(circle.isMember(circleId, carol));
  }

  function test_DepositWhenCircleDoesNotExist() external {
    // it reverts
  }

  modifier whenUserIsNotACircleMember() {
    _;
  }

  modifier whenTheUserIsDepositingOnBehalfOfAMember() {
    _;
  }

  function test_DepositWhenMemberHasAlreadyDeposited()
    external
    whenUserIsNotACircleMember
    whenTheUserIsDepositingOnBehalfOfAMember
  {
    // it reverts
  }

  function test_DepositWhenParametersAreValid()
    external
    whenUserIsNotACircleMember
    whenTheUserIsDepositingOnBehalfOfAMember
  {
    // it transfers tokens from depositor
    // it records member deposit
    // it updates round deposit count
    // it emits deposit made event
  }

  function test_DepositWhenDepositPeriodHasPassed() external {
    // it reverts
  }

  function test_DepositGivenMemberHasAlreadyDeposited() external {
    // it reverts
  }

  function test_WithdrawWhenCircleDoesNotExist() external {
    // it reverts
  }

  function test_WithdrawWhenUserIsNotACircleMember() external {
    // it reverts
  }

  function test_WithdrawWhenPayoutRoundHasNotEnded() external {
    // it reverts
  }

  function test_WithdrawWhenUserHasAlreadyClaimed() external {
    // it reverts
  }

  function test_WithdrawWhenUserMissedDeposits() external {
    // it reverts
  }

  function test_WithdrawWhenParametersAreValid() external {
    // it transfers payout amount to user
    // it marks payout as claimed
    // it emits payout claimed event
  }

  function test_CircleInfoWhenCircleDoesNotExist() external {
    // it reverts
  }

  function test_CircleInfoWhenCircleExists() external {
    // it returns correct circle information
  }

  function test_DecommissionWhenCallerIsNotOwner() external {
    // it reverts
  }

  function test_DecommissionWhenCircleDoesNotExist() external {
    // it reverts
  }

  function test_DecommissionWhenCircleHasActiveDeposits() external {
    // it reverts
  }

  function test_DecommissionWhenParametersAreValid() external {
    // it marks circle as decommissioned
    // it refunds remaining balances to members
    // it emits circle decommissioned event
  }
}
