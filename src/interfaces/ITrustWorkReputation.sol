// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IArbitrationCourt} from "./IArbitrationCourt.sol";
import {TrustWorkFactory} from "../TrustWorkFactory.sol";
import {WorkOrder} from "../WorkOrder.sol";

/// @title ITrustWorkReputation
/// @notice Factual records and per-account statistics of final orders created by one TrustWork factory, and optional
/// nontransferable receipts for their client and freelancer.
interface ITrustWorkReputation {
    enum Outcome {
        None,
        Completed,
        DeliveryExpired,
        FreelancerWins,
        ClientWins,
        Split,
        NoPanel
    }

    enum Role {
        Client,
        Freelancer
    }

    struct OrderRecord {
        Outcome outcome;
        uint64 registeredAt;
        uint8 receiptsClaimed;
    }

    /// @dev Amounts are gross order amounts in the order's own token; `freelancerAwarded` includes the protocol-fee
    /// portion and is not the freelancer's net receipt. `closedNotBefore` is a lower bound of the closing time.
    struct OrderFacts {
        address client;
        address freelancer;
        address token;
        Outcome outcome;
        uint256 milestoneCount;
        uint256 settledMilestones;
        uint256 totalAmount;
        uint256 settledAmount;
        uint256 disputedAmount;
        uint256 freelancerAwarded;
        uint256 clientReturned;
        uint256 disputeId;
        uint64 fundedAt;
        uint64 lastSubmittedAt;
        uint64 closedNotBefore;
    }

    struct Stats {
        uint256 registered;
        uint256 completed;
        uint256 deliveryExpired;
        uint256 freelancerWins;
        uint256 clientWins;
        uint256 splits;
        uint256 noPanel;
        uint256 milestonesSettled;
    }

    event OrderRegistered(address indexed order, Outcome outcome, address indexed client, address indexed freelancer);
    event ReceiptClaimed(address indexed order, Role role, address indexed holder, uint256 tokenId);

    error ZeroFactory();
    error FactoryHasNoCode(address factory);
    error UnknownOrder(address order);
    error AlreadyRegistered(address order);
    error CourtMismatch(address order, address orderCourt);
    error OrderNotFinal(address order, WorkOrder.OrderStatus status);
    error NoParticipation(address order);
    error InconsistentDispute(address order, uint256 disputeId);
    error UnsupportedRuling(address order, IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason);
    error NotRegistered(address order);
    error NotRoleHolder(address order, Role role, address caller);
    error ReceiptAlreadyClaimed(address order, Role role);
    error ReceiptLocked(uint256 tokenId);
    error ApprovalsDisabled();

    function factory() external view returns (TrustWorkFactory);
    function register(address order) external returns (Outcome outcome);
    function records(address order) external view returns (Outcome outcome, uint64 registeredAt, uint8 receiptsClaimed);
    function factsOf(address order) external view returns (OrderFacts memory);
    function statsOf(address account, Role role) external view returns (Stats memory);
    function orderCount(address account, Role role) external view returns (uint256);
    function ordersOf(address account, Role role, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page);
    function claimReceipt(address order, Role role) external returns (uint256 tokenId);
    function burn(uint256 tokenId) external;
    function receiptId(address order, Role role) external pure returns (uint256);
    function receiptOf(uint256 tokenId) external view returns (address order, Role role);
}
