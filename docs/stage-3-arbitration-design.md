# Stage 3 — Arbitration design

Status: design for review (Stage 3A). Nothing in this document is implemented yet.
Baseline: Stage 2, commit `5746ac19e947d4c72b5dbfcf518e4b05ba199165`.

This document fixes one recommended design. Items marked **Assumption** are inputs the design relies on; items
marked **Tradeoff** are deliberate choices with a stated cost. Everything else is a rule the implementation must
follow exactly.

## 1. Summary

- A client may dispute a **submitted** milestone before its review deadline. A dispute **terminates the order**:
  the disputed milestone is paid according to the ruling and every unstarted milestone is refunded to the client.
- A new per-order **delivery period** bounds how long the current milestone may stay unsubmitted. After it expires
  the client can reclaim the unsettled budget. This removes the Stage 1/2 case where funds lock forever if the
  freelancer never submits.
- Arbitration is a separate **ArbitrationCourt** with a stake **ArbitratorRegistry**. Each dispute draws a panel of
  **3** arbitrators, weighted by free stake capacity, from a future blockhash. Panelists commit, then reveal a
  binary vote. **Two matching valid reveals** decide the dispute; anything else falls back to a fixed **Split**.
- Arbitrators are rewarded for revealing a valid vote and penalized only for **objectively observable faults**
  (missing commit, missing or invalid reveal). Votes against the majority are **not** slashed.
- Recording a ruling (court) is separate from applying it (order). Order payouts after termination and all court
  rewards are **pull-based claims**, so one failed transfer never blocks anyone else.
- New orders opt in by being created through the Stage 3 factory, which deploys the court, which deploys the
  registry. No contract has an owner or an upgrade path. Stage 1/2 orders are unaffected.

## 2. Parameters

| Name | Kind | Value | Purpose |
| --- | --- | --- | --- |
| `PANEL_SIZE` | court constant | `3` | Seats per dispute |
| `DECISION_THRESHOLD` | court constant | `2` | Matching valid reveals needed for a decision |
| `SELECTION_DELAY_BLOCKS` | court constant | `10` | Blocks between arming and the seed block |
| `PANEL_PERIOD` | court constant | `3 days` | Time from opening to draw a panel |
| `COMMIT_PERIOD` | court constant | `2 days` | Commit phase length |
| `REVEAL_PERIOD` | court constant | `1 days` | Reveal phase length |
| `ACTIVATION_DELAY` | registry constant | `2 days` | Deposit warm-up before stake is eligible |
| `WITHDRAWAL_DELAY` | registry constant | `7 days` | Delay between withdrawal request and execution |
| `MAX_ARBITRATORS` | registry constant | `64` | Bound on registered accounts |
| `MAX_DELIVERY_PERIOD` | order constant | `180 days` | Upper bound for `deliveryPeriod` |
| `disputeFee` | court immutable | `> 0` (testnet default 20 USDC) | Paid by the client on opening |
| `seatLock` | court immutable | `> 0` (testnet default 100 USDC) | Stake locked per seat; minimum capacity; fault penalty |
| `penaltyRecipient` | court immutable | nonzero | Receives penalties, unearned fees and rounding dust |
| `deliveryPeriod` | order immutable | `0 < p <= MAX_DELIVERY_PERIOD` | Time to submit the current milestone |

Existing Stage 1/2 parameters (`feeBps <= 1000`, `0 < reviewPeriod <= 30 days`) are unchanged.

**Assumption A1 (token).** The court's `stakeToken` is a single exact-transfer ERC-20 (testnet USDC or a 6-decimal
mock) used for stakes, dispute fees, rewards and penalties. It does not block transfers between the registry, the
court and ordinary accounts. Fee-on-transfer and rebasing tokens are unsupported, as in Stage 1. Order payment tokens
follow the Stage 1 assumptions independently and may differ from `stakeToken`.

**Tradeoff (no governance token).** Stakes are denominated in an existing stablecoin. A protocol token would add
issuance, pricing and governance questions without improving the security of a testnet court.

## 3. Order lifecycle

### 3.1 States

`OrderStatus`: `Unfunded`, `Active`, `Disputed`, `Completed`, `Terminated`.

`MilestoneStatus`: `Pending`, `Submitted`, `Settled`, `Disputed`.

`Milestone` gains `deliveryDeadline` (`uint64`). Milestones after a terminated order's current milestone keep status
`Pending`; the terminal order status makes them void. No per-milestone loop runs on termination.

New order storage: `deliveryPeriod` (immutable), `court` (immutable), `disputeId`, `claimable[address]`.

### 3.2 Who can dispute, and when

- **Only the client** opens disputes, only on the **current** milestone, only while it is **`Submitted`**, and only
  while `block.timestamp < reviewDeadline`.
- The freelancer never needs to dispute: a submitted milestone is either approved or released by timeout, and the
  client can reclaim only an **unsubmitted** milestone after delivery expiry, which is objective.
- A client unhappy with progress **before** submission has no dispute. They wait for submission (then dispute) or
  for delivery expiry (then reclaim).

### 3.3 Freelancer never submits

`deliveryDeadline` of the current milestone is set when it becomes current:

- milestone `0`: at funding, `fundedAt + deliveryPeriod`;
- milestone `k > 0`: at settlement of `k - 1`, `settledAt + deliveryPeriod`.

Submission is valid only while `block.timestamp < deliveryDeadline`. From `block.timestamp >= deliveryDeadline`, if
the current milestone is still `Pending`, the client may call `reclaimAfterDeliveryExpiry()`, which refunds all
unsettled milestones and terminates the order.

**Required behavior change.** Delivery expiry and its refund are required for this design: without them a
non-submitting freelancer locks the budget forever, and arbitration cannot help because there is nothing submitted to
judge. General cancellation (unilateral or mutual) is **not** required and is not part of Stage 3.

### 3.4 Disputed work is not resubmitted

A dispute is terminal for the order. After the ruling is applied the order is `Terminated`; there is no resubmission,
appeal or continuation.

**Tradeoff.** Continuing after a dispute would need revised-work submissions, a second review cycle, a second
signature-invalidation rule and possibly multiple disputes per order. Termination keeps every order to at most one
dispute and gives each outcome a complete, finite money flow.

### 3.5 Blocked actions while `Disputed`

`fund`, `fundWithPermit`, `submitMilestone`, `approveMilestone`, `approveMilestoneBySignature`, `finalizeMilestone`,
`reclaimAfterDeliveryExpiry`, `openDispute` and `claimPayout` all revert with `InvalidOrderStatus(Disputed)`.
Only `applyRuling` changes state, and only once the court has a ruling.

### 3.6 Remaining milestones after each outcome

Let the current milestone be `k`, `D = amount[k]`, and `R = sum(amount[i] for i > k)`.

| Terminal path | Milestone `k` | Milestones `> k` |
| --- | --- | --- |
| `Completed` (last milestone settled) | settled | none exist |
| Delivery expiry at `k` | refunded to client | refunded to client |
| Ruling `FreelancerWins` | freelancer `D - fee(D)`, fee recipient `fee(D)` | refunded to client |
| Ruling `ClientWins` | refunded to client | refunded to client |
| Ruling `Split` | freelancer `floor(D/2) - fee(floor(D/2))`, fee recipient `fee(floor(D/2))`, client `D - floor(D/2)` | refunded to client |

`fee(x) = floor(x * feeBps / 10_000)` computed with `Math.mulDiv`, exactly as in Stage 1.

### 3.7 Order transition table

All functions are `nonReentrant`. "Next" means: if `k + 1 == milestoneCount` then `status = Completed`, otherwise
`currentMilestone = k + 1` and `milestones[k + 1].deliveryDeadline = now + deliveryPeriod`.

| # | Function | Actor | Preconditions | State updates | Tokens | Events |
| --- | --- | --- | --- | --- | --- | --- |
| O1 | `fund()` / `fundWithPermit(...)` | client | `Unfunded` | `Active`; `outstanding = total`; `m[0].deliveryDeadline = now + deliveryPeriod` | client → order `total`, exact balance check | `Funded` |
| O2 | `submitMilestone(k)` | freelancer | `Active`; `k == current`; `m[k] Pending`; `now < m[k].deliveryDeadline` | `m[k] Submitted`; `submittedAt`; `reviewDeadline = now + reviewPeriod` | none | `MilestoneSubmitted` |
| O3 | `approveMilestone(k)` | client | `Active`; `k == current`; `m[k] Submitted` | `m[k] Settled`; `outstanding -= D`; `approvalNonce++`; next | order → fee recipient `fee(D)` (if > 0), order → freelancer `D - fee(D)` | `MilestoneSettled`, maybe `OrderCompleted` |
| O4 | `approveMilestoneBySignature(k, n, d, sig)` | anyone | O3 preconditions; `now <= d`; `n == approvalNonce`; valid client signature | as O3 | as O3 | `MilestoneApprovedBySignature`, `MilestoneSettled`, maybe `OrderCompleted` |
| O5 | `finalizeMilestone(k)` | anyone | O3 preconditions; `now >= m[k].reviewDeadline` | as O3 | as O3 | `MilestoneSettled` (`byTimeout = true`), maybe `OrderCompleted` |
| O6 | `openDispute(k)` | client | `Active`; `k == current`; `m[k] Submitted`; `now < m[k].reviewDeadline` | `Disputed`; `m[k] Disputed`; `approvalNonce++`; `disputeId = court.openDispute(k)` | client → court `disputeFee` (pulled by the court, exact balance check) | `DisputeOpened(k, disputeId, consumedNonce)` |
| O7 | `reclaimAfterDeliveryExpiry()` | client | `Active`; `m[current] Pending`; `now >= m[current].deliveryDeadline` | `Terminated`; `approvalNonce++`; `outstanding = 0` | order → client, all unsettled amounts | `DeliveryExpired(current, refund)` |
| O8 | `applyRuling()` | anyone | `Disputed`; `court.rulingOf(disputeId) != None` | `Terminated`; credits per section 11.1; `outstanding` unchanged | none | `RulingApplied(disputeId, ruling, clientCredit, freelancerCredit, feeCredit)` |
| O9 | `claimPayout(account)` | anyone | `Terminated`; `claimable[account] > 0` | `claimable[account] = 0`; `outstanding -= amount` | order → `account` | `PayoutClaimed(account, amount)` |

`openDispute` updates status, milestone status and nonce before calling the court and stores only the returned
`disputeId` afterwards; re-entry during the call is blocked by the order guard. The court is the order's immutable `court`
and is trusted; the call also pulls the dispute fee, so a missing client allowance reverts the whole transaction and
the order stays `Active` with its nonce unchanged.

`claimPayout` pays `account`, not the caller, so anyone can push a payout to a contract wallet that cannot initiate
calls. A reverting transfer reverts only that claim; the credit remains for a later retry.

## 4. Deadline boundaries

All comparisons use `block.timestamp` (written `now`) or `block.number`. Every transaction in a block sees the same
values, so at any instant the conditions below are mutually exclusive where stated. When two conflicting
transactions are valid at the same instant, the one ordered first by the sequencer succeeds and the second reverts on
its state precondition. Nothing happens automatically: every timeout below needs an on-chain caller.

| Boundary | Valid strictly before | Valid at and after |
| --- | --- | --- |
| Delivery, `deliveryDeadline` | `submitMilestone` (`now < deliveryDeadline`) | `reclaimAfterDeliveryExpiry` (`now >= deliveryDeadline`, milestone `Pending`) |
| Review, `reviewDeadline` | `openDispute` (`now < reviewDeadline`) | `finalizeMilestone` (`now >= reviewDeadline`) |
| Approval signature, `deadline` | `approveMilestoneBySignature` while `now <= deadline` (inclusive) | expired from `now > deadline` |
| Panel, `panelDeadline = openedAt + PANEL_PERIOD` | `drawPanel` (`now < panelDeadline`, `block.number > selectionBlock`) | `resolve` without panel (`now >= panelDeadline`, status `AwaitingPanel`) |
| Commit, `commitDeadline = drawnAt + COMMIT_PERIOD` | `commitVote` (`drawnAt <= now < commitDeadline`) | reveal phase begins |
| Reveal, `revealDeadline = commitDeadline + REVEAL_PERIOD` | `revealVote` (`commitDeadline <= now < revealDeadline`) | `resolve` (`now >= revealDeadline`) |
| Deposit activation, `warmingUntil = depositAt + ACTIVATION_DELAY` | warming stake ineligible | eligible when `warmingUntil <= referenceTime` |
| Withdrawal, `withdrawableAt = requestedAt + WITHDRAWAL_DELAY` | requested stake still eligible and lockable | `withdraw` allowed (`now >= withdrawableAt`); stake ineligible when `withdrawableAt <= referenceTime` |

Consequences:

- At `now == reviewDeadline - 1` the client can approve or dispute, and whichever executes first wins. At
  `now == reviewDeadline` only approval and finalization remain; a dispute reverts with `ReviewPeriodElapsed`.
- Client approval stays valid after the review deadline (Stage 1 rule). The only post-deadline race is approval
  versus finalization; both settle identically except for `byTimeout` in the event.
- At `now == deliveryDeadline` a submission reverts with `DeliveryPeriodElapsed` and reclaim succeeds.
- `drawPanel` and a no-panel `resolve` never overlap. Commit and reveal phases are derived from timestamps and never
  overlap. There is no early transition when every seat has committed or revealed.
- Locks release and rewards become claimable only when someone calls `resolve`. Arbitrators have the strongest
  incentive to do so; anyone may.

## 5. Signature invalidation

### 5.1 Revised invariant

Stage 2: `approvalNonce == currentMilestone == settledCount`.

Stage 3:

```
settledCount == currentMilestone                     (unchanged; Completed: == milestoneCount)
approvalNonce == settledCount + (status == Disputed || status == Terminated ? 1 : 0)
```

`openDispute` increments the nonce; `applyRuling` does not, so a terminated-by-ruling order keeps the `+1` from the
dispute. `reclaimAfterDeliveryExpiry` increments the nonce. Failed transactions leave it unchanged.

### 5.2 Why old signatures can never revive

- A signature for disputed milestone `k` carries nonce `k`; after `openDispute` the nonce is `k + 1`.
- A pre-signed approval for a later milestone `j > k` with nonce `j` could match the nonce numerically
  (`j == k + 1`), but the order is `Disputed` or `Terminated` forever and milestone `j` never becomes current. The
  **terminal status**, not the nonce alone, invalidates it.
- There is no resubmission, so there is no revised work for an old signature to approve.

### 5.3 Message and domain

The typed message `ApproveMilestone(uint256 milestoneIndex,uint256 nonce,uint256 deadline)` and the domain (`TrustWork`,
`1`, `chainId`, `verifyingContract`) **do not change**. Stage 3 orders are new contracts, so `verifyingContract`
already separates them from Stage 1/2 orders, and the rules above make old signatures unusable.

**Constraint for later stages.** Any future design that resumes an order after a dispute must change the message
(for example add a round counter) or bump the domain version, because the numeric-collision case in 5.2 would then
become exploitable.

## 6. Contract boundaries

### 6.1 Deployment and authentication

```
TrustWorkFactory (Stage 3)  --constructor deploys-->  ArbitrationCourt  --constructor deploys-->  ArbitratorRegistry
        |                                                  ^      |
        | new WorkOrder(court = factory.court())           |      | onlyCourt: drawAndLock, release
        v                                                  |      v
    WorkOrder  --openDispute / rulingOf------------------->+   stake ledger
```

- `ArbitratorRegistry.court` is immutable and equals the deploying court. `drawAndLock` and `release` revert unless
  `msg.sender == court`.
- `ArbitrationCourt.factory` is immutable and equals the deploying factory. `openDispute` reverts with `UnknownOrder`
  unless `factory.isWorkOrder(msg.sender)`. The court reads `client`, `freelancer` and `feeRecipient` from the order
  instead of trusting arguments. Forged orders cannot open disputes, lock stake, or obtain rulings.
- `WorkOrder.court` is immutable. The order uses only the `disputeId` returned by its own `court.openDispute` call and
  reads `court.rulingOf(disputeId)`. A ruling cannot be forged for an order because the order never accepts a ruling
  as an argument.
- No contract has an owner, pause, parameter setter, upgrade hook or token-rescue function.

Bytecode check from the Stage 2 build: factory runtime 10,054 B, WorkOrder initcode 9,274 B. The factory's initcode
will contain the court and registry initcode; it must stay under the EIP-3860 limit of 49,152 B. Slice S4 measures
this with `forge build --sizes` as an acceptance criterion.

### 6.2 Interfaces

```solidity
interface IArbitratorRegistry {
    struct Account {
        uint256 stake;              // active principal; includes locked and pending-withdrawal stake
        uint256 warming;            // deposited, not yet active
        uint256 locked;             // seatLock * open seats
        uint256 pendingWithdrawal;  // requested, not yet withdrawn
        uint64 warmingUntil;
        uint64 withdrawableAt;
    }

    event Deposited(address indexed arbitrator, uint256 amount, uint256 warmingUntil);
    event WithdrawalRequested(address indexed arbitrator, uint256 amount, uint256 withdrawableAt);
    event Withdrawn(address indexed arbitrator, uint256 amount);
    event SeatLocked(address indexed arbitrator, uint256 indexed disputeId, uint256 amount);
    event SeatReleased(address indexed arbitrator, uint256 indexed disputeId, uint256 penalty);

    function stakeToken() external view returns (IERC20);
    function court() external view returns (address);
    function seatLock() external view returns (uint256);
    function totalStaked() external view returns (uint256);           // sum of stake + warming
    function arbitratorCount() external view returns (uint256);
    function accountOf(address arbitrator) external view returns (Account memory);
    function eligibleSeats(address arbitrator, uint256 referenceTime) external view returns (uint256);

    function deposit(uint256 amount) external;
    function requestWithdrawal(uint256 amount) external;               // replaces any pending request; 0 cancels
    function withdraw() external returns (uint256 amount);

    function drawAndLock(uint256 disputeId, bytes32 seed, address[3] calldata excluded, uint256 referenceTime)
        external
        returns (bool drawn, address[3] memory panel, uint256 eligibleCount); // onlyCourt
    function release(uint256 disputeId, address arbitrator, uint256 penalty) external; // onlyCourt
}

interface IArbitrationCourt {
    enum DisputeStatus { None, AwaitingPanel, Voting, Resolved }
    enum Vote { None, Freelancer, Client }
    enum Ruling { None, FreelancerWins, ClientWins, Split }
    enum SplitReason { None, NoPanel, NoDecision }

    struct Seat {
        address arbitrator;
        bytes32 commitment;
        Vote vote;                  // None until a valid reveal
    }

    struct Dispute {
        address order;
        address client;
        address freelancer;
        address feeRecipient;
        uint256 milestoneIndex;
        uint256 fee;
        DisputeStatus status;
        Ruling ruling;
        uint64 openedAt;
        uint64 panelDeadline;
        uint64 drawnAt;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint256 selectionBlock;
    }

    event DisputeOpened(uint256 indexed disputeId, address indexed order, uint256 milestoneIndex, uint256 selectionBlock);
    event SelectionRearmed(uint256 indexed disputeId, uint256 selectionBlock, uint256 eligibleCount);
    event PanelDrawn(uint256 indexed disputeId, address[3] panel, uint256 commitDeadline, uint256 revealDeadline);
    event VoteCommitted(uint256 indexed disputeId, address indexed arbitrator);
    event VoteRevealed(uint256 indexed disputeId, address indexed arbitrator, Vote vote);
    event DisputeResolved(
        uint256 indexed disputeId, Ruling ruling, SplitReason reason, uint256 validReveals, uint256 rewardPerReveal,
        uint256 penalties
    );
    event RewardClaimed(address indexed account, uint256 amount);

    function factory() external view returns (address);
    function registry() external view returns (IArbitratorRegistry);
    function stakeToken() external view returns (IERC20);
    function disputeFee() external view returns (uint256);
    function penaltyRecipient() external view returns (address);
    function claimable(address account) external view returns (uint256);
    function getDispute(uint256 disputeId) external view returns (Dispute memory);
    function getSeats(uint256 disputeId) external view returns (Seat[3] memory);
    function rulingOf(uint256 disputeId) external view returns (Ruling);
    function voteCommitment(uint256 disputeId, address arbitrator, Vote vote, bytes32 salt)
        external
        view
        returns (bytes32);

    function openDispute(uint256 milestoneIndex) external returns (uint256 disputeId); // genuine orders only
    function drawPanel(uint256 disputeId) external;
    function commitVote(uint256 disputeId, bytes32 commitment) external;
    function revealVote(uint256 disputeId, Vote vote, bytes32 salt) external;
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
mapping(address account => uint256) public claimable;

event DisputeOpened(uint256 indexed index, uint256 indexed disputeId, uint256 consumedNonce);
event DeliveryExpired(uint256 indexed index, uint256 refund);
event RulingApplied(
    uint256 indexed disputeId, IArbitrationCourt.Ruling ruling, uint256 clientCredit, uint256 freelancerCredit,
    uint256 feeCredit
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

The constructor gains `IArbitrationCourt court_` and `uint256 deliveryPeriod_` and rejects a zero court
(`ZeroAddress`) and an invalid delivery period.

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
`disputeFee > 0`, `seatLock > 0` and `penaltyRecipient != address(0)`.

### 6.3 Opt-in and existing orders

Stage 1/2 orders are immutable and keep their behavior forever, including the possibility of funds locking when the
freelancer never submits. Only orders created by a Stage 3 factory have delivery expiry and disputes. The Stage 3
factory is a new deployment; it does not adopt or list earlier orders.

### 6.4 Reentrancy and duplicate execution

- Every state-changing function in all three contracts is `nonReentrant`, and each follows
  checks-effects-interactions.
- Cross-contract calls: order → court (`openDispute`, trusted, made after order state updates); court → order (view
  reads only); court → registry (`drawAndLock`, `release`, made after court state updates); registry → token.
- `resolve` writes the ruling, status, credits and liabilities before calling `registry.release`. A token callback
  that re-enters the court is blocked by the court guard; one that calls `order.applyRuling` sees the ruling already
  recorded, which is harmless.
- Duplicate execution reverts on status: `drawPanel` (status must be `AwaitingPanel`), `resolve` (not `Resolved`),
  `applyRuling` (order must be `Disputed`), claims (credit must be nonzero).

## 7. Arbitrator registry

### 7.1 Eligibility

```
maturedWarming(ref)  = warmingUntil <= ref ? warming : 0
excludedPending(ref) = (withdrawableAt != 0 && withdrawableAt <= ref) ? pendingWithdrawal : 0
free(ref)            = max(0, stake + maturedWarming(ref) - locked - excludedPending(ref))
eligibleSeats(ref)   = free(ref) / seatLock
```

An account is eligible for a dispute when `eligibleSeats(openedAt) >= 1` and it is not the order's client,
freelancer or fee recipient. `referenceTime` is the dispute's `openedAt`, fixed before the seed exists.

- The minimum stake is `seatLock`; there is no separate minimum.
- Deposits are pulled with an exact balance check. A new account is appended to the list; registration reverts with
  `RegistryFull` at `MAX_ARBITRATORS`. An account with `stake + warming == 0` after `withdraw` is removed by
  swap-and-pop.
- Every account mutation first matures warming stake (`warmingUntil <= now` moves `warming` into `stake`). A new
  deposit adds to `warming` and resets `warmingUntil = now + ACTIVATION_DELAY` for the whole warming bucket.

### 7.2 Selection

At `drawPanel`, the court computes

```
seed = keccak256(abi.encode(blockhash(selectionBlock), block.chainid, address(court), disputeId))
```

and calls `registry.drawAndLock(disputeId, seed, [client, freelancer, feeRecipient], openedAt)`.

The registry loads every account once into memory with `weight_i = eligibleSeats_i(openedAt)` (0 if excluded). If
fewer than 3 accounts have positive weight it returns `drawn = false` without writing. Otherwise, for seat
`j = 0, 1, 2`:

```
r = uint256(keccak256(abi.encode(seed, j))) % totalWeight
walk accounts in list order; select the first i where cumulative weight > r
totalWeight -= weight_i; weight_i = 0          // one seat per address per dispute
```

Each selected account is matured, then `locked += seatLock`. Selection probability is proportional to free seat
capacity, so splitting stake across addresses does not increase expected seats.

`drawPanel` rules:

- requires status `AwaitingPanel`, `now < panelDeadline`, `block.number > selectionBlock`;
- if `blockhash(selectionBlock) == 0` (more than 256 blocks old), set `selectionBlock = block.number +
  SELECTION_DELAY_BLOCKS`, emit `SelectionRearmed`, return;
- if `drawn == false`, re-arm the same way and return. Because eligibility is evaluated at `openedAt`, a later
  retry can succeed only when another dispute's `resolve` releases locks; new deposits never help this dispute;
- otherwise store the panel, set `drawnAt = now`, the commit and reveal deadlines, and status `Voting`.

Gas bound: `drawAndLock` reads at most 64 accounts and runs 3 weighted walks. The target is under 1,500,000 gas
at 64 accounts, measured in tests. All other registry operations are O(1).

### 7.3 Predictability, manipulation and trust

- **Not unbiased.** The seed is unknown when the dispute opens, but it is not adversarially unbiased. On Base the
  sequencer orders transactions and produces blocks, so it can influence `blockhash(selectionBlock)`. `prevrandao`
  on OP-stack chains is not a better source, and `block.timestamp` is not randomness at all.
- **Public before use.** Once `selectionBlock` is mined, anyone can compute the panel before calling `drawPanel`.
  The only way to change it is to keep everyone from calling `drawPanel` for 256 blocks (about 8.5 minutes at 2 s
  blocks), which forces a re-arm. That requires censoring all callers, including the favored party.
- **Eligibility steering.** Deposits mature and withdrawals take effect at times fixed days in advance, and
  eligibility is evaluated at `openedAt`, before the seed exists. Residual: an arbitrator whose withdrawal becomes
  executable between `openedAt` and the draw can withdraw first and remove themselves. Draws for other disputes can
  also change locks in between.
- **Sybil assumption.** Exclusion by address does not stop a party from staking through other addresses. Capture
  resistance comes only from stake: controlling 2 of 3 seats requires a large share of free capacity. The
  one-seat-per-address rule stops a single address from taking two seats, but a staker split across addresses can
  still take several seats on one panel.
- **Registry capacity.** 64 slots can be filled by Sybil accounts at a cost of `64 * seatLock`. This is accepted for
  testnet; there is no eviction.
- **Administrator trust.** None for selection or registration. The deployer chooses immutable parameters and
  `penaltyRecipient`.
- **Upgrade path.** A later stage can replace the seed with a verifiable randomness source (for example Chainlink
  VRF on Base Sepolia) behind the same `drawPanel` step.

## 8. Stake accounting

### 8.1 Buckets per arbitrator

| Bucket | Meaning | Enters | Leaves |
| --- | --- | --- | --- |
| `warming` | deposited, not active | `deposit` | maturity into `stake` |
| `stake` | active principal | maturity | `withdraw`, penalty in `release` |
| `locked` (subset of `stake`) | `seatLock` per open seat | `drawAndLock` | `release` |
| `pendingWithdrawal` (subset of `stake`) | requested | `requestWithdrawal` | `withdraw`, replacement request |
| available | `stake - locked` | | |
| withdrawable now | `now >= withdrawableAt ? min(pendingWithdrawal, stake - locked) : 0` | | |
| penalized | removed from `stake` and `locked` by `release(…, penalty = seatLock)` and sent to the court | | |

Invariants: `locked <= stake`; `locked == seatLock * (open seats in the court)`;
`totalStaked == sum(stake + warming)`; `stakeToken.balanceOf(registry) >= totalStaked`.

### 8.2 Concurrency, withdrawals and lock release

- A seat lock always comes from free capacity, so one stake unit never secures more than one seat. An account with
  `stake = 350` and `seatLock = 100` can hold at most 3 concurrent seats; the fourth draw sees `eligibleSeats = 0`.
- A penalty is at most the lock of that seat, so a fault in one dispute never touches stake securing another.
- `requestWithdrawal(amount)` needs `amount <= stake` and replaces any earlier request. Until `withdrawableAt` the
  requested amount stays eligible and lockable. After it, the amount is excluded for disputes opened at or after
  `withdrawableAt`, and `withdraw()` transfers `min(pendingWithdrawal, stake - locked)`, leaving the rest pending
  until locks release. `withdraw()` reverts with `NothingToWithdraw` if that minimum is 0.
- Locks release only in `release`, called by `resolve`.

### 8.3 Separation of liabilities

| Contract | Liability | Tracked by |
| --- | --- | --- |
| WorkOrder | unsettled milestones, or unclaimed credits after termination | `outstandingObligations` |
| ArbitratorRegistry | principal (`stake + warming`) | `totalStaked` |
| ArbitrationCourt | fees of unresolved disputes, plus all unclaimed rewards, penalties and dust | `pendingFees + totalClaimable` |

Escrow tokens never enter the court or registry, stake never enters an order, and every contract ignores unsolicited
transfers (they are never counted as liabilities and cannot be withdrawn).

## 9. Commit-reveal

### 9.1 Commitment

```
VOTE_TAG   = keccak256("TrustWork.ArbitrationVote.v1")
commitment = keccak256(abi.encode(VOTE_TAG, block.chainid, address(court), disputeId, arbitrator, vote, salt))
```

`vote` is `uint8(Vote.Freelancer) == 1` or `uint8(Vote.Client) == 2`; `salt` is a secret `bytes32` chosen by the
arbitrator. `voteCommitment(...)` exposes the same encoding for wallets and tests. The chain id, court and dispute
bind a commitment to one dispute; the arbitrator field stops a panelist from copying another's commitment, because a
copied commitment can only be revealed with the original arbitrator's address.

### 9.2 Rules

- `commitVote`: caller must hold a seat; commit phase; seat has no commitment; `commitment != 0`. A second commit
  reverts with `AlreadyCommitted`; there is no overwrite.
- `revealVote`: caller must hold a seat; reveal phase; seat has a commitment and no revealed vote; `vote` is 1 or 2
  (otherwise `InvalidVote`); the recomputed commitment matches (otherwise `InvalidReveal`, no state change, may retry
  with the correct salt during the phase). A second reveal reverts with `AlreadyRevealed`.
- A seat is **faulty** if it has no commitment at the end of the commit phase, or no valid reveal at the end of the
  reveal phase. A commitment to a vote outside {1, 2} can never be revealed and is therefore faulty.

### 9.3 Ruling

```
f = valid reveals for Freelancer, c = valid reveals for Client, r = f + c
no panel by panelDeadline -> Split (NoPanel)
f >= 2                    -> FreelancerWins
c >= 2                    -> ClientWins
otherwise                 -> Split (NoDecision)
```

With 3 seats, `f >= 2` and `c >= 2` cannot both hold. Every case terminates:

| Situation | Ruling |
| --- | --- |
| 3–0 or 2–1 | majority side |
| 2–0 (one seat faulty) | the two matching votes |
| 1–1 (one seat faulty) — tie | `Split (NoDecision)` |
| one valid reveal | `Split (NoDecision)` |
| commits but zero valid reveals | `Split (NoDecision)` |
| zero commits | `Split (NoDecision)` |
| fewer than 3 eligible arbitrators until `panelDeadline` | `Split (NoPanel)` |

A dispute's longest path is `PANEL_PERIOD + COMMIT_PERIOD + REVEAL_PERIOD = 6 days` until `resolve` becomes callable.

### 9.4 Court and registry transition table

All functions are `nonReentrant`. `F = disputeFee`, `L = seatLock`.

| # | Function | Actor | Preconditions | State updates | Tokens | Events |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | `court.openDispute(k)` | genuine order | `factory.isWorkOrder(msg.sender)` | new `disputeId` (from 1); parties read from the order; `openedAt = now`; `panelDeadline = now + PANEL_PERIOD`; `selectionBlock = block.number + SELECTION_DELAY_BLOCKS`; `AwaitingPanel`; `pendingFees += F` | client → court `F`, exact balance check | `DisputeOpened` |
| C2 | `court.drawPanel(id)` | anyone | `AwaitingPanel`; `now < panelDeadline`; `block.number > selectionBlock` | expired blockhash or `drawn == false`: re-arm `selectionBlock`. Otherwise: seats stored; `drawnAt = now`; `commitDeadline`, `revealDeadline`; `Voting`; registry `locked += L` per seat | none | `SelectionRearmed` or `PanelDrawn`; registry `SeatLocked` ×3 |
| C3 | `court.commitVote(id, c)` | panelist | `Voting`; `now < commitDeadline`; own seat uncommitted; `c != 0` | seat commitment | none | `VoteCommitted` |
| C4 | `court.revealVote(id, v, salt)` | panelist | `Voting`; `commitDeadline <= now < revealDeadline`; committed, unrevealed; `v ∈ {1, 2}`; commitment matches | seat vote | none | `VoteRevealed` |
| C5 | `court.resolve(id)` | anyone | (`Voting` and `now >= revealDeadline`) or (`AwaitingPanel` and `now >= panelDeadline`) | ruling and reason; `Resolved`; reward and recipient credits; `pendingFees -= F`; `totalClaimable += F + P * L`; then registry `release` per seat | registry → court `P * L` | `DisputeResolved`; registry `SeatReleased` ×3 (if a panel exists) |
| C6 | `court.claimReward(a)` | anyone | `claimable[a] > 0` | `claimable[a] = 0`; `totalClaimable -= amount` | court → `a` | `RewardClaimed` |
| R1 | `registry.deposit(x)` | anyone | `x > 0`; registered or below `MAX_ARBITRATORS` | mature; `warming += x`; `warmingUntil = now + ACTIVATION_DELAY`; `totalStaked += x` | account → registry `x`, exact balance check | `Deposited` |
| R2 | `registry.requestWithdrawal(x)` | arbitrator | mature; `x <= stake` | `pendingWithdrawal = x`; `withdrawableAt = x == 0 ? 0 : now + WITHDRAWAL_DELAY` | none | `WithdrawalRequested` |
| R3 | `registry.withdraw()` | arbitrator | mature; `withdrawableAt != 0`; `now >= withdrawableAt`; `min(pendingWithdrawal, stake - locked) > 0` | `stake`, `pendingWithdrawal`, `totalStaked` reduced by the amount; clear `withdrawableAt` when nothing is pending; remove empty account | registry → arbitrator | `Withdrawn` |

## 10. Incentives and penalties

### 10.1 The original proposal: slash votes against the majority

A minority vote is not evidence of dishonesty. With 3 seats, one honest dissenter facing two colluding or careless
panelists would be slashed for being right. Majority-coherence rewards teach arbitrators to predict what others will
say (a Schelling point), not what is true, and they make bribery cheaper: a briber who secures two seats also gets the
third seat punished unless it herds. Kleros-style coherence works with large juries and appeals; a three-seat,
single-round testnet court has neither.

### 10.2 Recommended policy

- **Penalty:** a faulty seat forfeits its full `seatLock`. Faults are objective: missing commit, missing reveal,
  unrevealable commitment.
- **Reward:** the dispute fee is divided equally among valid revealers, whatever they voted:
  `rewardPerReveal = floor(disputeFee / r)` for `r >= 1`.
- **Destination of non-rewards:** penalties, the whole fee when `r == 0`, and rounding dust go to `penaltyRecipient`.
  They never go to the client, freelancer or other panelists, so no participant profits from someone else's fault.

**Departure from the original idea:** no slashing for the minority; the dispute fee rewards participation, not
agreement.

### 10.3 Residual risks

- **Lazy voting.** A panelist can reveal a random vote and still collect a reward. Nothing on-chain can verify the
  merits. A later reputation stage is the intended mitigation.
- **Bribery and collusion.** Two bribed seats decide a dispute. The cost to the briber is the bribe; arbitrators risk
  nothing extra by voting as bribed. Defenses are only stake-weighted random selection and the fee being too small to
  matter for large orders.
- **Strategic non-reveal.** In the reveal phase a panelist sees earlier reveals. A pivotal panelist (1–1 so far) can
  withhold and force `Split` at a cost of `seatLock`. Bribing for non-reveal costs at least `seatLock` per seat, and the
  penalty never returns to the briber.
- **Fallback exploitation.** A client cannot obtain `Split` for free: opening costs `disputeFee`, and with
  `r == 0` the fee goes to `penaltyRecipient`, not back to the client. An honest client also loses the fee when the
  court has no capacity; this is accepted.
- **Capacity exhaustion.** Many disputes can lock all arbitrator capacity at `disputeFee` each, pushing later
  disputes towards `Split (NoPanel)`. The attacker needs genuine factory orders, so it also funds escrows.

## 11. Outcomes and money flows

### 11.1 Order credits at `applyRuling`

`outstanding = D + R` when the dispute opens and is unchanged until `applyRuling`.

| Ruling | `freelancerGross` | `feeCredit` | `freelancerCredit` | `clientCredit` |
| --- | --- | --- | --- | --- |
| `FreelancerWins` | `D` | `fee(D)` | `D - fee(D)` | `R` |
| `ClientWins` | `0` | `0` | `0` | `D + R` |
| `Split` | `floor(D / 2)` | `fee(floor(D/2))` | `floor(D/2) - fee(floor(D/2))` | `D - floor(D/2) + R` |

Conservation: `feeCredit + freelancerCredit + clientCredit = D + R`. Credits are added with `+=`, so the equation
holds even if two parties share an address.

Rounding: the fee rounds down (dust stays with the freelancer, Stage 1 rule); an odd `D` gives the extra unit to the
client.

The protocol fee is charged only on amounts paid to the freelancer, as in Stage 1. The dispute fee is a court
token amount and never touches the order.

### 11.2 Court flows at `resolve`

With `P` penalized seats (`P <= 3`) and `F = disputeFee`, `L = seatLock`:

```
rewards          = r >= 1 ? r * floor(F / r) : 0
recipientCredit  = (F - rewards) + P * L
rewards + recipientCredit = F + P * L
registry.totalStaked decreases by P * L; registry locked decreases by 3 * L (0 if no panel)
court: pendingFees -= F; totalClaimable += F + P * L
```

### 11.3 Worked examples

Order: milestones `[1000, 2500, 500]` USDC (6 decimals), `feeBps = 250`. Milestone 0 is approved (freelancer 975,
fee recipient 25). Milestone 1 is submitted and disputed: `D = 2500`, `R = 500`, outstanding `3000`.

| Ruling | freelancer | fee recipient | client | sum |
| --- | --- | --- | --- | --- |
| `FreelancerWins` | 2437.5 | 62.5 | 500 | 3000 |
| `ClientWins` | 0 | 0 | 3000 | 3000 |
| `Split` | 1218.75 | 31.25 | 1750 | 3000 |

Whole order for `Split`: freelancer `975 + 1218.75`, fee recipient `25 + 31.25`, client `1750`, total `4000`.

Odd amount: `D = 7` units, `feeBps = 250`, `Split`: `freelancerGross = 3`, `fee(3) = 0`, freelancer 3, client
`4 + R`.

Delivery expiry at milestone 1 (milestone 0 settled): client refund `2500 + 500 = 3000`; outstanding becomes 0.

Court: `F = 20 USDC = 20_000_000`, `L = 100 USDC`.

| Case | Ruling | Rewards | Penalties | `penaltyRecipient` credit | Check |
| --- | --- | --- | --- | --- | --- |
| 3 reveals, 2–1 | majority | 3 × 6_666_666 | 0 | 2 (dust) | 19_999_998 + 2 = F |
| 2 reveals agree, 1 missing | the two | 2 × 10_000_000 | 100 USDC | 100 USDC | 20 + 100 = F + L |
| 2 reveals 1–1, 1 missing | Split | 2 × 10_000_000 | 100 USDC | 100 USDC | F + L |
| 1 reveal | Split | 20_000_000 | 200 USDC | 200 USDC | F + 2L |
| 0 reveals | Split | 0 | 300 USDC | 20 + 300 USDC | F + 3L |
| no panel | Split | 0 | 0 | 20 USDC | F |

### 11.4 Recording versus applying

- `court.resolve(id)` records the ruling, releases locks and credits rewards. It never transfers to an individual;
  the only transfers are registry → court penalty transfers between protocol contracts (**Assumption A1**). If such a
  transfer reverts, `resolve` reverts as a whole and can be retried.
- `order.applyRuling()` can run any time after `resolve`; before that it reverts with `RulingNotReady`. It moves no
  tokens and can run only once.
- Claims (`order.claimPayout`, `court.claimReward`) are per account. A failing transfer (for example a blocklisted
  recipient) reverts only that claim and leaves the credit for a retry. Other parties' claims and the recorded ruling
  are unaffected.

## 12. Changes to earlier assumptions

| Earlier behavior | Stage 3 behavior | Why |
| --- | --- | --- |
| Submission had no deadline | `now < deliveryDeadline` required | bounded locking when the freelancer never submits |
| No refunds | client refund after delivery expiry; refunds through rulings | needed for terminal outcomes |
| Statuses `Unfunded/Active/Completed` | adds `Disputed`, `Terminated`; milestone `Disputed` | dispute lifecycle |
| `approvalNonce == currentMilestone == settlements` | revised invariant in 5.1 | disputes and reclaim consume a nonce |
| `getMilestone` returned 4 fields | adds `deliveryDeadline` | ABI change for Stage 3 orders only |
| All payouts pushed | payouts after termination are claims | failed transfers must not block other parties |
| `WorkOrder` constructor had 7 arguments | adds `court`, `deliveryPeriod` | integration |
| Factory had no state | deploys court; records `isWorkOrder` | module authentication |
| `CLAUDE.md` lists disputes, refunds as out of scope | authorized from Stage 3 implementation slices | scope change |

Unchanged: fee formula and cap, review boundary for finalization, exact funding checks, permit fallback, signature
message and domain, reentrancy protection, no admin withdrawal path, unsupported token classes.

## 13. Remaining trust assumptions and limitations

- Panel randomness is sequencer-influenced and public once the seed block is mined (section 7.3).
- Security against capture is economic and Sybil-unaware beyond stake.
- One round, three seats, no appeal. A wrong decision by two panelists is final.
- Rewards pay participation, not correctness. Lazy and bribed votes are not detectable on-chain.
- `penaltyRecipient` is a trusted beneficiary of faults and dust (it has no powers).
- The client bears the dispute fee in every outcome.
- Clients can dispute only submitted work and only before the review deadline; freelancers cannot dispute.
- The registry holds at most 64 accounts; selection gas grows linearly with that bound.
- Stage 1/2 orders remain without delivery expiry or disputes.
- Unaudited, testnet-only.

## 14. Implementation slices

| Slice | Content | Depends on | Acceptance |
| --- | --- | --- | --- |
| S1 (3B) | `WorkOrder`: `deliveryPeriod`, delivery deadlines, `reclaimAfterDeliveryExpiry`, revised nonce invariant, `Terminated`; factory parameter | Stage 2 | Stage 1/2 suites pass with the new constructor arguments; delivery tests and invariants from the test plan pass; 100% production coverage |
| S2 (3C) | `ArbitratorRegistry` standalone, with a test harness acting as court | — | registry unit, fuzz and invariant tests pass; `drawAndLock` gas measured at 64 accounts |
| S3 (3D) | `ArbitrationCourt` with mock factory/order: open, draw, commit, reveal, resolve, rewards, claims | S2 | 125-case reveal matrix passes; court conservation invariants pass |
| S4 (3E) | Integration: `WorkOrder.openDispute/applyRuling/claimPayout`, factory deploys court, `isWorkOrder`, README | S1, S3 | end-to-end matrices and cross-contract invariants pass; `forge build --sizes` shows factory initcode < 49,152 B and runtimes < 24,576 B |

Each slice ends with `forge fmt --check`, `forge build`, `forge test` and `forge coverage`, reported separately, and
is reviewed before the next begins. The detailed cases are in [stage-3-test-plan.md](stage-3-test-plan.md).
