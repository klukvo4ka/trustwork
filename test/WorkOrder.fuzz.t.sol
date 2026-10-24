// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WorkOrder} from "../src/WorkOrder.sol";
import {WorkOrderTestBase} from "./utils/WorkOrderTestBase.sol";

contract WorkOrderFuzzTest is WorkOrderTestBase {
    uint256 internal constant MAX_MILESTONES = 12;
    uint256 internal constant MAX_MILESTONE_AMOUNT = 1e12 * USDC;

    function testFuzz_FundingDepositsSumOfMilestones(uint256[] memory rawAmounts) public {
        vm.assume(rawAmounts.length > 0);
        uint256[] memory amounts = _boundAmounts(rawAmounts);
        uint256 expectedTotal;
        for (uint256 i; i < amounts.length; ++i) {
            expectedTotal += amounts[i];
        }

        WorkOrder order = _createOrder(usdc, DEFAULT_FEE_BPS, amounts);
        assertEq(order.totalAmount(), expectedTotal);
        assertEq(order.milestoneCount(), amounts.length);

        _mintAndApprove(usdc, order, expectedTotal + 1);
        vm.prank(client);
        order.fund();

        assertEq(usdc.balanceOf(address(order)), expectedTotal);
        assertEq(usdc.balanceOf(client), 1);
        assertEq(order.outstandingObligations(), expectedTotal);
    }

    function testFuzz_SettlementSplitsAmountExactly(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, 1, type(uint128).max);
        feeBps = bound(feeBps, 0, 1000);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        WorkOrder order = _createOrder(usdc, feeBps, amounts);
        _fund(order);
        _submit(order, 0);

        _approve(order, 0);

        uint256 expectedFee = amount * feeBps / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
        assertEq(usdc.balanceOf(freelancer), amount - expectedFee);
        assertLe(expectedFee, amount / 10);
        assertEq(usdc.balanceOf(address(order)), 0);
        assertEq(order.outstandingObligations(), 0);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
    }

    function testFuzz_FinalizeEligibleExactlyFromDeadline(uint256 reviewPeriod, uint256 elapsed) public {
        reviewPeriod = bound(reviewPeriod, 1, 30 days);
        elapsed = bound(elapsed, 0, 60 days);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 * USDC;
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(freelancer, usdc, feeRecipient, 0, reviewPeriod, amounts);
        _fund(order);
        _submit(order, 0);
        uint256 deadline = block.timestamp + reviewPeriod;
        assertEq(order.getMilestone(0).reviewDeadline, deadline);

        vm.warp(block.timestamp + elapsed);
        if (elapsed < reviewPeriod) {
            vm.expectRevert(abi.encodeWithSelector(WorkOrder.ReviewPeriodNotElapsed.selector, 0, deadline));
            vm.prank(stranger);
            order.finalizeMilestone(0);
            assertEq(usdc.balanceOf(freelancer), 0);
        } else {
            vm.prank(stranger);
            order.finalizeMilestone(0);
            assertEq(usdc.balanceOf(freelancer), 100 * USDC);
        }
    }

    function testFuzz_ObligationsTrackUnsettledMilestones(
        uint256[] memory rawAmounts,
        uint256 feeBps,
        uint256 donation,
        uint256 timeoutMask
    ) public {
        vm.assume(rawAmounts.length > 0);
        uint256[] memory amounts = _boundAmounts(rawAmounts);
        feeBps = bound(feeBps, 0, 1000);
        donation = bound(donation, 0, MAX_MILESTONE_AMOUNT);

        WorkOrder order = _createOrder(usdc, feeBps, amounts);
        usdc.mint(address(order), donation);
        _fund(order);

        uint256 unsettled = order.totalAmount();
        uint256 paidOut;
        for (uint256 i; i < amounts.length; ++i) {
            assertEq(order.outstandingObligations(), unsettled);
            assertEq(usdc.balanceOf(address(order)), unsettled + donation);

            _submit(order, i);
            if ((timeoutMask >> i) & 1 == 1) {
                vm.warp(order.getMilestone(i).reviewDeadline);
                order.finalizeMilestone(i);
            } else {
                _approve(order, i);
            }

            unsettled -= amounts[i];
            paidOut += amounts[i];
            assertEq(usdc.balanceOf(freelancer) + usdc.balanceOf(feeRecipient), paidOut);
        }

        assertEq(order.outstandingObligations(), 0);
        assertEq(usdc.balanceOf(address(order)), donation);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
    }

    function _boundAmounts(uint256[] memory rawAmounts) private pure returns (uint256[] memory amounts) {
        uint256 length = rawAmounts.length > MAX_MILESTONES ? MAX_MILESTONES : rawAmounts.length;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            amounts[i] = bound(rawAmounts[i], 1, MAX_MILESTONE_AMOUNT);
        }
    }
}
