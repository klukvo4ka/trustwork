// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {TrustWorkReputation} from "../../src/TrustWorkReputation.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";
import {TransferLedger} from "../utils/TransferLedger.sol";
import {TrustWorkIntegrationHandler} from "./TrustWorkIntegrationHandler.sol";

/// @dev Adds registration to the Stage 3E integration handler. Expected outcomes come from the parent's ghosts
/// (settlement counts, dispute IDs, panel votes), never from the reputation contract.
contract TrustWorkReputationHandler is TrustWorkIntegrationHandler {
    TrustWorkReputation public immutable reputation;

    mapping(WorkOrder order => ITrustWorkReputation.Outcome) public ghostOutcome;
    mapping(WorkOrder order => uint64) public ghostRegisteredAt;
    mapping(WorkOrder order => bytes32) public ghostFactsHash;
    mapping(address account => mapping(ITrustWorkReputation.Role role => uint256[8])) internal _ghostStats;
    WorkOrder[] public registeredOrders;

    uint256[7] internal _registrationsByOutcome;
    uint256 public rejectedNotFinal;
    uint256 public rejectedNoParticipation;
    uint256 public rejectedDuplicate;
    uint256 public rejectedUnknown;

    constructor(
        TrustWorkFactory factory_,
        MockPermitUSDC paymentToken_,
        MockPermitUSDC stakeToken_,
        TransferLedger ledger_,
        address client_,
        uint256 clientKey_,
        address freelancer_,
        address feeRecipient_
    )
        TrustWorkIntegrationHandler(
            factory_, paymentToken_, stakeToken_, ledger_, client_, clientKey_, freelancer_, feeRecipient_
        )
    {
        reputation = new TrustWorkReputation(factory_);
    }

    function registerOrder(uint256 orderSeed) external {
        WorkOrder order = _order(orderSeed);
        if (address(order) == address(0)) return;
        _register(order);
    }

    function registerUnknown(uint256 seed) external {
        address[3] memory targets = [donor, address(court), address(registry)];
        address target = targets[seed % 3];
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.UnknownOrder.selector, target));
        reputation.register(target);
        ++rejectedUnknown;
    }

    /// @dev Attempts every order once, so campaigns end with every final order registered.
    function registerAll() external {
        for (uint256 i; i < orders.length; ++i) {
            _register(orders[i]);
        }
    }

    function registeredCount() external view returns (uint256) {
        return registeredOrders.length;
    }

    function registrationsByOutcome(ITrustWorkReputation.Outcome outcome) external view returns (uint256) {
        return _registrationsByOutcome[uint256(outcome)];
    }

    /// @dev `[registered, completed, deliveryExpired, freelancerWins, clientWins, splits, noPanel, milestonesSettled]`.
    function ghostStatsOf(address account, ITrustWorkReputation.Role role) external view returns (uint256[8] memory) {
        return _ghostStats[account][role];
    }

    function _register(WorkOrder order) internal {
        WorkOrder.OrderStatus status = order.status();
        bytes32 before = _escrowState(order);
        if (ghostOutcome[order] != ITrustWorkReputation.Outcome.None) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.AlreadyRegistered.selector, address(order)));
            reputation.register(address(order));
            ++rejectedDuplicate;
        } else if (status != WorkOrder.OrderStatus.Completed && status != WorkOrder.OrderStatus.Terminated) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.OrderNotFinal.selector, address(order), status));
            reputation.register(address(order));
            ++rejectedNotFinal;
        } else if (ghostDisputeId[order] == 0 && ghostSettled[order] == 0) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NoParticipation.selector, address(order)));
            reputation.register(address(order));
            ++rejectedNoParticipation;
        } else {
            ITrustWorkReputation.Outcome expected = _expectedOutcome(order, status);
            assertEq(uint256(reputation.register(address(order))), uint256(expected));
            _recordGhost(order, expected);
        }
        assertEq(_escrowState(order), before, "registration changed escrow, court or registry state");
    }

    function _expectedOutcome(WorkOrder order, WorkOrder.OrderStatus status)
        internal
        view
        returns (ITrustWorkReputation.Outcome)
    {
        if (status == WorkOrder.OrderStatus.Completed) return ITrustWorkReputation.Outcome.Completed;
        uint256 disputeId = ghostDisputeId[order];
        if (disputeId == 0) return ITrustWorkReputation.Outcome.DeliveryExpired;
        if (!_wasPanel(disputeId)) return ITrustWorkReputation.Outcome.NoPanel;
        uint256 forFreelancer;
        uint256 forClient;
        for (uint256 j; j < 3; ++j) {
            if (_disputes[disputeId].revealed[j] == 1) ++forFreelancer;
            if (_disputes[disputeId].revealed[j] == 2) ++forClient;
        }
        if (forFreelancer >= 2) return ITrustWorkReputation.Outcome.FreelancerWins;
        if (forClient >= 2) return ITrustWorkReputation.Outcome.ClientWins;
        return ITrustWorkReputation.Outcome.Split;
    }

    function _recordGhost(WorkOrder order, ITrustWorkReputation.Outcome outcome) internal {
        ghostOutcome[order] = outcome;
        ghostRegisteredAt[order] = uint64(block.timestamp);
        ITrustWorkReputation.OrderFacts memory facts = reputation.factsOf(address(order));
        assertEq(facts.settledMilestones, ghostSettled[order]);
        assertEq(facts.freelancerAwarded + facts.clientReturned, order.totalAmount());
        ghostFactsHash[order] = keccak256(abi.encode(facts));
        registeredOrders.push(order);
        ++_registrationsByOutcome[uint256(outcome)];
        _countGhost(client, ITrustWorkReputation.Role.Client, outcome, ghostSettled[order]);
        _countGhost(freelancer, ITrustWorkReputation.Role.Freelancer, outcome, ghostSettled[order]);
    }

    function _countGhost(
        address account,
        ITrustWorkReputation.Role role,
        ITrustWorkReputation.Outcome outcome,
        uint256 settled
    ) internal {
        uint256[8] storage stats = _ghostStats[account][role];
        ++stats[0];
        ++stats[uint256(outcome)];
        stats[7] += settled;
    }

    function _escrowState(WorkOrder order) internal view returns (bytes32) {
        bytes32 h = keccak256(
            abi.encode(
                order.status(),
                order.currentMilestone(),
                order.outstandingObligations(),
                order.approvalNonce(),
                order.disputeId(),
                order.directPaid(),
                order.claimsPaid(),
                order.claimable(client),
                order.claimable(freelancer),
                order.claimable(order.feeRecipient())
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
                registry.totalStaked(),
                registry.depositsReceived(),
                registry.withdrawalsPaid(),
                registry.penaltiesSent()
            )
        );
        address[3] memory holders = [address(order), address(court), address(registry)];
        for (uint256 i; i < 3; ++i) {
            h = keccak256(abi.encode(h, paymentToken.balanceOf(holders[i]), stakeToken.balanceOf(holders[i])));
        }
        return h;
    }
}
