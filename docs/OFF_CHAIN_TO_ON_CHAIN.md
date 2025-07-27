# Off-Chain to On-Chain Circle Creation Flow

This document describes the new off-chain to on-chain circle creation flow implemented in the SavingCircles contract.

## Overview

The enhanced saving circles system now supports creating circles with email addresses before transitioning them to the blockchain. This reduces onboarding friction for users unfamiliar with web3.

## Flow Description

### 1. Off-Chain Circle Creation

Users can create a "pending circle" using only email addresses:

```solidity
ISavingCircles.PendingCircle memory pendingCircle = ISavingCircles.PendingCircle({
    ownerEmail: "alice@example.com",
    memberEmails: ["alice@example.com", "bob@example.com", "carol@example.com"],
    depositAmount: 1000e18,
    token: tokenAddress,
    depositInterval: 7 days,
    maxDeposits: 10,
    isActive: false // Set by contract
});

uint256 pendingId = savingCircles.createPendingCircle(pendingCircle);
```

### 2. Email to Address Mapping

As users onboard and create wallet addresses, their emails are mapped to their wallet addresses:

```solidity
savingCircles.mapEmailToAddress("alice@example.com", aliceWalletAddress);
savingCircles.mapEmailToAddress("bob@example.com", bobWalletAddress);
savingCircles.mapEmailToAddress("carol@example.com", carolWalletAddress);
```

### 3. Migration to On-Chain

Once all members have wallet addresses, the pending circle can be migrated to an active on-chain circle:

```solidity
uint256 circleStart = block.timestamp + 1 days;
uint256 circleId = savingCircles.migratePendingCircle(pendingId, circleStart);
```

### 4. Normal Circle Operations

After migration, the circle operates exactly like a traditional on-chain circle with deposits, withdrawals, etc.

## Key Features

### Minimal Changes to Existing Functionality
- All existing circle functionality remains unchanged
- Existing contracts and integrations continue to work without modification
- New functionality is additive, not replacing existing patterns

### Validation and Security
- Email validation ensures non-empty email addresses
- All members must have mapped wallet addresses before migration
- Pending circles become inactive after migration to prevent double-spending
- Same token allowlist and validation rules apply

### Events and Transparency
- `PendingCircleCreated`: Emitted when a pending circle is created
- `EmailMapped`: Emitted when an email is mapped to a wallet address  
- `CircleMigrated`: Emitted when a pending circle migrates on-chain
- All existing events continue to be emitted for migrated circles

## Web3 Wallet Integration

This system is designed to work with web3 wallet providers that support email/social login, such as:

- Magic (magic.link)
- Web3Auth
- Wallet Connect with social providers
- Account abstraction solutions

The email-to-address mapping can be handled by:
1. Frontend applications during user onboarding
2. Backend services that manage user accounts
3. Smart contract integrations with identity providers

## Error Handling

The system includes comprehensive error handling:

- `InvalidEmail`: Thrown for empty or invalid email addresses
- `PendingCircleNotFound`: Thrown when trying to access inactive pending circles
- `EmailNotMapped`: Thrown when trying to migrate with unmapped emails
- `TokenNotAllowed`: Thrown for non-allowlisted tokens (same as existing)

## Migration Considerations

- Pending circles do not have circle start times until migration
- Members are not added to memberCircles mapping until migration
- Token balances and deposits only work on migrated circles
- Pending circles can be created without gas costs (off-chain storage)

## Usage Examples

See the test files for complete usage examples:
- `/test/unit/SavingCirclesPending.t.sol` - Unit tests for pending circle functionality
- `/test/integration/SavingCirclesPending.t.sol` - End-to-end integration tests

## API Reference

### New Functions

#### `createPendingCircle(PendingCircle memory pendingCircle) returns (uint256)`
Creates a new pending circle with email addresses.

#### `mapEmailToAddress(string calldata email, address walletAddress)`
Maps an email address to a wallet address.

#### `migratePendingCircle(uint256 pendingId, uint256 circleStart) returns (uint256)`
Migrates a pending circle to an active on-chain circle.

#### `getPendingCircle(uint256 id) returns (PendingCircle memory)`
Retrieves a pending circle by ID.

#### `getAddressFromEmail(string calldata email) returns (address)`
Gets the wallet address mapped to an email.

### New Structures

#### `PendingCircle`
```solidity
struct PendingCircle {
    string ownerEmail;
    string[] memberEmails;
    uint256 depositAmount;
    address token;
    uint256 depositInterval;
    uint256 maxDeposits;
    bool isActive;
}
```