// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WorkOrder} from "../src/WorkOrder.sol";
import {WorkOrderTestBase} from "./utils/WorkOrderTestBase.sol";
import {BlocklistToken} from "./mocks/BlocklistToken.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract WorkOrderTest is WorkOrderTestBase {
    event Funded(address indexed client, uint256 amount);
    event MilestoneSubmitted(uint256 indexed index, uint256 reviewDeadline);
    event MilestoneSettled(
        uint256 indexed index, address indexed settledBy, bool byTimeout, uint256 freelancerPayout, uint256 fee
    );
    event OrderCompleted();

    WorkOrder internal order;

    function setUp() public override {
        super.setUp();
        order = _createDefaultOrder();
    }

    function test_MockUSDC_UsesSixDecimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_Fund_TransfersExactTotal() public {
        _mintAndApprove(usdc, order, order.totalAmount());

        vm.expectEmit(address(order));
        emit Funded(client, 4000 * USDC);
        vm.prank(client);
        order.fund();

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Active));
        assertEq(usdc.balanceOf(address(order)), 4000 * USDC);
        assertEq(usdc.balanceOf(client), 0);
        assertEq(usdc.allowance(client, address(order)), 0);
        assertEq(order.outstandingObligations(), 4000 * USDC);
    }

    function test_Fund_TakesOnlyTotalWhenAllowanceIsLarger() public {
        usdc.mint(client, 10_000 * USDC);
        vm.startPrank(client);
        usdc.approve(address(order), type(uint256).max);
        order.fund();
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(order)), 4000 * USDC);
        assertEq(usdc.balanceOf(client), 6000 * USDC);
    }

    function test_RevertWhen_FundWithInsufficientBalance() public {
        uint256 total = order.totalAmount();
        usdc.mint(client, total - 1);
        vm.prank(client);
        usdc.approve(address(order), total);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, client, total - 1, total)
        );
        vm.prank(client);
        order.fund();

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Unfunded));
        assertEq(order.outstandingObligations(), 0);
    }

    function test_RevertWhen_FundWithInsufficientAllowance() public {
        uint256 total = order.totalAmount();
        usdc.mint(client, total);
        vm.prank(client);
        usdc.approve(address(order), total - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(order), total - 1, total)
        );
        vm.prank(client);
        order.fund();

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Unfunded));
    }

    function test_RevertWhen_FundCalledByNonClient() public {
        _mintAndApprove(usdc, order, order.totalAmount());

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotClient.selector, freelancer));
        vm.prank(freelancer);
        order.fund();
    }

    function test_RevertWhen_FundCalledTwice() public {
        _fund(order);
        _mintAndApprove(usdc, order, order.totalAmount());

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Active));
        vm.prank(client);
        order.fund();

        assertEq(usdc.balanceOf(address(order)), 4000 * USDC);
    }

    function test_RevertWhen_FundWithFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        WorkOrder feeOrder = _createOrder(feeToken, DEFAULT_FEE_BPS, _defaultAmounts());
        uint256 total = feeOrder.totalAmount();
        uint256 received = total - total * feeToken.TRANSFER_FEE_BPS() / 10_000;
        feeToken.mint(client, total);
        vm.prank(client);
        feeToken.approve(address(feeOrder), total);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.DepositMismatch.selector, total, received));
        vm.prank(client);
        feeOrder.fund();

        assertEq(uint256(feeOrder.status()), uint256(WorkOrder.OrderStatus.Unfunded));
        assertEq(feeToken.balanceOf(client), total);
    }

    function test_RevertWhen_SubmitBeforeFunding() public {
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Unfunded));
        _submit(order, 0);
    }

    function test_Submit_RecordsReviewDeadline() public {
        _fund(order);
        vm.warp(1_700_000_000);

        vm.expectEmit(address(order));
        emit MilestoneSubmitted(0, 1_700_000_000 + DEFAULT_REVIEW_PERIOD);
        _submit(order, 0);

        WorkOrder.Milestone memory milestone = order.getMilestone(0);
        assertEq(uint256(milestone.status), uint256(WorkOrder.MilestoneStatus.Submitted));
        assertEq(milestone.submittedAt, 1_700_000_000);
        assertEq(milestone.reviewDeadline, 1_700_000_000 + DEFAULT_REVIEW_PERIOD);
        assertEq(order.currentMilestone(), 0);
        assertEq(order.outstandingObligations(), 4000 * USDC);
    }

    function test_RevertWhen_SubmitCalledByNonFreelancer() public {
        _fund(order);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotFreelancer.selector, client));
        vm.prank(client);
        order.submitMilestone(0);
    }

    function test_RevertWhen_SubmitOutOfOrder() public {
        _fund(order);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 1, 0));
        _submit(order, 1);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 3, 0));
        _submit(order, 3);
    }

    function test_RevertWhen_SubmitTwice() public {
        _fund(order);
        _submit(order, 0);

        vm.expectRevert(
            abi.encodeWithSelector(WorkOrder.InvalidMilestoneStatus.selector, 0, WorkOrder.MilestoneStatus.Submitted)
        );
        _submit(order, 0);
    }

    function test_RevertWhen_SubmitSettledMilestone() public {
        _fund(order);
        _submit(order, 0);
        _approve(order, 0);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        _submit(order, 0);
    }

    function test_Approve_PaysFreelancerAndFeeRecipient() public {
        _fund(order);
        _submit(order, 0);

        vm.expectEmit(address(order));
        emit MilestoneSettled(0, client, false, 975 * USDC, 25 * USDC);
        _approve(order, 0);

        assertEq(usdc.balanceOf(freelancer), 975 * USDC);
        assertEq(usdc.balanceOf(feeRecipient), 25 * USDC);
        assertEq(usdc.balanceOf(address(order)), 3000 * USDC);
        assertEq(order.outstandingObligations(), 3000 * USDC);
        assertEq(order.currentMilestone(), 1);
        assertEq(uint256(order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Settled));
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Active));
    }

    function test_Approve_AllowedAfterDeadline() public {
        _fund(order);
        _submit(order, 0);
        vm.warp(block.timestamp + DEFAULT_REVIEW_PERIOD + 1 days);

        vm.expectEmit(address(order));
        emit MilestoneSettled(0, client, false, 975 * USDC, 25 * USDC);
        _approve(order, 0);
    }

    function test_RevertWhen_ApproveCalledByNonClient() public {
        _fund(order);
        _submit(order, 0);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotClient.selector, freelancer));
        vm.prank(freelancer);
        order.approveMilestone(0);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotClient.selector, stranger));
        vm.prank(stranger);
        order.approveMilestone(0);
    }

    function test_RevertWhen_ApproveBeforeSubmission() public {
        _fund(order);

        vm.expectRevert(
            abi.encodeWithSelector(WorkOrder.InvalidMilestoneStatus.selector, 0, WorkOrder.MilestoneStatus.Pending)
        );
        _approve(order, 0);
    }

    function test_RevertWhen_ApproveBeforeFunding() public {
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Unfunded));
        _approve(order, 0);
    }

    function test_RevertWhen_ApproveOutOfOrder() public {
        _fund(order);
        _submit(order, 0);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 1, 0));
        _approve(order, 1);
    }

    function test_RevertWhen_SettleTwice() public {
        _fund(order);
        _submit(order, 0);
        _approve(order, 0);
        uint256 freelancerBalance = usdc.balanceOf(freelancer);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        _approve(order, 0);

        vm.warp(block.timestamp + DEFAULT_REVIEW_PERIOD);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        order.finalizeMilestone(0);

        assertEq(usdc.balanceOf(freelancer), freelancerBalance);
        assertEq(order.outstandingObligations(), 3000 * USDC);
    }

    function test_RevertWhen_SettleAfterCompletion() public {
        _fund(order);
        for (uint256 i; i < 3; ++i) {
            _submit(order, i);
            _approve(order, i);
        }

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Completed));
        _approve(order, 2);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Completed));
        order.finalizeMilestone(2);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Completed));
        _submit(order, 3);
    }

    function test_RevertWhen_FinalizeImmediatelyBeforeDeadline() public {
        _fund(order);
        _submit(order, 0);
        uint256 deadline = order.getMilestone(0).reviewDeadline;

        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.ReviewPeriodNotElapsed.selector, 0, deadline));
        order.finalizeMilestone(0);

        assertEq(uint256(order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Submitted));
    }

    function test_RevertWhen_FinalizeAtSubmissionTime() public {
        _fund(order);
        _submit(order, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                WorkOrder.ReviewPeriodNotElapsed.selector, 0, block.timestamp + DEFAULT_REVIEW_PERIOD
            )
        );
        order.finalizeMilestone(0);
    }

    function test_Finalize_ExactlyAtDeadline() public {
        _fund(order);
        _submit(order, 0);
        vm.warp(order.getMilestone(0).reviewDeadline);

        vm.expectEmit(address(order));
        emit MilestoneSettled(0, stranger, true, 975 * USDC, 25 * USDC);
        vm.prank(stranger);
        order.finalizeMilestone(0);

        assertEq(usdc.balanceOf(freelancer), 975 * USDC);
        assertEq(order.currentMilestone(), 1);
    }

    function test_Finalize_AfterDeadline() public {
        _fund(order);
        _submit(order, 0);
        vm.warp(order.getMilestone(0).reviewDeadline + 365 days);

        vm.prank(stranger);
        order.finalizeMilestone(0);

        assertEq(usdc.balanceOf(freelancer), 975 * USDC);
        assertEq(usdc.balanceOf(feeRecipient), 25 * USDC);
    }

    function test_Finalize_CallableByAnyParty() public {
        address[3] memory callers = [freelancer, client, stranger];
        uint256[3] memory fees = [25 * USDC, 62_500_000, 12_500_000];
        uint256[3] memory payouts = [975 * USDC, 2_437_500_000, 487_500_000];
        _fund(order);

        for (uint256 i; i < callers.length; ++i) {
            _submit(order, i);
            vm.warp(order.getMilestone(i).reviewDeadline);

            vm.expectEmit(address(order));
            emit MilestoneSettled(i, callers[i], true, payouts[i], fees[i]);
            vm.prank(callers[i]);
            order.finalizeMilestone(i);
        }

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
        assertEq(usdc.balanceOf(feeRecipient), 100 * USDC);
    }

    function test_RevertWhen_FinalizeUnsubmittedMilestone() public {
        _fund(order);
        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(
            abi.encodeWithSelector(WorkOrder.InvalidMilestoneStatus.selector, 0, WorkOrder.MilestoneStatus.Pending)
        );
        order.finalizeMilestone(0);
    }

    function test_FullLifecycle_CompletesOrder() public {
        _fund(order);
        uint256[] memory amounts = _defaultAmounts();
        uint256[] memory expectedOutstanding = new uint256[](3);
        expectedOutstanding[0] = 3000 * USDC;
        expectedOutstanding[1] = 500 * USDC;
        expectedOutstanding[2] = 0;

        _submit(order, 0);
        _approve(order, 0);
        assertEq(order.outstandingObligations(), expectedOutstanding[0]);

        _submit(order, 1);
        vm.warp(order.getMilestone(1).reviewDeadline);
        order.finalizeMilestone(1);
        assertEq(order.outstandingObligations(), expectedOutstanding[1]);

        _submit(order, 2);
        vm.expectEmit(address(order));
        emit MilestoneSettled(2, client, false, 4875 * USDC / 10, 125 * USDC / 10);
        vm.expectEmit(address(order));
        emit OrderCompleted();
        _approve(order, 2);

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
        assertEq(order.currentMilestone(), amounts.length);
        assertEq(order.outstandingObligations(), 0);
        assertEq(usdc.balanceOf(address(order)), 0);
        assertEq(usdc.balanceOf(freelancer), 3900 * USDC);
        assertEq(usdc.balanceOf(feeRecipient), 100 * USDC);
        for (uint256 i; i < amounts.length; ++i) {
            assertEq(uint256(order.getMilestone(i).status), uint256(WorkOrder.MilestoneStatus.Settled));
        }
    }

    function test_Fee_RoundsDown() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 39;
        amounts[1] = 1;
        WorkOrder smallOrder = _createOrder(usdc, DEFAULT_FEE_BPS, amounts);
        _fund(smallOrder);

        _submit(smallOrder, 0);
        _approve(smallOrder, 0);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(freelancer), 39);

        _submit(smallOrder, 1);
        _approve(smallOrder, 1);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(freelancer), 40);

        assertEq(smallOrder.feeFor(40), 1);
        assertEq(smallOrder.feeFor(79), 1);
        assertEq(smallOrder.feeFor(80), 2);
    }

    function test_Fee_ZeroFeeSkipsFeeTransfer() public {
        BlocklistToken token = new BlocklistToken();
        token.setBlocked(feeRecipient, true);
        WorkOrder zeroFeeOrder = _createOrder(token, 0, _defaultAmounts());
        _fundWith(token, zeroFeeOrder);

        _submit(zeroFeeOrder, 0);
        vm.expectEmit(address(zeroFeeOrder));
        emit MilestoneSettled(0, client, false, 1000 * USDC, 0);
        _approve(zeroFeeOrder, 0);

        assertEq(token.balanceOf(freelancer), 1000 * USDC);
        assertEq(token.balanceOf(feeRecipient), 0);
    }

    function test_Fee_MaximumFee() public {
        WorkOrder maxFeeOrder = _createOrder(usdc, 1000, _defaultAmounts());
        _fund(maxFeeOrder);

        _submit(maxFeeOrder, 0);
        _approve(maxFeeOrder, 0);

        assertEq(usdc.balanceOf(feeRecipient), 100 * USDC);
        assertEq(usdc.balanceOf(freelancer), 900 * USDC);
    }

    function test_Donation_BeforeFundingDoesNotBlockFunding() public {
        usdc.mint(address(order), 123 * USDC);

        _fund(order);

        assertEq(order.outstandingObligations(), 4000 * USDC);
        assertEq(usdc.balanceOf(address(order)), 4123 * USDC);

        for (uint256 i; i < 3; ++i) {
            _submit(order, i);
            _approve(order, i);
        }
        assertEq(order.outstandingObligations(), 0);
        assertEq(usdc.balanceOf(address(order)), 123 * USDC);
        assertEq(usdc.balanceOf(freelancer) + usdc.balanceOf(feeRecipient), 4000 * USDC);
    }

    function test_Donation_AfterFundingDoesNotAffectSettlement() public {
        _fund(order);
        _submit(order, 0);
        usdc.mint(address(order), 77);

        _approve(order, 0);

        assertEq(usdc.balanceOf(freelancer), 975 * USDC);
        assertEq(usdc.balanceOf(feeRecipient), 25 * USDC);
        assertEq(order.outstandingObligations(), 3000 * USDC);
        assertEq(usdc.balanceOf(address(order)), 3000 * USDC + 77);
    }

    function test_RevertWhen_FreelancerPayoutFails() public {
        BlocklistToken token = new BlocklistToken();
        WorkOrder blockedOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        _fundWith(token, blockedOrder);
        _submit(blockedOrder, 0);
        token.setBlocked(freelancer, true);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, freelancer));
        _approve(blockedOrder, 0);

        _assertMilestoneZeroUnsettled(blockedOrder, token);
    }

    function test_RevertWhen_FeePayoutFails() public {
        BlocklistToken token = new BlocklistToken();
        WorkOrder blockedOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        _fundWith(token, blockedOrder);
        _submit(blockedOrder, 0);
        token.setBlocked(feeRecipient, true);
        vm.warp(blockedOrder.getMilestone(0).reviewDeadline);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, feeRecipient));
        blockedOrder.finalizeMilestone(0);

        _assertMilestoneZeroUnsettled(blockedOrder, token);

        token.setBlocked(feeRecipient, false);
        blockedOrder.finalizeMilestone(0);
        assertEq(token.balanceOf(freelancer), 975 * USDC);
    }

    function test_Reentrancy_DuringFundingIsBlocked() public {
        ReentrantToken token = new ReentrantToken();
        WorkOrder reentrantOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        uint256 total = reentrantOrder.totalAmount();
        token.mint(client, 2 * total);
        vm.prank(client);
        token.approve(address(reentrantOrder), 2 * total);
        token.arm(address(reentrantOrder), abi.encodeCall(WorkOrder.fund, ()));

        vm.prank(client);
        reentrantOrder.fund();

        _assertReentryBlocked(token);
        assertEq(token.balanceOf(address(reentrantOrder)), total);
        assertEq(reentrantOrder.outstandingObligations(), total);
    }

    function test_Reentrancy_DuringApprovalPayoutIsBlocked() public {
        ReentrantToken token = new ReentrantToken();
        WorkOrder reentrantOrder = _fundedReentrantOrder(token);
        _submit(reentrantOrder, 0);
        token.arm(address(reentrantOrder), abi.encodeCall(WorkOrder.approveMilestone, (0)));

        _approve(reentrantOrder, 0);

        _assertReentryBlocked(token);
        _assertSettledOnce(reentrantOrder, token);
    }

    function test_Reentrancy_DuringTimeoutPayoutIsBlocked() public {
        ReentrantToken token = new ReentrantToken();
        WorkOrder reentrantOrder = _fundedReentrantOrder(token);
        _submit(reentrantOrder, 0);
        vm.warp(reentrantOrder.getMilestone(0).reviewDeadline);
        token.arm(address(reentrantOrder), abi.encodeCall(WorkOrder.finalizeMilestone, (0)));

        vm.prank(stranger);
        reentrantOrder.finalizeMilestone(0);

        _assertReentryBlocked(token);
        _assertSettledOnce(reentrantOrder, token);
    }

    function test_Reentrancy_SubmitDuringPayoutIsBlocked() public {
        ReentrantToken token = new ReentrantToken();
        WorkOrder reentrantOrder = _fundedReentrantOrder(token);
        _submit(reentrantOrder, 0);
        token.arm(address(reentrantOrder), abi.encodeCall(WorkOrder.submitMilestone, (1)));

        _approve(reentrantOrder, 0);

        _assertReentryBlocked(token);
        assertEq(uint256(reentrantOrder.getMilestone(1).status), uint256(WorkOrder.MilestoneStatus.Pending));
    }

    function _fundWith(BlocklistToken token, WorkOrder target) private {
        token.mint(client, target.totalAmount());
        vm.startPrank(client);
        token.approve(address(target), target.totalAmount());
        target.fund();
        vm.stopPrank();
    }

    function _fundedReentrantOrder(ReentrantToken token) private returns (WorkOrder reentrantOrder) {
        reentrantOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        token.mint(client, reentrantOrder.totalAmount());
        vm.startPrank(client);
        token.approve(address(reentrantOrder), reentrantOrder.totalAmount());
        reentrantOrder.fund();
        vm.stopPrank();
    }

    function _assertReentryBlocked(ReentrantToken token) private view {
        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertEq(
            token.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function _assertSettledOnce(WorkOrder target, ReentrantToken token) private view {
        assertEq(token.balanceOf(freelancer), 975 * USDC);
        assertEq(token.balanceOf(feeRecipient), 25 * USDC);
        assertEq(token.balanceOf(address(target)), 3000 * USDC);
        assertEq(target.outstandingObligations(), 3000 * USDC);
        assertEq(target.currentMilestone(), 1);
    }

    function _assertMilestoneZeroUnsettled(WorkOrder target, BlocklistToken token) private view {
        assertEq(uint256(target.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Submitted));
        assertEq(target.currentMilestone(), 0);
        assertEq(target.outstandingObligations(), 4000 * USDC);
        assertEq(token.balanceOf(address(target)), 4000 * USDC);
        assertEq(token.balanceOf(freelancer), 0);
        assertEq(token.balanceOf(feeRecipient), 0);
    }
}
