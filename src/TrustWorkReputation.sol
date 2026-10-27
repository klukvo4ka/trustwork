// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IArbitrationCourt} from "./interfaces/IArbitrationCourt.sol";
import {ITrustWorkReputation} from "./interfaces/ITrustWorkReputation.sol";
import {TrustWorkFactory} from "./TrustWorkFactory.sol";
import {WorkOrder} from "./WorkOrder.sol";

/// @title TrustWorkReputation
/// @notice Permissionless registry of final orders created by one TrustWork factory, with factual per-account,
/// per-role counters. Registered history is only the orders someone chose to register.
/// @dev Reads only final order and court state, through view calls; never moves tokens and is never called by the
/// escrow, court or registry.
contract TrustWorkReputation is ITrustWorkReputation {
    TrustWorkFactory public immutable factory;

    mapping(address order => OrderRecord) public records;
    mapping(address account => mapping(Role role => Stats)) private _stats;
    mapping(address account => mapping(Role role => address[])) private _orders;

    constructor(TrustWorkFactory factory_) {
        if (address(factory_) == address(0)) revert ZeroFactory();
        if (address(factory_).code.length == 0) revert FactoryHasNoCode(address(factory_));
        factory = factory_;
    }

    /// @notice Records the outcome of a final factory order and updates its client's and freelancer's statistics.
    /// Callable by anyone, once per order.
    /// @dev The order is authenticated by the factory before any call is made to it. Requires `Completed` or
    /// `Terminated` and a first milestone that left `Pending`, which only the freelancer's submission can cause.
    function register(address order) external returns (Outcome outcome) {
        if (!factory.isWorkOrder(order)) revert UnknownOrder(order);
        if (records[order].outcome != Outcome.None) revert AlreadyRegistered(order);
        OrderFacts memory facts = _facts(WorkOrder(order));
        outcome = facts.outcome;

        records[order] =
            OrderRecord({outcome: outcome, registeredAt: SafeCast.toUint64(block.timestamp), receiptsClaimed: 0});
        _count(facts.client, Role.Client, order, facts);
        _count(facts.freelancer, Role.Freelancer, order, facts);

        emit OrderRegistered(order, outcome, facts.client, facts.freelancer);
    }

    /// @notice Facts of a registered order, recomputed from its final order and court state.
    function factsOf(address order) external view returns (OrderFacts memory) {
        if (records[order].outcome == Outcome.None) revert NotRegistered(order);
        return _facts(WorkOrder(order));
    }

    function statsOf(address account, Role role) external view returns (Stats memory) {
        return _stats[account][role];
    }

    function orderCount(address account, Role role) external view returns (uint256) {
        return _orders[account][role].length;
    }

    /// @notice Up to `limit` registered orders of `account` in `role`, from position `offset`, in registration order.
    function ordersOf(address account, Role role, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        address[] storage list = _orders[account][role];
        uint256 length = list.length;
        if (limit == 0 || offset >= length) return new address[](0);
        uint256 available = length - offset;
        page = new address[](limit < available ? limit : available);
        for (uint256 i; i < page.length; ++i) {
            page[i] = list[offset + i];
        }
    }

    function _facts(WorkOrder order) private view returns (OrderFacts memory facts) {
        IArbitrationCourt court = factory.court();
        IArbitrationCourt orderCourt = order.court();
        if (orderCourt != court) revert CourtMismatch(address(order), address(orderCourt));
        WorkOrder.OrderStatus status = order.status();
        if (status != WorkOrder.OrderStatus.Completed && status != WorkOrder.OrderStatus.Terminated) {
            revert OrderNotFinal(address(order), status);
        }
        WorkOrder.Milestone memory first = order.getMilestone(0);
        if (first.status == WorkOrder.MilestoneStatus.Pending) revert NoParticipation(address(order));

        facts.client = order.client();
        facts.freelancer = order.freelancer();
        facts.token = address(order.token());
        facts.milestoneCount = order.milestoneCount();
        facts.totalAmount = order.totalAmount();
        facts.settledAmount = order.directPaid();
        facts.disputeId = order.disputeId();
        facts.settledMilestones = order.currentMilestone();
        facts.fundedAt = SafeCast.toUint64(uint256(first.deliveryDeadline) - order.deliveryPeriod());

        uint256 freelancerGross;
        if (status == WorkOrder.OrderStatus.Completed) {
            facts.outcome = Outcome.Completed;
            facts.lastSubmittedAt = order.getMilestone(facts.milestoneCount - 1).submittedAt;
            facts.closedNotBefore = facts.lastSubmittedAt;
        } else if (facts.disputeId == 0) {
            facts.outcome = Outcome.DeliveryExpired;
            facts.lastSubmittedAt = order.getMilestone(facts.settledMilestones - 1).submittedAt;
            facts.closedNotBefore = order.getMilestone(facts.settledMilestones).deliveryDeadline;
        } else {
            WorkOrder.Milestone memory disputed = order.getMilestone(facts.settledMilestones);
            facts.disputedAmount = disputed.amount;
            facts.lastSubmittedAt = disputed.submittedAt;
            freelancerGross = _classifyRuling(order, court, facts);
        }

        facts.freelancerAwarded = facts.settledAmount + freelancerGross;
        facts.clientReturned = facts.totalAmount - facts.freelancerAwarded;
    }

    /// @dev Sets the ruling outcome and lower-bound closing time and returns the freelancer's gross share of the
    /// disputed milestone.
    function _classifyRuling(WorkOrder order, IArbitrationCourt court, OrderFacts memory facts)
        private
        view
        returns (uint256 freelancerGross)
    {
        IArbitrationCourt.Dispute memory dispute = court.getDispute(facts.disputeId);
        if (dispute.order != address(order) || dispute.milestoneIndex != facts.settledMilestones) {
            revert InconsistentDispute(address(order), facts.disputeId);
        }
        IArbitrationCourt.Ruling ruling = dispute.ruling;
        IArbitrationCourt.RulingReason reason = dispute.reason;
        uint256 disputed = facts.disputedAmount;

        if (ruling == IArbitrationCourt.Ruling.FreelancerWins && reason == IArbitrationCourt.RulingReason.NoPanel) {
            facts.outcome = Outcome.NoPanel;
            facts.closedNotBefore = dispute.panelDeadline;
            return disputed;
        }
        facts.closedNotBefore = dispute.revealDeadline;
        if (ruling == IArbitrationCourt.Ruling.FreelancerWins && reason == IArbitrationCourt.RulingReason.Majority) {
            facts.outcome = Outcome.FreelancerWins;
            return disputed;
        }
        if (ruling == IArbitrationCourt.Ruling.ClientWins && reason == IArbitrationCourt.RulingReason.Majority) {
            facts.outcome = Outcome.ClientWins;
            return 0;
        }
        if (ruling == IArbitrationCourt.Ruling.Split && reason == IArbitrationCourt.RulingReason.NoDecision) {
            facts.outcome = Outcome.Split;
            return disputed / 2;
        }
        revert UnsupportedRuling(address(order), ruling, reason);
    }

    function _count(address account, Role role, address order, OrderFacts memory facts) private {
        Stats storage stats = _stats[account][role];
        ++stats.registered;
        Outcome outcome = facts.outcome;
        if (outcome == Outcome.Completed) ++stats.completed;
        else if (outcome == Outcome.DeliveryExpired) ++stats.deliveryExpired;
        else if (outcome == Outcome.FreelancerWins) ++stats.freelancerWins;
        else if (outcome == Outcome.ClientWins) ++stats.clientWins;
        else if (outcome == Outcome.Split) ++stats.splits;
        else ++stats.noPanel;
        stats.milestonesSettled += facts.settledMilestones;
        _orders[account][role].push(order);
    }
}
