// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WorkOrder} from "../src/WorkOrder.sol";
import {IArbitrationCourt} from "../src/interfaces/IArbitrationCourt.sol";
import {WorkOrderTestBase} from "./utils/WorkOrderTestBase.sol";

contract TrustWorkFactoryTest is WorkOrderTestBase {
    event WorkOrderCreated(
        address indexed order,
        address indexed client,
        address indexed freelancer,
        address token,
        uint256 totalAmount,
        uint256 deliveryPeriod
    );

    function test_CreateWorkOrder_StoresTerms() public {
        uint256[] memory amounts = _defaultAmounts();
        WorkOrder order = _createDefaultOrder();

        assertEq(order.client(), client);
        assertEq(order.freelancer(), freelancer);
        assertEq(address(order.token()), address(usdc));
        assertEq(order.feeRecipient(), feeRecipient);
        assertEq(order.feeBps(), DEFAULT_FEE_BPS);
        assertEq(order.reviewPeriod(), DEFAULT_REVIEW_PERIOD);
        assertEq(order.deliveryPeriod(), DEFAULT_DELIVERY_PERIOD);
        assertEq(order.totalAmount(), 4000 * USDC);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Unfunded));
        assertEq(order.currentMilestone(), 0);
        assertEq(order.outstandingObligations(), 0);
        assertEq(order.milestoneCount(), amounts.length);
        assertEq(address(order.court()), address(factory.court()));
        assertEq(order.disputeId(), 0);
        assertTrue(factory.isWorkOrder(address(order)));

        for (uint256 i; i < amounts.length; ++i) {
            WorkOrder.Milestone memory milestone = order.getMilestone(i);
            assertEq(milestone.amount, amounts[i]);
            assertEq(uint256(milestone.status), uint256(WorkOrder.MilestoneStatus.Pending));
            assertEq(milestone.submittedAt, 0);
            assertEq(milestone.reviewDeadline, 0);
            assertEq(milestone.deliveryDeadline, 0);
        }
    }

    function test_CreateWorkOrder_EmitsEvent() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(address(factory));
        emit WorkOrderCreated(predicted, client, freelancer, address(usdc), 4000 * USDC, DEFAULT_DELIVERY_PERIOD);
        WorkOrder order = _createDefaultOrder();

        assertEq(address(order), predicted);
    }

    function test_CreateWorkOrder_ClientIsCaller() public {
        vm.prank(stranger);
        WorkOrder order = factory.createWorkOrder(
            freelancer,
            usdc,
            feeRecipient,
            DEFAULT_FEE_BPS,
            DEFAULT_REVIEW_PERIOD,
            DEFAULT_DELIVERY_PERIOD,
            _defaultAmounts()
        );

        assertEq(order.client(), stranger);
    }

    function test_CreateWorkOrder_OrdersAreIndependent() public {
        WorkOrder first = _createDefaultOrder();
        WorkOrder second = _createDefaultOrder();
        assertTrue(address(first) != address(second));

        _fund(first);

        assertEq(uint256(first.status()), uint256(WorkOrder.OrderStatus.Active));
        assertEq(uint256(second.status()), uint256(WorkOrder.OrderStatus.Unfunded));
        assertEq(usdc.balanceOf(address(second)), 0);
    }

    function test_CreateWorkOrder_AcceptsBoundaryTerms() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.startPrank(client);
        WorkOrder maxTerms = factory.createWorkOrder(freelancer, usdc, feeRecipient, 1000, 30 days, 180 days, amounts);
        WorkOrder minTerms = factory.createWorkOrder(freelancer, usdc, feeRecipient, 0, 1, 1, amounts);
        vm.stopPrank();

        assertEq(maxTerms.feeBps(), maxTerms.MAX_FEE_BPS());
        assertEq(maxTerms.reviewPeriod(), maxTerms.MAX_REVIEW_PERIOD());
        assertEq(minTerms.feeBps(), 0);
        assertEq(minTerms.reviewPeriod(), 1);
        assertEq(maxTerms.deliveryPeriod(), maxTerms.MAX_DELIVERY_PERIOD());
        assertEq(minTerms.deliveryPeriod(), 1);
    }

    function test_RevertWhen_FreelancerIsZero() public {
        vm.expectRevert(WorkOrder.ZeroAddress.selector);
        _create(address(0), usdc, feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());
    }

    function test_RevertWhen_TokenIsZero() public {
        vm.expectRevert(WorkOrder.ZeroAddress.selector);
        _create(freelancer, IERC20(address(0)), feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());
    }

    function test_RevertWhen_FeeRecipientIsZero() public {
        vm.expectRevert(WorkOrder.ZeroAddress.selector);
        _create(freelancer, usdc, address(0), DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());
    }

    function test_RevertWhen_ClientIsFreelancer() public {
        vm.expectRevert(WorkOrder.ClientIsFreelancer.selector);
        _create(client, usdc, feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());
    }

    function test_RevertWhen_TokenHasNoCode() public {
        address eoa = makeAddr("notAToken");
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.TokenHasNoCode.selector, eoa));
        _create(freelancer, IERC20(eoa), feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());
    }

    function test_RevertWhen_NoMilestones() public {
        vm.expectRevert(WorkOrder.NoMilestones.selector);
        _create(freelancer, usdc, feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, new uint256[](0));
    }

    function test_RevertWhen_MilestoneAmountIsZero() public {
        uint256[] memory amounts = _defaultAmounts();
        amounts[1] = 0;

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.ZeroMilestoneAmount.selector, 1));
        _create(freelancer, usdc, feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, amounts);
    }

    function test_RevertWhen_FeeAboveMaximum() public {
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.FeeTooHigh.selector, 1001));
        _create(freelancer, usdc, feeRecipient, 1001, DEFAULT_REVIEW_PERIOD, _defaultAmounts());
    }

    function test_RevertWhen_ReviewPeriodIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidReviewPeriod.selector, 0));
        _create(freelancer, usdc, feeRecipient, DEFAULT_FEE_BPS, 0, _defaultAmounts());
    }

    function test_RevertWhen_ReviewPeriodAboveMaximum() public {
        uint256 tooLong = 30 days + 1;
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidReviewPeriod.selector, tooLong));
        _create(freelancer, usdc, feeRecipient, DEFAULT_FEE_BPS, tooLong, _defaultAmounts());
    }

    function test_RevertWhen_DeliveryPeriodIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidDeliveryPeriod.selector, 0));
        _createWithDeliveryPeriod(0);
    }

    function test_RevertWhen_DeliveryPeriodAboveMaximum() public {
        uint256 tooLong = 180 days + 1;
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidDeliveryPeriod.selector, tooLong));
        _createWithDeliveryPeriod(tooLong);
    }

    function test_RevertWhen_FeeRecipientIsPredictedOrderAddress() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectRevert(WorkOrder.FeeRecipientIsOrder.selector);
        _create(freelancer, usdc, predicted, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());

        assertEq(predicted.code.length, 0);
    }

    function test_RevertWhen_DirectlyDeployedOrderIsOwnFeeRecipient() public {
        IArbitrationCourt court = factory.court();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(WorkOrder.FeeRecipientIsOrder.selector);
        new WorkOrder(
            client,
            freelancer,
            usdc,
            predicted,
            DEFAULT_FEE_BPS,
            DEFAULT_REVIEW_PERIOD,
            DEFAULT_DELIVERY_PERIOD,
            court,
            _defaultAmounts()
        );
    }

    function test_CreateWorkOrder_AllowsFeeRecipientAliases() public {
        WorkOrder clientCollects =
            _create(freelancer, usdc, client, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());
        WorkOrder freelancerCollects =
            _create(freelancer, usdc, freelancer, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, _defaultAmounts());

        assertEq(clientCollects.feeRecipient(), client);
        assertEq(freelancerCollects.feeRecipient(), freelancer);
    }

    function test_RevertWhen_MilestoneSumOverflows() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = type(uint256).max;
        amounts[1] = 1;

        vm.expectRevert();
        _create(freelancer, usdc, feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, amounts);
    }

    function test_RevertWhen_WorkOrderDeployedDirectlyWithZeroClient() public {
        IArbitrationCourt court = factory.court();
        vm.expectRevert(WorkOrder.ZeroAddress.selector);
        new WorkOrder(
            address(0),
            freelancer,
            usdc,
            feeRecipient,
            DEFAULT_FEE_BPS,
            DEFAULT_REVIEW_PERIOD,
            DEFAULT_DELIVERY_PERIOD,
            court,
            _defaultAmounts()
        );
    }

    function test_RevertWhen_WorkOrderDeployedDirectlyWithZeroCourt() public {
        vm.expectRevert(WorkOrder.ZeroAddress.selector);
        new WorkOrder(
            client,
            freelancer,
            usdc,
            feeRecipient,
            DEFAULT_FEE_BPS,
            DEFAULT_REVIEW_PERIOD,
            DEFAULT_DELIVERY_PERIOD,
            IArbitrationCourt(address(0)),
            _defaultAmounts()
        );
    }

    function _createWithDeliveryPeriod(uint256 deliveryPeriod) private returns (WorkOrder) {
        vm.prank(client);
        return factory.createWorkOrder(
            freelancer, usdc, feeRecipient, DEFAULT_FEE_BPS, DEFAULT_REVIEW_PERIOD, deliveryPeriod, _defaultAmounts()
        );
    }

    function _create(
        address freelancer_,
        IERC20 token,
        address feeRecipient_,
        uint256 feeBps,
        uint256 reviewPeriod,
        uint256[] memory amounts
    ) private returns (WorkOrder) {
        vm.prank(client);
        return factory.createWorkOrder(
            freelancer_, token, feeRecipient_, feeBps, reviewPeriod, DEFAULT_DELIVERY_PERIOD, amounts
        );
    }
}
