// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IChitSavingCircles} from 'interfaces/IChitSavingCircles.sol';

using SafeERC20 for IERC20;

/**
 * @title Chit Saving Circles — Variant D, "the foremanless chit"
 * @notice A permissionless, capital-efficient reverse-auction ROSCA with prize-time two-tier
 *         collateral. See {IChitSavingCircles} and docs/collateralized-permissionless-circles.md
 *         for the formal model.
 * @dev Safety rests on one invariant, established at each {award} and preserved by every rule:
 *      for every prized member `withheld(x) + coll(x) == residual(x)`, where `residual(x)` is the
 *      exact value of `x`'s remaining deposit obligations. Because a member's remaining
 *      obligation is always fully pre-funded by her own security, every pot is made whole against
 *      any set of prized defaulters and no honest member ever subsidizes one ("Theorem D3").
 *      Conservation holds by construction: covers and releases only move value between a member's
 *      security, a member's claimable balance, and the round pot — never in or out of the
 *      contract. Value enters only on {deposit}/{join}/{substitute} and leaves only on
 *      {claim}/{reclaimBond}/{abort}.
 * @author Breadchain Collective
 */
contract ChitSavingCircles is IChitSavingCircles, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  uint256 public constant MINIMUM_SLOTS = 2;

  uint256 internal _nextId;

  mapping(address token => bool allowed) internal _allowedTokens;
  mapping(uint256 id => Circle circle) internal _circles;
  mapping(uint256 id => address[] members) internal _members;
  // Append-only roster of every address ever substituted out of a slot, so {abort} can still
  // refund a defaulter's forfeited stake after {substitute} removed them from `_members`.
  mapping(uint256 id => address[] formerMembers) internal _formerMembers;
  mapping(uint256 id => mapping(address member => bool isMember)) internal _isMember;
  mapping(uint256 id => mapping(address member => uint256 slot)) internal _memberSlot;

  // Per-member security and status.
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _coll; // cash lock (prized)
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _withheld; // withheld bid (prized)
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _bond; // remaining membership bond
  mapping(uint256 id => mapping(address member => uint256 count)) internal _remaining; // owed future deposits
  mapping(uint256 id => mapping(address member => bool prized)) internal _prized;
  mapping(uint256 id => mapping(address member => uint256 round)) internal _prizeRound;
  mapping(uint256 id => mapping(address member => bool defaulted)) internal _defaulted;

  // Cash ledgers.
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _claimable; // withdrawable now
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _deposited; // cumulative deposits
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _bondPosted; // cumulative bonds
  mapping(uint256 id => mapping(address member => uint256 amount)) internal _withdrawn; // cumulative claimed out

  // Per-round bookkeeping.
  mapping(uint256 id => mapping(uint256 round => mapping(address member => uint256 amount))) internal _roundDeposit;
  mapping(uint256 id => mapping(uint256 round => uint256 amount)) internal _roundPot;
  mapping(uint256 id => mapping(uint256 round => mapping(address member => bytes32 h))) internal _commitment;
  mapping(uint256 id => mapping(uint256 round => mapping(address member => uint256 discount))) internal _bid;
  mapping(uint256 id => mapping(uint256 round => mapping(address member => bool revealed))) internal _revealed;

  mapping(uint256 id => uint256 count) internal _awardedCount;
  mapping(uint256 id => bool aborted) internal _aborted;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IChitSavingCircles
  function initialize(address owner) external override initializer {
    __Ownable_init(owner);
    __ReentrancyGuard_init();
  }

  /// @inheritdoc IChitSavingCircles
  function setTokenAllowed(address token, bool allowed) external override onlyOwner {
    _allowedTokens[token] = allowed;
    emit TokenAllowed(token, allowed);
  }

  // =======================
  // LIFECYCLE
  // =======================

  /// @inheritdoc IChitSavingCircles
  function createCircle(
    address token,
    uint256 depositAmount,
    uint256 numSlots,
    uint256 roundDuration,
    uint256 revealDuration
  ) external override returns (uint256 id) {
    if (!_allowedTokens[token]) revert TokenNotAllowed();
    if (depositAmount == 0 || numSlots < MINIMUM_SLOTS || roundDuration == 0) revert InvalidParameters();
    if (revealDuration == 0 || revealDuration >= roundDuration) revert InvalidParameters();

    id = _nextId++;
    _circles[id] = Circle({
      token: token,
      depositAmount: depositAmount,
      numSlots: numSlots,
      roundDuration: roundDuration,
      revealDuration: revealDuration,
      startTime: 0
    });

    emit CircleCreated(id, token, depositAmount, numSlots, roundDuration, revealDuration);
  }

  /// @inheritdoc IChitSavingCircles
  function join(uint256 id) external override nonReentrant {
    Circle storage circle = _existing(id);
    if (circle.startTime != 0) revert CircleNotOpen();
    if (_members[id].length >= circle.numSlots) revert CircleNotOpen();
    if (_isMember[id][msg.sender]) revert AlreadyMember();

    uint256 slot = _members[id].length;
    _members[id].push(msg.sender);
    _isMember[id][msg.sender] = true;
    _memberSlot[id][msg.sender] = slot;

    uint256 m = circle.depositAmount;
    _bond[id][msg.sender] = m;
    _bondPosted[id][msg.sender] += m;
    IERC20(circle.token).safeTransferFrom(msg.sender, address(this), m);

    emit MemberJoined(id, msg.sender, slot);
  }

  /// @inheritdoc IChitSavingCircles
  function start(uint256 id) external override {
    Circle storage circle = _existing(id);
    if (circle.startTime != 0) revert WrongState();
    if (_members[id].length != circle.numSlots) revert CircleNotFull();

    circle.startTime = block.timestamp;
    emit CircleStarted(id, block.timestamp);
  }

  // =======================
  // DEPOSITS
  // =======================

  /// @inheritdoc IChitSavingCircles
  function deposit(uint256 id, uint256 value) external override nonReentrant {
    _deposit(id, msg.sender, value);
  }

  /// @inheritdoc IChitSavingCircles
  function depositFor(uint256 id, address member, uint256 value) external override nonReentrant {
    _deposit(id, member, value);
  }

  function _deposit(uint256 id, address member, uint256 value) internal {
    Circle storage circle = _existing(id);
    if (circle.startTime == 0 || _aborted[id]) revert WrongState();
    if (!_isMember[id][member]) revert NotMember();
    if (value == 0) revert InvalidParameters();

    uint256 t = _round(circle);
    if (t >= circle.numSlots) revert WrongState(); // cycle over

    uint256 newTotal = _roundDeposit[id][t][member] + value;
    if (newTotal > circle.depositAmount) revert ExceedsDepositAmount();

    _roundDeposit[id][t][member] = newTotal;
    _roundPot[id][t] += value;
    _deposited[id][member] += value;

    IERC20(circle.token).safeTransferFrom(msg.sender, address(this), value);
    emit Deposited(id, member, t, value);
  }

  // =======================
  // SEALED-BID AUCTION
  // =======================

  /// @inheritdoc IChitSavingCircles
  function commitBid(uint256 id, bytes32 commitment) external override {
    Circle storage circle = _existing(id);
    uint256 t = _biddableRound(id, circle);
    if (_phase(circle) != Phase.Commit) revert WrongPhase();
    if (_commitment[id][t][msg.sender] != bytes32(0)) revert AlreadyCommitted();

    _commitment[id][t][msg.sender] = commitment;
    emit BidCommitted(id, msg.sender, t);
  }

  /// @inheritdoc IChitSavingCircles
  function revealBid(uint256 id, uint256 discount, bytes32 salt) external override {
    Circle storage circle = _existing(id);
    uint256 t = _biddableRound(id, circle);
    if (_phase(circle) != Phase.Reveal) revert WrongPhase();

    bytes32 h = _commitment[id][t][msg.sender];
    if (h == bytes32(0) || h != keccak256(abi.encode(discount, salt, msg.sender, id, t))) revert InvalidReveal();
    if (_roundDeposit[id][t][msg.sender] < circle.depositAmount) revert NotCurrent();
    if (discount > (circle.numSlots - 1 - t) * circle.depositAmount) revert BidTooHigh();

    _bid[id][t][msg.sender] = discount;
    _revealed[id][t][msg.sender] = true;
    emit BidRevealed(id, msg.sender, t, discount);
  }

  /// @dev Shared guards for {commitBid}/{revealBid}: an active, non-prized, non-defaulted member
  ///      bidding on the current, in-cycle round. Returns the current round index `t`.
  function _biddableRound(uint256 id, Circle storage circle) internal view returns (uint256 t) {
    if (circle.startTime == 0 || _aborted[id]) revert WrongState();
    if (!_isMember[id][msg.sender]) revert NotMember();
    if (_prized[id][msg.sender]) revert AlreadyPrized();
    if (_defaulted[id][msg.sender]) revert MemberIsDefaulted();
    t = _round(circle);
    if (t >= circle.numSlots) revert WrongState();
  }

  // =======================
  // AWARD / SETTLEMENT
  // =======================

  /// @inheritdoc IChitSavingCircles
  function award(uint256 id) external override nonReentrant {
    Circle storage circle = _existing(id);
    if (circle.startTime == 0 || _aborted[id]) revert WrongState();

    uint256 n = circle.numSlots;
    uint256 m = circle.depositAmount;
    uint256 f = _awardedCount[id];
    if (f >= n) revert WrongState(); // all rounds awarded
    if (_round(circle) <= f) revert RoundNotClosed(); // round f still open

    address[] memory members = _members[id];

    // (1) Complete the pot: cover every non-depositor's missed `m` from her own security.
    _coverNonDepositors(id, f, m, members);

    // (2) Choose the winner: highest revealed discount among eligible depositors, else rotation.
    (address winner, uint256 discount) = _selectWinner(id, f, m, members);

    // (3) Pay the winner and lock her exact residual as `withheld (= bid) + coll (= rest)`.
    uint256 residual = (n - 1 - f) * m;
    uint256 lock = residual - discount; // discount <= residual, enforced at reveal
    _prized[id][winner] = true;
    _prizeRound[id][winner] = f;
    _withheld[id][winner] = discount;
    _coll[id][winner] = lock;
    _remaining[id][winner] = n - 1 - f;
    _claimable[id][winner] += (f + 1) * m; // == n*m - discount - lock
    emit Awarded(id, winner, f, discount, (f + 1) * m, lock);

    // (4) Release one matured installment of every earlier winner who deposited this round.
    _releaseMatured(id, f, m, members);

    _roundPot[id][f] = 0;
    _awardedCount[id] = f + 1;
  }

  /// @dev Draw `m` into the pot for each member who did not deposit round `f`.
  function _coverNonDepositors(uint256 id, uint256 f, uint256 m, address[] memory members) internal {
    for (uint256 i = 0; i < members.length; i++) {
      address x = members[i];
      if (_roundDeposit[id][f][x] >= m) continue; // deposited in full
      if (_prized[id][x]) {
        // Prized: cover from withheld first, then cash lock. Solvent because withheld + coll ==
        // remaining*m >= m while an obligation is outstanding.
        uint256 fromWithheld = _withheld[id][x] >= m ? m : _withheld[id][x];
        _withheld[id][x] -= fromWithheld;
        _coll[id][x] -= (m - fromWithheld);
        _remaining[id][x] -= 1;
        emit Covered(id, x, f, m);
      } else {
        // Non-prized: cover from the one-round bond and flag defaulted. If the bond is already
        // spent the round cannot be completed; revert so the circle can be {abort}ed.
        if (_bond[id][x] < m) revert NotAwardable();
        _bond[id][x] -= m;
        _defaulted[id][x] = true;
        emit BondCovered(id, x, f, m);
        emit MemberDefaulted(id, x);
      }
    }
  }

  /// @dev Highest revealed discount among current, unprized, non-defaulted members wins; ties and
  ///      the no-bid case fall back to the lowest-slot eligible member at discount 0.
  function _selectWinner(
    uint256 id,
    uint256 f,
    uint256 m,
    address[] memory members
  ) internal view returns (address winner, uint256 discount) {
    bool found;
    for (uint256 i = 0; i < members.length; i++) {
      address x = members[i];
      if (_prized[id][x] || _defaulted[id][x] || _roundDeposit[id][f][x] < m) continue;
      if (_revealed[id][f][x] && (!found || _bid[id][f][x] > discount)) {
        found = true;
        winner = x;
        discount = _bid[id][f][x];
      }
    }
    if (found) return (winner, discount);

    // No valid bids: rotate to the lowest-slot eligible depositor.
    for (uint256 i = 0; i < members.length; i++) {
      address x = members[i];
      if (_prized[id][x] || _defaulted[id][x] || _roundDeposit[id][f][x] < m) continue;
      return (x, 0);
    }
    revert NoEligibleWinner();
  }

  /// @dev For every member prized before round `f` who deposited round `f`, unlock one installment:
  ///      return `m - dividend` of her cash lock and pay `dividend` out to the others as interest.
  function _releaseMatured(uint256 id, uint256 f, uint256 m, address[] memory members) internal {
    for (uint256 i = 0; i < members.length; i++) {
      address x = members[i];
      if (!_prized[id][x] || _prizeRound[id][x] >= f) continue; // not an earlier winner
      if (_roundDeposit[id][f][x] < m) continue; // missed → already covered in step (1)

      uint256 rem = _remaining[id][x];
      uint256 dividend = _withheld[id][x] / rem; // floor; the final installment takes the remainder
      _withheld[id][x] -= dividend;
      uint256 collBack = m - dividend;
      _coll[id][x] -= collBack;
      _remaining[id][x] = rem - 1;
      _claimable[id][x] += collBack;

      _distributeDividend(id, x, dividend, members);
      emit SecurityReleased(id, x, f, collBack, dividend);
    }
  }

  /// @dev Split `amount` equally among all members except `payer`; any rounding dust stays with
  ///      the payer, so the distribution is exact.
  function _distributeDividend(uint256 id, address payer, uint256 amount, address[] memory members) internal {
    if (amount == 0) return;
    uint256 share = amount / (members.length - 1);
    uint256 distributed;
    for (uint256 i = 0; i < members.length; i++) {
      address x = members[i];
      if (x == payer) continue;
      _claimable[id][x] += share;
      distributed += share;
    }
    _claimable[id][payer] += (amount - distributed); // dust back to payer
  }

  // =======================
  // CLAIMS / EXITS
  // =======================

  /// @inheritdoc IChitSavingCircles
  function claim(uint256 id) external override nonReentrant {
    Circle storage circle = _existing(id);
    uint256 amount = _claimable[id][msg.sender];
    if (amount == 0) revert NothingToClaim();

    _claimable[id][msg.sender] = 0;
    _withdrawn[id][msg.sender] += amount;
    IERC20(circle.token).safeTransfer(msg.sender, amount);
    emit Claimed(id, msg.sender, amount);
  }

  /// @inheritdoc IChitSavingCircles
  function substitute(uint256 id, address oldMember) external override nonReentrant {
    Circle storage circle = _existing(id);
    if (circle.startTime == 0 || _aborted[id]) revert WrongState();
    if (_round(circle) >= circle.numSlots) revert WrongState();
    if (!_isMember[id][oldMember]) revert NotMember();
    if (_prized[id][oldMember] || !_defaulted[id][oldMember]) revert NotSubstitutable();
    if (_isMember[id][msg.sender]) revert AlreadyMember();

    uint256 slot = _memberSlot[id][oldMember];
    _isMember[id][oldMember] = false;
    _isMember[id][msg.sender] = true;
    _memberSlot[id][msg.sender] = slot;
    _members[id][slot] = msg.sender;
    // Preserve the forfeiting member on the historical roster so {abort} still drains their stake.
    _formerMembers[id].push(oldMember);

    uint256 m = circle.depositAmount;
    _bond[id][msg.sender] = m;
    _bondPosted[id][msg.sender] += m;
    _defaulted[id][msg.sender] = false;
    _prized[id][msg.sender] = false;

    IERC20(circle.token).safeTransferFrom(msg.sender, address(this), m);
    emit MemberSubstituted(id, oldMember, msg.sender, slot);
    emit MemberJoined(id, msg.sender, slot);
  }

  /// @inheritdoc IChitSavingCircles
  function reclaimBond(uint256 id) external override nonReentrant {
    Circle storage circle = _existing(id);
    if (_aborted[id]) revert WrongState();
    if (_awardedCount[id] != circle.numSlots) revert WrongState(); // must have ended
    if (!_isMember[id][msg.sender]) revert NotMember();

    uint256 amount = _bond[id][msg.sender];
    if (amount == 0) revert NothingToClaim();

    _bond[id][msg.sender] = 0;
    IERC20(circle.token).safeTransfer(msg.sender, amount);
    emit BondReclaimed(id, msg.sender, amount);
  }

  /// @inheritdoc IChitSavingCircles
  function abort(uint256 id) external override nonReentrant {
    Circle storage circle = _existing(id);
    if (circle.startTime == 0 || _aborted[id]) revert WrongState();
    uint256 n = circle.numSlots;
    uint256 f = _awardedCount[id];
    // Stalled == the next round has closed but cannot be made whole (a defaulted slot, no substitute).
    if (f >= n || _round(circle) <= f || _awardableCore(id, f, circle.depositAmount)) revert NotStuck();

    _aborted[id] = true;

    // Net-zero unwind: refund every current AND substituted-out member their
    // `deposits + bonds posted - amounts already withdrawn`. This exactly drains the circle's
    // funds; unrealized prizes are clawed back. See {abort} docs. Refunding is idempotent (it
    // zeroes the member's ledger), so an address appearing on both rosters is paid at most once.
    address token = circle.token;
    address[] memory members = _members[id];
    for (uint256 i = 0; i < members.length; i++) {
      _refund(id, members[i], token);
    }
    address[] memory former = _formerMembers[id];
    for (uint256 i = 0; i < former.length; i++) {
      _refund(id, former[i], token);
    }

    emit CircleAborted(id);
  }

  /// @dev Pay `x` their net principal and zero every balance the contract holds for them, so a
  ///      second call (e.g. an address on both the active and former rosters) refunds nothing.
  function _refund(uint256 id, address x, address token) internal {
    uint256 credit = _deposited[id][x] + _bondPosted[id][x];
    uint256 debit = _withdrawn[id][x];
    uint256 refund = credit > debit ? credit - debit : 0;

    _claimable[id][x] = 0;
    _coll[id][x] = 0;
    _withheld[id][x] = 0;
    _bond[id][x] = 0;
    _deposited[id][x] = 0;
    _bondPosted[id][x] = 0;

    if (refund == 0) return;
    _withdrawn[id][x] += refund;
    IERC20(token).safeTransfer(x, refund);
    emit Refunded(id, x, refund);
  }

  // =======================
  // VIEWS
  // =======================

  /// @inheritdoc IChitSavingCircles
  function isTokenAllowed(address token) external view override returns (bool) {
    return _allowedTokens[token];
  }

  /// @inheritdoc IChitSavingCircles
  function nextId() external view override returns (uint256) {
    return _nextId;
  }

  /// @inheritdoc IChitSavingCircles
  function getCircle(uint256 id) external view override returns (Circle memory) {
    return _existingView(id);
  }

  /// @inheritdoc IChitSavingCircles
  function getMembers(uint256 id) external view override returns (address[] memory) {
    _existingView(id);
    return _members[id];
  }

  /// @inheritdoc IChitSavingCircles
  function circleState(uint256 id) external view override returns (CircleState) {
    Circle memory circle = _existingView(id);
    if (_aborted[id]) return CircleState.Aborted;
    if (circle.startTime == 0) return CircleState.Open;
    if (_awardedCount[id] >= circle.numSlots) return CircleState.Ended;
    return CircleState.Active;
  }

  /// @inheritdoc IChitSavingCircles
  function currentRound(uint256 id) external view override returns (uint256) {
    return _round(_existingView(id));
  }

  /// @inheritdoc IChitSavingCircles
  function currentPhase(uint256 id) external view override returns (Phase) {
    return _phase(_existingView(id));
  }

  /// @inheritdoc IChitSavingCircles
  function awardedCount(uint256 id) external view override returns (uint256) {
    _existingView(id);
    return _awardedCount[id];
  }

  /// @inheritdoc IChitSavingCircles
  function bidCap(uint256 id, uint256 round) external view override returns (uint256) {
    Circle memory circle = _existingView(id);
    if (round >= circle.numSlots) return 0;
    return (circle.numSlots - 1 - round) * circle.depositAmount;
  }

  /// @inheritdoc IChitSavingCircles
  function collateralOf(uint256 id, address member) external view override returns (uint256) {
    return _coll[id][member];
  }

  /// @inheritdoc IChitSavingCircles
  function withheldOf(uint256 id, address member) external view override returns (uint256) {
    return _withheld[id][member];
  }

  /// @inheritdoc IChitSavingCircles
  function bondOf(uint256 id, address member) external view override returns (uint256) {
    return _bond[id][member];
  }

  /// @inheritdoc IChitSavingCircles
  function claimableOf(uint256 id, address member) external view override returns (uint256) {
    return _claimable[id][member];
  }

  /// @inheritdoc IChitSavingCircles
  function residualOf(uint256 id, address member) external view override returns (uint256) {
    return _remaining[id][member] * _circles[id].depositAmount;
  }

  /// @inheritdoc IChitSavingCircles
  function isPrized(uint256 id, address member) external view override returns (bool) {
    return _prized[id][member];
  }

  /// @inheritdoc IChitSavingCircles
  function isDefaulted(uint256 id, address member) external view override returns (bool) {
    return _defaulted[id][member];
  }

  /// @inheritdoc IChitSavingCircles
  function isAwardable(uint256 id) external view override returns (bool) {
    Circle memory circle = _existingView(id);
    uint256 f = _awardedCount[id];
    if (_aborted[id] || f >= circle.numSlots || _round(circle) <= f) return false;
    return _awardableCore(id, f, circle.depositAmount);
  }

  // =======================
  // INTERNAL
  // =======================

  /// @dev Whether round `f` (assumed closed) can be settled: every non-depositor is coverable and
  ///      at least one eligible member remains to receive the pot.
  function _awardableCore(uint256 id, uint256 f, uint256 m) internal view returns (bool) {
    address[] memory members = _members[id];
    bool hasWinner;
    for (uint256 i = 0; i < members.length; i++) {
      address x = members[i];
      bool current = _roundDeposit[id][f][x] >= m;
      if (!current && !_prized[id][x] && _bond[id][x] < m) return false; // uncoverable non-prized miss
      if (current && !_prized[id][x] && !_defaulted[id][x]) hasWinner = true;
    }
    return hasWinner;
  }

  function _round(Circle memory circle) internal view returns (uint256) {
    if (circle.startTime == 0 || block.timestamp < circle.startTime) return 0;
    return (block.timestamp - circle.startTime) / circle.roundDuration;
  }

  function _phase(Circle memory circle) internal view returns (Phase) {
    if (circle.startTime == 0 || block.timestamp < circle.startTime) return Phase.Commit;
    uint256 into = (block.timestamp - circle.startTime) % circle.roundDuration;
    return into < circle.roundDuration - circle.revealDuration ? Phase.Commit : Phase.Reveal;
  }

  function _existing(uint256 id) internal view returns (Circle storage circle) {
    circle = _circles[id];
    if (circle.token == address(0)) revert CircleNotFound();
  }

  function _existingView(uint256 id) internal view returns (Circle memory circle) {
    circle = _circles[id];
    if (circle.token == address(0)) revert CircleNotFound();
  }
}
