// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";
import {MockArbitrationFactory} from "../mocks/MockArbitrationFactory.sol";

contract ArbitrationCourtFuzzTest is CourtTestBase {
    function testFuzz_ResolutionConservesFeesAndPenalties(uint256 fee, uint256 lock, uint256 pattern) public {
        fee = bound(fee, 1, 1e15);
        lock = bound(lock, 1, 1e15);
        pattern = bound(pattern, 0, 124);
        factory = new MockArbitrationFactory(token, fee, lock, penaltyRecipient);
        court = factory.court();
        registry = ArbitratorRegistry(address(court.registry()));
        order = factory.createOrder(client, freelancer, feeRecipient);
        for (uint256 i; i < 3; ++i) {
            _deposit(_arbitrator(i), lock);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        token.mint(client, fee);
        vm.prank(client);
        token.approve(address(court), fee);
        uint256 disputeId = order.openDispute(0);
        address[3] memory panel = _draw(disputeId);
        uint256[3] memory behaviors = [pattern % 5, (pattern / 5) % 5, pattern / 25];
        uint256 validReveals;
        for (uint256 j; j < 3; ++j) {
            if (behaviors[j] == 0) continue;
            _commit(disputeId, panel[j], behaviors[j] == 2 ? 3 : behaviors[j] == 4 ? CLIENT_VOTE : FREELANCER_VOTE);
        }
        _toRevealPhase(disputeId);
        for (uint256 j; j < 3; ++j) {
            if (behaviors[j] < 3) continue;
            _reveal(disputeId, panel[j], behaviors[j] == 4 ? CLIENT_VOTE : FREELANCER_VOTE);
            ++validReveals;
        }
        _toResolution(disputeId);

        court.resolve(disputeId);

        uint256 penalties = (3 - validReveals) * lock;
        uint256 rewards;
        for (uint256 j; j < 3; ++j) {
            rewards += court.claimable(panel[j]);
        }
        uint256 expectedReward = validReveals == 0 ? 0 : fee / validReveals;
        assertEq(rewards, expectedReward * validReveals);
        assertEq(rewards + court.claimable(penaltyRecipient) + court.claimable(client), fee + penalties);
        assertEq(court.claimable(client), 0);
        assertEq(court.penaltiesReceived(), penalties);
        assertEq(registry.penaltiesSent(), penalties);
        assertEq(token.balanceOf(address(court)), fee + penalties);
        _assertCourtBalanced();
    }

    function testFuzz_OnlyTheAllowedActionSucceedsAtEachBoundary(uint256 boundarySeed, uint256 offsetSeed) public {
        _activeArbitrators(3, 2 * SEAT_LOCK);
        uint256 disputeId = _open();
        uint256 offset = offsetSeed % 5;
        uint256 boundary = boundarySeed % 4;
        if (boundary == 0) _checkPanelDeadline(disputeId, offset);
        else if (boundary == 3) _checkSelectionBlock(disputeId, offset);
        else _checkVotingDeadline(disputeId, offset, boundary == 1);
    }

    function _checkPanelDeadline(uint256 disputeId, uint256 offset) private {
        uint256 deadline = court.getDispute(disputeId).panelDeadline;
        _setSeedBlock(disputeId, keccak256("seed"));
        vm.warp(_shift(deadline, offset));
        bool beforeDeadline = block.timestamp < deadline;
        _expectOutcome(beforeDeadline, abi.encodeCall(court.drawPanel, (disputeId)));
        _expectOutcome(!beforeDeadline, abi.encodeCall(court.resolve, (disputeId)));
    }

    function _checkSelectionBlock(uint256 disputeId, uint256 offset) private {
        uint256 selectionBlock = court.getDispute(disputeId).selectionBlock;
        vm.roll(selectionBlock + 2);
        vm.setBlockhash(selectionBlock, keccak256("seed"));
        vm.roll(_shift(selectionBlock, offset));
        _expectOutcome(block.number > selectionBlock, abi.encodeCall(court.drawPanel, (disputeId)));
    }

    function _checkVotingDeadline(uint256 disputeId, uint256 offset, bool aroundCommitDeadline) private {
        address[3] memory panel = _draw(disputeId);
        _commit(disputeId, panel[0], FREELANCER_VOTE);
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        vm.warp(_shift(aroundCommitDeadline ? dispute.commitDeadline : dispute.revealDeadline, offset));

        bytes32 commitment = _expectedCommitment(
            block.chainid, address(court), disputeId, panel[1], CLIENT_VOTE, _salt(panel[1], disputeId)
        );
        _expectOutcomeAs(
            panel[1],
            block.timestamp < dispute.commitDeadline,
            abi.encodeCall(court.commitVote, (disputeId, commitment))
        );
        _expectOutcomeAs(
            panel[0],
            block.timestamp >= dispute.commitDeadline && block.timestamp < dispute.revealDeadline,
            abi.encodeCall(court.revealVote, (disputeId, FREELANCER_VOTE, _salt(panel[0], disputeId)))
        );
        _expectOutcome(block.timestamp >= dispute.revealDeadline, abi.encodeCall(court.resolve, (disputeId)));
    }

    function _expectOutcome(bool shouldSucceed, bytes memory data) private {
        _expectOutcomeAs(address(this), shouldSucceed, data);
    }

    function _expectOutcomeAs(address caller, bool shouldSucceed, bytes memory data) private {
        uint256 state = vm.snapshotState();
        vm.prank(caller);
        (bool success,) = address(court).call(data);
        assertEq(success, shouldSucceed);
        vm.revertToState(state);
    }

    /// @dev Maps `offset` in `[0, 4]` to `value - 2 ... value + 2`.
    function _shift(uint256 value, uint256 offset) private pure returns (uint256) {
        return value + offset - 2;
    }
}
