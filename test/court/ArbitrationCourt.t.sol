// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";
import {BlocklistToken} from "../mocks/BlocklistToken.sol";
import {FeeOnTransferToken} from "../mocks/FeeOnTransferToken.sol";
import {MockArbitrationFactory} from "../mocks/MockArbitrationFactory.sol";
import {MockDisputableOrder} from "../mocks/MockDisputableOrder.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";

contract ArbitrationCourtTest is CourtTestBase {
    event DisputeOpened(uint256 indexed disputeId, address indexed order, uint256 milestoneIndex, uint256 candidates);
    event CandidatesPending(uint256 indexed disputeId, uint256 eligibleCount);
    event SelectionArmed(uint256 indexed disputeId, uint256 selectionBlock);
    event PanelDrawn(uint256 indexed disputeId, address[3] panel, uint256 commitDeadline, uint256 revealDeadline);
    event VoteCommitted(uint256 indexed disputeId, address indexed arbitrator);
    event VoteRevealed(uint256 indexed disputeId, address indexed arbitrator, IArbitrationCourt.Vote vote);
    event DisputeResolved(
        uint256 indexed disputeId,
        IArbitrationCourt.Ruling ruling,
        IArbitrationCourt.RulingReason reason,
        uint256 validReveals,
        uint256 rewardPerReveal,
        uint256 penalties,
        uint256 feeRefund
    );
    event RewardClaimed(address indexed account, uint256 amount);

    function test_Constructor_WiresFactoryRegistryAndTerms() public view {
        assertEq(court.factory(), address(factory));
        assertEq(registry.court(), address(court));
        assertEq(address(court.stakeToken()), address(token));
        assertEq(address(registry.stakeToken()), address(token));
        assertEq(court.disputeFee(), DISPUTE_FEE);
        assertEq(court.seatLock(), SEAT_LOCK);
        assertEq(registry.seatLock(), SEAT_LOCK);
        assertEq(court.penaltyRecipient(), penaltyRecipient);
        assertEq(registry.penaltyRecipient(), penaltyRecipient);
        assertEq(court.disputeCount(), 0);
    }

    function test_RevertWhen_ConstructorInputsInvalid() public {
        vm.expectRevert(ArbitrationCourt.ZeroAddress.selector);
        new ArbitrationCourt(IERC20(address(0)), DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        vm.expectRevert(ArbitrationCourt.ZeroAddress.selector);
        new ArbitrationCourt(token, DISPUTE_FEE, SEAT_LOCK, address(0));
        address eoa = makeAddr("notAToken");
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.TokenHasNoCode.selector, eoa));
        new ArbitrationCourt(IERC20(eoa), DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        vm.expectRevert(ArbitrationCourt.ZeroDisputeFee.selector);
        new ArbitrationCourt(token, 0, SEAT_LOCK, penaltyRecipient);
        vm.expectRevert(ArbitrationCourt.ZeroSeatLock.selector);
        new ArbitrationCourt(token, DISPUTE_FEE, 0, penaltyRecipient);
    }

    function test_Constructor_AcceptsDeployingFactoryAsPenaltyRecipient() public {
        ArbitrationCourt factoryRecipientCourt = new ArbitrationCourt(token, DISPUTE_FEE, SEAT_LOCK, address(this));
        assertEq(factoryRecipientCourt.factory(), address(this));
        assertEq(factoryRecipientCourt.penaltyRecipient(), address(this));
        assertEq(factoryRecipientCourt.registry().penaltyRecipient(), address(this));
        assertEq(factoryRecipientCourt.registry().court(), address(factoryRecipientCourt));
    }

    function test_RevertWhen_RegistryRestrictionsViolated() public {
        address predictedCourt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.PenaltyRecipientIsProtocol.selector, predictedCourt));
        new ArbitrationCourt(token, DISPUTE_FEE, SEAT_LOCK, predictedCourt);

        address nextCourt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedRegistry = vm.computeCreateAddress(nextCourt, 1);
        vm.expectRevert(
            abi.encodeWithSelector(ArbitratorRegistry.PenaltyRecipientIsProtocol.selector, predictedRegistry)
        );
        new ArbitrationCourt(token, DISPUTE_FEE, SEAT_LOCK, predictedRegistry);

        uint256 tooLarge = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooLarge));
        new ArbitrationCourt(token, DISPUTE_FEE, tooLarge, penaltyRecipient);
    }

    function test_RevertWhen_OpenedByUnknownOrder() public {
        MockDisputableOrder forged = new MockDisputableOrder(court, client, freelancer, feeRecipient);
        token.mint(client, DISPUTE_FEE);
        vm.prank(client);
        token.approve(address(court), DISPUTE_FEE);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.UnknownOrder.selector, address(forged)));
        forged.openDispute(0);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.UnknownOrder.selector, address(this)));
        court.openDispute(0);
        assertEq(court.disputeCount(), 0);
    }

    function test_OpenDispute_PullsExactFee() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();

        assertEq(disputeId, 1);
        assertEq(token.balanceOf(address(court)), DISPUTE_FEE);
        assertEq(token.balanceOf(client), 0);
        assertEq(court.pendingFees(), DISPUTE_FEE);
        assertEq(court.feesReceived(), DISPUTE_FEE);
        _assertCourtBalanced();
    }

    function test_RevertWhen_FeeCannotBePulled() public {
        _activeArbitrators(3, SEAT_LOCK);
        token.mint(client, DISPUTE_FEE);
        vm.prank(client);
        token.approve(address(court), DISPUTE_FEE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(court), DISPUTE_FEE - 1, DISPUTE_FEE
            )
        );
        order.openDispute(0);

        vm.prank(client);
        token.approve(address(court), DISPUTE_FEE);
        vm.prank(client);
        assertTrue(token.transfer(freelancer, 1));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, client, DISPUTE_FEE - 1, DISPUTE_FEE)
        );
        order.openDispute(0);

        assertEq(court.disputeCount(), 0);
        assertEq(court.pendingFees(), 0);
        assertEq(court.feesReceived(), 0);
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.None));
        assertEq(registry.accountOf(_arbitrator(0)).reserved, 0);
    }

    function test_RevertWhen_FeeTokenTakesTransferFee() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        MockArbitrationFactory feeFactory =
            new MockArbitrationFactory(feeToken, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        MockDisputableOrder feeOrder = feeFactory.createOrder(client, freelancer, feeRecipient);
        address feeCourt = address(feeFactory.court());
        feeToken.mint(client, DISPUTE_FEE);
        vm.prank(client);
        feeToken.approve(feeCourt, DISPUTE_FEE);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationCourt.DepositMismatch.selector, DISPUTE_FEE, DISPUTE_FEE - DISPUTE_FEE / 100
            )
        );
        feeOrder.openDispute(0);
        assertEq(feeFactory.court().disputeCount(), 0);
    }

    function test_OpenDispute_StoresSnapshotAndArmsSelection() public {
        address[] memory arbitrators = _activeArbitrators(4, SEAT_LOCK);
        _deposit(client, SEAT_LOCK);
        _deposit(feeRecipient, SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        token.mint(client, DISPUTE_FEE);
        vm.prank(client);
        token.approve(address(court), DISPUTE_FEE);

        vm.expectEmit(address(court));
        emit SelectionArmed(1, block.number + 10);
        vm.expectEmit(address(court));
        emit DisputeOpened(1, address(order), 0, 4);
        order.openDispute(0);

        IArbitrationCourt.Dispute memory dispute = court.getDispute(1);
        assertEq(dispute.order, address(order));
        assertEq(dispute.client, client);
        assertEq(dispute.freelancer, freelancer);
        assertEq(dispute.feeRecipient, feeRecipient);
        assertEq(uint256(dispute.status), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
        assertEq(dispute.openedAt, block.timestamp);
        assertEq(dispute.panelDeadline, block.timestamp + 3 days);
        assertEq(dispute.selectionBlock, block.number + 10);
        IArbitratorRegistry.Candidate[] memory candidates = registry.candidatesOf(1);
        assertEq(candidates.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(candidates[i].arbitrator, arbitrators[i]);
            assertEq(registry.accountOf(arbitrators[i]).reserved, SEAT_LOCK);
        }
        assertEq(registry.accountOf(client).reserved, 0);
        assertEq(registry.accountOf(feeRecipient).reserved, 0);
    }

    function test_OpenDispute_WithTooFewCandidatesAwaitsCandidates() public {
        _activeArbitrators(2, SEAT_LOCK);
        token.mint(client, DISPUTE_FEE);
        vm.prank(client);
        token.approve(address(court), DISPUTE_FEE);

        vm.expectEmit(address(court));
        emit CandidatesPending(1, 2);
        order.openDispute(0);

        IArbitrationCourt.Dispute memory dispute = court.getDispute(1);
        assertEq(uint256(dispute.status), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates));
        assertEq(dispute.selectionBlock, 0);
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.None));
        assertEq(registry.accountOf(_arbitrator(0)).reserved, 0);
        assertEq(court.pendingFees(), DISPUTE_FEE);
    }

    function test_RetrySnapshot_SucceedsOnceCandidatesExist() public {
        _activeArbitrators(2, SEAT_LOCK);
        uint256 disputeId = _open();
        address third = _arbitrator(2);
        _deposit(third, SEAT_LOCK);

        vm.expectEmit(address(court));
        emit CandidatesPending(disputeId, 2);
        court.retrySnapshot(disputeId);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates));

        vm.warp(block.timestamp + ACTIVATION_DELAY);
        vm.expectEmit(address(court));
        emit SelectionArmed(disputeId, block.number + 10);
        court.retrySnapshot(disputeId);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
        assertEq(registry.candidatesOf(disputeId).length, 3);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationCourt.InvalidDisputeStatus.selector, disputeId, IArbitrationCourt.DisputeStatus.AwaitingSeed
            )
        );
        court.retrySnapshot(disputeId);
        assertEq(registry.accountOf(third).reserved, SEAT_LOCK);
    }

    function test_RetrySnapshot_PanelDeadlineBoundary() public {
        _activeArbitrators(2, SEAT_LOCK);
        uint256 disputeId = _open();
        uint256 deadline = court.getDispute(disputeId).panelDeadline;
        _deposit(_arbitrator(2), SEAT_LOCK);

        vm.warp(deadline - 1);
        court.retrySnapshot(disputeId);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));

        uint256 second = _open();
        vm.warp(court.getDispute(second).panelDeadline);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationCourt.PanelPeriodElapsed.selector, second, court.getDispute(second).panelDeadline
            )
        );
        court.retrySnapshot(second);
    }

    function test_DrawPanel_SelectionBlockBoundary() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        uint256 selectionBlock = court.getDispute(disputeId).selectionBlock;

        vm.roll(selectionBlock);
        vm.expectRevert(
            abi.encodeWithSelector(ArbitrationCourt.SelectionBlockNotReached.selector, disputeId, selectionBlock)
        );
        court.drawPanel(disputeId);

        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256("hash"));
        court.drawPanel(disputeId);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.Voting));
    }

    function test_DrawPanel_ExpiredBlockhashRearmsSameSnapshot() public {
        _activeArbitrators(5, SEAT_LOCK);
        uint256 disputeId = _open();
        IArbitratorRegistry.Candidate[] memory stored = registry.candidatesOf(disputeId);
        uint256 selectionBlock = court.getDispute(disputeId).selectionBlock;

        vm.roll(selectionBlock + 256);
        assertTrue(blockhash(selectionBlock) != bytes32(0));
        vm.roll(selectionBlock + 257);
        vm.expectEmit(address(court));
        emit SelectionArmed(disputeId, block.number + 10);
        court.drawPanel(disputeId);

        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
        assertEq(court.getDispute(disputeId).selectionBlock, selectionBlock + 267);
        IArbitratorRegistry.Candidate[] memory afterRearm = registry.candidatesOf(disputeId);
        assertEq(afterRearm.length, stored.length);
        for (uint256 i; i < stored.length; ++i) {
            assertEq(afterRearm[i].arbitrator, stored[i].arbitrator);
            assertEq(uint256(afterRearm[i].state), uint256(IArbitratorRegistry.CandidateState.Reserved));
            assertEq(registry.accountOf(stored[i].arbitrator).reserved, SEAT_LOCK);
        }

        _draw(disputeId);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.Voting));
    }

    function test_DrawPanel_IgnoresRegistryChangesAfterSnapshot() public {
        address[] memory arbitrators = _activeArbitrators(6, 3 * SEAT_LOCK);
        address otherClient = makeAddr("otherClient");
        uint256 earlier = _openFor(factory.createOrder(otherClient, freelancer, feeRecipient), otherClient);
        _draw(earlier);
        vm.warp(court.getDispute(earlier).revealDeadline - 1 hours);
        uint256 disputeId = _open();
        IArbitratorRegistry.Candidate[] memory stored = registry.candidatesOf(disputeId);

        vm.warp(court.getDispute(earlier).revealDeadline);
        court.resolve(earlier);
        assertEq(registry.penaltiesSent(), 3 * SEAT_LOCK);
        _deposit(_arbitrator(10), 5 * SEAT_LOCK);
        uint256 free = registry.freeStake(arbitrators[0]);
        assertGt(free, 0);
        vm.prank(arbitrators[0]);
        registry.withdraw(free);

        bytes32 blockHash = keccak256("seed block");
        _setSeedBlock(disputeId, blockHash);
        court.drawPanel(disputeId);

        IArbitratorRegistry.Candidate[] memory afterDraw = registry.candidatesOf(disputeId);
        assertEq(afterDraw.length, stored.length);
        bytes32 seed = keccak256(abi.encode(blockHash, block.chainid, address(court), disputeId));
        uint256[3] memory expected = _expectedSelection(seed, stored.length);
        IArbitrationCourt.Seat[3] memory seats = court.getSeats(disputeId);
        for (uint256 j; j < 3; ++j) {
            assertEq(seats[j].candidateIndex, expected[j]);
            assertEq(seats[j].arbitrator, stored[expected[j]].arbitrator);
            assertEq(afterDraw[expected[j]].arbitrator, stored[expected[j]].arbitrator);
        }
    }

    function test_DrawPanel_PanelDeadlineBoundaryAndNoPanelResolution() public {
        _activeArbitrators(3, 2 * SEAT_LOCK);
        uint256 seeded = _open();
        _deposit(_arbitrator(7), SEAT_LOCK);
        MockDisputableOrder waitingOrder = factory.createOrder(makeAddr("client2"), freelancer, feeRecipient);
        vm.prank(_arbitrator(0));
        registry.withdraw(SEAT_LOCK);
        vm.prank(_arbitrator(1));
        registry.withdraw(SEAT_LOCK);
        uint256 waiting = _openFor(waitingOrder, makeAddr("client2"));
        assertEq(uint256(_status(waiting)), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates));

        uint256 deadline = court.getDispute(seeded).panelDeadline;
        _setSeedBlock(seeded, keccak256("late"));
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.PanelPeriodActive.selector, seeded, deadline));
        court.resolve(seeded);

        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.PanelPeriodElapsed.selector, seeded, deadline));
        court.drawPanel(seeded);

        vm.expectEmit(address(court));
        emit DisputeResolved(
            seeded,
            IArbitrationCourt.Ruling.FreelancerWins,
            IArbitrationCourt.RulingReason.NoPanel,
            0,
            0,
            0,
            DISPUTE_FEE
        );
        court.resolve(seeded);
        _assertNoPanel(seeded, client);

        vm.warp(court.getDispute(waiting).panelDeadline);
        court.resolve(waiting);
        _assertNoPanel(waiting, makeAddr("client2"));
        assertEq(court.claimable(client), DISPUTE_FEE);
        _assertCourtBalanced();
    }

    function test_DrawPanel_AllowedOneSecondBeforePanelDeadline() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        _setSeedBlock(disputeId, keccak256("just in time"));
        vm.warp(court.getDispute(disputeId).panelDeadline - 1);

        court.drawPanel(disputeId);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.Voting));
    }

    function test_NoPanel_ReleasesReservationsWithoutPenalties() public {
        address[] memory arbitrators = _activeArbitrators(5, SEAT_LOCK);
        uint256 disputeId = _open();
        vm.warp(court.getDispute(disputeId).panelDeadline);
        uint256 balanceBefore = token.balanceOf(address(court));

        court.resolve(disputeId);

        for (uint256 i; i < 5; ++i) {
            assertEq(registry.accountOf(arbitrators[i]).reserved, 0);
            assertEq(registry.accountOf(arbitrators[i]).stake, SEAT_LOCK);
        }
        assertEq(uint256(registry.snapshotState(disputeId)), uint256(IArbitratorRegistry.SnapshotState.Released));
        assertEq(court.claimable(client), DISPUTE_FEE);
        assertEq(court.claimable(penaltyRecipient), 0);
        assertEq(registry.penaltiesSent(), 0);
        assertEq(token.balanceOf(address(court)), balanceBefore);
        assertEq(registry.totalStaked(), 5 * SEAT_LOCK);
    }

    function test_RevertWhen_PanelDrawnTwice() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        _draw(disputeId);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationCourt.InvalidDisputeStatus.selector, disputeId, IArbitrationCourt.DisputeStatus.Voting
            )
        );
        court.drawPanel(disputeId);
    }

    function test_RevertWhen_UnknownDispute() public {
        bytes memory unknown = abi.encodeWithSelector(ArbitrationCourt.UnknownDispute.selector, 7);
        vm.expectRevert(unknown);
        court.retrySnapshot(7);
        vm.expectRevert(unknown);
        court.drawPanel(7);
        vm.expectRevert(unknown);
        court.commitVote(7, bytes32(uint256(1)));
        vm.expectRevert(unknown);
        court.revealVote(7, FREELANCER_VOTE, bytes32(0));
        vm.expectRevert(unknown);
        court.resolve(7);
        (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(7);
        assertEq(uint256(ruling), uint256(IArbitrationCourt.Ruling.None));
        assertEq(uint256(reason), uint256(IArbitrationCourt.RulingReason.None));
    }

    function test_RevertWhen_CommitInvalid() public {
        _activeArbitrators(4, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        address outsider = _nonPanelist(panel, 4);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NotPanelist.selector, disputeId, outsider));
        vm.prank(outsider);
        court.commitVote(disputeId, bytes32(uint256(1)));

        vm.expectRevert(ArbitrationCourt.ZeroCommitment.selector);
        vm.prank(panel[0]);
        court.commitVote(disputeId, bytes32(0));

        vm.expectEmit(address(court));
        emit VoteCommitted(disputeId, panel[0]);
        _commit(disputeId, panel[0], FREELANCER_VOTE);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.AlreadyCommitted.selector, disputeId, panel[0]));
        vm.prank(panel[0]);
        court.commitVote(disputeId, bytes32(uint256(2)));
    }

    function test_Commit_DeadlineBoundary() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        uint256 commitDeadline = court.getDispute(disputeId).commitDeadline;

        vm.warp(commitDeadline - 1);
        _commit(disputeId, panel[0], FREELANCER_VOTE);

        vm.warp(commitDeadline);
        vm.expectRevert(
            abi.encodeWithSelector(ArbitrationCourt.CommitPeriodElapsed.selector, disputeId, commitDeadline)
        );
        vm.prank(panel[1]);
        court.commitVote(disputeId, bytes32(uint256(1)));
    }

    function test_Reveal_PhaseBoundaries() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        for (uint256 j; j < 3; ++j) {
            _commit(disputeId, panel[j], FREELANCER_VOTE);
        }
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        bytes memory closed = abi.encodeWithSelector(
            ArbitrationCourt.NotRevealPeriod.selector, disputeId, dispute.commitDeadline, dispute.revealDeadline
        );

        vm.warp(dispute.commitDeadline - 1);
        vm.expectRevert(closed);
        _reveal(disputeId, panel[0], FREELANCER_VOTE);

        vm.warp(dispute.commitDeadline);
        vm.expectEmit(address(court));
        emit VoteRevealed(disputeId, panel[0], IArbitrationCourt.Vote.Freelancer);
        _reveal(disputeId, panel[0], FREELANCER_VOTE);

        vm.warp(dispute.revealDeadline - 1);
        _reveal(disputeId, panel[1], FREELANCER_VOTE);

        vm.warp(dispute.revealDeadline);
        vm.expectRevert(closed);
        _reveal(disputeId, panel[2], FREELANCER_VOTE);
    }

    function test_RevertWhen_RevealDoesNotMatchThenRetrySucceeds() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        address arbitrator = panel[0];
        bytes32 salt = _salt(arbitrator, disputeId);
        bytes32[5] memory commitments = [
            _expectedCommitment(block.chainid, address(court), disputeId, arbitrator, CLIENT_VOTE, salt),
            _expectedCommitment(block.chainid, address(court), disputeId, panel[1], FREELANCER_VOTE, salt),
            _expectedCommitment(block.chainid, address(court), disputeId + 1, arbitrator, FREELANCER_VOTE, salt),
            _expectedCommitment(block.chainid, address(factory), disputeId, arbitrator, FREELANCER_VOTE, salt),
            _expectedCommitment(block.chainid + 1, address(court), disputeId, arbitrator, FREELANCER_VOTE, salt)
        ];
        _commit(disputeId, panel[1], CLIENT_VOTE);
        _commit(disputeId, panel[2], CLIENT_VOTE);
        vm.prank(arbitrator);
        court.commitVote(disputeId, commitments[0]);
        _toRevealPhase(disputeId);

        bytes memory invalid = abi.encodeWithSelector(ArbitrationCourt.InvalidReveal.selector, disputeId, arbitrator);
        vm.expectRevert(invalid);
        vm.prank(arbitrator);
        court.revealVote(disputeId, FREELANCER_VOTE, salt);
        vm.expectRevert(invalid);
        vm.prank(arbitrator);
        court.revealVote(disputeId, CLIENT_VOTE, keccak256("wrong salt"));
        assertEq(uint256(court.getSeats(disputeId)[0].vote), uint256(IArbitrationCourt.Vote.None));

        for (uint256 i = 1; i < commitments.length; ++i) {
            assertTrue(commitments[i] != commitments[0]);
        }
        vm.prank(arbitrator);
        court.revealVote(disputeId, CLIENT_VOTE, salt);
        assertEq(uint256(court.getSeats(disputeId)[0].vote), uint256(IArbitrationCourt.Vote.Client));
    }

    function test_RevertWhen_CommitmentFromAnotherDomainIsRevealed() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        address arbitrator = panel[0];
        bytes32 salt = _salt(arbitrator, disputeId);
        bytes32 foreign =
            _expectedCommitment(block.chainid + 1, address(court), disputeId, arbitrator, CLIENT_VOTE, salt);
        vm.prank(arbitrator);
        court.commitVote(disputeId, foreign);
        bytes32 copied = _expectedCommitment(block.chainid, address(court), disputeId, panel[2], CLIENT_VOTE, salt);
        vm.prank(panel[1]);
        court.commitVote(disputeId, copied);
        _toRevealPhase(disputeId);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidReveal.selector, disputeId, arbitrator));
        vm.prank(arbitrator);
        court.revealVote(disputeId, CLIENT_VOTE, salt);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidReveal.selector, disputeId, panel[1]));
        vm.prank(panel[1]);
        court.revealVote(disputeId, CLIENT_VOTE, salt);
    }

    function test_RevertWhen_CommitmentBoundToAnotherCourtIsRevealed() public {
        MockArbitrationFactory otherFactory =
            new MockArbitrationFactory(token, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        address otherCourt = address(otherFactory.court());
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        address arbitrator = panel[0];
        bytes32 salt = _salt(arbitrator, disputeId);
        bytes32 foreign = _expectedCommitment(block.chainid, otherCourt, disputeId, arbitrator, CLIENT_VOTE, salt);
        vm.prank(arbitrator);
        court.commitVote(disputeId, foreign);
        _toRevealPhase(disputeId);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidReveal.selector, disputeId, arbitrator));
        vm.prank(arbitrator);
        court.revealVote(disputeId, CLIENT_VOTE, salt);

        IArbitrationCourt.Seat memory seat = court.getSeats(disputeId)[0];
        assertEq(seat.commitment, foreign);
        assertEq(uint256(seat.vote), uint256(IArbitrationCourt.Vote.None));
    }

    function test_RevertWhen_CommitmentBoundToAnotherDisputeIsRevealed() public {
        _activeArbitrators(3, 2 * SEAT_LOCK);
        uint256 disputeId = _open();
        uint256 otherId =
            _openFor(factory.createOrder(makeAddr("otherClient"), freelancer, feeRecipient), makeAddr("otherClient"));
        address[3] memory panel = _draw(disputeId);
        address arbitrator = panel[0];
        bytes32 salt = _salt(arbitrator, disputeId);
        bytes32 foreign = _expectedCommitment(block.chainid, address(court), otherId, arbitrator, CLIENT_VOTE, salt);
        vm.prank(arbitrator);
        court.commitVote(disputeId, foreign);
        _toRevealPhase(disputeId);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidReveal.selector, disputeId, arbitrator));
        vm.prank(arbitrator);
        court.revealVote(disputeId, CLIENT_VOTE, salt);

        IArbitrationCourt.Seat memory seat = court.getSeats(disputeId)[0];
        assertEq(seat.commitment, foreign);
        assertEq(uint256(seat.vote), uint256(IArbitrationCourt.Vote.None));
        assertEq(uint256(_status(otherId)), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
    }

    function test_RevealVote_RejectsRawValuesOutsideVoteRange() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        _commit(disputeId, panel[0], 3);
        _commit(disputeId, panel[1], FREELANCER_VOTE);
        _commit(disputeId, panel[2], FREELANCER_VOTE);
        _toRevealPhase(disputeId);

        uint8[3] memory invalidValues = [uint8(0), 3, 255];
        for (uint256 i; i < invalidValues.length; ++i) {
            assertEq(
                court.voteCommitment(disputeId, panel[0], invalidValues[i], bytes32(i)),
                _expectedCommitment(block.chainid, address(court), disputeId, panel[0], invalidValues[i], bytes32(i))
            );
            vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidVote.selector, invalidValues[i]));
            _reveal(disputeId, panel[0], invalidValues[i]);
        }
        _reveal(disputeId, panel[1], FREELANCER_VOTE);
        _reveal(disputeId, panel[2], FREELANCER_VOTE);
        _toResolution(disputeId);

        court.resolve(disputeId);
        assertEq(registry.accountOf(panel[0]).stake, 0);
        assertEq(court.claimable(penaltyRecipient), SEAT_LOCK);
        assertEq(court.claimable(panel[1]), DISPUTE_FEE / 2);
    }

    function test_RevertWhen_RevealRepeatedOrUncommitted() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        _commit(disputeId, panel[0], CLIENT_VOTE);
        _toRevealPhase(disputeId);
        _reveal(disputeId, panel[0], CLIENT_VOTE);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.AlreadyRevealed.selector, disputeId, panel[0]));
        _reveal(disputeId, panel[0], CLIENT_VOTE);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NotCommitted.selector, disputeId, panel[1]));
        _reveal(disputeId, panel[1], CLIENT_VOTE);
        address outsider = makeAddr("outsider");
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NotPanelist.selector, disputeId, outsider));
        vm.prank(outsider);
        court.revealVote(disputeId, CLIENT_VOTE, bytes32(0));
    }

    function test_VoteCommitment_MatchesIndependentEncoding() public view {
        address[2] memory arbitrators = [address(0xA11CE), address(0xB0B)];
        for (uint256 i; i < 2; ++i) {
            for (uint8 vote; vote < 4; ++vote) {
                bytes32 salt = keccak256(abi.encode(i, vote));
                assertEq(
                    court.voteCommitment(i + 1, arbitrators[i], vote, salt),
                    _expectedCommitment(block.chainid, address(court), i + 1, arbitrators[i], vote, salt)
                );
            }
        }
        assertEq(court.VOTE_TAG(), keccak256("TrustWork.ArbitrationVote.v1"));
    }

    function test_Resolve_RevealDeadlineBoundaryAndNoEarlyResolution() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        for (uint256 j; j < 3; ++j) {
            _commit(disputeId, panel[j], CLIENT_VOTE);
        }
        _toRevealPhase(disputeId);
        _reveal(disputeId, panel[0], CLIENT_VOTE);
        _reveal(disputeId, panel[1], CLIENT_VOTE);
        uint256 revealDeadline = court.getDispute(disputeId).revealDeadline;

        vm.warp(revealDeadline - 1);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.RevealPeriodActive.selector, disputeId, revealDeadline));
        court.resolve(disputeId);

        vm.warp(revealDeadline);
        court.resolve(disputeId);
        (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(disputeId);
        assertEq(uint256(ruling), uint256(IArbitrationCourt.Ruling.ClientWins));
        assertEq(uint256(reason), uint256(IArbitrationCourt.RulingReason.Majority));

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationCourt.InvalidDisputeStatus.selector, disputeId, IArbitrationCourt.DisputeStatus.Resolved
            )
        );
        court.resolve(disputeId);
        (IArbitrationCourt.Ruling rulingAfter,) = court.rulingOf(disputeId);
        assertEq(uint256(rulingAfter), uint256(IArbitrationCourt.Ruling.ClientWins));
    }

    function test_Resolve_WorkedExampleRows() public {
        uint8 none = 0;
        uint8[3][5] memory rows = [
            [FREELANCER_VOTE, FREELANCER_VOTE, CLIENT_VOTE],
            [FREELANCER_VOTE, FREELANCER_VOTE, none],
            [FREELANCER_VOTE, CLIENT_VOTE, none],
            [CLIENT_VOTE, none, none],
            [none, none, none]
        ];
        uint256[5] memory rewards = [uint256(6_666_666), 10_000_000, 10_000_000, 20_000_000, 0];
        uint256[5] memory recipientCredits = [uint256(2), 100 * USDC, 100 * USDC, 200 * USDC, 20 * USDC + 300 * USDC];
        IArbitrationCourt.Ruling[5] memory rulings = [
            IArbitrationCourt.Ruling.FreelancerWins,
            IArbitrationCourt.Ruling.FreelancerWins,
            IArbitrationCourt.Ruling.Split,
            IArbitrationCourt.Ruling.Split,
            IArbitrationCourt.Ruling.Split
        ];
        _activeArbitrators(3, 10 * SEAT_LOCK);

        for (uint256 row; row < rows.length; ++row) {
            uint256 recipientBefore = court.claimable(penaltyRecipient);
            uint256 disputeId = _open();
            address[3] memory panel = _draw(disputeId);
            uint256[3] memory rewardBefore;
            for (uint256 j; j < 3; ++j) {
                rewardBefore[j] = court.claimable(panel[j]);
                if (rows[row][j] != none) _commit(disputeId, panel[j], rows[row][j]);
            }
            _toRevealPhase(disputeId);
            for (uint256 j; j < 3; ++j) {
                if (rows[row][j] != none) _reveal(disputeId, panel[j], rows[row][j]);
            }
            _toResolution(disputeId);
            court.resolve(disputeId);

            (IArbitrationCourt.Ruling ruling,) = court.rulingOf(disputeId);
            assertEq(uint256(ruling), uint256(rulings[row]));
            assertEq(court.claimable(penaltyRecipient) - recipientBefore, recipientCredits[row]);
            for (uint256 j; j < 3; ++j) {
                uint256 expectedReward = rows[row][j] == none ? 0 : rewards[row];
                assertEq(court.claimable(panel[j]) - rewardBefore[j], expectedReward);
            }
            _assertCourtBalanced();
        }

        uint256 noPanel = _openAfterWithdrawingAll();
        vm.warp(court.getDispute(noPanel).panelDeadline);
        uint256 recipientBeforeNoPanel = court.claimable(penaltyRecipient);
        court.resolve(noPanel);
        assertEq(court.claimable(penaltyRecipient), recipientBeforeNoPanel);
        assertEq(court.claimable(client), DISPUTE_FEE);
        _assertCourtBalanced();
    }

    function test_FeeShareGrowsWhenAnotherSeatFaults() public {
        _activeArbitrators(3, 3 * SEAT_LOCK);
        uint256 allReveal = _resolveWithPattern([FREELANCER_VOTE, FREELANCER_VOTE, FREELANCER_VOTE]);
        address[3] memory panel = _panelOf(allReveal);
        assertEq(court.claimable(panel[0]), 6_666_666);

        uint256 claimedBefore = court.claimable(panel[1]);
        uint256 oneFaulty = _resolveWithPattern([FREELANCER_VOTE, FREELANCER_VOTE, 0]);
        address[3] memory second = _panelOf(oneFaulty);
        uint256 increase = court.claimable(second[0]) - (second[0] == panel[1] ? claimedBefore : 6_666_666);
        assertEq(increase, 10_000_000);
    }

    function test_ClaimReward_PaysAccountAndIsolatesFailures() public {
        BlocklistToken blockToken = new BlocklistToken();
        MockArbitrationFactory blockFactory =
            new MockArbitrationFactory(blockToken, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        ArbitrationCourt blockCourt = blockFactory.court();
        ArbitratorRegistry blockRegistry = ArbitratorRegistry(address(blockCourt.registry()));
        MockDisputableOrder blockOrder = blockFactory.createOrder(client, freelancer, feeRecipient);
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitrator(i);
            blockToken.mint(arbitrator, SEAT_LOCK);
            vm.startPrank(arbitrator);
            blockToken.approve(address(blockRegistry), SEAT_LOCK);
            blockRegistry.deposit(SEAT_LOCK);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        blockToken.mint(client, DISPUTE_FEE);
        vm.prank(client);
        blockToken.approve(address(blockCourt), DISPUTE_FEE);
        uint256 disputeId = blockOrder.openDispute(0);
        uint256 selectionBlock = blockCourt.getDispute(disputeId).selectionBlock;
        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256("block"));
        blockCourt.drawPanel(disputeId);
        IArbitrationCourt.Seat[3] memory seats = blockCourt.getSeats(disputeId);
        for (uint256 j; j < 2; ++j) {
            bytes32 salt = _salt(seats[j].arbitrator, disputeId);
            vm.prank(seats[j].arbitrator);
            blockCourt.commitVote(
                disputeId,
                _expectedCommitment(
                    block.chainid, address(blockCourt), disputeId, seats[j].arbitrator, FREELANCER_VOTE, salt
                )
            );
        }
        vm.warp(blockCourt.getDispute(disputeId).commitDeadline);
        for (uint256 j; j < 2; ++j) {
            vm.prank(seats[j].arbitrator);
            blockCourt.revealVote(disputeId, FREELANCER_VOTE, _salt(seats[j].arbitrator, disputeId));
        }
        vm.warp(blockCourt.getDispute(disputeId).revealDeadline);
        blockCourt.resolve(disputeId);
        blockToken.setBlocked(seats[0].arbitrator, true);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, seats[0].arbitrator));
        blockCourt.claimReward(seats[0].arbitrator);
        assertEq(blockCourt.claimable(seats[0].arbitrator), DISPUTE_FEE / 2);

        vm.expectEmit(address(blockCourt));
        emit RewardClaimed(seats[1].arbitrator, DISPUTE_FEE / 2);
        vm.prank(stranger());
        blockCourt.claimReward(seats[1].arbitrator);
        blockCourt.claimReward(penaltyRecipient);
        assertEq(blockToken.balanceOf(seats[1].arbitrator), DISPUTE_FEE / 2);
        assertEq(blockToken.balanceOf(penaltyRecipient), SEAT_LOCK);
        assertEq(blockToken.balanceOf(stranger()), 0);
        (IArbitrationCourt.Ruling ruling,) = blockCourt.rulingOf(disputeId);
        assertEq(uint256(ruling), uint256(IArbitrationCourt.Ruling.FreelancerWins));

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NothingToClaim.selector, seats[1].arbitrator));
        blockCourt.claimReward(seats[1].arbitrator);

        blockToken.setBlocked(seats[0].arbitrator, false);
        blockCourt.claimReward(seats[0].arbitrator);
        assertEq(blockCourt.totalClaimable(), 0);
        assertEq(blockCourt.claimsPaid(), DISPUTE_FEE + SEAT_LOCK);
    }

    function test_RevertWhen_PenaltyTransferFailsResolutionIsAtomic() public {
        BlocklistToken blockToken = new BlocklistToken();
        MockArbitrationFactory blockFactory =
            new MockArbitrationFactory(blockToken, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        ArbitrationCourt blockCourt = blockFactory.court();
        ArbitratorRegistry blockRegistry = ArbitratorRegistry(address(blockCourt.registry()));
        MockDisputableOrder blockOrder = blockFactory.createOrder(client, freelancer, feeRecipient);
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitrator(i);
            blockToken.mint(arbitrator, SEAT_LOCK);
            vm.startPrank(arbitrator);
            blockToken.approve(address(blockRegistry), SEAT_LOCK);
            blockRegistry.deposit(SEAT_LOCK);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        blockToken.mint(client, DISPUTE_FEE);
        vm.prank(client);
        blockToken.approve(address(blockCourt), DISPUTE_FEE);
        uint256 disputeId = blockOrder.openDispute(0);
        uint256 selectionBlock = blockCourt.getDispute(disputeId).selectionBlock;
        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256("block"));
        blockCourt.drawPanel(disputeId);
        vm.warp(blockCourt.getDispute(disputeId).revealDeadline);
        blockToken.setBlocked(address(blockCourt), true);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, address(blockCourt)));
        blockCourt.resolve(disputeId);

        assertEq(uint256(blockCourt.getDispute(disputeId).status), uint256(IArbitrationCourt.DisputeStatus.Voting));
        assertEq(blockCourt.pendingFees(), DISPUTE_FEE);
        assertEq(blockCourt.totalClaimable(), 0);
        assertEq(blockCourt.penaltiesReceived(), 0);
        assertEq(blockCourt.claimable(penaltyRecipient), 0);
        assertEq(blockRegistry.penaltiesSent(), 0);
        assertEq(blockRegistry.accountOf(_arbitrator(0)).locked, SEAT_LOCK);

        blockToken.setBlocked(address(blockCourt), false);
        blockCourt.resolve(disputeId);
        assertEq(blockCourt.penaltiesReceived(), 3 * SEAT_LOCK);
        assertEq(blockCourt.claimable(penaltyRecipient), DISPUTE_FEE + 3 * SEAT_LOCK);
        assertEq(blockToken.balanceOf(address(blockCourt)), DISPUTE_FEE + 3 * SEAT_LOCK);
    }

    function test_RevertWhen_PenaltyReceiptDiffersFromPenalties() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        address[3] memory panel = _draw(disputeId);
        _commit(disputeId, panel[0], FREELANCER_VOTE);
        _commit(disputeId, panel[1], FREELANCER_VOTE);
        _toRevealPhase(disputeId);
        _reveal(disputeId, panel[0], FREELANCER_VOTE);
        _reveal(disputeId, panel[1], FREELANCER_VOTE);
        _toResolution(disputeId);
        vm.mockCall(
            address(token), abi.encodeCall(IERC20.balanceOf, (address(court))), abi.encode(uint256(DISPUTE_FEE))
        );

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.DepositMismatch.selector, SEAT_LOCK, 0));
        court.resolve(disputeId);

        vm.clearMockedCalls();
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.Voting));
        assertEq(court.penaltiesReceived(), 0);
        assertEq(registry.penaltiesSent(), 0);
        court.resolve(disputeId);
        assertEq(court.penaltiesReceived(), SEAT_LOCK);
        _assertCourtBalanced();
    }

    function test_ConcurrentDisputes_FaultIsolatedToItsDispute() public {
        address shared = _arbitrator(0);
        _deposit(shared, 3 * SEAT_LOCK);
        _deposit(_arbitrator(1), 3 * SEAT_LOCK);
        _deposit(_arbitrator(2), 3 * SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        uint256 first = _open();
        uint256 second = _openFor(factory.createOrder(makeAddr("c2"), freelancer, feeRecipient), makeAddr("c2"));
        uint256 third = _openFor(factory.createOrder(makeAddr("c3"), freelancer, feeRecipient), makeAddr("c3"));
        _draw(first);
        _draw(second);
        assertEq(registry.accountOf(shared).locked, 2 * SEAT_LOCK);
        assertEq(registry.accountOf(shared).reserved, SEAT_LOCK);
        assertEq(registry.freeStake(shared), 0);

        _toResolution(first);
        court.resolve(first);
        assertEq(registry.accountOf(shared).stake, 2 * SEAT_LOCK);
        assertEq(registry.accountOf(shared).locked, SEAT_LOCK);
        assertEq(registry.accountOf(shared).reserved, SEAT_LOCK);
        assertEq(uint256(registry.candidatesOf(third)[0].state), uint256(IArbitratorRegistry.CandidateState.Reserved));
        assertEq(uint256(_status(second)), uint256(IArbitrationCourt.DisputeStatus.Voting));
        _assertCourtBalanced();
    }

    function test_Donations_CreateNoCredits() public {
        _activeArbitrators(3, SEAT_LOCK);
        uint256 disputeId = _open();
        token.mint(address(court), 55 * USDC);
        vm.warp(court.getDispute(disputeId).panelDeadline);
        court.resolve(disputeId);

        assertEq(court.totalClaimable(), DISPUTE_FEE);
        assertEq(token.balanceOf(address(court)), DISPUTE_FEE + 55 * USDC);
        assertEq(court.claimable(penaltyRecipient), 0);
        court.claimReward(client);
        assertEq(token.balanceOf(address(court)), 55 * USDC);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NothingToClaim.selector, penaltyRecipient));
        court.claimReward(penaltyRecipient);
        _assertCourtBalanced();
    }

    function test_Reentrancy_DuringFeePullPenaltyTransferAndClaim() public {
        ReentrantToken reentrant = new ReentrantToken();
        MockArbitrationFactory reentrantFactory =
            new MockArbitrationFactory(reentrant, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        ArbitrationCourt reentrantCourt = reentrantFactory.court();
        ArbitratorRegistry reentrantRegistry = ArbitratorRegistry(address(reentrantCourt.registry()));
        MockDisputableOrder reentrantOrder = reentrantFactory.createOrder(client, freelancer, feeRecipient);
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitrator(i);
            reentrant.mint(arbitrator, SEAT_LOCK);
            vm.startPrank(arbitrator);
            reentrant.approve(address(reentrantRegistry), SEAT_LOCK);
            reentrantRegistry.deposit(SEAT_LOCK);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        reentrant.mint(client, DISPUTE_FEE);
        vm.prank(client);
        reentrant.approve(address(reentrantCourt), DISPUTE_FEE);

        reentrant.arm(address(reentrantCourt), abi.encodeCall(ArbitrationCourt.retrySnapshot, (1)));
        uint256 disputeId = reentrantOrder.openDispute(0);
        _assertBlocked(reentrant);

        uint256 selectionBlock = reentrantCourt.getDispute(disputeId).selectionBlock;
        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256("block"));
        reentrantCourt.drawPanel(disputeId);
        vm.warp(reentrantCourt.getDispute(disputeId).revealDeadline);
        reentrant.arm(address(reentrantCourt), abi.encodeCall(ArbitrationCourt.claimReward, (penaltyRecipient)));
        reentrantCourt.resolve(disputeId);
        _assertBlocked(reentrant);
        assertEq(reentrantCourt.claimable(penaltyRecipient), DISPUTE_FEE + 3 * SEAT_LOCK);

        reentrant.arm(address(reentrantCourt), abi.encodeCall(ArbitrationCourt.resolve, (disputeId)));
        reentrantCourt.claimReward(penaltyRecipient);
        _assertBlocked(reentrant);
        assertEq(reentrant.balanceOf(penaltyRecipient), DISPUTE_FEE + 3 * SEAT_LOCK);
        assertEq(reentrantCourt.totalClaimable(), 0);
    }

    function _assertNoPanel(uint256 disputeId, address payer) private view {
        (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(disputeId);
        assertEq(uint256(ruling), uint256(IArbitrationCourt.Ruling.FreelancerWins));
        assertEq(uint256(reason), uint256(IArbitrationCourt.RulingReason.NoPanel));
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.Resolved));
        assertEq(court.claimable(payer), DISPUTE_FEE);
    }

    function test_Reentrancy_DrawPanelFromFeePullCallbackIsBlocked() public {
        ReentrantToken reentrant = new ReentrantToken();
        MockArbitrationFactory reentrantFactory =
            new MockArbitrationFactory(reentrant, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        ArbitrationCourt reentrantCourt = reentrantFactory.court();
        ArbitratorRegistry reentrantRegistry = ArbitratorRegistry(address(reentrantCourt.registry()));
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitrator(i);
            reentrant.mint(arbitrator, 2 * SEAT_LOCK);
            vm.startPrank(arbitrator);
            reentrant.approve(address(reentrantRegistry), 2 * SEAT_LOCK);
            reentrantRegistry.deposit(2 * SEAT_LOCK);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        reentrant.mint(client, 2 * DISPUTE_FEE);
        vm.prank(client);
        reentrant.approve(address(reentrantCourt), 2 * DISPUTE_FEE);
        uint256 disputeId = reentrantFactory.createOrder(client, freelancer, feeRecipient).openDispute(0);
        IArbitrationCourt.Dispute memory armed = reentrantCourt.getDispute(disputeId);
        vm.roll(armed.selectionBlock + 1);
        vm.setBlockhash(armed.selectionBlock, keccak256("block"));

        reentrant.arm(address(reentrantCourt), abi.encodeCall(ArbitrationCourt.drawPanel, (disputeId)));
        reentrantFactory.createOrder(client, freelancer, feeRecipient).openDispute(0);
        _assertBlocked(reentrant);

        IArbitrationCourt.Dispute memory dispute = reentrantCourt.getDispute(disputeId);
        assertEq(uint256(dispute.status), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
        assertEq(dispute.selectionBlock, armed.selectionBlock);
        assertEq(dispute.commitDeadline, 0);
        assertEq(reentrantCourt.getSeats(disputeId)[0].arbitrator, address(0));
        assertEq(
            uint256(reentrantRegistry.snapshotState(disputeId)), uint256(IArbitratorRegistry.SnapshotState.Reserved)
        );

        reentrantCourt.drawPanel(disputeId);
        assertEq(uint256(reentrantCourt.getDispute(disputeId).status), uint256(IArbitrationCourt.DisputeStatus.Voting));
    }

    function _assertBlocked(ReentrantToken reentrant) private view {
        assertTrue(reentrant.reentryAttempted());
        assertFalse(reentrant.reentrySucceeded());
        assertEq(
            reentrant.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function _nonPanelist(address[3] memory panel, uint256 count) private returns (address) {
        for (uint256 i; i < count; ++i) {
            address candidate = _arbitrator(i);
            if (candidate != panel[0] && candidate != panel[1] && candidate != panel[2]) return candidate;
        }
        revert("no outsider");
    }

    function _resolveWithPattern(uint8[3] memory votes) private returns (uint256 disputeId) {
        disputeId = _openFor(factory.createOrder(client, freelancer, feeRecipient), client);
        address[3] memory panel = _draw(disputeId);
        for (uint256 j; j < 3; ++j) {
            if (votes[j] != 0) _commit(disputeId, panel[j], votes[j]);
        }
        _toRevealPhase(disputeId);
        for (uint256 j; j < 3; ++j) {
            if (votes[j] != 0) _reveal(disputeId, panel[j], votes[j]);
        }
        _toResolution(disputeId);
        court.resolve(disputeId);
    }

    function _panelOf(uint256 disputeId) private view returns (address[3] memory panel) {
        IArbitrationCourt.Seat[3] memory seats = court.getSeats(disputeId);
        for (uint256 j; j < 3; ++j) {
            panel[j] = seats[j].arbitrator;
        }
    }

    function _openAfterWithdrawingAll() private returns (uint256) {
        for (uint256 i; i < 3; ++i) {
            uint256 free = registry.freeStake(_arbitrator(i));
            if (free == 0) continue;
            vm.prank(_arbitrator(i));
            registry.withdraw(free);
        }
        return _open();
    }

    function stranger() private returns (address) {
        return makeAddr("stranger");
    }
}
