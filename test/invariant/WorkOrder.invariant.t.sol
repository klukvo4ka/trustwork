// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {WorkOrderTestBase} from "../utils/WorkOrderTestBase.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";
import {WorkOrderHandler} from "./WorkOrderHandler.sol";

contract WorkOrderInvariantTest is StdInvariant, WorkOrderTestBase {
    MockPermitUSDC internal token;
    WorkOrder internal order;
    WorkOrderHandler internal handler;

    function setUp() public override {
        super.setUp();
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1 * USDC;
        amounts[1] = 333_333_333;
        amounts[2] = 7;
        amounts[3] = 50_000 * USDC;
        amounts[4] = 1_234_567;
        token = new MockPermitUSDC();
        order = _createOrder(token, 1000, amounts);
        handler = new WorkOrderHandler(order, token, clientKey);
        targetContract(address(handler));
    }

    function invariant_FundedTotalIsConserved() public view {
        assertEq(_fundedAmount(), order.directPaid() + order.claimsPaid() + order.outstandingObligations());
        assertEq(order.directPaid(), handler.settledTotal());
        assertEq(order.claimsPaid(), handler.claimedTotal());
    }

    function invariant_ObligationsMatchStatus() public view {
        WorkOrder.OrderStatus status = order.status();
        uint256 outstanding = order.outstandingObligations();
        if (status == WorkOrder.OrderStatus.Unfunded || status == WorkOrder.OrderStatus.Completed) {
            assertEq(outstanding, 0);
        } else if (status == WorkOrder.OrderStatus.Active) {
            uint256 unsettled;
            for (uint256 i; i < order.milestoneCount(); ++i) {
                if (order.getMilestone(i).status != WorkOrder.MilestoneStatus.Settled) {
                    unsettled += order.getMilestone(i).amount;
                }
            }
            assertEq(outstanding, unsettled);
        } else {
            assertEq(outstanding, order.claimable(client) + order.claimable(freelancer) + order.claimable(feeRecipient));
            assertEq(outstanding, handler.creditedTotal() - handler.claimedTotal());
            assertEq(order.claimable(freelancer), 0);
            assertEq(order.claimable(feeRecipient), 0);
        }
    }

    function invariant_BalanceCoversObligations() public view {
        assertGe(token.balanceOf(address(order)), order.outstandingObligations());
        assertEq(token.balanceOf(address(order)), order.outstandingObligations() + handler.donatedTotal());
    }

    function invariant_PayoutsEqualSettledAmounts() public view {
        assertEq(token.balanceOf(freelancer) + token.balanceOf(feeRecipient), handler.settledTotal());
        assertEq(token.balanceOf(client), handler.claimedTotal());
        assertLe(token.balanceOf(feeRecipient) * 10, handler.settledTotal());
    }

    function invariant_MilestonesSettleInOrder() public view {
        uint256 current = order.currentMilestone();
        assertEq(current, handler.settlementCount());
        for (uint256 i; i < order.milestoneCount(); ++i) {
            bool settled = order.getMilestone(i).status == WorkOrder.MilestoneStatus.Settled;
            assertEq(settled, i < current);
        }
        bool completed = order.status() == WorkOrder.OrderStatus.Completed;
        assertEq(completed, current == order.milestoneCount());
        if (order.status() == WorkOrder.OrderStatus.Terminated) {
            assertEq(current, handler.reclaimedAtIndex());
            assertEq(uint256(order.getMilestone(current).status), uint256(WorkOrder.MilestoneStatus.Pending));
        }
    }

    function invariant_ApprovalNonceCountsSettlementsAndTermination() public view {
        uint256 terminated = order.status() == WorkOrder.OrderStatus.Terminated ? 1 : 0;
        assertEq(order.approvalNonce(), handler.settlementCount() + terminated);
        assertEq(order.currentMilestone(), handler.settlementCount());
        assertLe(handler.reclaims(), 1);
        assertEq(handler.reclaims(), terminated);
    }

    function invariant_DeliveryDeadlinesFollowSchedule() public view {
        if (order.status() == WorkOrder.OrderStatus.Unfunded) {
            assertEq(order.getMilestone(0).deliveryDeadline, 0);
            return;
        }
        uint256 current = order.currentMilestone();
        for (uint256 i; i < order.milestoneCount(); ++i) {
            uint256 deliveryDeadline = order.getMilestone(i).deliveryDeadline;
            if (i <= current) assertGt(deliveryDeadline, 0);
            else assertEq(deliveryDeadline, 0);
            if (order.getMilestone(i).status != WorkOrder.MilestoneStatus.Pending) {
                assertLt(order.getMilestone(i).submittedAt, deliveryDeadline);
            }
        }
    }

    function invariant_FundedAtMostOnce() public view {
        uint256 fundings = handler.fundingCount();
        assertLe(fundings, 1);
        assertEq(fundings == 1, order.status() != WorkOrder.OrderStatus.Unfunded);
        assertEq(token.allowance(client, address(order)), 0);
        assertEq(token.nonces(client), handler.fundedWithPermit());
    }

    function afterInvariant() external view {
        console.log(
            string.concat(
                "transitions status=",
                vm.toString(uint256(order.status())),
                " funded=",
                vm.toString(handler.fundedDirectly()),
                "/",
                vm.toString(handler.fundedWithPermit()),
                "/",
                vm.toString(handler.fundedByPermitFallback()),
                " settled=",
                vm.toString(handler.settledByClient()),
                "/",
                vm.toString(handler.settledBySignature()),
                "/",
                vm.toString(handler.settledByTimeout()),
                string.concat(
                    " staleRejected=",
                    vm.toString(handler.rejectedStaleSignatures()),
                    " donatedBeforeFunding=",
                    vm.toString(handler.donatedBeforeFunding() > 0 ? 1 : 0),
                    " expiredSubmitRejected=",
                    vm.toString(handler.rejectedExpiredSubmissions()),
                    string.concat(
                        " reclaims=",
                        vm.toString(handler.reclaims()),
                        " reclaimIndex=",
                        vm.toString(handler.reclaimedAtIndex()),
                        " claims=",
                        vm.toString(handler.claims()),
                        " emptyClaimRejected=",
                        vm.toString(handler.rejectedEmptyClaims())
                    )
                )
            )
        );
    }

    function _fundedAmount() private view returns (uint256) {
        return order.status() == WorkOrder.OrderStatus.Unfunded ? 0 : order.totalAmount();
    }
}
