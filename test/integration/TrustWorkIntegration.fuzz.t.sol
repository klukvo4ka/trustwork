// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WorkOrder} from "../../src/WorkOrder.sol";
import {IntegrationTestBase} from "../utils/IntegrationTestBase.sol";
import {TransferLedger} from "../utils/TransferLedger.sol";

abstract contract TrustWorkIntegrationFuzzTest is IntegrationTestBase {
    function setUp() public override {
        super.setUp();
        _activateArbitrators(3, 2 * SEAT_LOCK);
    }

    /// @dev IF-01: credits sum to `D + R` and match fees computed without `WorkOrder.feeFor`.
    function testFuzz_RulingCreditsSumToDisputedAndRemaining(
        uint256[3] memory raw,
        uint256 bps,
        uint256 position,
        uint256 outcomeSeed
    ) public {
        bps = bound(bps, 0, 1000);
        position = position % 3;
        Outcome outcome = Outcome(outcomeSeed % 5);
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            amounts[i] = bound(raw[i], 1, 1e30);
        }
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(
            freelancer, paymentToken, feeRecipient, bps, REVIEW_PERIOD, DELIVERY_PERIOD, amounts
        );
        ledger.trackOrder(address(order));
        _fund(order);
        for (uint256 i; i < position; ++i) {
            _submitAndApprove(order, i);
        }
        uint256 disputeId = _openDispute(order, position);
        _resolveAs(disputeId, outcome);
        _applyRuling(order);

        uint256 remaining;
        for (uint256 i = position + 1; i < 3; ++i) {
            remaining += amounts[i];
        }
        (uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit) =
            _expectedCredits(amounts[position], remaining, bps, outcome);
        assertEq(order.claimable(client), clientCredit);
        assertEq(order.claimable(freelancer), freelancerCredit);
        assertEq(order.claimable(feeRecipient), feeCredit);
        assertEq(clientCredit + freelancerCredit + feeCredit, amounts[position] + remaining);
        assertEq(order.outstandingObligations(), amounts[position] + remaining);
        _claimAll(order);
        _assertOrderLedger(order);
        _assertProtocolEquations();
    }

    /// @dev IF-02: sampled funding, settlements and terminal path; nonce invariant and every §11.4 equation after each
    /// step.
    function testFuzz_LifecycleKeepsNonceAndConservation(
        uint256 fundingSeed,
        uint256 settledSeed,
        uint256 pathsSeed,
        uint256 terminalSeed
    ) public {
        WorkOrder order = _createDefaultOrder();
        _fundBy(order, Funding(fundingSeed % 3));
        _assertStep(order);
        uint256 settled = settledSeed % 4;
        for (uint256 i; i < settled; ++i) {
            _submit(order, i);
            _settleBy(order, i, Settlement((pathsSeed >> (8 * i)) % 3));
            _assertStep(order);
        }
        if (settled == 3) {
            assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
            assertEq(order.approvalNonce(), 3);
            return;
        }

        uint256 terminal = terminalSeed % 6;
        if (terminal == 0) {
            vm.warp(order.getMilestone(settled).deliveryDeadline);
            ledger.begin();
            vm.prank(client);
            order.reclaimAfterDeliveryExpiry();
            ledger.end(TransferLedger.Transition.OrderClaim, new TransferLedger.Edge[](0));
        } else {
            uint256 disputeId = _openDispute(order, settled);
            _assertStep(order);
            _resolveAs(disputeId, Outcome(terminal - 1));
            _assertStep(order);
            _applyRuling(order);
            _assertStep(order);
            _claimCourtCredits(disputeId);
        }
        _assertStep(order);
        assertEq(order.approvalNonce(), settled + 1);
        _claimAll(order);
        _assertStep(order);
        assertEq(order.outstandingObligations(), 0);
        assertEq(order.claimsPaid() + order.directPaid(), order.totalAmount());
    }

    function _assertStep(WorkOrder order) private view {
        _assertOrderLedger(order);
        _assertProtocolEquations();
    }
}

contract TrustWorkIntegrationFuzzSharedTokenTest is TrustWorkIntegrationFuzzTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkIntegrationFuzzSplitTokenTest is TrustWorkIntegrationFuzzTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
