// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {WorkOrderTestBase} from "../utils/WorkOrderTestBase.sol";
import {WorkOrderHandler} from "./WorkOrderHandler.sol";

contract WorkOrderInvariantTest is StdInvariant, WorkOrderTestBase {
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
        order = _createOrder(usdc, 1000, amounts);
        handler = new WorkOrderHandler(order, usdc);
        targetContract(address(handler));
    }

    function invariant_ObligationsEqualUnsettledFundedAmounts() public view {
        uint256 unsettled;
        if (order.status() != WorkOrder.OrderStatus.Unfunded) {
            for (uint256 i; i < order.milestoneCount(); ++i) {
                if (order.getMilestone(i).status != WorkOrder.MilestoneStatus.Settled) {
                    unsettled += order.getMilestone(i).amount;
                }
            }
        }
        assertEq(order.outstandingObligations(), unsettled);
        assertEq(order.outstandingObligations(), _fundedAmount() - handler.settledTotal());
    }

    function invariant_BalanceCoversObligations() public view {
        assertGe(usdc.balanceOf(address(order)), order.outstandingObligations());
        assertEq(usdc.balanceOf(address(order)), order.outstandingObligations() + handler.donatedTotal());
    }

    function invariant_PayoutsEqualSettledAmounts() public view {
        assertEq(usdc.balanceOf(freelancer) + usdc.balanceOf(feeRecipient), handler.settledTotal());
        assertLe(usdc.balanceOf(feeRecipient) * 10, handler.settledTotal());
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
        if (completed) assertEq(order.outstandingObligations(), 0);
    }

    function _fundedAmount() private view returns (uint256) {
        return order.status() == WorkOrder.OrderStatus.Unfunded ? 0 : order.totalAmount();
    }
}
