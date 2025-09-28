# Fuzz Tests Documentation

## SavingCirclesFuzz.t.sol

This file contains property-based fuzz tests that verify the contract's behavior with randomized inputs.

```
SavingCirclesFuzz Tests
│
├── Circle Creation Fuzz Tests
│   ├── testFuzz_CreateCircleWithVariousParameters()
│   │   └── Tests circle creation with random valid parameters:
│   │       ├── Random member counts (1-10)
│   │       ├── Random deposit amounts (100 wei - 1000 ether)
│   │       ├── Random intervals (1 hour - 30 days)
│   │       └── Random max deposits (1-100)
│   │
│   └── testFuzz_InvalidCircleCreation_ZeroValues()
│       └── Verifies validation order for invalid parameters:
│           ├── Zero deposit interval → InvalidDepositInterval
│           ├── Zero deposit amount → InvalidDepositAmount
│           └── Zero max deposits → InvalidMaxDeposits
│
├── Deposit Operation Fuzz Tests
│   ├── testFuzz_DepositWithVariousAmounts()
│   │   └── Tests deposits with random amounts:
│   │       ├── Exact deposit amount succeeds
│   │       ├── Less than required fails
│   │       └── More than required fails
│   │
│   ├── testFuzz_DepositTiming()
│   │   └── Verifies deposit timing constraints:
│   │       ├── Before circle start → DepositBeforeCircleStart
│   │       ├── After window closes → DepositWindowClosed
│   │       └── During window → Success
│   │
│   ├── testFuzz_DepositForDifferentMembers()
│   │   └── Tests depositFor functionality:
│   │       ├── Random depositor/target combinations
│   │       ├── Verifies correct balance attribution
│   │       └── Handles self-deposits correctly
│   │
│   └── testFuzz_RaceConditionDeposits()
│       └── Simulates concurrent deposit attempts:
│           ├── Multiple members depositing simultaneously
│           └── Verifies no race conditions exist
│
├── Withdrawal Fuzz Tests
│   ├── testFuzz_WithdrawWithVariousTimings()
│   │   └── Tests withdrawal timing requirements:
│   │       ├── Before interval ends → NotWithdrawable
│   │       ├── After interval → Success
│   │       └── Correct recipient validation
│   │
│   └── testFuzz_WithdrawableBy()
│       └── Verifies withdrawableBy view function:
│           ├── Returns correct member based on currentIndex
│           └── Updates after each withdrawal
│
├── Decommission Fuzz Tests
│   └── testFuzz_DecommissionWithPartialDeposits()
│       └── Tests decommission conditions:
│           ├── All deposits complete → NotDecommissionable
│           ├── Partial deposits → Success
│           └── Fund refunds verified
│
├── Access Control Fuzz Tests
│   └── testFuzz_NonMemberCannotInteract()
│       └── Verifies non-members cannot:
│           ├── Deposit funds
│           ├── Withdraw funds
│           └── Access member-only functions
│
└── Complex Scenario Fuzz Tests
    └── testFuzz_CompleteCircleWithMultipleRounds()
        └── Tests full circle lifecycle with random:
            ├── Member counts
            ├── Deposit amounts
            ├── Number of rounds
            └── Timing variations
```

## SavingCirclesMultiRound.t.sol

This file contains fuzz tests specifically for multi-round saving circle scenarios.

```
SavingCirclesMultiRound Fuzz Tests
│
├── Basic Multi-Round Tests
│   ├── testFuzz_CompleteCircleWithNRounds()
│   │   └── Tests N complete rounds:
│   │       ├── Random number of rounds (1-maxDeposits)
│   │       ├── All members deposit each round
│   │       ├── Withdrawals follow correct order
│   │       └── currentIndex wraps correctly
│   │
│   └── testFuzz_MultipleConcurrentCircles()
│       └── Tests multiple circles running simultaneously:
│           ├── Different start times
│           ├── Different deposit amounts
│           ├── Overlapping members
│           └── Independent state tracking
│
├── Partial Round Scenarios
│   ├── testFuzz_PartialRoundsWithDecommission()
│   │   └── Tests incomplete rounds:
│   │       ├── Random members miss deposits
│   │       ├── Decommission after window closes
│   │       ├── Funds returned correctly
│   │       └── Circle deleted properly
│   │
│   └── testFuzz_IncompleteRoundsRecovery()
│       └── Tests recovery from missed deposits:
│           ├── Some members miss initial deposits
│           ├── Cannot deposit after window closes
│           ├── Decommission available for cleanup
│           └── Partial refunds processed
│
├── Interleaved Operations
│   ├── testFuzz_InterleavedDepositsAndWithdrawals()
│   │   └── Tests mixed operations:
│   │       ├── Deposits and withdrawals interleaved
│   │       ├── Correct state transitions
│   │       ├── Balance tracking accuracy
│   │       └── No double withdrawals
│   │
│   └── testFuzz_WithdrawalOrderConsistency()
│       └── Verifies withdrawal ordering:
│           ├── currentIndex increments properly
│           ├── Correct member withdraws each round
│           ├── Order maintained across rounds
│           └── withdrawableBy accuracy
│
├── Boundary Condition Tests
│   ├── testFuzz_MaxDepositBoundaryWithMultipleRounds()
│   │   └── Tests maxDeposits boundary:
│   │       ├── Deposits after maxDeposits reached
│   │       ├── CircleExpired vs DepositWindowClosed
│   │       ├── Final round completion
│   │       └── Circle expiration handling
│   │
│   └── testFuzz_SequentialCirclesWithSameMembers()
│       └── Tests sequential circles:
│           ├── Same members, new circles
│           ├── Independent state per circle
│           ├── No state pollution
│           └── Proper cleanup between circles
│
└── Edge Cases
    └── testFuzz_EmergencyDecommissionScenarios()
        └── Tests emergency decommission:
            ├── Owner-initiated decommission
            ├── Member-initiated decommission  
            ├── Time-based requirements
            └── Incomplete deposit requirements
```

## Key Fuzz Testing Properties

### 1. **Invariants Tested**
- Total deposits never exceed member count × deposit amount
- currentIndex never exceeds member count
- Only one withdrawal per index position
- Balances always non-negative

### 2. **Randomization Coverage**
- Member counts: 1-20 members
- Deposit amounts: 100 wei to 1000 ether
- Time intervals: 1 hour to 30 days
- Number of rounds: 1 to maxDeposits
- Random member selection for operations

### 3. **Edge Cases Covered**
- Zero values in various parameters
- Maximum boundaries (uint256 max values)
- Minimum boundaries (1 wei, 1 second)
- Empty arrays and single-element arrays
- Concurrent operations

### 4. **State Transitions Verified**
- All valid state paths tested
- Invalid transitions properly rejected
- State consistency across operations
- No stuck states possible