// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IArbitratorRegistry} from "./IArbitratorRegistry.sol";

/// @title IArbitrationCourt
/// @notice Three-seat commit-reveal arbitration for disputes opened by orders of the deploying factory.
interface IArbitrationCourt {
    enum DisputeStatus {
        None,
        AwaitingCandidates,
        AwaitingSeed,
        Voting,
        Resolved
    }

    enum Vote {
        None,
        Freelancer,
        Client
    }

    enum Ruling {
        None,
        FreelancerWins,
        ClientWins,
        Split
    }

    enum RulingReason {
        None,
        Majority,
        NoPanel,
        NoDecision
    }

    struct Seat {
        address arbitrator;
        uint256 candidateIndex;
        bytes32 commitment;
        Vote vote;
    }

    struct Dispute {
        address order;
        address client;
        address freelancer;
        address feeRecipient;
        uint256 milestoneIndex;
        DisputeStatus status;
        Ruling ruling;
        RulingReason reason;
        uint64 openedAt;
        uint64 panelDeadline;
        uint64 drawnAt;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint256 selectionBlock;
    }

    event DisputeOpened(uint256 indexed disputeId, address indexed order, uint256 milestoneIndex, uint256 candidates);
    event CandidatesPending(uint256 indexed disputeId, uint256 eligibleCount);
    event SelectionArmed(uint256 indexed disputeId, uint256 selectionBlock);
    event PanelDrawn(uint256 indexed disputeId, address[3] panel, uint256 commitDeadline, uint256 revealDeadline);
    event VoteCommitted(uint256 indexed disputeId, address indexed arbitrator);
    event VoteRevealed(uint256 indexed disputeId, address indexed arbitrator, Vote vote);
    event DisputeResolved(
        uint256 indexed disputeId,
        Ruling ruling,
        RulingReason reason,
        uint256 validReveals,
        uint256 rewardPerReveal,
        uint256 penalties,
        uint256 feeRefund
    );
    event RewardClaimed(address indexed account, uint256 amount);

    function factory() external view returns (address);
    function registry() external view returns (IArbitratorRegistry);
    function stakeToken() external view returns (IERC20);
    function disputeFee() external view returns (uint256);
    function penaltyRecipient() external view returns (address);
    function claimable(address account) external view returns (uint256);
    function pendingFees() external view returns (uint256);
    function totalClaimable() external view returns (uint256);
    function feesReceived() external view returns (uint256);
    function penaltiesReceived() external view returns (uint256);
    function claimsPaid() external view returns (uint256);
    function getDispute(uint256 disputeId) external view returns (Dispute memory);
    function getSeats(uint256 disputeId) external view returns (Seat[3] memory);
    function rulingOf(uint256 disputeId) external view returns (Ruling ruling, RulingReason reason);
    function voteCommitment(uint256 disputeId, address arbitrator, uint8 vote, bytes32 salt)
        external
        view
        returns (bytes32);

    function openDispute(uint256 milestoneIndex) external returns (uint256 disputeId);
    function retrySnapshot(uint256 disputeId) external;
    function drawPanel(uint256 disputeId) external;
    function commitVote(uint256 disputeId, bytes32 commitment) external;
    function revealVote(uint256 disputeId, uint8 vote, bytes32 salt) external;
    function resolve(uint256 disputeId) external;
    function claimReward(address account) external returns (uint256 amount);
}
