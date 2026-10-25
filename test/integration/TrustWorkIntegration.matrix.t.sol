// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IntegrationTestBase} from "../utils/IntegrationTestBase.sol";
import {TransferLedger} from "../utils/TransferLedger.sol";

/// @dev Matrices M3–M7 of the test plan. Every case starts from the same state (three activated arbitrators) through
/// a state snapshot, and expected values come from `IntegrationTestBase`'s independent model.
abstract contract TrustWorkIntegrationMatrixTest is IntegrationTestBase {
    enum TerminalPath {
        Completed,
        ExpiryFirst,
        ExpiryLast,
        FreelancerWins,
        ClientWins,
        Split,
        NoPanel
    }

    uint256 private _cases;

    function setUp() public override {
        super.setUp();
        _activateArbitrators(3, 4 * SEAT_LOCK);
    }

    /// @dev M3: rulings × disputed position on `[1000, 2500, 500]`, `feeBps = 250`.
    function test_MatrixM3_RulingByDisputePosition() public {
        uint256[] memory amounts = _defaultAmounts();
        for (uint256 o; o < 5; ++o) {
            for (uint256 position; position < 3; ++position) {
                uint256 state = vm.snapshotState();
                _runM3Case(amounts, Outcome(o), position);
                vm.revertToState(state);
                ++_cases;
            }
        }
        assertEq(_cases, 15);
    }

    /// @dev M4: funding path × terminal path, nonce and conservation invariants after every step.
    function test_MatrixM4_FundingByTerminalPath() public {
        for (uint256 f; f < 3; ++f) {
            for (uint256 p; p < 7; ++p) {
                uint256 state = vm.snapshotState();
                WorkOrder order = _createDefaultOrder();
                _assertOrderLedger(order);
                _fundBy(order, Funding(f));
                _assertOrderLedger(order);
                _runTerminalPath(order, TerminalPath(p));
                vm.revertToState(state);
                ++_cases;
            }
        }
        assertEq(_cases, 21);
    }

    /// @dev M5: every assignment of direct, signed and timeout settlement to three milestones.
    function test_MatrixM5_SettlementPathPerMilestone() public {
        uint256[] memory amounts = _defaultAmounts();
        for (uint256 assignment; assignment < 27; ++assignment) {
            uint256 state = vm.snapshotState();
            WorkOrder order = _createDefaultOrder();
            _fund(order);
            uint256 expectedFees;
            uint256 code = assignment;
            for (uint256 i; i < 3; ++i) {
                _submit(order, i);
                _settleBy(order, i, Settlement(code % 3));
                code /= 3;
                expectedFees += _fee(amounts[i], FEE_BPS);
                assertEq(order.approvalNonce(), i + 1);
                _assertOrderLedger(order);
            }
            assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
            assertEq(order.approvalNonce(), 3);
            assertEq(order.directPaid(), 4000 * USDC);
            assertEq(order.outstandingObligations(), 0);
            assertEq(paymentToken.balanceOf(feeRecipient), expectedFees);
            assertEq(paymentToken.balanceOf(freelancer), 4000 * USDC - expectedFees);
            vm.revertToState(state);
            ++_cases;
        }
        assertEq(_cases, 27);
    }

    /// @dev M6: each boundary of design §4 at `t - 1`, `t` and `t + 1` against each competing action.
    function test_MatrixM6_Boundaries() public {
        _activationBoundary();
        _deliveryBoundary();
        _reviewBoundary();
        _signatureBoundary();
        _panelBoundary();
        _seedBlockBoundary();
        _commitBoundary();
        _revealBoundary();
        console.log("M6 cases:", _cases);
        assertEq(_cases, 48);
    }

    /// @dev M7: the terminal paths of M4 with `fund`, every transfer observed and attributed to its transition, and
    /// an unsolicited transfer into each protocol contract that must not change its liabilities.
    function test_MatrixM7_TokenConfigurationByTerminalPath() public {
        for (uint256 p; p < 7; ++p) {
            uint256 state = vm.snapshotState();
            WorkOrder order = _createDefaultOrder();
            _donate(paymentToken, address(order), 1);
            _donate(stakeToken, address(court), 2);
            _donate(stakeToken, address(registry), 3);
            _fund(order);
            _runTerminalPath(order, TerminalPath(p));
            assertEq(ledger.unsolicited(address(order), address(paymentToken)), 1);
            assertEq(ledger.unsolicited(address(court), address(stakeToken)), 2);
            assertEq(ledger.unsolicited(address(registry), address(stakeToken)), 3);
            assertEq(paymentToken.balanceOf(address(order)), 1);
            vm.revertToState(state);
            ++_cases;
        }
        assertEq(_cases, 7);
    }

    function _runM3Case(uint256[] memory amounts, Outcome outcome, uint256 position) private {
        WorkOrder order = _createDefaultOrder();
        _donate(paymentToken, address(order), 5);
        _fund(order);
        for (uint256 i; i < position; ++i) {
            _submitAndApprove(order, i);
        }
        uint256 disputeId = _openDispute(order, position);
        _resolveAs(disputeId, outcome);
        _applyRuling(order);

        uint256 remaining;
        for (uint256 i = position + 1; i < amounts.length; ++i) {
            remaining += amounts[i];
        }
        (uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit) =
            _expectedCredits(amounts[position], remaining, FEE_BPS, outcome);
        (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(disputeId);
        (IArbitrationCourt.Ruling expectedRuling, IArbitrationCourt.RulingReason expectedReason) =
            _expectedRuling(outcome);
        assertEq(uint256(ruling), uint256(expectedRuling));
        assertEq(uint256(reason), uint256(expectedReason));
        assertEq(order.claimable(client), clientCredit);
        assertEq(order.claimable(freelancer), freelancerCredit);
        assertEq(order.claimable(feeRecipient), feeCredit);
        assertEq(clientCredit + freelancerCredit + feeCredit, amounts[position] + remaining);
        _claimAll(order);
        assertEq(order.outstandingObligations(), 0);
        assertEq(paymentToken.balanceOf(address(order)), 5);
        _assertOrderLedger(order);
        _assertProtocolEquations();
    }

    function _runTerminalPath(WorkOrder order, TerminalPath path) private {
        if (path == TerminalPath.Completed) {
            for (uint256 i; i < 3; ++i) {
                _submitAndApprove(order, i);
                _assertStep(order);
            }
            assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
            return;
        }
        if (path == TerminalPath.ExpiryFirst || path == TerminalPath.ExpiryLast) {
            uint256 index = path == TerminalPath.ExpiryFirst ? 0 : 2;
            for (uint256 i; i < index; ++i) {
                _submitAndApprove(order, i);
                _assertStep(order);
            }
            vm.warp(order.getMilestone(index).deliveryDeadline);
            ledger.begin();
            vm.prank(client);
            order.reclaimAfterDeliveryExpiry();
            ledger.end(TransferLedger.Transition.OrderClaim, new TransferLedger.Edge[](0));
            _assertStep(order);
            assertEq(order.claimable(client), index == 0 ? 4000 * USDC : 500 * USDC);
        } else {
            _submitAndApprove(order, 0);
            _assertStep(order);
            uint256 disputeId = _openDispute(order, 1);
            _assertStep(order);
            Outcome outcome = path == TerminalPath.FreelancerWins
                ? Outcome.FreelancerMajority
                : path == TerminalPath.ClientWins
                    ? Outcome.ClientMajority
                    : path == TerminalPath.Split ? Outcome.SplitByTie : Outcome.NoPanel;
            _resolveAs(disputeId, outcome);
            _assertStep(order);
            _applyRuling(order);
            _assertStep(order);
            (uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit) =
                _expectedCredits(2500 * USDC, 500 * USDC, FEE_BPS, outcome);
            assertEq(order.claimable(client), clientCredit);
            assertEq(order.claimable(freelancer), freelancerCredit);
            assertEq(order.claimable(feeRecipient), feeCredit);
            _claimCourtCredits(disputeId);
            _assertStep(order);
        }
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Terminated));
        _claimAll(order);
        _assertStep(order);
        assertEq(order.outstandingObligations(), 0);
    }

    function _assertStep(WorkOrder order) private view {
        _assertOrderLedger(order);
        _assertProtocolEquations();
    }

    function _deliveryBoundary() private {
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        uint256 t = order.getMilestone(0).deliveryDeadline;
        for (uint256 o; o < 3; ++o) {
            vm.warp(t + o - 1);
            _expect(o < 1, freelancer, address(order), abi.encodeCall(WorkOrder.submitMilestone, (0)));
            _expect(o >= 1, client, address(order), abi.encodeCall(WorkOrder.reclaimAfterDeliveryExpiry, ()));
        }
    }

    function _reviewBoundary() private {
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        _approveCourtFee(client);
        uint256 t = order.getMilestone(0).reviewDeadline;
        for (uint256 o; o < 3; ++o) {
            vm.warp(t + o - 1);
            _expect(o < 1, client, address(order), abi.encodeCall(WorkOrder.openDispute, (0)));
            _expect(o >= 1, stranger, address(order), abi.encodeCall(WorkOrder.finalizeMilestone, (0)));
            _expect(true, client, address(order), abi.encodeCall(WorkOrder.approveMilestone, (0)));
        }
    }

    function _signatureBoundary() private {
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signApproval(order, 0, 0, deadline);
        for (uint256 o; o < 3; ++o) {
            vm.warp(deadline + o - 1);
            _expect(
                o <= 1,
                stranger,
                address(order),
                abi.encodeCall(WorkOrder.approveMilestoneBySignature, (0, 0, deadline, signature))
            );
        }
    }

    function _panelBoundary() private {
        WorkOrder seeded = _createDefaultOrder();
        _fund(seeded);
        uint256 seededId = _openDispute(seeded, 0);
        uint256 selectionBlock = court.getDispute(seededId).selectionBlock;
        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256("panel boundary"));

        address outsider = makeAddr("pendingClient");
        vm.prank(outsider);
        WorkOrder pending = factory.createWorkOrder(
            _arbitrator(0), paymentToken, _arbitrator(1), FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        _fundAs(pending, outsider);
        vm.prank(_arbitrator(0));
        pending.submitMilestone(0);
        _approveCourtFee(outsider);
        vm.prank(outsider);
        pending.openDispute(0);
        uint256 pendingId = pending.disputeId();
        assertEq(
            uint256(court.getDispute(pendingId).status), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates)
        );

        uint256 t = court.getDispute(seededId).panelDeadline;
        uint256 pendingDeadline = court.getDispute(pendingId).panelDeadline;
        for (uint256 o; o < 3; ++o) {
            vm.warp(t + o - 1);
            _expect(o < 1, stranger, address(court), abi.encodeCall(IArbitrationCourt.drawPanel, (seededId)));
            _expect(o >= 1, stranger, address(court), abi.encodeCall(IArbitrationCourt.resolve, (seededId)));
            vm.warp(pendingDeadline + o - 1);
            _expect(o < 1, stranger, address(court), abi.encodeCall(IArbitrationCourt.retrySnapshot, (pendingId)));
            _expect(o >= 1, stranger, address(court), abi.encodeCall(IArbitrationCourt.resolve, (pendingId)));
        }
    }

    function _seedBlockBoundary() private {
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        uint256 disputeId = _openDispute(order, 0);
        uint256 selectionBlock = court.getDispute(disputeId).selectionBlock;
        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256("seed boundary"));
        for (uint256 o; o < 3; ++o) {
            vm.roll(selectionBlock + o - 1);
            _expect(o == 2, stranger, address(court), abi.encodeCall(IArbitrationCourt.drawPanel, (disputeId)));
        }
    }

    function _commitBoundary() private {
        (uint256 disputeId, address[3] memory panel) = _drawnDispute();
        vm.prank(panel[1]);
        court.commitVote(disputeId, _commitment(disputeId, panel[1], FOR_CLIENT));
        uint256 t = court.getDispute(disputeId).commitDeadline;
        for (uint256 o; o < 3; ++o) {
            vm.warp(t + o - 1);
            _expect(
                o < 1,
                panel[0],
                address(court),
                abi.encodeCall(
                    IArbitrationCourt.commitVote, (disputeId, _commitment(disputeId, panel[0], FOR_FREELANCER))
                )
            );
            _expect(
                o >= 1,
                panel[1],
                address(court),
                abi.encodeCall(IArbitrationCourt.revealVote, (disputeId, FOR_CLIENT, _salt(disputeId, panel[1])))
            );
        }
    }

    function _revealBoundary() private {
        (uint256 disputeId, address[3] memory panel) = _drawnDispute();
        vm.prank(panel[0]);
        court.commitVote(disputeId, _commitment(disputeId, panel[0], FOR_FREELANCER));
        uint256 t = court.getDispute(disputeId).revealDeadline;
        for (uint256 o; o < 3; ++o) {
            vm.warp(t + o - 1);
            _expect(
                o < 1,
                panel[0],
                address(court),
                abi.encodeCall(IArbitrationCourt.revealVote, (disputeId, FOR_FREELANCER, _salt(disputeId, panel[0])))
            );
            _expect(o >= 1, stranger, address(court), abi.encodeCall(IArbitrationCourt.resolve, (disputeId)));
        }
    }

    /// @dev Warming stake backs a candidacy only in snapshots taken at `now >= warmingUntil`.
    function _activationBoundary() private {
        address late = _arbitrator(3);
        _stake(late, SEAT_LOCK);
        uint256 t = registry.accountOf(late).warmingUntil;
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        _approveCourtFee(client);
        for (uint256 o; o < 3; ++o) {
            uint256 state = vm.snapshotState();
            vm.warp(t + o - 1);
            vm.prank(client);
            order.openDispute(0);
            bool included = registry.candidatesOf(order.disputeId()).length == 4;
            assertEq(included, o >= 1);
            vm.revertToState(state);
            ++_cases;
        }
    }

    function _drawnDispute() private returns (uint256 disputeId, address[3] memory panel) {
        WorkOrder order = _createDefaultOrder();
        _fund(order);
        disputeId = _openDispute(order, 0);
        panel = _drawPanel(disputeId);
    }

    function _fundAs(WorkOrder order, address payer) private {
        uint256 total = order.totalAmount();
        paymentToken.mint(payer, total);
        vm.prank(payer);
        paymentToken.approve(address(order), total);
        vm.prank(payer);
        order.fund();
        ledger.trackOrder(address(order));
    }

    /// @dev Runs one call from `caller` against the current state, reverts it, and compares its success with the
    /// tabulated expectation.
    function _expect(bool shouldSucceed, address caller, address target, bytes memory data) private {
        uint256 state = vm.snapshotState();
        vm.prank(caller);
        (bool success,) = target.call(data);
        assertEq(success, shouldSucceed);
        vm.revertToState(state);
        ++_cases;
    }
}

contract TrustWorkIntegrationMatrixSharedTokenTest is TrustWorkIntegrationMatrixTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkIntegrationMatrixSplitTokenTest is TrustWorkIntegrationMatrixTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
