# Saving Circles — Workable Issues

Repo: https://github.com/BreadchainCoop/saving-circles
Stack: Solidity / Foundry

Skipped: #112 (covered by PR #117), #71 (covered by PR #72)
Total workable: 13 (6 done, 6 autonomous tasks open, 1 blocked on autonomous tasks)

---

## Summary Checklist

- [x] #130 — Countdown starts before deposits are made
- [x] #122 — Fee-on-transfer ERC20s break accounting
- [x] #120 — Optimise gas usage in decommission path
- [x] #113 — Code duplication across contract logic
- [x] #129 — Upgrade safety guardrails
- [x] #126 — Deprecate the isWithdrawable API
- [ ] #77 — redeemInvite can be abused (implement address-bound approach)
- [ ] #124 — Optimisation spec (gas analysis + draft)
- [ ] #118 — Gelato automation spec (technical research portion)
- [ ] #96 — Decommission behaviour when deposits are missed (options doc)
- [ ] #65 — Policy for member who stops depositing v2 (research + options doc)
- [ ] #37 — Off-chain circle creation flow (architecture design)
- [!] #8 — Gelato automation v2 (BLOCKED: waiting on #118 + #37)

---

## BUGS

### - [x] #130 — Countdown starts before deposits are made

Already fixed by the two-step create → start pattern. The `create()` function
requires `effectiveCircleStartTime == 0`, and `start()` sets it to
`block.timestamp`. Countdown only begins when the owner explicitly calls
`start()`, after members have joined.

---

## ENHANCEMENTS

### - [x] #122 — Fee-on-transfer ERC20s break accounting

Fixed: `_deposit()` now uses a balance-before / balance-after pattern so only
the net amount actually received is credited. Added `MockFeeOnTransferERC20`
test mock and `test_DepositFeeOnTransferTokenCreditsNetAmount` test.

---

### - [x] #120 — Optimise gas usage in decommission path

Refactored `decommission()` to aggregate refunds per depositor across all
unclaimed rounds before executing transfers. This reduces external `safeTransfer`
calls from O(N²) worst case to at most N (one per member), saving ~20k gas per
eliminated call. Also removed unnecessary SSTORE zeroing of roundDeposits.

---

### - [x] #113 — Code duplication across contract logic

Extracted `_registerMember()` helper to deduplicate member registration
in `create()` and `redeemInvite()`. Extracted `_isPreviousRoundTimedOut()`
helper to deduplicate missed-deposit checks in `_deposit()`, `circleState()`,
and `_isDecommissionable()`. NatSpec added. All 141 tests pass.

---

### - [x] #129 — Upgrade safety guardrails

Added `uint256[50] private __gap` storage gap following OpenZeppelin convention.
This reserves 50 storage slots for future implementation versions to add state
variables without breaking deployed storage layout. Constructor already calls
`_disableInitializers()` and `initialize()` uses `initializer` modifier.
Note: Timelock/multi-sig enforcement and CI storage-layout checks are deployment
infrastructure concerns — recommend configuring `forge inspect --storage-layout`
diff checks in CI separately.

---

### - [x] #126 — Deprecate the isWithdrawable API

NatSpec `@deprecated` added to both ISavingCircles interface and SavingCircles
implementation (commit d380ec5). Migration note points to `isMemberWithdrawable()`
and `currentRoundWithdrawer()`. Function retained for backward compatibility;
removal planned for next breaking release. No internal callers depend on it —
only tests exercise it for regression coverage.

---

## DESIGN / RESEARCH

### - [ ] #77 — redeemInvite can be abused (implement address-bound approach)

The redeemInvite function uses EIP-712 typed signatures with single-use nonces,
preventing replay attacks. The remaining concern is that invites are not
address-bound — anyone who obtains a signed invite can claim it.

Decision taken: implement the address-bound approach as the secure default
(can be relaxed later if UX warrants it). The owner controls invite issuance;
address-binding adds defence-in-depth with no protocol downside.

Action: Update the Invite typehash to include the intended recipient address.
Update `redeemInvite` to verify `msg.sender` matches the bound address.
Add regression tests covering both valid redemption and rejection of wrong sender.
This is fully implementable autonomously — no external data or owner input required.

---

### - [ ] #124 — Optimisation spec (gas analysis + draft)

Before implementing gas or algorithmic optimisations across the
codebase, a written spec is needed to enumerate the targets, proposed
approaches, trade-offs, and acceptance criteria.

Action (autonomous): Run `forge test --gas-report` to capture baseline gas
figures. Identify hot paths in `_deposit()`, `circleState()`, and payout
logic. Produce a design document covering: (a) identified hot paths with
measured gas costs, (b) candidate optimisation techniques, (c) measurable
gas benchmarks before/after, (d) any correctness trade-offs. No external
input needed — all data derivable from the codebase and test suite.

---

### - [ ] #118 — Gelato automation spec (technical research portion)

Gelato Network can be used to automate recurring on-chain actions
(e.g. triggering payout rounds, advancing circle state). A spec is
needed before implementation begins.

Action (autonomous — technical research): Research Gelato Network v2 automate
API and resolver pattern. Write a spec covering: (a) which contract functions
should be automated, (b) trigger conditions and frequency, (c) Gelato task
configuration options, (d) fallback behaviour if automation fails, (e)
cost model for BREAD/ETH top-ups. Community/deployment decisions can be
annotated as open questions; the technical architecture is fully researchable.

---

### - [ ] #96 — Decommission behaviour when deposits are missed (options doc)

It is unclear what should happen when a circle is decommissioned while
one or more members have missed deposits. The current behaviour may
leave funds in an ambiguous state.

Action (autonomous): Analyse current decommission logic in full. Produce an
options document covering at least three policy approaches: (a) forgive missed
deposits (full refund to all), (b) penalise missed deposits (redistribute
missed amounts to active members), (c) pro-rate refunds by actual contribution.
For each option: describe the implementation change, gas impact, and fairness
trade-offs. No external input needed to produce this doc.

---

### - [ ] #65 — Policy for member who stops depositing v2 (research + options doc)

For the v2 roadmap, a clear policy is needed to handle members who
stop making deposits mid-circle (lapsed members): should they be
removed, penalised, replaced, or given a grace period?

Action (autonomous): Research approaches used by traditional saving circles
(tontines, ROSCAs) and existing on-chain implementations. Produce a policy
options document with at least four approaches (removal, penalty, replacement
slot, grace period) including trade-offs and implementation notes for each.
Feed the outcome into the v2 spec. All research is publicly available; no
community vote needed to write the options doc.

---

### - [ ] #37 — Off-chain circle creation flow (architecture design)

Creating a circle entirely on-chain is expensive and exposes sensitive
membership details. An off-chain (or meta-transaction) creation flow
could reduce costs and improve privacy.

Action (autonomous): Design an off-chain creation architecture covering:
(a) what data lives off-chain vs on-chain (membership list, circle params),
(b) how membership commitments are anchored on-chain (Merkle root, commit-reveal),
(c) trust assumptions and threat model, (d) integration with existing invite
mechanism and EIP-712 signing flow. Produce a written architecture doc.
No deployment or external accounts needed to design this.

---

### - [!] #8 — Gelato automation v2 (BLOCKED: waiting on #118 + #37)

A broader v2 initiative to deeply integrate Gelato for full circle
lifecycle automation (creation, deposits, payouts, decommission).

Blocked: Requires the #118 Gelato spec (technical research) and the #37
off-chain creation architecture to be completed first before this v2 scope
can be meaningfully expanded.

Action (after #118 + #37 complete): Expand on the #118 spec with a v2 scope:
consider subscriber-pays models, fallback manual triggers, gas tank management,
and how automation interacts with the off-chain circle creation flow from #37.

---

## SKIPPED

| Issue | Reason                          |
|-------|---------------------------------|
| #112  | Active PR #117 covers this work |
| #71   | Active PR #72 covers this work  |
