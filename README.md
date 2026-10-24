# TrustWork

Milestone-based escrow for freelance work, written in Solidity with Foundry and OpenZeppelin Contracts v5.

> **Status:** Stage 2 of a portfolio project. Unaudited and intended for local development and testnets only.
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

1. **Fund** — only the client, once, for exactly `totalAmount`, through `fund()` (prior ERC-20 approval) or
   `fundWithPermit()` (ERC-2612 permit, see [Permit funding](#permit-funding)).
2. **Submit** — only the freelancer, for the current milestone, after funding. Records `submittedAt` and
   `reviewDeadline = block.timestamp + reviewPeriod`.
3. **Approve** — for the current submitted milestone, at any time after submission (including after the
   review deadline): directly by the client with `approveMilestone()`, or by anyone relaying the client's
   signature with `approveMilestoneBySignature()` (see [Signed approvals](#signed-approvals)).
4. **Finalize** — anyone, for the current submitted milestone, once `block.timestamp >= reviewDeadline`.
5. Settlement marks the milestone `Settled`, increments `approvalNonce`, advances `currentMilestone`, and pays
   out. Settling the last
   milestone sets the order to `Completed`.

Every function that targets a milestone takes its index and requires it to equal `currentMilestone`. Milestones are
strictly sequential, and a stale or duplicated transaction cannot act on a different milestone than intended.

### Timeout boundary

A submitted milestone becomes eligible for permissionless finalization at the deadline itself:

```
eligible  <=>  block.timestamp >= reviewDeadline
```

At `reviewDeadline - 1` finalization reverts with `ReviewPeriodNotElapsed`; at `reviewDeadline` it succeeds.

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

Example `eth_signTypedData_v4` payload for milestone `0` on Base Sepolia. The `verifyingContract` is a
placeholder; use the address of the order being approved.

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
settlement, whether it came from `approveMilestone`, `approveMilestoneBySignature` or `finalizeMilestone`. After
`k` settlements it equals `k` and equals `currentMilestone`, so the signature for milestone `i` must carry
nonce `i`.

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

- `SafeERC20` for every transfer; `ReentrancyGuard` on `fund`, `fundWithPermit`, `submitMilestone`,
  `approveMilestone`, `approveMilestoneBySignature` and `finalizeMilestone`.
- Checks-effects-interactions: status, obligations and milestone index are updated before tokens move. Funding
  additionally checks the received amount after the transfer.
- Custom errors for all failures; events `Funded`, `MilestoneSubmitted`, `MilestoneSettled` and `OrderCompleted`
  for every lifecycle change. A signed approval additionally emits
  `MilestoneApprovedBySignature(index, client, relayer, nonce)` before `MilestoneSettled`, whose `settledBy` is the
  relayer.
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

Tests are split into unit tests (`test/TrustWorkFactory.t.sol`, `test/WorkOrder.t.sol`,
`test/WorkOrder.signature.t.sol`, `test/WorkOrder.permit.t.sol`), fuzz tests (`test/WorkOrder.fuzz.t.sol`) and a
stateful invariant suite (`test/invariant/`) that mixes all funding and settlement paths. Mocks under `test/mocks/`
are test-only: `MockUSDC` (6 decimals, open minting), `MockPermitUSDC` (adds ERC-2612), a fee-on-transfer token, a
blocklist token, a token that re-enters the order during transfers, and an ERC-1271 wallet that can be switched to
return a wrong magic value or revert.

Run `forge test --match-path 'test/invariant/*' -vv` to print a per-campaign summary of the transitions reached in
the final run (funding path, settlement paths, rejected stale signatures).

## Current limitations

Not implemented in this stage:

- cancellation, refunds, and any way for the client to recover funds;
- disputes and arbitration — a submitted milestone is either approved or auto-released after the review period;
- recovery of unsolicited tokens sent directly to an order;
- reputation, governance, frontend, deployment scripts, and a relayer service.

Stage 2 caveats:

- The client cannot revoke a signed approval except by letting it expire or by settling the milestone some other
  way (direct approval, or waiting for the timeout); there is no nonce-cancel function.
- `fundWithPermit` treats a token whose fallback accepts the `permit` call without reverting the same as a
  successful permit; funding still requires the resulting allowance.

The milestone count has no explicit cap; creation gas grows linearly with it and is paid by the client.
