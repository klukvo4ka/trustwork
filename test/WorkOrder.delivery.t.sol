// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WorkOrder} from "../src/WorkOrder.sol";
import {WorkOrderTestBase} from "./utils/WorkOrderTestBase.sol";
import {BlocklistToken} from "./mocks/BlocklistToken.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {MockPermitUSDC} from "./mocks/MockPermitUSDC.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract WorkOrderDeliveryTest is WorkOrderTestBase {
    event DeliveryExpired(uint256 indexed index, uint256 clientCredit);
    event PayoutClaimed(address indexed account, uint256 amount);

    uint256 internal constant START = 1_700_000_000;

    WorkOrder internal order;

    function setUp() public override {
        super.setUp();
        vm.warp(START);
        order = _createDefaultOrder();
    }

    function test_Fund_SetsFirstDeliveryDeadline() public {
        _fund(order);

        assertEq(order.getMilestone(0).deliveryDeadline, START + DEFAULT_DELIVERY_PERIOD);
        assertEq(order.getMilestone(1).deliveryDeadline, 0);
        assertEq(order.getMilestone(2).deliveryDeadline, 0);
    }

    function test_FundWithPermit_SetsFirstDeliveryDeadlineOnBothPaths() public {
        MockPermitUSDC token = new MockPermitUSDC();
        WorkOrder permitOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        WorkOrder fallbackOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());

        _fundThroughPath(permitOrder, token, 1);
        vm.warp(START + 1 hours);
        _fundThroughPath(fallbackOrder, token, 2);

        assertEq(permitOrder.getMilestone(0).deliveryDeadline, START + DEFAULT_DELIVERY_PERIOD);
        assertEq(fallbackOrder.getMilestone(0).deliveryDeadline, START + 1 hours + DEFAULT_DELIVERY_PERIOD);
        assertEq(token.nonces(client), 1);
    }

    function test_RevertWhen_FundingFailsLeavesNoDeliveryDeadline() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        WorkOrder feeOrder = _createOrder(feeToken, DEFAULT_FEE_BPS, _defaultAmounts());
        feeToken.mint(client, feeOrder.totalAmount());
        vm.startPrank(client);
        feeToken.approve(address(feeOrder), feeOrder.totalAmount());
        vm.expectRevert();
        feeOrder.fund();
        vm.stopPrank();

        assertEq(feeOrder.getMilestone(0).deliveryDeadline, 0);
        assertEq(uint256(feeOrder.status()), uint256(WorkOrder.OrderStatus.Unfunded));
    }

    function test_DirectSettlement_SetsNextDeliveryDeadline() public {
        _fund(order);
        _submit(order, 0);
        vm.warp(START + 3 days);

        _approve(order, 0);

        assertEq(order.getMilestone(1).deliveryDeadline, START + 3 days + DEFAULT_DELIVERY_PERIOD);
        assertEq(order.getMilestone(2).deliveryDeadline, 0);
    }

    function test_SignedSettlement_SetsNextDeliveryDeadline() public {
        _fund(order);
        _submit(order, 0);
        vm.warp(START + 2 days);
        bytes memory signature = _signApproval(clientKey, order, 0, 0, block.timestamp);

        vm.prank(stranger);
        order.approveMilestoneBySignature(0, 0, block.timestamp, signature);

        assertEq(order.getMilestone(1).deliveryDeadline, START + 2 days + DEFAULT_DELIVERY_PERIOD);
    }

    function test_TimeoutSettlement_SetsNextDeliveryDeadline() public {
        _fund(order);
        _submit(order, 0);
        uint256 reviewDeadline = order.getMilestone(0).reviewDeadline;
        vm.warp(reviewDeadline);

        vm.prank(stranger);
        order.finalizeMilestone(0);

        assertEq(order.getMilestone(1).deliveryDeadline, reviewDeadline + DEFAULT_DELIVERY_PERIOD);
    }

    function test_FinalSettlement_CompletesWithoutFurtherDeadline() public {
        _fund(order);
        _settleThrough(order, 3);

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
        assertEq(order.directPaid(), order.totalAmount());
        assertEq(order.outstandingObligations(), 0);
    }

    function test_RevertWhen_PayoutFailsRollsBackCountersAndNextDeadline() public {
        BlocklistToken token = new BlocklistToken();
        WorkOrder blockedOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        _fundBlocklist(token, blockedOrder);
        _submit(blockedOrder, 0);
        token.setBlocked(freelancer, true);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, freelancer));
        _approve(blockedOrder, 0);

        assertEq(blockedOrder.getMilestone(1).deliveryDeadline, 0);
        assertEq(blockedOrder.directPaid(), 0);
        assertEq(blockedOrder.approvalNonce(), 0);
        assertEq(blockedOrder.currentMilestone(), 0);
        assertEq(blockedOrder.outstandingObligations(), blockedOrder.totalAmount());
    }

    function test_Submit_AllowedOneSecondBeforeDeliveryDeadline() public {
        _fund(order);
        vm.warp(order.getMilestone(0).deliveryDeadline - 1);

        _submit(order, 0);

        assertEq(uint256(order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Submitted));
    }

    function test_RevertWhen_SubmitAtDeliveryDeadline() public {
        _fund(order);
        uint256 deadline = order.getMilestone(0).deliveryDeadline;
        vm.warp(deadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.DeliveryPeriodElapsed.selector, 0, deadline));
        _submit(order, 0);
    }

    function test_RevertWhen_SubmitAfterDeliveryDeadline() public {
        _fund(order);
        uint256 deadline = order.getMilestone(0).deliveryDeadline;
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.DeliveryPeriodElapsed.selector, 0, deadline));
        _submit(order, 0);

        assertEq(uint256(order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Pending));
    }

    function test_DeliveryExpiry_DoesNotAffectSubmittedMilestone() public {
        _fund(order);
        vm.warp(order.getMilestone(0).deliveryDeadline - 1);
        _submit(order, 0);
        vm.warp(order.getMilestone(0).deliveryDeadline + 30 days);

        vm.expectRevert(
            abi.encodeWithSelector(WorkOrder.InvalidMilestoneStatus.selector, 0, WorkOrder.MilestoneStatus.Submitted)
        );
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();

        vm.prank(stranger);
        order.finalizeMilestone(0);
        assertEq(usdc.balanceOf(freelancer), 975 * USDC);
    }

    function test_RevertWhen_ReclaimOneSecondBeforeDeliveryDeadline() public {
        _fund(order);
        uint256 deadline = order.getMilestone(0).deliveryDeadline;
        vm.warp(deadline - 1);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.DeliveryPeriodNotElapsed.selector, 0, deadline));
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Active));
        assertEq(order.claimable(client), 0);
    }

    function test_Reclaim_AtDeliveryDeadline() public {
        _fund(order);
        vm.warp(order.getMilestone(0).deliveryDeadline);

        vm.expectEmit(address(order));
        emit DeliveryExpired(0, 4000 * USDC);
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Terminated));
    }

    function test_Reclaim_AtFirstMilestone() public {
        _assertReclaimAt(0, 4000 * USDC);
    }

    function test_Reclaim_AtMiddleMilestone() public {
        _assertReclaimAt(1, 3000 * USDC);
    }

    function test_Reclaim_AtLastMilestone() public {
        _assertReclaimAt(2, 500 * USDC);
    }

    function test_RevertWhen_ReclaimCalledByNonClient() public {
        _fund(order);
        vm.warp(order.getMilestone(0).deliveryDeadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotClient.selector, freelancer));
        vm.prank(freelancer);
        order.reclaimAfterDeliveryExpiry();

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotClient.selector, stranger));
        vm.prank(stranger);
        order.reclaimAfterDeliveryExpiry();

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Active));
    }

    function test_RevertWhen_ReclaimBeforeFunding() public {
        vm.warp(START + 365 days);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Unfunded));
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();
    }

    function test_RevertWhen_ReclaimAfterCompletion() public {
        _fund(order);
        _settleThrough(order, 3);
        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Completed));
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();
    }

    function test_RevertWhen_ReclaimTwice() public {
        _reclaimAt(order, 0);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Terminated));
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();

        assertEq(order.claimable(client), 4000 * USDC);
        assertEq(order.approvalNonce(), 1);
    }

    function test_Terminated_BlocksEveryLifecycleFunction() public {
        MockPermitUSDC token = new MockPermitUSDC();
        WorkOrder permitOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        _fundThroughPath(permitOrder, token, 0);
        vm.warp(permitOrder.getMilestone(0).deliveryDeadline);
        vm.prank(client);
        permitOrder.reclaimAfterDeliveryExpiry();
        bytes memory terminated =
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Terminated);

        vm.startPrank(client);
        vm.expectRevert(terminated);
        permitOrder.fund();
        vm.expectRevert(terminated);
        permitOrder.fundWithPermit(block.timestamp, 27, bytes32(0), bytes32(0));
        vm.expectRevert(terminated);
        permitOrder.approveMilestone(0);
        vm.expectRevert(terminated);
        permitOrder.reclaimAfterDeliveryExpiry();
        vm.stopPrank();

        vm.expectRevert(terminated);
        _submit(permitOrder, 0);
        vm.expectRevert(terminated);
        permitOrder.finalizeMilestone(0);
        vm.expectRevert(terminated);
        permitOrder.approveMilestoneBySignature(0, 1, block.timestamp, "");
    }

    function test_ClaimPayout_PaysReclaimCredit() public {
        _reclaimAt(order, 1);
        uint256 credit = order.claimable(client);

        vm.expectEmit(address(order));
        emit PayoutClaimed(client, credit);
        vm.prank(client);
        uint256 amount = order.claimPayout(client);

        assertEq(amount, 3000 * USDC);
        assertEq(usdc.balanceOf(client), 3000 * USDC);
        assertEq(order.claimable(client), 0);
        assertEq(order.outstandingObligations(), 0);
        assertEq(order.claimsPaid(), 3000 * USDC);
        assertEq(order.directPaid(), 1000 * USDC);
        assertEq(usdc.balanceOf(address(order)), 0);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Terminated));
    }

    function test_RevertWhen_ClaimRepeatedOrWithoutCredit() public {
        _reclaimAt(order, 0);
        vm.prank(client);
        order.claimPayout(client);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, client));
        order.claimPayout(client);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, freelancer));
        order.claimPayout(freelancer);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, feeRecipient));
        order.claimPayout(feeRecipient);

        assertEq(order.claimsPaid(), 4000 * USDC);
    }

    function test_RevertWhen_ClaimBeforeTermination() public {
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Unfunded));
        order.claimPayout(client);

        _fund(order);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Active));
        order.claimPayout(client);

        _settleThrough(order, 3);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Completed));
        order.claimPayout(client);
    }

    function test_ClaimPayout_ByUnrelatedCallerPaysCreditedAccount() public {
        _reclaimAt(order, 0);

        vm.prank(stranger);
        order.claimPayout(client);

        assertEq(usdc.balanceOf(client), 4000 * USDC);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_BlockedClient_ReclaimSucceedsAndClaimRetries() public {
        BlocklistToken token = new BlocklistToken();
        WorkOrder blockedOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        _fundBlocklist(token, blockedOrder);
        token.setBlocked(client, true);
        vm.warp(blockedOrder.getMilestone(0).deliveryDeadline);

        vm.prank(client);
        blockedOrder.reclaimAfterDeliveryExpiry();
        assertEq(blockedOrder.claimable(client), 4000 * USDC);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, client));
        blockedOrder.claimPayout(client);

        assertEq(blockedOrder.claimable(client), 4000 * USDC);
        assertEq(blockedOrder.outstandingObligations(), 4000 * USDC);
        assertEq(blockedOrder.claimsPaid(), 0);
        assertEq(token.balanceOf(address(blockedOrder)), 4000 * USDC);

        token.setBlocked(client, false);
        blockedOrder.claimPayout(client);
        assertEq(token.balanceOf(client), 4000 * USDC);
        assertEq(blockedOrder.outstandingObligations(), 0);
    }

    function test_Donations_StayOutsideCreditsAndClaims() public {
        usdc.mint(address(order), 11 * USDC);
        _fund(order);
        usdc.mint(address(order), 22 * USDC);
        _reclaimAt(order, 0);

        assertEq(order.claimable(client), 4000 * USDC);
        vm.prank(client);
        order.claimPayout(client);

        assertEq(usdc.balanceOf(client), 4000 * USDC);
        assertEq(usdc.balanceOf(address(order)), 33 * USDC);
        assertEq(order.outstandingObligations(), 0);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, client));
        order.claimPayout(client);
    }

    function test_Reentrancy_DuringClaimTransferIsBlocked() public {
        bytes[3] memory reentries = [
            abi.encodeCall(WorkOrder.claimPayout, (client)),
            abi.encodeCall(WorkOrder.reclaimAfterDeliveryExpiry, ()),
            abi.encodeCall(WorkOrder.approveMilestone, (0))
        ];
        for (uint256 i; i < reentries.length; ++i) {
            ReentrantToken token = new ReentrantToken();
            WorkOrder reentrantOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
            token.mint(client, reentrantOrder.totalAmount());
            vm.startPrank(client);
            token.approve(address(reentrantOrder), reentrantOrder.totalAmount());
            reentrantOrder.fund();
            vm.warp(reentrantOrder.getMilestone(0).deliveryDeadline);
            reentrantOrder.reclaimAfterDeliveryExpiry();
            vm.stopPrank();
            token.arm(address(reentrantOrder), reentries[i]);

            reentrantOrder.claimPayout(client);

            assertTrue(token.reentryAttempted());
            assertFalse(token.reentrySucceeded());
            assertEq(
                token.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(token.balanceOf(client), 4000 * USDC);
            assertEq(reentrantOrder.claimsPaid(), 4000 * USDC);
            assertEq(reentrantOrder.outstandingObligations(), 0);
        }
    }

    function test_StaleSignatures_FailAfterTermination() public {
        _fund(order);
        bytes memory current = _signApproval(clientKey, order, 0, 0, type(uint64).max);
        bytes memory nextNonce = _signApproval(clientKey, order, 0, 1, type(uint64).max);
        vm.warp(order.getMilestone(0).deliveryDeadline);
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();
        bytes memory terminated =
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Terminated);

        vm.expectRevert(terminated);
        order.approveMilestoneBySignature(0, 0, type(uint64).max, current);
        vm.expectRevert(terminated);
        order.approveMilestoneBySignature(0, 1, type(uint64).max, nextNonce);
        assertEq(order.approvalNonce(), 1);
    }

    function test_Counters_TrackEverySettlementPath() public {
        _fund(order);
        _submit(order, 0);
        _approve(order, 0);
        assertEq(order.directPaid(), 1000 * USDC);
        assertEq(order.approvalNonce(), 1);

        _submit(order, 1);
        bytes memory signature = _signApproval(clientKey, order, 1, 1, block.timestamp);
        vm.prank(stranger);
        order.approveMilestoneBySignature(1, 1, block.timestamp, signature);
        assertEq(order.directPaid(), 3500 * USDC);
        assertEq(order.approvalNonce(), 2);

        _submit(order, 2);
        vm.warp(order.getMilestone(2).reviewDeadline);
        order.finalizeMilestone(2);
        assertEq(order.directPaid(), 4000 * USDC);
        assertEq(order.approvalNonce(), 3);
        assertEq(order.claimsPaid(), 0);
        assertEq(order.directPaid() + order.claimsPaid() + order.outstandingObligations(), order.totalAmount());
    }

    function test_FeeRecipientAliases_SettleAndConserve() public {
        address[2] memory aliases = [client, freelancer];
        for (uint256 i; i < aliases.length; ++i) {
            MockPermitUSDC token = new MockPermitUSDC();
            vm.prank(client);
            WorkOrder aliasOrder = factory.createWorkOrder(
                freelancer,
                token,
                aliases[i],
                DEFAULT_FEE_BPS,
                DEFAULT_REVIEW_PERIOD,
                DEFAULT_DELIVERY_PERIOD,
                _defaultAmounts()
            );
            _fundThroughPath(aliasOrder, token, 0);
            _submit(aliasOrder, 0);
            _approve(aliasOrder, 0);
            vm.warp(aliasOrder.getMilestone(1).deliveryDeadline);
            vm.prank(client);
            aliasOrder.reclaimAfterDeliveryExpiry();
            aliasOrder.claimPayout(client);

            uint256 feeToAlias = 25 * USDC;
            uint256 clientExpected = 3000 * USDC + (aliases[i] == client ? feeToAlias : 0);
            uint256 freelancerExpected = 975 * USDC + (aliases[i] == freelancer ? feeToAlias : 0);
            assertEq(token.balanceOf(client), clientExpected);
            assertEq(token.balanceOf(freelancer), freelancerExpected);
            assertEq(token.balanceOf(address(aliasOrder)), 0);
            assertEq(aliasOrder.directPaid() + aliasOrder.claimsPaid(), aliasOrder.totalAmount());
        }
    }

    function test_Matrix_FundingPathTimesReclaimPosition() public {
        uint256 passed;
        uint256[3] memory unsettled = [4000 * USDC, 3000 * USDC, 500 * USDC];
        for (uint256 path; path < 3; ++path) {
            for (uint256 position; position < 3; ++position) {
                MockPermitUSDC token = new MockPermitUSDC();
                WorkOrder matrixOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
                _fundThroughPath(matrixOrder, token, path);
                _settleThrough(matrixOrder, position);
                vm.warp(matrixOrder.getMilestone(position).deliveryDeadline);

                vm.prank(client);
                matrixOrder.reclaimAfterDeliveryExpiry();

                assertEq(matrixOrder.claimable(client), unsettled[position]);
                assertEq(matrixOrder.outstandingObligations(), unsettled[position]);
                assertEq(matrixOrder.directPaid(), matrixOrder.totalAmount() - unsettled[position]);
                assertEq(matrixOrder.approvalNonce(), position + 1);
                assertEq(matrixOrder.currentMilestone(), position);
                assertEq(token.balanceOf(address(matrixOrder)), unsettled[position]);

                uint256 clientBefore = token.balanceOf(client);
                vm.prank(stranger);
                matrixOrder.claimPayout(client);

                assertEq(token.balanceOf(client) - clientBefore, unsettled[position]);
                assertEq(matrixOrder.claimsPaid(), unsettled[position]);
                assertEq(matrixOrder.outstandingObligations(), 0);
                assertEq(token.balanceOf(address(matrixOrder)), 0);
                assertEq(
                    matrixOrder.directPaid() + matrixOrder.claimsPaid() + matrixOrder.outstandingObligations(),
                    matrixOrder.totalAmount()
                );
                ++passed;
            }
        }
        assertEq(passed, 9);
    }

    function _assertReclaimAt(uint256 position, uint256 expectedCredit) private {
        uint256 clientBalance = usdc.balanceOf(client);
        _reclaimAt(order, position);

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Terminated));
        assertEq(order.claimable(client), expectedCredit);
        assertEq(order.outstandingObligations(), expectedCredit);
        assertEq(order.currentMilestone(), position);
        assertEq(order.approvalNonce(), position + 1);
        assertEq(uint256(order.getMilestone(position).status), uint256(WorkOrder.MilestoneStatus.Pending));
        assertEq(usdc.balanceOf(address(order)), expectedCredit);
        assertEq(usdc.balanceOf(client), clientBalance);
    }

    function _reclaimAt(WorkOrder target, uint256 position) private {
        if (target.status() == WorkOrder.OrderStatus.Unfunded) _fund(target);
        _settleThrough(target, position);
        vm.warp(target.getMilestone(position).deliveryDeadline);
        vm.prank(client);
        target.reclaimAfterDeliveryExpiry();
    }

    function _settleThrough(WorkOrder target, uint256 settledCount) private {
        for (uint256 i; i < settledCount; ++i) {
            _submit(target, i);
            _approve(target, i);
        }
    }

    function _fundThroughPath(WorkOrder target, MockPermitUSDC token, uint256 path) private {
        uint256 total = target.totalAmount();
        uint256 deadline = block.timestamp + 1 hours;
        token.mint(client, total);
        if (path == 0) {
            vm.startPrank(client);
            token.approve(address(target), total);
            target.fund();
            vm.stopPrank();
        } else if (path == 1) {
            (uint8 v, bytes32 r, bytes32 s) =
                _signPermit(clientKey, token, address(target), total, token.nonces(client), deadline);
            vm.prank(client);
            target.fundWithPermit(deadline, v, r, s);
        } else {
            vm.startPrank(client);
            token.approve(address(target), total);
            target.fundWithPermit(deadline, 27, bytes32(0), bytes32(0));
            vm.stopPrank();
        }
    }

    function _fundBlocklist(BlocklistToken token, WorkOrder target) private {
        token.mint(client, target.totalAmount());
        vm.startPrank(client);
        token.approve(address(target), target.totalAmount());
        target.fund();
        vm.stopPrank();
    }
}
