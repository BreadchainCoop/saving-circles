# Unit Tests Documentation

## SavingCirclesUnit.t.sol

This file contains comprehensive unit tests for the SavingCircles smart contract, verifying individual functions and their edge cases.

```
SavingCirclesUnit Tests
│
├── Basic Functionality Tests
│   ├── test_CreateCircleSuccess()
│   │   └── Tests successful creation of a new saving circle
│   ├── test_DepositSuccess()
│   │   └── Verifies standard deposit functionality works correctly
│   ├── test_WithdrawSuccess()
│   │   └── Tests successful withdrawal when conditions are met
│   └── test_ReentrancyProtection()
│       └── Ensures reentrancy attacks are prevented
│
├── Error Cases & Validation Tests
│   ├── test_InvalidCircleCreation()
│   │   └── Tests validation of invalid circle parameters
│   ├── test_InvalidDepositInterval()
│   │   └── Verifies rejection of zero deposit interval
│   ├── test_InvalidDepositAmount()
│   │   └── Ensures zero deposit amounts are rejected
│   ├── test_CreateWhenInvalidCurrentIndex()
│   │   └── Tests rejection of invalid current index values
│   ├── test_CreateWhenInvalidOwner()
│   │   └── Validates owner address cannot be zero
│   ├── test_CreateWhenInvalidMemberAddress()
│   │   └── Ensures member addresses cannot be zero
│   ├── test_CreateWhenCircleStartTimeIsZero()
│   │   └── Tests rejection of zero circle start time
│   ├── test_DepositExceedsDepositAmount()
│   │   └── Verifies deposits cannot exceed specified amount
│   ├── test_DepositForExceedsAmount()
│   │   └── Tests depositFor amount validation
│   ├── test_WithdrawForNonMember()
│   │   └── Ensures non-members cannot withdraw
│   ├── test_DecommissionWhenNotOwnerOrMember()
│   │   └── Tests decommission permission validation
│   └── test_DecommissionAfterCompleteCircle()
│       └── Verifies decommission behavior after completion
│
├── Edge Cases & Boundaries
│   ├── test_DepositBeforeCircleStart()
│   │   └── Tests deposits rejected before start time
│   ├── test_DepositAfterDepositWindow()
│   │   └── Verifies deposits blocked after window closes
│   ├── test_WithdrawBeforeWindowOpens()
│   │   └── Ensures withdrawals blocked before time
│   ├── test_MultipleWithdrawalsInSameWindow()
│   │   └── Tests single withdrawal per window enforcement
│   ├── test_DepositWhenCircleExpired()
│   │   └── Verifies CircleExpired revert is reachable
│   ├── test_ReentrancyOnWithdraw()
│   │   └── Tests reentrancy protection on withdrawals
│   └── test_IntegerOverflowProtection()
│       └── Verifies protection against integer overflow
│
├── Access Control Tests
│   ├── test_OnlyOwnerCanSetTokenAllowed()
│   │   └── Tests owner-only token allowlist management
│   ├── test_OnlyOwnerOrMemberCanDecommission()
│   │   └── Verifies decommission permissions
│   └── test_OnlyMemberCanDeposit()
│       └── Ensures only members can make deposits
│
├── Token Allowlist Tests
│   ├── test_SetTokenAllowed()
│   │   └── Tests adding tokens to allowlist
│   ├── test_CreateWithNotAllowedToken()
│   │   └── Verifies non-allowed tokens rejected
│   └── test_SetTokenAllowedNonOwner()
│       └── Tests permission restrictions
│
├── Decommission Tests
│   ├── test_DecommissionSuccess()
│   │   └── Tests successful decommission flow
│   ├── test_DecommissionNotEnoughTime()
│   │   └── Verifies time requirements
│   ├── test_DecommissionAllDepositsComplete()
│   │   └── Tests rejection when all deposits complete
│   └── test_DecommissionReturnsFunds()
│       └── Verifies fund returns on decommission
│
├── State Transition Tests
│   └── test_CircleLifecycleStateMachine()
│       └── Tests complete lifecycle state transitions:
│           ├── Created → Active
│           ├── Active → Withdrawing (incomplete deposits)
│           └── Withdrawing → Decommissioned
│
├── View Function Tests
│   ├── test_GetMemberCirclesWithManyCircles()
│   │   └── Tests getMemberCircles with multiple circles
│   └── test_CheckMembershipsPerformance()
│       └── Verifies membership check performance
│
└── Integration & Complex Scenarios
    ├── test_CompleteCircleLifecycle()
    │   └── Full end-to-end circle lifecycle test
    └── test_MultipleDepositsAndWithdrawals()
        └── Tests multiple rounds of deposits/withdrawals
```

## Key Test Categories

### 1. **Validation Tests**
- Ensure all input validation works correctly
- Test boundary conditions and edge cases
- Verify error messages are appropriate

### 2. **Access Control Tests**
- Verify only authorized users can perform actions
- Test role-based permissions (owner, member, non-member)
- Ensure modifiers work correctly

### 3. **State Machine Tests**
- Test all valid state transitions
- Verify invalid transitions are blocked
- Ensure state consistency throughout lifecycle

### 4. **Security Tests**
- Reentrancy protection validation
- Integer overflow/underflow protection
- Access control enforcement

### 5. **Business Logic Tests**
- Deposit and withdrawal mechanics
- Time-based restrictions
- Decommission conditions
- Token allowlist functionality