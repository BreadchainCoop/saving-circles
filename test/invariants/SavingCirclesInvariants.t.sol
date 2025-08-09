// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SavingCircles} from '../../src/contracts/SavingCircles.sol';
import {ISavingCircles} from '../../src/interfaces/ISavingCircles.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {SavingCirclesHandler} from './handlers/SavingCirclesHandler.sol';
import {ERC1967Proxy} from '@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol';
import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {Test} from 'forge-std/Test.sol';

contract SavingCirclesInvariantsTest is StdInvariant, Test {
  SavingCircles public implementation;
  SavingCircles public savingCircles;
  MockERC20 public token;
  SavingCirclesHandler public handler;

  address public owner = makeAddr('owner');

  function setUp() public {
    implementation = new SavingCircles();

    bytes memory initData = abi.encodeWithSelector(SavingCircles.initialize.selector, owner);
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
    savingCircles = SavingCircles(address(proxy));

    token = new MockERC20('Test Token', 'TEST');

    vm.prank(owner);
    savingCircles.setTokenAllowed(address(token), true);

    handler = new SavingCirclesHandler(savingCircles, token);

    bytes4[] memory selectors = new bytes4[](7);
    selectors[0] = SavingCirclesHandler.createCircle.selector;
    selectors[1] = SavingCirclesHandler.deposit.selector;
    selectors[2] = SavingCirclesHandler.depositFor.selector;
    selectors[3] = SavingCirclesHandler.withdraw.selector;
    selectors[4] = SavingCirclesHandler.withdrawFor.selector;
    selectors[5] = SavingCirclesHandler.decommission.selector;
    selectors[6] = SavingCirclesHandler.warpTime.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    targetContract(address(handler));
  }

  function invariant_TokenBalanceConsistency() public view {
    uint256 contractBalance = token.balanceOf(address(savingCircles));
    uint256 totalDeposits = handler.getTotalDeposits();

    assertEq(contractBalance, totalDeposits, 'Contract token balance should equal sum of all deposits');
  }

  function invariant_CircleIndexBounds() public view {
    uint256[] memory circleIds = handler.getActiveCircles();

    for (uint256 i = 0; i < circleIds.length; i++) {
      ISavingCircles.Circle memory circle = savingCircles.getCircle(circleIds[i]);

      assertLe(circle.currentIndex, circle.members.length, 'Current index should never exceed member count');
    }
  }

  function invariant_MemberBalanceBounds() public view {
    uint256[] memory circleIds = handler.getActiveCircles();

    for (uint256 i = 0; i < circleIds.length; i++) {
      ISavingCircles.Circle memory circle = savingCircles.getCircle(circleIds[i]);

      for (uint256 j = 0; j < circle.members.length; j++) {
        uint256 balance = savingCircles.balances(circleIds[i], circle.members[j]);

        assertLe(balance, circle.depositAmount, 'Member balance should never exceed deposit amount');
      }
    }
  }

  function invariant_WithdrawalAmounts() public view {
    uint256 totalWithdrawn = handler.getTotalWithdrawn();
    uint256 expectedWithdrawals = handler.getExpectedWithdrawals();

    assertEq(totalWithdrawn, expectedWithdrawals, 'Total withdrawn should match expected withdrawal amounts');
  }

  function invariant_CircleMembershipConsistency() public view {
    uint256[] memory circleIds = handler.getActiveCircles();

    for (uint256 i = 0; i < circleIds.length; i++) {
      ISavingCircles.Circle memory circle = savingCircles.getCircle(circleIds[i]);

      assertGe(circle.members.length, 2, 'Circle should always have at least 2 members');

      for (uint256 j = 0; j < circle.members.length; j++) {
        assertTrue(
          savingCircles.isMember(circleIds[i], circle.members[j]), 'All circle members should be marked as members'
        );
      }
    }
  }

  function invariant_DecommissionedCirclesAreEmpty() public {
    uint256[] memory decommissionedIds = handler.getDecommissionedCircles();

    for (uint256 i = 0; i < decommissionedIds.length; i++) {
      vm.expectRevert(ISavingCircles.NotCommissioned.selector);
      savingCircles.getCircle(decommissionedIds[i]);
    }
  }

  function invariant_NoNegativeBalances() public view {
    uint256[] memory circleIds = handler.getActiveCircles();

    for (uint256 i = 0; i < circleIds.length; i++) {
      ISavingCircles.Circle memory circle = savingCircles.getCircle(circleIds[i]);

      for (uint256 j = 0; j < circle.members.length; j++) {
        uint256 balance = savingCircles.balances(circleIds[i], circle.members[j]);

        assertGe(balance, 0, 'Member balances should never be negative');
      }
    }
  }

  function invariant_ValidCircleParameters() public view {
    uint256[] memory circleIds = handler.getActiveCircles();

    for (uint256 i = 0; i < circleIds.length; i++) {
      ISavingCircles.Circle memory circle = savingCircles.getCircle(circleIds[i]);

      assertGt(circle.depositAmount, 0, 'Deposit amount should be greater than 0');
      assertGt(circle.depositInterval, 0, 'Deposit interval should be greater than 0');
      assertGt(circle.maxDeposits, 0, 'Max deposits should be greater than 0');
      assertGt(circle.circleStart, 0, 'Circle start time should be greater than 0');
      assertTrue(circle.owner != address(0), 'Circle should have valid owner');
    }
  }

  function invariant_TokenAllowanceConsistency() public view {
    assertTrue(savingCircles.isTokenAllowed(address(token)), 'Token should remain allowed throughout testing');
  }
}
