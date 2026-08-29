# Circle Failure Handling

Status: draft — open questions in §8 must be closed before implementation.

## 1. Motivation

Today a missed deposit has exactly one outcome: any single member calls `decommission`
([`SavingCircles.sol`](../src/contracts/SavingCircles.sol)), the circle dies permanently, and the
contract pushes every unclaimed round's deposits back to the members in an `O(n²)` loop.

Three problems with that:

- **It does not scale, and BREAD makes it worse.** Up to `members × rounds` individual transfers
  in one transaction. BREAD is `ERC20VotesUpgradeable` and overrides `transfer`/`transferFrom` to
  auto-delegate:

  ```solidity
  function transfer(address recipient, uint256 amount) public override returns (bool) {
      super.transfer(recipient, amount);
      if (this.delegates(recipient) == address(0)) _delegate(recipient, recipient);
      return true;
  }
  ```

  So every transfer pays for voting-checkpoint writes on both sides, plus an external self-call to
  `this.delegates(recipient)`, plus a full `_delegate` the first time an address receives BREAD —
  several times the cost of a vanilla ERC20 transfer. The ceiling on how large a circle can be
  wound down is correspondingly lower. Needs a gas benchmark (§9) rather than an estimate.
- **One member pays for everyone.** Whoever calls `decommission` funds the entire refund
  distribution out of their own pocket. Pull-based settlement makes each member pay for their own
  exit. This holds regardless of any gas limit.
- **It does not make anyone whole.** Deposits that already funded a paid-out pot are gone. In a
  3-member circle where A and B claim and A then stops paying, C is down two full deposits and
  gets back only their partial round-2 deposit. A walks away net positive.

### Token assumptions

The only allowlisted token today is [BREAD on Gnosis](../script/Registry.sol) (`0xa555…5Ee3`),
which is `ERC20VotesUpgradeable, OwnableUpgradeable, IBread` — no blacklist, no pause, no transfer
hooks, no transfer restrictions. So the usual argument for pull payments — a recipient that can
permanently revert a push and brick the loop for everyone — **does not apply to the current
deployment**, and is not the justification for phase 1. The justification is gas and cost fairness.

It is still worth building pull-first as defense in depth: `allowedTokens`/`setTokenAllowed` exists
so the owner can add tokens, [`Registry.sol`](../script/Registry.sol) already lists `OPTIMISM_DAI`
and `GNOSIS_XDAI` alongside BREAD, and this is an upgradeable long-lived contract. If a token with
transfer restrictions is ever allowlisted, push-based refunds become a real hazard for every circle
created afterwards. Treat that as a hedge, not a present-day risk.

This spec replaces the single terminal action with a graded response — **pause → cure → eject →
halt** — backed by collateral, so the loss falls on the defaulter rather than on whoever had not
been paid yet. All value transfers become pull-based.

**Non-goals:** changing the rotation model, changing who claims when, recovering funds from
already paid-out pots.

## 2. Lifecycle

```
NotStarted ──start──> Active ──────────────────────> Completed (all claimed)
                        │  ▲
           flagDefault  │  │  resume (owner; stalled round whole)
          (permissionless) │
                        ▼  │
                      Paused ──── cure (permissionless, pays shortfall)
                        │
                        ├── endGrace (owner) ──> ejectDefaulter (permissionless)
                        │                             └──> resume (owner)
                        │
                        └── halt (any member, always available) ──> Halted (terminal)
```

**The pause is the grace window.** There is no grace timer. The circle owner decides when the
grace ends, by either resuming the circle or declaring the grace over and unlocking ejection.

**Power split.** The owner controls *continuation*; members retain unilateral *exit*. `halt` is
callable by any member for as long as the circle is paused, which is what makes owner-controlled
grace safe — an absent or self-interested owner can stall the circle, but can never trap the
funds. This is no weaker than today, where any single member can `decommission` unilaterally.

While paused: `deposit`, `depositFor`, `withdraw`, and `withdrawFor` all revert. Only `cure`,
`eject`, `halt`, and the owner's `resume`/`endGrace` are callable. The round clock is frozen.

## 3. Storage

All new state is appended after `isDecommissioned` — this is a transparent-proxy contract and the
layout is append-only. New `CircleState` enum values are appended after `MissedDeposit`;
`Decommissioned` keeps ordinal 5.

```solidity
// clock
mapping(uint256 id => uint256 timestamp) public pausedAt;      // 0 = running
mapping(uint256 id => uint256 duration)  public pausedTotal;   // cumulative frozen time
mapping(uint256 id => uint256 round)     public stalledRound;  // round that was incomplete
mapping(uint256 id => bool)              public graceEnded;    // owner unlocked ejection
mapping(uint256 id => bool)              public isHalted;

// collateral
mapping(uint256 id => uint256 amount) public bondAmount;                       // per circle
mapping(uint256 id => mapping(address member => uint256 amount)) public bonds;
mapping(uint256 id => uint256 amount) public forfeitedPool;

// membership
mapping(uint256 id => mapping(address member => bool)) public isEjected;
mapping(uint256 id => uint256 count) public activeMemberCount;

// settlement
mapping(uint256 id => mapping(address member => bool)) public hasSettled;
mapping(uint256 id => mapping(uint256 round => uint256 total)) public roundTotal;
```

Deliberately **not** adding fields to the `Circle` struct — it is returned by `getCircle` and
consumed by [`AutomaticSavingCircles`](../src/contracts/AutomaticSavingCircles.sol). Keeping that
ABI stable is worth a few extra mappings.

`isDecommissioned[id]` continues to return `true` when a circle is halted, so existing indexers
and `CircleState.Decommissioned` keep resolving.

## 4. Payout accounting

The current pot formula is `depositAmount * circleMembers.length`. That assumption breaks the
moment a member is ejected or a bond backfills a shortfall.

**New rule: the pot for round `r` is exactly what round `r` collected** — `roundTotal[id][r]`,
maintained on every write to `roundDeposits`. Self-consistent under ejection, backfill, and
partial deposits, and it removes the member-count assumption entirely.

`_allMembersDepositedForRound` becomes "every **non-ejected** member has deposited in full for
round `r`".

## 5. Phases

The order is load-bearing. Each of phases 1–3 is independently shippable and useful on its own;
phase 4 is optional and can be dropped without stranding the others.

### Phase 1 — Pull settlement

Independent of everything else, and it removes the gas ceiling and the cost-fairness problem on
its own. Ships alone.

```solidity
function halt(uint256 id) external;                       // O(1), any member
function settle(uint256 id) external;                     // pull, one transfer
function settleFor(uint256 id, address member) external;
function settlementOf(uint256 id, address member) external view returns (uint256);
```

`settlementOf` = the member's deposits across every round whose recipient has not claimed, plus
their bond if not forfeited, plus their share of `forfeitedPool`. Zeroed and flagged via
`hasSettled` on withdrawal.

Haltable condition initially stays the existing `_isDecommissionable`; phase 2 replaces it.

`decommission()` becomes a deprecated alias for `halt()`. **This is a behavior change** — funds no
longer arrive automatically, each member pulls. Nothing in `app/` calls it today.

### Phase 2 — Pause / resume

```solidity
function currentRound(uint256 id) public view returns (uint256);
function roundEndTime(uint256 id, uint256 round) public view returns (uint256);

function flagDefault(uint256 id) external;                  // permissionless -> Paused
function cure(uint256 id, address member, uint256 value) external;  // pays into stalledRound
function resume(uint256 id) external;                       // owner; requires stalled round whole
function endGrace(uint256 id) external;                     // owner; unlocks ejection
```

The round clock stops being a pure function of `block.timestamp`:

```
elapsed = now - effectiveCircleStartTime - pausedTotal - (pausedAt > 0 ? now - pausedAt : 0)
```

`resume` sets `pausedTotal += now - pausedAt`, clears `pausedAt`, `stalledRound`, and
`graceEnded`. The circle picks up exactly where it left off.

Two consequences, both load-bearing:

- **`AutomaticSavingCircles` must stop duplicating the clock.** Its private `_currentRoundIndex`
  and `_roundEndTime` are deleted in favour of the new views. Two copies of a pause-aware clock
  will drift.
- **Pausing needs a transaction.** State cannot change on its own, so the pause begins at
  `flagDefault`, not at the round boundary. This is the better semantics — the grace clock starts
  when someone actually notices — and `flagDefault` becomes a natural third Chainlink upkeep
  target alongside deposits and claims.

`cure` writes into `roundDeposits[id][stalledRound[id]][member]`, so the internal deposit path
needs an explicit round parameter rather than deriving the round from the clock.

### Phase 3 — Collateral

```solidity
function postBond(uint256 id) external;   // before start; start() requires all members bonded
function bondOf(uint256 id, address member) external view returns (uint256);
```

The risk a member imposes on the circle is `depositAmount × (obligations remaining after their own
payout)` — maximal at index 0, zero for the last member. Sizing is left open (§8.1).

Bonds are tracked separately from `balances` and `roundDeposits` so the pot math is untouched. A
bond is returned in full on normal completion or on halt, and forfeited on ejection.

### Phase 4 — Ejection

Riskiest phase; consumes all three above.

```solidity
function ejectDefaulter(uint256 id, address member) external;  // permissionless once graceEnded
```

**Do not compact `circleMembers`.** `memberIndex` *is* the payout round; compaction reshuffles who
gets paid when for every member downstream. Instead, mark the slot ejected and leave all indices
in place. The ejected member's own round becomes a skipped round — no claimant,
`currentRoundWithdrawer` returns `address(0)` — and the circle runs to the same `circleEnd`.

**The seized bond backfills first.** It covers the defaulter's missing deposit for the stalled
round, writing into `roundDeposits` so the round completes and that pot stays whole. Only the
remainder goes to `forfeitedPool` for pro-rata distribution among non-ejected members who have not
yet claimed. Without this, ejection silently shrinks the next recipient's payout.

Other required changes:

- `activeMemberCount--`; if it would drop below `MINIMUM_MEMBERS`, the circle auto-halts instead.
- The ejected member keeps `isMember` (history) but is gated everywhere by `isEjected`. They may
  `settle` for unclaimed-round deposits only — never for deposits already consumed by a paid pot,
  and never for their forfeited bond.
- Once every stalled-round shortfall is resolved by cure or ejection, the owner calls `resume`.

## 6. Invariants

- Per circle: `token balance ≥ Σ unclaimed roundTotal + Σ live bonds + forfeitedPool`.
- `currentRound(id)` is monotonic non-decreasing; `pausedTotal` never decreases.
- Ejection never changes any non-ejected member's `memberIndex` or payout round.
- `Halted` is absorbing — no path leaves it.
- `hasClaimed` and `hasSettled` each pay at most once; no member is ever paid both a pot and a
  refund for the same round.
- A paused circle accepts no deposits and no claims.
- `activeMemberCount ≥ MINIMUM_MEMBERS` for any circle that is not halted.

## 7. Decided

- **Ejection authority** — permissionless, once the owner has ended the grace. Given that the
  grace window is owner-controlled and unbounded in length, requiring a vote on top would give a
  passive membership another way to stall.
- **Grace length** — no timer. The owner ends it, by resuming or by calling `endGrace`. Members'
  protection against an absent owner is `halt`, not a clock.

## 8. Open questions

1. **Bond tier.** Flat `depositAmount` (covers exactly one missed round, cheap) versus
   position-scaled `depositAmount × (n − 1 − memberIndex)` (full collateralization, closes the
   "claim early then default" hole entirely, expensive in locked capital). Fixed at `start`, when
   the member set freezes.
2. **Repeat defaults.** After a cure, does anything change for that member — a second default with
   no bond left to seize, a shortened grace, automatic ejection?
3. **Bond top-up.** If a bond is consumed by backfill, the member is uncollateralized for the rest
   of the circle. Must they re-bond as a condition of `resume`? Closely tied to (2).
4. **Absent-owner backstop.** `halt` is the escape hatch, but it is terminal. Is there a hard cap
   on pause duration after which `endGrace` becomes permissionless, so a stalled circle can
   continue rather than only die?
5. **Halt authority during a pause.** Any single member (current behaviour, simplest) or a quorum?
   A quorum protects the circle from one impatient member but weakens the absent-owner backstop.
6. **Owner succession.** If the circle owner is the one ejected, the circle has no one to resume
   it. Recommended: ownership passes to the lowest-index non-ejected member — auto-halting instead
   would mean an owner's default kills the circle, which is exactly what ejection exists to
   prevent. Needs confirmation.

## 9. Test surface

Beyond unit coverage of each new function:

- **Gas benchmark against real BREAD, not a mock.** `MockERC20` will badly understate the cost of a
  transfer: it has no voting checkpoints and no auto-delegation. Fork Gnosis, measure the current
  `decommission` and the new per-member `settle` at 5/10/15/20 members, and record the largest
  circle the old path can actually wind down. This number is the concrete case for phase 1.
- Settlement conservation: sum of all settlements equals the contract's circle balance, across
  fuzzed deposit/claim/eject sequences.
- Settlement with a mock token whose `transfer` reverts for one recipient — every other member must
  still settle. Defense-in-depth against a future allowlisted token; not a property of BREAD.
- Clock monotonicity across repeated pause/resume cycles; round indices must match between
  `SavingCircles` and `AutomaticSavingCircles` at every step.
- Ejection preserves the payout order and timing of every remaining member.
- Bond backfill keeps the stalled round's pot whole.
- Ejection cascade down to `MINIMUM_MEMBERS` triggers auto-halt rather than an invalid circle.
