# Goal Saving Circles

*Goal-based group savings: a small group commits to saving toward a concrete target — "5,000 BREAD
for the neighborhood oven" — by a date.*

This document is the design rationale for `src/contracts/GoalSavingCircles.sol`. The full
implementable spec (storage layout, exact math, complete test plan) lives in the design notes that
produced it; this is the short version for reviewers.

---

## 0. What problem it solves

Saving alone is hard; the commitment device of a group with a shared, visible target makes it
easier. The organizer creates the goal and invites members with the same signed `StacksInvite`
links the app already uses for `SavingCircles`. Members deposit whatever they can, whenever they
can. Until the goal resolves, the money is locked — that lock IS the product. This is deliberately
the simplest stack type: no credit, no interest, no auctions, no rounds, and **no division
anywhere** — the contract only ever adds and subtracts exact deposit amounts.

## 1. The mechanism

A goal is an immutable config fixed at `create`: `(owner, token, beneficiary, goalAmount,
deadline)`. The creator is the goal owner and its first member. State is **derived, never stored**:

```
cancelled  → Cancelled          (owner called cancel during Funding; terminal)
released   → Released           (pot paid to beneficiary; terminal)
goalReached→ Funded             (one-way latch: pot once hit goalAmount)
now >= deadline → Failed        (unmet at the deadline; refunds open)
otherwise  → Funding            (locked, accepting deposits)
```

- **Deposits** (`deposit` / `depositFor`): any member, any amount, any number of times, strictly
  before the deadline. Overshoot is allowed — deposits stay open until the deadline even after the
  goal is met, and `release` pays goal + overshoot. The first deposit that makes
  `totalDeposited >= goalAmount` latches `goalReached` and emits `GoalReached` exactly once.
- **Invites** (`redeemInvite`): EIP-712 `StacksInvite`/`1` domain, `Invite(uint256 id,uint256
  nonce)` typehash — identical to `SavingCircles`, differing only by `verifyingContract`, so the
  app's invite flow ports unchanged. Nonces are per-goal. Joins share the same "open" predicate as
  deposits, so latecomers can still help overshoot.
- **Success with a beneficiary**: `release` is permissionless once Funded, forever (no time
  limit), and pays the whole pot to the pre-agreed beneficiary. Contributions are left untouched
  as historical receipts.
- **Success without a beneficiary** (commitment-savings mode): each member simply `withdraw`s
  exactly what they put in. The `goalReached` latch never clears, even if withdrawals drop the
  live pot below `goalAmount` — "the goal was achieved" is a historical fact, and re-locking
  would punish early withdrawers.
- **Failure or cancellation**: everyone `withdraw`s a full refund of exactly their own
  contributions. `cancel` is goal-owner-only, Funding-only, and moves no tokens — it only unlocks
  refunds earlier.

The deadline boundary is exclusive: at `block.timestamp == deadline` an unmet goal is already
Failed and deposits/joins revert.

## 2. Safety invariants

- **Solvency (per token, equality):** the contract's balance of `T` equals
  `Σ totalDeposited[id]` over goals using `T` (plus any unsolicited donations). Every increment of
  `totalDeposited` is matched by a `safeTransferFrom` pull in the same call; every decrement by a
  `safeTransfer` out. There is no other balance-touching path.
- **Per-goal ledger:** unless released, `totalDeposited[id] == Σ contributions[id][m]`. After
  release, `totalDeposited[id] == 0` and contributions persist as receipts (unreachable by
  `withdraw`, since Released is not refundable).
- **No honest member ever loses principal.** The only outflows are (a) `withdraw`, paying a
  member exactly their own recorded contributions, and (b) `release`, which requires the precise
  success condition every member accepted when depositing into a goal whose immutable config named
  that beneficiary. There is no debt, no default, no seizure: a member who stops depositing costs
  the others nothing but goal-success probability. Members risk only time-lock (worst case: funds
  locked until the deadline, then fully refundable).
- **Latch monotonicity:** `goalReached`, `cancelled`, `released` transition false→true only;
  Cancelled and Released are terminal; Failed is terminal because deposits close at the deadline.
- **No custody for anyone:** the goal owner can only sign invites and cancel (which never
  redirects funds); the registry admin only gates which tokens NEW goals may use (allowlist
  changes never affect existing goals, which store their token).

## 3. Decisions worth defending

- **`msg.sender` is the goal owner** (no `owner` parameter at create): the owner's only powers
  are invites and cancel; third-party appointment adds checks for zero product value.
- **Overshoot allowed** rather than clamping the crossing deposit: clamping needs a
  partial-refund branch or exact-remainder UX; overshoot is strictly simpler, strictly better for
  the beneficiary, and harmless in no-beneficiary mode.
- **`totalDeposited` is the live escrow** (decremented on withdraw, zeroed on release) with a
  separate one-way `goalReached` latch, instead of a cumulative counter — the solvency invariant
  becomes a single equality and the app's progress bar shows the actual pot.
- **Full-balance withdrawals only**: partial refunds add parameters and no value.
- **Re-entrancy**: all token-moving externals are `nonReentrant` and follow
  checks-effects-interactions; `release` sets `released` and zeroes the pot before transferring.
- **Weird tokens are out of scope**: the admin allowlist must exclude fee-on-transfer and
  rebasing tokens (documented on `setTokenAllowed`), matching repo policy.

## 4. Implementation scope (v1)

Implemented: invite-only membership, flexible deposits with the `GoalReached` latch, both success
modes (beneficiary release / commitment-savings withdrawal), failure refunds, owner cancellation,
and the full view surface — behind an OZ v5 `TransparentUpgradeableProxy`, with ~80 unit tests in
`test/unit/GoalSavingCirclesUnit.t.sol` covering every revert branch, state transition, and
boundary.

Deferred (documented extension points): open/permissionless-join goals; non-member donations that
waive refund rights; partial withdrawals; per-member caps or scheduled installments; yield on the
locked pot; member-quorum cancel or mutable config; a beneficiary claim expiry with
fallback-to-refund; and Chainlink automation to auto-release on Funded. The contract is standalone
and does not touch `SavingCircles`.
