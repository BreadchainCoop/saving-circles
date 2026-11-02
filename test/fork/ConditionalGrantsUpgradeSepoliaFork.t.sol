// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {ConditionalGrants} from '../../src/contracts/ConditionalGrants.sol';
import {IConditionalGrants} from '../../src/interfaces/IConditionalGrants.sol';

/**
 * @notice Upgrades the live Celo Sepolia proxy, which stored a terms hash instead of the agreement,
 *         to the current implementation and checks every existing grant reads and works the same.
 *         Run with: forge test --match-path test/fork/ConditionalGrantsUpgradeSepoliaFork.t.sol
 */
contract ConditionalGrantsUpgradeSepoliaForkTest is Test {
  /// @dev The terms struct as the old implementation returned it
  struct OldTerms {
    address token;
    uint256 advance;
    uint256 grant;
    uint256 fee;
    uint256 acceptBy;
    uint256 payBackPeriod;
    bytes32 termsHash;
  }

  string public constant RPC = 'https://forno.celo-sepolia.celo-testnet.org';
  ConditionalGrants public constant GRANTS = ConditionalGrants(0xb636fC0Ae8fa85d61b6953c88e0Ef613E7b70234);
  IERC20 public constant USDC = IERC20(0x01C5C0122039549AD1493B8220cABEdD739BC44E);
  bytes32 public constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

  uint256 internal _count;
  mapping(uint256 id => bytes oldGrant) internal _oldGrant;
  mapping(uint256 id => uint8 state) internal _oldState;
  mapping(uint256 id => uint256 outstanding) internal _oldOutstanding;

  function setUp() public {
    vm.createSelectFork(RPC);
    _count = GRANTS.nextId();
    for (uint256 _i = 0; _i < _count; _i++) {
      _oldGrant[_i] = _call(abi.encodeWithSignature('getGrant(uint256)', _i));
      _oldState[_i] = abi.decode(_call(abi.encodeWithSignature('grantState(uint256)', _i)), (uint8));
      _oldOutstanding[_i] = abi.decode(_call(abi.encodeWithSignature('outstanding(uint256)', _i)), (uint256));
    }

    ProxyAdmin _admin = ProxyAdmin(address(uint160(uint256(vm.load(address(GRANTS), ADMIN_SLOT)))));
    address _adminOwner = _admin.owner();
    address _implementation = address(new ConditionalGrants());
    vm.prank(_adminOwner);
    _admin.upgradeAndCall(ITransparentUpgradeableProxy(address(GRANTS)), _implementation, '');
  }

  function test_upgrade_keepsEveryGrant() public view {
    assertGt(_count, 20, 'expected the grants made before the upgrade');
    assertEq(GRANTS.nextId(), _count);
    for (uint256 _i = 0; _i < _count; _i++) {
      (OldTerms memory _old, IConditionalGrants.GrantStatus memory _oldStatus) =
        abi.decode(_oldGrant[_i], (OldTerms, IConditionalGrants.GrantStatus));
      (IConditionalGrants.GrantTerms memory _t, IConditionalGrants.GrantStatus memory _st) = GRANTS.getGrant(_i);

      assertEq(_t.token, _old.token, 'token');
      assertEq(_t.advance, _old.advance, 'advance');
      assertEq(_t.grant, _old.grant, 'grant');
      assertEq(_t.fee, _old.fee, 'fee');
      assertEq(_t.acceptBy, _old.acceptBy, 'acceptBy');
      assertEq(_t.payBackPeriod, _old.payBackPeriod, 'payBackPeriod');
      // Old grants only stored a hash, so there is no text to show
      assertEq(bytes(_t.agreement).length, 0, 'agreement');
      assertEq(abi.encode(_st), abi.encode(_oldStatus), 'status');
      assertEq(uint8(GRANTS.grantState(_i)), _oldState[_i], 'state');
      assertEq(GRANTS.outstanding(_i), _oldOutstanding[_i], 'outstanding');
    }
  }

  function test_upgrade_oldGrantsStillWork() public {
    for (uint256 _i = 0; _i < _count; _i++) {
      (IConditionalGrants.GrantTerms memory _t, IConditionalGrants.GrantStatus memory _st) = GRANTS.getGrant(_i);
      IConditionalGrants.GrantState _s = GRANTS.grantState(_i);

      if (_s == IConditionalGrants.GrantState.Offered) {
        // Accepting no longer takes the old terms hash
        uint256 _before = USDC.balanceOf(_st.grantee);
        vm.prank(_st.grantee);
        GRANTS.accept(_i);
        assertEq(USDC.balanceOf(_st.grantee), _before + _t.advance, 'accept paid the advance');
      } else if (_s == IConditionalGrants.GrantState.Expired) {
        uint256 _before = USDC.balanceOf(_st.grantor);
        vm.prank(_st.grantor);
        GRANTS.cancel(_i);
        assertEq(USDC.balanceOf(_st.grantor), _before + _st.held, 'cancel refunded');
        continue;
      } else if (_s != IConditionalGrants.GrantState.Active && _s != IConditionalGrants.GrantState.Overdue) {
        continue;
      }

      // Pay off whatever is owed, then release and collect
      uint256 _owed = GRANTS.outstanding(_i);
      deal(address(USDC), _st.grantee, USDC.balanceOf(_st.grantee) + _owed);
      vm.startPrank(_st.grantee);
      USDC.approve(address(GRANTS), _owed);
      GRANTS.payBack(_i, _owed);
      if (_t.grant > 0) GRANTS.releaseGrant(_i);
      vm.stopPrank();
      assertEq(uint8(GRANTS.grantState(_i)), uint8(IConditionalGrants.GrantState.Completed), 'completed');
      GRANTS.collect(_i);
    }
  }

  function test_upgrade_newGrantStoresAgreement() public {
    address _grantor = makeAddr('grantor');
    deal(address(USDC), _grantor, 2e6);
    IConditionalGrants.GrantTerms memory _t = IConditionalGrants.GrantTerms({
      token: address(USDC),
      advance: 1e6,
      grant: 1e6,
      fee: 0,
      acceptBy: block.timestamp + 1 days,
      payBackPeriod: 0,
      agreement: 'Pay back 1 USDC to receive a 1 USDC grant.'
    });
    vm.startPrank(_grantor);
    USDC.approve(address(GRANTS), 2e6);
    uint256 _id = GRANTS.create(_t, makeAddr('grantee'));
    vm.stopPrank();

    (IConditionalGrants.GrantTerms memory _stored,) = GRANTS.getGrant(_id);
    assertEq(_stored.agreement, _t.agreement);
    vm.prank(makeAddr('grantee'));
    GRANTS.accept(_id);
  }

  function _call(bytes memory _data) internal view returns (bytes memory _ret) {
    bool _ok;
    (_ok, _ret) = address(GRANTS).staticcall(_data);
    assertTrue(_ok, 'pre-upgrade read failed');
  }
}
