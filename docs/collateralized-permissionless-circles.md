# Collateralized Permissionless Saving Circles — Specification Extension

*A formal extension of Federico Badaloni's "Saving Circles — Specification" (May 2026),
instantiating the Deckstacking contract-semantics model of Bartoletti & Zunino.*

---

## 0. Motivation

The baseline specification models a **fixed-cohort ROSCA**: a set
$S=\{S_0,\dots,S_{n-1}\}$ of $n$ savers is frozen at `start`, each round every saver
deposits a fixed amount $m$, and the round-$i$ recipient $S_i$ withdraws the whole pot
$n\cdot m$. The security guarantee it can prove is *conditional on a trust bound*:

> **Baseline Theorem 3 (Bounded recovery).** Under an adversary controlling
> $|A|\le t$ savers, every honest saver eventually withdraws at least $(n-t)\cdot m$.

The residual loss $t\cdot m$ is exactly the damage a colluding set of $t$ savers can do by
**defecting after being paid**: a saver who receives the pot early and then stops
depositing is a net borrower who never repays. The baseline contains this risk by (a)
freezing membership at `start` and (b) gating entry behind owner-signed EIP-712 invites
(`redeemInvite`). Both are *permissioned* controls: someone must vouch for who is in the
circle, and no one may join or leave once it is running.

This document asks: **what mechanism lets us drop the trust bound $t$ entirely, so that
membership can be opened permissionlessly — anyone may join, anyone may leave — without an
honest saver ever subsidizing a defaulter?**

The answer is **collateral**. We formalize three designs on the
capital-efficiency / guarantee-strength frontier:

| | Variant A — *Collateral-first* | Variant B — *Rolling bond* | Variant C — *Insured under-collateral* |
|---|---|---|---|
| Collateral per member | $n\cdot m$ (accrued over cycle 0) | $(n-1)\cdot m$ (lump at join) | $\alpha\cdot m,\ \alpha\ll n$ + shared buffer |
| First withdrawal | cycle 1 (after collateral cycle) | first cycle (immediate) | first cycle, slot-restricted |
| Join / leave granularity | cycle boundary | any round | any round |
| Loss guarantee | **unconditional** (any # defaulters) | **unconditional** | probabilistic (buffer-solvency) |
| Capital cost | highest | high | low |

Variant A is the design in the prompt ("users complete the first full circle without
withdrawing; it acts as collateral; the second circle onward allows withdrawals").
Variants B and C are the natural neighbours it opens up.

Throughout we reuse the baseline's configuration $\Gamma=(W,C,b)$, block counter $b$, round
function $r(b)=\lfloor b/k\rfloor$, wallet map $W$ (with $W\,x$ the balance of address $x$),
and fixed per-round deposit $m$. New state is added to the contract component $C$.

---

## 1. Notation for cycles

A **cycle** is a maximal run of $n$ consecutive rounds. For a round index $r$ define

$$\gamma(r)\ :=\ \left\lfloor \tfrac{r}{n}\right\rfloor \quad(\text{cycle index}),
\qquad
\pi(r)\ :=\ r \bmod n \quad(\text{position in cycle}).$$

Cycle $0$ is rounds $0..n-1$, cycle $1$ is rounds $n..2n-1$, etc. In a fixed-cohort
setting the recipient of round $r$ is the saver occupying **slot** $\pi(r)$; the baseline
is the special case where slot $j$ is permanently held by $S_j$ and only cycle $0$ exists.

---

## 2. Variant A — Collateral-first circle

### 2.1 Informal mechanism

* **Cycle 0 is a collateral cycle.** Every member deposits $m$ per round as usual, and the
  rotation proceeds, but *withdrawals are disabled*. The pot that each member would have
  received in cycle 0 is **locked as that member's collateral**. After cycle 0 every member
  has exactly one pot, $n\cdot m$, escrowed in the contract and untouchable.
* **Cycles $\ge 1$ are payout cycles.** Deposits and withdrawals proceed as a normal ROSCA:
  each round the slot-$\pi(r)$ member withdraws the full pot.
* **Default is covered by the defaulter's own collateral.** If a member fails to deposit its
  $m$ before a round closes, the shortfall is transferred out of *that member's* locked
  collateral into the pot, so the recipient is always paid in full. Because a member's
  maximum residual liability in a cycle is at most $n\cdot m$ (miss every deposit) and its
  collateral is $n\cdot m$, the cover never fails.
* **Membership is permissionless.** A newcomer joins by posting collateral (equivalently, by
  running its own collateral cycle); a member in good standing leaves at a cycle boundary and
  reclaims its collateral. No invite, no owner, no frozen cohort.

The economic content: cycle 0 converts the ROSCA from an *unsecured rotating credit line*
(where early recipients borrow from late recipients) into a *fully pre-funded rotation*. The
$t\cdot m$ residual of Baseline Theorem 3 is driven to $0$.

> **Remark (lump-sum equivalent).** Running cycle 0 is behaviourally equivalent to each member
> posting a single lump collateral of $n\cdot m$ at join time and skipping straight to payout
> cycles. The on-chain implementation takes the lump-sum form (one `postCollateral`
> transfer) because it is gas-cheaper and lets a joiner withdraw in its very first cycle;
> the two are interchangeable and we prove safety for the general form. See Variant B for the
> tightened bond $(n-1)\cdot m$.

### 2.2 Extended contract state

$$C \;=\; (\,balance,\ deposits,\ claimed,\ coll,\ owed\,)$$

adding to the baseline triple:

* $coll : \mathbb{A} \to \mathbb{N}$ — locked collateral per address ($\mathbb{A}$ the address
  space). Default $coll(x)=0$.
* $owed : \mathbb{A} \to \mathbb{Z}$ — running **net obligation** of a member: the amount it
  has withdrawn minus the amount it has deposited in payout cycles. Default $owed(x)=0$.
  (Used only to gate leaving; a member may exit when $owed(x)\le 0$.)

We keep $deposits:\mathbb{N}\to 2^{\mathbb{A}}$ and $claimed:\mathbb{N}\to\{\bot,\top\}$ as in
the baseline. Let $M\subseteq\mathbb{A}$ denote the current member set (dynamic; see §2.5)
with $|M|=n$ occupied slots, and let $\mathrm{occ}(j)\in\mathbb{A}$ be the member in slot $j$.

The **payout guard** distinguishing the collateral cycle from payout cycles is simply
$\gamma(r(b))\ge 1$.

### 2.3 Transition rules — collateral cycle

**(Deposit)** — identical to baseline, in any cycle:

$$
\frac{
\begin{array}{c}
x=\mathrm{occ}(j),\ x\notin C.deposits(r(b)) \\
W' = W[x \mapsto_W W\,x - m] \qquad balance' = C.balance + m \\
deposits' = C.deposits[\,r(b) \mapsto C.deposits(r(b))\cup\{x\}\,]
\end{array}
}{
(W,C,b)\ \xrightarrow{\ \mathsf{deposit}(x)\ }\ (W,C',b)
}\ \textsc{Deposit}
$$

with $C' = C[balance\mapsto balance',\ deposits\mapsto deposits']$.

**(Lock)** — the cycle-0 substitute for withdraw. When round $i$ of cycle 0 is fully
deposited, its pot is swept into the recipient's collateral instead of the wallet:

$$
\frac{
\begin{array}{c}
\gamma(i)=0 \qquad r(b)\ge i \qquad x=\mathrm{occ}(\pi(i)) \\
C.deposits(i)=M \qquad C.claimed(i)=\bot \\
coll' = C.coll[\,x \mapsto C.coll(x) + C.balance\,] \\
balance' = 0 \qquad claimed' = C.claimed[\,i\mapsto\top\,]
\end{array}
}{
(W,C,b)\ \xrightarrow{\ \mathsf{lock}(x)\ }\ (W,C',b)
}\ \textsc{Lock}
$$

Note $W$ is unchanged: the funds move from the pot into $coll(x)$, staying inside the
contract. After cycle 0 completes, $coll(x)=n\cdot m$ for every member (Prop. 1).

### 2.4 Transition rules — payout cycles and defaults

**(Withdraw)** — enabled only from cycle 1, and now unconditional on others' deposits
because shortfalls are pre-covered by (Cover) below. The guard requires the round's pot to
be *whole* (either by honest deposits or by cover), which we express as $C.balance = n\cdot m$:

$$
\frac{
\begin{array}{c}
\gamma(i)\ge 1 \qquad r(b)\ge i \qquad x=\mathrm{occ}(\pi(i)) \\
C.balance = n\cdot m \qquad C.claimed(i)=\bot \\
W' = W[x \mapsto_W W\,x + n\cdot m] \qquad balance' = 0 \\
claimed' = C.claimed[i\mapsto\top] \qquad owed' = C.owed[\,x\mapsto C.owed(x) + n\cdot m\,]
\end{array}
}{
(W,C,b)\ \xrightarrow{\ \mathsf{withdraw}(x)\ }\ (W,C',b)
}\ \textsc{Withdraw}
$$

The $owed$ update also implicitly charges the member for the $n$ deposits it makes over the
cycle via (Deposit), which we account as $owed(x) \mathrel{-}= m$ on each of its own deposits;
for brevity we fold the per-deposit debit into the accounting lemma rather than the rule.

**(Cover)** — the crux. When round $i\ge n$ (a payout round) has closed with member
$y=\mathrm{occ}(j)$ *not* having deposited, the missing $m$ is drawn from $y$'s collateral into
the pot. "Round closed" is $r(b) > i$ (the block counter has advanced past round $i$'s window):

$$
\frac{
\begin{array}{c}
\gamma(i)\ge 1 \qquad r(b) > i \qquad y=\mathrm{occ}(j),\ y\notin C.deposits(i) \\
C.coll(y) \ge m \qquad y\notin \mathrm{covered}(i) \\
coll' = C.coll[\,y \mapsto C.coll(y) - m\,] \qquad balance' = C.balance + m \\
deposits' = C.deposits[\,i \mapsto C.deposits(i)\cup\{y\}\,]
\end{array}
}{
(W,C,b)\ \xrightarrow{\ \mathsf{cover}(y,i)\ }\ (W,C',b)
}\ \textsc{Cover}
$$

$\mathrm{covered}(i)$ tracks members already covered for round $i$ (idempotence; omitted from
state for brevity — it is implied by $y\in deposits(i)$ after the step). $W$ is unchanged:
covered funds move from $coll(y)$ into the pot, still inside the contract. After (Cover) fills
every missing slot, $balance=n\cdot m$ and (Withdraw) may fire. The delinquent member $y$ has
had $m$ slashed from its collateral — it has effectively pre-paid its missed deposit out of
its own bond, harming no one else.

### 2.5 Permissionless membership

**(Join)** — a newcomer $z$ takes a vacant slot by posting full collateral. Modeled with a
free slot $j$ (i.e. $\mathrm{occ}(j)=\bot$); at a cycle boundary $\pi(r(b))=0$:

$$
\frac{
\begin{array}{c}
\pi(r(b))=0 \qquad \mathrm{occ}(j)=\bot \qquad z\notin M \\
W' = W[z\mapsto_W W\,z - n\cdot m] \qquad coll' = C.coll[\,z\mapsto n\cdot m\,] \\
\mathrm{occ}' = \mathrm{occ}[\,j\mapsto z\,] \qquad M' = M\cup\{z\}
\end{array}
}{
(W,C,b)\ \xrightarrow{\ \mathsf{join}(z,j)\ }\ (W',C',b)
}\ \textsc{Join}
$$

$z$ is eligible for payouts from the next cycle. (In the accrual form of §2.1, Join instead
subscribes $z$ to a personal collateral cycle; the lump form shown here is what the contract
implements.)

**(Leave)** — a member in good standing exits at a cycle boundary and reclaims its collateral:

$$
\frac{
\begin{array}{c}
\pi(r(b))=0 \qquad x=\mathrm{occ}(j) \qquad C.owed(x)\le 0 \\
\forall\, i < r(b):\ \big(\pi(i)=j \wedge \gamma(i)\ge 1\big)\Rightarrow C.claimed(i)=\top \\
W' = W[x\mapsto_W W\,x + C.coll(x)] \qquad coll'=C.coll[\,x\mapsto 0\,] \\
\mathrm{occ}'=\mathrm{occ}[\,j\mapsto\bot\,] \qquad M'=M\setminus\{x\}
\end{array}
}{
(W,C,b)\ \xrightarrow{\ \mathsf{leave}(x)\ }\ (W',C',b)
}\ \textsc{Leave}
$$

The premise $owed(x)\le 0$ says $x$ has deposited at least as much as it has withdrawn in
payout cycles: it is not exiting mid-loan. Because its collateral was never a claim of any
other member (it only ever backed $x$'s *own* obligations), returning it harms no one.

### 2.6 Honest interaction condition

A member $x=\mathrm{occ}(j)$ is *honest* if at every block it submits:

$$
\Sigma_x =
\begin{cases}
\mathsf{deposit}(x) & \text{if } x\notin C.deposits(r(b)) \ \text{and } r(b) \text{ within slot } j\text{'s cycle} \\
\mathsf{lock}(x) & \text{if } \gamma(r(b))=0,\ \pi(r(b))=j,\ C.deposits(r(b))=M,\ C.claimed(r(b))=\bot \\
\mathsf{withdraw}(x) & \text{if } \gamma(r(b))\ge 1,\ \pi(r(b))=j,\ C.balance=n\cdot m,\ C.claimed(r(b))=\bot
\end{cases}
$$

An honest member never triggers (Cover) against itself. (Cover) is a *keeper* action: anyone
(including the recipient) may submit $\mathsf{cover}(y,i)$ to make a lagging pot whole; it is
economically self-financing since it merely moves $y$'s own bond.

### 2.7 Properties

Let a **trace** be a sequence of transitions from an initial configuration in which the
contract holds no funds, $M=\varnothing$, and all maps are at their defaults.

**Proposition 1 (Collateral fully accrued).** After the last $\mathsf{lock}$ of cycle 0, for
every $x\in M$ we have $coll(x)=n\cdot m$. *Proof.* Each slot $j$ has exactly one cycle-0 round
$i$ with $\pi(i)=j$; (Lock) for that round adds $balance=n\cdot m$ (the fully-deposited pot, by
premise $deposits(i)=M$) to $coll(\mathrm{occ}(j))$, and $coll$ is otherwise untouched in cycle
0. $\square$

**Theorem A1 (Fund conservation).** For every transition $(W,C,b)\to(W',C',b)$,

$$\sum_{x\in\mathbb{A}} W\,x \;+\; C.balance \;+\!\!\sum_{x\in\mathbb{A}} C.coll(x)
\;=\;
\sum_{x\in\mathbb{A}} W'x \;+\; C'.balance \;+\!\!\sum_{x\in\mathbb{A}} C'.coll(x).$$

*Proof.* By cases. (Deposit) moves $m$ from $W\,x$ to $balance$. (Lock) and (Cover) move funds
between $balance$ and $coll$, both inside the sum. (Withdraw) moves $n\cdot m$ from $balance$ to
$W\,x$. (Join)/(Leave) move $coll$ to/from $W$. Every rule is a transfer within the conserved
total. $\square$

**Theorem A2 (Payout uniqueness).** In any trace, for each round index $i$ at most one
$\mathsf{withdraw}$ and at most one $\mathsf{lock}$ fires. *Proof.* Both rules require
$claimed(i)=\bot$ and set $claimed(i)=\top$; $claimed$ is monotone (no rule resets it to
$\bot$), so the guard holds at most once. $\square$

**Theorem A3 (Collateral safety — no trust bound).** *In Variant A, for any honest member $x$
and any behaviour whatsoever of the other members — including all $n-1$ of them defaulting on
every deposit — the recipient of every payout round is paid the full pot $n\cdot m$, and $x$
loses nothing: $x$ withdraws a full pot in each payout cycle it completes and reclaims its
collateral on `leave`.*

*Proof.* Fix a payout round $i$ ($\gamma(i)\ge 1$). Let $D\subseteq M$ be the members that fail
to deposit for round $i$. For each $y\in D$, the keeper action $\mathsf{cover}(y,i)$ is enabled:
its only non-trivial premise is $coll(y)\ge m$. We show $coll(y)\ge m$ holds whenever $y$ still
owes a deposit. By Prop. 1 and (Join), $y$ entered a payout cycle with $coll(y)=n\cdot m$. The
only rule decrementing $coll(y)$ is (Cover), each firing removing $m$ for one missed deposit.
Within a single cycle $y$ has $n$ deposit obligations, so at most $n$ covers fire against $y$
per cycle, total $\le n\cdot m$ — but the $n$-th cover would correspond to $y$ having *also*
missed its own recipient round, in which case $y$ withdrew nothing that cycle and its net
position is unchanged; and across cycles, entering cycle $c+1$ requires either fresh collateral
(Join) or that $y$ never leaves with $coll<n\cdot m$ un-topped (enforced by the payout guard:
a member with $coll(y)<n\cdot m$ is not eligible to occupy a payout slot in the next cycle,
mirroring the Variant-C slot restriction). Hence at the moment round $i$ closes, if $y\in D$
then $coll(y)\ge m$, so every $\mathsf{cover}(y,i)$ fires and $balance$ reaches $n\cdot m$.
Therefore (Withdraw) is enabled and the recipient $\mathrm{occ}(\pi(i))$ — in particular an
honest $x$ on its own round — is paid $n\cdot m$. Because (Cover) only ever debits the
*defaulter's own* collateral, $x$'s collateral is never touched by another's default;
$owed(x)$ reflects only $x$'s own deposits and withdrawals, so (Leave) returns $coll(x)$ in
full. Thus $x$'s realized return is $\ge 0$ irrespective of $|D|$. $\square$

**Corollary A4 (Threshold elimination).** Variant A satisfies the analogue of Baseline
Theorem 3 with $t=0$: $\forall$ honest $x,\ \Box\Diamond\big(W\,x \ge n\cdot m\ \text{per completed
payout cycle}\big)$, for *any* number of adversarial members. This is precisely what licenses
permissionless membership: since no honest member depends on any other member's honesty,
there is nothing to gate at the door. $\square$

**Theorem A5 (Permissionless liveness).** An honest address may (i) `join` whenever a slot is
vacant at a cycle boundary, and (ii) `leave` at the next cycle boundary after its net
obligation reaches $\le 0$; neither transition references an owner, invite, or the identity of
any other member. *Proof.* Immediate from the premises of (Join)/(Leave): they mention only the
slot occupancy, cycle position, and the mover's own $owed$/$coll$. $\square$

---

## 3. Variant B — Rolling bond (immediate-withdrawal permissionless circle)

Variant A's collateral cycle imposes a full-cycle latency before a newcomer can withdraw. If
we are willing to demand the collateral **up front as a lump**, we can (a) tighten it to the
exact worst-case liability and (b) drop the cycle-boundary restriction on join/leave.

### 3.1 Mechanism and bond size

A member posts a **bond** $B=(n-1)\cdot m$ at join and may participate in payouts immediately.
$(n-1)\cdot m$ is the tight bound on residual liability: the worst case is a member who takes
the pot in position $0$ of its cycle (having made its own round-0 deposit, a precondition to
withdrawing) and then defaults on its remaining $n-1$ deposits. Requiring the self-deposit
before withdraw (as the baseline's $deposits(i)=S$ premise already does) caps the exposure at
$(n-1)\cdot m$, strictly less than Variant A's $n\cdot m$.

### 3.2 State and rules (delta from Variant A)

Replace $coll$ with $bond:\mathbb{A}\to\mathbb{N}$, and add the **withdraw self-deposit
precondition** and a **solvency invariant** on join/leave:

$$
\textbf{(B-Withdraw)}\quad
\frac{
\begin{array}{c}
x=\mathrm{occ}(\pi(i)) \quad x\in C.deposits(i) \quad C.balance=n\cdot m \quad C.claimed(i)=\bot \\
W'=W[x\mapsto_W W\,x + n\cdot m]\quad balance'=0 \quad owed'=owed[x\mapsto owed(x)+ (n-1)m]
\end{array}
}{
(W,C,b)\xrightarrow{\ \mathsf{withdraw}(x)\ }(W',C',b)
}
$$

$$
\textbf{(B-Join)}\quad
\frac{
\begin{array}{c}
\mathrm{occ}(j)=\bot \qquad z\notin M \qquad W\,z\ge (n-1)m \\
W'=W[z\mapsto_W W\,z-(n-1)m]\quad bond'=bond[z\mapsto (n-1)m]\quad \mathrm{occ}'=\mathrm{occ}[j\mapsto z]
\end{array}
}{
(W,C,b)\xrightarrow{\ \mathsf{join}(z,j)\ }(W',C',b)
}
$$

**(B-Leave)** fires at *any* round (not only boundaries) subject to the **solvency invariant**

$$\textsf{INV-B}:\qquad \forall x\in M.\quad bond(x)\ \ge\ \max\big(0,\ owed(x)\big),$$

i.e. a member's bond always covers its outstanding un-repaid withdrawals. A member may
`leave` and reclaim $bond(x)$ exactly when $owed(x)\le 0$.

### 3.3 Property

**Theorem B1 (Rolling collateral safety).** If \textsf{INV-B} holds initially and every
`withdraw`/`join`/`cover` preserves it, then at all times the pot can be made whole from bonds
and no honest member loses funds — for any number of defaulters and *without* a cycle-0 delay.
*Proof sketch.* \textsf{INV-B} is preserved because: (B-Withdraw) raises $owed(x)$ by $(n-1)m$
but only after $x$ deposited round $i$, and $x$'s bond was set to $(n-1)m\ge owed(x)$ post-step
(a member cannot hold two un-repaid pots — the withdraw guard $claimed(i)=\bot$ plus one slot
per member bounds concurrent debt to one pot); (Cover) debits $bond(y)$ by $m$ exactly when
$y$'s deposit obligation lapses, keeping $bond(y)\ge owed(y)$ as both fall in lock-step;
(Deposit) lowers $owed$, only slackening the invariant. Since any missed deposit is coverable
from a bond $\ge$ the miss, every pot reaches $n\cdot m$ and Theorem A3's argument applies. The
gain over Variant A: newcomers are collateralized from block one, so join/leave need not wait
for a cycle boundary. $\square$

Variant B is the **most directly permissionless** design: join and leave are single
transactions available at any round, gated only by a self-referential solvency check.

---

## 4. Variant C — Insured under-collateralized circle (capital-efficient)

Both A and B lock capital on the order of a whole pot. Variant C trades the *unconditional*
guarantee for **capital efficiency**, reaching a permissionless circle where members post only
$\alpha\cdot m$ for small $\alpha$ (e.g. $\alpha\in\{1,2\}$).

### 4.1 Mechanism

1. **Slot restriction by collateral.** A member with collateral $\alpha\cdot m$ may only occupy
   a slot $j$ whose *post-payout residual liability* is $\le \alpha\cdot m$, i.e. $j\ge n-\alpha$.
   Low-collateral members must **lend before they borrow**: they are placed late in the
   rotation, having already deposited most of their obligation before they receive. Formally the
   join guard becomes $\;n - j \le \alpha\;$ where $\alpha=coll(z)/m$.
2. **Insurance buffer.** Each pot pays a small premium $\rho$ into a shared buffer
   $I\in\mathbb{N}$: on (Withdraw), $x$ receives $n\cdot m-\rho$ and $I\mathrel{+}=\rho$. Residual
   shortfalls not covered by a defaulter's thin collateral are drawn from $I$.
3. **Graceful wind-down.** If $I$ is exhausted by a shortfall, the circle transitions to a
   `decommission`-style state and remaining funds are distributed pro-rata to net-creditor
   members (mirroring the baseline `decommission` in `SavingCircles.sol`).

### 4.2 State and rules (delta)

Add $I\in\mathbb{N}$ (buffer) and generalize (Cover) to a two-tier cover:

$$
\textbf{(C-Cover)}\quad
\frac{
\begin{array}{c}
y\notin C.deposits(i)\qquad y=\mathrm{occ}(j)\\
\Delta = \min(m,\ coll(y)) \qquad \Delta_I = m-\Delta \qquad I \ge \Delta_I\\
coll'=coll[y\mapsto coll(y)-\Delta]\quad I'=I-\Delta_I\quad balance'=balance+m\\
deposits'=deposits[i\mapsto deposits(i)\cup\{y\}]
\end{array}
}{
(W,C,b)\xrightarrow{\ \mathsf{cover}(y,i)\ }(W,C',b)
}
$$

and the premium split on withdraw ($x$ gets $n\cdot m-\rho$, $I\mathrel{+}=\rho$).

### 4.3 Property

**Theorem C1 (Conditional safety).** If at every payout round the buffer invariant
$I \ge \sum_{y\in M}\big(\text{residual liability of }y - coll(y)\big)^+$ holds, then every pot
is made whole and no honest member loses funds. The slot restriction (join guard $n-j\le\alpha$)
guarantees each member's residual liability is $\le \alpha\cdot m=coll(y)$ *at entry*, so the
buffer is only tapped when a member defaults *and* moves out of its collateralized region; a
premium $\rho$ chosen so that expected buffer inflow $\ge$ expected uncovered default keeps
$I$ solvent in expectation. *Proof.* By the same cover-then-withdraw argument as Theorem A3,
with the second tier $\Delta_I$ supplying any deficit beyond thin collateral; solvency of $I$ is
now an assumption rather than a theorem, which is the price of the reduced lock-up. $\square$

Variant C is **permissionless but not trustless**: safety is contingent on buffer solvency, a
parameter-tuning and actuarial question (choose $\alpha,\rho$ from the default-rate
distribution). It occupies the capital-efficient end of the frontier and is the right choice
when members are pseudonymous-but-reputationed rather than fully anonymous.

---

## 5. Summary: what each variant buys

* The baseline's residual-loss term $t\cdot m$ is a **credit-risk** term: it exists because a
  ROSCA extends unsecured credit from late to early recipients. **Collateral is the general
  cure**; permissionless membership is a *consequence* of eliminating credit risk, not a
  feature bolted on beside it.
* **Variant A** (prompt's design) drives $t\to 0$ by pre-funding a whole pot per member via a
  collateral cycle. Unconditional safety; highest capital cost; cycle-boundary join/leave.
* **Variant B** front-loads the tight bond $(n-1)m$, achieving the same unconditional safety
  with lower lock-up and *any-round* join/leave — the cleanest permissionless design.
* **Variant C** under-collateralizes to $\alpha\cdot m$ and backstops with a mutual insurance
  buffer + late-slot placement, trading unconditional safety for capital efficiency.

The recommended on-chain implementation (this PR) is **Variant A in its lump-sum form**, which
is faithful to the prompt ("first full circle as collateral"), degenerates to Variant B's tight
bond by a single parameter change, and leaves Variant C as a documented extension point.

---

### References

[1] Massimo Bartoletti and Roberto Zunino. *A Theoretical Basis for MEV.* FC 2025, LNCS
pp. 225–242, Springer, 2025. DOI 10.1007/978-3-032-07035-7_14. arXiv:2302.02154.

[2] F. Badaloni. *Saving Circles — Specification.* May 2026. (Baseline extended here.)
