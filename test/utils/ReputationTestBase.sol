// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vm} from "forge-std/Vm.sol";
import {TrustWorkReputation} from "../../src/TrustWorkReputation.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {IntegrationTestBase} from "./IntegrationTestBase.sol";

/// @dev Drives production orders to each terminal state while recording, independently of the contracts, the times and
/// amounts the reputation facts must report.
abstract contract ReputationTestBase is IntegrationTestBase {
    struct Scenario {
        WorkOrder order;
        uint256[] amounts;
        uint256 settled;
        ITrustWorkReputation.Outcome outcome;
        uint256 disputeId;
        uint64 fundedAt;
        uint64 lastSubmittedAt;
        uint64 closedNotBefore;
    }

    uint256 internal constant STEP = 1 hours;
    uint256 internal constant PANEL_PERIOD = 3 days;
    uint256 internal constant COMMIT_PLUS_REVEAL = 3 days;
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    TrustWorkReputation internal reputation;

    function setUp() public virtual override {
        super.setUp();
        reputation = new TrustWorkReputation(factory);
        _activateArbitrators(3, 10 * SEAT_LOCK);
    }

    function _toReputation(Outcome outcome) internal pure returns (ITrustWorkReputation.Outcome) {
        if (outcome == Outcome.FreelancerMajority) return ITrustWorkReputation.Outcome.FreelancerWins;
        if (outcome == Outcome.ClientMajority) return ITrustWorkReputation.Outcome.ClientWins;
        if (outcome == Outcome.NoPanel) return ITrustWorkReputation.Outcome.NoPanel;
        return ITrustWorkReputation.Outcome.Split;
    }

    function _start(address orderFeeRecipient, uint256[] memory amounts) internal returns (Scenario memory s) {
        s.order = _createOrder(client, orderFeeRecipient, amounts);
        s.amounts = amounts;
        vm.warp(block.timestamp + STEP);
        s.fundedAt = SafeCast.toUint64(block.timestamp);
        _fund(s.order);
    }

    /// @dev Submits and approves milestones `[0, count)`, one step apart, and returns the time the last one settled.
    function _settleFirst(Scenario memory s, uint256 count) internal returns (uint256 settledAt) {
        settledAt = s.fundedAt;
        for (uint256 i; i < count; ++i) {
            vm.warp(block.timestamp + STEP);
            s.lastSubmittedAt = SafeCast.toUint64(block.timestamp);
            _submit(s.order, i);
            vm.warp(block.timestamp + STEP);
            settledAt = block.timestamp;
            _approve(s.order, i);
        }
        s.settled = count;
    }

    function _completed(uint256[] memory amounts) internal returns (Scenario memory s) {
        s = _start(feeRecipient, amounts);
        _settleFirst(s, amounts.length);
        s.outcome = ITrustWorkReputation.Outcome.Completed;
        s.closedNotBefore = s.lastSubmittedAt;
    }

    /// @dev Settles `index` milestones, then lets milestone `index` expire and reclaims.
    function _expired(uint256[] memory amounts, uint256 index) internal returns (Scenario memory s) {
        s = _start(feeRecipient, amounts);
        uint256 lastSettledAt = _settleFirst(s, index);
        uint256 deadline = lastSettledAt + DELIVERY_PERIOD;
        vm.warp(deadline);
        vm.prank(client);
        s.order.reclaimAfterDeliveryExpiry();
        s.outcome = ITrustWorkReputation.Outcome.DeliveryExpired;
        s.closedNotBefore = SafeCast.toUint64(deadline);
    }

    function _ruled(uint256[] memory amounts, uint256 index, Outcome ruling) internal returns (Scenario memory s) {
        return _ruledWith(feeRecipient, amounts, index, ruling);
    }

    /// @dev Settles `index` milestones, disputes milestone `index`, drives the court to `ruling` and applies it.
    function _ruledWith(address orderFeeRecipient, uint256[] memory amounts, uint256 index, Outcome ruling)
        internal
        returns (Scenario memory s)
    {
        s = _start(orderFeeRecipient, amounts);
        _settleFirst(s, index);
        vm.warp(block.timestamp + STEP);
        s.lastSubmittedAt = SafeCast.toUint64(block.timestamp);
        uint256 openedAt = block.timestamp;
        s.disputeId = _openDispute(s.order, index);
        vm.warp(block.timestamp + STEP);
        s.closedNotBefore = SafeCast.toUint64(
            ruling == Outcome.NoPanel ? openedAt + PANEL_PERIOD : block.timestamp + COMMIT_PLUS_REVEAL
        );
        _resolveAs(s.disputeId, ruling);
        _applyRuling(s.order);
        s.outcome = _toReputation(ruling);
    }

    /// @dev Expected facts from the scenario's own inputs (design §4 and §5.1).
    function _expectedFacts(Scenario memory s) internal view returns (ITrustWorkReputation.OrderFacts memory e) {
        e.client = s.order.client();
        e.freelancer = freelancer;
        e.token = address(paymentToken);
        e.outcome = s.outcome;
        e.milestoneCount = s.amounts.length;
        e.settledMilestones = s.settled;
        for (uint256 i; i < s.amounts.length; ++i) {
            e.totalAmount += s.amounts[i];
            if (i < s.settled) e.settledAmount += s.amounts[i];
        }
        uint256 gross;
        if (s.disputeId != 0) {
            e.disputedAmount = s.amounts[s.settled];
            if (s.outcome == ITrustWorkReputation.Outcome.Split) gross = e.disputedAmount / 2;
            else if (s.outcome != ITrustWorkReputation.Outcome.ClientWins) gross = e.disputedAmount;
        }
        e.freelancerAwarded = e.settledAmount + gross;
        e.clientReturned = e.totalAmount - e.freelancerAwarded;
        e.disputeId = s.disputeId;
        e.fundedAt = s.fundedAt;
        e.lastSubmittedAt = s.lastSubmittedAt;
        e.closedNotBefore = s.closedNotBefore;
    }

    function _assertFacts(ITrustWorkReputation.OrderFacts memory actual, ITrustWorkReputation.OrderFacts memory e)
        internal
        pure
    {
        assertEq(actual.client, e.client, "client");
        assertEq(actual.freelancer, e.freelancer, "freelancer");
        assertEq(actual.token, e.token, "token");
        assertEq(uint256(actual.outcome), uint256(e.outcome), "outcome");
        assertEq(actual.milestoneCount, e.milestoneCount, "milestoneCount");
        assertEq(actual.settledMilestones, e.settledMilestones, "settledMilestones");
        assertEq(actual.totalAmount, e.totalAmount, "totalAmount");
        assertEq(actual.settledAmount, e.settledAmount, "settledAmount");
        assertEq(actual.disputedAmount, e.disputedAmount, "disputedAmount");
        assertEq(actual.freelancerAwarded, e.freelancerAwarded, "freelancerAwarded");
        assertEq(actual.clientReturned, e.clientReturned, "clientReturned");
        assertEq(actual.freelancerAwarded + actual.clientReturned, actual.totalAmount, "awarded + returned");
        assertEq(actual.disputeId, e.disputeId, "disputeId");
        assertEq(actual.fundedAt, e.fundedAt, "fundedAt");
        assertEq(actual.lastSubmittedAt, e.lastSubmittedAt, "lastSubmittedAt");
        assertEq(actual.closedNotBefore, e.closedNotBefore, "closedNotBefore");
    }

    function _register(Scenario memory s) internal returns (ITrustWorkReputation.OrderFacts memory facts) {
        vm.prank(stranger);
        assertEq(uint256(reputation.register(address(s.order))), uint256(s.outcome));
        (ITrustWorkReputation.Outcome outcome, uint64 registeredAt, uint8 receiptsClaimed) =
            reputation.records(address(s.order));
        assertEq(uint256(outcome), uint256(s.outcome));
        assertEq(registeredAt, block.timestamp);
        assertEq(receiptsClaimed, 0);
        facts = reputation.factsOf(address(s.order));
        _assertFacts(facts, _expectedFacts(s));
    }

    function _statsOf(address account, ITrustWorkReputation.Role role)
        internal
        view
        returns (ITrustWorkReputation.Stats memory)
    {
        return reputation.statsOf(account, role);
    }

    function _assertStats(
        address account,
        ITrustWorkReputation.Role role,
        uint256[6] memory outcomes,
        uint256 milestonesSettled
    ) internal view {
        ITrustWorkReputation.Stats memory stats = reputation.statsOf(account, role);
        uint256 registered = outcomes[0] + outcomes[1] + outcomes[2] + outcomes[3] + outcomes[4] + outcomes[5];
        assertEq(stats.registered, registered, "registered");
        assertEq(stats.completed, outcomes[0], "completed");
        assertEq(stats.deliveryExpired, outcomes[1], "deliveryExpired");
        assertEq(stats.freelancerWins, outcomes[2], "freelancerWins");
        assertEq(stats.clientWins, outcomes[3], "clientWins");
        assertEq(stats.splits, outcomes[4], "splits");
        assertEq(stats.noPanel, outcomes[5], "noPanel");
        assertEq(stats.milestonesSettled, milestonesSettled, "milestonesSettled");
        assertEq(reputation.orderCount(account, role), registered, "orderCount");
    }

    /// @dev Counts per outcome, indexed `Completed` .. `NoPanel` as 0 .. 5, for one registration of `outcome`.
    function _one(ITrustWorkReputation.Outcome outcome) internal pure returns (uint256[6] memory counts) {
        counts[uint256(outcome) - 1] = 1;
    }

    /// @dev Hash of every balance, credit, nonce, counter and status of the order, the court and the registry.
    function _escrowState(WorkOrder order) internal view returns (bytes32 h) {
        address[6] memory holders =
            [address(order), address(court), address(registry), client, freelancer, order.feeRecipient()];
        for (uint256 i; i < holders.length; ++i) {
            h = keccak256(abi.encode(h, paymentToken.balanceOf(holders[i]), stakeToken.balanceOf(holders[i])));
            h = keccak256(abi.encode(h, order.claimable(holders[i]), court.claimable(holders[i])));
        }
        h = keccak256(
            abi.encode(
                h,
                order.status(),
                order.currentMilestone(),
                order.outstandingObligations(),
                order.approvalNonce(),
                order.disputeId(),
                order.directPaid(),
                order.claimsPaid()
            )
        );
        h = keccak256(
            abi.encode(
                h,
                court.feesReceived(),
                court.penaltiesReceived(),
                court.claimsPaid(),
                court.pendingFees(),
                court.totalClaimable(),
                court.disputeCount(),
                court.claimable(penaltyRecipient)
            )
        );
        h = keccak256(
            abi.encode(
                h,
                registry.totalStaked(),
                registry.depositsReceived(),
                registry.withdrawalsPaid(),
                registry.penaltiesSent(),
                registry.listedCount()
            )
        );
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitratorAddress(i);
            h = keccak256(abi.encode(h, registry.accountOf(arbitrator), court.claimable(arbitrator)));
        }
    }

    function _arbitratorAddress(uint256 i) internal pure returns (address) {
        return vm.addr(uint256(keccak256(abi.encodePacked(string.concat("arbitrator", vm.toString(i))))));
    }

    /// @dev Registers with the logs recorded and requires that no payment- or stake-token transfer happened.
    function _registerWithoutTransfers(address order) internal {
        vm.recordLogs();
        reputation.register(order);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            bool tokenEvent = logs[i].emitter == address(paymentToken) || logs[i].emitter == address(stakeToken);
            assertFalse(tokenEvent && logs[i].topics[0] == TRANSFER_TOPIC, "token transfer during registration");
        }
    }
}
