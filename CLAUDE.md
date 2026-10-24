# TrustWork

Milestone-based freelance escrow. Portfolio project, unaudited, testnet-oriented.

## Scope

The project is built in stages. Each stage is implemented only after the previous one is reviewed.

Stage 1 (current): escrow core.

- `TrustWorkFactory` deploys independent `WorkOrder` contracts; the caller becomes the client.
- `WorkOrder` holds the full milestone budget, settles milestones strictly in order on client
  approval or after the review deadline, and pays the fee recipient and freelancer.
- Test-only token mocks, Foundry unit, fuzz and invariant tests, README.

Out of scope until a later stage explicitly asks for it: signatures, permit, arbitration,
disputes, cancellation, refunds, recovery of unsolicited tokens, reputation, governance,
frontend, and deployment scripts (Base Sepolia comes later).

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
- Funding verifies the actual balance increase equals the required deposit.
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
