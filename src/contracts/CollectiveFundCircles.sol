// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {EIP712Upgradeable} from '@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {ICollectiveFundCircles} from 'interfaces/ICollectiveFundCircles.sol';

using SafeERC20 for IERC20;

/**
 * @title Collective Fund Circles
 * @notice A communal savings pot for local communities: members deposit flexible amounts anytime,
 *         may rage-quit anytime for a pro-rata slice of what remains, and spend the pool together
 *         via one-member-one-vote disbursement proposals with a snapshotted electorate.
 * @dev Singleton registry keyed by uint256 id; each fund carries its own on-chain display name
 *      (white-label). Membership is by fund-owner-signed EIP-712 invite (domain 'StacksInvite',
 *      identical to SavingCircles). Shares are a ledger of tokens contributed (minted 1:1, not
 *      vault shares); an executed proposal dilutes every shareholder pro-rata. Rage-quit is never
 *      blocked: a passed proposal does not reserve funds, and execute simply reverts if the pool
 *      no longer covers the amount. See docs/collective-fund-circles.md for the design rationale.
 * @author Breadchain Collective
 */
contract CollectiveFundCircles is
  ICollectiveFundCircles,
  ReentrancyGuardUpgradeable,
  OwnableUpgradeable,
  EIP712Upgradeable
{
  /// @notice Basis-point denominator
  uint256 public constant MAX_BPS = 10_000;
  /// @notice Upper bound on a fund's voting period; bounds deadline math so no overflow is possible
  uint256 public constant MAX_VOTING_PERIOD = 365 days;

  string private constant _EIP712_NAME = 'StacksInvite';
  string private constant _EIP712_VERSION = '1';
  bytes32 private constant _INVITE_TYPEHASH = keccak256('Invite(uint256 id,uint256 nonce)');

  /// @inheritdoc ICollectiveFundCircles
  uint256 public override nextId;

  /// @notice Admin (contract owner) ERC20 allowlist, exactly like SavingCircles
  mapping(address token => bool status) public allowedTokens;

  /// @notice Fund config + accounting; `owner != address(0)` is the existence sentinel
  mapping(uint256 id => Fund fund) internal _funds;

  /// @inheritdoc ICollectiveFundCircles
  mapping(uint256 id => mapping(address member => bool status)) public override isMember;

  /// @notice APPEND-ONLY ordered member list. Never shuffled/shrunk — proposal electorate
  ///         snapshots rely on `memberIndex < proposal.electorate`
  mapping(uint256 id => address[] members) public fundMembers;

  /// @inheritdoc ICollectiveFundCircles
  mapping(uint256 id => mapping(address member => uint256 index)) public override memberIndex;

  /// @inheritdoc ICollectiveFundCircles
  mapping(uint256 id => mapping(address member => uint256 shares)) public override sharesOf;

  /// @notice Reverse index: all fund ids an address is a member of (frontend enumeration)
  mapping(address member => uint256[] ids) public memberFunds;

  /// @inheritdoc ICollectiveFundCircles
  mapping(uint256 id => mapping(uint256 nonce => bool used)) public override usedNonces;

  /// @notice Proposals per fund, keyed by per-fund proposalId (0.._funds[id].proposalCount-1)
  mapping(uint256 id => mapping(uint256 proposalId => Proposal proposal)) internal _proposals;

  /// @inheritdoc ICollectiveFundCircles
  mapping(uint256 id => mapping(uint256 proposalId => mapping(address voter => bool voted))) public override hasVoted;

  /// @dev Requires the fund exists
  modifier onlyExisting(uint256 _id) {
    if (_funds[_id].owner == address(0)) revert FundNotFound();
    _;
  }

  /// @dev Requires the address is a member of the fund
  modifier onlyMember(uint256 _id, address _member) {
    if (!isMember[_id][_member]) revert NotMember();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc ICollectiveFundCircles
  function initialize(address _owner) external override initializer {
    __EIP712_init(_EIP712_NAME, _EIP712_VERSION);
    __Ownable_init(_owner);
    __ReentrancyGuard_init();
  }

  /// @inheritdoc ICollectiveFundCircles
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    allowedTokens[_token] = _allowed;

    emit TokenAllowed(_token, _allowed);
  }

  /// @inheritdoc ICollectiveFundCircles
  function create(
    address _token,
    address _fundOwner,
    string calldata _name,
    uint256 _votingPeriod,
    uint256 _approvalThresholdBps
  ) external override returns (uint256 _id) {
    if (!allowedTokens[_token]) revert TokenNotAllowed();
    if (_fundOwner == address(0)) revert InvalidFundOwner();
    if (bytes(_name).length == 0) revert InvalidName();
    if (_votingPeriod == 0 || _votingPeriod > MAX_VOTING_PERIOD) revert InvalidVotingPeriod();
    if (_approvalThresholdBps == 0 || _approvalThresholdBps > MAX_BPS) revert InvalidThreshold();

    _id = nextId++;

    Fund storage _fund = _funds[_id];
    _fund.owner = _fundOwner;
    _fund.token = _token;
    _fund.votingPeriod = _votingPeriod;
    _fund.approvalThresholdBps = _approvalThresholdBps;
    _fund.name = _name;

    isMember[_id][_fundOwner] = true;
    fundMembers[_id].push(_fundOwner);
    memberIndex[_id][_fundOwner] = 0;
    memberFunds[_fundOwner].push(_id);

    emit FundCreated(_id, _fundOwner, _token, _name, _votingPeriod, _approvalThresholdBps);
  }

  /// @inheritdoc ICollectiveFundCircles
  function redeemInvite(
    uint256 _id,
    uint256 _nonce,
    bytes calldata _signature
  ) external override nonReentrant onlyExisting(_id) {
    if (usedNonces[_id][_nonce]) revert InviteAlreadyUsed();
    if (isMember[_id][msg.sender]) revert AlreadyMember();

    bytes32 _digest = _hashInvite(_id, _nonce);
    address _signer = ECDSA.recover(_digest, _signature);

    if (_signer != _funds[_id].owner) revert InvalidSigner();

    usedNonces[_id][_nonce] = true;

    isMember[_id][msg.sender] = true;
    address[] storage _members = fundMembers[_id];
    _members.push(msg.sender);
    memberIndex[_id][msg.sender] = _members.length - 1;
    memberFunds[msg.sender].push(_id);

    emit InviteRedeemed(_id, msg.sender);
  }

  /// @inheritdoc ICollectiveFundCircles
  function deposit(
    uint256 _id,
    uint256 _amount
  ) external override nonReentrant onlyExisting(_id) onlyMember(_id, msg.sender) {
    if (_amount == 0) revert InvalidAmount();

    Fund storage _fund = _funds[_id];
    sharesOf[_id][msg.sender] += _amount;
    _fund.totalShares += _amount;
    _fund.poolBalance += _amount;

    IERC20(_fund.token).safeTransferFrom(msg.sender, address(this), _amount);

    emit FundsDeposited(_id, msg.sender, _amount);
  }

  /// @inheritdoc ICollectiveFundCircles
  function donate(uint256 _id, uint256 _amount) external override nonReentrant onlyExisting(_id) {
    if (_amount == 0) revert InvalidAmount();

    Fund storage _fund = _funds[_id];
    _fund.poolBalance += _amount;

    IERC20(_fund.token).safeTransferFrom(msg.sender, address(this), _amount);

    emit FundsDonated(_id, msg.sender, _amount);
  }

  /// @inheritdoc ICollectiveFundCircles
  function withdraw(
    uint256 _id,
    uint256 _shares
  ) external override nonReentrant onlyExisting(_id) onlyMember(_id, msg.sender) {
    if (_shares == 0) revert InvalidAmount();

    uint256 _memberShares = sharesOf[_id][msg.sender];
    if (_shares > _memberShares) revert InsufficientShares();

    Fund storage _fund = _funds[_id];
    // Pro-rata at time of withdrawal; floor division rounds in favor of the pool. Since
    // _shares <= totalShares, _amountOut <= poolBalance and the debit below cannot underflow.
    uint256 _amountOut = (_shares * _fund.poolBalance) / _fund.totalShares;

    sharesOf[_id][msg.sender] = _memberShares - _shares;
    _fund.totalShares -= _shares;
    _fund.poolBalance -= _amountOut;

    IERC20(_fund.token).safeTransfer(msg.sender, _amountOut);

    emit FundsWithdrawn(_id, msg.sender, _shares, _amountOut);
  }

  /// @inheritdoc ICollectiveFundCircles
  function propose(
    uint256 _id,
    address _recipient,
    uint256 _amount,
    string calldata _description
  ) external override onlyExisting(_id) onlyMember(_id, msg.sender) returns (uint256 _proposalId) {
    if (_recipient == address(0) || _recipient == address(this)) revert InvalidRecipient();
    if (_amount == 0) revert InvalidAmount();

    Fund storage _fund = _funds[_id];
    _proposalId = _fund.proposalCount++;

    uint256 _electorate = fundMembers[_id].length;
    // Ceiling division: "at least thresholdBps of the electorate" must not be satisfiable by
    // fewer heads via flooring. Always >= 1 since electorate >= 1 and thresholdBps >= 1.
    uint256 _requiredYes = (_electorate * _fund.approvalThresholdBps + MAX_BPS - 1) / MAX_BPS;

    Proposal storage _proposal = _proposals[_id][_proposalId];
    _proposal.proposer = msg.sender;
    _proposal.recipient = _recipient;
    _proposal.amount = _amount;
    _proposal.createdAt = block.timestamp;
    _proposal.electorate = _electorate;
    _proposal.requiredYes = _requiredYes;
    _proposal.yesVotes = 1; // proposer auto-votes yes
    _proposal.description = _description;

    hasVoted[_id][_proposalId][msg.sender] = true;

    emit ProposalCreated(_id, _proposalId, msg.sender, _recipient, _amount, _description);
  }

  /// @inheritdoc ICollectiveFundCircles
  function vote(
    uint256 _id,
    uint256 _proposalId,
    bool _support
  ) external override onlyExisting(_id) onlyMember(_id, msg.sender) {
    Fund storage _fund = _funds[_id];
    if (_proposalId >= _fund.proposalCount) revert ProposalNotFound();

    Proposal storage _proposal = _proposals[_id][_proposalId];
    // Append-only member list makes "index < snapshot length" exactly "was a member at snapshot".
    if (memberIndex[_id][msg.sender] >= _proposal.electorate) revert NotEligible();
    if (_proposal.executed || block.timestamp > _proposal.createdAt + _fund.votingPeriod) revert VotingClosed();
    if (hasVoted[_id][_proposalId][msg.sender]) revert AlreadyVoted();

    hasVoted[_id][_proposalId][msg.sender] = true;
    if (_support) {
      _proposal.yesVotes += 1;
    } else {
      _proposal.noVotes += 1;
    }

    emit VoteCast(_id, _proposalId, msg.sender, _support);
  }

  /// @inheritdoc ICollectiveFundCircles
  function execute(uint256 _id, uint256 _proposalId) external override nonReentrant onlyExisting(_id) {
    Fund storage _fund = _funds[_id];
    if (_proposalId >= _fund.proposalCount) revert ProposalNotFound();

    Proposal storage _proposal = _proposals[_id][_proposalId];
    if (_proposal.yesVotes < _proposal.requiredYes) revert ProposalNotPassed();
    if (_proposal.executed) revert ProposalAlreadyExecuted();
    if (block.timestamp > _proposal.createdAt + 2 * _fund.votingPeriod) revert ProposalExpired();
    if (_fund.poolBalance < _proposal.amount) revert InsufficientPoolBalance();

    _proposal.executed = true;
    _fund.poolBalance -= _proposal.amount;

    IERC20(_fund.token).safeTransfer(_proposal.recipient, _proposal.amount);

    emit ProposalExecuted(_id, _proposalId, _proposal.recipient, _proposal.amount);
  }

  /// @inheritdoc ICollectiveFundCircles
  function setFundName(uint256 _id, string calldata _name) external override onlyExisting(_id) {
    if (msg.sender != _funds[_id].owner) revert NotFundOwner();
    if (bytes(_name).length == 0) revert InvalidName();

    _funds[_id].name = _name;

    emit FundNameUpdated(_id, _name);
  }

  /// @inheritdoc ICollectiveFundCircles
  function getFund(uint256 _id) external view override onlyExisting(_id) returns (Fund memory _fund) {
    return _funds[_id];
  }

  /// @inheritdoc ICollectiveFundCircles
  function getFunds(uint256[] calldata _ids) external view override returns (Fund[] memory _result) {
    _result = new Fund[](_ids.length);

    for (uint256 _i = 0; _i < _ids.length; _i++) {
      _result[_i] = _funds[_ids[_i]];
    }
  }

  /// @inheritdoc ICollectiveFundCircles
  function getFundMembers(uint256 _id) external view override returns (address[] memory _members) {
    return fundMembers[_id];
  }

  /// @inheritdoc ICollectiveFundCircles
  function getMemberFunds(address _member) external view override returns (uint256[] memory _ids) {
    return memberFunds[_member];
  }

  /// @inheritdoc ICollectiveFundCircles
  function checkMemberships(
    address _member,
    uint256[] calldata _ids
  ) external view override returns (bool[] memory _memberships) {
    _memberships = new bool[](_ids.length);

    for (uint256 _i = 0; _i < _ids.length; _i++) {
      _memberships[_i] = isMember[_ids[_i]][_member];
    }
  }

  /// @inheritdoc ICollectiveFundCircles
  function getProposal(uint256 _id, uint256 _proposalId) external view override returns (Proposal memory _proposal) {
    if (_proposalId >= _funds[_id].proposalCount) revert ProposalNotFound();
    return _proposals[_id][_proposalId];
  }

  /// @inheritdoc ICollectiveFundCircles
  function getProposals(uint256 _id) external view override returns (Proposal[] memory _result) {
    uint256 _count = _funds[_id].proposalCount;
    _result = new Proposal[](_count);

    for (uint256 _i = 0; _i < _count; _i++) {
      _result[_i] = _proposals[_id][_i];
    }
  }

  /// @inheritdoc ICollectiveFundCircles
  function proposalState(uint256 _id, uint256 _proposalId) external view override returns (ProposalState _state) {
    Fund storage _fund = _funds[_id];
    if (_proposalId >= _fund.proposalCount) revert ProposalNotFound();

    return _proposalState(_proposals[_id][_proposalId], _fund.votingPeriod);
  }

  /// @inheritdoc ICollectiveFundCircles
  function isExecutable(uint256 _id, uint256 _proposalId) external view override returns (bool _executable) {
    Fund storage _fund = _funds[_id];
    if (_proposalId >= _fund.proposalCount) return false;

    Proposal storage _proposal = _proposals[_id][_proposalId];
    return
      _proposalState(_proposal, _fund.votingPeriod) == ProposalState.Passed && _fund.poolBalance >= _proposal.amount;
  }

  /// @inheritdoc ICollectiveFundCircles
  function previewWithdraw(uint256 _id, address _member) external view override returns (uint256 _amount) {
    Fund storage _fund = _funds[_id];
    if (_fund.totalShares == 0) return 0;

    return (sharesOf[_id][_member] * _fund.poolBalance) / _fund.totalShares;
  }

  /// @inheritdoc ICollectiveFundCircles
  function isTokenAllowed(address _token) external view override returns (bool _allowed) {
    return allowedTokens[_token];
  }

  /**
   * @dev Compute the lifecycle state of a proposal — a pure function of storage + time.
   *      Evaluation order (first match wins):
   *        1. executed -> Executed (terminal)
   *        2. threshold reached, now <= executionDeadline -> Passed
   *        3. threshold reached, now > executionDeadline -> Expired (terminal)
   *        4. now > voteDeadline -> Defeated (terminal)
   *        5. threshold mathematically unreachable -> Defeated
   *        6. otherwise -> Active
   *      where voteDeadline = createdAt + votingPeriod and executionDeadline = createdAt +
   *      2 * votingPeriod (self-scaling execution grace of one extra voting period).
   * @param _proposal The proposal
   * @param _votingPeriod The fund's voting period
   * @return _state The proposal state
   */
  function _proposalState(
    Proposal storage _proposal,
    uint256 _votingPeriod
  ) internal view returns (ProposalState _state) {
    if (_proposal.executed) return ProposalState.Executed;

    if (_proposal.yesVotes >= _proposal.requiredYes) {
      return block.timestamp <= _proposal.createdAt + 2 * _votingPeriod ? ProposalState.Passed : ProposalState.Expired;
    }
    if (block.timestamp > _proposal.createdAt + _votingPeriod) return ProposalState.Defeated;
    // Early mathematical defeat: even if every remaining eligible voter votes yes,
    // yesVotes + (electorate - yesVotes - noVotes) == electorate - noVotes < requiredYes.
    if (_proposal.electorate - _proposal.noVotes < _proposal.requiredYes) return ProposalState.Defeated;

    return ProposalState.Active;
  }

  /**
   * @dev Computes the EIP-712 hash for an invite
   * @notice _INVITE_TYPEHASH is keccak256('Invite(uint256 id,uint256 nonce)')
   */
  function _hashInvite(uint256 _id, uint256 _nonce) private view returns (bytes32) {
    bytes32 _structHash = keccak256(abi.encode(_INVITE_TYPEHASH, _id, _nonce));
    return _hashTypedDataV4(_structHash);
  }
}
