# TrustWork

Milestone-based freelance escrow. Portfolio project, unaudited, testnet-oriented.

## Scope

The project is built in stages. Each stage is implemented only after the previous one is reviewed.

Stage 1 (accepted, `3440319`): escrow core.

- `TrustWorkFactory` deploys independent `WorkOrder` contracts; the caller becomes the client.
- `WorkOrder` holds the full milestone budget, settles milestones strictly in order on client
  approval or after the review deadline, and pays the fee recipient and freelancer.
- Test-only token mocks, Foundry unit, fuzz and invariant tests, README.

Stage 2 (accepted, `5746ac1`): signed approvals and optional permit funding.

- `approveMilestoneBySignature`: any relayer submits the client's EIP-712 approval
  (`ApproveMilestone(uint256 milestoneIndex,uint256 nonce,uint256 deadline)`, domain `TrustWork` / `1`).
  EOA and ERC-1271 clients via `SignatureChecker`. Order-wide `approvalNonce` increments on every settlement.
- `fundWithPermit`: client-only, best-effort ERC-2612 permit for fixed terms (client, this order,
  `totalAmount`), then the same deposit logic as `fund()`.
- Stage 1 behavior, accounting, access control and deadline boundaries are unchanged.

Stage 3A (accepted, `f0a1c1b`): arbitration design in `docs/stage-3-arbitration-design.md` and
`docs/stage-3-test-plan.md`. Implementation follows its slices S1–S4, each authorized and reviewed separately.

Stage 3B (accepted, `86e4588`): slice S1 — delivery deadlines, delivery-expiry reclaim credits and claims.

- `deliveryPeriod` (`0 < p <= 180 days`) per order; each milestone's `deliveryDeadline` is set when it becomes
  current; submission requires `block.timestamp < deliveryDeadline`.
- `reclaimAfterDeliveryExpiry`: client-only, current milestone `Pending`, `block.timestamp >= deliveryDeadline`;
  sets `Terminated`, increments `approvalNonce` once, credits all obligations to the client, moves no tokens.
- `claimPayout(account)`: anyone, pays only `account`, only when `Terminated`.
- `directPaid` and `claimsPaid` with `fundedTotal == directPaid + claimsPaid + outstandingObligations`.
- The fee recipient may not be the order itself (`FeeRecipientIsOrder`).

Stage 3C (accepted, `d10d661`): slice S2 — `ArbitratorRegistry`, `IArbitratorRegistry`, `PanelSelection`, and the
test-only `RegistryCourtHarness`.

- Immutable `court = msg.sender`; `penaltyRecipient` may not be the court or the registry; `seatLock` fits `uint128`.
- Per-account `stake + warming <= MAX_PRINCIPAL = type(uint128).max`; larger deposits revert with
  `PrincipalLimitExceeded(amount, capacity)`, computed against remaining capacity in `uint256`.
- Stake buckets `stake`, `warming`, `reserved`, `locked`; listing minimum `seatLock`; at most 32 listed accounts;
  automatic delisting below `seatLock`.
- Court-only snapshots reserve `seatLock` per candidate before any seed; failed snapshots write nothing; stored
  snapshots never change; `locked + reserved <= stake`.

Stage 3D (accepted, `f243e4b`): slice S3 — `ArbitrationCourt`, `IArbitrationCourt`, the minimal read interfaces
`IOrderFactory` and `IOrderParties`, and the test-only `MockArbitrationFactory` and `MockDisputableOrder`.

- Immutable `factory = msg.sender`; the court deploys its own immutable `ArbitratorRegistry`; `penaltyRecipient` is
  restricted only by the registry (not the court or the registry).
- Snapshot at opening, blockhash-seeded draw with expiry re-arm, commit-reveal with
  `VOTE_TAG = keccak256("TrustWork.ArbitrationVote.v1")`, `NoPanel`/`Majority`/`Split` rulings, seat penalties,
  credits claimed through `claimReward`.
- The registry's private storage keeps `principal = stake + warming`; its API and rules are unchanged.

Stage 3E (accepted, `8c55497`): slice S4 — production order and factory integration.

- `TrustWorkFactory(stakeToken, disputeFee, seatLock, penaltyRecipient)` deploys its immutable court; `isWorkOrder`
  is true only for orders it created; `createWorkOrder` keeps its parameters, passes the court to the order and
  rejects `penaltyRecipient` as client, freelancer or fee recipient (`PenaltyRecipientIsParty`).
- `WorkOrder` takes an immutable nonzero `court`; `OrderStatus.Disputed`, `MilestoneStatus.Disputed`, `disputeId`.
- `openDispute(index)`: client, `Active`, current `Submitted` milestone, `block.timestamp < reviewDeadline`; sets
  `Disputed`, consumes one nonce, then calls `court.openDispute`, which pulls the fee from the client. Any failure
  reverts the whole call. While `Disputed` every state-changing order function except `applyRuling` reverts.
- `applyRuling()`: anyone, reads the court's ruling for the stored `disputeId`, sets `Terminated`, credits per design
  §11.1 without moving tokens; payouts through `claimPayout`.
- `approvalNonce == settledCount + (Disputed || Terminated ? 1 : 0)`; EIP-712 message and domain unchanged.
- `ArbitrationCourt`, `ArbitratorRegistry`, their interfaces and `PanelSelection` are unchanged.

Stage 4A (accepted, `c14d760`, with the clarifications recorded in Stage 4B): reputation and soulbound receipts design
in `docs/stage-4-reputation-design.md` and `docs/stage-4-test-plan.md`; implementation in slices 4B and 4C.

Stage 4B (current): `TrustWorkReputation` and `ITrustWorkReputation` — registration, facts and statistics only.

- Immutable `factory`; no owner, setters, fees, pause, upgrade or rescue; no token transfer and no state-changing
  external call. Escrow, court and registry never call it.
- `register(order)`: anyone, once; `factory.isWorkOrder` before any call to the order; `CourtMismatch`,
  `OrderNotFinal` (including `Disputed` after court resolution), `NoParticipation` (first milestone `Pending`),
  `InconsistentDispute`, `UnsupportedRuling`.
- Six distinct outcomes; `NoPanel` never counts as `FreelancerWins`. Facts from final order and court state only;
  gross amounts with `freelancerAwarded + clientReturned == totalAmount`; `registeredAt` is not the closing time.
- Per-account, per-role `Stats` through `statsOf`; `orderCount` and bounded `ordersOf`; no monetary aggregate.
- `receiptsClaimed` stays `0`; no ERC-721 or receipt functions until 4C.

Out of scope until a later stage explicitly asks for it: Stage 4C receipts (ERC-721/ERC-5192, claim, burn); appeals,
resubmission or continuation after a dispute; cancellation by agreement and other refunds; recovery of unsolicited
tokens, governance, frontend, deployment scripts (Base Sepolia comes later), and any relayer service. Do not add
placeholder functions or hooks for these.

## Toolchain

- Foundry 1.5.1-stable, solc 0.8.28 (pinned in `foundry.toml`), EVM target `cancun`.
- OpenZeppelin Contracts v5.6.1 and forge-std v1.11.0 as git submodules under `lib/`.
- Import OpenZeppelin through the `@openzeppelin/contracts/` remapping.

## Engineering and writing style

- Clear, specific names and straightforward control flow.
- Cohesive functions; architecture proportional to the current stage.
- No speculative abstractions, generic frameworks, unnecessary inheritance, or unused extension points.
- No tutorial comments, AI notes, conversational remarks, decorative section banners, or comments
  that restate the code.
- Keep SPDX identifiers. Use concise NatSpec only where it clarifies a public API, a security
  assumption, or a non-obvious constraint.
- Explain design decisions in documentation (README), not in source comments.
- Tests verify observable behavior and failure cases, not implementation details.
- Never claim a command passed unless it was actually run successfully.

## Security conventions

- Token transfers go through `SafeERC20`.
- State-changing entry points that move tokens are `nonReentrant`.
- Checks-effects-interactions: validate, update state, then transfer.
- Funding verifies the actual balance increase equals the required deposit, on every funding path.
- Permit calls are wrapped in try/catch and never replace the allowance check; caller and order state
  are validated before the token is called.
- Signatures are bound to the domain (chain id, order address), the milestone index, the nonce and an
  expiry; any settlement consumes the current nonce. Failed validation or payout leaves the nonce unchanged.
- Escrow obligations are tracked in storage (`outstandingObligations`), never inferred from the raw
  token balance; unsolicited transfers must not block funding or settlement.
- Each milestone settles at most once; settlement advances the order.
- Termination pays nothing directly; every post-termination payout is a credit claimed through `claimPayout`,
  and claim counters update before the transfer.
- No administrative path may withdraw escrowed funds.
- Custom errors for failures, events for every lifecycle change.
- Only exact-transfer ERC-20 tokens are supported; fee-on-transfer and rebasing tokens are not.
- Mocks live under `test/` and are never deployed.

## Verification

```sh
forge fmt --check
forge build
forge test
forge coverage
```

All four must pass before committing. Do not weaken tests or exclude production code from coverage.
