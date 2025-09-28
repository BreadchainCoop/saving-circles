# Integration Tests Documentation

## SavingCircles.t.sol

This file contains integration tests that verify the interaction between multiple components and contracts.

```
SavingCirclesIntegration Tests
│
├── Basic Integration Tests
│   ├── test_CreateAndDepositIntegration()
│   │   └── Tests complete flow from creation to deposits:
│   │       ├── Contract deployment
│   │       ├── Token allowlist setup
│   │       ├── Circle creation
│   │       ├── Multiple member deposits
│   │       └── Balance verification
│   │
│   ├── test_WithdrawAfterDepositsIntegration()
│   │   └── Verifies withdrawal after all deposits:
│   │       ├── Full deposit completion
│   │       ├── Time progression
│   │       ├── Withdrawal execution
│   │       ├── Token transfer verification
│   │       └── Balance updates
│   │
│   └── test_MultipleRoundsIntegration()
│       └── Tests multiple complete rounds:
│           ├── Round 1: deposits & withdrawal
│           ├── Round 2: deposits & withdrawal
│           ├── currentIndex progression
│           └── Correct recipient each round
│
├── Access Control Integration
│   ├── test_OnlyOwnerCanSetTokenAllowedIntegration()
│   │   └── Verifies owner-only token management:
│   │       ├── Owner can add tokens
│   │       ├── Non-owner rejected
│   │       └── Token usable after addition
│   │
│   └── test_TokenNotAllowedIntegration()
│       └── Tests token allowlist enforcement:
│           ├── Non-allowed token creation fails
│           ├── Allowed token creation succeeds
│           └── Multiple tokens managed correctly
│
├── Decommission Flow Integration
│   ├── test_DecommissionWithPartialDepositsIntegration()
│   │   └── Full decommission flow:
│   │       ├── Partial deposits made
│   │       ├── Window closes
│   │       ├── Decommission executed
│   │       ├── Funds returned to depositors
│   │       └── Circle deleted
│   │
│   └── test_CannotDecommissionWithAllDepositsIntegration()
│       └── Verifies decommission restrictions:
│           ├── All members deposit
│           ├── Decommission rejected
│           └── Normal withdrawal proceeds
│
├── Complex Scenario Integration Tests
│   ├── test_MultipleCirclesWithOverlappingMembers()
│   │   └── Tests members in multiple circles:
│   │       ├── Create two circles with shared members
│   │       ├── Independent deposit tracking
│   │       ├── Separate withdrawal rights
│   │       ├── Balance isolation per circle
│   │       └── No cross-contamination
│   │
│   └── test_CircleWithMaxMembers()
│       └── Tests with large member count (20):
│           ├── Gas cost verification
│           ├── Creation succeeds
│           ├── Multiple deposits tracked
│           ├── Balance accuracy
│           └── Performance acceptable
│
├── Token Transfer Integration
│   ├── test_DepositTokenTransferIntegration()
│   │   └── Verifies deposit token flow:
│   │       ├── Approval required
│   │       ├── transferFrom executed
│   │       ├── Contract receives tokens
│   │       └── Member balance updated
│   │
│   └── test_WithdrawTokenTransferIntegration()
│       └── Verifies withdrawal token flow:
│           ├── Contract has tokens
│           ├── Transfer to recipient
│           ├── Correct amount sent
│           └── Contract balance reduced
│
├── View Functions Integration
│   ├── test_GetCircleIntegration()
│   │   └── Tests circle data retrieval:
│   │       ├── All fields populated
│   │       ├── Data consistency
│   │       └── Updates reflected
│   │
│   ├── test_GetMemberCirclesIntegration()
│   │   └── Tests member circle tracking:
│   │       ├── Multiple circles returned
│   │       ├── Only member's circles
│   │       └── Accurate circle IDs
│   │
│   └── test_IsWithdrawableIntegration()
│       └── Verifies withdrawal eligibility:
│           ├── Time-based checks
│           ├── Deposit completion checks
│           ├── currentIndex checks
│           └── Accurate true/false returns
│
└── Error Handling Integration
    ├── test_RevertOnInsufficientBalanceIntegration()
    │   └── Tests insufficient balance handling:
    │       ├── Deposit without approval fails
    │       ├── Deposit with insufficient tokens fails
    │       └── Appropriate error messages
    │
    └── test_RevertOnInvalidTimingIntegration()
        └── Tests timing validation:
            ├── Early deposits rejected
            ├── Late deposits rejected
            ├── Early withdrawals blocked
            └── Proper revert reasons
```

## IntegrationBase.sol

Base contract providing common setup for integration tests:

```
IntegrationBase Setup
│
├── Contract Deployment
│   ├── SavingCircles proxy deployment
│   ├── MockERC20 token deployment
│   └── Owner assignment
│
├── Account Setup
│   ├── Alice account
│   │   ├── Address generation
│   │   ├── Token minting
│   │   └── Approval setup
│   │
│   ├── Bob account
│   │   ├── Address generation
│   │   ├── Token minting
│   │   └── Approval setup
│   │
│   └── Carol account
│       ├── Address generation
│       ├── Token minting
│       └── Approval setup
│
├── Base Circle Configuration
│   ├── Owner: Alice
│   ├── Members: [Alice, Bob, Carol]
│   ├── Deposit amount: 1000e18
│   ├── Interval: 7 days
│   ├── Max deposits: 1000
│   └── Current index: 0
│
└── Helper Functions
    ├── createBaseCircle()
    │   ├── Sets token as allowed
    │   └── Creates circle with base config
    │
    └── _setUpAccounts()
        ├── Mints tokens to accounts
        ├── Sets up approvals
        └── Populates members array
```

## Key Integration Test Patterns

### 1. **Full Flow Tests**
- Test complete user journeys
- Verify state changes across operations
- Ensure proper event emissions
- Check token balances throughout

### 2. **Multi-Contract Interactions**
- SavingCircles ↔ ERC20 token
- Proxy ↔ Implementation
- Multiple circles simultaneously
- Cross-circle member tracking

### 3. **Permission Boundaries**
- Owner vs member vs non-member
- Time-based permissions
- State-based permissions
- Token allowlist enforcement

### 4. **Edge Case Combinations**
- Maximum members with maximum deposits
- Overlapping circles with shared members
- Sequential circles with same configuration
- Concurrent operations on multiple circles