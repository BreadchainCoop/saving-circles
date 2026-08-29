# Variant D — The Foremanless Chit

*A permissionless, capital-efficient reverse-auction saving circle. On-chain compilation of the
Indian chit fund (Chit Funds Act, 1982), extending F. Badaloni's* Saving Circles — Specification.

This document is the design rationale for `src/contracts/ChitSavingCircles.sol`. It is the fourth
of four collateralized permissionless ROSCA designs; the full comparative spec (Variants A–D, with
the Deckstacking / Bartoletti–Zunino contract-semantics model and all proofs) lives in
[breadchainCoop/saving-circles #182](https://github.com/BreadchainCoop/saving-circles/pull/182).
Variant A (collateral-first) is implemented there; **Variant D, implemented here, supersedes the
rolling-bond Variant B** at roughly a quarter of the locked capital.

---

## 0. What problem it solves

A plain ROSCA is secretly a loan: an early recipient takes the pot and is *trusted* to keep
depositing. The baseline `SavingCircles` can only guarantee an honest saver recovers `(n − t)·m`
against an adversary controlling `t` savers — the residual `t·m` is unsecured credit — which is
why it must gate entry with owner-signed invites and freeze the cohort.

The collateral variants (A, B) drive `t → 0` by making every member post security for their
worst case, so nobody can be hurt and the door can open to anyone. But they over-pay: they
collateralize **every** member for a **whole pot**, at all times.

The chit fund shows this is ~4× too much. **Only a member who has already won can steal**, and only
for what she still owes. So collateral should be demanded *at prize time* and *only for the exact
residual*. Variant D does that, and — by allocating the pot with a reverse auction — it also pays
patient members an endogenous interest rate that a fixed-rotation circle forces to zero.

## 1. The mechanism

A circle runs a single cycle of `n = numSlots` rounds. Every member deposits `m` every round.
Exactly one member is *prized* (wins the pot) per round, so after `n` rounds everyone has won once.

Each round `j` (0-indexed) has two phases inside its window:

1. **Commit** (first part of the round): members `deposit(m)` and submit a sealed bid
   `commitBid(H(discount, salt))`.
2. **Reveal** (last `revealDuration` of the round): members `revealBid(discount, salt)`.

After the round closes anyone calls `award()`, which settles rounds **strictly in order**.

**Why sealed bids.** An open-outcry on-chain auction hands the block scheduler a last-look: censor
rivals for a few blocks, then snipe with `d + ε`. That is auction MEV. The commit/reveal split (with
the reveal phase carved out of the round) makes the auction robust to an adversarial scheduler in the
Deckstacking sense — honest commitments and reveals are guaranteed inclusion, and `award` is a
deterministic function of the revealed set. **No-bid rounds fall back to fixed rotation** (`d = 0`,
lowest free slot), so a rotation ROSCA is D's degenerate case; the allocation rule is a parameter,
not a commitment.

### 1.1 Prize-time two-tier security — the safety core ("Theorem D3")

At `award`, the winner of round `j` still owes her remaining `residual = (n − 1 − j)·m` of deposits.
Her winning bid `d` is **withheld as first-loss security** instead of being paid out, and she locks
the rest in cash:

```
withheld = d            coll = (n − 1 − j)·m − d            withheld + coll = residual
```

The immediate cash she receives is `(j + 1)·m` (`= n·m − d − coll`), funded entirely from the pot —
**she posts no new capital**. A bigger bid means a smaller cash lock; you can never bid away more
than you owe (`d ≤ residual`, replacing the Act's ad-hoc 30–40 % cap with a structural one).

The invariant

> **`withheld(x) + coll(x) == residual(x)`** for every prized `x`

holds at award (with equality) and is preserved by every subsequent rule — both sides fall by exactly
`m` per settled deposit. Therefore every future pot can be made whole against **any** set of prized
defaulters, and **no honest member ever loses principal**. A would-be thief who bids high merely
pre-pays her own first-loss cover: her realizable theft is `0` whatever she bids. (The unit test
`test_PrizedDefault_TheftIsZero_HonestMembersWhole` bids the maximum and then defaults on every
remaining deposit; every recipient is still paid in full and the defaulter nets zero.)

### 1.2 Dividends = endogenous interest ("D6")

As a prized member makes each on-time deposit, a slice `withheld / (rounds remaining)` of her withheld
bid is released **pro-rata to the other members** (a credit they can `claim`), and the matching slice
of her cash lock is returned to her. Over her residual period an honest winner pays out exactly her
bid `d` — her interest — and recovers her whole cash lock. Patient members who win late with low bids
are net **receivers** of interest; impatient early winners pay it. The interest market is zero-sum
(`test_Auction_BidBecomesDividendInterest`: a member who bids `2m` ends `−2m`; the two others end
`+m` each).

### 1.3 Capital ("D4")

Aggregate security held at the close of round `j` equals the outstanding-credit parabola
`K(j) = (j + 1)(n − 1 − j)·m` plus the `n·m` of one-round bonds — within `n·m` of the
information-theoretic floor, versus Variant B's `≈ 4×` it at peak.

## 2. Non-prized default and churn

A member who has **not** won owes nothing she has not already lent; her default is a coordination
event, not a credit event. She posts a one-round **membership bond** of `m` at `join`. A missed
deposit is covered from that bond and she is flagged defaulted, freeing her slot for permissionless
`substitute` — a successor posts a fresh bond and assumes the slot, its future deposit schedule, and
its prize eligibility (the Act's §§28–30). The defaulter forfeits her bond; no other member is
affected, and the pot stays `n·m` (no resize).
`test_Substitution_DefaultedSlotTakenOver_CircleCompletes` covers this.

If a defaulted slot is **never** substituted, the circle can no longer complete a round. Anyone may
then `abort`, which unwinds every member to **net-zero on principal**:
`refund = deposits + bondsPosted − amountsWithdrawn` (≥ 0), clawing back unrealized prizes. Because
every prized member's remaining obligation is fully secured (`withheld + coll == residual`), this
exactly drains the circle's funds and **no honest member loses principal** — the worst case for an
honest member is that a mid-cycle default forces an early, whole unwind
(`test_Abort_StalledCircle_UnwindsEveryoneToNetZero`).

## 3. Two honest limits (from the spec)

- **Do not combine the auction with under-collateralization (Variant C).** A member who plans to
  default is discount-insensitive; with thin collateral the auction routes pots to the worst risks
  first (adverse selection) and drains the insurance buffer. The safe compositions are exactly
  *auction + full prize-time security* (this contract) and *no-auction + under-collateral + slot
  restriction + buffer* (Variant C). The combination is excluded.
- **The trilemma (Prop. 5.4).** No design gives all three of (i) unconditional safety, (ii)
  membership open to fresh anonymous keys, and (iii) positive net credit *in the circle's own asset*.
  Same-asset Variant D chooses (i) and (ii), so net credit is `≤ 0`: it is a **commitment-savings +
  mutual-insurance + interest-market** device, not a lender. Real credit content requires the
  prize-time security to be *something other than same-asset cash* — heterogeneous collateral or an
  on-chain surety (the Act's salaried co-signer, compiled) — which the design admits as a documented
  extension point.

## 4. Implementation scope (v1)

Implemented: the sealed-bid auction, prize-time two-tier security, dividends, prized-default cover,
no-bid rotation fallback, defaulted-slot substitution, and the net-zero abort valve — on a cohort
fixed at `start`, with permissionless create / join / start (no owner, no invite). See the 16 unit
tests in `test/unit/ChitSavingCirclesUnit.t.sol`.

Deferred (documented extension points): continuous mid-cycle resize; voluntary (non-default)
substitution with claim transfer; a Vickrey price rule (winner pays the second-highest discount) for
truthful bidding in the price dimension; and heterogeneous / surety collateral for genuine credit.
The contract is standalone and does not touch `SavingCircles` / `AutomaticSavingCircles`.

---

### References

- M. Bartoletti, R. Zunino. *A Theoretical Basis for MEV.* FC 2025. (Deckstacking; sealed-bid rationale.)
- F. Badaloni. *Saving Circles — Specification.* 2026. (Baseline extended here.)
- Besley, Coate, Loury. *The Economics of Rotating Savings and Credit Associations.* AER 1993.
- Kovsted, Lyk-Jensen. *ROSCAs: random vs. bidding allocation.* J. Dev. Econ. 1999.
- *The Chit Funds Act, 1982* (Act No. 40 of 1982, India). §§28–30 substitution; discount and
  commission caps; prized-subscriber security before draw.
