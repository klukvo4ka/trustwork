// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IArbitrationCourt} from "./interfaces/IArbitrationCourt.sol";
import {IERC5192} from "./interfaces/IERC5192.sol";
import {ITrustWorkReputation} from "./interfaces/ITrustWorkReputation.sol";
import {TrustWorkFactory} from "./TrustWorkFactory.sol";
import {WorkOrder} from "./WorkOrder.sol";

/// @title TrustWorkReputation
/// @notice Permissionless registry of final orders created by one TrustWork factory, with factual per-account,
/// per-role counters, and optional ERC-5192 receipts that the order's client and freelancer may each claim once.
/// Registered history is only the orders someone chose to register.
/// @dev Reads only final order and court state, through view calls; never moves ERC-20 tokens and is never called by
/// the escrow, court or registry. Its own receipts can only be minted and burned, never transferred.
contract TrustWorkReputation is ITrustWorkReputation, IERC5192, ERC721 {
    TrustWorkFactory public immutable factory;

    mapping(address order => OrderRecord) public records;
    mapping(address account => mapping(Role role => Stats)) private _stats;
    mapping(address account => mapping(Role role => address[])) private _orders;

    constructor(TrustWorkFactory factory_) ERC721("TrustWork Receipt", "TWR") {
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

    /// @notice Mints the caller's receipt for `role` of a registered order. Each `(order, role)` gets at most one
    /// receipt over its lifetime, also after a burn.
    /// @dev Minted without a receiver callback, so any account that can make this call can hold the receipt.
    function claimReceipt(address order, Role role) external returns (uint256 tokenId) {
        OrderRecord storage record = records[order];
        if (record.outcome == Outcome.None) revert NotRegistered(order);
        address holder = role == Role.Client ? WorkOrder(order).client() : WorkOrder(order).freelancer();
        if (msg.sender != holder) revert NotRoleHolder(order, role, msg.sender);
        uint8 bit = uint8(1) << uint8(role);
        if (record.receiptsClaimed & bit != 0) revert ReceiptAlreadyClaimed(order, role);

        record.receiptsClaimed |= bit;
        tokenId = receiptId(order, role);
        _mint(msg.sender, tokenId);

        emit Locked(tokenId);
        emit ReceiptClaimed(order, role, msg.sender, tokenId);
    }

    /// @notice Destroys the caller's receipt. The order's record, facts and statistics are unaffected, and the receipt
    /// can never be claimed again.
    function burn(uint256 tokenId) external {
        _update(address(0), tokenId, msg.sender);
    }

    function receiptId(address order, Role role) public pure returns (uint256) {
        return (uint256(uint160(order)) << 1) | uint256(role);
    }

    /// @notice Order and role of an existing receipt; reverts for IDs that were never minted or were burned.
    function receiptOf(uint256 tokenId) external view returns (address order, Role role) {
        _requireOwned(tokenId);
        return (address(SafeCast.toUint160(tokenId >> 1)), Role(tokenId & 1));
    }

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function approve(address, uint256) public pure override {
        revert ApprovalsDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert ApprovalsDisabled();
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Allows only minting and burning. An ordinary transfer of an existing token first passes the inherited
    /// authorization check, then reverts `ReceiptLocked`; transfers of nonexistent tokens fail authorization.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            if (auth != address(0)) _checkAuthorized(from, auth, tokenId);
            revert ReceiptLocked(tokenId);
        }
        return super._update(to, tokenId, auth);
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
