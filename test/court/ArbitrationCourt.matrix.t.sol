// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";
import {MockArbitrationFactory} from "../mocks/MockArbitrationFactory.sol";
import {MockDisputableOrder} from "../mocks/MockDisputableOrder.sol";

/// @dev Enumerated matrices M1 (reveal patterns) and M2 (panel availability) from the S3 test plan.
contract ArbitrationCourtMatrixTest is CourtTestBase {
    uint256 internal constant NO_COMMIT = 0;
    uint256 internal constant COMMIT_NO_REVEAL = 1;
    uint256 internal constant COMMIT_UNREVEALABLE = 2;
    uint256 internal constant REVEAL_FREELANCER = 3;
    uint256 internal constant REVEAL_CLIENT = 4;

    struct Expected {
        uint256 freelancerVotes;
        uint256 clientVotes;
        uint256 validReveals;
        uint256 reward;
        uint256 penalties;
        uint256 recipientCredit;
        IArbitrationCourt.Ruling ruling;
        IArbitrationCourt.RulingReason reason;
    }

    function test_MatrixM1_AllRevealPatterns() public {
        address[] memory arbitrators = _activeArbitrators(3, 400 * SEAT_LOCK);
        uint256 cases;
        uint256 expectedFees;
        uint256 expectedPenalties;
        for (uint256 pattern; pattern < 125; ++pattern) {
            uint256[3] memory behaviors = [pattern % 5, (pattern / 5) % 5, pattern / 25];
            uint256 disputeId = _open();
            address[3] memory panel = _draw(disputeId);
            uint256[3] memory stakeBefore;
            uint256[3] memory creditBefore;
            for (uint256 j; j < 3; ++j) {
                stakeBefore[j] = registry.accountOf(panel[j]).stake;
                creditBefore[j] = court.claimable(panel[j]);
                _act(disputeId, panel[j], behaviors[j], true);
            }
            _toRevealPhase(disputeId);
            for (uint256 j; j < 3; ++j) {
                _act(disputeId, panel[j], behaviors[j], false);
            }
            _toResolution(disputeId);
            uint256 recipientBefore = court.claimable(penaltyRecipient);

            court.resolve(disputeId);

            Expected memory expected = _expectedOutcome(behaviors);
            (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(disputeId);
            assertEq(uint256(ruling), uint256(expected.ruling));
            assertEq(uint256(reason), uint256(expected.reason));
            assertEq(court.claimable(penaltyRecipient) - recipientBefore, expected.recipientCredit);
            assertEq(
                expected.validReveals * expected.reward + expected.recipientCredit, DISPUTE_FEE + expected.penalties
            );
            for (uint256 j; j < 3; ++j) {
                bool valid = behaviors[j] == REVEAL_FREELANCER || behaviors[j] == REVEAL_CLIENT;
                assertEq(court.claimable(panel[j]) - creditBefore[j], valid ? expected.reward : 0);
                assertEq(stakeBefore[j] - registry.accountOf(panel[j]).stake, valid ? 0 : SEAT_LOCK);
                assertEq(registry.accountOf(panel[j]).locked, 0);
                assertEq(registry.accountOf(panel[j]).reserved, 0);
            }
            expectedFees += DISPUTE_FEE;
            expectedPenalties += expected.penalties;
            ++cases;
        }
        assertEq(cases, 125);
        assertEq(court.feesReceived(), expectedFees);
        assertEq(court.penaltiesReceived(), expectedPenalties);
        assertEq(court.pendingFees(), 0);
        assertEq(court.totalClaimable(), expectedFees + expectedPenalties);
        assertEq(registry.penaltiesSent(), expectedPenalties);
        assertEq(arbitrators.length, 3);
        _assertCourtBalanced();
    }

    function test_MatrixM2_PanelAvailability() public {
        uint256 cases;
        for (uint256 candidates; candidates <= 4; ++candidates) {
            for (uint256 drawCalled; drawCalled < 2; ++drawCalled) {
                MockArbitrationFactory caseFactory =
                    new MockArbitrationFactory(token, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
                ArbitrationCourt caseCourt = caseFactory.court();
                ArbitratorRegistry caseRegistry = ArbitratorRegistry(address(caseCourt.registry()));
                MockDisputableOrder caseOrder = caseFactory.createOrder(client, freelancer, feeRecipient);
                for (uint256 i; i < candidates; ++i) {
                    address arbitrator = _arbitrator(100 + i);
                    token.mint(arbitrator, SEAT_LOCK);
                    vm.startPrank(arbitrator);
                    token.approve(address(caseRegistry), SEAT_LOCK);
                    caseRegistry.deposit(SEAT_LOCK);
                    vm.stopPrank();
                }
                vm.warp(block.timestamp + ACTIVATION_DELAY);
                token.mint(client, DISPUTE_FEE);
                vm.prank(client);
                token.approve(address(caseCourt), DISPUTE_FEE);
                uint256 disputeId = caseOrder.openDispute(0);
                IArbitrationCourt.Dispute memory dispute = caseCourt.getDispute(disputeId);

                if (drawCalled == 1 && candidates >= 3) {
                    vm.roll(dispute.selectionBlock + 1);
                    vm.setBlockhash(dispute.selectionBlock, keccak256(abi.encode(candidates)));
                    caseCourt.drawPanel(disputeId);
                    assertEq(
                        uint256(caseCourt.getDispute(disputeId).status), uint256(IArbitrationCourt.DisputeStatus.Voting)
                    );
                    for (uint256 i; i < candidates; ++i) {
                        IArbitratorRegistry.Account memory account = caseRegistry.accountOf(_arbitrator(100 + i));
                        assertEq(account.reserved, 0);
                    }
                } else {
                    if (drawCalled == 1) {
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                ArbitrationCourt.InvalidDisputeStatus.selector,
                                disputeId,
                                IArbitrationCourt.DisputeStatus.AwaitingCandidates
                            )
                        );
                        caseCourt.drawPanel(disputeId);
                    }
                    vm.warp(dispute.panelDeadline);
                    caseCourt.resolve(disputeId);
                    (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) =
                        caseCourt.rulingOf(disputeId);
                    assertEq(uint256(ruling), uint256(IArbitrationCourt.Ruling.FreelancerWins));
                    assertEq(uint256(reason), uint256(IArbitrationCourt.RulingReason.NoPanel));
                    assertEq(caseCourt.claimable(client), DISPUTE_FEE);
                    assertEq(caseCourt.claimable(penaltyRecipient), 0);
                    assertEq(caseCourt.penaltiesReceived(), 0);
                    assertEq(caseRegistry.penaltiesSent(), 0);
                    for (uint256 i; i < candidates; ++i) {
                        IArbitratorRegistry.Account memory account = caseRegistry.accountOf(_arbitrator(100 + i));
                        assertEq(account.reserved, 0);
                        assertEq(account.locked, 0);
                        assertEq(account.stake + account.warming, SEAT_LOCK);
                    }
                }
                ++cases;
            }
        }
        assertEq(cases, 10);
    }

    function _act(uint256 disputeId, address arbitrator, uint256 behavior, bool commitPhase) private {
        if (behavior == NO_COMMIT) return;
        uint8 vote = behavior == COMMIT_UNREVEALABLE ? 3 : behavior == REVEAL_CLIENT ? CLIENT_VOTE : FREELANCER_VOTE;
        if (commitPhase) {
            _commit(disputeId, arbitrator, vote);
            return;
        }
        if (behavior == COMMIT_UNREVEALABLE) {
            vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidVote.selector, uint8(3)));
            _reveal(disputeId, arbitrator, vote);
        } else if (behavior != COMMIT_NO_REVEAL) {
            _reveal(disputeId, arbitrator, vote);
        }
    }

    function _expectedOutcome(uint256[3] memory behaviors) private pure returns (Expected memory expected) {
        for (uint256 j; j < 3; ++j) {
            if (behaviors[j] == REVEAL_FREELANCER) ++expected.freelancerVotes;
            if (behaviors[j] == REVEAL_CLIENT) ++expected.clientVotes;
        }
        expected.validReveals = expected.freelancerVotes + expected.clientVotes;
        expected.penalties = (3 - expected.validReveals) * SEAT_LOCK;
        if (expected.validReveals == 0) {
            expected.recipientCredit = DISPUTE_FEE + expected.penalties;
        } else {
            expected.reward = DISPUTE_FEE / expected.validReveals;
            expected.recipientCredit = DISPUTE_FEE - expected.reward * expected.validReveals + expected.penalties;
        }
        if (expected.freelancerVotes >= 2) {
            (expected.ruling, expected.reason) =
            (IArbitrationCourt.Ruling.FreelancerWins, IArbitrationCourt.RulingReason.Majority);
        } else if (expected.clientVotes >= 2) {
            (expected.ruling, expected.reason) =
            (IArbitrationCourt.Ruling.ClientWins, IArbitrationCourt.RulingReason.Majority);
        } else {
            (expected.ruling, expected.reason) =
            (IArbitrationCourt.Ruling.Split, IArbitrationCourt.RulingReason.NoDecision);
        }
    }
}
