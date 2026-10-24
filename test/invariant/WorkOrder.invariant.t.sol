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
        assertGe(token.balanceOf(address(order)), order.outstandingObligations());
        assertEq(token.balanceOf(address(order)), order.outstandingObligations() + handler.donatedTotal());
    }

    function invariant_PayoutsEqualSettledAmounts() public view {
        assertEq(token.balanceOf(freelancer) + token.balanceOf(feeRecipient), handler.settledTotal());
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
        if (completed) assertEq(order.outstandingObligations(), 0);
    }

    function invariant_ApprovalNonceCountsSettlements() public view {
        assertEq(order.approvalNonce(), handler.settlementCount());
        assertEq(order.approvalNonce(), order.currentMilestone());
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
                    vm.toString(handler.donatedBeforeFunding() > 0 ? 1 : 0)
                )
            )
        );
    }

    function _fundedAmount() private view returns (uint256) {
        return order.status() == WorkOrder.OrderStatus.Unfunded ? 0 : order.totalAmount();
    }
}
