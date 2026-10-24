# Stage 3 — Test plan

Companion to [stage-3-arbitration-design.md](stage-3-arbitration-design.md). Section references (§) point to that
document. Case IDs are stable so implementation slices can report them.

## 1. Conventions

- **Unit** tests are deterministic and assert exact state, balances, events and revert data.
- **Matrix** tests are deterministic loops over an explicit, fully enumerated input table. They are the only tests
  that may claim guaranteed coverage of a combination space.
- **Fuzz** tests sample bounded inputs. Each run executes one sampled combination; a campaign of N runs does not
  enumerate the combination space, and reports must say "sampled", never "covered every combination".
- **Invariant** tests drive a handler through random action sequences and check properties after every call. Their
  reports state per-campaign transition counters from the final run and, where useful, aggregated samples across
  seeds; they are evidence of reachability, not exhaustive coverage.
- Boundary tests always check three instants: `deadline - 1`, `deadline`, `deadline + 1`.
- Every revert test also asserts that the relevant state is unchanged: order status, milestone status,
  `approvalNonce`, `outstandingObligations`, balances, registry account, court dispute.
- Mocks stay under `test/`. Reused: `MockUSDC`, `MockPermitUSDC`, `BlocklistToken`, `FeeOnTransferToken`,
  `ReentrantToken`, `MockERC1271Wallet`. New: `MockArbitrationFactory` and `MockDisputableOrder` (S3 only),
  `RegistryCourtHarness` (S2 only).

**Correction to the Stage 2 report.** The Stage 2 handoff said the lifecycle fuzz test "covers every combination of
funding path and settlement path in each run". That is inaccurate: each run picks one funding path and one
settlement path per milestone from fuzzed bits, so combinations are sampled across runs. The Stage 3 matrices below
(M1–M6) provide the guaranteed coverage.

## 2. Slice S1 — delivery deadline and reclaim

### Unit

| ID | Case |
| --- | --- |
| D-01 | Constructor rejects `deliveryPeriod == 0` and `> MAX_DELIVERY_PERIOD`; accepts 1 and `MAX_DELIVERY_PERIOD` |
| D-02 | Funding sets `m[0].deliveryDeadline = fundedAt + deliveryPeriod`, both funding paths |
| D-03 | Settlement of `k` sets `m[k+1].deliveryDeadline = settledAt + deliveryPeriod` for direct, signed and timeout settlement |
| D-04 | `submitMilestone` at `deliveryDeadline - 1` succeeds; at `deliveryDeadline` and `+ 1` reverts `DeliveryPeriodElapsed` |
| D-05 | `reclaimAfterDeliveryExpiry` at `deliveryDeadline - 1` reverts `DeliveryPeriodNotElapsed`; at the deadline succeeds |
| D-06 | Reclaim at milestone 0, a middle milestone and the last milestone: refund equals unsettled sum; `outstanding == 0`; `Terminated`; `approvalNonce` incremented once; `DeliveryExpired` emitted |
| D-07 | Reclaim reverts for non-client callers (`NotClient`), when `Unfunded`, `Completed`, `Terminated`, and when the current milestone is `Submitted` (even far past the delivery deadline) |
| D-08 | After reclaim every mutating function reverts with `InvalidOrderStatus(Terminated)`, except `claimPayout`, which reverts `NothingToClaim` because reclaim pays directly |
| D-09 | Donation before and after funding: reclaim refunds only obligations; donation remains in the order |
| D-10 | Reclaim with a blocklisted client reverts and leaves state unchanged; succeeds after unblocking |
| D-11 | `ReentrantToken` callback during the reclaim transfer re-entering reclaim, approve, finalize: blocked with `ReentrancyGuardReentrantCall` |
| D-12 | Pre-signed approval for the current milestone fails after reclaim (`InvalidOrderStatus`) |
| D-13 | Regression: every Stage 1/2 unit test passes with the added constructor arguments and unchanged assertions |

### Fuzz

| ID | Case |
| --- | --- |
| DF-01 | `deliveryPeriod ∈ [1, MAX]`, elapsed `∈ [0, 2·MAX]`: exactly one of submit / reclaim succeeds at each sampled instant |
| DF-02 | Sampled lifecycle with a sampled stopping point: settle a sampled number of milestones, then reclaim; refund + paid out == total |

## 3. Slice S2 — arbitrator registry

Tests use `RegistryCourtHarness`, which deploys the registry (becoming its court) and exposes `drawAndLock` and
`release`.

### Unit

| ID | Case |
| --- | --- |
| R-01 | Deposit: exact transfer, `warming`, `warmingUntil`, `totalStaked`, event; zero amount reverts; fee-on-transfer token reverts |
| R-02 | Maturity boundary: stake ineligible at `warmingUntil - 1` reference time, eligible at `warmingUntil` |
| R-03 | Top-up while warming resets `warmingUntil` for the whole warming bucket; matured stake is unaffected |
| R-04 | Registration up to 64 accounts; the 65th distinct depositor reverts `RegistryFull`; an existing account can top up when full |
| R-05 | Empty account removed by swap-and-pop on withdraw; list indices remain consistent; slot is reusable |
| R-06 | `requestWithdrawal` above `stake` reverts; a new request replaces the old one and resets the timer; `0` cancels |
| R-07 | Withdraw at `withdrawableAt - 1` reverts; at `withdrawableAt` transfers `min(pending, stake - locked)` |
| R-08 | Partial withdrawal while locked: remainder stays pending; completes after `release` |
| R-09 | Pending stake is lockable before `withdrawableAt` and excluded for reference times `>= withdrawableAt` |
| R-10 | `drawAndLock` / `release` revert for any caller other than the court |
| R-11 | `release` with penalty: `stake` and `locked` reduced, penalty transferred to the court, `totalStaked` reduced |
| R-12 | `eligibleSeats` integer division: `stake = 350`, `seatLock = 100` → 3; fourth concurrent draw sees 0 |
| R-13 | Excluded addresses (client, freelancer, fee recipient) are never selected, even with the largest stake |
| R-14 | Fewer than 3 eligible accounts → `drawn == false`, no state written |
| R-15 | Exactly 3 eligible → all three selected, each locked once |
| R-16 | No address appears twice in one panel for seeds that would hit it repeatedly (constructed seeds) |
| R-17 | Weighted walk boundaries: constructed seeds that land on the first unit, the last unit, and the boundary between two accounts select the expected accounts |
| R-18 | Gas: `drawAndLock` with 64 accounts stays below 1,500,000 gas (`vm.lastCallGas` / gas snapshot) |
| R-19 | Donations to the registry do not change `totalStaked` or any account and cannot be withdrawn |
| R-20 | `ReentrantToken` callbacks during deposit, withdraw and penalty transfer: re-entry blocked |

### Fuzz

| ID | Case |
| --- | --- |
| RF-01 | Sampled deposits, requests and withdrawals with bounded amounts and times: balances match a reference model |
| RF-02 | Sampled stake distributions (≤ 64 accounts) and seeds: panel has 3 distinct eligible, non-excluded members; locks equal `3 · seatLock` |
| RF-03 | Selection frequency over many seeds for a fixed distribution is within a stated tolerance of capacity weights (statistical sanity check, not a proof of fairness) |

### Invariants (handler: deposit, request, withdraw, warp, draw, release, donate)

| ID | Property |
| --- | --- |
| RI-01 | `locked <= stake` for every account |
| RI-02 | `sum(locked) == seatLock · openSeats` (handler ghost) |
| RI-03 | `totalStaked == sum(stake + warming)` |
| RI-04 | `balanceOf(registry) == totalStaked + donations` |
| RI-05 | Total withdrawn + total penalized + `totalStaked` == total deposited |
| RI-06 | `arbitratorCount <= 64` and the list contains no duplicates or empty accounts |

## 4. Slice S3 — arbitration court

Tests use `MockArbitrationFactory` (deploys the court, answers `isWorkOrder`) and `MockDisputableOrder` (exposes
parties and calls `openDispute`).

### Unit

| ID | Case |
| --- | --- |
| C-01 | Constructor validation: zero token, token without code, zero fee, zero `seatLock`, zero `penaltyRecipient` |
| C-02 | `openDispute` from an address the factory does not recognize reverts `UnknownOrder` |
| C-03 | `openDispute` pulls exactly `disputeFee` from the client; insufficient allowance or balance reverts; fee-on-transfer token reverts |
| C-04 | Parties are read from the order; dispute fields and `selectionBlock = block.number + 10` |
| C-05 | `drawPanel` at `selectionBlock` reverts; at `selectionBlock + 1` draws |
| C-06 | Blockhash expiry: draw at `selectionBlock + 257` re-arms and emits `SelectionRearmed`; draw after the new seed block succeeds |
| C-07 | Insufficient eligible arbitrators re-arms; a retry succeeds after another dispute's `resolve` releases enough locks; stake deposited after `openedAt`, or warming stake maturing after `openedAt`, never counts |
| C-08 | `drawPanel` at `panelDeadline - 1` allowed; at `panelDeadline` reverts; `resolve` at `panelDeadline - 1` reverts, at `panelDeadline` gives `Split (NoPanel)` |
| C-09 | Repeated `drawPanel` after drawing reverts |
| C-10 | Commit by a non-panelist reverts; zero commitment reverts; duplicate commit reverts `AlreadyCommitted` |
| C-11 | Commit at `commitDeadline - 1` succeeds; at `commitDeadline` reverts |
| C-12 | Reveal at `commitDeadline - 1` reverts; at `commitDeadline` succeeds; at `revealDeadline` reverts |
| C-13 | Reveal with wrong salt, wrong vote, another arbitrator's commitment, or a commitment built for another dispute, court or chain: `InvalidReveal`, retry with correct data succeeds |
| C-14 | Reveal of vote `0` or `3` reverts `InvalidVote`; a seat committed to such a vote ends faulty |
| C-15 | Duplicate reveal reverts `AlreadyRevealed` |
| C-16 | `voteCommitment` equals an independently computed `keccak256(abi.encode(...))` |
| C-17 | `resolve` at `revealDeadline - 1` reverts; at `revealDeadline` succeeds; second `resolve` reverts |
| C-18 | Reward and penalty arithmetic for each row of §11.3 with exact amounts and dust |
| C-19 | Penalties and unearned fees credited to `penaltyRecipient`, never to parties or panelists |
| C-20 | `claimReward` pays `account`; zero claim reverts; blocklisted account's claim reverts without affecting others' claims or the recorded ruling |
| C-21 | Penalty transfer failure during `resolve` (registry token paused in a mock) reverts `resolve` atomically; retry after unpause succeeds |
| C-22 | Concurrent disputes: one arbitrator on several panels; locks and releases per dispute; a fault in one dispute does not affect locks in another |
| C-23 | Reentrancy: callbacks during fee pull, penalty transfer and claim attempt `resolve`, `claimReward`, `drawPanel`: blocked |

### Matrix M1 — reveal patterns (guaranteed)

Each seat takes one of 5 behaviors: `NoCommit`, `CommitNoReveal`, `CommitUnrevealableVote`, `RevealFreelancer`,
`RevealClient`. The test loops over all `5^3 = 125` assignments, each in a fresh dispute, and asserts:

- ruling and `SplitReason` per §9.3;
- `validReveals`, `rewardPerReveal`, penalties `P · L`, `penaltyRecipient` credit;
- `rewards + recipientCredit == F + P · L`;
- every seat's lock released; faulty seats lose exactly `L`.

### Matrix M2 — panel availability (guaranteed)

Eligible counts `{0, 1, 2, 3, 4}` × draw attempt `{called before panelDeadline, never called}` = 10 cases. A panel
forms only with at least 3 eligible accounts and a draw call; every other case resolves to `Split (NoPanel)` at
`panelDeadline`, with the fee flow per §11.3.

### Fuzz

| ID | Case |
| --- | --- |
| CF-01 | Sampled `disputeFee`, `seatLock`, reveal counts: conservation `rewards + recipient = F + P · L` |
| CF-02 | Sampled times around every court boundary: exactly the allowed action succeeds |

### Invariants (handler: open, draw, commit, reveal, warp, resolve, claim, deposit, withdraw, donate)

| ID | Property |
| --- | --- |
| CI-01 | `balanceOf(court) == pendingFees + totalClaimable + donations` |
| CI-02 | `pendingFees == disputeFee · unresolvedDisputes` |
| CI-03 | `registry.locked(a) == seatLock · openSeats(a)` for every account |
| CI-04 | Resolved disputes never change ruling; `rulingOf` is `None` exactly for unresolved disputes |
| CI-05 | Sum of all fees paid in == rewards claimed + rewards unclaimed + recipient credits + pending fees |
| CI-06 | Every dispute reaches `Resolved` when the handler warps past `panelDeadline + COMMIT + REVEAL` and calls resolve (bounded terminal path) |

## 5. Slice S4 — integration

### Unit

| ID | Case |
| --- | --- |
| I-01 | Factory constructor deploys court and registry; `factory.court().factory() == factory`; `court.registry().court() == court`; parameters wired |
| I-02 | `isWorkOrder` true for factory-created orders, false for arbitrary addresses and directly deployed `WorkOrder` contracts |
| I-03 | `openDispute` by non-client reverts `NotClient`; on `Unfunded`, `Completed`, `Terminated`, `Disputed` reverts `InvalidOrderStatus` |
| I-04 | `openDispute` on a `Pending` milestone reverts `InvalidMilestoneStatus`; on a non-current index reverts `NotCurrentMilestone` |
| I-05 | Dispute at `reviewDeadline - 1` succeeds; at `reviewDeadline` reverts `ReviewPeriodElapsed`, and finalization succeeds instead |
| I-06 | Race at `reviewDeadline - 1` in one block: approve then dispute (dispute reverts), and dispute then approve (approve reverts); same for signed approval |
| I-07 | Race at `reviewDeadline`: dispute reverts in either order; finalize and approve each settle once |
| I-08 | `openDispute` increments `approvalNonce`; `DisputeOpened` reports the consumed nonce |
| I-09 | Stale signatures after dispute: signature for the disputed milestone fails; pre-signed signature for milestone `k+1` with nonce `k+1` fails on status; both still fail after `applyRuling` |
| I-10 | Missing court allowance: `openDispute` reverts and order state, nonce and balances are unchanged |
| I-11 | While `Disputed`, every blocked function in §3.5 reverts `InvalidOrderStatus(Disputed)` |
| I-12 | `applyRuling` before `resolve` reverts `RulingNotReady`; after, credits per §11.1; second call reverts |
| I-13 | `claimPayout` for client, freelancer, fee recipient: exact amounts; zero claim reverts; blocklisted freelancer's claim reverts while client and fee recipient claim successfully; retry after unblocking succeeds |
| I-14 | `claimPayout` called by a third party pays the account, not the caller |
| I-15 | Fee recipient equal to client: credits accumulate in one entry and conservation holds |
| I-16 | ERC-1271 client opens a dispute (contract wallet approves the court) |
| I-17 | Reentrancy: `ReentrantToken` as order token during `claimPayout` re-entering claims and `applyRuling`; as court token during the fee pull re-entering `openDispute` and order functions: blocked |
| I-18 | Donations to order, court and registry during a dispute change no liability and no credit |
| I-19 | Bytecode: `forge build --sizes` within EIP-170 runtime and EIP-3860 initcode limits |

### Matrix M3 — terminal outcome × dispute position (guaranteed)

Rulings `{FreelancerWins, ClientWins, Split (NoDecision), Split (NoPanel), Split (zero reveals)}` × disputed milestone
position `{first, middle, last}` = 15 cases on the `[1000, 2500, 500]` order with `feeBps = 250`. Each asserts the
credits from §11.1, the claims, `outstanding == 0` after all claims, and order balance equal to donations.

### Matrix M4 — terminal path × funding path (guaranteed)

Funding `{fund, valid permit, failed permit with allowance}` × terminal path `{Completed, delivery expiry at first,
delivery expiry at last, FreelancerWins, ClientWins, Split}` = 18 cases. Asserts the revised nonce invariant (§5.1)
and total conservation.

### Matrix M5 — settlement path per milestone (guaranteed)

For a 3-milestone order, every assignment of `{direct, signed, timeout}` to the three milestones = 27 cases, each
ending in `Completed`, asserting `approvalNonce == 3` and fees. This replaces the Stage 2 claim of "all combinations"
with an actual enumeration.

### Matrix M6 — boundaries (guaranteed)

For each boundary in §4: `{t - 1, t, t + 1}` × each competing action. Expected success/revert is tabulated in the
test and must match §4 exactly.

### Fuzz

| ID | Case |
| --- | --- |
| IF-01 | Sampled milestone amounts (including amounts near `type(uint256).max` in a separate deterministic case), `feeBps`, disputed index and ruling: credits sum to `D + R`, fee formula independent of `WorkOrder.feeFor` |
| IF-02 | Sampled lifecycle: funding path, settlements before the dispute, and terminal path; revised nonce invariant and conservation at every step |

### Invariants (handler covers order, court and registry actions together)

| ID | Property |
| --- | --- |
| II-01 | Order: `balanceOf(order) == outstandingObligations + donations` |
| II-02 | Order `Active`/`Disputed`: `outstanding == sum(unsettled milestone amounts)`; `Terminated`: `outstanding == sum(claimable)` |
| II-03 | Revised nonce invariant (§5.1) |
| II-04 | Total funded == settled payouts + claimed credits + unclaimed credits + refunds (per order) |
| II-05 | Court and registry invariants CI-01…CI-03, RI-01…RI-04 hold with real orders |
| II-06 | An order has at most one dispute; `disputeId != 0` iff status is `Disputed` or terminated by ruling |
| II-07 | No escrow token ever appears in court or registry balances, and no stake token ever enters an order, beyond donations |

Invariant reports list, per campaign: terminal states reached, rulings by kind, funding paths, settlement paths,
rejected stale signatures, re-arms, and faults. They are reported as sampled counts.

## 6. Requirement traceability

| Requirement | Cases |
| --- | --- |
| Every transition and deadline boundary | D-02…D-06, C-04…C-17, I-05…I-07, M6 |
| Unauthorized operations | D-07, R-10, C-02, C-10, I-03 |
| Dispute vs approval/finalization races | I-06, I-07, M6 |
| Stale signatures after dispute transitions | D-12, I-08, I-09 |
| Concurrent stake locks and withdrawal attempts | R-08, R-09, R-12, C-22, RI-01, RI-02 |
| Missing arbitrators, commits and reveals | R-14, C-07, C-08, M1, M2 |
| Tie and fallback outcomes | M1, M2, M3 |
| Repeated resolution, application, claims | C-09, C-17, C-20, I-12, I-13 |
| Failed transfers and callbacks | D-10, D-11, R-20, C-20, C-21, C-23, I-13, I-17 |
| Conservation of escrow, stake and fee liabilities | RI-03…RI-05, CI-01, CI-02, CI-05, II-01…II-04, M1, M3, M4 |

## 7. Slice acceptance

A slice is accepted only when all of the following are reported with actual command output:

- `forge fmt --check`, `forge build` (with warnings listed), `forge test`, `forge coverage`;
- every case ID of the slice present and passing, plus all earlier suites unchanged in intent;
- 100% line and branch coverage for the slice's production contracts, or each uncovered line explained;
- matrices reported as enumerated counts (for example "M1: 125/125"), fuzz and invariant results reported as sampled.
