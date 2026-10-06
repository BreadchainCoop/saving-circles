# Microloans

*Step-up microloans: a lender offers a zero-interest loan to one borrower and escrows a grant that
unlocks once the loan is repaid. For example, Bread lends a community center 1,000 USDT for
computers, and once the center pays that back, another 1,000 USDT is released to it for free.*

This is the design rationale for `src/contracts/Microloans.sol`.

---

## 0. What problem it solves

The other stack types are built for groups that save together. Some partners need something
different: one organization receiving money up front and paying it back over time, with an
incentive to finish. Microfinance calls this progressive lending, where repaying one loan earns
access to the next. Here the next step is a grant rather than a bigger loan, so the lender absorbs
the grant as the cost of the program, but only once the borrower has shown it can repay.

## 1. The mechanism

A loan has immutable terms fixed at `create`: `(token, vault, principal, grant, acceptBy,
repaymentPeriod, termsHash)`. The caller becomes the lender and pays `principal + grant` into
escrow in the same transaction, so the borrower can verify on-chain that both the loan and the
reward are real before agreeing to anything.

State is derived, never stored:

```
cancelled                       → Cancelled   (terminal)
not accepted, now < acceptBy    → Offered
not accepted, now >= acceptBy   → Expired     (lender can cancel for a refund)
grant reclaimed                 → Defaulted   (terminal for the grant)
repaid >= disbursed             → Repaid      (grant waiting) or Completed (grant paid, or no grant)
now < repayBy                   → Active
otherwise                       → Overdue
```

- **Borrower.** Named at `create`, or left empty and set once with `setBorrower`. This matches the
  app flow where someone asks to join off-chain and the lender adds them. Only the borrower can
  accept.
- **Acceptance.** `accept(id, termsHash)` must pass the hash of the off-chain agreement (for example
  an IPFS document with the conditions in plain language). This records on-chain exactly which
  terms the borrower agreed to. The principal is paid out immediately and the clock starts:
  `repayBy = acceptedAt + repaymentPeriod`.
- **Repayment.** `repay` accepts any amount at any time, from the borrower or anyone paying on their
  behalf. Overpayment is capped, so only what is owed is pulled. Repayments are credited to the
  lender and paid out with `collect`, which anyone can trigger.
- **Grant unlock.** Once cumulative repayments reach the disbursed principal, `releaseGrant` pays
  the grant to the borrower. It is permissionless, so the app or an automation can trigger it,
  but the grant can only ever go to the borrower.
- **Late payment.** After `repayBy` the loan is Overdue. The borrower can still repay and claim the
  grant until the lender acts. The lender can either `extendRepayBy` to give more time or
  `reclaimGrant` to take the grant back. The principal remains owed after a reclaim and can still
  be repaid, but the grant is gone.
- **Cancellation.** Before acceptance the lender can `cancel` and get everything back, including
  yield.

## 2. Yield on escrow

Money waits in escrow twice: the principal between offer and acceptance, and the grant for the
whole repayment period. Each loan can name an ERC-4626 vault from an admin allowlist, and escrow is
deposited there instead of sitting idle. On Celo the natural choice is Aave v3, which supports
USDT; Aave's static aToken wrappers expose the ERC-4626 interface. The exact wrapper address for
USDT on Celo should be confirmed before it is allowlisted.

All yield belongs to the lender. When escrow empties (grant paid, reclaimed, or offer cancelled),
whatever is left beyond what was owed out is credited to the lender. Each loan tracks its own
vault shares, so two loans in the same vault never touch each other's yield.

Using a generic ERC-4626 interface keeps the contract chain-agnostic. A loan with `vault =
address(0)` keeps escrow as a plain token balance.

## 3. Safety

- **Solvency.** For plain-balance loans, the contract's token balance equals the sum of escrow held
  plus lender credits. For vault loans, the contract's vault shares equal the sum of per-loan
  shares. Every increment is matched by a transfer in, and every decrement by a transfer out.
- **No custody beyond the lender's own funds.** The admin can only change which tokens and vaults
  new loans may use. Existing loans keep their token and vault. The lender can cancel only before
  acceptance and reclaim the grant only once the loan is Overdue; neither touches the borrower's
  principal or repayments.
- **Vault losses.** If the vault loses value, payouts are capped at what escrow can cover. The
  borrower only owes what was actually disbursed (`disbursed`, not `principal`), so a vault loss
  never leaves them owing money they did not receive.
- **Vault liquidity.** If the vault cannot pay out at the moment (for example Aave at 100%
  utilization), acceptance, grant release and cancellation revert until liquidity returns. No
  funds are lost, but actions can be delayed. Allowlist only vaults with deep liquidity.
- **Re-entrancy.** Every token-moving function is `nonReentrant` and updates state before
  transfers, except where a vault's return value is needed to update shares.
- **Weird tokens.** Fee-on-transfer and rebasing tokens must never be allowlisted, matching repo
  policy. USDT on Celo uses 6 decimals, which the tests exercise.

## 4. Decisions worth defending

- **Lender initiates, borrower accepts.** Loans start from the lender, who sets every term. The
  borrower's only choice is to accept as written, which keeps the offer verifiable and avoids a
  negotiation protocol on-chain. A borrower-initiated request flow can live in the app.
- **No interest.** The product is a zero-interest loan with a reward for completing it. The lender
  earns yield on escrow instead, which partly offsets the cost of the grant.
- **Grant is all-or-nothing.** There is no partial release for partial repayment. That keeps the
  incentive clear and the accounting simple.
- **Separate contract.** The ASCA in #184 caps credit at the borrower's own savings, which is the
  right safety rule for a savings group but rules out lending to a borrower with no savings.
  Loosening that cap would weaken the ASCA, so this lives on its own.

## 5. Scope (v1) and follow-ups

Implemented: lender-funded offers, late-bound borrower, terms-hash acceptance, flexible repayment
by anyone, permissionless grant release, reclaim on default, deadline extensions, ERC-4626 escrow
yield, and the view surface, behind an OZ v5 `TransparentUpgradeableProxy`, with 44 unit tests
including a lifecycle fuzz test.

Deferred: multiple backers funding one loan, more than one step (e.g. 500 then 1,000 then a
grant), installment schedules with per-installment deadlines, yield routed to the borrower or a
solidarity fund, Chainlink automation for `releaseGrant` and `collect`, and fork tests against the
live Aave wrapper on Celo.
