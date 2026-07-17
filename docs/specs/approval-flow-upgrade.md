# Spec: Pre-launch member removal + address-bound invites

**Target issue:** [BreadchainCoop/app-stacks#99 — [3.1] General invite link for Stacks](https://github.com/BreadchainCoop/app-stacks/issues/99)
**Repo affected:** `saving-circles` (this repo) — contract upgrade
**Companion changes:** `app-stacks` — Supabase schema + API routes + UI (tracked in #99 itself)
**Status:** Proposed

---

## 1. What issue #99 requires

The issue replaces the current invite model (creator pre-generates N single-use
links; anyone clicking one instantly joins on-chain) with an approval flow:

1. Creator shares one general link → visitors see a Stack **preview page**.
2. Visitor clicks "Request to join" → appears in the creator's **pending list**.
3. Creator **approves or removes** members before launch.
4. "Launch Stack" is enabled only when the minimum member count is reached.
5. After launch the roster is **locked** and the link can be deactivated.

## 2. Why this needs a contract upgrade at all

Two acceptance criteria cannot be satisfied by the currently deployed
implementation, no matter what the app or database do:

1. **"Creator can remove approved members before launch."**
   Once a user calls `redeemInvite` they are an on-chain member
   (`SavingCircles.sol:190-213`). The contract has **no function that removes
   a member** — the only roster mutations are `create` (adds owner),
   `redeemInvite` (adds caller), and `decommission` (kills the whole circle).
   A member who was approved by mistake can only be dealt with by
   decommissioning and recreating the entire Stack.

2. **Approval integrity.** The invite signature covers only
   `Invite(uint256 id,uint256 nonce)` (`SavingCircles.sol:34`, `540-543`).
   It is a bearer token: *whoever* holds the signed payload becomes a member.
   In the current "hand each person their own private link" model that is
   acceptable. In an approval flow it is a hole: approval means *this specific
   person* passed review, but a forwarded or leaked link lets an unvetted
   wallet consume the nonce and take the approved slot — defeating the
   anti-sybil purpose of the whole flow.

Because the contract lives behind a proxy, fixing either point means shipping
a new implementation and upgrading. There is no admin setter, flag, or
off-chain workaround that produces these behaviours.

## 3. Contract changes (minimal set)

No storage additions. No struct changes. No `initialize` changes.

### 3.1 New function: `removeMember`

**Hard requirement: removal is only possible strictly before the Stack is
started.** The guard is `if (isActive[_id]) revert AlreadyActive()` —
`isActive` is set in exactly one place, `start()`
(`SavingCircles.sol:131`), so the window in which `removeMember` can
succeed closes atomically in the same transaction that starts the circle.
After `start`, every call reverts and the roster is immutable.

```solidity
/// @notice Owner removes a member from a circle that has not started yet.
function removeMember(uint256 _id, address _member) external onlyCommissioned(_id) {
  Circle storage _circle = circles[_id];
  if (msg.sender != _circle.owner) revert NotOwner();
  if (isActive[_id]) revert AlreadyActive();
  if (!isMember[_id][_member]) revert NotMember();
  if (_member == _circle.owner) revert InvalidMemberAddress();

  isMember[_id][_member] = false;
  delete _memberStates[_id][_member];

  // circleMembers[_id]: swap-and-pop; fix the swapped member's memberIndex
  // memberCircles[_member]: swap-and-pop _id out

  emit MemberRemoved(_id, _member);
}
```

Plus in `ISavingCircles`: the function signature and
`event MemberRemoved(uint256 indexed id, address indexed member);`.
All four errors used above already exist in the interface — no new errors.

**Why this is safe and small:**

- `deposit`/`depositFor` carry the `onlyActive` modifier
  (`SavingCircles.sol:136,141`), so **a circle that has not started holds no
  member funds**. Pre-launch removal is pure roster bookkeeping — no refund
  or balance-accounting logic is needed or included.
- The bookkeeping is the exact inverse of what `redeemInvite` writes at
  `SavingCircles.sol:206-210`: `isMember`, `circleMembers` (swap-and-pop with
  `memberIndex` fix-up for the swapped member), `_memberStates`, and
  `memberCircles` (otherwise `getMemberCircles` returns ghost circles).
- Swap-and-pop reorders `circleMembers`, which is safe **only because the
  function is gated to pre-launch**: payout rotation and round math bind to
  member order at `start` time; nothing reads the order before that.
- The `AlreadyActive` guard preserves the "roster locked after launch"
  acceptance criterion — the same guard `redeemInvite` already has
  (`SavingCircles.sol:196`).
- The removed member's redeemed nonce stays burned in `usedNonces`; to
  re-admit them the creator simply signs a fresh invite. No nonce recycling.

### 3.2 Address-bound invites

Change the typehash constant and the hash function (3 lines):

```solidity
// before: keccak256('Invite(uint256 id,uint256 nonce)')
bytes32 private constant _INVITE_TYPEHASH =
  keccak256('Invite(uint256 id,uint256 nonce,address member)');

function _hashInvite(uint256 _id, uint256 _nonce) private view returns (bytes32) {
  bytes32 _structHash = keccak256(abi.encode(_INVITE_TYPEHASH, _id, _nonce, msg.sender));
  return _hashTypedDataV4(_structHash);
}
```

`redeemInvite`'s signature and external ABI are unchanged. The EIP-712 domain
(`StacksInvite` / `1`) is untouched. The creator now signs the approved
user's wallet address into the invite at approval time; only that wallet can
redeem it.

The reference signing helper in this repo, `app/invites.tsx`, hardcodes the
old typehash (`INVITE_TYPEHASH = 0xd86e...`) and builds typed data with
`{ id, nonce }` — it must be updated to the new typehash and
`{ id, nonce, member }` message, together with `app/invites.test.ts`.

### 3.3 Tests

- `test/unit/SavingCirclesUnit.t.sol`: unit tests for `removeMember`
  (happy path incl. `memberIndex` fix-up of the swapped member; reverts:
  non-owner caller, active circle, non-member target, owner self-removal,
  decommissioned circle) and updated `redeemInvite` signature fixtures
  (member-bound digest; wrong-wallet redemption reverts `InvalidSigner`).
- `test/invariants/handlers/SavingCirclesHandler.sol`: add a `removeMember`
  action so invariants cover roster-shrinking (membership arrays and
  `memberIndex` stay consistent).
- `test/integration`: approve → redeem → remove → re-invite → `start` flow.

## 4. Why the upgrade is clean

Deployment uses an OpenZeppelin `TransparentUpgradeableProxy`
(`script/Common.sol:30`). An upgrade is safe iff the new implementation's
storage layout is compatible. This change set qualifies on inspection:

- **Zero new storage.** `removeMember` only writes to mappings that already
  exist. Functions, events, and errors live in implementation bytecode, not
  in the proxy's storage.
- **The typehash is a `constant`** (`SavingCircles.sol:34`) — inlined into
  bytecode, not a storage slot. Changing it cannot corrupt state.
- **EIP-712 domain state is untouched.** `__EIP712_init('StacksInvite','1')`
  already ran at proxy initialization; we change neither name nor version,
  so no re-initialization (`reinitializer`) is required. `initialize` is not
  modified.
- **Mechanical proof:** `forge inspect SavingCircles storage-layout` on `dev`
  vs. this branch must produce an identical layout. This check is a required
  step below, not an assumption.
- **`AutomaticSavingCircles` (Chainlink upkeep) is unaffected:** it operates
  on active circles only, and `removeMember` is pre-launch only, so the two
  never overlap. Its address holds a reference to the proxy, which does not
  change.

One deliberate breaking effect, contained to off-chain data:
**unredeemed old-format invite links stop working at the moment of upgrade**
(`InvalidSigner`), because the signed struct changes. This is intended — the
approval flow replaces those links — but it means the upgrade and the
app-stacks release that signs the new format must ship together, and any
outstanding pre-launch invites at that moment must be re-issued by their
creators. No on-chain state is affected; already-redeemed memberships are
untouched.

## 5. How the three layers together close issue #99

| Acceptance criterion | Layer that satisfies it |
| --- | --- |
| Shareable link opens a preview page, not an instant join | **App/Supabase** — link is a DB token (`share_token`) resolving to a public preview; no signature in the URL |
| Creator approval/rejection UI for pending members | **App/Supabase** — "request to join" writes a `pending` row; approval signs a member-bound invite (contract §3.2) and delivers it privately to that user only |
| Remove approved members before launch | **Contract §3.1** (`removeMember`) for members already on-chain; a DB status flip for members who have not redeemed yet |
| Removed members get a graceful notification | **App/Supabase** — `removed` status row drives the in-app notice |
| Creator can set a member cap | **App/Supabase** — enforced at approval time; consistent with the contract's existing stance (`redeemInvite`: "No max count validation, the owner issues a finite amount of invites") |
| Launch button disabled until minimum members reached | **App** reads `getCircleMembers(id).length`; the contract's `start` additionally enforces `MINIMUM_MEMBERS = 2` on-chain (`SavingCircles.sol:122`) |
| Roster locked after launch | **Contract** — already enforced (`redeemInvite` reverts `AlreadyActive`); `removeMember` gets the same guard |
| Link deactivated after launch | **App/Supabase** — `share_link_active` flag; on-chain invites die at launch automatically |

The contract's job in this flow is deliberately narrow: it is the
*enforcement* layer (who is a member, roster immutability after `start`,
invites usable only by the approved wallet). Vetting, pending queues, caps,
and link lifecycle are *policy* and live off-chain, where they can change
without another upgrade.

Sketch of the app-stacks side (specified here for context; implemented and
reviewed in that repo): add `share_token` / `share_link_active` /
`member_cap` / `creator_user_id` to `stacks_metadata`; add a
`status ∈ {pending, approved, joined, removed}` column to `user_stacks`; move
signed invites out of the publicly readable `invite_links` jsonb into a
service-role-only table so an approved user's link cannot be read and
front-run by anyone else; verify the Privy access token server-side on the
approve/remove routes and check the caller is the stack creator.

## 6. Execution path

1. **Implement** §3.1 + §3.2 on a feature branch off `dev`; update
   `ISavingCircles`, `app/invites.tsx`, `app/invites.test.ts`.
2. **Tests** per §3.3; full suite: `forge test` (unit, fuzz, integration,
   invariants).
3. **Layout check:** `forge inspect SavingCircles storage-layout` identical
   between `dev` and the branch (empty diff — hard gate for review).
4. **Review + merge** to `dev`.
5. **Upgrade tooling:** the validation/execution scripts
   (`UpgradeValidate.s.sol`, `UpgradeExecute.s.sol`,
   `UpgradePostValidate.s.sol`) currently live on the
   `104-deploy-guardrails` branch (commit `9f3de5f`), not on `dev` — merge or
   cherry-pick them first. `UpgradeExecute` already does the right thing:
   guardrail asserts (admin owner, current implementation, code at new
   address), then `ProxyAdmin.upgradeAndCall(proxy, newImpl, "")` — the empty
   calldata is correct because no re-initialization is needed.
6. **Deploy** the new implementation, run `UpgradeValidate` (read-only),
   execute `UpgradeExecute` as the ProxyAdmin owner, then
   `UpgradePostValidate`.
7. **Coordinate release:** ship the app-stacks change that signs
   member-bound invites in the same release window; creators re-issue any
   outstanding pre-launch invites.

## 7. Explicitly out of scope

- On-chain member cap or configurable minimum (`Circle` struct unchanged).
- Owner-side direct `addMembers` (approval without a user transaction).
  Approved members still redeem their own invite before launch. If that
  friction ever matters, it is a separate upgrade with its own spec.
- Any change to deposits, withdrawals, rounds, decommissioning, or the
  automation/viewer contracts.
