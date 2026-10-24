// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WorkOrder} from "./WorkOrder.sol";

/// @title TrustWorkFactory
/// @notice Deploys independent WorkOrder escrows. The caller becomes the order's client.
/// @dev Input validation is enforced by the WorkOrder constructor, so its custom errors bubble up from here.
contract TrustWorkFactory {
    event WorkOrderCreated(
        address indexed order,
        address indexed client,
        address indexed freelancer,
        address token,
        uint256 totalAmount,
        uint256 deliveryPeriod
    );

    function createWorkOrder(
        address freelancer,
        IERC20 token,
        address feeRecipient,
        uint256 feeBps,
        uint256 reviewPeriod,
        uint256 deliveryPeriod,
        uint256[] calldata milestoneAmounts
    ) external returns (WorkOrder order) {
        order = new WorkOrder(
            msg.sender, freelancer, token, feeRecipient, feeBps, reviewPeriod, deliveryPeriod, milestoneAmounts
        );
        emit WorkOrderCreated(
            address(order), msg.sender, freelancer, address(token), order.totalAmount(), deliveryPeriod
        );
    }
}
