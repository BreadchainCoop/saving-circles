// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {SavingCircles} from 'contracts/SavingCircles.sol';
import {IYieldModule} from 'interfaces/IYieldModule.sol';

using SafeERC20 for IERC20;

/**
 * @title YieldSavingCircles
 * @notice A yield-bearing ROSCA. Deposits are routed into a crowdstake.fun yield
 *         module (sDAI on Gnosis) so principal earns yield while the circle runs.
 * @author Breadchain Collective
 * @dev  ============================ DRAFT / NOT YET COMPILED ============================
 *       Written without a local Solidity toolchain (agent sandbox was out of disk).
 *       Compilation, tests, and an accounting/security review are REQUIRED before use.
 *       Tracking issue: BreadchainCoop/saving-circles#189.
 *       ================================================================================
 *
 *       Agreed yield model (issue #189):
 *       - Base = per-member, time-weighted accrual. Each deposit earns yield for the
 *         depositor for as long as it sits staked -> earlier deposits earn more. This is
 *         implemented with a MasterChef-style global accumulator over staked principal.
 *       - Claimant option: when a member claims their round's pot they may either take it
 *         (redeem principal to their wallet, yield on it stops) or LEAVE IT STAKED so the
 *         pot keeps compounding for THEM until they pull it (`claim(id, keepStaked=true)`).
 *       - Claim-timing is modular per circle: yield claimable ANYTIME or only ONCE THE
 *         CIRCLE ENDS ({ClaimTiming}). Set via {setClaimTiming} before the circle starts.
 *       - No forfeiture (out of scope for v1).
 *
 *       Token model: v1 treats the circle token as the yield module's underlying
 *       (identity wrap). To keep BREAD user-facing (burn BREAD -> xDAI -> stake to sDAI,
 *       and reverse on payout) override {_toUnderlying}/{_fromUnderlying}; the accounting
 *       below is denominated in the module's underlying units. See #189 gap "BREAD wrap".
 */
contract YieldSavingCircles is SavingCircles {
  /// @notice When a member may claim their accrued yield.
  enum ClaimTiming {
    Anytime,
    EndOnly
  }

  uint256 private constant _ACC_PRECISION = 1e18;

  /// @notice The crowdstake.fun yield module (stake pool) principal is staked into.
  IYieldModule public yieldModule;

  /// @notice Per-circle yield claim-timing policy. Defaults to Anytime (0).
  mapping(uint256 id => ClaimTiming timing) public claimTiming;

  // --- MasterChef-style global yield accounting (single shared pool) ---
  uint256 private _accYieldPerPrincipal; // scaled by _ACC_PRECISION
  uint256 private _totalPrincipal; // total principal currently staked across all circles
  uint256 private _lastYieldSeen; // module yieldAccrued() already booked into the accumulator
  mapping(address member => uint256 principal) private _principalOf;
  mapping(address member => uint256 debt) private _rewardDebt;
  mapping(address member => uint256 amount) public claimableYield; // credited, awaiting claim

  /// @dev Per-call flag: whether the claimant keeps their pot staked. Reset after use.
  bool private _keepStakedFlag;

  event YieldModuleSet(address indexed yieldModule);
  event ClaimTimingSet(uint256 indexed id, ClaimTiming timing);
  event PotKeptStaked(uint256 indexed id, address indexed member, uint256 amount);
  event YieldClaimed(address indexed member, address indexed receiver, uint256 amount);

  error YieldModuleNotSet();
  error YieldLocked();
  error NothingToClaim();

  /// @notice Set the yield module. Owner only. Must be set before any deposits.
  function setYieldModule(address _yieldModule) external onlyOwner {
    if (_yieldModule == address(0)) revert YieldModuleNotSet();
    yieldModule = IYieldModule(_yieldModule);
    emit YieldModuleSet(_yieldModule);
  }

  /// @notice Set a circle's yield claim-timing. Owner of the circle, before it starts.
  function setClaimTiming(uint256 _id, ClaimTiming _timing) external {
    if (circles[_id].owner != msg.sender) revert NotOwner();
    if (isActive[_id]) revert AlreadyActive();
    claimTiming[_id] = _timing;
    emit ClaimTimingSet(_id, _timing);
  }

  /**
   * @notice Claim the round pot, choosing whether to keep it staked and compounding.
   * @param _id The circle id.
   * @param _keepStaked If true, the pot stays in the yield module earning for the caller
   *        (withdraw later via {withdrawStakedPrincipal}); if false it is redeemed to the wallet.
   */
  function claim(uint256 _id, bool _keepStaked) external nonReentrant onlyMember(_id, msg.sender) onlyActive(_id) {
    _keepStakedFlag = _keepStaked;
    _withdraw(_id, msg.sender);
    _keepStakedFlag = false;
  }

  /// @notice Claim accrued yield to `_receiver`, subject to the member's circles' claim-timing.
  function claimYield(address _receiver) external nonReentrant {
    if (address(yieldModule) == address(0)) revert YieldModuleNotSet();
    _harvestGlobal();
    _settle(msg.sender);
    if (!_yieldUnlocked(msg.sender)) revert YieldLocked();

    uint256 _amount = claimableYield[msg.sender];
    if (_amount == 0) revert NothingToClaim();
    claimableYield[msg.sender] = 0;

    // Pull yield (underlying) from the module, then hand it to the member.
    yieldModule.claimYield(_amount, address(this));
    _lastYieldSeen -= _amount; // module's yieldAccrued() dropped by _amount
    uint256 _out = _fromUnderlying(_amount);
    _payoutToken().safeTransfer(_receiver, _out);

    emit YieldClaimed(msg.sender, _receiver, _out);
  }

  /// @notice Withdraw principal a claimant previously left staked (keepStaked path).
  function withdrawStakedPrincipal(address _receiver) external nonReentrant {
    if (address(yieldModule) == address(0)) revert YieldModuleNotSet();
    _harvestGlobal();
    _settle(msg.sender);

    uint256 _principal = _principalOf[msg.sender];
    if (_principal == 0) revert NothingToClaim();
    _principalOf[msg.sender] = 0;
    _totalPrincipal -= _principal;
    _rewardDebt[msg.sender] = 0;

    yieldModule.burn(_principal, address(this));
    uint256 _out = _fromUnderlying(_principal);
    _payoutToken().safeTransfer(_receiver, _out);
  }

  // =========================================================================
  //                              Overrides
  // =========================================================================

  /// @dev Route the just-deposited principal into the yield module and book it for the member.
  function _deposit(uint256 _id, uint256 _value, address _member) internal override {
    if (address(yieldModule) == address(0)) revert YieldModuleNotSet();

    _harvestGlobal();
    _settle(_member);

    // Base pulls `_value` of the circle token into this contract and updates ROSCA bookkeeping.
    super._deposit(_id, _value, _member);

    uint256 _underlyingAmount = _toUnderlying(_value);
    _underlyingToken().forceApprove(address(yieldModule), _underlyingAmount);
    yieldModule.mint(_underlyingAmount, address(this));

    _principalOf[_member] += _underlyingAmount;
    _totalPrincipal += _underlyingAmount;
    _rewardDebt[_member] = (_principalOf[_member] * _accYieldPerPrincipal) / _ACC_PRECISION;
  }

  /**
   * @dev Claimant takes their round's pot. Each depositor's yield on that round is settled to
   *      them (kept per Model B); the pot principal either redeems to the claimant, or (Model A)
   *      is re-attributed to the claimant and kept staked to keep compounding.
   */
  function _withdraw(uint256 _id, address _member) internal override onlyMember(_id, _member) {
    if (!_claimable(_id, _member)) revert NotWithdrawable();

    _harvestGlobal();

    uint256 _round = _memberStates[_id][_member].memberIndex; // claimant's turn == their index
    address[] memory _members = circleMembers[_id];
    uint256 _pot;

    for (uint256 i = 0; i < _members.length; i++) {
      address _depositor = _members[i];
      uint256 _d = roundDeposits[_id][_round][_depositor];
      if (_d == 0) continue;

      uint256 _underlyingD = _toUnderlying(_d);

      // Credit this depositor the yield their principal earned, then remove this round's principal.
      _settle(_depositor);
      _principalOf[_depositor] -= _underlyingD;
      _totalPrincipal -= _underlyingD;
      _rewardDebt[_depositor] = (_principalOf[_depositor] * _accYieldPerPrincipal) / _ACC_PRECISION;

      roundDeposits[_id][_round][_depositor] = 0; // consumed into the pot
      _pot += _underlyingD;
    }

    _memberStates[_id][_member].hasClaimed = true;

    if (_keepStakedFlag) {
      // Pot never leaves the pool; re-attribute it to the claimant so it keeps earning for them.
      _settle(_member);
      _principalOf[_member] += _pot;
      _totalPrincipal += _pot;
      _rewardDebt[_member] = (_principalOf[_member] * _accYieldPerPrincipal) / _ACC_PRECISION;
      emit PotKeptStaked(_id, _member, _pot);
    } else {
      yieldModule.burn(_pot, address(this));
      uint256 _out = _fromUnderlying(_pot);
      _payoutToken().safeTransfer(_member, _out);
    }

    emit FundsWithdrawn(_id, _member, _pot);

    if (_allMembersClaimed(_id)) {
      isActive[_id] = false;
    }
  }

  // =========================================================================
  //                              Internals
  // =========================================================================

  /// @dev Book newly accrued module yield into the global per-principal accumulator.
  function _harvestGlobal() internal {
    if (_totalPrincipal == 0) return;
    uint256 _accruedNow = yieldModule.yieldAccrued();
    if (_accruedNow > _lastYieldSeen) {
      uint256 _delta = _accruedNow - _lastYieldSeen;
      _accYieldPerPrincipal += (_delta * _ACC_PRECISION) / _totalPrincipal;
      _lastYieldSeen = _accruedNow;
    }
  }

  /// @dev Move a member's pending accumulator yield into their claimable balance.
  function _settle(address _member) internal {
    uint256 _accumulated = (_principalOf[_member] * _accYieldPerPrincipal) / _ACC_PRECISION;
    uint256 _pending = _accumulated - _rewardDebt[_member];
    if (_pending > 0) claimableYield[_member] += _pending;
    _rewardDebt[_member] = _accumulated;
  }

  /// @dev A member's yield is locked while any of their circles is EndOnly and still active.
  function _yieldUnlocked(address _member) internal view returns (bool) {
    uint256[] memory _ids = memberCircles[_member];
    for (uint256 i = 0; i < _ids.length; i++) {
      if (isActive[_ids[i]] && claimTiming[_ids[i]] == ClaimTiming.EndOnly) return false;
    }
    return true;
  }

  // =========================================================================
  //      Wrap seams — override to keep BREAD user-facing (BREAD<->xDAI<->sDAI)
  // =========================================================================

  /// @dev Convert a circle-token amount into the yield module's underlying. Identity in v1.
  function _toUnderlying(uint256 _amount) internal virtual returns (uint256) {
    return _amount;
  }

  /// @dev Convert an underlying amount back into the circle/payout token. Identity in v1.
  function _fromUnderlying(uint256 _amount) internal virtual returns (uint256) {
    return _amount;
  }

  /// @dev The ERC20 the yield module pulls on mint / returns on burn. v1: the payout token.
  function _underlyingToken() internal view virtual returns (IERC20) {
    return _payoutToken();
  }

  /// @dev The ERC20 members are paid in (principal + yield). v1: single supported token.
  function _payoutToken() internal view virtual returns (IERC20) {
    return IERC20(_soleToken);
  }

  /// @dev v1 single-token constraint: set on first allowed token. See #189 (multi-token later).
  address private _soleToken;

  /// @notice Owner sets the single supported ERC20 for circles + payouts (v1 constraint).
  function setSoleToken(address _token) external onlyOwner {
    _soleToken = _token;
  }
}
