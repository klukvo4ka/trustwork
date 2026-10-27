# TrustWork

Milestone-based escrow for freelance work, written in Solidity with Foundry and OpenZeppelin Contracts v5.

> **Status:** Stage 4B (reputation registration and statistics) of a portfolio project. Stage 3 and the Stage 4A
> design ([design](docs/stage-4-reputation-design.md), [test plan](docs/stage-4-test-plan.md)) are accepted;
> soulbound receipts (slice 4C) are not implemented. Unaudited and intended for local development and testnets only.
> Do not use it with real funds.

## Architecture

| Contract           | Role                                                                                   |
| ------------------ | -------------------------------------------------------------------------------------- |
| `TrustWorkFactory` | Deploys the arbitration court once, then an independent `WorkOrder` per engagement bound to that court. The caller becomes the client. |
| `WorkOrder`        | Holds one engagement's budget and releases it milestone by milestone; a disputed milestone ends the order with the court's ruling. |
| `ArbitrationCourt` | Disputes opened by the factory's orders: candidate snapshot, panel draw, commit-reveal voting, rulings, fee and penalty credits. |
| `ArbitratorRegistry` | Stake ledger and per-dispute candidate snapshots, deployed by and used only by the court. |
| `TrustWorkReputation` | Optional, standalone: permissionless registration of final factory orders and factual per-account statistics. Nothing in the escrow, court or registry calls it. |

Each order is its own contract, so funds and state of different engagements never mix. There is no owner, admin,
upgrade path, or pause switch. Escrowed tokens leave an order only through settlement (to the fee recipient and the
freelancer) or through `claimPayout` of a credit recorded at termination.

Order terms (client, freelancer, token, fee recipient, fee, review period, delivery period, total) are immutables. Milestone amounts
live in a storage array because Solidity has no immutable arrays; nothing writes to an amount after construction.

The factory forwards all terms and its court to the `WorkOrder` constructor, which performs the validation. A
`WorkOrder` deployed directly therefore enforces the same rules, but the court only accepts disputes from orders the
factory created (`isWorkOrder`), so a directly deployed order can never open a dispute. The factory's
`WorkOrderCreated` event is the source of truth for orders created through TrustWork.

### Validation at creation

| Rule                                                      | Error                    |
| --------------------------------------------------------- | ------------------------ |
| Client, freelancer, token, fee recipient and court are nonzero | `ZeroAddress`       |
| Client and freelancer differ                              | `ClientIsFreelancer`     |
| Token address has deployed code                           | `TokenHasNoCode`         |
| At least one milestone                                    | `NoMilestones`           |
| Every milestone amount is positive                        | `ZeroMilestoneAmount`    |
| `feeBps <= 1000` (10%)                                    | `FeeTooHigh`             |
| `0 < reviewPeriod <= 30 days`                             | `InvalidReviewPeriod`    |
| `0 < deliveryPeriod <= 180 days`                          | `InvalidDeliveryPeriod`  |
| Fee recipient is not the order itself                     | `FeeRecipientIsOrder`    |
| `penaltyRecipient` is not the client, freelancer or fee recipient (factory) | `PenaltyRecipientIsParty` |

A milestone list whose sum overflows `uint256` reverts with a checked-arithmetic panic.

The fee recipient may equal the client or the freelancer, and may be a contract. It may not be the order's own
address: an ERC-20 transfer to oneself does not reduce the balance, so the fee would stay locked in the order while
the accounting records it as paid.

## Lifecycle

```
Unfunded --fund()--> Active --(last milestone settled)--> Completed
                       |
                       +--reclaimAfterDeliveryExpiry()--------------------> Terminated --claimPayout()--> (credits paid)
                       |                                                       ^
                       +--openDispute()--> Disputed --applyRuling()-----------+

Milestone: Pending --submitMilestone()--> Submitted --approveMilestone() | finalizeMilestone()--> Settled
                                              |
                                              +--openDispute()--> Disputed
```

1. **Fund** — only the client, once, for exactly `totalAmount`, through `fund()` (prior ERC-20 approval) or
   `fundWithPermit()` (ERC-2612 permit, see [Permit funding](#permit-funding)). Sets the first milestone's
   `deliveryDeadline = block.timestamp + deliveryPeriod`.
2. **Submit** — only the freelancer, for the current milestone, after funding, while
   `block.timestamp < deliveryDeadline`. Records `submittedAt` and `reviewDeadline = block.timestamp + reviewPeriod`.
3. **Approve** — for the current submitted milestone, at any time after submission (including after the
   review deadline): directly by the client with `approveMilestone()`, or by anyone relaying the client's
   signature with `approveMilestoneBySignature()` (see [Signed approvals](#signed-approvals)).
4. **Finalize** — anyone, for the current submitted milestone, once `block.timestamp >= reviewDeadline`.
5. Settlement marks the milestone `Settled`, increments `approvalNonce`, adds the milestone amount to `directPaid`,
   advances `currentMilestone`, sets the next milestone's `deliveryDeadline = block.timestamp + deliveryPeriod`,
   and pays out. Settling the last milestone sets the order to `Completed` instead.
6. **Reclaim** — only the client, when the current milestone is still `Pending` and
   `block.timestamp >= deliveryDeadline` (see [Delivery expiry](#delivery-expiry-and-claims)).
7. **Dispute** — only the client, for the current `Submitted` milestone, while `block.timestamp < reviewDeadline`;
   the court's ruling then ends the order (see [Disputes](#disputes)).

Every function that targets a milestone takes its index and requires it to equal `currentMilestone`. Milestones are
strictly sequential, and a stale or duplicated transaction cannot act on a different milestone than intended.

### Timeout boundary

A submitted milestone becomes eligible for permissionless finalization at the deadline itself:

```
eligible  <=>  block.timestamp >= reviewDeadline
```

At `reviewDeadline - 1` finalization reverts with `ReviewPeriodNotElapsed`; at `reviewDeadline` it succeeds.

## Delivery expiry and claims

Each milestone gets a delivery deadline when it becomes current: at funding for milestone 0, at the settlement of
the previous milestone for every later one. A failed funding or payout transaction leaves no deadline behind.

| Instant | `submitMilestone` | `reclaimAfterDeliveryExpiry` |
| --- | --- | --- |
| `deliveryDeadline - 1` | allowed | reverts `DeliveryPeriodNotElapsed` |
| `deliveryDeadline` and later | reverts `DeliveryPeriodElapsed` | allowed (client, milestone `Pending`) |

The delivery deadline only limits submission. A milestone submitted in time keeps its review deadline, and direct
approval, signed approval and timeout finalization work as before, however late they happen. Reclaim is rejected
for a `Submitted` milestone even long after its delivery deadline.

`reclaimAfterDeliveryExpiry()` moves no tokens. It sets the order to `Terminated`, increments `approvalNonce` once,
and credits all `outstandingObligations` to `claimable[client]`. The current milestone stays current and `Pending`,
and later milestones are not touched; the terminal status voids them.

`claimPayout(account)` can be called by anyone and always pays `account`. It clears the credit, reduces
`outstandingObligations` and increases `claimsPaid` before the transfer. If the transfer fails (for example the token
blocks the recipient), the whole call reverts and the credit stays for a later retry. Reclaim itself succeeds even
while the client is blocked, because it transfers nothing. A zero credit reverts with `NothingToClaim`. The order
stays `Terminated` after all credits are paid.

## Disputes

**Wiring.** `TrustWorkFactory(stakeToken, disputeFee, seatLock, penaltyRecipient)` deploys its immutable
`ArbitrationCourt`, which deploys its immutable `ArbitratorRegistry`. The court's and registry's constructor checks
(nonzero token with code, positive fee and seat lock, nonzero `penaltyRecipient` that is neither the court nor the
registry) bubble up from the factory. Every order the factory creates receives the immutable `court` and is recorded
in `isWorkOrder`; nothing else is ever recognized, including earlier orders and directly deployed `WorkOrder`
contracts. The factory rejects `penaltyRecipient` as the caller (client), freelancer or fee recipient with
`PenaltyRecipientIsParty`, and adds no other address restriction. There is no owner, setter, upgrade, pause or rescue
function in any of the three contracts.

**Opening.** `openDispute(index)` requires the client, an `Active` order, `index == currentMilestone`, a
`Submitted` milestone and `block.timestamp < reviewDeadline`. It sets the order and the milestone to `Disputed`,
consumes one `approvalNonce`, then calls `court.openDispute(index)`, stores the returned `disputeId` and emits
`DisputeOpened(index, disputeId, consumedNonce)`. The court pulls `disputeFee` of its stake token directly from the
client, so the client approves that amount to the **court**, separately from the escrow funding approved to the
order. A failed fee pull or court call reverts the whole transaction: order status, milestone, nonce, `disputeId`,
balances, reservations and court counters stay as they were.

| Instant | `openDispute` | `finalizeMilestone` | `approveMilestone` |
| --- | --- | --- | --- |
| `reviewDeadline - 1` | allowed | reverts `ReviewPeriodNotElapsed` | allowed |
| `reviewDeadline` and later | reverts `ReviewPeriodElapsed` | allowed | allowed |

When an approval and a dispute land in the same block, the first transaction wins and the second reverts on its
state precondition (`NotCurrentMilestone` after settlement, `InvalidOrderStatus(Disputed)` after the dispute).

**While disputed.** `fund`, `fundWithPermit`, `submitMilestone`, `approveMilestone`, `approveMilestoneBySignature`,
`finalizeMilestone`, `reclaimAfterDeliveryExpiry`, `openDispute` and `claimPayout` revert with
`InvalidOrderStatus(Disputed)`. A dispute is final for the order: there is no resubmission, continuation or second
dispute.

**Applying the ruling.** `applyRuling()` can be called by anyone while the order is `Disputed`. It reads
`court.rulingOf(disputeId)` for the order's own stored `disputeId`, never an argument, and reverts with
`RulingNotReady` until the court has resolved. It sets the order to `Terminated` and credits, with `D` the disputed
milestone, `R` the later unsettled milestones and `fee(x) = floor(x * feeBps / 10_000)`:

| Ruling (reason) | Freelancer | Fee recipient | Client |
| --- | --- | --- | --- |
| `FreelancerWins` (`Majority` or `NoPanel`) | `D - fee(D)` | `fee(D)` | `R` |
| `ClientWins` (`Majority`) | `0` | `0` | `D + R` |
| `Split` (`NoDecision`) | `floor(D/2) - fee(floor(D/2))` | `fee(floor(D/2))` | `D - floor(D/2) + R` |

Credits add up when roles share an address, and always sum to `D + R`. `applyRuling` moves no tokens and leaves
`outstandingObligations` unchanged; every party collects through `claimPayout`, as after delivery expiry. The order
does not advance: the disputed milestone stays `Disputed`, later milestones stay `Pending`, and the terminal status
voids them. `NoPanel` (no panel formed before `panelDeadline`) pays the submitted work as if it had not been disputed,
and the court refunds the client's dispute fee as a court credit.

**Nonces.** `approvalNonce == settledCount + (status == Disputed || status == Terminated ? 1 : 0)`. Opening a dispute
and delivery-expiry reclaim each consume one nonce; `applyRuling`, claims and failed transactions consume none. A
signature for the disputed milestone, or a pre-signed one for a later milestone whose nonce now matches numerically,
fails on the order status for good. The EIP-712 message and domain are unchanged.

## Signed approvals

`approveMilestoneBySignature(index, nonce, deadline, signature)` settles a milestone with an EIP-712 signature from
the client. Any account may submit it; the submitter (relayer) pays the transaction gas and receives nothing from the
order. Settlement is identical to `approveMilestone()`: same checks on order and milestone state, same fee
calculation, same payouts.

### Domain and message

| Domain field        | Value                     |
| ------------------- | ------------------------- |
| `name`              | `TrustWork`               |
| `version`           | `1`                       |
| `chainId`           | current `block.chainid`   |
| `verifyingContract` | the `WorkOrder` address   |

```
ApproveMilestone(uint256 milestoneIndex,uint256 nonce,uint256 deadline)
```

Example `eth_signTypedData_v4` payload for milestone `0` on Base Sepolia. All values are illustrative: replace
`verifyingContract` with the address of the order being approved, and `deadline` with a future Unix timestamp
(`1767225600` is 2026-01-01 00:00:00 UTC, so a signature with it would already be expired).

```json
{
  "types": {
    "EIP712Domain": [
      { "name": "name", "type": "string" },
      { "name": "version", "type": "string" },
      { "name": "chainId", "type": "uint256" },
      { "name": "verifyingContract", "type": "address" }
    ],
    "ApproveMilestone": [
      { "name": "milestoneIndex", "type": "uint256" },
      { "name": "nonce", "type": "uint256" },
      { "name": "deadline", "type": "uint256" }
    ]
  },
  "primaryType": "ApproveMilestone",
  "domain": {
    "name": "TrustWork",
    "version": "1",
    "chainId": 84532,
    "verifyingContract": "0x1111111111111111111111111111111111111111"
  },
  "message": {
    "milestoneIndex": 0,
    "nonce": 0,
    "deadline": 1767225600
  }
}
```

`approvalDigest(index, nonce, deadline)` returns the digest the client must sign, and `eip712Domain()` (ERC-5267)
returns the domain. The test suite builds the digest independently and checks it against both.

### Validation order

The call reverts, leaving all state including `approvalNonce` unchanged, unless:

1. the order is `Active` (`InvalidOrderStatus`);
2. `index` is the current milestone (`NotCurrentMilestone`) and it is `Submitted` (`InvalidMilestoneStatus`);
3. `block.timestamp <= deadline` (`ApprovalSignatureExpired`);
4. `nonce == approvalNonce` (`InvalidApprovalNonce`);
5. the signature is valid for the immutable `client` (`InvalidApprovalSignature`).

A payout failure after validation reverts the whole transaction, so the nonce is not consumed and the same signature
can be submitted again once the transfer can succeed.

### Nonces and replay protection

`approvalNonce` is a single order-wide counter that starts at `0` and increases by exactly one on every successful
settlement, whether it came from `approveMilestone`, `approveMilestoneBySignature` or `finalizeMilestone`, and once
more when the order leaves the settlement path through `openDispute` or `reclaimAfterDeliveryExpiry`. Rulings and
claims do not change it:

```
currentMilestone == settlementCount
approvalNonce    == settlementCount + (status == Disputed || status == Terminated ? 1 : 0)
```

While the order is active the signature for milestone `i` must therefore carry nonce `i`. Once the order is disputed
or terminated every signature fails on the order status, including one that happens to match the incremented nonce.

- **Same milestone twice:** after settlement the milestone is no longer current and the nonce has moved on.
- **Another milestone:** the index is part of the signed message.
- **Outstanding signatures:** a direct approval or a timeout consumes the nonce, invalidating any unused signature
  issued for it.
- **Another order or chain:** the domain separator includes `verifyingContract` and `chainId`; OpenZeppelin's
  `EIP712` recomputes it if the chain id changes after a fork.

### Signature expiry vs. review deadline

The two deadlines are independent:

- **Signature `deadline`** — chosen by the client, inclusive (`block.timestamp <= deadline`). It only limits how long
  the signature can be relayed.
- **Milestone `reviewDeadline`** — fixed at submission. Reaching it lets anyone call `finalizeMilestone`, but it does
  not invalidate a signature: a signed approval can still be relayed after the review deadline, as long as the
  signature has not expired and the milestone has not been finalized.

### Contract clients (ERC-1271)

Signatures are checked with OpenZeppelin `SignatureChecker`. If the client address has no code, the signature must
be a 65-byte ECDSA signature with low `s` from that address. If the client is a contract, the order calls
`isValidSignature(digest, signature)` with `staticcall` and requires the ERC-1271 magic value; a wrong return value
or a reverting validator is treated as an invalid signature. Contract signatures are revocable: validity is whatever
the wallet reports at execution time.

ERC-1271 applies only to milestone approvals. Permit funding depends on the token's own `permit` implementation,
which for most ERC-2612 tokens accepts only ECDSA signatures from EOAs.

## Permit funding

`fundWithPermit(deadline, v, r, s)` lets the client approve and fund in one transaction on tokens that implement
ERC-2612. The permit terms are fixed: owner `client`, spender the order, value `totalAmount`. There are no
caller-supplied owner, spender, recipient or amount parameters.

1. The caller must be the client and the order must be `Unfunded`; otherwise it reverts before calling the token,
   and the permit is not consumed.
2. `permit` is called inside `try/catch`. A revert for any reason (expired, wrong signer, wrong value, nonce
   already used, or no `permit` function on the token) is ignored.
3. The same deposit logic as `fund()` runs: `transferFrom(client, order, totalAmount)` followed by the exact balance
   check.

A failed permit therefore never authorizes funding by itself. Funding succeeds after a failed permit only if the
client's existing allowance already covers `totalAmount`; otherwise the transfer reverts with the token's
insufficient-allowance error. This also defuses permit front-running: if someone submits the client's permit to the
token first, the allowance it created is used and funding still succeeds. Any revert after the permit, such as an
insufficient balance, rolls the permit back with the rest of the transaction.

`fund()` remains for tokens and wallets without ERC-2612 support. The permit tests use OpenZeppelin's `ERC20Permit`
in a mock; they do not demonstrate compatibility with any deployed USDC contract, whose permit domain and behavior
must be checked separately.

## Fees

```
fee              = floor(amount * feeBps / 10_000)
freelancerPayout = amount - fee
```

The fee is computed per milestone with `Math.mulDiv`, so the product cannot overflow, and it rounds down: rounding
dust always goes to the freelancer. For example, a 39-unit milestone at 250 bps pays no fee. A zero fee skips the
fee-recipient transfer entirely. The fee is capped at 1,000 bps.

## Accounting

`outstandingObligations` tracks escrow liabilities in storage instead of reading the token balance:

| Status | `outstandingObligations` |
| --- | --- |
| `Unfunded` | `0` |
| `Active` | sum of unsettled milestone amounts |
| `Disputed` | sum of unsettled milestone amounts (the disputed one and every later one) |
| `Completed` | `0` |
| `Terminated` | sum of unclaimed credits |

Two cumulative counters record what has left the order: `directPaid` (gross settled milestone amounts, protocol fees
included) and `claimsPaid` (amounts transferred by `claimPayout`). They satisfy

```
fundedTotal == directPaid + claimsPaid + outstandingObligations
```

where `fundedTotal` is `0` before funding and `totalAmount` afterwards. All counters are updated before tokens move,
so a failed transfer rolls them back with the rest of the transaction.

Anyone can transfer tokens directly to an order. Those tokens are not liabilities and do not influence any check:
funding measures the balance increase of its own transfer, and settlement transfers exactly the milestone amount.
For supported tokens the order's balance is always `outstandingObligations + unsolicited tokens`, so the balance
always covers obligations. Unsolicited tokens currently stay in the order permanently.

## Token assumptions

Only standard ERC-20 tokens that move exactly the requested amount are supported (USDC-style tokens are the
target).

- **Fee-on-transfer tokens are rejected.** `fund()` compares the balance before and after the transfer and reverts
  with `DepositMismatch` unless the increase equals `totalAmount`.
- **Rebasing tokens are unsupported.** A negative rebase can leave the order unable to pay out; positive rebases
  behave like unsolicited tokens. This is not detected on-chain.
- Tokens with transfer hooks are handled defensively: all state-changing functions are `nonReentrant`, and state is
  updated before any external call.
- Tokens that can block recipients (for example USDC's blacklist) can make a payout revert. The whole settlement
  then reverts atomically and the milestone stays `Submitted` until the transfer can succeed. A blocked claim
  reverts the same way and leaves its credit in place.

## Security notes

- `SafeERC20` for every transfer; `ReentrancyGuard` on `fund`, `fundWithPermit`, `submitMilestone`,
  `approveMilestone`, `approveMilestoneBySignature`, `finalizeMilestone`, `reclaimAfterDeliveryExpiry`,
  `openDispute`, `applyRuling` and `claimPayout`.
- Checks-effects-interactions: status, obligations and milestone index are updated before tokens move or the court
  is called. `openDispute` sets `Disputed` and consumes the nonce before calling the court, so a token callback that
  re-enters the order during the fee pull is rejected by the order's guard and, if it reached another function, by
  the `Disputed` status. A stake-token callback during `court.resolve` may call `applyRuling` and sees the ruling
  already recorded. Funding additionally checks the received amount after the transfer.
- The order trusts only its immutable `court` and only the `disputeId` that court returned to it.
- Custom errors for all failures; events `Funded`, `MilestoneSubmitted`, `MilestoneSettled`, `OrderCompleted`,
  `DeliveryExpired(index, clientCredit)`, `DisputeOpened(index, disputeId, consumedNonce)`,
  `RulingApplied(disputeId, ruling, reason, clientCredit, freelancerCredit, feeCredit)` and
  `PayoutClaimed(account, amount)` for every lifecycle change. A signed approval additionally emits
  `MilestoneApprovedBySignature(index, client, relayer, nonce)` before `MilestoneSettled`, whose `settledBy` is the
  relayer.
- Timestamps are stored as `uint64` via `SafeCast`.

## Arbitrator registry

`ArbitratorRegistry` is slice S2 of the arbitration design
([`docs/stage-3-arbitration-design.md`](docs/stage-3-arbitration-design.md), sections 7–8). It is deployed by the
contract that becomes its immutable `court`: `ArbitrationCourt` deploys its own registry (registry unit tests use a
test harness instead). No order or factory uses it.

**Construction.** `stakeToken` (nonzero, has code), `seatLock` (positive, fits `uint128`) and `penaltyRecipient`
(nonzero, and neither the court nor the registry itself, so a protocol contract can never be the final beneficiary of
its own penalties; any other contract is accepted). There is no owner, setter, pause, upgrade or rescue function.

**Stake.** Each account has `stake` (matured), `warming`, `reserved` and `locked`:

- `deposit(amount)` adds to `warming` after maturing any warming stake whose `warmingUntil` has passed, and restarts
  `warmingUntil = now + 2 days` for the remaining warming bucket. Matured stake never becomes warming again. Deposits
  use an exact balance check; the penalty recipient cannot deposit.
- An unlisted account is listed only if its principal after the deposit is at least `seatLock` and fewer than 32
  accounts are listed (`BelowListingMinimum`, `RegistryFull`).
- **Principal limit.** One account's `stake + warming` may never exceed `MAX_PRINCIPAL = type(uint128).max`. A
  deposit larger than the remaining capacity `MAX_PRINCIPAL - (stake + warming)` reverts with
  `PrincipalLimitExceeded(amount, capacity)`. The check is done in `uint256` against the remaining capacity, so any
  `uint256` amount, including `type(uint256).max`, gets that error rather than an arithmetic panic. The limit exists
  because amounts are stored as `uint128` (see Gas below): without it, maturing warming stake into `stake` could
  overflow and block withdrawals and snapshots for that account.
- `withdraw(amount)` pays out at most `stake - locked - reserved`, with no delay. Any withdrawal or penalty that drops
  `stake + warming` below `seatLock` delists the account by swap-and-pop; its remaining balance stays withdrawable.

**Snapshots.** The court-only `reserveCandidates(disputeId, excluded)` scans the (at most 32) listed accounts and takes
those with at least `seatLock` of free matured stake that are not excluded, in listing order. With fewer than three it
returns the count and writes nothing, not even maturation. Otherwise it reserves `seatLock` from each candidate and
stores the list. Later deposits, maturation, withdrawals, penalties in other disputes, delisting and slot reuse do not
change a stored snapshot, and `locked + reserved <= stake` always holds.

**Selection and release.** `selectPanel(disputeId, seed)` picks three distinct stored candidates with the partial
Fisher–Yates of `PanelSelection`, locks them and releases every other reservation. The registry uses the seed it is
given and does not source randomness; selection is uniform only to the extent the seed is, and splitting stake across
addresses increases expected seats (design section 7.6). `releaseReservations` frees a snapshot that never formed a
panel. `releaseSeat(disputeId, index, penalty)` frees one locked seat, forfeits `penalty <= seatLock` of its stake to
the court, and rejects unknown disputes, out-of-range indexes and seats that are not currently locked.

**Accounting.** `totalStaked == sum(stake + warming)`, `depositsReceived == withdrawalsPaid + penaltiesSent +
totalStaked`, and the token balance equals `totalStaked` plus unsolicited transfers, which create no principal.

**Gas** (`test/registry/ArbitratorRegistry.gas.t.sol`; 32 candidates; registry and court-harness storage marked cold
with `vm.cool` before each measured call, address warmth not reset; measured with `vm.lastCallGas` as the external
call into the court harness, including its forwarding call and excluding the 21,000 intrinsic cost and calldata):

| Operation | Mixed fixture (16 matured warming, 16 materialized) | All-warming fixture (32 matured warming) | Target |
| --- | --- | --- | --- |
| `reserveCandidates` | 1,292,803 (was 1,580,835) | 1,343,187 (was 1,915,251) | ≤ 2,000,000 |
| `selectPanel` | 245,173 | 205,373 | ≤ 800,000 |
| `releaseReservations` | 180,943 | 180,943 | ≤ 800,000 |

The mixed `releaseReservations` figure was previously reported as 170,399 for what was actually a 30-candidate
second snapshot (two materialized accounts lacked free stake for it). The fixture now funds those accounts with one
extra unit so that both snapshots hold exactly 32 candidates, and the test asserts it.

**Storage.** Each account is packed into three slots, all amounts `uint128`: `principal` with `reserved`, `warming`
with `locked`, and `warmingUntil` with `listed`. `principal` is `stake + warming`; matured stake is derived as
`principal - warming`, and maturation only clears `warming`. An earlier layout stored `stake` instead of
`principal`, so the first reservation of an account whose stake had only ever warmed wrote its `stake` slot from zero
(about 20,000 gas each, 32 times in the all-warming snapshot). With `principal` that slot is nonzero from the first
deposit, and a reservation rewrites it at the nonzero-to-nonzero price. The first deposit now pays that zero-to-nonzero
write instead. Observable behavior is unchanged:

- `accountOf` reports the same buckets (`stake = principal - warming`), and warming still folds into stake only on a
  state-changing touch;
- `freeStake` still counts warming only after its activation time, and a top-up still restarts only the delay of
  stake that has not matured yet;
- withdrawals and penalties can only draw on matured stake, because `locked + reserved <= stake` is checked against
  the derived stake;
- delisting compares `principal`, which equals the former `stake + warming`.

Packing has consequences that are part of the API: `seatLock` must fit in `uint128`, and the per-account principal
limit above bounds `principal` itself, so it cannot overflow. The public `accountOf` view still returns `uint256`
amounts.

Each measured call runs inside one Foundry test transaction together with the calls before it, so EIP-2200 prices
a write to a slot already changed earlier in the test as a cheap "dirty" write. `vm.cool` resets warmth, not these
original values. Running the same fixtures with `forge test --isolate`, where every top-level call is its own
transaction, gives the higher, more realistic figures in the isolated columns. Every target holds in both modes.

| Operation (isolated) | Mixed fixture | All-warming fixture | Target |
| --- | --- | --- | --- |
| `reserveCandidates` | 1,235,487 (was 1,523,519) | 1,209,071 (was 1,781,135) | ≤ 2,000,000 |
| `selectPanel` | 468,489 | 468,489 | ≤ 800,000 |
| `releaseReservations` | 383,847 | 383,847 | ≤ 800,000 |

## Arbitration court

`ArbitrationCourt` is slice S3 of the arbitration design (sections 2, 4, 6, 7, 9 and 11). It is deployed by the
contract that becomes its immutable `factory`, and it deploys its own immutable `ArbitratorRegistry`. In production
that factory is `TrustWorkFactory` and its orders open disputes (see [Disputes](#disputes)); the court's own test
suite uses the mocks `MockArbitrationFactory` and `MockDisputableOrder`.

**Construction.** `stakeToken` (nonzero, has code), `disputeFee` and `seatLock` (positive) and `penaltyRecipient`
(nonzero). The registry's own checks apply unchanged: `penaltyRecipient` cannot be the court or the registry, and
`seatLock` must fit `uint128`. Any other address is accepted, including the deploying factory and other contracts.
There is no owner, setter, pause, upgrade or rescue function.

**Opening.** `openDispute(milestoneIndex)` is accepted only from an address for which `factory.isWorkOrder` returns
true. The court reads `client`, `freelancer` and `feeRecipient` from that order, assigns the next id (ids start at
1), records the counters, asks the registry to snapshot candidates excluding the three parties, and then pulls
exactly `disputeFee` from the client with a balance-increase check. With fewer than three candidates nothing is
reserved and the dispute is `AwaitingCandidates`; `retrySnapshot` (anyone) may take the snapshot later, strictly
before `panelDeadline = openedAt + 3 days`, and a stored snapshot is never retaken. With three or more the dispute is
`AwaitingSeed` with `selectionBlock = block.number + 10`.

**Panel.** `drawPanel` (anyone) requires `AwaitingSeed`, `now < panelDeadline` and `block.number > selectionBlock`.
The seed is `keccak256(abi.encode(blockhash(selectionBlock), chainid, court, disputeId))`. If the hash is no longer
available (more than 256 blocks later) the call re-arms `selectionBlock = block.number + 10` against the same
snapshot instead of drawing. Drawing locks three candidates in the registry, releases the other reservations and sets
`commitDeadline = now + 2 days` and `revealDeadline = commitDeadline + 1 day`.

**Voting.** Only seated arbitrators may commit or reveal.

- Commitment: `keccak256(abi.encode(VOTE_TAG, chainid, court, disputeId, arbitrator, vote, salt))` with
  `VOTE_TAG = keccak256("TrustWork.ArbitrationVote.v1")`; `voteCommitment` computes it for any `uint8`.
- `commitVote` before `commitDeadline`; zero and repeated commitments revert.
- `revealVote` in `[commitDeadline, revealDeadline)`. `vote` is a raw `uint8`, so values outside `{1, 2}` revert
  `InvalidVote` from the function body. A mismatching reveal reverts `InvalidReveal` and may be retried; a repeated
  reveal reverts. A seat committed to an invalid value can never reveal and ends faulty.
- There is no early resolution: `resolve` waits for `revealDeadline` even when every seat has revealed.

**Resolution and credits.** `resolve` (anyone) at or after `panelDeadline` without a panel, or at or after
`revealDeadline` with one. Let `F = disputeFee`, `L = seatLock` and `r` the number of valid reveals.

| Case | Ruling | Credits |
| --- | --- | --- |
| No panel (`AwaitingCandidates` or `AwaitingSeed`) | `FreelancerWins`, `NoPanel` | client `F`; any reservations released; no penalties |
| Two or more reveals for one side | `FreelancerWins` or `ClientWins`, `Majority` | each revealer `floor(F / r)`; `penaltyRecipient` `F - r·floor(F / r) + (3 - r)·L` |
| Otherwise (including `r = 0`) | `Split`, `NoDecision` | same formula; with `r = 0` the whole `F` and `3L` go to `penaltyRecipient` |

Every seat without a valid reveal forfeits exactly `L`, transferred from the registry to the court during `resolve`;
a revealed minority vote is never penalized. The court checks that its balance grew by exactly the penalties, and any
failed penalty transfer reverts the whole resolution. Credits are additive across disputes and are paid only by
`claimReward(account)`, which anyone may call for any account; it clears the credit before transferring.

**Accounting.** With cumulative counters:

- `feesReceived + penaltiesReceived == claimsPaid + pendingFees + totalClaimable`;
- `pendingFees == disputeFee × (number of unresolved disputes)`;
- `penaltiesReceived == registry.penaltiesSent()`;
- the court's token balance is `pendingFees + totalClaimable` plus unsolicited transfers, which create no credit.

**Gas** (`test/court/ArbitrationCourt.gas.t.sol`; 32 candidates; storage of the court, registry, token, factory and
order marked cold with `vm.cool` before each measured call, address warmth not reset; measured with `vm.lastCallGas`
as one external call from the test, which for `openDispute` is the mock order's forwarding call; excludes the 21,000
intrinsic cost and calldata; optimized build, `optimizer_runs = 200`):

| Operation | Mixed fixture (16 materialized, 16 matured warming) | All-warming fixture (32 matured warming) | Target |
| --- | --- | --- | --- |
| `openDispute` (first dispute) | 1,547,740 | 1,598,124 | ≤ 2,000,000 |
| `openDispute` (after an earlier dispute) | — | 1,331,824 | ≤ 2,000,000 |
| successful `retrySnapshot` | 1,193,993 | 1,199,577 | ≤ 2,000,000 |
| `drawPanel` | 394,511 | 374,611 | ≤ 800,000 |
| `resolve`, panel, 3 faulty seats | 209,289 | 209,289 | ≤ 400,000 |
| `resolve`, panel, 3 valid reveals | 176,286 | 176,286 | ≤ 400,000 |
| `resolve`, `NoPanel` from `AwaitingSeed` | 221,240 | 221,240 | ≤ 800,000 |

Every row is an unconditional assertion, and every fixture asserts exactly 32 candidates. Before the registry
storage change, the first all-warming `openDispute` measured 2,170,188 and failed its target; the other rows were
1,835,772 (mixed open), 1,993,488 (steady-state open), 1,526,825 / 1,861,241 (retry), 204,259 / 201,459 (faulty
resolve) and 176,856 (revealed resolve). The savings come entirely from the registry snapshot (see Storage under
Arbitrator registry); the court is unchanged apart from its constructor. The faulty-seat resolve now looks 5,030–
7,830 gas higher only because the old `stake` slot had been written earlier in the same test transaction and
was priced as dirty. In isolated runs it is lower than before.

Each measured call runs inside one Foundry test transaction together with the calls before it, so EIP-2200 prices
a write to a slot already changed earlier in the test as a cheap "dirty" write. `vm.cool` resets warmth, not these
original values. Running the same fixtures with `forge test --isolate`, where every top-level call is its own
transaction, gives the higher, more realistic figures in the isolated columns. Every target holds in both modes.

| Operation (isolated) | Mixed fixture | All-warming fixture | Target |
| --- | --- | --- | --- |
| `openDispute` (first dispute) | 1,485,032 (was 1,773,064) | 1,458,616 (was 2,030,680) | ≤ 2,000,000 |
| `openDispute` (after an earlier dispute) | — | 1,390,216 (was 1,962,280) | ≤ 2,000,000 |
| successful `retrySnapshot` | 1,272,497 (was 1,560,529) | 1,246,081 (was 1,818,145) | ≤ 2,000,000 |
| `drawPanel` | 637,215 | 637,215 | ≤ 800,000 |
| `resolve`, panel, 3 faulty seats | 230,293 (was 230,863) | 230,293 (was 230,863) | ≤ 400,000 |
| `resolve`, panel, 3 valid reveals | 200,090 (was 200,660) | 200,090 (was 200,660) | ≤ 400,000 |
| `resolve`, `NoPanel` from `AwaitingSeed` | 424,944 | 424,944 | ≤ 800,000 |

Through the production order (`test/integration/TrustWorkIntegration.gas.t.sol`, same cooling, all 32 candidates
holding only matured warming stake), the client's `WorkOrder.openDispute` call measures 1,672,706 gas, or 1,522,298
with `--isolate`, in both token configurations (target ≤ 2,000,000).

**Sizes** (optimized build, EIP-170 runtime limit 24,576 B, EIP-3860 initcode limit 49,152 B):

| Contract | Runtime | Initcode |
| --- | --- | --- |
| `TrustWorkFactory` | 13,668 B | 34,735 B (embeds the court and registry creation code; the runtime embeds the `WorkOrder` creation code) |
| `WorkOrder` | 9,849 B | 12,427 B |
| `ArbitrationCourt` | 10,616 B | 20,745 B (embeds the registry creation code) |
| `ArbitratorRegistry` | 8,667 B | 9,364 B |

`test_Sizes_WithinDeploymentLimits` checks the deployed runtimes and the factory initcode in the ordinary build.

## Reputation

`TrustWorkReputation(factory)` is slice 4B of the Stage 4 design
([`docs/stage-4-reputation-design.md`](docs/stage-4-reputation-design.md)). It is bound to one immutable
`TrustWorkFactory`, has no owner, setter, fee, pause, upgrade or rescue function, never moves tokens, and only makes
view calls to the factory, the order and the factory's court. Deploying it, or not, changes nothing in escrow,
arbitration or claims.

**Registration.** `register(order)` can be called by anyone, once per order:

1. `factory.isWorkOrder(order)` must be true (`UnknownOrder`); this is checked before any call to `order`. Directly
   deployed orders, orders of other factories and arbitrary contracts are rejected.
2. Not registered yet (`AlreadyRegistered`).
3. The order's `court()` equals `factory.court()` (`CourtMismatch`; cannot fail for factory orders).
4. The order is `Completed` or `Terminated` (`OrderNotFinal`). A `Disputed` order is not eligible even after the
   court has resolved; anyone can call `applyRuling` first. Registration never calls it.
5. The first milestone is no longer `Pending` (`NoParticipation`). Only the freelancer's submission moves it out of
   `Pending`, so an unsolicited order whose named freelancer never acted can never be registered and cannot affect
   that address.
6. For a dispute, the court's record must name this order and its current milestone (`InconsistentDispute`) and carry
   one of the four ruling/reason pairs the court produces (`UnsupportedRuling`).

**Outcomes.** `Completed`, `DeliveryExpired` (the client reclaimed after the freelancer had delivered at least once),
`FreelancerWins` and `ClientWins` (panel majority), `Split` (formed panel, no majority) and `NoPanel` (no panel
formed; the submitted milestone was paid by default). `NoPanel` is never counted as a win, and `Completed` is not a
quality rating.

**Facts.** `factsOf(order)` recomputes, from final order and court state only, the parties, token, outcome,
milestone counts, `totalAmount`, `settledAmount` (`directPaid`), `disputedAmount`, `freelancerAwarded` and
`clientReturned` (gross amounts in the order's token, with `freelancerAwarded + clientReturned == totalAmount`;
`freelancerAwarded` includes the protocol-fee portion and is not the freelancer's net receipt), the dispute ID,
`fundedAt` and `lastSubmittedAt` (exact), and `closedNotBefore` (a lower bound of the closing time). It never reads
payout credits, `claimsPaid`, `outstandingObligations` or balances, so registering before or after any claim yields
the same facts. `records(order)` stores only the outcome and `registeredAt`, the registration time, which is not the
closing time; `receiptsClaimed` is always `0` until receipts exist.

**Statistics.** `statsOf(account, role)` returns, separately for the client and freelancer roles, `registered`, one
counter per outcome and `milestonesSettled`. The fee-recipient position gives no statistics. No monetary amount is
ever summed across orders, so near-`uint256` orders cannot overflow anything. `orderCount` and
`ordersOf(account, role, offset, limit)` list registered orders in registration order: `ordersOf` returns an empty
array for `limit == 0` or `offset >= length`, otherwise `min(limit, length - offset)` entries, without computing
`offset + limit`.

**Meaning and limits.** Registration is voluntary, so statistics describe registered orders only and are biased
toward orders someone wanted on record. Wash orders between addresses one person controls, worthless tokens and
negligible amounts are possible and are not detected; every order's token, amounts and counterparty are exposed so
consumers can filter. There is no Sybil resistance, identity or quality signal.

**Gas** (`test/reputation/TrustWorkReputation.gas.t.sol`, storage cooled before the call, reported without a
threshold): first registration for both accounts 284,560 (`Completed`), 287,169 (`DeliveryExpired`), 306,835
(`FreelancerWins`), 307,196 (`Split`), 306,909 (`NoPanel`); 125,360 for `Completed` when both accounts already have a
registration. With `--isolate`: 310,992, 313,601, 335,767, 336,128, 335,841 and 174,192.

Size: `TrustWorkReputation` runtime 7,207 B, initcode 7,448 B.

## Development

Toolchain: Foundry 1.5.1-stable, solc 0.8.28 (EVM `cancun`), OpenZeppelin Contracts v5.6.1, forge-std v1.11.0.
Dependencies are git submodules.

```sh
git submodule update --init --recursive
forge fmt --check
forge build
forge test
forge coverage
```

Tests are split into unit tests (`test/TrustWorkFactory.t.sol`, `test/WorkOrder.t.sol`,
`test/WorkOrder.signature.t.sol`, `test/WorkOrder.permit.t.sol`, `test/WorkOrder.delivery.t.sol`), fuzz tests (`test/WorkOrder.fuzz.t.sol`) and a
stateful invariant suite (`test/invariant/`) that mixes all funding, settlement, reclaim and claim paths. Registry
tests live in `test/registry/` (unit, matrix M0, fuzz against a reference model, gas) and
`test/invariant/ArbitratorRegistry*.sol`; `test/mocks/RegistryCourtHarness.sol` stands in for the court. Court tests
live in `test/court/` (unit, matrices M1 and M2, fuzz, gas) and `test/invariant/ArbitrationCourt*.sol`, with
`test/mocks/MockArbitrationFactory.sol` and `test/mocks/MockDisputableOrder.sol` in place of the production factory and
order. Production integration tests live in `test/integration/` (unit cases I-01…I-22, matrices M3–M7, fuzz, gas)
and `test/invariant/TrustWorkIntegration*.sol`. Each runs twice, with one token for escrow and stake
(`SharedToken`) and with separate tokens (`SplitToken`). `test/utils/TransferLedger.sol` records every token
transfer during each protocol action, requires it to match the edges the test's own model expects for that
transition, and keeps an independent per-contract ledger of liabilities and unsolicited balance. Reputation tests live in
`test/reputation/` (unit, fuzz, gas; `MockReputationSources.sol` reaches the three consistency guards that the
accepted contracts cannot trigger) and `test/invariant/TrustWorkReputation*.sol`, which runs the Stage 3E integration
campaign with registrations interleaved, in both token configurations.
`test/WorkOrder.delivery.t.sol` also contains a deterministic matrix of every funding path × reclaim at the first,
middle and last milestone (9 cases); fuzz and invariant runs sample combinations rather than enumerating them. Mocks under `test/mocks/`
are test-only: `MockUSDC` (6 decimals, open minting), `MockPermitUSDC` (adds ERC-2612), a fee-on-transfer token, a
blocklist token, a token that re-enters the order during transfers, and an ERC-1271 wallet that can be switched to
return a wrong magic value or revert.

Run `forge test --match-path 'test/invariant/*' -vv` to print a per-campaign summary of the transitions reached in
the final run (funding path, settlement paths, rejected stale signatures and expired submissions, reclaims,
claims). `test_RandomCampaignsReachEveryTransition` in the court invariant suite replays 64 fixed pseudo-random
campaigns through the same handler, checks every court invariant after each call, and prints the summed transition
counts; the integration invariant suite has the same test (32 campaigns of 128 calls) for funding paths, settlement
paths, terminal states, rulings by reason, stale signatures and claims.

Coverage instruments and enlarges bytecode, so `test_Sizes_WithinDeploymentLimits` fails under `forge coverage`
(instrumented factory initcode 59,185 B). Functional coverage is therefore reported with that one test filtered:

```sh
forge coverage --no-match-test test_Sizes_WithinDeploymentLimits
```

## Current limitations

Not implemented in this stage:

- appeals, resubmission after a dispute, or more than one dispute per order;
- cancellation by agreement, and any refund other than delivery-expiry reclaim;
- recovery of unsolicited tokens sent directly to an order;
- soulbound receipts (designed in [`docs/stage-4-reputation-design.md`](docs/stage-4-reputation-design.md), slice 4C,
  not implemented), governance, frontend, deployment scripts, and a relayer service.

Stage 2 caveats:

- The client cannot revoke a signed approval except by letting it expire or by settling the milestone some other
  way (direct approval, or waiting for the timeout); there is no nonce-cancel function.
- `fundWithPermit` treats a token whose fallback accepts the `permit` call without reverting the same as a
  successful permit; funding still requires the resulting allowance.

Stage 3B caveats:

- The delivery clock for each milestone starts when it becomes current; a late approval of the previous milestone
  also delays the next delivery deadline.
- Orders deployed by the Stage 1/2 factory have no delivery period and cannot be reclaimed.

Stage 3E caveats:

- `NoPanel` pays the submitted work when no panel forms; an honest client gets no protection from an empty or
  exhausted court (design §11.1).
- Penalties do not bound bribery or strategic non-reveal when the disputed amount greatly exceeds `seatLock`
  (design §10.4).
- Address checks cannot detect that a party, an arbitrator and `penaltyRecipient` share a controller.
- Orders from the Stage 1/2 factories have no court and cannot be disputed; the Stage 3 factory does not adopt them.
- The status enums changed: `OrderStatus` gains `Disputed` before `Completed`, so `Completed` and `Terminated` have
  new numeric values, and `MilestoneStatus` gains `Disputed` at the end.

Stage 4B caveats:

- Registered history is incomplete and voluntarily selected; counters are not statistics over all orders.
- The closing time is not on-chain state; only `closedNotBefore` and `registeredAt` bound it.
- Orders left `Active` or `Disputed` forever never become eligible.

The milestone count has no explicit cap; creation gas grows linearly with it and is paid by the client.
