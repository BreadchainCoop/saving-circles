# Accumulating Saving Circles (ASCA)

*The "loose" cousin of the ROSCA: flexible savings, a self-collateralized credit line, and
interest that flows back to the savers — the group banks itself.*

This document is the design rationale for `src/contracts/AccumulatingSavingCircles.sol`. The
definitive spec (storage layout, exact math, full test plan) lives in the design notes; the
interface `src/interfaces/IAccumulatingSavingCircles.sol` is the API reference.

---

## 0. What problem it solves

A `SavingCircles` ROSCA forces a fixed deposit on a fixed schedule and pays each member the pot
exactly once. Many real groups (village associations, co-ops, friend circles) want the *other*
classic mutual-finance shape instead — the **ASCA** (Accumulating Savings and Credit Association):
each member puts in **whatever amount they want, whenever they want**, and in exchange earns a
**credit line equal to a percentage of their own savings**. Loans are repaid within a configured
number of periods, optionally with simple interest set by the group, and **all interest flows back
pro-rata to the savers** rather than to a bank.

## 1. The mechanism

- **Singleton registry.** One contract hosts many funds, keyed by `uint256 id`, exactly like
  `SavingCircles`. The organizer calls `create(token, borrowLimitBps, interestRateBps,
  repaymentPeriods, periodLength)`, becomes the fund owner and its first member, and invites
  members with the same EIP-712 `StacksInvite` flow the app already ships (domain
  `'StacksInvite'/'1'`, typehash `Invite(uint256 id,uint256 nonce)`; only the verifying-contract
  address differs).
- **Savings.** `deposit`/`depositFor` add any positive amount to `savings[id][member]`; `withdraw`
  returns it, subject to the collateral and liquidity guards below. Savings double as
  MasterChef-style accumulator shares.
- **Credit.** `borrow(id, amount)` requires `amount * 10_000 <= borrowLimitBps * savings` (the
  multiplicative form leaves no rounding loophole) and enough `poolCash`. One loan at a time:
  a second `borrow` reverts with `OutstandingLoan` until the first is fully repaid or liquidated.
- **Interest.** Simple interest accrues lazily per **whole elapsed period** on outstanding
  principal (`principal * interestRateBps / 10_000` per period), checkpointed at every touch, and
  **capped at `repaymentPeriods` periods** — accrual stops at the due date, so the borrower's
  liability is known at borrow time and can never outgrow deterministic bounds.
- **Repay waterfall.** `repay` settles accrued interest first, then principal, pulls at most the
  total debt (overpayment is not taken), and immediately streams the interest received to savers
  via `accInterestPerShare += interest * 1e18 / totalSavings` (floor; sub-wei dust stays in the
  pool). Members collect with `claimInterest`.
- **Liquidation.** Once `block.timestamp >= startTime + repaymentPeriods * periodLength`, anyone
  may call `liquidate`: it seizes the borrower's savings for the full principal (always covered),
  plus `min(interestOwed, remaining savings)` which is distributed to savers as interest. It is a
  **pure ledger reallocation** — no tokens move.
- **Wind-down.** The organizer's one-way `deactivate` freezes `deposit`/`depositFor`/`borrow`/
  `redeemInvite` while leaving `withdraw`/`repay`/`claimInterest`/`liquidate` open, so a
  deactivated fund drains naturally. There is no share-out event; membership is continuous.

## 2. Safety invariants

Let, per fund: `S = totalSavings`, `B = totalBorrowed`, `C = poolCash`, `P = Σ pendingInterestOf`.

- **I1 — internal cash ledger.** All logic reads `poolCash`, never `token.balanceOf`, so donations
  and other funds sharing the contract cannot corrupt accounting. Every outbound transfer is
  guarded by `poolCash >= amount`.
- **I2 — full self-collateralization.** `borrowLimitBps <= 10_000` implies `principal <= savings`
  for every open loan. Established at `borrow`, preserved by the `withdraw` guard
  (`(principal + accrued interest) * 10_000 <= borrowLimitBps * remaining savings` — accrued
  interest counts as debt), and cleared by `liquidate`. Liquidation can therefore always seize the
  full principal: **a defaulter can only ever burn their own savings, never another member's
  principal.**
- **I3 — solvency.** `C + B >= S + P` holds inductively across every operation (distribution and
  settlement round down, so rounding always favors the pool). Combined with I2, every receivable
  in `B` is backed by seizable savings, so all liabilities are eventually payable and the
  liquidity guards are belt-and-suspenders: honest members can always exit within at most
  `repaymentPeriods * periodLength` via permissionless liquidation.
- **I4 — value flow.** Tokens enter only via `deposit`/`depositFor`/`repay` and leave only via
  `withdraw`/`borrow`/`claimInterest`. `liquidate` and `deactivate` move no tokens. Every
  token-moving external is `nonReentrant` and strictly checks-effects-interactions.
- **Who can lose what.** A defaulting borrower loses their own savings up to
  `principal + interestOwed`. Honest savers can lose only *expected future interest* (never
  credited, never principal) when a defaulter's remaining savings do not cover accrued interest.

## 3. Decisions

- **One loan at a time.** No due-date merges, no per-tranche interest; "loose amounts" is
  preserved because the member sizes the single borrow freely. Top-ups are a v2 extension.
- **Interest capped at the due date.** Bounds liability, makes seizure deterministic, and avoids
  unbounded interest outgrowing collateral; overdue enforcement is permissionless `liquidate`,
  not compounding.
- **Borrower's savings stay shares while borrowed.** No freezing bookkeeping; the borrower earning
  a pro-rata slice of interest (including of their own payments) is standard pool behavior.
- **Sole-saver liquidation skips interest seizure.** If seizing interest would leave zero shares,
  there is nobody to distribute it to; burning value to nobody is worse than leaving it as the
  defaulter's savings. Principal is always seized.
- **`repay` pulls only `min(amount, debt)`.** Friendlier than reverting; no refund path needed.
- **Admin ERC20 allowlist as the token control.** Fee-on-transfer, rebasing and ERC777-style
  tokens are out of scope by policy, exactly the `SavingCircles` pattern.

## 4. Scope (v1) and extensions

Implemented: multi-fund registry, EIP-712 invites, flexible savings, pro-rata interest
accumulator, single self-collateralized loans, permissionless liquidation, organizer deactivation
— with branch-complete unit tests in `test/unit/AccumulatingSavingCirclesUnit.t.sol`.

Deferred (documented extension points): loan top-ups / `repayFor`, a Chainlink-automation
satellite calling `liquidate` on overdue loans, viewer-lens getters, reserving expected interest
inside the credit line, late fees / grace periods, member removal, protocol fees, and dedicated
fuzz + invariant suites. The contract is standalone and does not touch `SavingCircles`.
