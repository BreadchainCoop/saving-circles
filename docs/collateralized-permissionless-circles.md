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

The answer is **collateral**. We formalize four designs on the
capital-efficiency / guarantee-strength frontier:

| | Variant A — *Collateral-first* | Variant B — *Rolling bond* | Variant C — *Insured under-collateral* | Variant D — *Foremanless chit* (§5) |
|---|---|---|---|---|
| Collateral per member | $n\cdot m$ (accrued over cycle 0) | $(n-1)\cdot m$ (lump at join) | $\alpha\cdot m,\ \alpha\ll n$ + shared buffer | $(n{-}1{-}j)\cdot m$ at prize time only, less the bid discount; $+\,m$ bond |
| First withdrawal | cycle 1 (after collateral cycle) | first cycle (immediate) | first cycle, slot-restricted | any round, by reverse auction |
| Join / leave granularity | cycle boundary | any round | any round | any round (substitution market) |
| Loss guarantee | **unconditional** (any # defaulters) | **unconditional** | probabilistic (buffer-solvency) | **unconditional** |
| Compensation to patient members | none | none | none | auction dividends (endogenous interest) |
| Capital cost | highest | high | low | minimal for full security ($=$ outstanding credit) |

Variant A is the design in the prompt ("users complete the first full circle without
withdrawing; it acts as collateral; the second circle onward allows withdrawals").
Variants B and C are the natural neighbours it opens up. Variant D (§5) is obtained by
confronting A–C with the oldest *market-allocated* ROSCA in continuous operation — the Indian
chit fund and its reverse auction — which turns out to sharpen the risk analysis of all three
and to strictly improve B.

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
(§5.3 relaxes the cycle-boundary restriction via chit-fund *substitution*: leaving at any
round by selling the position to a successor.)

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
(§5.2–5.3 show B is nonetheless $\sim$4× over-collateralized relative to the credit actually
at risk, and derive the cheaper prize-time collateralization that Variant D adopts.)

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

## 5. The chit-fund lens: reverse auctions and the anatomy of default risk

Variants A–C were derived from first principles. This section checks them against the oldest
*market-allocated* ROSCA in continuous large-scale operation — the Indian **chit fund**, a
bidding ROSCA regulated by the Chit Funds Act, 1982 — and against the economics literature on
bidding vs. random ROSCAs [3,4]. The comparison is productive in both directions: chit
practice exposes that Variants A and B **secure the wrong thing** (they collateralize members
uniformly when only *prized* members carry credit risk, overpaying by $\sim$4×), and it
contributes two mechanisms we had no analogue of (the reverse auction and subscriber
substitution). Conversely, our framework shows exactly which of the foreman's roles the
contract can absorb and which it provably cannot (§5.6).

### 5.1 How a chit works

A chit of $n$ subscribers and installment $m$ runs $n$ periods. Every period each subscriber
pays $m$; the pot ("chit amount" $n\cdot m$) is allocated by **reverse auction** among the
subscribers who have not yet won: each bids a *discount* — the portion of the pot they are
willing to forgo. The highest discount wins (the Act caps it at 30–40% of the pot, with ties
broken by lot), the winner — the **prized subscriber** — receives $n\cdot m - d$, the foreman
retains a commission (capped at 5%), and the remaining discount is distributed to all
subscribers as a **dividend**, reducing their effective installment. Two structural facts
matter here:

1. **Security attaches at prize time, and only to prized subscribers.** Before drawing the
   pot, the prized subscriber must furnish security for the *future* installments she still
   owes (the Act admits sureties, property, deposits, gold, insurance policies). A
   *non-prized* defaulter is handled entirely differently: under §§28–30 of the Act she is
   *removed* and a **substituted subscriber** takes over her ticket. No collateral is ever
   demanded from non-prized subscribers.
2. **The discount is a price.** It aggregates time preference (who values liquidity now) and
   the group's compensation for extending credit, endogenously, every round. Patient members
   are *paid* (dividends) for lending; impatient members pay. In a fixed-rotation ROSCA the
   implicit interest rate is forced to zero.

The foreman bundles three roles — gatekeeper (vets subscribers), guarantor (must make the pot
whole and is required to post the full chit value with the Registrar), and market-maker
(finds substitutes). The rest of this section compiles roles two and three into contract
rules, and proves that role one — vetting — is exactly the part that cannot be compiled away
without giving up either credit or safety.

### 5.2 What the chit teaches: prized and non-prized default differ in kind

Fix a payout cycle and suppose all covers are current. Two elementary facts our Variants A–B
failed to exploit:

**Lemma 5.1 (Residual uniformity).** At the close of round $j$ of a payout cycle, every prized
member has residual liability exactly $(n-1-j)\cdot m$. *Proof.* The winner of round $w\le j$
had residual $(n-1-w)\cdot m$ at award and has made $j-w$ deposits since:
$(n-1-w)m-(j-w)m=(n-1-j)m$. $\square$

**Corollary 5.2 (Outstanding-credit parabola).** System-wide outstanding credit at the close of
round $j$ is

$$K(j) \;=\; (j+1)(n-1-j)\,m \;\le\; \left\lceil\tfrac{n}{2}\right\rceil\!\left\lfloor\tfrac{n}{2}\right\rfloor m \;\approx\; \tfrac{n^2}{4}\,m,$$

peaking mid-cycle. Variant B locks $n(n-1)\cdot m$ of bonds at *all* times — asymptotically
**4×** the peak credit at risk, and far more than the off-peak $K(j)$; Variant A locks
$n^2 m$. Full security does not require holding more than $K(j)$: everything above it secures
obligations that do not exist. $\square$

**Lemma 5.3 (Non-prized default is not a credit event).** Let a non-prized member default
after depositing $i$ rounds of the cycle, having posted a one-round bond $m$ (§5.4). Her
forfeiture is $i\cdot m$ (the claim she abandons) $+\;m$ (bond) against $(n-i)\cdot m$ of
missing future deposits, so the *aggregate* uncovered shortfall is $(n-2i-1)^{+}m$ if the
circle inertly runs to completion at size $n$ — and $0$ if, at detection, the defaulter is
removed and either **substituted** (a successor buys the position by paying the accumulated
claim and assumes the deposit schedule, exactly the Act's §§28–30) or the circle is
**resized** to $n-1$ with pots $(n-1)m$; fund conservation plus the forfeited claim and bond
make the resize solvent, with the transition round bridged by the bond. In particular a
non-prized defaulter never *profits* (she forfeits $\ge$ her own stake), and for
$i\ge (n-1)/2$ she damages no one even without removal. $\square$

The asymmetry: **prized default is credit theft** (the defaulter has withdrawn more than she
deposited and walks away from the difference) while **non-prized default is a lender declining
to keep lending** — its harm is re-coordination, absorbed by substitution or resizing.
Variants A and B secure both risks identically with worst-case member collateral; the chit
prices them separately, demanding real security only where theft is possible. That is the
correction we now backport.

### 5.3 Backported improvements to Variants A and B

**(I1) Prize-time (just-in-time) collateral — Variant B done right.** Replace B's uniform
join-time bond $(n-1)m$ with: a one-round **membership bond** $m$ at join, and a **prize
lock** of the winner's exact residual $(n-1-j)m$, demanded *at award* and released $m$-per-
on-time-deposit thereafter. Non-prized defaults are handled by bond + removal + substitution
or resize (Lemma 5.3); prized defaults are covered from the prize lock as in (Cover). Peak
aggregate capital held falls from $n(n-1)m$ to $n\cdot m + K(j^*) \approx n\cdot m + n^2m/4$
— a $\sim$4× reduction at scale (2.5–3× at $n=10$–$20$) for the *same unconditional
prized-default safety* (Theorem D3 below). Everything Variant B promised, at a quarter of the
lockup.

**(I2) Release-at-prize — a refund schedule for Variant A.** Variant A's lock of $n\cdot m$
per member is needed in full only *until that member's own prize round*: from Lemma 5.1 her
residual at award is $(n-1-j)m$, so $(j+1)\cdot m$ of her lock is releasable **immediately at
prize time**, and $m$ more per subsequent on-time deposit — rather than everything waiting
for circle end as in §2.5. Average lock duration roughly halves; the cycle-0 accrual (A's
defining commitment feature) is unchanged.

**(I3) Substitution — permissionless leave at any round, for every variant.** The Act's
§§28–30 substitution mechanism generalizes (Leave): a member may exit at *any* round by
selling her position — voluntarily (she finds or the contract auctions a successor; the
successor pays her net claim, i.e. deposits made $\pm$ accrued dividends $-$ penalties, and
steps into her slot, schedule and lock) or involuntarily on default (the vacated position is
auctioned, proceeds to the estate after covering shortfalls). No other member's position
changes, so the safety invariants are untouched. This strictly improves Variant A's
cycle-boundary-only (Leave) and gives the member set true churn without B's standing bonds.

### 5.4 Variant D — the foremanless chit

Variant D composes the reverse auction with (I1) and (I3). State, extending §2.2: $bids$
$:\mathbb{N}\to(\mathbb{A}\rightharpoonup\mathbb{N}_{\ge0})$ per-round revealed discounts (commitments
elided), $withheld:\mathbb{A}\to\mathbb{N}$ per-member withheld discount, $bond:\mathbb{A}\to\mathbb{N}$,
$prized\subseteq\mathbb{A}$ per-cycle, plus $coll$, $deposits$, $claimed$ as before.

**(Join-D)** requires only the bond: $W'=W[z\mapsto_W W z - m]$, $bond'=bond[z\mapsto m]$ —
any round, any address, no invite.

**(Commit / Reveal)** During round $i$, any member with $x\notin prized$ and
$x\in deposits(i)$ (you must be current to bid) may submit a sealed commitment
$\mathsf{H}(d,\mathit{salt})$ up to $2k$ blocks before the round closes, and must reveal in
the window $[\,\mathrm{close}-2k,\ \mathrm{close}-k\,)$. The two $k$-margins make the auction
robust in the Deckstacking sense: an adversarial block scheduler can delay an honest
transaction at most $k$ blocks, so honest commitments and reveals are guaranteed inclusion
(§5.5). Sealed bids are not optional decoration: an open-outcry auction on a chain hands the
block scheduler a last-look — censor rival bids for $\le k$ blocks, snipe with $d+\epsilon$ —
i.e. auction MEV in exactly the sense of the base spec's framework [1].

**(Award)** At the close of round $i$ with $j=\pi(i)$, pot whole ($C.balance=n\cdot m$, by
deposits, bond draws, or covers), let $x^{*}=\arg\max_x bids(i)$ (deterministic tie-break on
the commitment hash; if no bids, fall back to fixed rotation among the unprized):

$$
\frac{
\begin{array}{c}
d = bids(i)(x^{*}) \qquad 0\le d\le (n-1-j)\,m \qquad C.claimed(i)=\bot \\
\ell = (n-1-j)\,m - d \qquad W\,x^{*} + n\cdot m - d \ \ge\ \ell \\
W' = W[x^{*}\mapsto_W W\,x^{*} + (n\cdot m - d) - \ell] \qquad coll' = C.coll[x^{*}\mapsto \ell] \\
withheld' = C.withheld[x^{*}\mapsto d] \qquad balance'=0 \\
claimed' = C.claimed[i\mapsto\top] \qquad prized' = prized\cup\{x^{*}\}
\end{array}
}{
(W,C,b)\ \xrightarrow{\ \mathsf{award}(x^{*},i)\ }\ (W',C',b)
}\ \textsc{Award}
$$

The winner's bid is **withheld as first-loss security** rather than paid out as an immediate
dividend, and the *cash* lock is only the difference $\ell=(n-1-j)m-d$: at award,
$withheld(x^{*})+coll(x^{*}) = d + \ell = (n-1-j)m = $ her exact residual. **A bigger bid is a
smaller cash-collateral requirement** — the market lets each member choose her own mix of
price and pledge, and the Act's ad-hoc 30–40% cap is replaced by the structural cap
$d\le(n-1-j)m$ (you cannot bid away more than you will owe).

**(Dividend)** Each subsequent on-time deposit by a prized $x$ releases
$withheld(x)/(\text{rounds remaining at award})$ pro-rata to the other members (chit-style,
as a credit against their next deposits) and $m - $ that quantum from $coll(x)$ back to $x$.
Over the residual period the honest winner pays out exactly $d$ — her interest — and recovers
exactly her cash lock.

**(Cover-D)** A prized member's missed deposit is covered $m$ from $withheld(x)$ first, then
from $coll(x)$; a non-prized member's from $bond(x)$, triggering removal and (Substitute) /
(Resize) per Lemma 5.3.

**Properties.**

* **D1 (Conservation)** and **D2 (Payout uniqueness)**: as Theorems A1–A2, with $withheld$ and
  $bond$ added to the conserved sum and $\mathsf{award}$ replacing $\mathsf{withdraw}$ in the
  $claimed$-monotonicity argument.
* **D3 (Prize safety — unconditional, no trust bound).** The invariant
  $withheld(x)+coll(x)\ \ge\ \text{residual}(x)$ holds at award (with equality) and is
  preserved by every rule ((Dividend) decrements both sides equally; (Cover-D) likewise), so
  every future pot is made whole against *any* set of prized defaulters — the Theorem A3
  argument goes through verbatim with the two-tier security replacing $coll$ alone. Note the
  self-defeating character this gives to strategic max-bidding: a member intending to default
  who bids $d$ merely converts $d$ of her own prize into pre-paid first-loss coverage; total
  security equals her residual whatever she bids, so her theft is $0$ whatever she bids.
* **D4 (Capital optimality).** Aggregate security held at close of round $j$ is
  $K(j) + n\cdot m$ (locks+withholdings $=$ outstanding credit, by D3-equality and Lemma 5.1,
  plus bonds). Any design with unconditional prize safety must hold $\ge K(j)$ in
  contract-controlled value at that moment — otherwise some prized coalition's net outflow
  exceeds security and a simultaneous walk-away is profitable. So Variant D is within
  $n\cdot m$ of the information-theoretic floor, while Variant B holds $\approx 4\times$ it at
  peak and worse off-peak.
* **D5 (Auction fairness under the adversarial scheduler).** If an honest bidder submits her
  commitment $\ge 2k$ blocks and her reveal $\ge k$ blocks before round close, both are
  included (Deckstacking $k$-inclusion), and (Award) is a deterministic function of the
  revealed set: the scheduler can neither exclude an honest bid nor react to it. Under
  first-price rules bidding one's true liquidity value is not dominant; a **Vickrey variant**
  (winner pays the second-highest discount) restores truthful bidding as the dominant
  strategy for the price dimension, with the caveat that the price–collateral substitution
  above couples bids to private collateral costs, so full incentive analysis is left open.
* **D6 (Who is compensated — economics, informal).** Dividends give patient members a strictly
  positive return, i.e. an endogenous interest rate — Variants A–C all force it to zero,
  which in an anonymous setting (no social reciprocity to fall back on) makes late positions
  strictly worse and invites a scramble for early ones. The literature qualifies the welfare
  claim, and we adopt the qualification rather than fight it: with *identical* preferences a
  random ROSCA ex-ante dominates a bidding one, while with *heterogeneous* liquidity needs
  bidding allocates pots to those who value them most [3,4]. A permissionless membership is
  heterogeneous by construction — but (Award)'s no-bid fallback to rotation means D contains
  the random/rotation circle as its degenerate case, so the allocation rule is a parameter,
  not a commitment.

### 5.5 A warning: the auction must not be bolted onto Variant C

The auction interacts *destructively* with under-collateralization. A member intending to
default is discount-insensitive — she is spending money she never plans to repay — so with
thin collateral the auction **routes pots toward the worst risks first** (adverse selection)
and drains C's insurance buffer at the maximum feasible rate; the Act's 40% cap is consumer
protection against distress bidding, not a security device, and does not help. C's own
defence was the slot restriction (thin collateral ⇒ late slots), which open bidding would
simply delete. The safe compositions are exactly:

* **auction + full prize-time security (D3 invariant)** — safe, capital-optimal: Variant D;
* **no auction + under-collateral + slot restriction + buffer** — conditionally safe:
  Variant C as specified in §4;
* **auction + under-collateral** — an adverse-selection engine; excluded.

### 5.6 What cannot be compiled away: a no-free-lunch observation

Chit funds extend *unsecured* credit (the prized subscriber's sureties are salaried
guarantors and off-chain assets — identity-based claims on future income) and buy safety with
the foreman's vetting. Our variants refuse identity; the honest question is what that costs.

**Proposition 5.4 (Trilemma).** No design simultaneously provides (i) unconditional safety,
(ii) membership open to fresh anonymous keys, and (iii) positive net credit *in the circle's
own asset*. *Proof sketch.* Unconditional safety against an anonymous member — whose only
stake is what the contract holds from her — requires the contract to hold, at every moment,
security $\ge$ her maximal remaining net outflow (else walking away profits her); holding
security $\ge$ the outflow in the same asset means her net position never exceeds what she
has already surrendered, i.e. net credit $\le 0$. $\square$

Consequently: A, B and cash-collateralized D are **commitment-savings devices with mutual
default-insurance and (in D) an interest market** — genuinely useful (the empirical ROSCA
literature finds commitment, not credit, is the dominant service [3]) but not lenders. The
credit content of a *safe* permissionless circle comes exactly from letting the prize-time
security be something other than same-asset cash: heterogeneous collateral (other tokens, LP
or staked positions — liquidity transformation, as in secured lending), or third-party
**sureties** (an on-chain guarantor stakes for the winner — the Act's salaried co-signer,
compiled), or reputation/attestation systems (Variant C's natural home). The foreman's
gatekeeping is not an inefficiency the contract forgot to remove; it is where unsecured
credit comes from. Variant D therefore parameterizes the lock asset and admits surety locks,
and claims safety, not alchemy.

---

## 6. Summary: what each variant buys, revised

* The baseline's residual-loss term $t\cdot m$ is a **credit-risk** term. Collateral is the
  general cure, and permissionless membership is a *consequence* of eliminating credit risk.
* The chit-fund lens corrects *where* collateral must sit: **only prized members carry theft
  risk** (Lemmas 5.1–5.3), and securing everyone for the worst case (A, B) over-pays $\sim$4×
  relative to the outstanding-credit parabola $K(j)$.
* **Variant A** (the prompt's design; implemented in this PR) — full pre-funding via a
  collateral cycle. Unconditional safety, simplest rules, highest lockup; improved by
  release-at-prize (I2) and substitution-based leave (I3).
* **Variant B** — join-time bond $(n-1)m$; subsumed by (I1): its uniform bond does nothing
  that prize-time locks don't do cheaper. Retained as the fixed-rotation special case of D.
* **Variant C** — under-collateralized, buffer-insured, conditionally safe; must **not** be
  combined with the auction (§5.5).
* **Variant D — the foremanless chit** — reverse auction with sealed $2k/k$ commit-reveal,
  prize-time two-tier security ($withheld + coll = $ residual), dividends as endogenous
  interest, substitution for any-round join/leave, rotation as its no-bid degenerate case.
  Unconditional prize safety at near-minimal capital (D4); the foreman's guarantee and
  market-making are compiled into rules, his commission (≤5%) becomes a keeper-fee parameter,
  and his vetting is honestly surfaced as the trilemma (Prop. 5.4) rather than silently
  dropped.

The recommended implementation path is unchanged for this PR — **Variant A in lump-sum form**
as the faithful-to-prompt v1 — with Variant D as the follow-up that supersedes B, and C kept
as a documented, auction-free extension point.

---

### References

[1] Massimo Bartoletti and Roberto Zunino. *A Theoretical Basis for MEV.* FC 2025, LNCS
pp. 225–242, Springer, 2025. DOI 10.1007/978-3-032-07035-7_14. arXiv:2302.02154.

[2] F. Badaloni. *Saving Circles — Specification.* May 2026. (Baseline extended here.)

[3] Timothy Besley, Stephen Coate and Glenn Loury. *The Economics of Rotating Savings and
Credit Associations.* American Economic Review 83(4), pp. 792–810, 1993. (Random vs. bidding
allocation; random ex-ante dominates under identical preferences, not under heterogeneity.)

[4] Jens Kovsted and Peter Lyk-Jensen. *Rotating savings and credit associations: the choice
between random and bidding allocation of funds.* Journal of Development Economics 60(1),
pp. 143–172, 1999.

[5] *The Chit Funds Act, 1982* (Act No. 40 of 1982, India). Reverse-auction discount ceiling
(30–40%); foreman commission cap (5%); prized-subscriber security before draw; §§28–30
removal and substitution of defaulting non-prized subscribers.
