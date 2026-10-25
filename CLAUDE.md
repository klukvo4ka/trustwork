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

Stage 3D (current): slice S3 — `ArbitrationCourt`, `IArbitrationCourt`, the minimal read interfaces `IOrderFactory`
and `IOrderParties`, and the test-only `MockArbitrationFactory` and `MockDisputableOrder`.

- Immutable `factory = msg.sender`; the court deploys its own immutable `ArbitratorRegistry`; `penaltyRecipient` is
  restricted only by the registry (not the court or the registry). No owner, pause, setters, upgrades or rescue
  functions.
- `openDispute` only from orders the factory recognizes; pulls exactly `disputeFee` from the order's client; snapshots
  candidates excluding client, freelancer and fee recipient; `AwaitingCandidates` below three candidates, otherwise
  `AwaitingSeed` with `selectionBlock = block.number + 10`. `retrySnapshot` only before `panelDeadline`.
- `drawPanel` seeds from `blockhash(selectionBlock)`; an expired hash re-arms against the same snapshot.
- Commit-reveal with `VOTE_TAG = keccak256("TrustWork.ArbitrationVote.v1")`; raw `uint8` votes; no early resolution.
- `NoPanel` refunds the fee to the client as a credit; a panel ruling needs two matching reveals, otherwise `Split`;
  every seat without a valid reveal loses exactly `seatLock`; fee shares `floor(F / r)`, dust and penalties to
  `penaltyRecipient`; all payouts are credits claimed through `claimReward`.
- `feesReceived + penaltiesReceived == claimsPaid + pendingFees + totalClaimable`,
  `pendingFees == disputeFee * unresolved`, `penaltiesReceived == registry.penaltiesSent`.
- The registry's API and rules are unchanged; the corrective pass changed only its private storage to keep
  `principal = stake + warming` (matured stake derived as `principal - warming`) to meet the gas targets.
- `WorkOrder` and `TrustWorkFactory` are unchanged and do not use the court.

Out of scope until a later stage explicitly asks for it: order or factory integration with the court (slice S4) and
their constructor arguments, `applyRuling` and order-side dispute state; cancellation by agreement and other refunds;
recovery of unsolicited tokens, reputation, governance, frontend, deployment scripts (Base Sepolia comes later), and
any relayer service. Do not add placeholder arbitration functions or hooks.

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
