// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract WorkOrderHandler is Test {
    WorkOrder public immutable order;
    MockUSDC public immutable usdc;

    uint256 public settledTotal;
    uint256 public donatedTotal;
    uint256 public settlementCount;

    constructor(WorkOrder order_, MockUSDC usdc_) {
        order = order_;
        usdc = usdc_;
    }

    function fund() external {
        if (order.status() != WorkOrder.OrderStatus.Unfunded) return;
        uint256 total = order.totalAmount();
        address client = order.client();
        usdc.mint(client, total);
        vm.startPrank(client);
        usdc.approve(address(order), total);
        order.fund();
        vm.stopPrank();
    }

    function submit() external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Pending)) return;
        uint256 index = order.currentMilestone();
        address freelancer = order.freelancer();
        vm.prank(freelancer);
        order.submitMilestone(index);
    }

    function approve() external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        settledTotal += order.getMilestone(index).amount;
        ++settlementCount;
        address client = order.client();
        vm.prank(client);
        order.approveMilestone(index);
    }

    function finalize(address caller) external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        WorkOrder.Milestone memory milestone = order.getMilestone(index);
        if (block.timestamp < milestone.reviewDeadline) return;
        settledTotal += milestone.amount;
        ++settlementCount;
        vm.prank(caller);
        order.finalizeMilestone(index);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 10 days));
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1e9 * 1e6);
        donatedTotal += amount;
        usdc.mint(address(order), amount);
    }

    function _currentIs(WorkOrder.MilestoneStatus expected) private view returns (bool) {
        return order.status() == WorkOrder.OrderStatus.Active
            && order.getMilestone(order.currentMilestone()).status == expected;
    }
}
