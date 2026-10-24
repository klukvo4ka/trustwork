# TrustWork

Milestone-based escrow for freelance work, written in Solidity with Foundry and OpenZeppelin Contracts v5.

> **Status:** Stage 1 of a portfolio project. Unaudited and intended for local development and testnets only.
> Do not use it with real funds.

## Architecture

| Contract           | Role                                                                                   |
| ------------------ | -------------------------------------------------------------------------------------- |
| `TrustWorkFactory` | Deploys an independent `WorkOrder` per engagement. The caller becomes the client.     |
| `WorkOrder`        | Holds one engagement's budget and releases it milestone by milestone.                  |

Each order is its own contract, so funds and state of different engagements never mix. There is no owner, admin,
upgrade path, or pause switch, and no function that can move escrowed tokens anywhere other than the fee recipient
and the freelancer.

Order terms (client, freelancer, token, fee recipient, fee, review period, total) are immutables. Milestone amounts
live in a storage array because Solidity has no immutable arrays; nothing writes to an amount after construction.

The factory forwards all terms to the `WorkOrder` constructor, which performs the validation. A `WorkOrder` deployed
directly therefore enforces the same rules, and the factory's `WorkOrderCreated` event is the source of truth for
orders created through TrustWork.

### Validation at creation

| Rule                                                      | Error                    |
| --------------------------------------------------------- | ------------------------ |
| Client, freelancer, token and fee recipient are nonzero   | `ZeroAddress`            |
| Client and freelancer differ                              | `ClientIsFreelancer`     |
| Token address has deployed code                           | `TokenHasNoCode`         |
| At least one milestone                                    | `NoMilestones`           |
| Every milestone amount is positive                        | `ZeroMilestoneAmount`    |
| `feeBps <= 1000` (10%)                                    | `FeeTooHigh`             |
| `0 < reviewPeriod <= 30 days`                             | `InvalidReviewPeriod`    |

A milestone list whose sum overflows `uint256` reverts with a checked-arithmetic panic.

## Lifecycle

```
Unfunded --fund()--> Active --(last milestone settled)--> Completed

Milestone: Pending --submitMilestone()--> Submitted --approveMilestone() | finalizeMilestone()--> Settled
```

1. **Fund** — only the client, once, for exactly `totalAmount`. Requires a prior ERC-20 approval.
2. **Submit** — only the freelancer, for the current milestone, after funding. Records `submittedAt` and
   `reviewDeadline = block.timestamp + reviewPeriod`.
3. **Approve** — only the client, for the current submitted milestone, at any time after submission
   (including after the deadline).
4. **Finalize** — anyone, for the current submitted milestone, once `block.timestamp >= reviewDeadline`.
5. Settlement marks the milestone `Settled`, advances `currentMilestone`, and pays out. Settling the last
   milestone sets the order to `Completed`.

Every function that targets a milestone takes its index and requires it to equal `currentMilestone`. Milestones are
strictly sequential, and a stale or duplicated transaction cannot act on a different milestone than intended.

### Timeout boundary

A submitted milestone becomes eligible for permissionless finalization at the deadline itself:

```
eligible  <=>  block.timestamp >= reviewDeadline
```

At `reviewDeadline - 1` finalization reverts with `ReviewPeriodNotElapsed`; at `reviewDeadline` it succeeds.

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

- `0` before funding;
- `totalAmount` after funding;
- reduced by each settled milestone's amount;
- `0` on completion.

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
  then reverts atomically and the milestone stays `Submitted` until the transfer can succeed.

## Security notes

- `SafeERC20` for every transfer; `ReentrancyGuard` on `fund`, `submitMilestone`, `approveMilestone` and
  `finalizeMilestone`.
- Checks-effects-interactions: status, obligations and milestone index are updated before tokens move. Funding
  additionally checks the received amount after the transfer.
- Custom errors for all failures; events `Funded`, `MilestoneSubmitted`, `MilestoneSettled` and `OrderCompleted`
  for every lifecycle change.
- Timestamps are stored as `uint64` via `SafeCast`.

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

Tests are split into unit tests (`test/TrustWorkFactory.t.sol`, `test/WorkOrder.t.sol`), fuzz tests
(`test/WorkOrder.fuzz.t.sol`) and a stateful invariant suite (`test/invariant/`). Token mocks under `test/mocks/`
are test-only: `MockUSDC` (6 decimals, open minting), a fee-on-transfer token, a blocklist token, and a token that
re-enters the order during transfers.

## Current limitations

Not implemented in this stage:

- cancellation, refunds, and any way for the client to recover funds;
- disputes and arbitration — a submitted milestone is either approved or auto-released after the review period;
- recovery of unsolicited tokens sent directly to an order;
- signed approvals, `permit`, reputation, governance, frontend, and deployment scripts.

The milestone count has no explicit cap; creation gas grows linearly with it and is paid by the client.
