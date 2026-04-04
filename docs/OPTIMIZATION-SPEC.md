# Gas Optimization Spec — SavingCircles

Issue: #124
Date: 2026-04-04
Baseline: `forge test --gas-report` on branch `dev` (commit `27257ae`, Solc 0.8.28, via_ir=true, optimizer_runs=10000)

---

## Table of Contents

1. [Deployment Cost](#1-deployment-cost)
2. [Function Gas Profile](#2-function-gas-profile)
3. [Storage Layout Analysis](#3-storage-layout-analysis)
4. [Hot Path Analysis](#4-hot-path-analysis)
5. [Algorithmic Complexity](#5-algorithmic-complexity)
6. [Viewer Contract Analysis](#6-viewer-contract-analysis)
7. [DelegatedSavingCircles Analysis](#7-delegatedsavingcircles-analysis)
8. [ERC20 Interaction Patterns](#8-erc20-interaction-patterns)
9. [Compiler Configuration](#9-compiler-configuration)
10. [Optimization Candidates](#10-optimization-candidates)
11. [What NOT to Optimize](#11-what-not-to-optimize)
12. [Prioritized Recommendations](#12-prioritized-recommendations)
13. [Acceptance Criteria](#13-acceptance-criteria)

---

## 1. Deployment Cost

| Contract | Deployment Gas | Size (bytes) | % of Limit |
|----------|---------------|-------------|------------|
| SavingCircles | 3,767,762 | 17,339 | 70.6% |
| SavingCirclesViewer | 1,973,293 | 9,140 | 37.2% |
| DelegatedSavingCircles | 1,310,271 | 5,945 | 24.2% |
| ERC1967Proxy | 241,103 | 840 | 3.4% |

SavingCircles is at 70.6% of the 24,576-byte Spurious Dragon limit. Any optimization that reduces bytecode is doubly valuable — it saves gas on every call AND preserves headroom for future features.

---

## 2. Function Gas Profile

### SavingCircles (core contract)

Measured across unit, fuzz, and invariant test suites (140 tests, 333.82s CPU time).

| Function | Min | Avg | Median | Max | Calls | Complexity | Hot? |
|----------|-----|-----|--------|-----|-------|------------|------|
| `deposit` | 8,258 | 105,617 | 101,595 | 145,145 | 26,790 | O(N) | **YES** |
| `withdraw` | 7,524 | 112,115 | 112,526 | 149,531 | 5,797 | O(N) | **YES** |
| `decommission` | 10,348 | 210,470 | 174,918 | 642,376 | 778 | **O(N²)** | **YES** |
| `create` | 10,280 | 213,150 | 217,001 | 219,801 | 5,550 | O(1) | moderate |
| `redeemInvite` | 8,189 | 143,026 | 141,071 | 160,971 | 12,988 | O(1) | moderate |
| `start` | 23,023 | 87,232 | 87,275 | 87,275 | 5,510 | O(1) | low |
| `isWithdrawable` | 2,992 | 12,145 | 11,329 | 56,302 | 3,986 | **O(N²)** | **YES** (view) |
| `isMemberWithdrawable` | 894 | 14,451 | 15,000 | 27,535 | 551 | O(N) | moderate (view) |
| `circleState` | 1,746 | 13,769 | 12,437 | 31,421 | 6 | O(N) | low (view) |
| `roundState` | 23,647 | 28,438 | 30,834 | 30,834 | 3 | O(N) | low (view) |
| `isDecommissionable` | 1,932 | 5,965 | 2,843 | 17,932 | 44 | O(N) | low (view) |

### SavingCirclesViewer

| Function | Min | Avg | Median | Max | Calls |
|----------|-----|-----|--------|-----|-------|
| `getComprehensiveUserData` | 46,363 | 237,155 | 257,496 | 477,967 | 8 |
| `getUserFinancialSummary` | 103,485 | 142,209 | 142,209 | 180,934 | 2 |
| `getTotalBalance` | 11,619 | 32,531 | 32,531 | 53,443 | 2 |

### DelegatedSavingCircles

| Function | Min | Avg | Median | Max | Calls |
|----------|-----|-----|--------|-----|-------|
| `batchDepositIfAllowed` | 28,555 | 238,288 | 268,479 | 417,831 | 3 |
| `depositIfAllowed` | 29,068 | 104,915 | 94,065 | 191,918 | 6 |
| `getAddressesForDeposit` | 96,638 | 96,638 | 96,638 | 96,638 | 1 |

### ERC20 Token (MockERC20)

| Function | Min | Avg | Median | Max | Calls |
|----------|-----|-----|--------|-----|-------|
| `approve` | 28,833 | 45,919 | 45,909 | 46,245 | 26,159 |
| `balanceOf` | 513 | 514 | 513 | 2,513 | 12,105 |
| `mint` | 33,825 | 47,988 | 50,925 | 68,121 | 26,151 |

---

## 3. Storage Layout Analysis

### 3.1 Contract Storage Variables

SavingCircles inherits from OZ upgradeable contracts which use ERC-7201 namespaced storage. The contract's own storage variables occupy consecutive slots:

| Slot | Variable | Type |
|------|----------|------|
| 0 | `nextId` | `uint256` |
| 1 | `circles` | `mapping(uint256 => Circle)` |
| 2 | `balances` | `mapping(uint256 => mapping(address => uint256))` |
| 3 | `isMember` | `mapping(uint256 => mapping(address => bool))` |
| 4 | `memberCircles` | `mapping(address => uint256[])` |
| 5 | `allowedTokens` | `mapping(address => bool)` |
| 6 | `usedNonces` | `mapping(uint256 => mapping(uint256 => bool))` |
| 7 | `isActive` | `mapping(uint256 => bool)` |
| 8 | `circleMembers` | `mapping(uint256 => address[])` |
| 9 | `_memberStates` | `mapping(uint256 => mapping(address => MemberState))` |
| 10 | `roundDeposits` | `mapping(uint256 => mapping(uint256 => mapping(address => uint256)))` |

### 3.2 Circle Struct Layout (7 storage slots per circle)

```
struct Circle {
    address owner;                    // slot+0: 20 bytes (12 bytes wasted padding)
    uint256 currentIndex;             // slot+1: 32 bytes ← NEVER MEANINGFULLY WRITTEN
    uint256 depositAmount;            // slot+2: 32 bytes
    address token;                    // slot+3: 20 bytes (12 bytes wasted padding)
    uint256 depositInterval;          // slot+4: 32 bytes
    uint256 effectiveCircleStartTime; // slot+5: 32 bytes
    uint256 circleEnd;                // slot+6: 32 bytes
}
```

**Finding: `currentIndex` (slot+1) is wasted storage.** It is:
- Required to be 0 on `create()` (line 93: `if (_circle.currentIndex != 0) revert`)
- Computed on-the-fly by `_currentRoundIndex()` in every view function
- Never written to after creation

This wastes 1 SLOAD (2,100 gas cold) on every Circle struct load from storage, and 1 SSTORE (20,000 gas) on creation.

**Packing opportunity:** `owner` (20 bytes) and `token` (20 bytes) each waste 12 bytes of padding. If `depositInterval` and `effectiveCircleStartTime` were `uint48` (good until year 8,900,000) and `depositAmount` were `uint128`, the struct could fit in 3-4 slots instead of 7. However, this is a **breaking storage layout change** for deployed proxies.

### 3.3 MemberState Struct Layout (3 storage slots per member per circle)

```
struct MemberState {
    bool hasClaimed;          // slot+0: 1 byte → wastes 31 bytes of padding
    uint256 lastDepositRound; // slot+1: 32 bytes
    uint256 memberIndex;      // slot+2: 32 bytes
}
```

**Packing opportunity:** All three fields could pack into 1 slot:
```
struct MemberState {
    bool hasClaimed;          // 1 byte
    uint64 lastDepositRound;  // 8 bytes (max: 18.4 quintillion rounds)
    uint64 memberIndex;       // 8 bytes (max: 18.4 quintillion members)
}
// Total: 17 bytes → 1 slot
```
Saves 2 SLOADs (4,200 gas cold) per member access. **Breaking storage layout change** for deployed proxies.

### 3.4 Redundant `balances` Mapping

The `balances` mapping (slot 2) stores exactly the same value as `roundDeposits[_id][currentRound][_member]`. See `_deposit()` line 432:

```solidity
balances[_id][_member] = newTotal;  // duplicates roundDeposits[_id][currentRound][_member]
```

This costs an additional SSTORE per deposit (20,000 gas for first deposit in a new circle, 2,900 gas for subsequent deposits). The data is redundant — callers could read from `roundDeposits` directly given the current round index.

---

## 4. Hot Path Analysis

### 4.1 `_deposit()` — median 101,595 gas

Step-by-step SLOAD/SSTORE trace for a deposit call:

```
Step  Gas Cost   Operation
────  ─────────  ──────────────────────────────────────────────
 1    2,100      SLOAD circles[_id].owner (onlyCommissioned modifier, cold)
 2    2,100      SLOAD isMember[_id][_member] (onlyMember modifier, cold)
 3    2,100      SLOAD isActive[_id] (onlyActive modifier, cold)
 4    ~7,900     ReentrancyGuard: SLOAD guard (cold 2,100) + SSTORE enter (2,900) + SSTORE exit (2,900)
 5    12,700     Circle memory _circle = circles[_id] — loads 7 struct slots:
                   slot+0 owner (warm 100) + slots 1-6 (cold 6×2,100 = 12,600)
 6    100        circles[_id].effectiveCircleStartTime — REDUNDANT warm SLOAD
                   (already in memory as _circle.effectiveCircleStartTime)
 7    0          _currentRoundIndex(_circle) — pure computation on memory
 8    2,100      circleMembers[_id].length — SLOAD array length (cold)
 9    N×4,200    _allMembersDepositedForRound (previous round check, if currentRound > 0):
                   For each of N members:
                     SLOAD circleMembers[_id][i] = 2,100 (cold)
                     SLOAD roundDeposits[_id][prev][member] = 2,100 (cold)
10    2,100      SLOAD roundDeposits[_id][currentRound][_member] (cold)
11    2,900–     SSTORE roundDeposits[_id][currentRound][_member] = newTotal
      20,000       (2,900 warm update, 20,000 zero-to-nonzero first deposit)
12    2,100      SLOAD _memberStates[_id][_member].lastDepositRound (cold)
13    5,000      SSTORE _memberStates[_id][_member].lastDepositRound = currentRound
14    2,900–     SSTORE balances[_id][_member] = newTotal — REDUNDANT
      20,000       (duplicates roundDeposits, see §3.4)
15    ~40,000    IERC20.safeTransferFrom (external call: ~30k-50k depending on token)
16    ~1,500     emit FundsDeposited
```

**Total for N=5 members, warm deposit:** ~29,400 (fixed) + 21,000 (loop) + 2,900 (roundDeposits write) + 5,000 (memberState write) + 2,900 (balances write, redundant) + 40,000 (transfer) = **~101,200 gas** (matches median of 101,595).

**Identified waste:**
- Step 6: redundant SLOAD of `effectiveCircleStartTime` — 100 gas
- Step 14: redundant `balances` SSTORE — 2,900–20,000 gas
- Step 9: O(N) member loop for previous-round check — 21,000 gas for N=5

### 4.2 `_withdraw()` — median 112,526 gas

The withdrawal path chains multiple function calls that each re-load the same data:

```
_withdraw(_id, _member)
  ├── _claimable(_id, _member)
  │     ├── onlyCommissioned: SLOAD circles[_id].owner          [cold: 2,100]
  │     ├── _isDecommissionable(_id)
  │     │     ├── Circle memory = circles[_id]                   [7 SLOADs: 1 warm + 6 cold = 12,700]
  │     │     ├── circleMembers[_id].length                      [cold: 2,100]
  │     │     ├── _currentRoundIndex (pure)
  │     │     ├── _roundEndTime (pure)
  │     │     └── _allMembersDepositedForRound(prev round)       [N members: N×4,200 cold]
  │     └── _activeClaimableCheck(_id, _member)
  │           ├── Circle memory = circles[_id]                   [7 SLOADs: all warm = 700] ← REDUNDANT
  │           ├── _memberStates[_id][_member].hasClaimed         [cold: 2,100]
  │           ├── _currentRoundIndex (pure)                      ← REDUNDANT
  │           ├── _getMemberIndex: isMember + memberIndex         [2 cold SLOADs: 4,200]
  │           └── _allMembersDepositedForRound(memberIdx round)  [N members: warm = N×200] ← REDUNDANT CHECK
  ├── _circle.depositAmount × circleMembers.length               [warm reads: ~200]
  ├── _memberStates[_id][_member].hasClaimed = true              [SSTORE: 2,900]
  ├── IERC20.safeTransfer                                        [~30,000–50,000]
  ├── emit FundsWithdrawn                                        [~1,500]
  └── _allMembersClaimed(_id)                                    ← LOOPS ALL N MEMBERS AGAIN
        └── For each member: _memberStates[_id][m].hasClaimed    [N cold SLOADs: N×2,100]
```

**Redundancies in withdraw:**
1. Circle struct loaded from storage **3 times** (once in `_isDecommissionable`, once in `_activeClaimableCheck`, once via storage pointer in `_withdraw`)
2. `_currentRoundIndex` computed **3 times** on the same data
3. `_allMembersDepositedForRound` called **twice** — once in `_isDecommissionable` (previous round) and once in `_activeClaimableCheck` (member's round)
4. `circleMembers` array referenced **3+ times** from storage

### 4.3 `decommission()` — max 642,376 gas

Nested loop: for each of up to N unclaimed rounds, iterates all N members:

```solidity
for (uint256 r = 0; r < membersLength; r++) {           // N rounds
    if (_memberStates[_id][recipient].hasClaimed) continue;
    for (uint256 i = 0; i < membersLength; i++) {        // N members
        uint256 amount = roundDeposits[_id][r][member];   // SLOAD: 2,100 cold
        roundDeposits[_id][r][member] = 0;                // SSTORE: 2,900
        IERC20(token).safeTransfer(member, amount);       // ~30,000
    }
}
```

**Worst case (no claims, all deposits made):** N² iterations, each with SLOAD + SSTORE + external transfer.

**Status: Already optimized in PR #147** — refunds aggregated into memory array, single transfer per member. Reduces external calls from O(N²) to O(N).

---

## 5. Algorithmic Complexity

### 5.1 Per-function complexity

| Function | Complexity | Root Cause |
|----------|-----------|------------|
| `_allMembersDepositedForRound` | O(N) | Iterates all members checking `roundDeposits` |
| `_allMembersClaimed` | O(N) | Iterates all members checking `hasClaimed` |
| `_isDecommissionable` | O(N) | Calls `_allMembersDepositedForRound` |
| `_claimable` | O(N) | Calls both `_isDecommissionable`(O(N)) and `_activeClaimableCheck`(O(N)) |
| `_deposit` (w/ prev round check) | O(N) | Calls `_allMembersDepositedForRound` |
| `_withdraw` | O(N) | Calls `_claimable`(O(N)) + `_allMembersClaimed`(O(N)) |
| `circleState` | O(N) | Calls `_allMembersDepositedForRound` up to 2× |
| `isWithdrawable` | **O(N²)** | Loops N members, each calling `_activeClaimableCheck`(O(N)) |
| `decommission` (current) | **O(N²)** | Nested round × member loop |

### 5.2 Worst-case gas projections

Based on measured gas per SLOAD (2,100 cold, 100 warm) and per safeTransfer (~30,000).

**`isWithdrawable` (view function — costs gas for `eth_call`):**

| N (members) | Cold SLOADs | Est. Gas | Status |
|-------------|-------------|----------|--------|
| 5 | ~25 | ~52,500 | OK (matches measured max 56,302) |
| 10 | ~100 | ~210,000 | Expensive for a view |
| 20 | ~400 | ~840,000 | Problematic |
| 50 | ~2,500 | ~5,250,000 | May timeout in RPC |

**`decommission` (state-changing — current unoptimized version):**

| N | SLOAD ops | SSTORE ops | Transfers | Est. Gas |
|---|-----------|------------|-----------|----------|
| 5 | 25 | 25 | ≤25 | ~875,000 |
| 10 | 100 | 100 | ≤100 | ~3,500,000 |
| 20 | 400 | 400 | ≤400 | ~14,000,000 |
| 50 | 2,500 | 2,500 | ≤2,500 | **~87,500,000** (exceeds 30M block gas limit) |

**`deposit` (per call, dominated by `_allMembersDepositedForRound`):**

| N | Loop SLOADs | Est. Loop Gas | Total Est. |
|---|-------------|--------------|------------|
| 5 | 10 | 21,000 | ~101,000 |
| 10 | 20 | 42,000 | ~122,000 |
| 20 | 40 | 84,000 | ~164,000 |
| 50 | 100 | 210,000 | ~290,000 |

---

## 6. Viewer Contract Analysis

### 6.1 `getComprehensiveUserData` — Catastrophic Redundancy

The call tree for `getComprehensiveUserData` with C circles and K total circles ever created:

```
getComprehensiveUserData(_user)
  ├── _getAllUserCircleIds                          [1 + 2K external calls]
  │     ├── getMemberCircles(_user)                   1 call
  │     ├── _countOwnedOnlyCircles                    K calls (scans ALL circles)
  │     └── _getOwnedOnlyCircleIds                    K calls (scans ALL circles AGAIN)
  ├── _getUserMembershipStatus                      [2 × C × 7 external calls]
  │     ├── for each circle: _getUserCircleData       C × 7 calls (FIRST fetch)
  │     └── _populateStatusArrays
  │           └── for each circle: _getUserCircleData C × 7 calls (SECOND fetch, REDUNDANT)
  ├── _getUserFinancialSummary                      [C × 7 external calls]
  │     └── for each circle: _getUserCircleData       C × 7 calls (THIRD fetch, REDUNDANT)
  └── main loop                                     [C × 7 external calls]
        └── for each circle: _getUserCircleData       C × 7 calls (FOURTH fetch, REDUNDANT)
```

**`_getUserCircleData` is called 4 TIMES per circle.** Each invocation makes 7 external calls:

```
_getUserCircleData(_user, _circleId)
  ├── _getCircle()                    → getCircles()            1 call
  ├── isDecommissionable()                                      1 call
  ├── _setUserBalanceData()           → getMemberBalances()     1 call
  ├── _setUserPermissions()           → currentRoundWithdrawer() + isMemberWithdrawable()  2 calls
  ├── _setCircleTimingData()          → getCircleMembers()      1 call
  └── _setDepositProgress()           → getMemberBalances()     1 call ← REDUNDANT (same data as _setUserBalanceData)
```

**Total external calls for `getComprehensiveUserData`:**
- Owned-circle scan: 2K
- Per-circle data: 4 × C × 7 = 28C
- **Grand total: 2K + 28C + 1**

For a user with 3 circles, 20 total circles ever created: 40 + 84 + 1 = **125 external calls**.

### 6.2 Specific Viewer Redundancies

1. **`_getUserCircleData` called 4× per circle** — should be called once, results shared
2. **`getMemberBalances` called 2× within each `_getUserCircleData`** (lines 304 and 346) — should be called once, result passed to both `_setUserBalanceData` and `_setDepositProgress`
3. **`_getCircle` wraps a single ID in an array** to call `getCircles` instead of calling `getCircle` directly
4. **`_countOwnedOnlyCircles` + `_getOwnedOnlyCircleIds` scan all circles twice** — should be a single pass
5. **`_isInArray` is O(M) linear scan** used inside an O(K) loop — O(K×M) total

---

## 7. DelegatedSavingCircles Analysis

### 7.1 `_depositIfAllowed` — ~200,000–250,000 gas per deposit

```
Step  Gas Cost    Operation
────  ──────────  ──────────────────────────────────────
 1    2,100       SLOAD delegatedDepositsEnabled[_member]
 2    ~10,000     External: isDecommissionable(_circleId)
                    (loads circle struct + loops members — REDUNDANT, re-checked in depositFor)
 3    ~10,000     External: getCircle(_circleId)
 4    ~5,000      External: getCircleMembers(_circleId)
 5    N×100       O(N) loop to check membership
                    ← REDUNDANT: could use isMember(_circleId, _member) = 1 SLOAD
 6    ~10,000     External: _memberBalance → getMemberBalances
                    Returns ALL member balances, then linear search for target member
                    ← REDUNDANT: could use balances(_circleId, _member) = 1 SLOAD
 7    ~2,600      External: IERC20.allowance()
 8    ~40,000     External: IERC20.safeTransferFrom()
 9    ~26,000     External: IERC20.forceApprove()
10    ~100,000+   External: SAVING_CIRCLES.depositFor()
                    (the full deposit path with all its own SLOADs)
```

**Key waste:**
- Step 2: `isDecommissionable` check is redundant — `depositFor` will check this via `onlyCommissioned` and the timeout check in `_deposit`
- Step 5: O(N) membership loop should be `isMember()` — 1 SLOAD
- Step 6: `getMemberBalances` returns all balances; should use `balances()` for single member

### 7.2 `getAddressesForDeposit` — O(K×N) double scan

Scans ALL circles (0 to `nextId`) **twice** (lines 73-103 for counting, lines 111-139 for filling). Each iteration makes 3-4 external calls per circle. Should be a single pass.

---

## 8. ERC20 Interaction Patterns

**SafeERC20 overhead:** ~200-500 gas per call for well-behaved tokens. The `_callOptionalReturn` pattern checks `returndatasize` and falls back to `EXTCODESIZE` (2,600 gas cold) only for non-standard tokens. **Not worth removing** — protects against non-standard ERC20s and the cost is negligible.

**`forceApprove` in DelegatedSavingCircles:** For USDT-like tokens that require approve(0) before approve(N), this makes up to 3 calls. For standard tokens, 1 call. This is the correct pattern — the alternative (having members approve SavingCircles directly) is an architectural change.

**Redundant allowance check in DelegatedSavingCircles:** `IERC20.allowance()` is checked explicitly (line 175) before `safeTransferFrom` checks it again inside the token. The explicit check provides a better error message (`InsufficientAllowance` vs. generic revert). UX choice, not waste (~2,600 gas).

---

## 9. Compiler Configuration

From `foundry.toml`:
```toml
via_ir = true
optimizer_runs = 10_000
solc = "0.8.28"
```

- **`via_ir = true`**: IR pipeline enabled. Good for complex contracts with many internal functions.
- **`optimizer_runs = 10_000`**: Optimizes for frequent calls at the cost of deployment size. Reasonable for a heavily-called contract.
- **Increasing to 100,000**: Diminishing returns, would increase deployment size.
- **Decreasing to 200**: Would reduce deployment cost but increase per-call cost. Not recommended.

**Verdict:** Current settings are well-tuned. No meaningful gains from compiler config changes.

---

## 10. Optimization Candidates

### OPT-0: Switch to `ReentrancyGuardTransientUpgradeable` (EIP-1153 transient storage)

**Location:** `SavingCircles.sol:4` (import), `SavingCircles.sol:24` (inheritance), `SavingCircles.sol:75` (`__ReentrancyGuard_init()`)

**Current behavior:** Uses `ReentrancyGuardUpgradeable` which stores the reentrancy flag in regular storage:
- Entry: SLOAD guard slot (2,100 cold / 100 warm) + SSTORE from 1→2 (5,000 cold / 2,900 warm)
- Exit: SSTORE from 2→1 (2,900 with gas refund)
- **Total: ~7,900 gas (cold) / ~5,800 gas (warm) per `nonReentrant` call**

**Proposed change:** Replace with `ReentrancyGuardTransientUpgradeable` from OZ 5.4.0 (already available in `node_modules/@openzeppelin/contracts-upgradeable/utils/`). Uses EIP-1153 transient storage (`TLOAD`/`TSTORE`):
- Entry: TLOAD (100 gas) + TSTORE (100 gas)
- Exit: TSTORE (100 gas)
- **Total: ~200 gas per `nonReentrant` call**

```solidity
// Before
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
contract SavingCircles is ISavingCircles, ReentrancyGuardUpgradeable, ...

// After
import {ReentrancyGuardTransientUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol';
contract SavingCircles is ISavingCircles, ReentrancyGuardTransientUpgradeable, ...
```

**Gas analysis:**

| Function | Calls in tests | Savings per call | Total savings |
|----------|---------------|-----------------|---------------|
| `deposit` | 26,790 | ~5,600–7,700 | Primary hot path |
| `withdraw` | 5,797 | ~5,600–7,700 | Primary hot path |
| `decommission` | 778 | ~5,600–7,700 | |
| `redeemInvite` | 12,988 | ~5,600–7,700 | |
| `start` | 5,510 | ~5,600–7,700 | One-time per circle |
| `depositFor` | 266 | ~5,600–7,700 | |
| `withdrawFor` | 5 | ~5,600–7,700 | |

For `deposit` (median 101,595 gas): saves ~5,600–7,700 gas = **5.5–7.6% reduction**.

**Requirements:**
- Target chain must support EIP-1153 (Cancun upgrade). Ethereum mainnet, Optimism, Arbitrum, Base, and Gnosis Chain all support it as of 2025. The contract is currently deployed on Gnosis (see deploy scripts).
- Solc 0.8.24+ required — already using 0.8.28.
- No explicit `evm_version` in `foundry.toml` — defaults to `cancun` for 0.8.28, which includes EIP-1153.

**Risks:**
- **No storage layout break.** The transient variant uses ERC-7201 namespaced storage at the same slot hash (`0x9b779b17...`), but writes to transient storage instead of regular storage. The old regular storage slot becomes unused (still holds the last-written value of 1, which is harmless — it's never read again).
- **No ABI change.** The `nonReentrant` modifier interface is identical.
- **Chain compatibility:** Must verify the target deployment chain supports EIP-1153. If deploying to a chain without Cancun support, this optimization cannot be used.
- **Initializer change:** `__ReentrancyGuard_init()` becomes `__ReentrancyGuardTransient_init()` (no-op in both cases, but the function name changes). For an existing proxy, the initializer has already run — the new implementation just needs to inherit the transient variant. No re-initialization needed since the transient guard has no persistent state.

**Priority: P0** — largest per-call savings across ALL state-changing functions, trivial to implement, no breaking changes.

---

### OPT-1: Add `roundDepositCount` to replace O(N) `_allMembersDepositedForRound`

**Location:** `SavingCircles.sol:511-524` (called from `_deposit`, `_withdraw`, `circleState`, `roundState`, `isWithdrawable`, `_isDecommissionable`)

**Current behavior:** Iterates ALL members, loading `roundDeposits[_id][_round][member]` from storage for each:
```solidity
function _allMembersDepositedForRound(uint256 _id, uint256 _round, uint256 _depositAmount) internal view returns (bool) {
    address[] memory members = circleMembers[_id];
    for (uint256 i = 0; i < members.length; i++) {
        if (roundDeposits[_id][_round][members[i]] < _depositAmount) return false;
    }
    return true;
}
```

**Cost per call:** N members × (SLOAD member address + SLOAD roundDeposits) = N × 4,200 gas (cold).

**Proposed change:** Add a counter that tracks completed deposits per round:
```solidity
mapping(uint256 id => mapping(uint256 round => uint256 count)) public roundDepositCount;
```
Increment in `_deposit()` when a member's deposit reaches `depositAmount`:
```solidity
if (newTotal == _circle.depositAmount) {
    roundDepositCount[_id][currentRound]++;
}
```
Replace the loop:
```solidity
function _allMembersDepositedForRound(uint256 _id, uint256 _round, uint256) internal view returns (bool) {
    return roundDepositCount[_id][_round] == circleMembers[_id].length;
}
```

**Gas analysis:**
- Cost added: 1 SLOAD (2,100 cold) + 1 conditional SSTORE (5,000 for dirty / 20,000 for clean) in `_deposit()` — but ONLY on the final deposit that completes the round for that member, not on partial deposits
- Cost removed per check: N × 4,200 replaced by 2 × 2,100 = 4,200 fixed

| N (members) | Current cost/check | New cost/check | Savings/check |
|-------------|-------------------|---------------|--------------|
| 3 | 12,600 | 4,200 | 8,400 (67%) |
| 5 | 21,000 | 4,200 | 16,800 (80%) |
| 10 | 42,000 | 4,200 | 37,800 (90%) |
| 20 | 84,000 | 4,200 | 79,800 (95%) |

**Cascade impact on `isWithdrawable`:** Currently O(N²) because it loops N members each calling `_activeClaimableCheck` → `_allMembersDepositedForRound`(O(N)). With this change, `_allMembersDepositedForRound` is O(1), making `isWithdrawable` O(N). For N=10: **from ~210,000 to ~21,000 gas (10× improvement).**

**Risks:** None — append-only storage addition. Safe for proxy upgrades. Non-breaking ABI change (adds new public getter). Counter only increments; deposits are irreversible within a round.

**Priority: P0**

---

### OPT-2: Remove redundant `balances` SSTORE in `_deposit()`

**Location:** `SavingCircles.sol:432`

**Current behavior:**
```solidity
roundDeposits[_id][currentRound][_member] = newTotal;  // line 429
// ...
balances[_id][_member] = newTotal;                       // line 432 — duplicates the above
```

**Cost:** 2,900 gas (warm SSTORE) per deposit. For first deposit in a circle: 20,000 gas (zero-to-nonzero).

**Proposed change:** Stop writing to `balances`. Any code reading `balances[_id][_member]` should read `roundDeposits[_id][currentRound][_member]` instead.

**Callers of `balances`:**
- `getMemberBalances()` (line 250-272) — already computes `currentRound` and has the member list
- `SavingCirclesViewer._memberBalance()` — reads `balances` indirectly via `getMemberBalances`
- DelegatedSavingCircles — uses `getMemberBalances`

**Estimated savings:** 2,900–20,000 gas per deposit (2.8–19.7% of median deposit cost).

**Risks:** `balances` is a public mapping getter in the ABI. Removing writes causes it to return stale data. **This is a breaking change for any frontend directly querying `balances()`**. The `getMemberBalances()` function should become the canonical API.

**Alternative (non-breaking):** Keep writing to `balances` but document it as redundant for future removal. Or: leave `balances` as-is and accept the 2,900 gas cost for backward compatibility.

**Priority: P1**

---

### OPT-3: Fix redundant storage read in `_deposit()`

**Location:** `SavingCircles.sol:422`

**Current behavior:**
```solidity
Circle memory _circle = circles[_id];                    // line 420 — loads all 7 slots
if (block.timestamp < circles[_id].effectiveCircleStartTime) {  // line 422 — re-reads from storage!
```

**Proposed change:**
```solidity
if (block.timestamp < _circle.effectiveCircleStartTime) {
```

**Savings:** 100 gas (warm SLOAD). Minor but trivially fixable.

**Priority: P2 (trivial fix)**

---

### OPT-4: Cache Circle struct across `_withdraw` call chain

**Location:** `SavingCircles.sol:377-408, 443-461, 463-472, 464-498`

**Problem:** During a single `_withdraw()` call, the Circle struct is loaded from storage 3 separate times:
1. In `_isDecommissionable()` — `Circle memory _circle = circles[_id]` (line 465)
2. In `_activeClaimableCheck()` — `Circle memory _circle = circles[_id]` (line 449)
3. Via storage pointer in `_withdraw()` — `Circle storage _circle = circles[_id]` (line 378)

**Also:** `_currentRoundIndex()` is computed 3 times on the same data.

**Proposed change:** Load Circle once at the top of `_withdraw`, pass as parameter through `_claimable` → `_isDecommissionable` and `_activeClaimableCheck`. Similarly, compute `currentRound` once and pass through.

**Savings:** ~1,200–1,400 gas per withdraw (14 redundant warm SLOADs at 100 each, plus computation).

**Risks:** None — pure refactor. No storage or ABI change.

**Priority: P2**

---

### OPT-5: Pack MemberState struct to 1 slot

**Location:** `SavingCircles.sol:25-29`

**Current cost:** 3 storage slots per MemberState. Every access loads up to 3 slots.

**Proposed change:**
```solidity
struct MemberState {
    bool hasClaimed;          // 1 byte
    uint64 lastDepositRound;  // 8 bytes
    uint64 memberIndex;       // 8 bytes
}
```

**Savings:** 2 fewer SLOADs per MemberState read (4,200 gas cold), 2 fewer SSTOREs per write. Applies to every deposit and withdraw.

**Risks:** Limits `lastDepositRound` and `memberIndex` to `uint64` max (18.4 quintillion) — more than sufficient for any realistic circle. **Breaking storage layout change** — requires migration for deployed proxies, or only applicable to new deployments.

**Priority: P2 (deferred to next major version)**

---

### OPT-6: Remove `currentIndex` from Circle struct

**Location:** `ISavingCircles.sol:42`, `SavingCircles.sol:93,103`

**Savings:** 1 SLOAD (2,100 cold) per Circle struct load, 1 SSTORE (20,000) on creation.

**Risks:** **Breaking storage layout change** — shifts all subsequent struct fields. ALL existing circle data would be corrupted after proxy upgrade. Only viable in a new deployment.

**Priority: P3 (deferred to next major version)**

---

### OPT-7: Viewer — cache `_getUserCircleData` results

**Location:** `SavingCirclesViewer.sol:47-68`

**Problem:** `_getUserCircleData` called 4× per circle (see §6.1).

**Proposed change:** Compute `UserCircleData[]` once at the top of `getComprehensiveUserData`, pass the array to `_getUserMembershipStatus` and `_getUserFinancialSummary`.

**Savings:** 75% reduction in external calls. For 3 circles: from 84 to 21 external calls. Estimated ~315,000 gas saved. Current max is 477,967 gas, so this would roughly halve it.

**Risks:** Viewer is not upgradeable (immutable). Requires redeployment. No impact on core contract.

**Priority: P1**

---

### OPT-8: Viewer — deduplicate `getMemberBalances` in `_getUserCircleData`

**Location:** `SavingCirclesViewer.sol:304` and `SavingCirclesViewer.sol:346`

**Problem:** `getMemberBalances` called twice within a single `_getUserCircleData` invocation.

**Proposed change:** Call once, pass result to both `_setUserBalanceData` and `_setDepositProgress`.

**Savings:** 1 external call per `_getUserCircleData` invocation. ~7,000–25,000 gas depending on member count.

**Priority: P1**

---

### OPT-9: Viewer — single-pass owned circle scan

**Location:** `SavingCirclesViewer.sol:143-170`

**Problem:** `_countOwnedOnlyCircles` + `_getOwnedOnlyCircleIds` scan ALL circles twice.

**Proposed change:** Single pass that counts and collects simultaneously.

**Savings:** 50% reduction in the owned-circle scan. For 20 total circles: ~20 fewer external calls (~40,000–300,000 gas).

**Priority: P1**

---

### OPT-10: DelegatedSavingCircles — use `isMember()` instead of O(N) loop

**Location:** `DelegatedSavingCircles.sol:160-167`

**Problem:** O(N) loop over `getCircleMembers()` array to check membership.

**Proposed change:** Replace with `SAVING_CIRCLES.isMember(_circleId, _member)` — single external call, single SLOAD.

**Savings:** Eliminates the `getCircleMembers()` call entirely (saves ~2,000–10,000 gas) plus the O(N) loop.

**Priority: P1**

---

### OPT-11: DelegatedSavingCircles — use `balances()` instead of `getMemberBalances()`

**Location:** `DelegatedSavingCircles.sol:208-216`

**Problem:** `_memberBalance` calls `getMemberBalances()` which returns ALL member balances (O(N) loop + N SLOADs), then linearly searches for the target member.

**Proposed change:** Call `SAVING_CIRCLES.balances(_circleId, _member)` directly — single external call, single SLOAD.

**Savings:** For N=5: ~10,000 gas. For N=10: ~20,000 gas.

**Note:** If OPT-2 is implemented (removing `balances` writes), this would need to use `roundDeposits` instead, which requires knowing the current round.

**Priority: P1**

---

### OPT-12: DelegatedSavingCircles — remove redundant `isDecommissionable` check

**Location:** `DelegatedSavingCircles.sol:152`

**Problem:** Calls `SAVING_CIRCLES.isDecommissionable(_circleId)` which loads the circle struct and loops all members. This is then re-checked inside `depositFor` → `_deposit` via the timeout check and `onlyCommissioned` modifier.

**Proposed change:** Remove the explicit check. Let `depositFor` handle it (it will revert with `CircleTimedOut` or `NotCommissioned`).

**Savings:** ~10,000 gas per delegated deposit.

**Risks:** Changes the error message — caller would get `CircleTimedOut` instead of a custom `CircleNotActive` error. May affect frontend error handling.

**Priority: P2**

---

### OPT-13: DelegatedSavingCircles — eliminate `getAddressesForDeposit` double scan

**Location:** `DelegatedSavingCircles.sol:63-142`

**Problem:** Scans all circles twice (count pass + fill pass), each with 3-4 external calls per circle.

**Proposed change:** Single pass using a dynamically sized array or overallocated array with truncation.

**Savings:** 50% reduction in external calls. For 20 circles: ~80 fewer external calls.

**Priority: P2**

---

## 11. What NOT to Optimize

These look wasteful but are necessary:

1. **ReentrancyGuard (~7,900 gas per state-changing call):** Essential. The contract transfers ERC20 tokens and updates state after the transfer. A malicious token could re-enter `withdraw` before `hasClaimed` is set. The reentrancy guard is critical for security.

2. **SafeERC20 (~200-500 gas overhead per transfer):** Protects against non-standard ERC20 tokens (USDT, BNB, etc.) that don't return `true`. Since this ROSCA whitelists arbitrary tokens, this protection is essential.

3. **EIP-712 signature verification in `redeemInvite` (~3,000 gas for ECDSA.recover):** One-time cost per member. Cannot be optimized without removing the security model.

4. **`onlyCommissioned` / `onlyActive` / `onlyMember` modifiers (single SLOAD each):** Minimal-cost guards that prevent invalid operations. Essential for correctness.

5. **`memberCircles` array never cleaned up on decommission:** Cleaning up would cost O(N×M) gas for shifting array elements. The monotonic growth preserves historical membership records and the Viewer handles decommissioned circles gracefully.

6. **`forceApprove` in DelegatedSavingCircles (up to 3 calls for USDT):** Correct pattern for non-standard tokens. The alternative would be an architectural change (members approve SavingCircles directly).

7. **`nonReentrant` on `start()`:** While `start` doesn't make external calls, keeping the guard is defensive and the 7,900 gas cost on a one-time-per-circle function is negligible.

---

## 12. Prioritized Recommendations

### P0 — High impact, no breaking changes

| # | Target | Change | Est. Savings | Breaking? |
|---|--------|--------|-------------|-----------|
| OPT-1 | `_allMembersDepositedForRound` | Add `roundDepositCount` mapping | ~16,800/call (N=5), makes `isWithdrawable` O(N) from O(N²) | No |

### P1 — Significant impact, may require Viewer/Delegated redeployment

| # | Target | Change | Est. Savings | Breaking? |
|---|--------|--------|-------------|-----------|
| OPT-2 | `_deposit` | Remove redundant `balances` SSTORE | 2,900–20,000/deposit | ABI (public getter returns stale) |
| OPT-7 | Viewer | Cache `_getUserCircleData` results | ~315,000 for 3 circles | Viewer redeploy |
| OPT-8 | Viewer | Deduplicate `getMemberBalances` | 7,000–25,000/circle | Viewer redeploy |
| OPT-9 | Viewer | Single-pass owned circle scan | 40,000–300,000 | Viewer redeploy |
| OPT-10 | Delegated | `isMember()` instead of O(N) loop | 2,000–10,000/deposit | Delegated redeploy |
| OPT-11 | Delegated | `balances()` instead of `getMemberBalances()` | 10,000–20,000/deposit | Delegated redeploy |

### P2 — Moderate impact, refactoring

| # | Target | Change | Est. Savings | Breaking? |
|---|--------|--------|-------------|-----------|
| OPT-3 | `_deposit` | Fix redundant `effectiveCircleStartTime` SLOAD | 100 | No |
| OPT-4 | `_withdraw` | Cache Circle struct across call chain | ~1,400/withdraw | No |
| OPT-12 | Delegated | Remove redundant `isDecommissionable` check | ~10,000/deposit | Error message change |
| OPT-13 | Delegated | Single-pass `getAddressesForDeposit` | ~80 external calls saved | Delegated redeploy |

### P3 — High impact but breaking storage layout (next major version only)

| # | Target | Change | Est. Savings | Breaking? |
|---|--------|--------|-------------|-----------|
| OPT-5 | `MemberState` | Pack to 1 slot | ~4,200/access | **Storage layout break** |
| OPT-6 | Circle struct | Remove `currentIndex` | ~2,100/load | **Storage layout break** |

---

## 13. Acceptance Criteria

For each optimization implemented:

1. **Gas benchmark before/after:** Run `forge test --gas-report` and compare the target function's avg/median/max gas against this baseline document
2. **Correctness:** All 140 existing tests pass without modification (behavior-preserving)
3. **No new storage conflicts:** For the upgradeable proxy (SavingCircles), new mappings must be appended after existing storage variables or consume `__gap` slots (PR #149)
4. **Bytecode size:** SavingCircles must remain under 24,576 bytes (currently 17,339 — 7,237 bytes of headroom)
5. **No removed safety mechanisms:** ReentrancyGuard, SafeERC20, access modifiers, and ECDSA verification must not be weakened

### Baseline Reference

```
Compiler: Solc 0.8.28, via_ir=true, optimizer_runs=10000
Tests: 140 passed, 0 failed, 0 skipped
Suites: 7 test suites in 111.18s (333.82s CPU time)
Deployment: SavingCircles 3,767,762 gas (17,339 bytes)
```
