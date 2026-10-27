# Stage 4 — Test plan

Status: test plan for [stage-4-reputation-design.md](stage-4-reputation-design.md), with the Stage 4B clarifications.
The 4B cases of section 11 are implemented under `test/reputation/` and `test/invariant/TrustWorkReputation*.sol`;
the 4C receipt cases are not implemented.

## 1. Conventions

- Fixtures use the production `TrustWorkFactory`, `WorkOrder`, `ArbitrationCourt` and `ArbitratorRegistry` from
  Stage 3E and reuse the Stage 3E integration helpers to reach each order state. Every case marked **(2×)** runs in
  both the `SharedToken` (one token for escrow and stake) and `SplitToken` configurations.
- Expected outcomes, facts and counters are computed in the test from the scenario it drove (milestones settled,
  ruling forced, amounts chosen), never read back from `TrustWorkReputation` or from the order counters under test.
- Default order `[1000, 2500, 500]` USDC (6 decimals), `feeBps = 250`, client `C`, freelancer `F`, fee recipient `R`.
- "Unchanged" means every balance and counter of every order, the court and the registry, plus all `claimable`
  credits, is identical before and after the action.
- Case IDs are stable: `RA` authentication, `RE` eligibility, `RG` griefing and participation, `RS` statistics,
  `RR` receipt issuance, `RT` transfer, approval and burn, `RC` interface compliance, `RW` contract recipients,
  `RN` numeric boundaries, `RU` unchanged escrow, `RF` fuzz, `RI` invariants.

## 2. Factory authentication

| ID | Case |
| --- | --- |
| RA-01 | Constructor stores `factory`; a zero address reverts `ZeroFactory` and an address without code reverts `FactoryHasNoCode`; no owner, setter or administrative function exists (ABI check) |
| RA-02 | `register` of an order created by the bound factory succeeds once it is eligible |
| RA-03 | `register` of a `WorkOrder` deployed directly with the factory's court reverts `UnknownOrder` |
| RA-04 | `register` of an order created by a second `TrustWorkFactory` reverts `UnknownOrder` |
| RA-05 | `register` of an EOA, of the court, of the registry and of a mock contract that mimics the `WorkOrder` views reverts `UnknownOrder`, and the mock's views are never called (call trace) |
| RA-06 | `factsOf` for an unregistered order (genuine, unknown or zero address) reverts `NotRegistered` (4B) |
| RA-07 | Canonical-court guard: an order recognized by the bound factory whose `court()` differs from `factory.court()` reverts `CourtMismatch(order, orderCourt)` (mock factory and order) |
| RA-08 | Dispute link guard: a terminated order whose court dispute names another order, or another milestone index, reverts `InconsistentDispute(order, disputeId)` (mocks) |
| RA-09 | Ruling guard: every ruling/reason pair other than the four the court produces (including `None/None`) reverts `UnsupportedRuling(order, ruling, reason)` (mocks) |

## 3. Eligibility table (one case per row, (2×))

| ID | State | Expected |
| --- | --- | --- |
| RE-01 | `Unfunded` | `OrderNotFinal(order, Unfunded)` |
| RE-02 | `Active`, each of: m0 pending, m0 submitted, m1 submitted after m0 settled | `OrderNotFinal(order, Active)` |
| RE-03 | `Disputed`, court in `AwaitingCandidates`, `AwaitingSeed` and `Voting` | `OrderNotFinal(order, Disputed)` |
| RE-04 | `Disputed`, court `Resolved`, `applyRuling` not called | `OrderNotFinal(order, Disputed)`; after `applyRuling` the same order registers |
| RE-05 | `Completed` | outcome `Completed`; facts per design §5.4 |
| RE-06 | `Terminated` by delivery expiry at m0, no submission | `NoParticipation` |
| RE-07 | `Terminated` by delivery expiry at m1 and at m2 | outcome `DeliveryExpired`; `settledMilestones` 1 and 2 |
| RE-08 | `Terminated`, `FreelancerWins / Majority` | outcome `FreelancerWins` |
| RE-09 | `Terminated`, `ClientWins / Majority` | outcome `ClientWins` |
| RE-10 | `Terminated`, `Split / NoDecision` by tie and by zero reveals | outcome `Split` |
| RE-11 | `Terminated`, `FreelancerWins / NoPanel` from `AwaitingCandidates` and from `AwaitingSeed` | outcome `NoPanel`, never `FreelancerWins` |
| RE-12 | Every feasible terminal position: `Completed` after all milestones; each ruling and `NoPanel` with the dispute at the first, middle and last milestone; delivery expiry at the middle and last milestone (expiry at the first remains ineligible, RE-06) | `settledMilestones`, `disputedAmount`, `freelancerAwarded`, `clientReturned` per design §4 |
| RE-13 | Claim independence: for every terminal outcome, register before any claim, after some claims and after all order and court claims (separate snapshots, each registering at its own time) | identical outcome, business facts, counters and order lists; `registeredAt` equals each call's own block timestamp; complete records are compared only in a variant that registers at the same timestamp |
| RE-14 | `closedNotBefore` per outcome equals the independently known value (last submission, delivery deadline, `revealDeadline`, `panelDeadline`); `fundedAt` equals the funding block time; `registeredAt` equals the registration block time and is reported separately |
| RE-15 | Zero-timestamp submission: an order funded and submitted in a block with timestamp `0` (so `submittedAt == 0`) and then completed registers as `Completed`; participation comes from the first milestone's status, and `lastSubmittedAt` reports the true value |
| RE-16 | Participation evidence by first-milestone status: `Disputed` (dispute at the first milestone) and `Settled` are accepted; `Pending` is rejected |

## 4. Unsolicited orders and participation evidence

| ID | Case |
| --- | --- |
| RG-01 | A client creates, funds and reclaims an order naming victim `V` who never acts: `register` reverts `NoParticipation`; `V`'s stats, order lists and receipts are untouched |
| RG-02 | Same victim, ten such orders from different clients: all revert; `V`'s stats stay zero |
| RG-03 | An unfunded or active unsolicited order naming `V` cannot be registered at any time (`OrderNotFinal`) |
| RG-04 | `V` submits m0 of an order, then misses m1's deadline and the client reclaims: registers as `DeliveryExpired` (evidenced participation) |
| RG-05 | Nobody but the role holder can mint a receipt for `V`: `claimReceipt(order, Freelancer)` from the client, a third party and the fee recipient reverts `NotRoleHolder`; `balanceOf(V) == 0` |
| RG-06 | Hiding: after `F` loses `ClientWins`, the client and a third party can each register; `F` cannot block or undo it; a second registration by `F` reverts `AlreadyRegistered` |
| RG-07 | Wash order: one controller with client and freelancer addresses and a worthless token completes an order; it registers (no Sybil claim), and `factsOf` exposes the token, amounts and counterparty for filtering |
| RG-08 | Negligible value: order with one-unit milestones registers like any other; facts show the amounts |

## 5. Outcomes, facts and counters

| ID | Case |
| --- | --- |
| RS-01 | Each worked example row of design §5.4 (2×): exact facts and counters for client and freelancer roles |
| RS-02 | Repeated registration of every outcome reverts `AlreadyRegistered`; counters, order lists and `registeredAt` unchanged |
| RS-03 | Role overlap: fee recipient equal to the client, and to the freelancer. The fee-recipient position grants no additional entitlement (no extra counter, order-list entry or, in 4C, receipt); the address keeps exactly its client or freelancer role's normal entitlement, so counters equal the non-overlap case |
| RS-04 | One account as freelancer in order A and client in order B: role stats are separate and each order list holds one entry |
| RS-05 | Partition: `completed + deliveryExpired + freelancerWins + clientWins + splits + noPanel == registered` after a mixed sequence of registrations |
| RS-06 | `milestonesSettled` sums `settledMilestones` over registered orders |
| RS-07 | Derived metrics from design §5.3 computed off counters in the test (completion share, adjudicated share; undefined denominator handled) |
| RS-08 | `ordersOf` paging: empty, partial, exact and out-of-range pages; registration order preserved |
| RS-09 | Events: `OrderRegistered(order, outcome, client, freelancer)` exactly once per registration |
| RS-10 | Odd disputed amount (`D = 7` units, `Split`): freelancer 3 units, client 4 units plus `R` |
| RS-11 | `ordersOf` with `limit == 0`, `offset >= length`, `offset == type(uint256).max`, `limit == type(uint256).max` and both at maximum: empty or `min(limit, length - offset)` entries, never a revert |
| RS-12 | `statsOf(account, role)` returns the full `Stats` struct; an account with no registrations returns all zeros |

## 6. Receipts

### Issuance

| ID | Case |
| --- | --- |
| RR-01 | Client and freelancer each claim for every outcome; `ownerOf`, `balanceOf`, `receiptOf` and `receiptId` match `(order << 1) | role` |
| RR-02 | Second claim of the same `(order, role)` reverts `ReceiptAlreadyClaimed` |
| RR-03 | Claim after burn reverts `ReceiptAlreadyClaimed`; the token ID is never reissued |
| RR-04 | Token IDs of all receipts across many orders are distinct; `receiptOf` inverts `receiptId` |
| RR-05 | Event order at mint: `Transfer(0, holder, id)`, `Locked(id)`, `ReceiptClaimed`; `Unlocked` never emitted |
| RR-06 | Claiming never changes `outcome`, `registeredAt`, facts, counters or order lists; it sets exactly the claimed role's bit in `receiptsClaimed`, which never clears, including after burn |
| RR-07 | `claimReceipt` for an unregistered order reverts `NotRegistered`; `receiptOf` of a never-minted ID reverts `ERC721NonexistentToken` |

### Transfer, approval and burn

| ID | Case |
| --- | --- |
| RT-01 | `transferFrom`, `safeTransferFrom(from, to, id)` and `safeTransferFrom(from, to, id, data)` of an existing token by its holder to a nonzero recipient revert `ReceiptLocked(id)`; for nonexistent tokens and the zero recipient the standard `ERC721NonexistentToken` and `ERC721InvalidReceiver` errors are acceptable |
| RT-02 | Same calls by a third party revert (lock check or authorization); ownership unchanged |
| RT-03 | `approve` and `setApprovalForAll` revert `ApprovalsDisabled`; `getApproved` returns zero for existing and reverts for nonexistent tokens; `isApprovedForAll` is false |
| RT-04 | `burn` by the holder succeeds: `Transfer(holder, 0, id)`, `balanceOf` decreases, `locked` and `ownerOf` revert afterwards; records and counters unchanged |
| RT-05 | `burn` by anyone else, and of a nonexistent token, reverts |

### Interface compliance

| ID | Case |
| --- | --- |
| RC-01 | `supportsInterface` true for `0x01ffc9a7`, `0x80ac58cd`, `0x5b5e139f`, `0xb45a3c0e`; false for `0xffffffff` and a random ID |
| RC-02 | `locked(id)` true for every existing receipt; reverts `ERC721NonexistentToken` for never-minted and burned IDs |
| RC-03 | `name`, `symbol`; `tokenURI` empty for existing and reverting for nonexistent tokens |
| RC-04 | Locally declared `IERC5192` selector equals `0xb45a3c0e` (`type(IERC5192).interfaceId`) |

### Contract recipients

| ID | Case |
| --- | --- |
| RW-01 | Client is a contract wallet without `IERC721Receiver` that executes `claimReceipt`: mint succeeds, no callback is made |
| RW-02 | Client is a wallet whose `onERC721Received` reverts or re-enters `claimReceipt` / `register`: never called; mint succeeds once |
| RW-03 | A contract role holder that cannot initiate calls cannot claim; registration and counters are unaffected |

## 7. Isolation from escrow, court and registry

| ID | Case |
| --- | --- |
| RU-01 | (2×) For every outcome: `register` (4B) and both `claimReceipt` calls (4C) leave every order, court and registry balance, counter, credit, nonce and status unchanged, and emit no payment- or stake-token `Transfer`. The receipt contract's own ERC-721 mint and burn `Transfer` events in 4C are expected |
| RU-02 | (2×) Settlement, `openDispute`, `resolve`, `applyRuling`, `claimPayout` and `claimReward` behave identically with the reputation contract deployed, absent, or holding records for the same orders |
| RU-03 | (2×) Order and court claims succeed before and after registration and receipt claims, in either order |

## 8. Numeric boundaries

| ID | Case |
| --- | --- |
| RN-01 | Order total `type(uint256).max - small` (representable supply): every outcome registers; facts exact; `freelancerAwarded + clientReturned == totalAmount` |
| RN-02 | Two such near-maximum orders for the same accounts register without overflow (no monetary aggregate exists); counters equal 2 |
| RN-03 | One-unit milestones and `feeBps = 0` and `1000`: facts exact |
| RN-04 | Order with many milestones (for example 50) completed: `milestonesSettled` exact |

## 9. Fuzz

| ID | Property |
| --- | --- |
| RF-01 | (2×) Sampled milestone amounts, `feeBps`, terminal path and disputed index: `factsOf` equals an independent model, `freelancerAwarded + clientReturned == totalAmount`, and counters change by exactly one outcome per role |
| RF-02 | (2×) Sampled claim schedules before and after registration: identical classification, business facts, counters and order lists; `registeredAt` equals each registration's own timestamp |
| RF-03 | Sampled distinct `(order, role)` pairs: `receiptId` is injective (pure function, no minted tokens needed) |
| RF-04 | Sampled minted receipts: `receiptOf(receiptId(o, r)) == (o, r)` for every existing token |

## 10. Invariants (handler: Stage 3E integration actions plus register, claim receipt, burn, transfer attempts)

| ID | Property |
| --- | --- |
| RI-01 | For every account and role, the outcome counters sum to `registered`, and `registered == orderCount(account, role)` |
| RI-02 | Every registered order is a factory order, was final and had a first milestone that was not `Pending` at registration; its outcome equals the handler's ghost |
| RI-03 | `outcome`, `registeredAt` and `factsOf` of a registered order never change afterwards; `receiptsClaimed` stays `0` in 4B and in 4C only gains bits |
| RI-04 | Every existing receipt is locked and owned by its role holder; receipts are never transferred (ghost of `Transfer` events: only mints and burns) |
| RI-05 | At most one mint per `(order, role)` over the whole campaign, burned or not |
| RI-06 | The Stage 3E integration invariants II-01…II-08 hold unchanged with reputation actions interleaved |

Campaign reports list registrations by outcome, rejected registrations by reason (`OrderNotFinal`,
`NoParticipation`, `AlreadyRegistered`, `UnknownOrder`), and in 4C receipts claimed and burned, and rejected transfers.

## 11. Slice acceptance

| Slice | Cases |
| --- | --- |
| 4B | RA-01…RA-09, RE-01…RE-16, RG-01…RG-04, RG-06…RG-08, RS-01…RS-12, RU-01…RU-03 (registration part), RN-01…RN-04, RF-01, RF-02, RI-01…RI-03, RI-06 |
| 4C | RG-05, RR-01…RR-07, RT-01…RT-05, RC-01…RC-04, RW-01…RW-03, RU-01 and RU-03 (receipt part), RF-03, RF-04, RI-04, RI-05 |

A slice is accepted only when `forge fmt --check`, `forge build` (diagnostics listed), `forge test` and
`forge coverage` are reported from actual output, all its cases pass, earlier suites are unchanged in intent,
production coverage of the new contract is 100% (or each gap explained), and sizes are within EIP-170.

## 12. 4B implementation map

All `test/reputation/TrustWorkReputation.t.sol` cases except the guard tests run in `SharedToken` and `SplitToken`
(abstract suite with two concrete contracts). Expected facts come from `test/utils/ReputationTestBase.sol`, which
drives production orders and records times and amounts itself.

| Cases | Test (`test/reputation/TrustWorkReputation.t.sol` unless noted) |
| --- | --- |
| RA-01 | `test_Constructor_BindsFactoryAndHasNoAdministration` (also runtime below 24,576 B) |
| RA-02 | `test_Register_AcceptsEligibleFactoryOrder` |
| RA-03, RA-04, RA-05 | `test_RevertWhen_OrderNotCreatedByBoundFactory` (direct order, second factory, EOA, court, registry, zero address, and a mock mimicking order views that is never called: `vm.expectCall(mock, "", 0)`) |
| RA-06 | `test_RevertWhen_FactsOfUnregisteredOrder` |
| RA-07 | `TrustWorkReputationGuardTest.test_RevertWhen_OrderCourtDiffersFromFactoryCourt` |
| RA-08 | `TrustWorkReputationGuardTest.test_RevertWhen_DisputeRecordInconsistent` |
| RA-09 | `TrustWorkReputationGuardTest.test_RevertWhen_RulingReasonPairUnsupported` (all 16 pairs; 4 accepted) |
| RE-01, RE-02, RG-03 | `test_RevertWhen_OrderUnfundedOrActive` |
| RE-03, RE-04 | `test_RevertWhen_OrderDisputedUntilRulingApplied` |
| RE-05, RE-14 | `test_Register_Completed`; times are asserted in every registration through `_register` |
| RE-06, RG-01, RE-16 (`Pending`) | `test_RevertWhen_ExpiredBeforeAnySubmission` |
| RE-07, RG-04 | `test_Register_DeliveryExpiredAfterParticipation` |
| RE-08…RE-10, RE-16 | `test_Register_EveryRulingOutcome` |
| RE-11, RE-16 (`Disputed`) | `test_Register_NoPanelFromBothWaitingStates` |
| RE-12 | `test_Register_EveryFeasibleTerminalPosition` (asserts 18 cases: 5 rulings × 3 positions, 2 expiries, 1 completion) |
| RE-13 | `test_Register_IndependentOfClaimTiming` |
| RE-15 | `test_Register_ZeroTimestampSubmissionIsParticipation` |
| RG-02 | `test_UnsolicitedOrders_NeverAffectInactiveVictim` |
| RG-06 | `test_Hiding_LosingPartyCannotBlockOrUndo` |
| RG-07, RG-08 | `test_WashAndNegligibleOrders_RegisterWithInspectableFacts` |
| RS-01, RS-10 | `test_WorkedExamples` |
| RS-02 | `test_RevertWhen_RegisteredTwice` |
| RS-03 | `test_RoleOverlap_FeeRecipientPositionGrantsNothing` |
| RS-04 | `test_RoleStatistics_SeparatePerRole` |
| RS-05, RS-06, RS-07, RS-09 | `test_Statistics_PartitionMilestonesAndDerivedShares` |
| RS-08, RS-11, RS-12 | `test_OrdersOf_PagingBoundaries` |
| RU-01 | `test_Register_LeavesEscrowCourtAndRegistryUnchanged` |
| RU-02, RU-03 | `test_Claims_IdenticalWithOrWithoutRegistration` |
| RN-01, RN-02 | `test_NearMaximumTotals_RegisterWithoutOverflow` |
| RN-03 | `test_UnitMilestonesAndFeeBounds` |
| RN-04 | `test_ManyMilestones_Completed` |
| RF-01 | `TrustWorkReputation.fuzz.t.sol`: `testFuzz_FactsMatchModel` |
| RF-02 | `testFuzz_ClaimScheduleDoesNotChangeFacts` |
| RI-01 | `test/invariant/TrustWorkReputation.invariant.t.sol`: `invariant_CountersPartitionRegistrations` |
| RI-02 | `invariant_RegisteredOrdersWereEligible` |
| RI-03 | `invariant_RecordsAndFactsNeverChange` |
| RI-06 | the inherited `invariant_*` of `TrustWorkIntegration.invariant.t.sol` (II-01…II-08) |

The reputation handler extends the Stage 3E integration handler. Every registration attempt also asserts that the
order's status, nonce, counters and credits and the court's and registry's counters and balances are unchanged.
`test_RandomCampaignsRegisterEveryOutcome` replays 32 fixed campaigns of 128 calls with registrations interleaved,
checks all Stage 3E and reputation invariants after every call, registers every order at the end, and requires every
outcome and every rejection reason (`OrderNotFinal`, `NoParticipation`, `AlreadyRegistered`, `UnknownOrder`). The
inherited Stage 3E replay keeps its original call mix. `TrustWorkReputation.gas.t.sol` reports registration gas for
representative outcomes without a threshold.
