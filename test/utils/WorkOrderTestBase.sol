// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

abstract contract WorkOrderTestBase is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant DEFAULT_FEE_BPS = 250;
    uint256 internal constant DEFAULT_REVIEW_PERIOD = 7 days;

    address internal client = makeAddr("client");
    address internal freelancer = makeAddr("freelancer");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal stranger = makeAddr("stranger");

    TrustWorkFactory internal factory;
    MockUSDC internal usdc;

    function setUp() public virtual {
        factory = new TrustWorkFactory();
        usdc = new MockUSDC();
    }

    function _defaultAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = 1000 * USDC;
        amounts[1] = 2500 * USDC;
        amounts[2] = 500 * USDC;
    }

    function _createOrder(IERC20 token, uint256 feeBps, uint256[] memory amounts) internal returns (WorkOrder order) {
        vm.prank(client);
        order = factory.createWorkOrder(freelancer, token, feeRecipient, feeBps, DEFAULT_REVIEW_PERIOD, amounts);
    }

    function _createDefaultOrder() internal returns (WorkOrder) {
        return _createOrder(usdc, DEFAULT_FEE_BPS, _defaultAmounts());
    }

    function _mintAndApprove(MockUSDC token, WorkOrder order, uint256 amount) internal {
        token.mint(client, amount);
        vm.prank(client);
        token.approve(address(order), amount);
    }

    function _fund(WorkOrder order) internal {
        _mintAndApprove(usdc, order, order.totalAmount());
        vm.prank(client);
        order.fund();
    }

    function _submit(WorkOrder order, uint256 index) internal {
        vm.prank(freelancer);
        order.submitMilestone(index);
    }

    function _approve(WorkOrder order, uint256 index) internal {
        vm.prank(client);
        order.approveMilestone(index);
    }
}
