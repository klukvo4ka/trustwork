# Stage 4 — Reputation and soulbound receipts design

Status: Stage 4A design (accepted with the clarifications of Stage 4B). Slice 4B — registration, facts and
statistics — (accepted, `1cb0e3f`) and slice 4C — receipts, sections 6.2 and 6.3 — are implemented in
`src/TrustWorkReputation.sol`, `src/interfaces/ITrustWorkReputation.sol` and `src/interfaces/IERC5192.sol`. Decisions
U1, U2 and U6 are resolved as recommended (section 9).
Baseline: Stage 3E, commit `8c5549772b6561f0118644d8a71ee23d9e6cf205` (escrow, arbitration and production
integration accepted).

**Assumption** marks an input the design relies on; **Tradeoff** marks a deliberate choice with a stated cost;
**Limitation** marks a property the design does not provide. Everything else is a rule the implementation must
follow exactly.

## 1. Summary

- One new contract, `TrustWorkReputation`, bound at construction to one immutable `TrustWorkFactory`. No accepted
  contract changes. Escrow, court and registry never call it, so it cannot block settlement, resolution or claims.
- **Registration is permissionless** and records the outcome of a **final, genuine** TrustWork order: `Completed`, or
  `Terminated` with its cause read from the order and the court. Each order registers at most once.
- **Participation rule.** An order is eligible only if the freelancer demonstrably took part: at least one milestone
  was submitted, which only the freelancer can do. An unsolicited order the named freelancer never touched can
  never be registered, so it cannot affect that address.
- The record stores **facts** (outcome, milestone counts, amounts in the order's own token, exact and lower-bound
  timestamps) and updates **per-account, per-role counters**. No monetary amount is ever summed across orders. No
  composite score is stored; two documented ratios can be derived from the counters.
- Each participant (client and freelancer) may **claim** one optional, nontransferable **ERC-5192 receipt** per
  registered order. Receipts are minted without a receiver callback, are locked forever, and can be burned only by
  their holder; burning never changes records or counters.
- Registered history is **not** complete history: it contains only orders someone chose to register.

## 2. What the accepted contracts expose

Solidity cannot read historical events, so the design uses only on-chain state. After an order reaches `Completed` or
`Terminated`, every field listed here is final: no accepted function changes it afterwards.

| Source | Field | Final after | Meaning |
| --- | --- | --- | --- |
| `TrustWorkFactory` | `isWorkOrder(order)` | creation | order was created by this factory |
| `TrustWorkFactory` | `court()` | deployment | the factory's court |
| `WorkOrder` | `client`, `freelancer`, `token`, `feeBps`, `deliveryPeriod`, `totalAmount`, `court` | creation (immutable) | terms |
| `WorkOrder` | `status` | terminal state | `Completed` or `Terminated` |
| `WorkOrder` | `currentMilestone` | terminal state | settled milestone count (equals `milestoneCount` when `Completed`) |
| `WorkOrder` | `disputeId` | terminal state | `0` unless a dispute was opened |
| `WorkOrder` | `directPaid` | terminal state | gross amounts settled before termination |
| `WorkOrder` | `getMilestone(i)`: `amount`, `status`, `submittedAt`, `reviewDeadline`, `deliveryDeadline` | terminal state | per-milestone facts |
| `ArbitrationCourt` | `rulingOf(id)` | court `Resolved` | ruling and reason |
| `ArbitrationCourt` | `getDispute(id)`: `order`, `milestoneIndex`, `openedAt`, `panelDeadline`, `drawnAt`, `revealDeadline` | court `Resolved` | dispute facts |

**Not final and therefore never used:** `outstandingObligations`, `claimsPaid` and `claimable` change with every
claim after termination; court credits change with every `claimReward`. Using them would make the classification
depend on whether claims happened before registration.

**Derivable exactly:**

- `fundedAt = milestone[0].deliveryDeadline - deliveryPeriod` (milestone 0's deadline is set at funding).
- For every settled milestone `k` that is followed by another milestone,
  `settledAt(k) = milestone[k + 1].deliveryDeadline - deliveryPeriod`.
- `submittedAt(k)` for every submitted milestone (settlement does not clear it).

**Not available on-chain (missing information):**

- the settlement time of the **last** milestone of a `Completed` order, the time of delivery-expiry termination and
  the time `applyRuling` ran;
- the time `resolve` ran in the court (only its earliest permitted time is stored);
- the settlement path of a milestone (direct, signed or timeout): `settledAt >= reviewDeadline` is consistent with
  both a late direct approval and a timeout, so the design does not infer it;
- whether the freelancer agreed to the order before its first submission;
- anything about work quality.

Registration time is recorded as `registeredAt` and is never presented as the closing time. Where only a bound exists,
the record stores `closedNotBefore` (section 5).

## 3. Architecture and trust boundaries

```
TrustWorkFactory (accepted, immutable) <--isWorkOrder, court--- TrustWorkReputation (new, no owner)
      |                                                                |  reads (view calls only)
      +--creates--> WorkOrder (accepted) <-----------------------------+
      +--deploys--> ArbitrationCourt (accepted) <-- rulingOf / getDispute
```

- `TrustWorkReputation(TrustWorkFactory factory_)`: rejects a zero address (`ZeroFactory`) or an address without code
  (`FactoryHasNoCode`). `factory` is immutable. No owner, setter, pause, upgrade, fee, oracle or rescue function.
- It is deployed after the factory and is optional: escrow works the same with or without it.
- It makes only `view` calls (compiled to `STATICCALL`) to the factory, genuine orders and the factory's court.
  `STATICCALL` prevents the callee, and anything it calls, from changing state; it does not prevent a callee from
  reading this contract's views during the call. Registration writes its state only after its last external call,
  so such a read sees the order as unregistered, which is accurate at that point.
- **Assumption R1.** The factory, its orders and its court are the accepted Stage 3 bytecode. Authentication relies
  on `factory.isWorkOrder(order)`; an order's own `court()` must equal `factory.court()`, which is always true for
  factory orders and is checked as a consistency guard (`CourtMismatch`). The court's dispute record must name this
  order and its current milestone (`InconsistentDispute`), and the ruling and reason must be one of the four pairs
  the court can produce (`UnsupportedRuling`). These guards cannot fail with the accepted contracts; tests reach them
  with mocks.

**Tradeoff (standalone contract).** Recording inside `WorkOrder` would give complete history, but it would change
accepted money-handling code and make reputation a dependency of settlement. A standalone recorder cannot force
registration, so history is incomplete (section 7).

## 4. Eligibility and outcome classification

`register(order)` requires `factory.isWorkOrder(order)`. Orders from another factory, Stage 1/2 orders, directly
deployed `WorkOrder` contracts and arbitrary contracts are rejected with `UnknownOrder(order)` before any other call
is made to them.

**Participation evidence.** `milestone[0].status != Pending`. Only the freelancer can move a milestone out of
`Pending` (by submitting it), and milestones are sequential, so the first milestone's status is `Submitted`, `Settled`
or `Disputed` exactly when the freelancer submitted at least once. For an eligible terminal order it is `Settled`
(completion, or a dispute or expiry at a later milestone) or `Disputed` (a dispute at the first milestone). A delivery
expiry satisfies it only if an earlier milestone was submitted and settled (`currentMilestone > 0`).

The status is used rather than `submittedAt != 0` because a submission in a block with timestamp `0` would store
`submittedAt == 0`; the status cannot be confused that way. `submittedAt` is still reported as a fact
(`lastSubmittedAt`).

Let `k = currentMilestone`, `D = amount[k]` (dispute or expiry milestone), `S = directPaid`,
`R = totalAmount - S - D` (later milestones), `fee(x) = order.feeFor(x)`.

| Order state | Eligible | Outcome recorded | Factual record | Receipts | Counter effects (client role / freelancer role) |
| --- | --- | --- | --- | --- | --- |
| `Unfunded` | no (`OrderNotFinal`) | — | — | — | none |
| `Active` | no (`OrderNotFinal`) | — | — | — | none |
| `Disputed`, court not resolved | no (`OrderNotFinal`) | — | — | — | none |
| `Disputed`, court resolved, `applyRuling` not called | no (`OrderNotFinal`); anyone may call `applyRuling` first | — | — | — | none |
| `Completed` | yes (participation always holds) | `Completed` | `settledMilestones = milestoneCount`, `settledAmount = totalAmount`, `freelancerAwarded = totalAmount`, `clientReturned = 0` | client and freelancer may claim | `registered`, `completed`, `milestonesSettled += count` for both |
| `Terminated`, `disputeId == 0`, `k == 0` (first milestone still `Pending`) | **no** (`NoParticipation`) | — | — | — | none |
| `Terminated`, `disputeId == 0`, `k > 0` | yes | `DeliveryExpired` | `settledMilestones = k`, `settledAmount = S`, `freelancerAwarded = S`, `clientReturned = totalAmount - S` | both may claim | `registered`, `deliveryExpired`, `milestonesSettled += k` for both |
| `Terminated`, ruling `FreelancerWins` / `Majority` | yes | `FreelancerWins` | `settledMilestones = k`, `disputedAmount = D`, `freelancerAwarded = S + D`, `clientReturned = R` | both may claim | `registered`, `freelancerWins`, `milestonesSettled += k` for both |
| `Terminated`, ruling `ClientWins` / `Majority` | yes | `ClientWins` | `freelancerAwarded = S`, `clientReturned = D + R` | both may claim | `registered`, `clientWins`, `milestonesSettled += k` for both |
| `Terminated`, ruling `Split` / `NoDecision` | yes | `Split` | `freelancerAwarded = S + floor(D/2)`, `clientReturned = D - floor(D/2) + R` | both may claim | `registered`, `splits`, `milestonesSettled += k` for both |
| `Terminated`, ruling `FreelancerWins` / `NoPanel` | yes | `NoPanel` | `freelancerAwarded = S + D`, `clientReturned = R` | both may claim | `registered`, `noPanel`, `milestonesSettled += k` for both |

Rules:

- `NoPanel` is its own outcome. It is **not** counted as `FreelancerWins`: no panel judged the work. It records only
  that the submitted milestone was paid by the default rule of design §11.1 (Stage 3).
- `Completed` records that every milestone settled. It does not mean the work was good: any milestone may have been
  released by timeout without the client's approval, and the contracts do not say which.
- Amounts are gross order amounts in the order's token, before the protocol fee; the fee recipient's share is not
  attributed to anyone.
- A terminated order with `disputeId != 0` takes its ruling and reason from `court.getDispute(disputeId)` (the same
  values `rulingOf` returns); the implementation checks that the dispute's `order` is this order and its
  `milestoneIndex == k` (`InconsistentDispute`) and accepts only `FreelancerWins/Majority`, `ClientWins/Majority`,
  `Split/NoDecision` and `FreelancerWins/NoPanel` (`UnsupportedRuling` otherwise). A `Terminated` order with
  `disputeId == 0` was terminated by delivery expiry: no other accepted path reaches `Terminated` without a dispute.
- A `Completed` order has `currentMilestone == milestoneCount`; that path never reads `getMilestone(currentMilestone)`
  and takes `lastSubmittedAt` from the last milestone. A delivery expiry reads milestones `k` and `k - 1` (`k > 0` is
  guaranteed by the participation rule). Registration and `factsOf` read at most three milestones and never iterate
  over milestones or registered orders.
- **Claim independence.** The classification and every business fact use only the final fields of section 2, so
  registering before, between or after any `claimPayout` or `claimReward` yields the same outcome, facts, counters and
  order lists (test RE-13). `registeredAt` is the registration block's timestamp and naturally differs when
  registration happens at a different time; complete records are equal only when registration time is the same.

## 5. Stored data and metrics

### 5.1 Per-order record

Stored once at registration:

```solidity
enum Outcome { None, Completed, DeliveryExpired, FreelancerWins, ClientWins, Split, NoPanel }

struct OrderRecord {
    Outcome outcome;
    uint64 registeredAt;        // block.timestamp of registration; not the closing time
    uint8 receiptsClaimed;      // bit 0: client receipt minted, bit 1: freelancer receipt minted (slice 4C)
}
mapping(address order => OrderRecord) public records;
```

`outcome` and `registeredAt` are immutable after registration. Facts, counters and order lists never change through
receipt operations. `receiptsClaimed` is the only mutable part of a record: in slice 4C it gains a bit on the first
successful claim of each role and never clears, including on burn. In 4B no receipt exists and it is always `0`.

The remaining facts are final order and court state (section 2). They are returned by a view that recomputes
them, so they need no copy:

```solidity
struct OrderFacts {
    address client;
    address freelancer;
    address token;
    Outcome outcome;
    uint256 milestoneCount;
    uint256 settledMilestones;  // k, or milestoneCount when Completed
    uint256 totalAmount;
    uint256 settledAmount;      // directPaid
    uint256 disputedAmount;     // D for rulings and NoPanel, otherwise 0
    uint256 freelancerAwarded;  // gross: settledAmount plus the ruling's freelancer share of D
    uint256 clientReturned;     // totalAmount - freelancerAwarded
    uint256 disputeId;
    uint64 fundedAt;            // exact: milestone[0].deliveryDeadline - deliveryPeriod
    uint64 lastSubmittedAt;     // exact: submittedAt of the last submitted milestone
    uint64 closedNotBefore;     // lower bound of the closing time, see below
}
function factsOf(address order) external view returns (OrderFacts memory);
```

`closedNotBefore`: `Completed` → `lastSubmittedAt`; `DeliveryExpired` → `milestone[k].deliveryDeadline`; panel
rulings → the dispute's `revealDeadline`; `NoPanel` → `panelDeadline`. Every value is exact on-chain data, and the
true closing time lies in `[closedNotBefore, registeredAt]`.

`freelancerAwarded + clientReturned == totalAmount` holds for every outcome. Each value is at most `totalAmount`,
which itself fits in `uint256`, so no per-order arithmetic can overflow; `floor(D/2)` and `D - floor(D/2)` are exact.

**Tradeoff (recompute instead of copy).** The final state cannot change, so a view recomputes the same facts at
every call, and registration stores one slot per order instead of about ten. Test RE-13 checks that `factsOf` is
unchanged by later claims.

Timestamps are converted with checked `SafeCast.toUint64`: `fundedAt = milestone[0].deliveryDeadline -
deliveryPeriod` (checked subtraction), `registeredAt = block.timestamp`.

### 5.2 Per-account counters

```solidity
enum Role { Client, Freelancer }

struct Stats {
    uint256 registered;
    uint256 completed;
    uint256 deliveryExpired;
    uint256 freelancerWins;
    uint256 clientWins;
    uint256 splits;
    uint256 noPanel;
    uint256 milestonesSettled;
}
mapping(address account => mapping(Role role => Stats)) private _stats;          // read through statsOf
mapping(address account => mapping(Role role => address[])) private _orders;   // append-only, paged view
function statsOf(address account, Role role) external view returns (Stats memory);
```

| Counter | Source | Update at registration | Meaning |
| --- | --- | --- | --- |
| `registered` | registration | `+1` for the order's client (Client role) and freelancer (Freelancer role) | registered final orders in which the account had this role |
| `completed` | outcome `Completed` | `+1` | every milestone settled |
| `deliveryExpired` | outcome `DeliveryExpired` | `+1` | the client reclaimed after the freelancer had delivered at least once and then missed a delivery deadline |
| `freelancerWins` / `clientWins` | panel `Majority` rulings | `+1` | a formed panel decided for that side |
| `splits` | `Split` / `NoDecision` | `+1` | a formed panel did not reach two matching votes |
| `noPanel` | `NoPanel` | `+1` | no panel formed; default payment rule applied |
| `milestonesSettled` | `settledMilestones` | `+= settledMilestones` | milestones settled before the order ended |

The outcome counters partition `registered`:
`completed + deliveryExpired + freelancerWins + clientWins + splits + noPanel == registered`.

`_orders[account][role]` lists the registered orders in registration order, with
`ordersOf(account, role, offset, limit)` and `orderCount(account, role)`. `ordersOf` returns an empty array when
`limit == 0` or `offset >= length`, and otherwise `min(limit, length - offset)` entries starting at `offset`; it never
computes `offset + limit`, so `type(uint256).max` inputs cannot overflow. With these lists a consumer can recompute
any statistic restricted to tokens, counterparties or amounts it trusts.

**Numeric safety.** Counters only count. Each registration adds 1, or `settledMilestones`, which is at most the
order's milestone array length; reaching `2^256` would need more orders or milestones than can ever be created, so
checked arithmetic is used and can never revert in practice.

**No monetary aggregate.** The design stores no cumulative volume. Summing raw amounts across orders is wrong for
three reasons:

- it mixes tokens with different values and decimals, and decimals or symbols are not proof of value;
- arbitrary tokens make it trivially inflatable;
- two valid orders near `type(uint256).max` would overflow it and freeze registration.

A per-token sum would avoid mixing but not the overflow. Per-order amounts remain available through `factsOf` and
the order lists for off-chain aggregation with arbitrary-precision arithmetic.

### 5.3 Derived metrics (documented, not stored)

No composite score exists on-chain. Two ratios may be computed from the counters, and their meaning is stated
exactly:

- **Completion share** of an account in a role = `completed / registered`: among registered final orders in which
  the account had this role, the share in which every milestone settled. It is not a quality rating.
- **Adjudicated share for the freelancer side** = `freelancerWins / (freelancerWins + clientWins)` (undefined when the
  denominator is 0): among disputes that a formed panel decided by majority, the share decided for the freelancer.
  `Split` and `NoPanel` are excluded from both terms.

Both inherit the selection bias of section 7 and must be shown together with `registered`.

### 5.4 Worked examples

Order `[1000, 2500, 500]` USDC, `feeBps = 250`, client `C`, freelancer `F`.

| Case | Eligible | Outcome | settled | settledAmount | disputedAmount | freelancerAwarded | clientReturned | Counters (C as Client and F as Freelancer) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| all three settled | yes | `Completed` | 3 | 4000 | 0 | 4000 | 0 | registered 1, completed 1, milestonesSettled 3 |
| m0 settled, m1 never submitted, reclaimed | yes | `DeliveryExpired` | 1 | 1000 | 0 | 1000 | 3000 | registered 1, deliveryExpired 1, milestonesSettled 1 |
| funded, m0 never submitted, reclaimed | **no** | — | — | — | — | — | — | unchanged |
| m0 settled, m1 disputed, `FreelancerWins (Majority)` | yes | `FreelancerWins` | 1 | 1000 | 2500 | 3500 | 500 | registered 1, freelancerWins 1, milestonesSettled 1 |
| same, `ClientWins (Majority)` | yes | `ClientWins` | 1 | 1000 | 2500 | 1000 | 3000 | registered 1, clientWins 1, milestonesSettled 1 |
| same, `Split (NoDecision)` | yes | `Split` | 1 | 1000 | 2500 | 2250 | 1750 | registered 1, splits 1, milestonesSettled 1 |
| same, `FreelancerWins (NoPanel)` | yes | `NoPanel` | 1 | 1000 | 2500 | 3500 | 500 | registered 1, noPanel 1, milestonesSettled 1 |
| order `[7 units, 3000 USDC]`, m0 disputed, `Split` | yes | `Split` | 0 | 0 | 7 units | 3 units | 4 units + 3000 USDC | registered 1, splits 1, milestonesSettled 0 |
| any of the above registered a second time | — | reverts `AlreadyRegistered` | | | | | | unchanged |
| fee recipient equals `C` | as above | as above | | | | | | identical: the fee recipient is not a role and gets no counter or receipt |
| `F` is client of another order with `C'` | separate order | | | | | | | `F`'s Client-role stats change; its Freelancer-role stats do not |

Amounts in the table are in whole USDC except where units are given. Client and freelancer cannot be the same
address (Stage 1 rule), so one order never changes both roles of one account.

## 6. Registration and receipts API

```solidity
interface ITrustWorkReputation /* full design; 4B implements only the registration, facts and statistics members */ {
    event OrderRegistered(address indexed order, Outcome outcome, address indexed client, address indexed freelancer);
    event ReceiptClaimed(address indexed order, Role role, address indexed holder, uint256 tokenId);

    error ZeroFactory();
    error FactoryHasNoCode(address factory);
    error UnknownOrder(address order);
    error OrderNotFinal(address order, WorkOrder.OrderStatus status);
    error NoParticipation(address order);
    error CourtMismatch(address order, address orderCourt);
    error InconsistentDispute(address order, uint256 disputeId);
    error UnsupportedRuling(address order, IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason);
    error AlreadyRegistered(address order);
    error NotRegistered(address order);
    error NotRoleHolder(address order, Role role, address caller);
    error ReceiptAlreadyClaimed(address order, Role role);
    error ReceiptLocked(uint256 tokenId);
    error ApprovalsDisabled();

    function factory() external view returns (TrustWorkFactory);
    function register(address order) external returns (Outcome outcome);
    function claimReceipt(address order, Role role) external returns (uint256 tokenId);
    function burn(uint256 tokenId) external;

    function records(address order) external view returns (Outcome outcome, uint64 registeredAt, uint8 receiptsClaimed);
    function factsOf(address order) external view returns (OrderFacts memory);
    function statsOf(address account, Role role) external view returns (Stats memory);
    function orderCount(address account, Role role) external view returns (uint256);
    function ordersOf(address account, Role role, uint256 offset, uint256 limit) external view returns (address[] memory);
    function receiptId(address order, Role role) external pure returns (uint256);
    function receiptOf(uint256 tokenId) external view returns (address order, Role role);
}
```

`factsOf` and `claimReceipt` revert `NotRegistered` for an order that has not been registered; `receiptOf` reverts
`ERC721NonexistentToken` for an ID that is not currently minted.

**Implemented in 4B:** `factory`, `register`, `records`, `factsOf`, `statsOf`, `orderCount`, `ordersOf`,
`OrderRegistered` and the errors up to `NotRegistered`. **Not implemented (4C):** `claimReceipt`, `burn`,
`receiptId`, `receiptOf`, `ReceiptClaimed` and the receipt errors.

### 6.1 `register(order)`

```
require factory.isWorkOrder(order)                      else UnknownOrder        (before any call to order)
require records[order].outcome == None                  else AlreadyRegistered
require order.court() == factory.court()                else CourtMismatch
status = order.status()
require status == Completed or status == Terminated     else OrderNotFinal
require order.getMilestone(0).status != Pending         else NoParticipation
outcome = classify(order)                               (section 4; InconsistentDispute, UnsupportedRuling)
records[order] = (outcome, block.timestamp, 0)
statsOf[client][Client] += outcome; statsOf[freelancer][Freelancer] += outcome
_orders[client][Client].push(order); _orders[freelancer][Freelancer].push(order)
emit OrderRegistered
```

- **Who may register:** anyone, at any time after the order is final, including either party, the fee recipient or a
  third party. Registration needs no consent because the participation rule already requires the freelancer's own
  submission, and because restricting it to the favoured party would let each side register only good outcomes.
- **Duplicate protection:** `outcome != None` after the first registration; every later call reverts before any state
  change. The record is final.
- Registration makes no token transfer and no state-changing external call, so it needs no reentrancy guard. Its only
  external calls are `view` calls to the factory and to the order and court that the factory authenticated.
- The contract never calls or moves an ERC-20 token. In 4C its only token events are its own ERC-721 `Transfer`
  events for receipt mints and burns; no order, court or registry token moves.

### 6.2 Receipts

- **Recipients:** the order's client (`Role.Client`) and freelancer (`Role.Freelancer`), each at most one receipt per
  registered order. The fee recipient, arbitrators and third parties get none. The fee-recipient position grants no
  additional receipt; an address that is also the client or the freelancer keeps that role's ordinary entitlement.
- **Consent:** receipts are never pushed. `claimReceipt(order, role)` requires `msg.sender` to be that role's address;
  nobody can place a receipt in someone else's wallet. Claiming is optional and works for every outcome.
- **Token ID:** `receiptId(order, role) = (uint256(uint160(order)) << 1) | uint256(role)`. It is deterministic and
  unique per `(order, role)` because order addresses are unique, and it is computable off-chain before claiming.
  `receiptOf(tokenId)` inverts it for existing tokens.
- **Duplicate mint protection:** bit `role` of `records[order].receiptsClaimed` is set before minting; a second claim
  reverts `ReceiptAlreadyClaimed`, also after a burn, so a burned receipt can never be reissued.
- **Minting policy:** `_mint`, not `_safeMint`. No `onERC721Received` callback is made, so a contract wallet without
  `IERC721Receiver` can hold a receipt, and minting cannot re-enter anything. Because only the role holder can claim,
  a contract role holder that can make calls (for example a smart wallet) can claim; one that cannot initiate calls
  cannot hold a receipt, which affects nothing else. Order of operations: checks, set claim bit, `_mint`, emit
  `Locked(tokenId)` and `ReceiptClaimed`.
- **Isolation:** neither registration nor receipts are called by escrow, court or registry code, so no receipt
  failure or callback can affect settlement, resolution or claims (tests RU-01…RU-03).

### 6.3 ERC-721, ERC-165 and ERC-5192 behavior

Implemented on OpenZeppelin `ERC721` v5.6.1, which has no ERC-5192 support, so the interface is declared locally:

```solidity
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);
    function locked(uint256 tokenId) external view returns (bool);
}
```

| Item | Behavior |
| --- | --- |
| `supportsInterface` | `true` for ERC-165 (`0x01ffc9a7`), ERC-721 (`0x80ac58cd`), ERC-721 Metadata (`0x5b5e139f`) and ERC-5192 (`0xb45a3c0e`); `false` for `0xffffffff` and others |
| `locked(tokenId)` | `true` for every existing receipt; reverts `ERC721NonexistentToken` for a nonexistent or burned token (ERC-5192: queries about tokens assigned to the zero address throw) |
| `Locked` event | emitted once at mint, after `Transfer(0, holder, id)`; `Unlocked` is never emitted |
| `transferFrom`, both `safeTransferFrom` | revert `ReceiptLocked(tokenId)` through an `_update` override that allows only mint (`from == 0`) and burn (`to == 0`). The exact `ReceiptLocked` error applies to an existing token, an authorized holder and a nonzero recipient; the standard `ERC721NonexistentToken`, `ERC721InvalidReceiver` and authorization errors may come first otherwise |
| `approve`, `setApprovalForAll` | revert `ApprovalsDisabled`; `getApproved` returns `address(0)` for existing tokens and reverts for nonexistent ones; `isApprovedForAll` returns `false` |
| `burn(tokenId)` | holder only (`msg.sender == ownerOf(tokenId)`), no approved operators; emits `Transfer(holder, 0, id)`; records, counters and `receiptsClaimed` are unchanged |
| `balanceOf`, `ownerOf` | standard ERC-721 |
| `name`, `symbol` | `"TrustWork Receipt"`, `"TWR"` |
| `tokenURI` | returns `""` for existing tokens (standard nonexistent-token revert otherwise); structured data is on-chain through `receiptOf` and `factsOf` |

Everything a receipt describes is immutable: its `(order, role)` is fixed by its ID, and the order's facts are final.

**Tradeoff (burnable).** A holder can remove a receipt from their wallet, which respects consent. It cannot hide the
outcome, because records and counters stay and the receipt cannot be reissued. **Decision U1 (resolved in 4C):**
holders may burn their own receipts.

**Tradeoff (empty `tokenURI`).** On-chain JSON would need string and Base64 encoding code with little review value at
this stage; off-chain URIs would need an administrator. Wallets show the receipt without an image. **Decision U2
(resolved in 4C):** `tokenURI` is empty; an on-chain JSON `tokenURI` remains the optional slice 4D.

## 7. Griefing, consent, bias and manipulation

**Unsolicited orders.** `createWorkOrder` lets a client name any freelancer without that freelancer's consent. A
client can create, fund and reclaim such an order. Under this design:

- an order with no submission is never eligible (`NoParticipation`), so it changes no counter and yields no
  receipt, for the victim or anyone else;
- every other eligible outcome requires the freelancer's own `submitMilestone` call, which is the only on-chain
  evidence of participation the contracts provide;
- a client cannot open a dispute or reach `Completed` without a submission, so no outcome can be forced on a
  freelancer who never engaged.

**Limitation.** Participation is evidenced, not consent to every later outcome: a freelancer who submitted once and
then stopped delivering is recorded as `DeliveryExpired`, which is the intended factual record.

**Hiding outcomes.** Because anyone may register, a party cannot prevent registration of an outcome it dislikes, and
it cannot undo one. Each party can still decline to register its own unfavourable order. It can also hope nobody else
registers it.

**Selection bias.** Registration is voluntary and costs gas, so registered history over-represents orders that some
party wanted on record (typically completions registered by freelancers and losses registered by clients) and
under-represents everything else. Counters describe registered orders only, never all orders. `registered` should
always be shown, and no claim of completeness is made.

**Self-dealing and wash orders.** One person controlling a client and a freelancer address can create, fund, submit
and complete orders with a worthless token or one-unit milestones, inflating `completed` at the cost of gas. The
design does not prevent this and does not claim Sybil resistance. It makes such records inspectable: every order
lists its token, amounts and counterparty, so consumers can ignore tokens, counterparties or amounts they do not trust.
Address checks cannot detect common control (Stage 3 design §6.2).

**Arbitrary tokens.** Any ERC-20 with code can be an order token, including tokens whose transfers are worthless.
Registration never calls the token. The token's symbol and decimals are not read and are not evidence of value.

**Receipts are selectively held.** Holders choose which receipts to claim and can burn them, so a wallet's receipts
are a curated selection; the counters are the less biased view.

## 8. Limitations

- Registered history is incomplete and voluntarily selected; counters are statistics over registered orders only.
- No Sybil resistance, no proof of quality, no identity; wash orders are possible.
- `Completed` includes milestones released by timeout; the settlement path is not on-chain state.
- Closing times are only bounded (`closedNotBefore`, `registeredAt`).
- Orders that stay `Active` forever (nobody reclaims) or `Disputed` forever (nobody applies the ruling) never become
  eligible.
- Stage 1/2 orders and orders of any other factory cannot be registered.
- A contract role holder that cannot initiate calls cannot claim a receipt.

## 9. Decisions

| ID | Decision | Recommendation in this design |
| --- | --- | --- |
| U1 | Allow holder burn | yes; records unaffected, no reissue (resolved in 4C) |
| U2 | `tokenURI` content | empty in 4C; optional on-chain JSON later (resolved in 4C: empty) |
| U3 | Restrict registration to participants | no; permissionless, to limit hiding |
| U4 | Per-token monetary aggregates on-chain | no; off-chain from per-order facts |
| U5 | Client-role statistics | keep; same counters, separate role |
| U6 | Receipt for the fee recipient | no; not a participant (resolved in 4C: no additional receipt for the position) |

## 10. Implementation slices

| Slice | Content | Acceptance |
| --- | --- | --- |
| 4B (accepted, `1cb0e3f`) | `TrustWorkReputation` registration: factory binding, eligibility, participation rule, classification, `factsOf`, records, counters, order lists, events and errors; no ERC-721 | the 4B cases of test plan §11 pass, (2×) cases in both token configurations; escrow, court and registry counters and balances unchanged by registration; 100% line and branch coverage of the new contract; `forge fmt --check`, `forge build`, `forge test`, `forge coverage` reported |
| 4C (implemented) | Receipts: ERC-721 base, ERC-5192 `locked` and `Locked`, `claimReceipt`, deterministic IDs, `_update` lock, disabled approvals, holder burn, `supportsInterface`, empty `tokenURI` | the 4C cases of test plan §11 pass; no receipt operation can affect order or court state; runtime below 24,576 B; same command reporting |
| 4D (optional) | On-chain JSON `tokenURI` (decision U2) | only if authorized after 4C review |

Each slice is reviewed before the next begins. Accepted contracts (`WorkOrder`, `TrustWorkFactory`,
`ArbitrationCourt`, `ArbitratorRegistry`, their interfaces, `PanelSelection`) do not change in any slice. Detailed
cases: [stage-4-test-plan.md](stage-4-test-plan.md).
