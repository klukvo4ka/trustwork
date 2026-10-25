# Stage 3 — Arbitration design

Status: Stage 3A design (revision 2, accepted at `f0a1c1b`) with narrow corrections made during slice S1. Slice S1
(Stage 3B) and the registry of slice S2 (Stage 3C) are implemented; sections describing the court and disputes are
not.
Baseline: Stage 2, commit `5746ac19e947d4c72b5dbfcf518e4b05ba199165`. Revision 1: `8a3995e`. Section 15 maps the
review findings R1–R6 to the sections that resolve them.

This document fixes one recommended design. **Assumption** marks an input the design relies on; **Tradeoff** marks a
deliberate choice with a stated cost; **Limitation** marks a property the design does not provide. Everything else
is a rule the implementation must follow exactly.

## 1. Summary

- A client may dispute a **submitted** milestone before its review deadline. A dispute **terminates the order**: the
  disputed milestone is paid according to the ruling and every unstarted milestone is refunded to the client.
- A per-order **delivery period** bounds how long the current milestone may stay unsubmitted. After it expires the
  client can reclaim the unsettled budget.
- Every payout after termination, including the delivery-expiry refund, is a **credit claimed separately**
  (`claimPayout`). A blocked recipient never blocks another party or the termination itself.
- Arbitration is an **ArbitrationCourt** with a stake **ArbitratorRegistry**. When a dispute opens, the registry
  stores a **candidate snapshot** and **reserves** `seatLock` of each candidate's stake, before any seed exists. A
  later blockhash selects 3 distinct candidates uniformly from the stored snapshot; the rest are released. Registry
  changes after the snapshot cannot change the candidate set or make a selected candidate unavailable.
- Panelists commit, then reveal a binary vote. **Two matching valid reveals** decide. A formed panel without a
  decision gives a 50/50 **Split**. If **no panel forms**, the submitted work is paid as if it had not been disputed
  (`FreelancerWins` with reason `NoPanel`) and the dispute fee is refunded to the client.
- Arbitrators are rewarded for valid reveals and penalized only for **objectively observable faults**. Minority votes
  are not slashed. Penalties are not a quantified security guarantee (section 10).
- New orders opt in by being created through the Stage 3 factory, which deploys the court, which deploys the
  registry. No contract has an owner or an upgrade path. Stage 1/2 orders are unaffected.

## 2. Parameters

| Name | Kind | Value | Purpose |
| --- | --- | --- | --- |
| `PANEL_SIZE` | court constant | `3` | Seats per dispute |
| `DECISION_THRESHOLD` | court constant | `2` | Matching valid reveals needed for a decision |
| `SELECTION_DELAY_BLOCKS` | court constant | `10` | Blocks between snapshot (or re-arm) and the seed block |
| `PANEL_PERIOD` | court constant | `3 days` | Time from opening to form a panel |
| `COMMIT_PERIOD` | court constant | `2 days` | Commit phase length |
| `REVEAL_PERIOD` | court constant | `1 days` | Reveal phase length |
| `ACTIVATION_DELAY` | registry constant | `2 days` | Deposit warm-up before stake can back a candidacy |
| `MAX_ARBITRATORS` | registry constant | `32` | Bound on listed accounts and on candidates per snapshot |
| `MAX_DELIVERY_PERIOD` | order constant | `180 days` | Upper bound for `deliveryPeriod` |
| `disputeFee` (`F`) | court immutable | `> 0` (testnet default 20 USDC) | Paid by the client on opening |
| `seatLock` (`L`) | court immutable | `> 0` (testnet default 100 USDC) | Reservation and lock per candidacy/seat; listing minimum; fault penalty |
| `penaltyRecipient` | court immutable | nonzero | Receives penalties, unearned fees and dust |
| `deliveryPeriod` | order immutable | `0 < p <= MAX_DELIVERY_PERIOD` | Time to submit the current milestone |

Stage 1/2 parameters (`feeBps <= 1000`, `0 < reviewPeriod <= 30 days`) are unchanged.

**Assumption A1 (tokens).** The court's `stakeToken` is one exact-transfer ERC-20 used for stakes, dispute fees,
rewards and penalties. It does not block transfers between the registry, the court and ordinary accounts. Order
payment tokens follow the Stage 1 assumptions. The payment token and `stakeToken` **may be the same ERC-20 or
different ones**; nothing in the design infers the purpose of funds from the token address (section 11.4).

**Tradeoff (no governance token).** Stakes use an existing stablecoin. A protocol token would add issuance, pricing
and governance questions without improving the security of a testnet court.

## 3. Order lifecycle

### 3.1 States and storage

`OrderStatus`: `Unfunded`, `Active`, `Disputed`, `Completed`, `Terminated`.
`MilestoneStatus`: `Pending`, `Submitted`, `Settled`, `Disputed`.

`Milestone` gains `deliveryDeadline` (`uint64`). Milestones after a terminated order's current milestone keep status
`Pending`; the terminal order status voids them. No per-milestone loop runs on termination.

New storage: `deliveryPeriod` (immutable), `court` (immutable), `disputeId`, `claimable[address]`, `directPaid`,
`claimsPaid`.

`outstandingObligations` in every state:

| Status | `outstandingObligations` |
| --- | --- |
| `Unfunded` | `0` |
| `Active` | sum of unsettled milestone amounts |
| `Disputed` | sum of unsettled milestone amounts (`D + R`, section 3.6) |
| `Completed` | `0` |
| `Terminated` | sum of unclaimed `claimable` credits |

### 3.2 Who can dispute, and when

- **Only the client**, only on the **current** milestone, only while it is **`Submitted`**, and only while
  `block.timestamp < reviewDeadline`.
- The freelancer does not need a dispute: submitted work is approved or released by timeout, and the client can only
  reclaim **unsubmitted** milestones after delivery expiry, which is objective.
- A client unhappy before submission has no dispute; they wait for submission or for delivery expiry.

### 3.3 Freelancer never submits

The current milestone's `deliveryDeadline` is set when it becomes current: at funding for milestone `0`
(`fundedAt + deliveryPeriod`), at settlement of `k - 1` for milestone `k` (`settledAt + deliveryPeriod`).

Submission requires `block.timestamp < deliveryDeadline`. From `block.timestamp >= deliveryDeadline`, if the current
milestone is still `Pending`, the client may call `reclaimAfterDeliveryExpiry()`. It terminates the order and
credits all unsettled amounts to the client, who (or anyone on their behalf) then calls `claimPayout(client)`.

**Required behavior change.** Without delivery expiry a non-submitting freelancer locks the budget forever, and
arbitration cannot help because nothing was submitted. General cancellation is not part of Stage 3.

### 3.4 Disputed work is not resubmitted

A dispute is terminal for the order; there is no resubmission, appeal or continuation.

**Tradeoff.** Continuing would need revised-work submissions, a second review cycle, a second signature rule and
possibly several disputes per order. Termination keeps at most one dispute per order and a finite money flow per
outcome.

### 3.5 Blocked actions while `Disputed`

`fund`, `fundWithPermit`, `submitMilestone`, `approveMilestone`, `approveMilestoneBySignature`, `finalizeMilestone`,
`reclaimAfterDeliveryExpiry`, `openDispute` and `claimPayout` revert with `InvalidOrderStatus(Disputed)`. Only
`applyRuling` changes state, and only after the court has a ruling.

### 3.6 Remaining milestones after each outcome

Current milestone `k`, `D = amount[k]`, `R = sum(amount[i] for i > k)`, `fee(x) = Math.mulDiv(x, feeBps, 10_000)`
(Stage 1 rounding, down).

| Terminal path | Milestone `k` | Milestones `> k` |
| --- | --- | --- |
| `Completed` | settled normally | none |
| Delivery expiry at `k` | credited to client | credited to client |
| `FreelancerWins` (`Majority` or `NoPanel`) | freelancer `D - fee(D)`, fee recipient `fee(D)` | credited to client |
| `ClientWins` (`Majority`) | credited to client | credited to client |
| `Split` (`NoDecision`) | freelancer `floor(D/2) - fee(floor(D/2))`, fee recipient `fee(floor(D/2))`, client `D - floor(D/2)` | credited to client |

### 3.7 Order transition table

All functions are `nonReentrant`. "Next" means: if `k + 1 == milestoneCount` then `status = Completed`, otherwise
`currentMilestone = k + 1` and `milestones[k + 1].deliveryDeadline = now + deliveryPeriod`.

| # | Function | Actor | Preconditions | State updates | Tokens | Events |
| --- | --- | --- | --- | --- | --- | --- |
| O1 | `fund()` / `fundWithPermit(...)` | client | `Unfunded` | `Active`; `outstanding = total`; `m[0].deliveryDeadline` | client → order `total`, exact balance check | `Funded` |
| O2 | `submitMilestone(k)` | freelancer | `Active`; `k == current`; `m[k] Pending`; `now < m[k].deliveryDeadline` | `m[k] Submitted`; `submittedAt`; `reviewDeadline = now + reviewPeriod` | none | `MilestoneSubmitted` |
| O3 | `approveMilestone(k)` | client | `Active`; `k == current`; `m[k] Submitted` | `m[k] Settled`; `outstanding -= D`; `directPaid += D`; `approvalNonce++`; next | order → fee recipient `fee(D)` if > 0; order → freelancer `D - fee(D)` | `MilestoneSettled`, maybe `OrderCompleted` |
| O4 | `approveMilestoneBySignature(k, n, d, sig)` | anyone | O3 preconditions; `now <= d`; `n == approvalNonce`; valid client signature | as O3 | as O3 | `MilestoneApprovedBySignature`, `MilestoneSettled`, maybe `OrderCompleted` |
| O5 | `finalizeMilestone(k)` | anyone | O3 preconditions; `now >= m[k].reviewDeadline` | as O3 | as O3 | `MilestoneSettled` (`byTimeout`), maybe `OrderCompleted` |
| O6 | `openDispute(k)` | client | `Active`; `k == current`; `m[k] Submitted`; `now < m[k].reviewDeadline` | `Disputed`; `m[k] Disputed`; `approvalNonce++`; then `disputeId = court.openDispute(k)` | client → court `F` (pulled by the court, exact balance check) | `DisputeOpened(k, disputeId, consumedNonce)` |
| O7 | `reclaimAfterDeliveryExpiry()` | client | `Active`; `m[current] Pending`; `now >= m[current].deliveryDeadline` | `Terminated`; `approvalNonce++`; `claimable[client] += outstanding`; `outstanding` unchanged | none | `DeliveryExpired(current, credit)` |
| O8 | `applyRuling()` | anyone | `Disputed`; court ruling recorded | `Terminated`; credits per section 11.1; `outstanding` unchanged | none | `RulingApplied(disputeId, ruling, reason, clientCredit, freelancerCredit, feeCredit)` |
| O9 | `claimPayout(account)` | anyone | `Terminated`; `claimable[account] > 0` | `claimable[account] = 0`; `outstanding -= amount`; `claimsPaid += amount` | order → `account` | `PayoutClaimed(account, amount)` |

`openDispute` updates status, milestone status and nonce before calling the court and stores the returned
`disputeId` afterwards; re-entry during the call is blocked by the order guard. A failed fee pull reverts the whole
transaction, leaving the order `Active` with its nonce unchanged.

`claimPayout` pays `account`, not the caller, so a contract wallet that cannot initiate calls can still be paid. A
reverting transfer reverts only that claim and leaves the credit for a retry.

## 4. Deadline boundaries

All comparisons use `block.timestamp` (`now`) or `block.number`. Every transaction in a block sees the same values,
so the conditions in each row are mutually exclusive. When two conflicting transactions are valid at the same
instant, the one ordered first succeeds and the second reverts on its state precondition. Nothing executes
automatically: every timeout needs an on-chain caller.

| Boundary | Valid strictly before | Valid at and after |
| --- | --- | --- |
| Delivery, `deliveryDeadline` | `submitMilestone` | `reclaimAfterDeliveryExpiry` (milestone `Pending`) |
| Review, `reviewDeadline` | `openDispute` | `finalizeMilestone` |
| Approval signature, `deadline` | relay while `now <= deadline` (inclusive) | expired from `now > deadline` |
| Panel, `panelDeadline = openedAt + PANEL_PERIOD` | `retrySnapshot`, `drawPanel` | `resolve` with `NoPanel` (status `AwaitingCandidates` or `AwaitingSeed`) |
| Seed block, `selectionBlock` | `drawPanel` reverts while `block.number <= selectionBlock` | `drawPanel` allowed from `block.number > selectionBlock` |
| Commit, `commitDeadline = drawnAt + COMMIT_PERIOD` | `commitVote` (`drawnAt <= now`) | reveal phase |
| Reveal, `revealDeadline = commitDeadline + REVEAL_PERIOD` | `revealVote` (`commitDeadline <= now`) | `resolve` |
| Activation, `warmingUntil = depositAt + ACTIVATION_DELAY` | warming stake cannot back a candidacy | can back a candidacy in snapshots taken at `now >= warmingUntil` |

Withdrawals have no delay: free stake (section 8) can be withdrawn at any time, and stake backing a reservation or a
seat cannot.

Consequences:

- At `reviewDeadline - 1` approval and dispute are both valid; the first wins. At `reviewDeadline` a dispute reverts
  with `ReviewPeriodElapsed`; approval and finalization remain.
- At `deliveryDeadline` submission reverts with `DeliveryPeriodElapsed`; reclaim succeeds.
- `retrySnapshot`/`drawPanel` and a `NoPanel` resolve never overlap. Commit and reveal phases never overlap and never
  end early.
- Locks and reservations release only when `drawPanel` or `resolve` executes.

## 5. Signature invalidation

### 5.1 Revised invariant

Stage 2: `approvalNonce == currentMilestone == settledCount`. Stage 3:

```
settledCount == currentMilestone                     (Completed: == milestoneCount)
approvalNonce == settledCount + (status == Disputed || status == Terminated ? 1 : 0)
```

`openDispute` and `reclaimAfterDeliveryExpiry` each increment the nonce once; `applyRuling` and `claimPayout` do not.
Failed transactions leave it unchanged.

### 5.2 Why old signatures cannot revive

- A signature for disputed milestone `k` carries nonce `k`; after `openDispute` the nonce is `k + 1`.
- A pre-signed approval for milestone `j > k` with nonce `j` can match numerically (`j == k + 1`), but the order is
  `Disputed` or `Terminated` forever and milestone `j` never becomes current. The **terminal status**, not the nonce
  alone, invalidates it.
- There is no resubmission, so there is no revised work for an old signature to approve.

### 5.3 Message and domain

`ApproveMilestone(uint256 milestoneIndex,uint256 nonce,uint256 deadline)` and the domain (`TrustWork`, `1`, `chainId`,
`verifyingContract`) do not change: Stage 3 orders are new contracts, and section 5.2 makes old signatures unusable.

**Constraint for later stages.** A design that resumes an order after a dispute must change the message (for example
add a round counter) or bump the domain version, because the numeric collision in 5.2 would become exploitable.

## 6. Contract boundaries

### 6.1 Deployment and authentication

```
TrustWorkFactory --constructor deploys--> ArbitrationCourt --constructor deploys--> ArbitratorRegistry
      | creates WorkOrder(court)                ^   | onlyCourt: reserveCandidates, selectPanel,
      v                                         |   v            releaseReservations, releaseSeat
  WorkOrder --openDispute / rulingOf------------+   stake ledger, candidate snapshots
```

- `registry.court` is immutable (the deploying court). Every snapshot and seat function reverts unless
  `msg.sender == court`.
- `court.factory` is immutable (the deploying factory). `court.openDispute` reverts with `UnknownOrder` unless
  `factory.isWorkOrder(msg.sender)`. The court reads `client`, `freelancer` and `feeRecipient` from the order.
- `WorkOrder.court` is immutable. The order uses only the `disputeId` returned by its own call and reads
  `court.rulingOf(disputeId)`; it never accepts a ruling as an argument.
- No contract has an owner, pause, parameter setter, upgrade hook or token-rescue function.

Bytecode baseline (Stage 2 build): factory runtime 10,054 B, WorkOrder initcode 9,274 B. The factory's initcode will
embed court and registry initcode and must stay under 49,152 B (EIP-3860); runtimes under 24,576 B (EIP-170). Slice
S4 measures both.

### 6.2 Enforceable address restrictions

| Restriction | Where enforced | Error |
| --- | --- | --- |
| `penaltyRecipient` cannot deposit into the registry | registry `deposit` | `PenaltyRecipientCannotStake` |
| `penaltyRecipient` cannot be client, freelancer or fee recipient of a Stage 3 order | factory `createWorkOrder` | `PenaltyRecipientIsParty` |
| Client, freelancer and fee recipient are never candidates in their own dispute | registry `reserveCandidates` (exclusion list) | — |
| One seat per address per dispute | snapshot entries are distinct listed addresses | — |
| Client and freelancer differ | order constructor (Stage 1) | `ClientIsFreelancer` |
| Fee recipient is not the order itself | order constructor (S1) | `FeeRecipientIsOrder` |
| `penaltyRecipient` is neither the court nor the registry | registry constructor (S2) | `PenaltyRecipientIsProtocol` |

**Limitation.** These are address checks. Nothing on-chain can detect that different addresses share a controller:
a party, an arbitrator and `penaltyRecipient` may be the same person behind different addresses.

The self-fee-recipient check (implemented in S1) exists because an ERC-20 transfer from the order to itself does not
reduce its balance: a 1,000-unit settlement with a 100-unit fee directed to the order would record 1,000 in
`directPaid` and zero obligations while 100 stays locked. The fee recipient may still equal the client or the
freelancer, and may be any other contract. Role addresses are **not** prevented from equaling the court or registry
address; section 11.4 states why that does not create liabilities.

### 6.3 Interfaces

```solidity
interface IArbitratorRegistry {
    enum CandidateState { None, Reserved, Unselected, Locked, Released }
    enum SnapshotState { None, Reserved, Selected, Released }

    struct Account {
        uint256 stake;        // matured principal; includes locked and reserved amounts
        uint256 warming;      // deposited, not matured
        uint256 locked;       // seatLock per Locked candidacy
        uint256 reserved;     // seatLock per Reserved candidacy
        uint64 warmingUntil;
        bool listed;
    }

    struct Candidate {
        address arbitrator;
        CandidateState state;
    }

    event Deposited(address indexed arbitrator, uint256 amount, uint256 warmingUntil);
    event Withdrawn(address indexed arbitrator, uint256 amount);
    event Listed(address indexed arbitrator);
    event Delisted(address indexed arbitrator);
    event CandidatesReserved(uint256 indexed disputeId, address[] candidates);
    event PanelSelected(uint256 indexed disputeId, uint256[3] candidateIndexes);
    event ReservationsReleased(uint256 indexed disputeId);
    event SeatReleased(uint256 indexed disputeId, address indexed arbitrator, uint256 penalty);

    function stakeToken() external view returns (IERC20);
    function court() external view returns (address);
    function seatLock() external view returns (uint256);
    function penaltyRecipient() external view returns (address);
    function totalStaked() external view returns (uint256);           // sum(stake + warming)
    function depositsReceived() external view returns (uint256);
    function withdrawalsPaid() external view returns (uint256);
    function penaltiesSent() external view returns (uint256);
    function listedCount() external view returns (uint256);
    function listedAccounts() external view returns (address[] memory);   // listing order; added in S2 for tests
    function accountOf(address arbitrator) external view returns (Account memory);
    function freeStake(address arbitrator) external view returns (uint256);
    function candidatesOf(uint256 disputeId) external view returns (Candidate[] memory);
    function snapshotState(uint256 disputeId) external view returns (SnapshotState);

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;

    function reserveCandidates(uint256 disputeId, address[3] calldata excluded) external returns (uint256 count);
    function selectPanel(uint256 disputeId, bytes32 seed)
        external
        returns (uint256[3] memory candidateIndexes, address[3] memory panel);
    function releaseReservations(uint256 disputeId) external;
    function releaseSeat(uint256 disputeId, uint256 candidateIndex, uint256 penalty) external;
}

interface IArbitrationCourt {
    enum DisputeStatus { None, AwaitingCandidates, AwaitingSeed, Voting, Resolved }
    enum Vote { None, Freelancer, Client }
    enum Ruling { None, FreelancerWins, ClientWins, Split }
    enum RulingReason { None, Majority, NoPanel, NoDecision }

    struct Seat {
        address arbitrator;
        uint256 candidateIndex;
        bytes32 commitment;
        Vote vote;            // None until a valid reveal
    }

    struct Dispute {
        address order;
        address client;
        address freelancer;
        address feeRecipient;
        uint256 milestoneIndex;
        DisputeStatus status;
        Ruling ruling;
        RulingReason reason;
        uint64 openedAt;
        uint64 panelDeadline;
        uint64 drawnAt;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint256 selectionBlock;
    }

    event DisputeOpened(uint256 indexed disputeId, address indexed order, uint256 milestoneIndex, uint256 candidates);
    event CandidatesPending(uint256 indexed disputeId, uint256 eligibleCount);
    event SelectionArmed(uint256 indexed disputeId, uint256 selectionBlock);
    event PanelDrawn(uint256 indexed disputeId, address[3] panel, uint256 commitDeadline, uint256 revealDeadline);
    event VoteCommitted(uint256 indexed disputeId, address indexed arbitrator);
    event VoteRevealed(uint256 indexed disputeId, address indexed arbitrator, Vote vote);
    event DisputeResolved(
        uint256 indexed disputeId, Ruling ruling, RulingReason reason, uint256 validReveals, uint256 rewardPerReveal,
        uint256 penalties, uint256 feeRefund
    );
    event RewardClaimed(address indexed account, uint256 amount);

    function factory() external view returns (address);
    function registry() external view returns (IArbitratorRegistry);
    function stakeToken() external view returns (IERC20);
    function disputeFee() external view returns (uint256);
    function penaltyRecipient() external view returns (address);
    function claimable(address account) external view returns (uint256);
    function pendingFees() external view returns (uint256);
    function totalClaimable() external view returns (uint256);
    function feesReceived() external view returns (uint256);
    function penaltiesReceived() external view returns (uint256);
    function claimsPaid() external view returns (uint256);
    function getDispute(uint256 disputeId) external view returns (Dispute memory);
    function getSeats(uint256 disputeId) external view returns (Seat[3] memory);
    function rulingOf(uint256 disputeId) external view returns (Ruling ruling, RulingReason reason);
    function voteCommitment(uint256 disputeId, address arbitrator, uint8 vote, bytes32 salt)
        external
        view
        returns (bytes32);

    function openDispute(uint256 milestoneIndex) external returns (uint256 disputeId); // genuine orders only
    function retrySnapshot(uint256 disputeId) external;
    function drawPanel(uint256 disputeId) external;
    function commitVote(uint256 disputeId, bytes32 commitment) external;
    function revealVote(uint256 disputeId, uint8 vote, bytes32 salt) external;
    function resolve(uint256 disputeId) external;
    function claimReward(address account) external returns (uint256 amount);
}
```

`WorkOrder` additions (Stage 1/2 functions keep their signatures):

```solidity
uint256 public constant MAX_DELIVERY_PERIOD = 180 days;
IArbitrationCourt public immutable court;
uint256 public immutable deliveryPeriod;
uint256 public disputeId;
uint256 public directPaid;
uint256 public claimsPaid;
mapping(address account => uint256) public claimable;

event DisputeOpened(uint256 indexed index, uint256 indexed disputeId, uint256 consumedNonce);
event DeliveryExpired(uint256 indexed index, uint256 clientCredit);
event RulingApplied(
    uint256 indexed disputeId, IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason,
    uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit
);
event PayoutClaimed(address indexed account, uint256 amount);

error InvalidDeliveryPeriod(uint256 deliveryPeriod);
error DeliveryPeriodElapsed(uint256 index, uint256 deliveryDeadline);
error DeliveryPeriodNotElapsed(uint256 index, uint256 deliveryDeadline);
error ReviewPeriodElapsed(uint256 index, uint256 reviewDeadline);
error RulingNotReady(uint256 disputeId);
error NothingToClaim(address account);

function openDispute(uint256 index) external;
function reclaimAfterDeliveryExpiry() external;
function applyRuling() external;
function claimPayout(address account) external returns (uint256 amount);
```

`directPaid` accumulates every settlement transfer (O3–O5); `claimsPaid` accumulates every `claimPayout`. Both exist
for the conservation equation in section 11.4. The constructor gains `IArbitrationCourt court_` and
`uint256 deliveryPeriod_`, rejecting a zero court and an invalid delivery period.

`TrustWorkFactory` (Stage 3):

```solidity
constructor(IERC20 stakeToken, uint256 disputeFee, uint256 seatLock, address penaltyRecipient);
function court() external view returns (IArbitrationCourt);
function isWorkOrder(address order) external view returns (bool);
function createWorkOrder(
    address freelancer,
    IERC20 token,
    address feeRecipient,
    uint256 feeBps,
    uint256 reviewPeriod,
    uint256 deliveryPeriod,
    uint256[] calldata milestoneAmounts
) external returns (WorkOrder order);
```

`WorkOrderCreated` gains `deliveryPeriod`. The court constructor validates `stakeToken` (nonzero, has code),
`disputeFee > 0`, `seatLock > 0`, `penaltyRecipient != address(0)`, and passes `stakeToken`, `seatLock` and
`penaltyRecipient` to the registry it deploys.

**Slice S1 note.** S1 has no court. Its `WorkOrder` takes `deliveryPeriod` only; the `court` argument,
`openDispute` and `applyRuling` arrive in S4. The S1 factory takes the delivery period as a parameter and has no
constructor arguments.

### 6.4 Opt-in and existing orders

Stage 1/2 orders keep their behavior forever, including possible locking when the freelancer never submits. Only
orders from a Stage 3 factory have delivery expiry and disputes. The Stage 3 factory does not adopt earlier orders.

### 6.5 Reentrancy and duplicate execution

- Every state-changing function in all three contracts is `nonReentrant` and follows checks-effects-interactions.
- Cross-contract calls: order → court (`openDispute`, after order state updates); court → order (view reads); court
  → registry (after court state updates); registry → token.
- `resolve` writes ruling, status, credits and counters before calling `registry.releaseSeat`. A token callback that
  re-enters the court is blocked by its guard; one that calls `order.applyRuling` sees the ruling already recorded.
- Duplicates revert on recorded state: `retrySnapshot` (status `AwaitingCandidates`), `drawPanel` (status
  `AwaitingSeed`), `resolve` (not `Resolved`), `applyRuling` (order `Disputed`), claims (nonzero credit). The registry
  independently rejects a second `reserveCandidates`, `selectPanel` or `releaseReservations` for the same dispute
  (`SnapshotState`) and any `releaseSeat` whose candidate is not `Locked` (`UnknownSeat`), including a second release
  and an out-of-range index.

## 7. Arbitrator registry and selection

### 7.1 Accounts and listing

```
free(account) = stake + (warmingUntil <= now ? warming : 0) - locked - reserved
```

Invariants: `locked + reserved <= stake`; `listed` iff `stake + warming >= seatLock`; `listedCount <= 32`.

- **Admission.** `deposit(amount)` by an unlisted account requires `stake + warming + amount >= seatLock`
  (`BelowListingMinimum`) and `listedCount < MAX_ARBITRATORS` (`RegistryFull`); the account is then listed. A listed
  account may deposit any positive amount. Deposits use an exact balance check, add to `warming` and set
  `warmingUntil = now + ACTIVATION_DELAY` for the whole warming bucket (already matured warming is first moved into
  `stake`).
- **Withdrawal.** `withdraw(amount)` requires `0 < amount <= stake - locked - reserved` after maturing; warming stake
  is not withdrawable. There is no request step or delay.
- **Automatic delisting.** Every transition that reduces `stake + warming` (`withdraw`, `releaseSeat` with a penalty)
  delists the account by swap-and-pop if `stake + warming < seatLock`. No manual call and no top-up is needed to free
  a slot; the listing invariant above therefore always holds.
- **Delisted accounts** keep their remaining balance in the mapping and may withdraw it at any time. They never hold
  reservations or locks: if `stake + warming < seatLock`, then `locked + reserved <= stake < seatLock`, and both are
  multiples of `seatLock`, so both are 0.
- **Slot reuse.** Snapshots store addresses, never list positions, so swap-and-pop and later reuse of a slot cannot
  change any snapshot. An address whose candidate entry is still `Reserved` or `Locked` has a matching reservation
  or lock and is therefore still listed. Historical `Unselected` and `Released` entries carry no stake and may refer
  to addresses that have since been delisted or whose slot has been reused.

Cost of occupying all slots: each listed account must keep `stake + warming >= seatLock`, so holding 32 slots needs
at least `32 * seatLock` of capital for as long as they are held (recoverable on exit).

### 7.2 Snapshot and reservation (before the seed)

`reserveCandidates(disputeId, [client, freelancer, feeRecipient])`, called by the court inside `openDispute` and
`retrySnapshot`:

1. Load every listed account (at most 32) into memory and compute `free` at the current `now`.
2. Candidates are the listed accounts with `free >= seatLock` that are not excluded, in **listing order at this
   moment**.
3. If there are fewer than `PANEL_SIZE` candidates, write nothing and return the count.
4. Otherwise mature each candidate, set `reserved += seatLock`, store `Candidate{arbitrator, Reserved}` entries in
   `candidates[disputeId]` (one slot each), set `snapshotState = Reserved`, and emit the full list.

The snapshot stores **identities and order**; selection is uniform, so no weights are stored. It is taken in the same
transaction as `openDispute`, or in a later `retrySnapshot`, and in both cases before `selectionBlock` is set, so no
seed exists yet.

Effects of later registry activity on a stored snapshot:

| Later event | Effect |
| --- | --- |
| New deposit or maturation | none (not in the stored list; `free` is not re-read) |
| Withdrawal | cannot take reserved stake (`withdraw` bound excludes `reserved`); there is no withdrawal request, so nothing can be cancelled to re-enter eligibility |
| Penalty in another dispute | reduces only that dispute's lock; reservation stays covered (`locked + reserved <= stake` is preserved because penalty `<= seatLock`) |
| Delisting | impossible while a reservation exists (section 7.1) |
| Concurrent disputes | each snapshot reserves its own `seatLock`; a candidate with free stake `3 * seatLock` can be in at most 3 unfinished snapshots or seats |

A selected candidate is therefore always available: its seat is backed by stake reserved before the seed existed.

### 7.3 Selection

When `block.number > selectionBlock` and the blockhash is available:

```
seed = keccak256(abi.encode(blockhash(selectionBlock), block.chainid, address(court), disputeId))
n = candidates[disputeId].length                           // 3 <= n <= 32
order = [0, 1, ..., n - 1] in memory
for j in 0, 1, 2:
    pick = j + uint256(keccak256(abi.encode(seed, j))) % (n - j)
    swap(order[j], order[pick])
selected = order[0], order[1], order[2]
```

`selectPanel` turns the 3 selected entries into `Locked` (`reserved -= seatLock`, `locked += seatLock`) and every
other entry into `Unselected` (`reserved -= seatLock`). Modulo bias is below `32 / 2^256`.

### 7.4 Retry rules

- **Fewer than 3 candidates at opening:** status `AwaitingCandidates`; nothing is reserved. Anyone may call
  `retrySnapshot` while `now < panelDeadline`; a successful retry stores a snapshot and arms
  `selectionBlock = block.number + SELECTION_DELAY_BLOCKS`. Once a snapshot exists it can never be retaken.
- **Blockhash expired** (`blockhash(selectionBlock) == 0`, more than 256 blocks old): `drawPanel` re-arms
  `selectionBlock = block.number + SELECTION_DELAY_BLOCKS` against the **same** snapshot and returns.
- **No panel by `panelDeadline`:** `resolve` releases any reservations and records `FreelancerWins (NoPanel)`.

**Who can change the outcome of a draw.** After a snapshot exists, registry activity cannot change the panel. The
selected panel changes only if `drawPanel` is not executed for 256 blocks (about 8.5 minutes at 2-second blocks),
forcing a re-arm. Any party, any candidate, or anyone else can execute it, so a single participant cannot re-roll a
seed it dislikes; a re-roll requires every interested party to abstain, or censorship of their transactions.
**Limitation:** before a snapshot exists (`AwaitingCandidates`), the timing of `retrySnapshot` is discretionary, so a
caller can choose *which* candidate set is captured, though not the seed it will later face.

### 7.5 Gas and storage bounds

| Operation | Bound | Target |
| --- | --- | --- |
| `openDispute` / successful `retrySnapshot` | 32 account reads, ≤ 32 reservation writes, ≤ 32 snapshot slots | ≤ 2,000,000 gas at 32 candidates |
| `drawPanel` | ≤ 32 candidate and account updates | ≤ 800,000 gas |
| `resolve` with `NoPanel` from `AwaitingSeed` | ≤ 32 reservation releases | ≤ 800,000 gas |
| `resolve` with a panel | 3 seat releases | ≤ 400,000 gas |
| registry `deposit`, `withdraw` | O(1) plus one swap-and-pop | — |

Targets are acceptance criteria for slices S2–S3. Snapshot storage is 1 slot per candidate per dispute and is not
deleted (it serves as history).

S2 measurements (32 candidates; registry and harness storage marked cold with `vm.cool`; external call into the court
harness, excluding intrinsic and calldata cost):

| Operation | Mixed (16 matured warming, 16 materialized) | All 32 matured warming | Target |
| --- | --- | --- | --- |
| `reserveCandidates` | 1,580,835 | 1,915,251 | ≤ 2,000,000 |
| `selectPanel` | 245,173 | 205,373 | ≤ 800,000 |
| `releaseReservations` | 170,399 | 180,943 | ≤ 800,000 |

Meeting the snapshot target required packing the account into three slots (`uint128` amounts, `stake` with
`reserved`, `warming` with `locked`, `warmingUntil` with `listed`). That layout has two consequences:

- `seatLock` must fit in `uint128`.
- Each account's `stake + warming` is bounded by `MAX_PRINCIPAL = type(uint128).max`. `deposit` computes the remaining
  capacity `MAX_PRINCIPAL - (stake + warming)` in `uint256` and rejects any larger amount with
  `PrincipalLimitExceeded(amount, capacity)`, so maturation, withdrawal and snapshots can never overflow.

The `Account` view in section 6.3 keeps `uint256` fields. The court-level targets for `openDispute`, `drawPanel` and `resolve` remain for S3.

Selection is implemented in `PanelSelection.selectIndexes(seed, n)`, which reverts with `TooFewCandidates` for
`n < 3`; the registry takes the seed from the court and never fetches block data.

### 7.6 Predictability, manipulation and trust

- **Not unbiased.** The seed is unknown when the snapshot is taken but is not adversarially unbiased: the Base
  sequencer orders transactions and produces blocks and can influence `blockhash(selectionBlock)`. `prevrandao` on
  OP-stack chains is not a better source; `block.timestamp` is not randomness.
- **Public before use.** Once `selectionBlock` is mined anyone can compute the panel. Section 7.4 states who can force
  a re-roll.
- **Sybil sensitivity.** Selection is uniform over distinct listed addresses with `free >= seatLock`, one seat per
  address. **Splitting stake across addresses increases expected seats.** Example: one owner has 300, two others
  have 100 each, `seatLock = 100`. Unsplit there are exactly 3 candidates and the owner gets 1 seat. Split into three
  100-stake addresses, there are 5 equal candidates: expected owner seats `3 * 3 / 5 = 1.8`, and
  `P(owner holds >= 2 seats) = (C(3,2)·C(2,1) + C(3,3)) / C(5,3) = 7/10 = 70%`. Stake-weighted sampling without
  replacement would not remove this effect either. The only cost of an extra candidacy is keeping `seatLock` free
  and listed.
- **Capture cost.** Holding `m` of `n` candidacies requires `m` listed addresses each with `seatLock` free at the
  snapshot. This is a capital requirement, not proof of independent identities.
- **Administrator trust.** None for listing or selection. The deployer chooses immutable parameters and
  `penaltyRecipient`.
- **Upgrade path.** A later stage can replace the seed with a verifiable randomness source (for example Chainlink VRF
  on Base Sepolia) or use historical blockhashes (EIP-2935) when the target EVM provides them.

## 8. Stake accounting

### 8.1 Buckets

| Bucket | Meaning | Enters | Leaves |
| --- | --- | --- | --- |
| `warming` | deposited, not matured | `deposit` | maturity into `stake` |
| `stake` | matured principal | maturity | `withdraw`; penalty in `releaseSeat` |
| `reserved` (part of `stake`) | `seatLock` per `Reserved` candidacy | `reserveCandidates` | `selectPanel`, `releaseReservations` |
| `locked` (part of `stake`) | `seatLock` per `Locked` seat | `selectPanel` | `releaseSeat` |
| free | `stake + maturedWarming - locked - reserved` | | |
| withdrawable now | `stake - locked - reserved` | | `withdraw` |
| penalized | removed from `stake` and `locked` in `releaseSeat` and transferred to the court | | |

Per-dispute candidate states: `Reserved → Unselected` or `Reserved → Locked → Released` through `selectPanel` and
`releaseSeat`, and `Reserved → Released` through `releaseReservations` (no panel). No other transition exists.

Registry invariants:

```
for every account: locked + reserved <= stake
locked   == seatLock * #(Locked candidacies of the account)
reserved == seatLock * #(Reserved candidacies of the account)
totalStaked == sum(stake + warming)
depositsReceived == withdrawalsPaid + penaltiesSent + totalStaked          (cumulative counters)
stakeToken.balanceOf(registry) == totalStaked + unsolicited transfers to the registry
```

### 8.2 Regression example (finding R3)

Revision 1 had a `pendingWithdrawal` bucket that survived penalties. Revision 2 has no such bucket.

`stake = 100`, `locked = 100`, `reserved = 0`, `warming = 0`. The arbitrator misses a reveal; `releaseSeat(id, i, 100)`:
`locked = 0`, `stake = 0`, candidate `Released`, 100 transferred to the court, and since `stake + warming < seatLock`
the account is delisted in the same call. Nothing remains to reconcile, and the slot is free.

Partial case: `stake = 250`, `locked = 100`, `reserved = 100`. Penalty 100 in the locked dispute: `stake = 150`,
`locked = 0`, `reserved = 100 <= 150`, still listed (`150 >= 100`); the reservation for the other dispute remains
fully backed.

### 8.3 Separation of liabilities

| Contract | Liability | Tracked by |
| --- | --- | --- |
| WorkOrder | section 3.1 | `outstandingObligations` |
| ArbitratorRegistry | principal | `totalStaked` |
| ArbitrationCourt | fees of unresolved disputes and unclaimed credits | `pendingFees + totalClaimable` |

Liabilities are tracked per contract in storage, never inferred from balances or token addresses.

## 9. Commit-reveal

### 9.1 Commitment

```
VOTE_TAG   = keccak256("TrustWork.ArbitrationVote.v1")
commitment = keccak256(abi.encode(VOTE_TAG, block.chainid, address(court), disputeId, arbitrator, vote, salt))
```

`vote` is `1` (Freelancer) or `2` (Client); `salt` is a secret `bytes32`. `voteCommitment(...)` exposes the encoding.
Both `voteCommitment` and `revealVote` take the vote as a raw `uint8`, not the `Vote` enum: Solidity's ABI decoder
reverts on an out-of-range enum argument before the function body runs, which would make `InvalidVote` unreachable
for a value such as `3`. `voteCommitment` hashes any `uint8` without validation, so a client tool can reproduce a
commitment to an invalid value; `revealVote` rejects values outside `{1, 2}` with `InvalidVote` and stores a valid
value as the `Vote` enum.
Chain id, court and dispute bind a commitment to one dispute; the arbitrator field makes a copied commitment
unrevealable by anyone but its author.

### 9.2 Rules

- `commitVote`: caller holds a seat; commit phase; seat has no commitment; `commitment != 0`. A second commit reverts
  `AlreadyCommitted`.
- `revealVote`: caller holds a seat; reveal phase; committed and unrevealed; `vote ∈ {1, 2}` (else `InvalidVote`);
  commitment matches (else `InvalidReveal`, no state change, retry allowed in the phase). A second reveal reverts
  `AlreadyRevealed`.
- A seat is **faulty** if it has no commitment at the end of the commit phase or no valid reveal at the end of the
  reveal phase. A commitment to a vote outside `{1, 2}` can never be revealed and is faulty.

### 9.3 Ruling

```
no panel formed by panelDeadline -> FreelancerWins, NoPanel
f = valid Freelancer reveals, c = valid Client reveals
f >= 2 -> FreelancerWins, Majority
c >= 2 -> ClientWins, Majority
else   -> Split, NoDecision
```

| Situation | Ruling |
| --- | --- |
| 3–0 or 2–1 | majority side, `Majority` |
| 2–0 with one faulty seat | the two matching votes, `Majority` |
| 1–1 with one faulty seat (tie) | `Split`, `NoDecision` |
| one valid reveal | `Split`, `NoDecision` |
| commits but zero valid reveals | `Split`, `NoDecision` |
| zero commits | `Split`, `NoDecision` |
| fewer than 3 candidates for every snapshot attempt, or no `drawPanel` before `panelDeadline` | `FreelancerWins`, `NoPanel` |

Longest path until `resolve` is callable: `PANEL_PERIOD + COMMIT_PERIOD + REVEAL_PERIOD = 6 days`.

### 9.4 Court and registry transition table

All functions are `nonReentrant`.

| # | Function | Actor | Preconditions | State updates | Tokens | Events |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | `court.openDispute(k)` | genuine order | `factory.isWorkOrder(msg.sender)` | new `disputeId` (from 1); parties from the order; `openedAt`; `panelDeadline`; `pendingFees += F`; `feesReceived += F`; `registry.reserveCandidates`; ≥ 3 → `AwaitingSeed`, `selectionBlock = block.number + 10`; else `AwaitingCandidates` | client → court `F`, exact balance check | `DisputeOpened`; `SelectionArmed` or `CandidatesPending`; registry `CandidatesReserved` |
| C2 | `court.retrySnapshot(id)` | anyone | `AwaitingCandidates`; `now < panelDeadline` | as C1 snapshot step | none | as C1 |
| C3 | `court.drawPanel(id)` | anyone | `AwaitingSeed`; `now < panelDeadline`; `block.number > selectionBlock` | expired blockhash → re-arm; otherwise `registry.selectPanel`, seats stored, `drawnAt`, deadlines, `Voting` | none | `SelectionArmed` or `PanelDrawn`; registry `PanelSelected` |
| C4 | `court.commitVote(id, c)` | panelist | `Voting`; `now < commitDeadline`; own seat uncommitted; `c != 0` | seat commitment | none | `VoteCommitted` |
| C5 | `court.revealVote(id, v, salt)` | panelist | `Voting`; `commitDeadline <= now < revealDeadline`; committed, unrevealed; `v ∈ {1, 2}`; matches | seat vote | none | `VoteRevealed` |
| C6 | `court.resolve(id)` | anyone | `Voting` and `now >= revealDeadline`, or `AwaitingCandidates`/`AwaitingSeed` and `now >= panelDeadline` | ruling, reason, `Resolved`; credits per 11.2; `pendingFees -= F`; `totalClaimable += F + P·L`; `penaltiesReceived += P·L`; then `registry.releaseSeat` ×3, or `releaseReservations` from `AwaitingSeed` | registry → court `P·L` | `DisputeResolved`; registry `SeatReleased` or `ReservationsReleased` |
| C7 | `court.claimReward(a)` | anyone | `claimable[a] > 0` | `claimable[a] = 0`; `totalClaimable -= x`; `claimsPaid += x` | court → `a` | `RewardClaimed` |
| R1 | `registry.deposit(x)` | not `penaltyRecipient` | `x > 0`; admission rule if unlisted | mature; `warming += x`; `warmingUntil`; `totalStaked += x`; `depositsReceived += x`; list if needed | account → registry, exact balance check | `Deposited`, maybe `Listed` |
| R2 | `registry.withdraw(x)` | arbitrator | mature; `0 < x <= stake - locked - reserved` | `stake -= x`; `totalStaked -= x`; `withdrawalsPaid += x`; delist if below `seatLock` | registry → arbitrator | `Withdrawn`, maybe `Delisted` |
| R3 | `registry.reserveCandidates` | court | `snapshotState == None` | section 7.2 | none | `CandidatesReserved` (only when ≥ 3) |
| R4 | `registry.selectPanel` | court | `snapshotState == Reserved` | section 7.3; `snapshotState = Selected` | none | `PanelSelected` |
| R5 | `registry.releaseReservations` | court | `snapshotState == Reserved` | every `Reserved` → `Released`; `reserved -= L` each; `snapshotState = Released` | none | `ReservationsReleased` |
| R6 | `registry.releaseSeat(id, i, p)` | court | candidate `i` is `Locked`; `p <= seatLock` | `Released`; `locked -= L`; `stake -= p`; `totalStaked -= p`; `penaltiesSent += p`; delist if below `seatLock` | registry → court `p` | `SeatReleased`, maybe `Delisted` |

## 10. Incentives and penalties

### 10.1 The original proposal: slash votes against the majority

A minority vote is not evidence of dishonesty. With 3 seats, an honest dissenter facing two colluding or careless
panelists would be slashed for being right. Majority-coherence rewards teach arbitrators to predict others' votes
(a Schelling point), not the truth, and they make bribery cheaper: a briber who secures two seats also gets the third
punished unless it herds. Coherence schemes rely on large juries and appeals, which a three-seat single-round court
lacks.

### 10.2 Recommended policy

- **Penalty:** a faulty seat (missing commit, missing or unrevealable reveal) forfeits its full `seatLock`.
- **Reward:** the dispute fee is shared equally by valid revealers, whatever they voted: `floor(F / r)` each for
  `r >= 1` valid reveals.
- **Penalties, the whole fee when a formed panel has `r == 0`, and rounding dust** are credited to `penaltyRecipient`.
- **No panel:** the fee is credited back to the client; no penalties exist.

**Departure from the original idea:** minority votes are not slashed; the fee rewards participation, not agreement.

### 10.3 Who gains from a fault

- `penaltyRecipient` receives every penalty. The enforced restrictions (section 6.2) stop that address from being a
  party or an arbitrator, but its controller may also control other addresses.
- The remaining valid revealers gain from another seat's fault, because the fee is shared among fewer revealers:
  with `F = 20 USDC`, each of 3 revealers receives `floor(F/3) = 6.666666`; if one seat is faulty, each of the other
  2 receives `floor(F/2) = 10`.
- A party gains when a fault changes the ruling in its favor (section 10.4).

### 10.4 Strategic non-reveal and bribery

Penalties are **not** a quantified security bound. They state what an honest, independent, unbribed arbitrator loses
by failing to reveal: `seatLock` plus the forgone fee share. They do not bound what a party can gain, and an
arbitrator compensated by a briber, or controlled by a party, may bear no net cost at all.

Example: `D = 10,000 USDC`, `L = 100 USDC`, `F = 20 USDC`. Votes so far are heading to 2–1 for the freelancer. If
the client pays one freelancer-side panelist to withhold its reveal, the result is 1–1, so `Split`. The client
recovers 5,000 instead of 0. For an independent panelist the cost of withholding is 100 plus a forgone reward of about
6.67, so a bribe of about 107 suffices. A non-reveal is publicly observable, so such a bribe can be made trustless
with a contract that pays if no reveal appears by `revealDeadline`. Symmetrically, a freelancer facing 2–1 against it
gains 5,000 from one withheld reveal.

Why `NoDecision` after a formed panel is `Split` rather than the submitted-work default: with `Split`, forcing
`NoDecision` from a losing position gains either side at most `D/2`. A freelancer-favoring fallback would let the
freelancer gain `D` from one withheld reveal and the client nothing, which is a larger maximum incentive. Neither
choice removes the incentive when `D` greatly exceeds `seatLock`. **Limitation:** a larger panel, appeals, or a
`seatLock` that scales with `D` would be needed for meaningful protection; none is part of Stage 3.

### 10.5 Other residual risks

- **Lazy voting.** A random reveal still earns a reward; the merits cannot be verified on-chain. A later reputation
  stage is the intended mitigation.
- **Capacity exhaustion.** Unfinished snapshots and formed panels hold reservations and locks. A participant who
  opens many disputes (each needing a genuine order with submitted work) can leave too few candidates for a victim's
  dispute, which then ends `NoPanel`, paying the freelancer. Each spam dispute pays `F` up front; the fee is spent on
  rewards or penalties only if a panel forms, and is refunded to the spam dispute's client if that dispute itself
  ends `NoPanel`. Spam disputes that never form a panel therefore cost only capital tied up in escrows and fees for up
  to `PANEL_PERIOD`, plus gas. Unfinished spam snapshots can be cleared by anyone calling `drawPanel` after their
  seed block; formed spam panels keep 3 seats locked each until resolution.

## 11. Outcomes and money flows

### 11.1 Order credits at `applyRuling`

`outstanding = D + R` from `openDispute` until `applyRuling`, and `applyRuling` moves it into credits.

| Ruling (reason) | `feeCredit` | `freelancerCredit` | `clientCredit` |
| --- | --- | --- | --- |
| `FreelancerWins` (`Majority` or `NoPanel`) | `fee(D)` | `D - fee(D)` | `R` |
| `ClientWins` (`Majority`) | `0` | `0` | `D + R` |
| `Split` (`NoDecision`) | `fee(floor(D/2))` | `floor(D/2) - fee(floor(D/2))` | `D - floor(D/2) + R` |

`feeCredit + freelancerCredit + clientCredit = D + R`. Credits use `+=`, so the equation holds when two roles share an
address. Fee dust stays with the freelancer (Stage 1 rule); an odd `D` gives the extra unit to the client in `Split`.

**Limitation (NoPanel).** When no panel forms, nobody has judged whether the submitted work met the agreement. The
default applies the Stage 1/2 rule for unchallenged submitted work: it is paid. A client therefore cannot obtain a
discount by disputing when the court is empty; it also cannot obtain protection.

### 11.2 Court flows at `resolve`

`P` = penalized seats, `r` = valid reveals.

| Case | Rewards | `penaltyRecipient` | Client fee refund |
| --- | --- | --- | --- |
| panel, `r >= 1` | `r · floor(F / r)` | `F - r·floor(F/r) + P·L` | 0 |
| panel, `r == 0` | 0 | `F + P·L` (`P == 3`) | 0 |
| no panel | 0 | 0 | `F` |

Per dispute: `rewards + penaltyRecipientCredit + clientRefund = F + P·L`.

### 11.3 Worked examples

Order: `[1000, 2500, 500]` USDC (6 decimals), `feeBps = 250`. Milestone 0 approved (freelancer 975, fee recipient
25). Milestone 1 submitted and disputed: `D = 2500`, `R = 500`, outstanding `3000`.

| Ruling (reason) | freelancer | fee recipient | client | sum |
| --- | --- | --- | --- | --- |
| `FreelancerWins` (`Majority`) | 2437.5 | 62.5 | 500 | 3000 |
| `FreelancerWins` (`NoPanel`) | 2437.5 | 62.5 | 500 | 3000 |
| `ClientWins` (`Majority`) | 0 | 0 | 3000 | 3000 |
| `Split` (`NoDecision`) | 1218.75 | 31.25 | 1750 | 3000 |

Finding R2's example, revised: `D = 1,000 USDC`, `F = 20 USDC`, empty court. Revision 1 gave the client 500 back. Now
the client receives `R` only, the freelancer `1000 - fee(1000)`, and the client's 20 fee is refunded: disputing an
empty court yields exactly what not disputing yields, after a delay of up to `PANEL_PERIOD`.

Odd amount: `D = 7` units, `Split`: freelancer gross 3, `fee(3) = 0`, freelancer 3, client `4 + R`.

Delivery expiry at milestone 1 (milestone 0 settled): client credit `3000`, then `claimPayout(client)`.

Court, `F = 20 USDC = 20_000_000`, `L = 100 USDC`:

| Case | Ruling (reason) | Rewards | Penalties | `penaltyRecipient` | Client refund | Check |
| --- | --- | --- | --- | --- | --- | --- |
| 3 reveals 2–1 | majority (`Majority`) | 3 × 6_666_666 | 0 | 2 units | 0 | 19_999_998 + 2 = F |
| 2 reveals agree, 1 faulty | (`Majority`) | 2 × 10_000_000 | 100 USDC | 100 USDC | 0 | F + L |
| 2 reveals 1–1, 1 faulty | `Split` (`NoDecision`) | 2 × 10_000_000 | 100 USDC | 100 USDC | 0 | F + L |
| 1 reveal | `Split` (`NoDecision`) | 20_000_000 | 200 USDC | 200 USDC | 0 | F + 2L |
| 0 reveals | `Split` (`NoDecision`) | 0 | 300 USDC | 320 USDC | 0 | F + 3L |
| no panel | `FreelancerWins` (`NoPanel`) | 0 | 0 | 0 | 20 USDC | F |

### 11.4 Conservation with cumulative counters

Every counter below is updated only by the named protocol transitions; unsolicited transfers never touch them.

```
Order (per order):
  fundedTotal = directPaid + claimsPaid + outstandingObligations
  fundedTotal  = totalAmount after funding, 0 before
  directPaid   = settlement transfers to freelancer and fee recipient (O3–O5)
  claimsPaid   = claimPayout transfers (O9)
  balanceOf(order) = outstandingObligations + unsolicited transfers to the order

Court:
  feesReceived + penaltiesReceived = claimsPaid + pendingFees + totalClaimable
  balanceOf(court) = pendingFees + totalClaimable + unsolicited transfers to the court

Registry:
  depositsReceived = withdrawalsPaid + penaltiesSent + totalStaked
  penaltiesSent    = court.penaltiesReceived
  balanceOf(registry) = totalStaked + unsolicited transfers to the registry
```

Each balance equation is per contract address, so it holds whether `paymentToken == stakeToken` or not. The table
lists the authorized transitions that move tokens and the liability each one changes.

| From → to | Transition | Liability change |
| --- | --- | --- |
| client → order | O1 | order `outstandingObligations` set to `totalAmount` |
| order → freelancer, fee recipient | O3–O5 | order obligations decrease |
| order → claimant | O9 | order obligations decrease |
| client → court | C1 | court `pendingFees` increase |
| arbitrator → registry | R1 | registry `totalStaked` increase |
| registry → arbitrator | R2 | registry `totalStaked` decrease |
| registry → court | R6 | registry `totalStaked` decrease; court `totalClaimable` increase |
| court → claimant | C7 | court `totalClaimable` decrease |

Only these transitions change liabilities. Role addresses are not restricted from equaling protocol contracts: a fee
recipient or claimant may be the court, the registry or another order. Such a payout is still the paying contract's
O3–O5, O9 or C7 transition. The receiving contract records no liability for it, because liabilities are created
only inside its own deposit or fee routine (O1, C1, R1, R6); for the receiver it is an unsolicited transfer, which
stays outside every equation and cannot be withdrawn. Slice S4 adds a shared-token regression for this case
(test plan I-22).

### 11.5 Trace of the equations

Shared-token configuration (`paymentToken == stakeToken`): order above; arbitrators A, B, C, E with 200 matured stake
each; `F = 20`, `L = 100`. Amounts in USDC.

| Step | Order `funded = direct + claims + outstanding` | Court `fees + penalties = claimsPaid + pending + claimable` | Registry `deposits = withdrawn + penaltiesSent + staked` |
| --- | --- | --- | --- |
| deposits | — | `0 + 0 = 0 + 0 + 0` | `800 = 0 + 0 + 800` |
| fund | `4000 = 0 + 0 + 4000` | unchanged | unchanged |
| approve m0 | `4000 = 1000 + 0 + 3000` | unchanged | unchanged |
| open dispute (4 candidates reserved, 100 each) | `4000 = 1000 + 0 + 3000` | `20 + 0 = 0 + 20 + 0` | `800 = 0 + 0 + 800` |
| draw (A, B, C locked; E unselected) | unchanged | unchanged | unchanged |
| A, B reveal Freelancer; C faulty; resolve | unchanged | `20 + 100 = 0 + 0 + 120` (A 10, B 10, recipient 100) | `800 = 0 + 100 + 700` |
| applyRuling (`FreelancerWins`, `Majority`) | `4000 = 1000 + 0 + 3000` (credits 2437.5 / 62.5 / 500) | unchanged | unchanged |
| freelancer claims | `4000 = 1000 + 2437.5 + 562.5` | unchanged | unchanged |
| client, fee recipient claim | `4000 = 1000 + 3000 + 0` | unchanged | unchanged |
| A claims | unchanged | `120 = 10 + 0 + 110` | unchanged |
| C withdraws remaining 100 | unchanged | unchanged | `800 = 100 + 100 + 600`; C delisted |

Balances after these steps: order `0`, court `110`, registry `600`, each equal to its liabilities. The `NoPanel`
variant: open → `20 + 0 = 0 + 20 + 0`; resolve → `20 + 0 = 0 + 0 + 20` (client credit 20); reservations released
with no penalty; applyRuling credits as `FreelancerWins`.

## 12. Changes to earlier assumptions

| Earlier behavior | Stage 3 behavior | Why |
| --- | --- | --- |
| Submission had no deadline | `now < deliveryDeadline` | bounded locking |
| No refunds | delivery-expiry and ruling credits | terminal outcomes |
| Statuses `Unfunded/Active/Completed` | adds `Disputed`, `Terminated`; milestone `Disputed` | dispute lifecycle |
| `approvalNonce == currentMilestone == settlements` | section 5.1 | disputes and reclaim consume a nonce |
| `getMilestone` returned 4 fields | adds `deliveryDeadline` | ABI change for Stage 3 orders |
| All payouts pushed | all payouts after termination are claims | blocked recipients |
| `WorkOrder` constructor had 7 arguments | adds `deliveryPeriod` (S1) and `court` (S4) | integration |
| Factory had no state | deploys court; `isWorkOrder`; rejects `penaltyRecipient` as a party | authentication |

Changes from revision 1 of this document:

| Revision 1 | Revision 2 | Finding |
| --- | --- | --- |
| eligibility read at `openedAt` from mutable fields | snapshot and reservation stored at opening | R1 |
| no-panel and no-decision both `Split` | no panel → submitted-work default, fee refunded; formed panel without decision → `Split` | R2 |
| withdrawal request/delay, `pendingWithdrawal`, 64 slots, no admission minimum | immediate withdrawal of free stake, listing minimum `seatLock`, automatic delisting, 32 slots, per-candidate states | R1, R3 |
| capacity-weighted selection claimed split-neutral | uniform selection, Sybil sensitivity documented with example | R4 |
| conservation without penalty and claim counters; token-address provenance | cumulative counters per contract; transfer-edge provenance | R5 |
| reclaim pushed a refund | reclaim credits the client; claims move into S1 | R6 |

Unchanged: fee formula and cap, review boundary for finalization, exact funding checks, permit fallback, signature
message and domain, reentrancy protection, no admin withdrawal path, unsupported token classes.

## 13. Trust assumptions and limitations

- **Randomness:** sequencer-influenced, public once the seed block is mined; re-roll by universal abstention or
  censorship (section 7.4).
- **Snapshot timing:** `retrySnapshot` timing is discretionary while a dispute waits for candidates.
- **Sybil:** splitting stake across addresses increases expected seats (section 7.6). Address restrictions do not
  detect shared control (section 6.2).
- **Incentives:** penalties do not bound bribery or strategic non-reveal when `D` greatly exceeds `seatLock`
  (section 10.4); rewards pay participation, not correctness.
- **NoPanel:** without adjudication the submitted work is paid; an honest client gets no protection from an empty
  or exhausted court.
- **One round, three seats, no appeal.**
- **`penaltyRecipient`** is a trusted beneficiary of faults and dust, with no powers.
- **Tokens:** Assumption A1; a blocklisting stake token that blocks the registry or court would halt `resolve`.
- **Gas:** opening a dispute costs the client up to about 2,000,000 gas at 32 candidates.
- Stage 1/2 orders remain without delivery expiry or disputes. Unaudited, testnet only.

## 14. Implementation slices

| Slice | Content | Depends on | Acceptance |
| --- | --- | --- | --- |
| S1 (3B) | `WorkOrder`: `deliveryPeriod`, delivery deadlines, `reclaimAfterDeliveryExpiry` with client credit, `claimable`, `claimPayout`, `directPaid`, `claimsPaid`, `Terminated`, revised nonce invariant; factory parameter | Stage 2 | Stage 1/2 suites pass with the new constructor argument; S1 cases in the test plan pass; 100% production coverage |
| S2 (3C) | `ArbitratorRegistry` standalone with a court harness: admission, withdrawal, delisting, snapshot, reservation, selection, seat release | — | registry cases and invariants pass; gas targets (7.5) met at 32 candidates |
| S3 (3D) | `ArbitrationCourt` with mock factory/order: open, retry, draw, commit, reveal, resolve, rewards, refunds, claims | S2 | M1 (125/125) and M2 (10/10) pass; court counter invariants pass; gas targets met |
| S4 (3E) | Integration: `court` argument, `openDispute`, `applyRuling` reusing S1 claims, factory deploys court, `isWorkOrder`, `penaltyRecipient` restriction, README | S1, S3 | M3–M7 and cross-contract invariants pass in shared-token and different-token configurations; size limits met |

Each slice reports `forge fmt --check`, `forge build`, `forge test` and `forge coverage` separately and is reviewed
before the next begins. Detailed cases: [stage-3-test-plan.md](stage-3-test-plan.md).

## 15. Review findings R1–R6

| Finding | Resolution | Sections | Remaining limitation |
| --- | --- | --- | --- |
| R1 eligibility not a snapshot | candidate identities and order stored at opening with `seatLock` reserved per candidate before the seed; uniform selection from the stored list; retries reuse the snapshot | 7.2–7.5, 8.1, 9.4 | sequencer bias; re-roll by universal abstention; discretionary `retrySnapshot` timing before a snapshot exists |
| R2 no-panel discount | `NoPanel` → `FreelancerWins` with normal fee, `R` to client, fee refunded; formed-panel `NoDecision` stays `Split` with bribery analysis | 9.3, 10.4, 11.1–11.3 | no adjudication of the work when no panel forms; non-reveal incentive up to `D/2` |
| R3 admission and cleanup | listing minimum `seatLock`; automatic delisting on every reduction; no pending-withdrawal bucket; per-candidate states reject duplicate and unknown releases | 7.1, 8.1, 8.2, 9.4 | 32 slots can be held by one owner with `32 · seatLock` |
| R4 overstated claims | split-neutrality claim removed; 300/100/100 example; fee-share gain from faults; enforced vs assumed address separation | 6.2, 7.6, 10.3, 10.4 | Sybil splitting increases seats; shared control undetectable |
| R5 conservation | cumulative counters per contract; outstanding defined for every state; transfer-edge provenance; trace table | 3.1, 8.1, 11.4, 11.5 | equations hold only under Assumption A1 |
| R6 reclaim semantics | reclaim credits the client; claims part of S1 | 3.3, 3.7, 6.3, 14 | — |
