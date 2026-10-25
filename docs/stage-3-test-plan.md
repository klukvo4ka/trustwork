# Stage 3 — Test plan

Companion to [stage-3-arbitration-design.md](stage-3-arbitration-design.md) (revision 2). Section references (§)
point to that document. Case IDs are stable so implementation slices can report them; IDs changed or added in
revision 2 are listed in section 8.

## 1. Conventions

- **Unit** tests are deterministic and assert exact state, balances, events and revert data.
- **Matrix** tests are deterministic loops over a fully enumerated input table. Only matrices may claim guaranteed
  coverage of a combination space, and they are reported as counts (for example "M1: 125/125").
- **Fuzz** tests sample bounded inputs. Each run executes one sampled combination; a campaign does not enumerate the
  combination space and is reported as "sampled".
- **Invariant** tests drive handlers through random action sequences. Reports give per-campaign transition counters
  from the final run and, where useful, aggregated samples across seeds. They show reachability, not exhaustiveness.
- Boundary tests check `deadline - 1`, `deadline` and `deadline + 1` (or the block-number equivalent).
- Every revert test asserts unchanged state: order and milestone status, `approvalNonce`, `outstandingObligations`,
  counters, balances, registry account and candidate states, court dispute.
- **Token configurations.** Every slice that moves both escrow and stake runs its integration cases in
  `SharedToken` (`paymentToken == stakeToken`, one `MockUSDC`) and `SplitToken` (distinct `MockUSDC` instances).
- Mocks stay under `test/`. Reused: `MockUSDC`, `MockPermitUSDC`, `BlocklistToken`, `FeeOnTransferToken`,
  `ReentrantToken`, `MockERC1271Wallet`. New: `RegistryCourtHarness` (S2), `MockArbitrationFactory` and
  `MockDisputableOrder` (S3), `PausableMockToken` (S3, to make registry → court transfers fail).

**Correction to the Stage 2 report.** The Stage 2 handoff said the lifecycle fuzz test "covers every combination of
funding path and settlement path in each run". That is inaccurate: each run samples one funding path and one
settlement path per milestone. Matrices M4 and M5 below provide the enumerated coverage.

## 2. Slice S1 — delivery deadline, reclaim credits and claims

### Unit

| ID | Case |
| --- | --- |
| D-01 | Constructor rejects `deliveryPeriod == 0` and `> MAX_DELIVERY_PERIOD`; accepts 1 and `MAX_DELIVERY_PERIOD` |
| D-02 | Funding sets `m[0].deliveryDeadline = fundedAt + deliveryPeriod`, both funding paths |
| D-03 | Settlement of `k` sets `m[k+1].deliveryDeadline = settledAt + deliveryPeriod` for direct, signed and timeout settlement |
| D-04 | `submitMilestone` at `deliveryDeadline - 1` succeeds; at `deliveryDeadline` and `+ 1` reverts `DeliveryPeriodElapsed` |
| D-05 | `reclaimAfterDeliveryExpiry` at `deliveryDeadline - 1` reverts `DeliveryPeriodNotElapsed`; at the deadline succeeds |
| D-06 | Reclaim at the first, a middle and the last milestone: `claimable[client]` equals the unsettled sum; `outstanding` unchanged; no token moves; `Terminated`; nonce +1; `DeliveryExpired` |
| D-07 | Reclaim reverts for non-client callers (`NotClient`); when `Unfunded`, `Completed`, `Terminated`; when the current milestone is `Submitted`, even far past the delivery deadline |
| D-08 | After reclaim every mutating function except `claimPayout` reverts `InvalidOrderStatus(Terminated)` |
| D-09 | `claimPayout(client)` after reclaim: pays exactly the credit; `outstanding == 0`; `claimsPaid` updated; second claim reverts `NothingToClaim`; claims for freelancer and fee recipient revert `NothingToClaim` |
| D-10 | `claimPayout` while `Unfunded`, `Active` or `Completed` reverts `InvalidOrderStatus` |
| D-11 | Blocklisted client: reclaim **succeeds** (no transfer); `claimPayout(client)` reverts and the credit remains; succeeds after unblocking |
| D-12 | `claimPayout(client)` called by a third party pays the client, not the caller |
| D-13 | Donation before and after funding: credit equals obligations only; donation stays in the order |
| D-14 | `ReentrantToken` callback during the claim transfer re-entering `claimPayout`, reclaim, approve: blocked with `ReentrancyGuardReentrantCall` |
| D-15 | Pre-signed approval for the current milestone fails after reclaim (`InvalidOrderStatus`) |
| D-16 | `directPaid` equals the sum of settlement transfers after each settlement path |
| D-17 | Regression: every Stage 1/2 unit test passes with the added constructor argument and unchanged assertions |
| D-18 | Fee recipient equal to the order is rejected with `FeeRecipientIsOrder`, both through the factory (predicted CREATE address) and by direct deployment |
| D-19 | Fee recipient equal to the client or the freelancer is accepted; settlement, reclaim and claim conserve funds |

### Fuzz

| ID | Case |
| --- | --- |
| DF-01 | `deliveryPeriod ∈ [1, MAX]`, elapsed `∈ [0, 2·MAX]`: exactly one of submit and reclaim succeeds at the sampled instant |
| DF-02 | Sampled settlements followed by reclaim and claim: `fundedTotal == directPaid + claimsPaid + outstanding` after every step |

### Invariants (handler: fund, submit, approve, signed approve, finalize, warp, reclaim, claim, donate)

| ID | Property |
| --- | --- |
| DI-01 | `fundedTotal == directPaid + claimsPaid + outstandingObligations` |
| DI-02 | `balanceOf(order) == outstandingObligations + donations` |
| DI-03 | `outstandingObligations` matches the per-status definition (§3.1) |
| DI-04 | Revised nonce invariant (§5.1) |

## 3. Slice S2 — arbitrator registry

`RegistryCourtHarness` deploys the registry (becoming its court) and exposes the four court-only functions.

### Unit

| ID | Case |
| --- | --- |
| R-01 | Deposit: exact transfer, `warming`, `warmingUntil`, `totalStaked`, `depositsReceived`, events; zero amount reverts; fee-on-transfer token reverts |
| R-02 | Admission: unlisted deposit of `seatLock - 1` reverts `BelowListingMinimum`; `seatLock` lists the account; a delisted account holding 50 may re-list by depositing 50 |
| R-03 | Registry full: 32 listed; the 33rd distinct depositor reverts `RegistryFull`; listed accounts may still top up |
| R-04 | `penaltyRecipient` deposit reverts `PenaltyRecipientCannotStake` |
| R-05 | Maturity: warming stake is not a candidate at `warmingUntil - 1`; is a candidate in a snapshot taken at `warmingUntil` |
| R-06 | Top-up while warming resets `warmingUntil` for the whole warming bucket; matured stake is unaffected |
| R-07 | Withdraw: `0` reverts; above `stake - locked - reserved` reverts; warming is not withdrawable; exact amount transferred |
| R-08 | Automatic delisting on withdraw below `seatLock`; swap-and-pop keeps positions consistent; the freed slot is reusable |
| R-09 | **R3 regression:** `stake = locked = 100`; `releaseSeat` with penalty 100 → `stake == 0`, `locked == 0`, candidate `Released`, account delisted, 100 sent to the court, `penaltiesSent == 100` |
| R-10 | Partial penalty: `stake 250, locked 100, reserved 100`; penalty 100 → `stake 150`, still listed, reservation intact |
| R-11 | Penalty leaving `0 < stake < seatLock` delists; the remainder is withdrawable; no reservation or lock remains |
| R-12 | Court-only functions revert for any other caller |
| R-13 | Snapshot: candidates are listed, non-excluded accounts with `free >= seatLock`, in listing order; each reserved exactly `seatLock`; `CandidatesReserved` lists them |
| R-14 | Fewer than 3 candidates: returns the count; no reservation, no snapshot state written |
| R-15 | Second `reserveCandidates` for the same dispute reverts |
| R-16 | Deposit, maturation, withdrawal, penalty in another dispute and delisting attempts after a snapshot do not change `candidatesOf(id)` or its reservations (one case each) |
| R-17 | Reserved stake cannot be withdrawn; the attempt reverts and leaves the account unchanged |
| R-18 | Concurrency: account with free `3 · seatLock` appears in 3 snapshots; a 4th snapshot excludes it; locks + reservations never exceed stake |
| R-19 | `selectPanel` with constructed seeds: first, last and middle candidates selectable; 3 distinct indices; selected → `Locked`, others → `Unselected`; reservations returned |
| R-20 | `selectPanel` twice, `releaseReservations` after selection, `selectPanel` after release: all revert |
| R-21 | `releaseSeat` on `Unselected`, `Reserved`, `Released`, out-of-range index, unknown dispute: revert `UnknownSeat`; a second release of the same seat reverts |
| R-22 | `releaseReservations` returns every reservation and marks candidates `Released` |
| R-23 | Slot reuse: a delisted address's slot reused by a new account; existing snapshots still reference the original addresses |
| R-24 | Gas: snapshot with 32 candidates ≤ 2,000,000; `selectPanel` ≤ 800,000; `releaseReservations` with 32 ≤ 800,000 (gas snapshots) |
| R-25 | Donations to the registry change no account, counter or `totalStaked` and cannot be withdrawn |
| R-26 | `ReentrantToken` callbacks during deposit, withdraw and penalty transfer: re-entry blocked |

### Matrix M0 — Sybil example (guaranteed)

Deterministic enumeration over all `C(5,3) = 10` index triples for five 100-stake candidates where one owner holds
three: owner seat counts `{1: 3 triples, 2: 6 triples, 3: 1 triple}`, expected value 1.8, `P(>= 2) = 7/10`. The
unsplit configuration (300, 100, 100) yields exactly 3 candidates and 1 owner seat. This documents §7.6; it is not a
fairness proof of the seed.

### Fuzz

| ID | Case |
| --- | --- |
| RF-01 | Sampled deposits, withdrawals, warps and penalties against a reference model: accounts, listing and counters match |
| RF-02 | Sampled listings (≤ 32) and seeds: panel is 3 distinct non-excluded snapshot members; reservations fully returned |
| RF-03 | Sampled seeds over a fixed snapshot: selection frequencies per candidate within a stated tolerance of uniform (sanity check of the index arithmetic, not of seed quality) |

### Invariants (handler: deposit, withdraw, warp, snapshot, select, releaseReservations, releaseSeat, donate)

| ID | Property |
| --- | --- |
| RI-01 | `locked + reserved <= stake` for every account |
| RI-02 | `locked == seatLock · #Locked` and `reserved == seatLock · #Reserved` per account |
| RI-03 | `totalStaked == sum(stake + warming)` |
| RI-04 | `depositsReceived == withdrawalsPaid + penaltiesSent + totalStaked` |
| RI-05 | `balanceOf(registry) == totalStaked + donations` |
| RI-06 | `listed` iff `stake + warming >= seatLock`; `listedCount <= 32`; no duplicates in the list |
| RI-07 | Candidate states only follow the transitions in §8.1; stored snapshot addresses never change |

## 4. Slice S3 — arbitration court

`MockArbitrationFactory` deploys the court and answers `isWorkOrder`; `MockDisputableOrder` exposes parties and calls
`openDispute`.

### Unit

| ID | Case |
| --- | --- |
| C-01 | Constructor validation: zero token, token without code, zero fee, zero `seatLock`, zero `penaltyRecipient` |
| C-02 | `openDispute` from an address the factory does not recognize reverts `UnknownOrder` |
| C-03 | Fee pull: exactly `F`; insufficient allowance or balance reverts with no dispute created; fee-on-transfer token reverts |
| C-04 | With ≥ 3 candidates: `AwaitingSeed`, `selectionBlock = block.number + 10`, snapshot stored; with fewer: `AwaitingCandidates`, nothing reserved |
| C-05 | `retrySnapshot` succeeds once enough free stake exists; a second call reverts; calling it in `AwaitingSeed` reverts |
| C-06 | `retrySnapshot` at `panelDeadline - 1` allowed; at `panelDeadline` reverts |
| C-07 | `drawPanel` at `selectionBlock` reverts; at `selectionBlock + 1` draws |
| C-08 | Blockhash expiry: at `selectionBlock + 257` `drawPanel` re-arms against the same snapshot (candidate list unchanged); later draw succeeds |
| C-09 | Registry changes between snapshot and draw (deposits, withdrawals of unreserved stake, penalties elsewhere) leave the drawn panel equal to the panel computed from the stored snapshot and seed |
| C-10 | `drawPanel` at `panelDeadline - 1` allowed; at `panelDeadline` reverts; `resolve` at `panelDeadline - 1` reverts and at `panelDeadline` records `FreelancerWins (NoPanel)` from both `AwaitingCandidates` and `AwaitingSeed` |
| C-11 | `NoPanel` from `AwaitingSeed` releases every reservation; client credited `F`; no penalties |
| C-12 | Repeated `drawPanel` after drawing reverts |
| C-13 | Commit by non-panelist reverts; zero commitment reverts; duplicate commit reverts `AlreadyCommitted` |
| C-14 | Commit at `commitDeadline - 1` succeeds; at `commitDeadline` reverts |
| C-15 | Reveal at `commitDeadline - 1` reverts; at `commitDeadline` succeeds; at `revealDeadline` reverts |
| C-16 | Reveal with wrong salt, wrong vote, another arbitrator's commitment, or a commitment for another dispute, court or chain: `InvalidReveal`; retry with correct data succeeds |
| C-17 | `revealVote` takes a raw `uint8`: values `0`, `3` and `255` revert `InvalidVote` from the function body (not an ABI decoding failure); `voteCommitment` returns a hash for those values; a seat committed to such a value ends faulty |
| C-18 | Duplicate reveal reverts `AlreadyRevealed` |
| C-19 | `voteCommitment` equals an independently computed `keccak256(abi.encode(...))` |
| C-20 | `resolve` at `revealDeadline - 1` reverts; at `revealDeadline` succeeds; second `resolve` reverts |
| C-21 | Each court row of §11.3 with exact amounts, dust and counters |
| C-22 | Fee share rises from `floor(F/3)` to `floor(F/2)` when one seat is faulty (§10.3) |
| C-23 | `claimReward` pays `account`; zero claim reverts; a blocklisted account's claim reverts without affecting other claims or the ruling |
| C-24 | Registry → court penalty transfer failing (`PausableMockToken`) reverts `resolve` atomically; retry after unpause succeeds |
| C-25 | Concurrent disputes: one arbitrator on several panels and snapshots; a fault in one leaves the others' locks and reservations intact |
| C-26 | Gas: `openDispute` with 32 candidates, `drawPanel`, `NoPanel` resolve, panel resolve within §7.5 targets |
| C-27 | Reentrancy: callbacks during fee pull, penalty transfer and claim re-entering `resolve`, `claimReward`, `drawPanel`, `retrySnapshot`: blocked |

### Matrix M1 — reveal patterns (guaranteed, 125 cases)

Each seat takes one of `NoCommit`, `CommitNoReveal`, `CommitUnrevealableVote`, `RevealFreelancer`, `RevealClient`.
All `5^3 = 125` assignments, each in a fresh dispute, assert: ruling and reason per §9.3; `r`, `floor(F / r)`, `P·L`,
`penaltyRecipient` credit; `rewards + recipientCredit == F + P·L`; every lock released; faulty seats lose exactly `L`.

### Matrix M2 — panel availability (guaranteed, 10 cases)

Candidate counts `{0, 1, 2, 3, 4}` × draw attempt `{called before panelDeadline, never called}`. A panel forms only
with ≥ 3 candidates and a draw call. Every other case resolves at `panelDeadline` to `FreelancerWins (NoPanel)` with
`F` credited to the client, no penalties, and all reservations released.

### Fuzz

| ID | Case |
| --- | --- |
| CF-01 | Sampled `F`, `L`, reveal patterns: `rewards + recipient + refund == F + P·L` |
| CF-02 | Sampled times and block numbers around every court boundary: exactly the allowed action succeeds |

### Invariants (handler: open, retry, draw, commit, reveal, warp, roll, resolve, claim, deposit, withdraw, donate)

| ID | Property |
| --- | --- |
| CI-01 | `feesReceived + penaltiesReceived == claimsPaid + pendingFees + totalClaimable` |
| CI-02 | `balanceOf(court) == pendingFees + totalClaimable + donations` |
| CI-03 | `pendingFees == F · #(unresolved disputes)` |
| CI-04 | `court.penaltiesReceived == registry.penaltiesSent` |
| CI-05 | `registry.locked(a) == L · #(Locked seats of a in unresolved disputes)` and `reserved(a) == L · #(Reserved candidacies of a)` |
| CI-06 | A resolved ruling never changes; `rulingOf` is `(None, None)` exactly for unresolved disputes |
| CI-07 | Every dispute reaches `Resolved` once the handler warps past `panelDeadline + COMMIT + REVEAL` and calls resolve |

## 5. Slice S4 — integration

### Unit

| ID | Case |
| --- | --- |
| I-01 | Factory deploys court and registry; `court.factory() == factory`; `registry.court() == court`; parameters wired |
| I-02 | `isWorkOrder` true for factory orders; false for arbitrary addresses and directly deployed `WorkOrder` contracts |
| I-03 | `createWorkOrder` with `penaltyRecipient` as caller, freelancer or fee recipient reverts `PenaltyRecipientIsParty` |
| I-04 | `openDispute` by non-client reverts `NotClient`; on `Unfunded`, `Completed`, `Terminated`, `Disputed` reverts `InvalidOrderStatus` |
| I-05 | `openDispute` on a `Pending` milestone reverts `InvalidMilestoneStatus`; on a non-current index `NotCurrentMilestone` |
| I-06 | Dispute at `reviewDeadline - 1` succeeds; at `reviewDeadline` reverts `ReviewPeriodElapsed` and finalization succeeds |
| I-07 | Race at `reviewDeadline - 1` in one block: approve then dispute (dispute reverts) and dispute then approve (approve reverts); same with signed approval |
| I-08 | Race at `reviewDeadline`: dispute reverts in either order; finalize and approve each settle once |
| I-09 | `openDispute` increments `approvalNonce`; `DisputeOpened` reports the consumed nonce |
| I-10 | Stale signatures: the disputed milestone's signature fails; a pre-signed `(k+1, nonce k+1)` signature fails on status; both still fail after `applyRuling` |
| I-11 | Missing court allowance: `openDispute` reverts; order state, nonce, balances and court counters unchanged |
| I-12 | While `Disputed`, every function in §3.5 reverts `InvalidOrderStatus(Disputed)` |
| I-13 | `applyRuling` before `resolve` reverts `RulingNotReady`; after, credits per §11.1 for each reason; second call reverts |
| I-14 | Claims for client, freelancer, fee recipient; blocklisted freelancer's claim reverts while the others succeed; retry after unblocking |
| I-15 | Fee recipient equal to client: credits accumulate in one entry; conservation holds |
| I-16 | ERC-1271 client opens a dispute (wallet approves the court) |
| I-17 | Reentrancy: `ReentrantToken` as order token during claims re-entering claims and `applyRuling`; as stake token during the fee pull re-entering `openDispute` and order functions: blocked |
| I-18 | Donations to order, court and registry during a dispute change no liability, counter or credit |
| I-19 | `forge build --sizes`: runtimes < 24,576 B; factory initcode < 49,152 B |
| I-20 | **R2 regression:** empty court, `D = 1,000`, `F = 20`: dispute ends `FreelancerWins (NoPanel)`; freelancer `1000 - fee(1000)`, client receives `R` plus the 20 fee refund; client's net equals not disputing |
| I-21 | Trace §11.5 step by step in `SharedToken` and `SplitToken`, asserting each equation after each step |
| I-22 | Shared-token recipient aliases: fee recipient set to the court address, and freelancer set to the registry address; payouts arrive as unsolicited balance; `pendingFees`, `totalClaimable` and `totalStaked` are unchanged and the received tokens cannot be withdrawn or claimed |

### Matrix M3 — ruling × dispute position (guaranteed, 15 cases)

Rulings `{FreelancerWins (Majority), ClientWins (Majority), Split (NoDecision by tie), Split (NoDecision by zero
reveals), FreelancerWins (NoPanel)}` × disputed milestone `{first, middle, last}` on `[1000, 2500, 500]`,
`feeBps = 250`. Asserts §11.1 credits, all claims, `outstanding == 0` afterwards, order balance equal to donations.

### Matrix M4 — terminal path × funding path (guaranteed, 21 cases)

Funding `{fund, valid permit, failed permit with allowance}` × terminal path `{Completed, delivery expiry first,
delivery expiry last, FreelancerWins (Majority), ClientWins, Split, FreelancerWins (NoPanel)}`. Asserts the revised
nonce invariant and `fundedTotal == directPaid + claimsPaid + outstanding` at every step.

### Matrix M5 — settlement path per milestone (guaranteed, 27 cases)

Every assignment of `{direct, signed, timeout}` to three milestones, ending `Completed`, asserting
`approvalNonce == 3`, fees and `directPaid`.

### Matrix M6 — boundaries (guaranteed)

Each boundary in §4 at `{t - 1, t, t + 1}` × each competing action. Expected success or revert is tabulated in the
test and must match §4.

### Matrix M7 — token configuration (guaranteed, 2 × 7 cases)

`{SharedToken, SplitToken}` × the terminal paths of M4 with `fund`. Asserts the per-contract balance equations of
§11.4 and the transition table: handler ghosts record every transfer by (from, to, transition); a transfer produced
by anything other than an authorized transition fails the test, and a transfer into a protocol contract outside its
deposit or fee routine must leave that contract's liabilities unchanged.

### Fuzz

| ID | Case |
| --- | --- |
| IF-01 | Sampled milestone amounts, `feeBps`, disputed index and ruling: credits sum to `D + R`; fee computed independently of `WorkOrder.feeFor`. Amounts near `type(uint256).max` are a separate deterministic case |
| IF-02 | Sampled lifecycle across funding paths, settlements before the dispute and terminal paths: nonce invariant and all §11.4 equations after every step |

### Invariants (handler covers order, court and registry actions; run in both token configurations)

| ID | Property |
| --- | --- |
| II-01 | Order: `fundedTotal == directPaid + claimsPaid + outstandingObligations` |
| II-02 | Order: `balanceOf(order) == outstandingObligations + orderDonations` |
| II-03 | `outstandingObligations` per status as defined in §3.1 |
| II-04 | Revised nonce invariant (§5.1) |
| II-05 | Court: CI-01, CI-02, CI-04 |
| II-06 | Registry: RI-01 … RI-06 |
| II-07 | Provenance: every token transfer observed by the handler ghosts comes from an authorized transition of §11.4; each contract's liabilities equal its cumulative liability-creating inflows minus its outflows, and transfers into it from other contracts' payouts count only as unsolicited balance |
| II-08 | An order has at most one dispute; `disputeId != 0` iff status is `Disputed` or terminated by ruling |

Invariant reports list per campaign: terminal states, rulings by reason, funding and settlement paths, rejected stale
signatures, snapshot retries, re-arms and faults, all as sampled counts.

## 6. Requirement traceability

| Requirement | Cases |
| --- | --- |
| Every transition and deadline boundary | D-02…D-06, R-05, C-04…C-20, I-06…I-08, M6 |
| Unauthorized operations | D-07, R-04, R-12, C-02, C-13, I-03, I-04 |
| Dispute vs approval/finalization races | I-07, I-08, M6 |
| Stale signatures after dispute transitions | D-15, I-09, I-10 |
| Snapshot integrity and concurrent stake | R-13…R-18, C-08, C-09, C-25, RI-01, RI-02, CI-05 |
| Admission, cleanup and duplicate release | R-02, R-03, R-08…R-11, R-20…R-23 |
| Missing arbitrators, commits and reveals | R-14, C-04…C-06, C-10, C-11, M1, M2 |
| Tie and fallback outcomes | M1, M2, M3, I-20 |
| Repeated resolution, application, claims | C-12, C-20, C-23, D-09, I-13, I-14 |
| Failed transfers and callbacks | D-11, D-14, R-26, C-23, C-24, C-27, I-14, I-17 |
| Conservation of escrow, stake and fee liabilities | DI-01, RI-04, CI-01, CI-04, II-01, II-05…II-07, I-21, I-22, M7 |
| Shared and different token configurations | I-21, M7, II-01…II-08 |

## 7. Slice acceptance

A slice is accepted only when all of the following are reported from actual command output:

- `forge fmt --check`, `forge build` (warnings listed), `forge test`, `forge coverage`;
- every case ID of the slice present and passing, and all earlier suites unchanged in intent;
- 100% line and branch coverage for the slice's production contracts, or each uncovered line explained;
- matrices as enumerated counts; fuzz and invariant results as sampled;
- gas targets of §7.5 for S2 and S3, and size limits for S4.

## 8. Changes from revision 1

| Revision 1 | Revision 2 | Finding |
| --- | --- | --- |
| R-02, R-09 withdrawal delay and pending-withdrawal cases | removed; R-07, R-09 (penalty regression), R-17 | R1, R3 |
| R-13/R-16/R-17 weighted walk | R-13…R-19 snapshot, reservation, uniform selection; M0 Sybil example | R1, R4 |
| no admission case | R-02, R-03, R-04 | R3 |
| no duplicate/unknown release case | R-20, R-21 | R3 |
| M2 expected `Split (NoPanel)` | M2 expects `FreelancerWins (NoPanel)` with fee refund; I-20 | R2 |
| CI-05 without penalties | CI-01 with cumulative counters; CI-04 | R5 |
| II-04 without outstanding obligations | II-01 `fundedTotal == directPaid + claimsPaid + outstanding` | R5 |
| II-07 by token address | II-07 transfer-edge provenance; M7; both token configurations | R5 |
| D-08/D-10 pushed refund | D-06, D-08…D-12 credit and claim in S1 | R6 |

## 9. Corrections during slice S1

| Item | Change |
| --- | --- |
| Self-fee-recipient | D-18 and D-19 added; design §6.2 |
| Raw `uint8` vote | C-17 rewritten; design §6.3, §9.1 |
| Provenance with role aliases | M7 and II-07 reworded; I-22 added; design §11.4 |
| Listing guarantee | design §7.1 limited to `Reserved` and `Locked` entries |
| Spam-dispute cost | design §10.5: fees are refunded on `NoPanel` |

## 10. S1 implementation map

| Cases | Test |
| --- | --- |
| D-01 | `TrustWorkFactory.t.sol`: `test_RevertWhen_DeliveryPeriodIsZero`, `test_RevertWhen_DeliveryPeriodAboveMaximum`, `test_CreateWorkOrder_AcceptsBoundaryTerms` |
| D-02 | `WorkOrder.delivery.t.sol`: `test_Fund_SetsFirstDeliveryDeadline`, `test_FundWithPermit_SetsFirstDeliveryDeadlineOnBothPaths`, `test_RevertWhen_FundingFailsLeavesNoDeliveryDeadline` |
| D-03 | `test_DirectSettlement_…`, `test_SignedSettlement_…`, `test_TimeoutSettlement_SetsNextDeliveryDeadline`, `test_FinalSettlement_CompletesWithoutFurtherDeadline`, `test_RevertWhen_PayoutFailsRollsBackCountersAndNextDeadline` |
| D-04 | `test_Submit_AllowedOneSecondBeforeDeliveryDeadline`, `test_RevertWhen_SubmitAtDeliveryDeadline`, `test_RevertWhen_SubmitAfterDeliveryDeadline`, `test_DeliveryExpiry_DoesNotAffectSubmittedMilestone` |
| D-05 | `test_RevertWhen_ReclaimOneSecondBeforeDeliveryDeadline`, `test_Reclaim_AtDeliveryDeadline` |
| D-06 | `test_Reclaim_AtFirstMilestone`, `…AtMiddleMilestone`, `…AtLastMilestone` |
| D-07 | `test_RevertWhen_ReclaimCalledByNonClient`, `…BeforeFunding`, `…AfterCompletion`, `…ReclaimTwice`, `test_DeliveryExpiry_DoesNotAffectSubmittedMilestone` |
| D-08 | `test_Terminated_BlocksEveryLifecycleFunction` |
| D-09 | `test_ClaimPayout_PaysReclaimCredit`, `test_RevertWhen_ClaimRepeatedOrWithoutCredit` |
| D-10 | `test_RevertWhen_ClaimBeforeTermination` |
| D-11 | `test_BlockedClient_ReclaimSucceedsAndClaimRetries` |
| D-12 | `test_ClaimPayout_ByUnrelatedCallerPaysCreditedAccount` |
| D-13 | `test_Donations_StayOutsideCreditsAndClaims` |
| D-14 | `test_Reentrancy_DuringClaimTransferIsBlocked` |
| D-15 | `test_StaleSignatures_FailAfterTermination` |
| D-16 | `test_Counters_TrackEverySettlementPath` |
| D-17 | all Stage 1/2 suites; `test_Submit_RecordsReviewDeadline` sets the clock before funding |
| D-18 | `TrustWorkFactory.t.sol`: `test_RevertWhen_FeeRecipientIsPredictedOrderAddress`, `test_RevertWhen_DirectlyDeployedOrderIsOwnFeeRecipient` |
| D-19 | `test_CreateWorkOrder_AllowsFeeRecipientAliases`, `test_FeeRecipientAliases_SettleAndConserve` |
| Matrix (3 funding paths × reclaim first/middle/last) | `test_Matrix_FundingPathTimesReclaimPosition` (9 cases) |
| DF-01 | `WorkOrder.fuzz.t.sol`: `testFuzz_SubmitAndReclaimAreExclusiveAtEveryInstant` |
| DF-02 | `testFuzz_SettleThenReclaimConservesFunds` |
| DI-01 | `invariant_FundedTotalIsConserved` |
| DI-02 | `invariant_BalanceCoversObligations` |
| DI-03 | `invariant_ObligationsMatchStatus` |
| DI-04 | `invariant_ApprovalNonceCountsSettlementsAndTermination` |

## 11. S2 implementation map

Added in S2: R-27 (constructor validation, including `penaltyRecipient` equal to the court or the registry and a
contract recipient accepted), R-28 (`seatLock` above `uint128`), R-29 (failed outgoing transfers roll back delisting,
seat state and counters). Added in the S2 corrective pass: R-30 (per-account principal limit), RF-04 (boundary fuzz
around `type(uint128).max`), RI-08 (principal within limit) and an all-warming gas fixture for R-24.

| Cases | Test (`test/registry/ArbitratorRegistry.t.sol` unless noted) |
| --- | --- |
| R-01 | `test_Deposit_AddsWarmingStakeAndLists`, `test_RevertWhen_DepositZero`, `test_RevertWhen_DepositReceivesInexactAmount` |
| R-02 | `test_Admission_RequiresListingMinimum`, `test_Admission_DelistedRemainderCanRelist` |
| R-03 | `test_RevertWhen_RegistryFull`, `test_Capacity_DelistedSlotIsReusableWhenFull` |
| R-04 | `test_RevertWhen_PenaltyRecipientDeposits` |
| R-05 | `test_Activation_ExactBoundary` |
| R-06 | `test_TopUp_RestartsWarmingBucketOnly` |
| R-07 | `test_Withdraw_TransfersExactAmount`, `test_RevertWhen_WithdrawInvalidAmount` |
| R-08 | `test_Withdraw_DelistsWithSwapAndPopAndFreesSlot` |
| R-09 | `test_FullPenalty_RemovesExhaustedAccount` |
| R-10 | `test_PartialPenalty_KeepsOtherReservation` |
| R-11 | `test_PenaltyBelowMinimum_DelistsAndRemainderIsWithdrawable` |
| R-12 | `test_RevertWhen_CourtFunctionsCalledByOthers` |
| R-13 | `test_Snapshot_StoresEligibleListedAccountsInOrder` |
| R-14 | `test_RevertWhen_TooFewCandidatesWritesNothing` |
| R-15 | `test_RevertWhen_SnapshotTakenTwice` |
| R-16 | `test_Snapshot_UnaffectedByLaterRegistryActivity` |
| R-17 | `test_RevertWhen_WithdrawingReservedStake` |
| R-18 | `test_Concurrency_CollateralBacksOneObligationEach` |
| R-19 | `test_SelectPanel_LocksSelectedAndReleasesOthers`, `test_SelectPanel_CanSelectFirstMiddleAndLastCandidates` |
| R-20 | `test_RevertWhen_SnapshotStateTransitionRepeated` |
| R-21 | `test_RevertWhen_ReleaseSeatUnknownOrNotLocked` |
| R-22 | `test_ReleaseReservations_ReturnsEveryReservation`, `test_ZeroPenaltyRelease_MovesNoTokens` |
| R-23 | `test_SlotReuse_SnapshotKeepsOriginalIdentities` |
| R-24 | `ArbitratorRegistry.gas.t.sol`: `test_Gas_SnapshotSelectAndRelease` |
| R-25 | `test_Donations_CreateNoPrincipal` |
| R-26 | `test_Reentrancy_DuringDepositWithdrawAndPenaltyIsBlocked` |
| R-27 | `test_Constructor_StoresTermsAndDeployerIsCourt`, `test_RevertWhen_ConstructorInputsInvalid`, `test_RevertWhen_PenaltyRecipientIsCourt`, `test_RevertWhen_PenaltyRecipientIsRegistry`, `test_Constructor_AcceptsContractPenaltyRecipient` |
| R-28 | `test_RevertWhen_SeatLockExceedsUint128` |
| R-29 | `test_RevertWhen_WithdrawTransferFailsRollsBackDelisting`, `test_RevertWhen_PenaltyTransferFailsRollsBackRelease` |
| R-30 | Principal limit, deterministic (`ArbitratorRegistry.principal.t.sol`): `test_PrincipalAtLimit_MaturesAndWithdraws`, `test_RevertWhen_TopUpAtMaturedLimit`, `test_MixedPrincipal_ExactCapacitySucceedsAndOneMoreFails`, `test_RepeatedTopUpsCannotBypassLimit`, `test_RevertWhen_DepositOversized`, `test_RejectedDeposit_PreservesAllState`, `test_AfterRejectedTopUp_WithdrawalsAndSnapshotsSucceed`, `test_MaxPrincipalConstant` |
| RF-04 | Principal limit, fuzz: `testFuzz_DepositSequenceStaysWithinLimit`, `testFuzz_OversizedDepositRejectedWithoutChanges`, `testFuzz_NearLimitAccountStaysUsable` |
| RI-08 | `invariant_PrincipalWithinLimit`; handler action `depositNearLimit` deposits remaining capacity ± 2 or an unbounded amount |
| R-24 (all-warming) | `ArbitratorRegistry.gas.t.sol`: `ArbitratorRegistryAllWarmingGasTest.test_Gas_SnapshotSelectAndRelease` |
| M0 | `ArbitratorRegistry.matrix.t.sol`: `test_MatrixM0_SplitStakeGainsSeats` (all 10 triples observed through registry draws), `test_MatrixM0_UnsplitStakeHoldsOneSeat` |
| RF-01 | `ArbitratorRegistry.fuzz.t.sol`: `testFuzz_MatchesReferenceModel` |
| RF-02 | `testFuzz_PanelComesFromStoredSnapshot` |
| RF-03 | `testFuzz_SelectionFrequenciesAreNearUniform` (fuzz); `test_PanelSelection_RevertWhen_FewerThanThreeCandidates` is a deterministic test in the same file |
| RI-01 | `test/invariant/ArbitratorRegistry.invariant.t.sol`: `invariant_CommitmentsNeverExceedStake` |
| RI-02 | `invariant_CommitmentsMatchLiveCandidacies` |
| RI-03 | `invariant_TotalStakedIsSumOfPrincipal` |
| RI-04 | `invariant_CumulativeFlowsBalance` |
| RI-05 | `invariant_BalanceIsPrincipalPlusDonations` |
| RI-06 | `invariant_ListingMatchesPrincipal` |
| RI-07 | `invariant_SnapshotsMatchGhostHistory` |

The registry invariant campaign starts from four funded and activated actors (set up through the handler so the
ghost model records them); without that seed state, random sequences almost never formed a snapshot.

## 12. S3 implementation map

Deviations in S3: C-24 uses `BlocklistToken` blocking the court as recipient instead of a `PausableMockToken` (the
registry's penalty transfer to the court fails; "unpause" is unblocking). C-01 also covers the registry's own
restrictions surfacing through the court constructor and the added `PenaltyRecipientIsFactory`. C-26 enforces every
target except the all-warming first `openDispute`, which is logged as missed (2,170,188 against 2,000,000; see the
design, section 7.5).

| Cases | Test (`test/court/ArbitrationCourt.t.sol` unless noted) |
| --- | --- |
| C-01 | `test_Constructor_WiresFactoryRegistryAndTerms`, `test_RevertWhen_ConstructorInputsInvalid`, `test_RevertWhen_RegistryRestrictionsViolated` |
| C-02 | `test_RevertWhen_OpenedByUnknownOrder` |
| C-03 | `test_OpenDispute_PullsExactFee`, `test_RevertWhen_FeeCannotBePulled`, `test_RevertWhen_FeeTokenTakesTransferFee` |
| C-04 | `test_OpenDispute_StoresSnapshotAndArmsSelection`, `test_OpenDispute_WithTooFewCandidatesAwaitsCandidates` |
| C-05 | `test_RetrySnapshot_SucceedsOnceCandidatesExist` |
| C-06 | `test_RetrySnapshot_PanelDeadlineBoundary` |
| C-07 | `test_DrawPanel_SelectionBlockBoundary` |
| C-08 | `test_DrawPanel_ExpiredBlockhashRearmsSameSnapshot` |
| C-09 | `test_DrawPanel_IgnoresRegistryChangesAfterSnapshot` |
| C-10 | `test_DrawPanel_PanelDeadlineBoundaryAndNoPanelResolution`, `test_DrawPanel_AllowedOneSecondBeforePanelDeadline` |
| C-11 | `test_NoPanel_ReleasesReservationsWithoutPenalties` |
| C-12 | `test_RevertWhen_PanelDrawnTwice`, `test_RevertWhen_UnknownDispute` |
| C-13 | `test_RevertWhen_CommitInvalid` |
| C-14 | `test_Commit_DeadlineBoundary` |
| C-15 | `test_Reveal_PhaseBoundaries` |
| C-16 | `test_RevertWhen_RevealDoesNotMatchThenRetrySucceeds`, `test_RevertWhen_CommitmentFromAnotherDomainIsRevealed` |
| C-17 | `test_RevealVote_RejectsRawValuesOutsideVoteRange` |
| C-18 | `test_RevertWhen_RevealRepeatedOrUncommitted` |
| C-19 | `test_VoteCommitment_MatchesIndependentEncoding` |
| C-20 | `test_Resolve_RevealDeadlineBoundaryAndNoEarlyResolution` |
| C-21 | `test_Resolve_WorkedExampleRows` |
| C-22 | `test_FeeShareGrowsWhenAnotherSeatFaults` |
| C-23 | `test_ClaimReward_PaysAccountAndIsolatesFailures` |
| C-24 | `test_RevertWhen_PenaltyTransferFailsResolutionIsAtomic`, `test_RevertWhen_PenaltyReceiptDiffersFromPenalties` |
| C-25 | `test_ConcurrentDisputes_FaultIsolatedToItsDispute`, `test_Donations_CreateNoCredits` |
| C-26 | `ArbitrationCourt.gas.t.sol`: mixed and all-warming `test_Gas_CourtEntryPoints`, `test_Gas_RetrySnapshotAllWarming`, `test_Gas_RetrySnapshotMixed`, `test_Gas_OpenDisputeAllWarmingAfterEarlierDispute` |
| C-27 | `test_Reentrancy_DuringFeePullPenaltyTransferAndClaim` |
| M1 | `ArbitrationCourt.matrix.t.sol`: `test_MatrixM1_AllRevealPatterns` (asserts 125 cases) |
| M2 | `test_MatrixM2_PanelAvailability` (asserts 10 cases) |
| CF-01 | `ArbitrationCourt.fuzz.t.sol`: `testFuzz_ResolutionConservesFeesAndPenalties` |
| CF-02 | `testFuzz_OnlyTheAllowedActionSucceedsAtEachBoundary` (panel deadline, commit deadline, reveal deadline, selection block, each at offsets −2…+2) |
| CI-01 | `test/invariant/ArbitrationCourt.invariant.t.sol`: `invariant_CourtFlowsBalance` |
| CI-02 | `invariant_BalanceIsLiabilitiesPlusDonations` |
| CI-03 | `invariant_PendingFeesMatchUnresolvedDisputes` |
| CI-04 | `invariant_PenaltiesMatchRegistry` |
| CI-05 | `invariant_RegistryCommitmentsMatchDisputes` |
| CI-06 | `invariant_RulingsAndSnapshotsMatchHistory` |
| CI-07 | `afterInvariant` (warps past every deadline, resolves every dispute, then claims every credit) |

`invariant_CreditsMatchGhosts` additionally compares each account's credit with an independent ghost computed from
the handler's own record of commits and reveals. The court invariant campaign starts from six actors with matured
stake for three seats each, deposited through the handler; without it random sequences rarely form a panel.
`test_RandomCampaignsReachEveryTransition` replays 64 fixed pseudo-random campaigns of 64 calls through the same
handler, checks all invariants after every call and asserts that each core transition was reached.
