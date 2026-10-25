// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {BlocklistToken} from "../mocks/BlocklistToken.sol";
import {CallbackToken} from "../mocks/CallbackToken.sol";
import {MockExecutingWallet} from "../mocks/MockExecutingWallet.sol";
import {IntegrationTestBase} from "../utils/IntegrationTestBase.sol";
import {TransferLedger} from "../utils/TransferLedger.sol";

abstract contract TrustWorkIntegrationTest is IntegrationTestBase {
    event DisputeOpened(uint256 indexed index, uint256 indexed disputeId, uint256 consumedNonce);
    event RulingApplied(
        uint256 indexed disputeId,
        IArbitrationCourt.Ruling ruling,
        IArbitrationCourt.RulingReason reason,
        uint256 clientCredit,
        uint256 freelancerCredit,
        uint256 feeCredit
    );

    /// @dev I-01.
    function test_Factory_DeploysAndWiresCourtAndRegistry() public view {
        assertEq(address(factory.court()), address(court));
        assertEq(court.factory(), address(factory));
        assertEq(address(court.registry()), address(registry));
        assertEq(registry.court(), address(court));
        assertEq(address(court.stakeToken()), address(stakeToken));
        assertEq(address(registry.stakeToken()), address(stakeToken));
        assertEq(court.disputeFee(), DISPUTE_FEE);
        assertEq(court.seatLock(), SEAT_LOCK);
        assertEq(registry.seatLock(), SEAT_LOCK);
        assertEq(court.penaltyRecipient(), penaltyRecipient);
        assertEq(registry.penaltyRecipient(), penaltyRecipient);
    }

    /// @dev I-01: court and registry constructor validation still applies through the factory.
    function test_RevertWhen_FactoryCourtParametersInvalid() public {
        vm.expectRevert(ArbitrationCourt.ZeroAddress.selector);
        new TrustWorkFactory(stakeToken, DISPUTE_FEE, SEAT_LOCK, address(0));
        vm.expectRevert(ArbitrationCourt.ZeroDisputeFee.selector);
        new TrustWorkFactory(stakeToken, 0, SEAT_LOCK, penaltyRecipient);
        vm.expectRevert(ArbitrationCourt.ZeroSeatLock.selector);
        new TrustWorkFactory(stakeToken, DISPUTE_FEE, 0, penaltyRecipient);
        address eoa = makeAddr("notAToken");
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.TokenHasNoCode.selector, eoa));
        new TrustWorkFactory(IERC20(eoa), DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);

        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedCourt = vm.computeCreateAddress(predictedFactory, 1);
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.PenaltyRecipientIsProtocol.selector, predictedCourt));
        new TrustWorkFactory(stakeToken, DISPUTE_FEE, SEAT_LOCK, predictedCourt);
    }

    /// @dev I-02.
    function test_IsWorkOrder_OnlyOrdersThisFactoryCreated() public {
        WorkOrder order = _createDefaultOrder();
        assertTrue(factory.isWorkOrder(address(order)));
        assertFalse(factory.isWorkOrder(stranger));
        assertFalse(factory.isWorkOrder(address(court)));

        IArbitrationCourt orderCourt = factory.court();
        WorkOrder direct = new WorkOrder(
            client,
            freelancer,
            paymentToken,
            feeRecipient,
            FEE_BPS,
            REVIEW_PERIOD,
            DELIVERY_PERIOD,
            orderCourt,
            _defaultAmounts()
        );
        assertFalse(factory.isWorkOrder(address(direct)));

        TrustWorkFactory other = new TrustWorkFactory(stakeToken, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        assertFalse(other.isWorkOrder(address(order)));

        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.prank(client);
        vm.expectRevert(WorkOrder.NoMilestones.selector);
        factory.createWorkOrder(
            freelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, new uint256[](0)
        );
        assertFalse(factory.isWorkOrder(predicted));

        _activateArbitrators(3, SEAT_LOCK);
        _fundDirect(direct);
        vm.prank(freelancer);
        direct.submitMilestone(0);
        _approveCourtFee(client);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.UnknownOrder.selector, address(direct)));
        vm.prank(client);
        direct.openDispute(0);
        assertEq(uint256(direct.status()), uint256(WorkOrder.OrderStatus.Active));
        assertEq(direct.approvalNonce(), 0);
        assertEq(court.disputeCount(), 0);
    }

    /// @dev I-03.
    function test_RevertWhen_PenaltyRecipientIsParty() public {
        bytes memory expected =
            abi.encodeWithSelector(TrustWorkFactory.PenaltyRecipientIsParty.selector, penaltyRecipient);
        vm.expectRevert(expected);
        vm.prank(penaltyRecipient);
        factory.createWorkOrder(
            freelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        vm.expectRevert(expected);
        vm.prank(client);
        factory.createWorkOrder(
            penaltyRecipient, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        vm.expectRevert(expected);
        vm.prank(client);
        factory.createWorkOrder(
            freelancer, paymentToken, penaltyRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );

        WorkOrder courtCollects = _createOrder(client, address(court), _defaultAmounts());
        assertEq(courtCollects.feeRecipient(), address(court));
    }

    /// @dev I-04.
    function test_RevertWhen_OpenDisputeByNonClientOrInWrongOrderStatus() public {
        _activateArbitrators(3, 4 * SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _expectOpenRevert(
            order,
            0,
            client,
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Unfunded)
        );

        _fund(order);
        _submit(order, 0);
        _approveCourtFee(freelancer);
        _expectOpenRevert(order, 0, freelancer, abi.encodeWithSelector(WorkOrder.NotClient.selector, freelancer));
        _expectOpenRevert(order, 0, stranger, abi.encodeWithSelector(WorkOrder.NotClient.selector, stranger));

        _approveCourtFee(client);
        vm.prank(client);
        order.openDispute(0);
        _approveCourtFee(client);
        _expectOpenRevert(
            order,
            0,
            client,
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Disputed)
        );
        _resolveAs(order.disputeId(), Outcome.FreelancerMajority);
        order.applyRuling();
        _expectOpenRevert(
            order,
            0,
            client,
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Terminated)
        );

        uint256[] memory single = new uint256[](1);
        single[0] = 100 * USDC;
        WorkOrder completed = _createOrder(client, feeRecipient, single);
        _fund(completed);
        _submitAndApprove(completed, 0);
        _expectOpenRevert(
            completed,
            0,
            client,
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Completed)
        );

        WorkOrder expired = _createDefaultOrder();
        _fund(expired);
        vm.warp(expired.getMilestone(0).deliveryDeadline);
        vm.prank(client);
        expired.reclaimAfterDeliveryExpiry();
        _expectOpenRevert(
            expired,
            0,
            client,
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Terminated)
        );
    }

    /// @dev I-05.
    function test_RevertWhen_OpenDisputeOnPendingOrNonCurrentMilestone() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _approveCourtFee(client);
        _expectOpenRevert(
            order,
            0,
            client,
            abi.encodeWithSelector(WorkOrder.InvalidMilestoneStatus.selector, 0, WorkOrder.MilestoneStatus.Pending)
        );
        _expectOpenRevert(order, 1, client, abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 1, 0));
        _submitAndApprove(order, 0);
        _expectOpenRevert(order, 0, client, abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        _expectOpenRevert(
            order,
            1,
            client,
            abi.encodeWithSelector(WorkOrder.InvalidMilestoneStatus.selector, 1, WorkOrder.MilestoneStatus.Pending)
        );
    }

    /// @dev I-06.
    function test_OpenDispute_ReviewDeadlineBoundary() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        uint256 reviewDeadline = order.getMilestone(0).reviewDeadline;
        _approveCourtFee(client);

        uint256 state = vm.snapshotState();
        vm.warp(reviewDeadline - 1);
        vm.prank(client);
        order.openDispute(0);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Disputed));
        vm.revertToState(state);

        vm.warp(reviewDeadline);
        _expectOpenRevert(
            order, 0, client, abi.encodeWithSelector(WorkOrder.ReviewPeriodElapsed.selector, 0, reviewDeadline)
        );
        order.finalizeMilestone(0);
        assertEq(uint256(order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Settled));
        assertEq(order.approvalNonce(), 1);
    }

    /// @dev I-07: one block at `reviewDeadline - 1`, both transaction orders, direct and signed approval.
    function test_Race_ApprovalAndDisputeOneSecondBeforeReviewDeadline() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        vm.warp(order.getMilestone(0).reviewDeadline - 1);
        _approveCourtFee(client);
        bytes memory signature = _signApproval(order, 0, 0, block.timestamp);

        for (uint256 path; path < 4; ++path) {
            uint256 state = vm.snapshotState();
            bool signed = path >= 2;
            bool approvalFirst = path % 2 == 0;
            if (approvalFirst) {
                _settleFirst(order, signed, signature);
                _expectOpenRevert(
                    order, 0, client, abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1)
                );
                assertEq(order.approvalNonce(), 1);
                assertEq(order.disputeId(), 0);
            } else {
                vm.prank(client);
                order.openDispute(0);
                bytes memory disputed =
                    abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Disputed);
                vm.expectRevert(disputed);
                if (signed) {
                    order.approveMilestoneBySignature(0, 0, block.timestamp, signature);
                } else {
                    vm.prank(client);
                    order.approveMilestone(0);
                }
                assertEq(order.approvalNonce(), 1);
                assertEq(order.directPaid(), 0);
                assertEq(order.outstandingObligations(), order.totalAmount());
            }
            vm.revertToState(state);
        }
    }

    /// @dev I-08: at `reviewDeadline` the dispute fails in either order and each settlement path settles once.
    function test_Race_DisputeFinalizeAndApprovalAtReviewDeadline() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        uint256 reviewDeadline = order.getMilestone(0).reviewDeadline;
        vm.warp(reviewDeadline);
        _approveCourtFee(client);
        bytes memory elapsed = abi.encodeWithSelector(WorkOrder.ReviewPeriodElapsed.selector, 0, reviewDeadline);

        uint256 state = vm.snapshotState();
        _expectOpenRevert(order, 0, client, elapsed);
        order.finalizeMilestone(0);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        vm.prank(client);
        order.approveMilestone(0);
        assertEq(order.directPaid(), 1000 * USDC);
        vm.revertToState(state);

        vm.prank(client);
        order.approveMilestone(0);
        _expectOpenRevert(order, 0, client, abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        order.finalizeMilestone(0);
        assertEq(order.directPaid(), 1000 * USDC);
        assertEq(order.approvalNonce(), 1);
    }

    /// @dev I-09.
    function test_OpenDispute_ConsumesOneNonceAndReportsIt() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submitAndApprove(order, 0);
        _submit(order, 1);
        _approveCourtFee(client);

        vm.expectEmit(address(order));
        emit DisputeOpened(1, 1, 1);
        vm.prank(client);
        order.openDispute(1);

        assertEq(order.approvalNonce(), 2);
        assertEq(order.disputeId(), 1);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Disputed));
        assertEq(uint256(order.getMilestone(1).status), uint256(WorkOrder.MilestoneStatus.Disputed));
        assertEq(order.outstandingObligations(), 3000 * USDC);
        assertEq(court.getDispute(1).order, address(order));
        assertEq(court.getDispute(1).milestoneIndex, 1);
        assertEq(court.getDispute(1).client, client);
        _assertNonceInvariant(order);
    }

    /// @dev I-10.
    function test_StaleSignatures_RejectedWhileDisputedAndAfterRuling() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submitAndApprove(order, 0);
        uint256 deadline = block.timestamp + 30 days;
        bytes memory disputedSignature = _signApproval(order, 1, 1, deadline);
        bytes memory futureSignature = _signApproval(order, 2, 2, deadline);
        uint256 disputeId = _openDispute(order, 1);
        assertEq(order.approvalNonce(), 2);

        _expectSignatureRevert(order, 1, 1, deadline, disputedSignature, WorkOrder.OrderStatus.Disputed);
        _expectSignatureRevert(order, 2, 2, deadline, futureSignature, WorkOrder.OrderStatus.Disputed);

        _resolveAs(disputeId, Outcome.ClientMajority);
        order.applyRuling();
        _expectSignatureRevert(order, 1, 1, deadline, disputedSignature, WorkOrder.OrderStatus.Terminated);
        _expectSignatureRevert(order, 2, 2, deadline, futureSignature, WorkOrder.OrderStatus.Terminated);
        assertEq(order.approvalNonce(), 2);
        assertEq(order.directPaid(), 1000 * USDC);
        _assertNonceInvariant(order);
    }

    /// @dev I-11: a failed fee pull rolls back the order, the nonce, balances, reservations and court counters.
    function test_RevertWhen_CourtFeeCannotBePulledEverythingRollsBack() public {
        _activateArbitrators(4, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        uint256 orderBalance = paymentToken.balanceOf(address(order));
        uint256 courtBalance = stakeToken.balanceOf(address(court));

        stakeToken.mint(client, DISPUTE_FEE);
        vm.prank(client);
        stakeToken.approve(address(order), DISPUTE_FEE);
        _expectOpenRevert(
            order,
            0,
            client,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(court), 0, DISPUTE_FEE)
        );
        _assertUndisputed(order, orderBalance, courtBalance);

        vm.prank(client);
        stakeToken.approve(address(court), DISPUTE_FEE - 1);
        _expectOpenRevert(
            order,
            0,
            client,
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(court), DISPUTE_FEE - 1, DISPUTE_FEE
            )
        );
        _assertUndisputed(order, orderBalance, courtBalance);

        uint256 held = stakeToken.balanceOf(client);
        vm.prank(client);
        assertTrue(stakeToken.transfer(stranger, held));
        vm.prank(client);
        stakeToken.approve(address(court), DISPUTE_FEE);
        _expectOpenRevert(
            order,
            0,
            client,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, client, 0, DISPUTE_FEE)
        );
        _assertUndisputed(order, orderBalance, courtBalance);

        _approveCourtFee(client);
        vm.prank(client);
        order.openDispute(0);
        assertEq(order.disputeId(), 1);
        assertEq(registry.accountOf(_arbitrator(0)).reserved, SEAT_LOCK);
    }

    /// @dev I-12.
    function test_RevertWhen_BlockedFunctionsCalledWhileDisputed() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        uint256 disputeId = _openDispute(order, 0);
        bytes memory disputed =
            abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Disputed);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signApproval(order, 0, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(order), order.totalAmount(), deadline);

        vm.startPrank(client);
        vm.expectRevert(disputed);
        order.fund();
        vm.expectRevert(disputed);
        order.fundWithPermit(deadline, v, r, s);
        vm.expectRevert(disputed);
        order.approveMilestone(0);
        vm.expectRevert(disputed);
        order.reclaimAfterDeliveryExpiry();
        vm.expectRevert(disputed);
        order.openDispute(0);
        vm.stopPrank();
        vm.expectRevert(disputed);
        vm.prank(freelancer);
        order.submitMilestone(0);
        vm.expectRevert(disputed);
        order.approveMilestoneBySignature(0, 1, deadline, signature);
        vm.warp(order.getMilestone(0).reviewDeadline);
        vm.expectRevert(disputed);
        order.finalizeMilestone(0);
        vm.warp(order.getMilestone(0).deliveryDeadline);
        vm.expectRevert(disputed);
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();
        vm.expectRevert(disputed);
        order.claimPayout(client);

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Disputed));
        assertEq(order.approvalNonce(), 1);
        assertEq(order.disputeId(), disputeId);
        assertEq(order.outstandingObligations(), order.totalAmount());
    }

    /// @dev I-13: the ruling is read from the court for this order's own dispute; credits follow §11.1.
    function test_ApplyRuling_CreditsEachReasonAfterResolution() public {
        _activateArbitrators(3, 10 * SEAT_LOCK);
        for (uint256 o; o < 5; ++o) {
            Outcome outcome = Outcome(o);
            WorkOrder order = _createDefaultOrder();
            _fund(order);
            _submitAndApprove(order, 0);
            uint256 disputeId = _openDispute(order, 1);

            vm.expectRevert(abi.encodeWithSelector(WorkOrder.RulingNotReady.selector, disputeId));
            order.applyRuling();

            _resolveAs(disputeId, outcome);
            (uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit) =
                _expectedCredits(2500 * USDC, 500 * USDC, FEE_BPS, outcome);
            (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = _expectedRuling(outcome);
            ledger.begin();
            vm.expectEmit(address(order));
            emit RulingApplied(disputeId, ruling, reason, clientCredit, freelancerCredit, feeCredit);
            vm.prank(stranger);
            order.applyRuling();
            ledger.end(TransferLedger.Transition.OrderClaim, new TransferLedger.Edge[](0));

            assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Terminated));
            assertEq(uint256(order.getMilestone(1).status), uint256(WorkOrder.MilestoneStatus.Disputed));
            assertEq(uint256(order.getMilestone(2).status), uint256(WorkOrder.MilestoneStatus.Pending));
            assertEq(order.currentMilestone(), 1);
            assertEq(order.claimable(client), clientCredit);
            assertEq(order.claimable(freelancer), freelancerCredit);
            assertEq(order.claimable(feeRecipient), feeCredit);
            assertEq(order.outstandingObligations(), 3000 * USDC);
            assertEq(order.approvalNonce(), 2);

            vm.expectRevert(
                abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Terminated)
            );
            order.applyRuling();
            _assertOrderLedger(order);
        }
        _assertProtocolEquations();
    }

    /// @dev I-13: a ruling for another order's dispute cannot be applied to this one.
    function test_ApplyRuling_IgnoresOtherDisputes() public {
        _activateArbitrators(3, 4 * SEAT_LOCK);
        WorkOrder first = _createDefaultOrder();
        WorkOrder second = _createDefaultOrder();
        _fund(first);
        _fund(second);
        uint256 firstId = _openDispute(first, 0);
        uint256 secondId = _openDispute(second, 0);
        _resolveAs(firstId, Outcome.ClientMajority);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.RulingNotReady.selector, secondId));
        second.applyRuling();
        first.applyRuling();
        assertEq(first.claimable(client), 4000 * USDC);
        assertEq(uint256(second.status()), uint256(WorkOrder.OrderStatus.Disputed));
    }

    /// @dev I-14.
    function test_Claims_BlockedFreelancerDoesNotBlockOtherClaims() public {
        _activateArbitrators(3, SEAT_LOCK);
        BlocklistToken blockToken = new BlocklistToken();
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(
            freelancer, blockToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        blockToken.mint(client, 4000 * USDC);
        vm.prank(client);
        blockToken.approve(address(order), 4000 * USDC);
        vm.prank(client);
        order.fund();
        _submit(order, 0);
        _approveCourtFee(client);
        vm.prank(client);
        order.openDispute(0);
        _resolveAs(order.disputeId(), Outcome.FreelancerMajority);
        order.applyRuling();
        uint256 freelancerCredit = 1000 * USDC - _fee(1000 * USDC, FEE_BPS);

        blockToken.setBlocked(freelancer, true);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, freelancer));
        order.claimPayout(freelancer);
        assertEq(order.claimable(freelancer), freelancerCredit);
        assertEq(order.outstandingObligations(), 4000 * USDC);
        assertEq(order.claimsPaid(), 0);

        assertEq(order.claimPayout(client), 3000 * USDC);
        assertEq(order.claimPayout(feeRecipient), _fee(1000 * USDC, FEE_BPS));
        assertEq(blockToken.balanceOf(client), 3000 * USDC);
        assertEq(blockToken.balanceOf(feeRecipient), _fee(1000 * USDC, FEE_BPS));
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, client));
        order.claimPayout(client);

        blockToken.setBlocked(freelancer, false);
        vm.prank(stranger);
        assertEq(order.claimPayout(freelancer), freelancerCredit);
        assertEq(blockToken.balanceOf(freelancer), freelancerCredit);
        assertEq(order.outstandingObligations(), 0);
        assertEq(order.claimsPaid(), 4000 * USDC);
        _assertOrderConservation(order);
    }

    /// @dev I-15.
    function test_FeeRecipientIsClient_CreditsAccumulateInOneEntry() public {
        _activateArbitrators(3, 4 * SEAT_LOCK);
        Outcome[2] memory outcomes = [Outcome.FreelancerMajority, Outcome.SplitByTie];
        for (uint256 o; o < 2; ++o) {
            WorkOrder order = _createOrder(client, client, _defaultAmounts());
            _fund(order);
            _submitAndApprove(order, 0);
            uint256 disputeId = _openDispute(order, 1);
            _resolveAs(disputeId, outcomes[o]);
            _applyRuling(order);
            (uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit) =
                _expectedCredits(2500 * USDC, 500 * USDC, FEE_BPS, outcomes[o]);
            assertEq(order.claimable(client), clientCredit + feeCredit);
            assertEq(order.claimable(freelancer), freelancerCredit);
            _claim(order, client);
            _claim(order, freelancer);
            assertEq(order.outstandingObligations(), 0);
            _assertOrderLedger(order);
        }
        _assertProtocolEquations();
    }

    /// @dev I-16: a contract client approves the court and opens the dispute through its own calls.
    function test_ContractClient_ApprovesCourtAndOpensDispute() public {
        _activateArbitrators(3, SEAT_LOCK);
        MockExecutingWallet wallet = new MockExecutingWallet(client);
        vm.prank(client);
        bytes memory created = wallet.execute(
            address(factory),
            abi.encodeCall(
                TrustWorkFactory.createWorkOrder,
                (freelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts())
            )
        );
        WorkOrder order = abi.decode(created, (WorkOrder));
        ledger.trackOrder(address(order));
        assertEq(order.client(), address(wallet));
        paymentToken.mint(address(wallet), 4000 * USDC);
        stakeToken.mint(address(wallet), DISPUTE_FEE);
        vm.startPrank(client);
        wallet.execute(address(paymentToken), abi.encodeCall(IERC20.approve, (address(order), 4000 * USDC)));
        wallet.execute(address(order), abi.encodeCall(WorkOrder.fund, ()));
        vm.stopPrank();

        _submit(order, 0);
        order.approveMilestoneBySignature(0, 0, block.timestamp, _signApproval(order, 0, 0, block.timestamp));
        assertEq(order.approvalNonce(), 1);
        _submit(order, 1);

        vm.startPrank(client);
        wallet.execute(address(stakeToken), abi.encodeCall(IERC20.approve, (address(court), DISPUTE_FEE)));
        wallet.execute(address(order), abi.encodeCall(WorkOrder.openDispute, (1)));
        vm.stopPrank();
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Disputed));
        assertEq(court.getDispute(order.disputeId()).client, address(wallet));
        assertEq(stakeToken.balanceOf(address(wallet)), 0);

        _resolveAs(order.disputeId(), Outcome.ClientMajority);
        order.applyRuling();
        order.claimPayout(address(wallet));
        assertEq(paymentToken.balanceOf(address(wallet)), 3000 * USDC);
    }

    /// @dev I-17: a payment-token callback during a claim re-enters the order.
    function test_Reentrancy_PaymentTokenCallbackDuringClaimIsBlocked() public {
        _activateArbitrators(3, SEAT_LOCK);
        CallbackToken callbackToken = new CallbackToken();
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(
            freelancer, callbackToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        callbackToken.mint(client, 4000 * USDC);
        vm.prank(client);
        callbackToken.approve(address(order), 4000 * USDC);
        vm.prank(client);
        order.fund();
        _submit(order, 0);
        _approveCourtFee(client);
        vm.prank(client);
        order.openDispute(0);
        _resolveAs(order.disputeId(), Outcome.FreelancerMajority);
        order.applyRuling();

        bytes[2] memory reentries =
            [abi.encodeCall(WorkOrder.claimPayout, (freelancer)), abi.encodeCall(WorkOrder.applyRuling, ())];
        address[2] memory claimants = [client, feeRecipient];
        for (uint256 i; i < 2; ++i) {
            callbackToken.arm(address(order), address(order), reentries[i]);
            order.claimPayout(claimants[i]);
            _assertCallbackBlocked(callbackToken);
        }
        assertEq(order.claimable(freelancer), 1000 * USDC - _fee(1000 * USDC, FEE_BPS));
        assertEq(order.claimsPaid(), 3000 * USDC + _fee(1000 * USDC, FEE_BPS));
        _assertOrderConservation(order);
    }

    /// @dev I-17: a stake-token callback during the court's fee pull re-enters the order and the court.
    function test_Reentrancy_StakeTokenCallbackDuringFeePullIsBlocked() public {
        CallbackToken callbackStake = new CallbackToken();
        TrustWorkFactory callbackFactory = new TrustWorkFactory(callbackStake, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        ArbitrationCourt callbackCourt = ArbitrationCourt(address(callbackFactory.court()));
        ArbitratorRegistry callbackRegistry = ArbitratorRegistry(address(callbackCourt.registry()));
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitrator(i);
            callbackStake.mint(arbitrator, 2 * SEAT_LOCK);
            vm.startPrank(arbitrator);
            callbackStake.approve(address(callbackRegistry), 2 * SEAT_LOCK);
            callbackRegistry.deposit(2 * SEAT_LOCK);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        vm.prank(client);
        WorkOrder order = callbackFactory.createWorkOrder(
            freelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        _fundDirect(order);
        _submit(order, 0);
        callbackStake.mint(client, 10 * DISPUTE_FEE);
        vm.prank(client);
        callbackStake.approve(address(callbackCourt), 10 * DISPUTE_FEE);

        bytes[4] memory reentries = [
            abi.encodeCall(WorkOrder.openDispute, (0)),
            abi.encodeCall(WorkOrder.approveMilestone, (0)),
            abi.encodeCall(WorkOrder.applyRuling, ()),
            abi.encodeCall(ArbitrationCourt.openDispute, (0))
        ];
        for (uint256 i; i < reentries.length; ++i) {
            uint256 state = vm.snapshotState();
            address target = i == 3 ? address(callbackCourt) : address(order);
            callbackStake.arm(address(callbackCourt), target, reentries[i]);
            vm.prank(client);
            order.openDispute(0);
            _assertCallbackBlocked(callbackStake);
            assertEq(callbackCourt.disputeCount(), 1);
            assertEq(order.approvalNonce(), 1);
            assertEq(order.directPaid(), 0);
            vm.revertToState(state);
        }
    }

    /// @dev I-17, design §6.5: a stake-token callback during `resolve` that calls `applyRuling` already sees the ruling.
    function test_StakeTokenCallbackDuringResolveCanApplyRecordedRuling() public {
        CallbackToken callbackStake = new CallbackToken();
        TrustWorkFactory callbackFactory = new TrustWorkFactory(callbackStake, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        ArbitrationCourt callbackCourt = ArbitrationCourt(address(callbackFactory.court()));
        ArbitratorRegistry callbackRegistry = ArbitratorRegistry(address(callbackCourt.registry()));
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitrator(i);
            callbackStake.mint(arbitrator, SEAT_LOCK);
            vm.startPrank(arbitrator);
            callbackStake.approve(address(callbackRegistry), SEAT_LOCK);
            callbackRegistry.deposit(SEAT_LOCK);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        vm.prank(client);
        WorkOrder order = callbackFactory.createWorkOrder(
            freelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        _fundDirect(order);
        _submit(order, 0);
        callbackStake.mint(client, DISPUTE_FEE);
        vm.prank(client);
        callbackStake.approve(address(callbackCourt), DISPUTE_FEE);
        vm.prank(client);
        order.openDispute(0);
        uint256 disputeId = order.disputeId();
        uint256 selectionBlock = callbackCourt.getDispute(disputeId).selectionBlock;
        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256("callback seed"));
        callbackCourt.drawPanel(disputeId);
        vm.warp(callbackCourt.getDispute(disputeId).revealDeadline);

        callbackStake.arm(address(callbackCourt), address(order), abi.encodeCall(WorkOrder.applyRuling, ()));
        callbackCourt.resolve(disputeId);

        assertTrue(callbackStake.callbackAttempted());
        assertTrue(callbackStake.callbackSucceeded());
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Terminated));
        assertEq(order.claimable(client), 4000 * USDC - 1000 * USDC / 2 + _fee(0, FEE_BPS));
        assertEq(order.claimable(freelancer), 500 * USDC - _fee(500 * USDC, FEE_BPS));
        assertEq(callbackCourt.penaltiesReceived(), 3 * SEAT_LOCK);
    }

    /// @dev I-18.
    function test_Donations_DuringDisputeCreateNoLiabilityOrCredit() public {
        _activateArbitrators(3, SEAT_LOCK);
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        uint256 disputeId = _openDispute(order, 0);
        uint256 pendingFees = court.pendingFees();
        uint256 totalStaked = registry.totalStaked();

        _donate(paymentToken, address(order), 7 * USDC);
        _donate(stakeToken, address(order), 3 * USDC);
        _donate(stakeToken, address(court), 11 * USDC);
        _donate(stakeToken, address(registry), 13 * USDC);

        assertEq(order.outstandingObligations(), 4000 * USDC);
        assertEq(court.pendingFees(), pendingFees);
        assertEq(court.totalClaimable(), 0);
        assertEq(registry.totalStaked(), totalStaked);
        assertEq(registry.depositsReceived(), totalStaked);
        _assertProtocolEquations();

        _resolveAs(disputeId, Outcome.ClientMajority);
        _applyRuling(order);
        assertEq(order.claimable(client), 4000 * USDC);
        _claim(order, client);
        for (uint256 i; i < 3; ++i) {
            if (court.claimable(_arbitrator(i)) != 0) _claimCourt(_arbitrator(i));
        }
        _claimCourt(penaltyRecipient);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, donor));
        order.claimPayout(donor);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NothingToClaim.selector, donor));
        court.claimReward(donor);
        assertEq(order.outstandingObligations(), 0);
        uint256 orderDonations = _sharedToken() ? 10 * USDC : 7 * USDC;
        assertEq(paymentToken.balanceOf(address(order)), orderDonations);
        assertEq(court.totalClaimable(), 0);
        assertEq(stakeToken.balanceOf(address(court)), 11 * USDC);
        _assertOrderLedger(order);
        _assertProtocolEquations();
    }

    /// @dev I-19.
    function test_Sizes_WithinDeploymentLimits() public {
        WorkOrder order = _createDefaultOrder();
        assertLt(address(factory).code.length, 24_576);
        assertLt(address(order).code.length, 24_576);
        assertLt(address(court).code.length, 24_576);
        assertLt(address(registry).code.length, 24_576);
        assertLt(type(TrustWorkFactory).creationCode.length, 49_152);
    }

    /// @dev I-20 (finding R2): with an empty court the dispute ends `FreelancerWins (NoPanel)` and the client's net cost
    /// equals approving the milestone.
    function test_EmptyCourt_NoPanelEqualsNotDisputing() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000 * USDC;
        amounts[1] = 500 * USDC;
        WorkOrder order = _createOrder(client, feeRecipient, amounts);
        _fund(order);
        uint256 clientPaymentBefore = paymentToken.balanceOf(client);
        uint256 clientStakeBefore = stakeToken.balanceOf(client);
        uint256 disputeId = _openDispute(order, 0);
        assertEq(
            uint256(court.getDispute(disputeId).status), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates)
        );

        _resolveAs(disputeId, Outcome.NoPanel);
        (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(disputeId);
        assertEq(uint256(ruling), uint256(IArbitrationCourt.Ruling.FreelancerWins));
        assertEq(uint256(reason), uint256(IArbitrationCourt.RulingReason.NoPanel));
        _applyRuling(order);
        _claim(order, client);
        _claim(order, freelancer);
        _claim(order, feeRecipient);
        assertEq(_claimCourt(client), DISPUTE_FEE);

        uint256 fee = _fee(1000 * USDC, FEE_BPS);
        assertEq(paymentToken.balanceOf(freelancer), 1000 * USDC - fee);
        assertEq(paymentToken.balanceOf(feeRecipient), fee);
        uint256 received = paymentToken.balanceOf(client) - clientPaymentBefore;
        if (!_sharedToken()) received += stakeToken.balanceOf(client) - clientStakeBefore;
        assertEq(received, 500 * USDC + DISPUTE_FEE);
        assertEq(1500 * USDC + DISPUTE_FEE - received, 1000 * USDC);
        assertEq(court.penaltiesReceived(), 0);
        _assertOrderLedger(order);
        _assertProtocolEquations();
    }

    /// @dev I-21: design §11.5, every equation after every step.
    function test_Trace_EquationsAfterEveryStep() public {
        address[] memory arbitrators = _activateArbitrators(4, 200 * USDC);
        WorkOrder order = _createDefaultOrder();
        _assertTraceStep(order, 0, 0, 0, 0, 0, 0, 800, 0, 0, 800);
        _fund(order);
        _assertTraceStep(order, 4000, 0, 0, 4000, 0, 0, 800, 0, 0, 800);
        _submitAndApprove(order, 0);
        _assertTraceStep(order, 4000, 1000, 0, 3000, 0, 0, 800, 0, 0, 800);
        uint256 disputeId = _openDispute(order, 1);
        assertEq(registry.candidatesOf(disputeId).length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(registry.accountOf(arbitrators[i]).reserved, SEAT_LOCK);
        }
        _assertTraceCourt(20, 0, 0, 20, 0);
        _assertTraceStep(order, 4000, 1000, 0, 3000, 0, 0, 800, 20, 0, 800);

        address[3] memory panel = _drawPanel(disputeId);
        address faulty = panel[2];
        for (uint256 j; j < 2; ++j) {
            vm.prank(panel[j]);
            court.commitVote(disputeId, _commitment(disputeId, panel[j], FOR_FREELANCER));
        }
        vm.warp(court.getDispute(disputeId).commitDeadline);
        for (uint256 j; j < 2; ++j) {
            vm.prank(panel[j]);
            court.revealVote(disputeId, FOR_FREELANCER, _salt(disputeId, panel[j]));
        }
        vm.warp(court.getDispute(disputeId).revealDeadline);
        TransferLedger.Edge[] memory penalty = new TransferLedger.Edge[](1);
        penalty[0] = TransferLedger.Edge(address(registry), address(court), SEAT_LOCK);
        ledger.begin();
        court.resolve(disputeId);
        ledger.end(TransferLedger.Transition.Penalty, penalty);
        _assertTraceCourt(20, 100, 0, 0, 120);
        assertEq(court.claimable(panel[0]), 10 * USDC);
        assertEq(court.claimable(panel[1]), 10 * USDC);
        assertEq(court.claimable(penaltyRecipient), 100 * USDC);
        _assertTraceStep(order, 4000, 1000, 0, 3000, 0, 100, 700, 120, 0, 800);

        _applyRuling(order);
        assertEq(order.claimable(freelancer), 2_437_500_000);
        assertEq(order.claimable(feeRecipient), 62_500_000);
        assertEq(order.claimable(client), 500 * USDC);
        _assertTraceStep(order, 4000, 1000, 0, 3000, 0, 100, 700, 120, 0, 800);
        _claim(order, freelancer);
        assertEq(order.claimsPaid(), 2_437_500_000);
        assertEq(order.outstandingObligations(), 562_500_000);
        _claim(order, client);
        _claim(order, feeRecipient);
        _assertTraceStep(order, 4000, 1000, 3000, 0, 0, 100, 700, 120, 0, 800);

        _claimCourt(panel[0]);
        _assertTraceCourt(20, 100, 10, 0, 110);
        ledger.begin();
        vm.prank(faulty);
        registry.withdraw(100 * USDC);
        _end(TransferLedger.Transition.Unstake, address(registry), faulty, 100 * USDC);
        assertFalse(registry.accountOf(faulty).listed);
        _assertTraceStep(order, 4000, 1000, 3000, 0, 100, 100, 600, 110, 10, 800);

        assertEq(paymentToken.balanceOf(address(order)), 0);
        assertEq(stakeToken.balanceOf(address(court)), 110 * USDC);
        assertEq(stakeToken.balanceOf(address(registry)), 600 * USDC);
    }

    /// @dev I-22: payouts whose recipient is the court or the registry are unsolicited balance for that contract.
    function test_ProtocolContractRecipients_ReceiveUnsolicitedBalanceOnly() public {
        _activateArbitrators(3, SEAT_LOCK);
        address registryAsFreelancer = address(registry);
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(
            registryAsFreelancer,
            paymentToken,
            address(court),
            FEE_BPS,
            REVIEW_PERIOD,
            DELIVERY_PERIOD,
            _defaultAmounts()
        );
        ledger.trackOrder(address(order));
        _fund(order);
        uint256 totalStaked = registry.totalStaked();

        vm.prank(registryAsFreelancer);
        order.submitMilestone(0);
        uint256 fee = _fee(1000 * USDC, FEE_BPS);
        TransferLedger.Edge[] memory edges = new TransferLedger.Edge[](2);
        edges[0] = TransferLedger.Edge(address(order), address(court), fee);
        edges[1] = TransferLedger.Edge(address(order), registryAsFreelancer, 1000 * USDC - fee);
        ledger.begin();
        vm.prank(client);
        order.approveMilestone(0);
        ledger.end(TransferLedger.Transition.Settle, edges);
        assertEq(court.pendingFees(), 0);
        assertEq(court.totalClaimable(), 0);
        assertEq(registry.totalStaked(), totalStaked);
        _assertProtocolEquations();

        vm.prank(registryAsFreelancer);
        order.submitMilestone(1);
        _approveCourtFee(client);
        ledger.begin();
        vm.prank(client);
        order.openDispute(1);
        _end(TransferLedger.Transition.DisputeFee, client, address(court), DISPUTE_FEE);
        _resolveAs(order.disputeId(), Outcome.FreelancerMajority);
        _applyRuling(order);
        _claim(order, address(court));
        _claim(order, registryAsFreelancer);
        _claim(order, client);
        assertEq(registry.totalStaked(), totalStaked);
        assertEq(court.pendingFees(), 0);
        assertEq(court.totalClaimable(), DISPUTE_FEE);
        _assertProtocolEquations();
        _assertOrderLedger(order);

        uint256 courtReceived = fee + _fee(2500 * USDC, FEE_BPS);
        uint256 registryReceived = 3500 * USDC - courtReceived;
        assertEq(ledger.unsolicited(address(court), address(paymentToken)), courtReceived);
        assertEq(ledger.unsolicited(address(registry), address(paymentToken)), registryReceived);
        assertEq(court.claimable(address(court)), 0);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NothingToClaim.selector, address(court)));
        court.claimReward(address(court));
        assertEq(registry.freeStake(address(registry)), 0);
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, 1, 0));
        vm.prank(address(registry));
        registry.withdraw(1);
    }

    /// @dev Escrow amounts near `type(uint256).max` with a token supply that still fits.
    function test_NearMaxEscrow_RulingsCreditAndClaimExactly() public {
        _activateArbitrators(3, 4 * SEAT_LOCK);
        uint256 total = type(uint256).max - 1e15;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000 * USDC;
        amounts[1] = (total - amounts[0]) / 2 + 1;
        amounts[2] = total - amounts[0] - amounts[1];
        WorkOrder order = _createOrder(client, feeRecipient, amounts);
        _fund(order);
        _submitAndApprove(order, 0);
        uint256 disputeId = _openDispute(order, 1);

        Outcome[3] memory outcomes = [Outcome.FreelancerMajority, Outcome.SplitByTie, Outcome.ClientMajority];
        for (uint256 o; o < 3; ++o) {
            uint256 state = vm.snapshotState();
            _resolveAs(disputeId, outcomes[o]);
            _applyRuling(order);
            (uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit) =
                _expectedCredits(amounts[1], amounts[2], FEE_BPS, outcomes[o]);
            assertEq(order.claimable(client), clientCredit);
            assertEq(order.claimable(freelancer), freelancerCredit);
            assertEq(order.claimable(feeRecipient), feeCredit);
            assertEq(clientCredit + freelancerCredit + feeCredit, amounts[1] + amounts[2]);
            if (clientCredit != 0) _claim(order, client);
            if (freelancerCredit != 0) _claim(order, freelancer);
            if (feeCredit != 0) _claim(order, feeRecipient);
            assertEq(order.outstandingObligations(), 0);
            _assertOrderLedger(order);
            _assertProtocolEquations();
            vm.revertToState(state);
        }
    }

    function _settleFirst(WorkOrder order, bool signed, bytes memory signature) private {
        if (signed) {
            order.approveMilestoneBySignature(0, 0, block.timestamp, signature);
        } else {
            vm.prank(client);
            order.approveMilestone(0);
        }
    }

    function _expectOpenRevert(WorkOrder order, uint256 index, address caller, bytes memory reason) internal {
        vm.expectRevert(reason);
        vm.prank(caller);
        order.openDispute(index);
    }

    function _expectSignatureRevert(
        WorkOrder order,
        uint256 index,
        uint256 nonce,
        uint256 deadline,
        bytes memory signature,
        WorkOrder.OrderStatus status
    ) private {
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, status));
        order.approveMilestoneBySignature(index, nonce, deadline, signature);
    }

    function _assertCallbackBlocked(CallbackToken callbackToken) private view {
        assertTrue(callbackToken.callbackAttempted());
        assertFalse(callbackToken.callbackSucceeded());
        assertEq(
            callbackToken.callbackRevertData(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    /// @dev Amounts in whole USDC: order funded, direct, claims, outstanding; registry withdrawn, penalties, staked;
    /// court pending plus claimable, court claims paid; registry deposits.
    function _assertTraceStep(
        WorkOrder order,
        uint256 funded,
        uint256 direct,
        uint256 claims,
        uint256 outstanding,
        uint256 withdrawn,
        uint256 penalties,
        uint256 staked,
        uint256 courtLiabilities,
        uint256 courtClaims,
        uint256 deposits
    ) private view {
        assertEq(funded * USDC, direct * USDC + claims * USDC + outstanding * USDC);
        assertEq(order.directPaid(), direct * USDC);
        assertEq(order.claimsPaid(), claims * USDC);
        assertEq(order.outstandingObligations(), outstanding * USDC);
        assertEq(deposits * USDC, withdrawn * USDC + penalties * USDC + staked * USDC);
        assertEq(registry.depositsReceived(), deposits * USDC);
        assertEq(registry.withdrawalsPaid(), withdrawn * USDC);
        assertEq(registry.penaltiesSent(), penalties * USDC);
        assertEq(registry.totalStaked(), staked * USDC);
        assertEq(court.pendingFees() + court.totalClaimable(), courtLiabilities * USDC);
        assertEq(court.claimsPaid(), courtClaims * USDC);
        _assertOrderLedger(order);
        _assertProtocolEquations();
    }

    function _assertTraceCourt(uint256 fees, uint256 penalties, uint256 claims, uint256 pending, uint256 claimable)
        private
        view
    {
        assertEq(fees * USDC + penalties * USDC, claims * USDC + pending * USDC + claimable * USDC);
        assertEq(court.feesReceived(), fees * USDC);
        assertEq(court.penaltiesReceived(), penalties * USDC);
        assertEq(court.claimsPaid(), claims * USDC);
        assertEq(court.pendingFees(), pending * USDC);
        assertEq(court.totalClaimable(), claimable * USDC);
    }

    function _assertUndisputed(WorkOrder order, uint256 orderBalance, uint256 courtBalance) private {
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Active));
        assertEq(uint256(order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Submitted));
        assertEq(order.approvalNonce(), 0);
        assertEq(order.disputeId(), 0);
        assertEq(paymentToken.balanceOf(address(order)), orderBalance);
        assertEq(stakeToken.balanceOf(address(court)), courtBalance);
        assertEq(court.disputeCount(), 0);
        assertEq(court.pendingFees(), 0);
        assertEq(court.feesReceived(), 0);
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.None));
        for (uint256 i; i < 4; ++i) {
            assertEq(registry.accountOf(_arbitrator(i)).reserved, 0);
        }
    }

    function _fundDirect(WorkOrder order) internal {
        uint256 total = order.totalAmount();
        paymentToken.mint(client, total);
        vm.prank(client);
        paymentToken.approve(address(order), total);
        vm.prank(client);
        order.fund();
    }
}

contract TrustWorkIntegrationSharedTokenTest is TrustWorkIntegrationTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkIntegrationSplitTokenTest is TrustWorkIntegrationTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
