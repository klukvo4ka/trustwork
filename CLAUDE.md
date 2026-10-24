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

Stage 3A (current): arbitration design only.

- Deliverables: `docs/stage-3-arbitration-design.md` and `docs/stage-3-test-plan.md`.
- No changes to contracts, tests, dependencies or compiler settings. Implementation follows the slices
  in the design document (S1–S4), each authorized and reviewed separately.

Out of scope until a later stage explicitly asks for it: implementing arbitration, disputes, delivery
deadlines, cancellation or refunds; recovery of unsolicited tokens, reputation, governance, frontend,
deployment scripts (Base Sepolia comes later), and any relayer service.

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
