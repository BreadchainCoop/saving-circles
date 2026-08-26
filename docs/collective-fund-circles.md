# Collective Fund Circles — the Logos white-label communal fund

*A communal savings pot: deposit anytime, rage-quit anytime for your pro-rata slice, and spend the
pot together by one-member-one-vote proposals.*

This is the design rationale for `src/contracts/CollectiveFundCircles.sol` /
`src/interfaces/ICollectiveFundCircles.sol`. The definitive spec lives in
`.context/design/spec-collective.md`; this note summarizes the mechanism, the math, and the safety
argument.

---

## 0. What it is

A local community (a Logos cell, a neighborhood group, a co-op) saves into a shared pot and then
**spends the pot together** — a venue deposit, a food drive, a speaker's travel. Unlike a ROSCA
there are no rounds, no rotation, no automation and no credit: nobody ever owes anything.

The contract is a singleton registry: many funds per deployment, keyed by `uint256 id`. Each fund
stores its own on-chain `name`, so a white-label frontend resolves everything from `?f=<id>` with a
single `getFund(id)` call. Membership uses the exact `StacksInvite` EIP-712 invite flow of
`SavingCircles` (same domain, same typehash), so the existing app-stacks invite UX ports unchanged.
Funds are **perpetual** — no start, no decommission; "closing" a fund is everyone withdrawing.

## 1. The mechanism

- **create** (permissionless, allowlisted token): fixes `token`, `votingPeriod`
  (`0 < x <= 365 days`) and `approvalThresholdBps` (`0 < x <= 10_000`); the `fundOwner` auto-joins
  at member index 0. The fund owner's only powers are signing invites and renaming the fund.
- **redeemInvite**: joins with a fund-owner-signed EIP-712 invite, at any time in the fund's life.
  The member list is **append-only** — no removal in v1 (see §3).
- **deposit** (member-only): mints shares **1:1** with tokens contributed. Shares are a ledger of
  contribution, not vault shares ("solidarity accounting", §2).
- **donate** (anyone): raises the pool without minting shares — gifts to the collective.
- **withdraw** (rage-quit, anytime): burns shares for
  `floor(shares * poolBalance / totalShares)`. Never blocked by any proposal state.
- **propose** (member-only): snapshots `electorate = memberCount` and
  `requiredYes = ceil(electorate * thresholdBps / 10_000)`; the proposer auto-votes yes. The amount
  is neither checked against nor reserved from the pool.
- **vote**: one member one vote, eligible iff `memberIndex < electorate` (the snapshot), open while
  `now <= createdAt + votingPeriod` and unexecuted.
- **execute** (anyone): as soon as `yesVotes >= requiredYes` and until
  `createdAt + 2 * votingPeriod` (a self-scaling grace of one extra voting period), provided
  `poolBalance >= amount` *at execute time*.

Proposal state is a pure function of storage + time: `Executed`, else `Passed`/`Expired` once the
threshold is reached (inside/outside the execution window), else `Defeated` after the vote deadline
or once `electorate - noVotes < requiredYes` (mathematically unreachable), else `Active`.

## 2. The math, and why it rounds the way it does

- **Mint: exact 1:1, always.** After a disbursement (`poolBalance < totalShares`) a *new* deposit
  still mints 1:1, so a late depositor shares the past dilution equally per contributed token. This
  is deliberate: everyone who ever contributed X tokens can redeem the same fraction of X,
  regardless of timing. Frontends must show `previewWithdraw` next to the deposit box.
- **Withdraw: floor, in favor of the pool.** Rounding dust stays in the pool and accrues to the
  remaining shareholders; the pool can never be over-drawn. When the last exiter burns
  `shares == totalShares`, the payout is exactly `poolBalance` — nothing is stranded. Burning
  zero-value shares when the pool is empty is allowed (share-base reset for future deposits).
- **Threshold: ceiling, in favor of stricter approval.** "At least thresholdBps of the electorate"
  cannot be satisfied by fewer heads via flooring; `requiredYes >= 1` always, so no proposal ever
  passes with zero voices. A single-member fund passes its own proposals at creation (intended:
  personal pot / demo mode).
- **Snapshot in O(1).** Because the member list is append-only, "was a member at proposal
  creation" is exactly `memberIndex < proposal.electorate` — one comparison, no per-proposal
  eligibility map.

## 3. Safety invariants and decisions

- **I1 share conservation**: `Σ sharesOf == totalShares` per fund (mint in deposit, burn in
  withdraw — no other mutation, no transfer).
- **I2 pool conservation**: `poolBalance == deposits + donations − withdrawals − executed amounts`.
- **I3 singleton solvency**: per token, contract balance `>= Σ poolBalance` across funds — every
  outflow is debited from exactly one fund and bounded by its pool, so **no fund can spend another
  fund's tokens**. Direct ERC20 transfers to the contract are not credited and never make a fund
  insolvent.
- **I4 single execution**: `executed` flips before the transfer; `execute` is `nonReentrant`.
- **No reservation, by decision.** A passed proposal does not lock funds: rage-quit freedom is the
  trust anchor, and a member's deposit is never hostage to a vote they lost. If exits drain the
  pool below a passed amount, `execute` reverts (`InsufficientPoolBalance`) and the proposal stays
  `Passed` inside its window — a top-up re-enables it. Reserving would instead let a hostile
  majority freeze dissenters' exits.
- **No member removal in v1.** Removal would break the O(1) snapshot; economic exit = withdraw all
  shares (the vote persists — a curation decision of the fund owner, who controls invites). Listed
  as the first extension (tombstoned slots).
- **No defaulter exists.** Nobody owes anything, so no honest member can lose principal to a
  defaulter — structurally. Redeemable value decreases only via (a) a disbursement the community
  approved at threshold (the product; the defense is voting no and/or rage-quitting first, which
  nothing can block) or (b) one's own choice to deposit into an already-diluted pool.
- **Reentrancy / CEI**: all token-moving externals (`deposit`, `donate`, `withdraw`, `execute`,
  `redeemInvite`) are `nonReentrant` and write state before transferring; weird tokens
  (fee-on-transfer, rebasing) are excluded by the admin allowlist.

## 4. Scope (v1) and extensions

Implemented: the full deposit/donate/withdraw ledger, EIP-712 invites, snapshot voting, early
execution, execution expiry, white-label naming, and the one-call frontend views
(`getFund(s)`, `getProposals`, `proposalState`, `isExecutable`, `previewWithdraw`,
`checkMemberships`). 100 unit tests in `test/unit/CollectiveFundCirclesUnit.t.sol`.

Deferred (documented extension points): member removal via tombstones, ERC-4626-style
parity-preserving mint, earmarked (spend-only) donations, vote-by-signature, per-fund
`metadataURI`/ERC-7572, multi-recipient or cancellable proposals, and a decommission/sunset mode.
The contract is standalone and does not touch `SavingCircles`.
