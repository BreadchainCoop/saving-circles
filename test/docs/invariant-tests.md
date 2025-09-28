# Invariant Tests Documentation

## SavingCirclesInvariants.t.sol

This file contains stateful invariant tests that verify system-wide properties hold true regardless of the sequence of operations.

```
SavingCirclesInvariants Tests
│
├── Core System Invariants
│   ├── invariant_TotalBalancesEqualDeposits()
│   │   └── Ensures total balances always equal total deposits:
│   │       ├── Sum of all member balances = total deposited
│   │       ├── No tokens created or destroyed
│   │       ├── Withdrawals reduce both equally
│   │       └── Decommissions maintain equality
│   │
│   ├── invariant_CurrentIndexNeverExceedsMaxDeposits()
│   │   └── Verifies currentIndex boundaries:
│   │       ├── currentIndex ≤ maxDeposits
│   │       ├── Increments correctly on withdrawal
│   │       ├── Wraps at maxDeposits (if multi-round)
│   │       └── Never goes negative
│   │
│   ├── invariant_OnlyMembersHaveBalances()
│   │   └── Ensures balance isolation:
│   │       ├── Non-members have zero balance
│   │       ├── Only members can deposit
│   │       ├── Balances cleared on withdrawal
│   │       └── No unauthorized balance changes
│   │
│   └── invariant_TotalDepositsNeverExceedMaximum()
│       └── Verifies deposit limits:
│           ├── Total ≤ members × depositAmount × maxDeposits
│           ├── Per-member limit enforced
│           ├── No overflow possible
│           └── Decommission respects limits
│
├── Withdrawal Invariants
│   ├── invariant_WithdrawalsFollowCurrentIndex()
│   │   └── Ensures withdrawal ordering:
│   │       ├── Only currentIndex member can withdraw
│   │       ├── Index increments after withdrawal
│   │       ├── Previous indices cannot re-withdraw
│   │       └── Order maintained across operations
│   │
│   ├── invariant_NoDoubleWithdrawals()
│   │   └── Prevents multiple withdrawals:
│   │       ├── One withdrawal per index position
│   │       ├── Withdrawal clears eligibility
│   │       ├── Cannot withdraw twice in window
│   │       └── State properly updated
│   │
│   └── invariant_OnlyOneWithdrawalPerRound()
│       └── Enforces single withdrawal per round:
│           ├── Each round has exactly one withdrawal
│           ├── Withdrawal advances to next round
│           ├── Cannot skip rounds
│           └── Round progression is linear
│
├── State Consistency Invariants
│   ├── invariant_CircleStartTimeNeverChanges()
│   │   └── Verifies immutable start time:
│   │       ├── Start time set at creation
│   │       ├── Never modified after creation
│   │       ├── All operations respect original time
│   │       └── Time calculations consistent
│   │
│   ├── invariant_MemberCountRemainConstant()
│   │   └── Ensures member list stability:
│   │       ├── Member count fixed at creation
│   │       ├── No members added/removed
│   │       ├── Member addresses unchanged
│   │       └── Order preserved
│   │
│   └── invariant_TokenAddressNeverChanges()
│       └── Verifies token immutability:
│           ├── Token set at creation
│           ├── Cannot change token
│           ├── All operations use same token
│           └── Token consistency maintained
│
├── Economic Invariants
│   ├── invariant_NoTokensLostOrCreated()
│   │   └── Conservation of tokens:
│   │       ├── Contract balance + withdrawn = deposited
│   │       ├── No tokens stuck in contract
│   │       ├── Decommission returns all funds
│   │       └── No minting or burning
│   │
│   └── invariant_BalancesNonNegative()
│       └── Prevents negative balances:
│           ├── All balances ≥ 0
│           ├── Withdrawals cannot exceed balance
│           ├── No underflow in calculations
│           └── Safe math throughout
│
└── Access Control Invariants
    ├── invariant_OnlyOwnerCanSetAllowedTokens()
    │   └── Owner privilege enforcement:
    │       ├── Only owner modifies allowlist
    │       ├── Non-owners always rejected
    │       ├── Owner status preserved
    │       └── No privilege escalation
    │
    └── invariant_DecommissionRequiresIncompleteDeposits()
        └── Decommission conditions:
            ├── Only when deposits incomplete
            ├── After deposit window closes
            ├── Cannot decommission completed circles
            └── Proper authorization required
```

## SavingCirclesHandler.sol

Handler contract that generates valid random operations for invariant testing:

```
SavingCirclesHandler Operations
│
├── Circle Management
│   ├── createCircle()
│   │   └── Creates circles with valid random parameters:
│   │       ├── Random member selection from actors
│   │       ├── Valid deposit amounts
│   │       ├── Reasonable time intervals
│   │       └── Tracks created circle IDs
│   │
│   └── Ghost Variables
│       ├── circleIds[] - tracks all created circles
│       ├── circleCreators - maps circles to creators
│       └── activeCircles - count of non-decommissioned circles
│
├── Deposit Operations
│   ├── deposit()
│   │   └── Attempts deposits with random parameters:
│   │       ├── Random actor selection
│   │       ├── Random circle selection
│   │       ├── Proper token approval
│   │       ├── Tracks successful deposits
│   │       └── Updates ghost variables
│   │
│   ├── depositFor()
│   │   └── Deposits on behalf of others:
│   │       ├── Random depositor/target pairs
│   │       ├── Valid member targeting
│   │       └── Balance tracking
│   │
│   └── Ghost Variables
│       ├── totalDeposits - sum of all deposits
│       ├── memberDeposits - per-member tracking
│       └── circleDeposits - per-circle totals
│
├── Withdrawal Operations
│   ├── withdraw()
│   │   └── Attempts withdrawals:
│   │       ├── Random eligible member selection
│   │       ├── Time advancement when needed
│   │       ├── Tracks withdrawal amounts
│   │       └── Updates currentIndex
│   │
│   └── Ghost Variables
│       ├── totalWithdrawn - sum of all withdrawals
│       ├── withdrawalCounts - per-circle withdrawal count
│       └── lastWithdrawer - tracks recent withdrawals
│
├── Decommission Operations
│   ├── decommission()
│   │   └── Attempts circle decommission:
│   │       ├── Random circle selection
│   │       ├── Checks prerequisites
│   │       ├── Tracks refunds
│   │       └── Updates circle status
│   │
│   └── Ghost Variables
│       ├── decommissionedCircles - count of decommissioned
│       ├── refundedAmounts - tracks refunds
│       └── decommissionTimestamps - when decommissioned
│
└── Helper Functions
    ├── _getRandomActor()
    │   └── Selects valid actor address
    │
    ├── _getRandomCircle()
    │   └── Selects from created circles
    │
    ├── _advanceTime()
    │   └── Moves time forward randomly
    │
    └── _validateInvariant()
        └── Checks invariant conditions
```

## Key Invariant Testing Concepts

### 1. **Ghost Variables**
Track aggregate state outside the main contract:
- Total deposits across all circles
- Withdrawal counts and amounts
- Circle creation timestamps
- Member participation tracking

### 2. **Actor Management**
- Fixed set of test actors
- Random actor selection for operations
- Realistic user behavior simulation
- Multiple actors per test run

### 3. **Operation Sequences**
Handler generates realistic sequences:
- Create → Deposit → Withdraw → Decommission
- Multiple circles running concurrently
- Random time advancement
- Interleaved operations

### 4. **Invariant Properties**
Properties that must always hold:
- **Safety**: No token loss or creation
- **Liveness**: Progress always possible
- **Fairness**: Correct withdrawal ordering
- **Consistency**: State always valid

### 5. **Failure Handling**
Handler gracefully handles expected failures:
- Deposits outside windows
- Unauthorized operations
- Invalid state transitions
- Maintains test continuity