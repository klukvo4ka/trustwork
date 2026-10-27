// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {ReputationTestBase} from "../utils/ReputationTestBase.sol";

abstract contract TrustWorkReputationFuzzTest is ReputationTestBase {
    /// @dev RF-01: sampled amounts, fee, terminal path and position; facts match the independent model and each role's
    /// counters change by exactly one outcome.
    function testFuzz_FactsMatchModel(uint256[3] memory raw, uint256 bps, uint256 pathSeed, uint256 positionSeed)
        public
    {
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            amounts[i] = bound(raw[i], 1, 1e30);
        }
        Scenario memory s = _sampled(amounts, bound(bps, 0, 1000), pathSeed % 7, positionSeed % 3);
        ITrustWorkReputation.Stats memory clientBefore = reputation.statsOf(client, ITrustWorkReputation.Role.Client);

        ITrustWorkReputation.OrderFacts memory facts = _register(s);
        assertEq(facts.freelancerAwarded + facts.clientReturned, facts.totalAmount);

        ITrustWorkReputation.Stats memory clientAfter = reputation.statsOf(client, ITrustWorkReputation.Role.Client);
        assertEq(clientAfter.registered, clientBefore.registered + 1);
        assertEq(clientAfter.milestonesSettled, clientBefore.milestonesSettled + s.settled);
        _assertStats(freelancer, ITrustWorkReputation.Role.Freelancer, _one(s.outcome), s.settled);
    }

    /// @dev RF-02: any claim schedule before registration gives the same classification, facts and counters, and
    /// `registeredAt` is the registration's own timestamp.
    function testFuzz_ClaimScheduleDoesNotChangeFacts(uint256 pathSeed, uint256 claimMask, uint256 delay) public {
        Scenario memory s = _sampled(_defaultAmounts(), FEE_BPS, pathSeed % 7, 1);
        uint256 state = vm.snapshotState();
        reputation.register(address(s.order));
        bytes32 expected = _registrationHash(address(s.order));
        vm.revertToState(state);

        address[3] memory accounts = [client, freelancer, feeRecipient];
        for (uint256 i; i < 3; ++i) {
            if ((claimMask >> i) & 1 == 1 && s.order.claimable(accounts[i]) != 0) s.order.claimPayout(accounts[i]);
        }
        if ((claimMask >> 3) & 1 == 1 && s.disputeId != 0) _claimCourtCredits(s.disputeId);
        vm.warp(block.timestamp + bound(delay, 0, 365 days));
        reputation.register(address(s.order));
        (, uint64 registeredAt,) = reputation.records(address(s.order));
        assertEq(registeredAt, block.timestamp);
        assertEq(_registrationHash(address(s.order)), expected);
    }

    /// @dev Path 0 Completed, 1 delivery expiry, 2–6 rulings `Outcome(path - 2)`. Expiry uses position 1 or 2.
    function _sampled(uint256[] memory amounts, uint256 bps, uint256 path, uint256 position)
        private
        returns (Scenario memory s)
    {
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(
            freelancer, paymentToken, feeRecipient, bps, REVIEW_PERIOD, DELIVERY_PERIOD, amounts
        );
        ledger.trackOrder(address(order));
        s.order = order;
        s.amounts = amounts;
        vm.warp(block.timestamp + STEP);
        s.fundedAt = SafeCast.toUint64(block.timestamp);
        _fund(order);
        if (path == 0) {
            _settleFirst(s, 3);
            s.outcome = ITrustWorkReputation.Outcome.Completed;
            s.closedNotBefore = s.lastSubmittedAt;
        } else if (path == 1) {
            uint256 index = position == 0 ? 1 : position;
            uint256 deadline = _settleFirst(s, index) + DELIVERY_PERIOD;
            vm.warp(deadline);
            vm.prank(client);
            order.reclaimAfterDeliveryExpiry();
            s.outcome = ITrustWorkReputation.Outcome.DeliveryExpired;
            s.closedNotBefore = SafeCast.toUint64(deadline);
        } else {
            Outcome ruling = Outcome(path - 2);
            _settleFirst(s, position);
            vm.warp(block.timestamp + STEP);
            s.lastSubmittedAt = SafeCast.toUint64(block.timestamp);
            uint256 openedAt = block.timestamp;
            s.disputeId = _openDispute(order, position);
            vm.warp(block.timestamp + STEP);
            s.closedNotBefore = SafeCast.toUint64(
                ruling == Outcome.NoPanel ? openedAt + PANEL_PERIOD : block.timestamp + COMMIT_PLUS_REVEAL
            );
            _resolveAs(s.disputeId, ruling);
            _applyRuling(order);
            s.outcome = _toReputation(ruling);
        }
    }

    function _registrationHash(address order) private view returns (bytes32) {
        (ITrustWorkReputation.Outcome outcome,, uint8 receiptsClaimed) = reputation.records(order);
        return keccak256(
            abi.encode(
                outcome,
                receiptsClaimed,
                reputation.factsOf(order),
                reputation.statsOf(client, ITrustWorkReputation.Role.Client),
                reputation.statsOf(freelancer, ITrustWorkReputation.Role.Freelancer),
                reputation.ordersOf(client, ITrustWorkReputation.Role.Client, 0, 10),
                reputation.ordersOf(freelancer, ITrustWorkReputation.Role.Freelancer, 0, 10)
            )
        );
    }
}

contract TrustWorkReputationFuzzSharedTokenTest is TrustWorkReputationFuzzTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkReputationFuzzSplitTokenTest is TrustWorkReputationFuzzTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
