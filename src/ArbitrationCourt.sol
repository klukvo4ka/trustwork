// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArbitratorRegistry} from "./ArbitratorRegistry.sol";
import {IArbitrationCourt} from "./interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "./interfaces/IArbitratorRegistry.sol";
import {IOrderFactory} from "./interfaces/IOrderFactory.sol";
import {IOrderParties} from "./interfaces/IOrderParties.sol";

/// @title ArbitrationCourt
/// @notice Arbitrates disputes opened by orders of the deploying factory with a three-seat commit-reveal panel drawn
/// from candidates the registry reserved before the seed existed.
/// @dev The seed is a future blockhash, which the sequencer can influence and anyone can read once mined; it is not
/// adversarially unbiased. Exact-transfer stake token only. Every timeout needs an on-chain caller.
contract ArbitrationCourt is IArbitrationCourt, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PANEL_SIZE = 3;
    uint256 public constant DECISION_THRESHOLD = 2;
    uint256 public constant SELECTION_DELAY_BLOCKS = 10;
    uint256 public constant PANEL_PERIOD = 3 days;
    uint256 public constant COMMIT_PERIOD = 2 days;
    uint256 public constant REVEAL_PERIOD = 1 days;
    bytes32 public constant VOTE_TAG = keccak256("TrustWork.ArbitrationVote.v1");

    address public immutable factory;
    IArbitratorRegistry public immutable registry;
    IERC20 public immutable stakeToken;
    uint256 public immutable disputeFee;
    uint256 public immutable seatLock;
    address public immutable penaltyRecipient;

    uint256 public disputeCount;
    uint256 public pendingFees;
    uint256 public totalClaimable;
    uint256 public feesReceived;
    uint256 public penaltiesReceived;
    uint256 public claimsPaid;
    mapping(address account => uint256) public claimable;

    mapping(uint256 disputeId => Dispute) private _disputes;
    mapping(uint256 disputeId => Seat[3]) private _seats;

    error ZeroAddress();
    error TokenHasNoCode(address token);
    error ZeroDisputeFee();
    error ZeroSeatLock();
    error PenaltyRecipientIsFactory(address penaltyRecipient);
    error UnknownOrder(address caller);
    error UnknownDispute(uint256 disputeId);
    error InvalidDisputeStatus(uint256 disputeId, DisputeStatus status);
    error PanelPeriodElapsed(uint256 disputeId, uint256 panelDeadline);
    error PanelPeriodActive(uint256 disputeId, uint256 panelDeadline);
    error SelectionBlockNotReached(uint256 disputeId, uint256 selectionBlock);
    error CommitPeriodElapsed(uint256 disputeId, uint256 commitDeadline);
    error NotRevealPeriod(uint256 disputeId, uint256 commitDeadline, uint256 revealDeadline);
    error RevealPeriodActive(uint256 disputeId, uint256 revealDeadline);
    error NotPanelist(uint256 disputeId, address caller);
    error ZeroCommitment();
    error AlreadyCommitted(uint256 disputeId, address arbitrator);
    error NotCommitted(uint256 disputeId, address arbitrator);
    error AlreadyRevealed(uint256 disputeId, address arbitrator);
    error InvalidVote(uint8 vote);
    error InvalidReveal(uint256 disputeId, address arbitrator);
    error NothingToClaim(address account);
    error DepositMismatch(uint256 expected, uint256 received);

    /// @dev The deployer becomes `factory`. The registry is deployed here, so its `court` is this contract and its own
    /// restrictions on `seatLock` and `penaltyRecipient` apply as well.
    constructor(IERC20 stakeToken_, uint256 disputeFee_, uint256 seatLock_, address penaltyRecipient_) {
        if (address(stakeToken_) == address(0) || penaltyRecipient_ == address(0)) revert ZeroAddress();
        if (address(stakeToken_).code.length == 0) revert TokenHasNoCode(address(stakeToken_));
        if (disputeFee_ == 0) revert ZeroDisputeFee();
        if (seatLock_ == 0) revert ZeroSeatLock();
        if (penaltyRecipient_ == msg.sender) revert PenaltyRecipientIsFactory(penaltyRecipient_);

        factory = msg.sender;
        stakeToken = stakeToken_;
        disputeFee = disputeFee_;
        seatLock = seatLock_;
        penaltyRecipient = penaltyRecipient_;
        registry = new ArbitratorRegistry(stakeToken_, seatLock_, penaltyRecipient_);
    }

    /// @notice Opens a dispute for `milestoneIndex` of the calling order and pulls `disputeFee` from its client.
    function openDispute(uint256 milestoneIndex) external nonReentrant returns (uint256 disputeId) {
        if (!IOrderFactory(factory).isWorkOrder(msg.sender)) revert UnknownOrder(msg.sender);
        IOrderParties order = IOrderParties(msg.sender);
        address client = order.client();

        disputeId = ++disputeCount;
        Dispute storage dispute = _disputes[disputeId];
        dispute.order = msg.sender;
        dispute.client = client;
        dispute.freelancer = order.freelancer();
        dispute.feeRecipient = order.feeRecipient();
        dispute.milestoneIndex = milestoneIndex;
        dispute.openedAt = SafeCast.toUint64(block.timestamp);
        dispute.panelDeadline = SafeCast.toUint64(block.timestamp + PANEL_PERIOD);
        pendingFees += disputeFee;
        feesReceived += disputeFee;

        uint256 candidates = _snapshot(disputeId, dispute);
        emit DisputeOpened(disputeId, msg.sender, milestoneIndex, candidates);

        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(client, address(this), disputeFee);
        uint256 received = stakeToken.balanceOf(address(this)) - balanceBefore;
        if (received != disputeFee) revert DepositMismatch(disputeFee, received);
    }

    /// @notice Retries the candidate snapshot of a dispute that had fewer than three candidates.
    function retrySnapshot(uint256 disputeId) external nonReentrant {
        Dispute storage dispute = _requireStatus(disputeId, DisputeStatus.AwaitingCandidates);
        if (block.timestamp >= dispute.panelDeadline) revert PanelPeriodElapsed(disputeId, dispute.panelDeadline);
        _snapshot(disputeId, dispute);
    }

    /// @notice Draws the panel from the stored snapshot once the seed block is mined. If its hash is no longer
    /// available, re-arms a later seed block against the same snapshot.
    function drawPanel(uint256 disputeId) external nonReentrant {
        Dispute storage dispute = _requireStatus(disputeId, DisputeStatus.AwaitingSeed);
        if (block.timestamp >= dispute.panelDeadline) revert PanelPeriodElapsed(disputeId, dispute.panelDeadline);
        uint256 selectionBlock = dispute.selectionBlock;
        if (block.number <= selectionBlock) revert SelectionBlockNotReached(disputeId, selectionBlock);

        bytes32 blockHash = blockhash(selectionBlock);
        if (blockHash == bytes32(0)) {
            _armSelection(disputeId, dispute);
            return;
        }

        uint64 commitDeadline = SafeCast.toUint64(block.timestamp + COMMIT_PERIOD);
        uint64 revealDeadline = SafeCast.toUint64(block.timestamp + COMMIT_PERIOD + REVEAL_PERIOD);
        dispute.status = DisputeStatus.Voting;
        dispute.drawnAt = SafeCast.toUint64(block.timestamp);
        dispute.commitDeadline = commitDeadline;
        dispute.revealDeadline = revealDeadline;

        bytes32 seed = keccak256(abi.encode(blockHash, block.chainid, address(this), disputeId));
        (uint256[3] memory candidateIndexes, address[3] memory panel) = registry.selectPanel(disputeId, seed);
        Seat[3] storage seats = _seats[disputeId];
        for (uint256 j; j < PANEL_SIZE; ++j) {
            seats[j].arbitrator = panel[j];
            seats[j].candidateIndex = candidateIndexes[j];
        }

        emit PanelDrawn(disputeId, panel, commitDeadline, revealDeadline);
    }

    function commitVote(uint256 disputeId, bytes32 commitment) external nonReentrant {
        Dispute storage dispute = _requireStatus(disputeId, DisputeStatus.Voting);
        if (block.timestamp >= dispute.commitDeadline) revert CommitPeriodElapsed(disputeId, dispute.commitDeadline);
        Seat storage seat = _seatOf(disputeId, msg.sender);
        if (commitment == bytes32(0)) revert ZeroCommitment();
        if (seat.commitment != bytes32(0)) revert AlreadyCommitted(disputeId, msg.sender);

        seat.commitment = commitment;
        emit VoteCommitted(disputeId, msg.sender);
    }

    /// @notice Reveals a committed vote. `vote` is a raw value so that values outside `{1, 2}` reach `InvalidVote`
    /// instead of failing ABI decoding.
    function revealVote(uint256 disputeId, uint8 vote, bytes32 salt) external nonReentrant {
        Dispute storage dispute = _requireStatus(disputeId, DisputeStatus.Voting);
        if (block.timestamp < dispute.commitDeadline || block.timestamp >= dispute.revealDeadline) {
            revert NotRevealPeriod(disputeId, dispute.commitDeadline, dispute.revealDeadline);
        }
        Seat storage seat = _seatOf(disputeId, msg.sender);
        if (seat.commitment == bytes32(0)) revert NotCommitted(disputeId, msg.sender);
        if (seat.vote != Vote.None) revert AlreadyRevealed(disputeId, msg.sender);
        if (vote != uint8(Vote.Freelancer) && vote != uint8(Vote.Client)) revert InvalidVote(vote);
        if (voteCommitment(disputeId, msg.sender, vote, salt) != seat.commitment) {
            revert InvalidReveal(disputeId, msg.sender);
        }

        seat.vote = Vote(vote);
        emit VoteRevealed(disputeId, msg.sender, Vote(vote));
    }

    /// @notice Records the ruling of a dispute whose panel period (no panel) or reveal period has ended, credits
    /// rewards, refunds and penalties, and releases the dispute's reservations or seats.
    function resolve(uint256 disputeId) external nonReentrant {
        Dispute storage dispute = _requireDispute(disputeId);
        DisputeStatus status = dispute.status;
        if (status == DisputeStatus.AwaitingCandidates || status == DisputeStatus.AwaitingSeed) {
            if (block.timestamp < dispute.panelDeadline) revert PanelPeriodActive(disputeId, dispute.panelDeadline);
            _resolveWithoutPanel(disputeId, dispute, status == DisputeStatus.AwaitingSeed);
        } else if (status == DisputeStatus.Voting) {
            if (block.timestamp < dispute.revealDeadline) {
                revert RevealPeriodActive(disputeId, dispute.revealDeadline);
            }
            _resolveWithPanel(disputeId, dispute);
        } else {
            revert InvalidDisputeStatus(disputeId, status);
        }
    }

    /// @notice Transfers the credit of `account` to `account`. Callable by anyone.
    function claimReward(address account) external nonReentrant returns (uint256 amount) {
        amount = claimable[account];
        if (amount == 0) revert NothingToClaim(account);

        claimable[account] = 0;
        totalClaimable -= amount;
        claimsPaid += amount;

        emit RewardClaimed(account, amount);
        stakeToken.safeTransfer(account, amount);
    }

    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        return _disputes[disputeId];
    }

    function getSeats(uint256 disputeId) external view returns (Seat[3] memory) {
        return _seats[disputeId];
    }

    function rulingOf(uint256 disputeId) external view returns (Ruling ruling, RulingReason reason) {
        Dispute storage dispute = _disputes[disputeId];
        return (dispute.ruling, dispute.reason);
    }

    /// @notice Commitment for `vote` by `arbitrator` in `disputeId`. Hashes any `uint8`; only `1` (Freelancer) and `2`
    /// (Client) can later be revealed.
    function voteCommitment(uint256 disputeId, address arbitrator, uint8 vote, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(VOTE_TAG, block.chainid, address(this), disputeId, arbitrator, vote, salt));
    }

    function _snapshot(uint256 disputeId, Dispute storage dispute) private returns (uint256 candidates) {
        candidates = registry.reserveCandidates(disputeId, [dispute.client, dispute.freelancer, dispute.feeRecipient]);
        if (candidates < PANEL_SIZE) {
            dispute.status = DisputeStatus.AwaitingCandidates;
            emit CandidatesPending(disputeId, candidates);
        } else {
            _armSelection(disputeId, dispute);
        }
    }

    function _armSelection(uint256 disputeId, Dispute storage dispute) private {
        uint256 selectionBlock = block.number + SELECTION_DELAY_BLOCKS;
        dispute.status = DisputeStatus.AwaitingSeed;
        dispute.selectionBlock = selectionBlock;
        emit SelectionArmed(disputeId, selectionBlock);
    }

    function _resolveWithoutPanel(uint256 disputeId, Dispute storage dispute, bool hasSnapshot) private {
        dispute.status = DisputeStatus.Resolved;
        dispute.ruling = Ruling.FreelancerWins;
        dispute.reason = RulingReason.NoPanel;
        pendingFees -= disputeFee;
        totalClaimable += disputeFee;
        claimable[dispute.client] += disputeFee;

        emit DisputeResolved(disputeId, Ruling.FreelancerWins, RulingReason.NoPanel, 0, 0, 0, disputeFee);
        if (hasSnapshot) registry.releaseReservations(disputeId);
    }

    function _resolveWithPanel(uint256 disputeId, Dispute storage dispute) private {
        Seat[3] storage seats = _seats[disputeId];
        uint256 freelancerVotes;
        uint256 clientVotes;
        for (uint256 j; j < PANEL_SIZE; ++j) {
            Vote vote = seats[j].vote;
            if (vote == Vote.Freelancer) ++freelancerVotes;
            else if (vote == Vote.Client) ++clientVotes;
        }
        uint256 validReveals = freelancerVotes + clientVotes;
        uint256 penalties = (PANEL_SIZE - validReveals) * seatLock;

        (Ruling ruling, RulingReason reason) = freelancerVotes >= DECISION_THRESHOLD
            ? (Ruling.FreelancerWins, RulingReason.Majority)
            : clientVotes >= DECISION_THRESHOLD
                ? (Ruling.ClientWins, RulingReason.Majority)
                : (Ruling.Split, RulingReason.NoDecision);
        dispute.status = DisputeStatus.Resolved;
        dispute.ruling = ruling;
        dispute.reason = reason;

        uint256 rewardPerReveal = validReveals == 0 ? 0 : disputeFee / validReveals;
        for (uint256 j; j < PANEL_SIZE; ++j) {
            if (seats[j].vote != Vote.None) claimable[seats[j].arbitrator] += rewardPerReveal;
        }
        claimable[penaltyRecipient] += disputeFee - rewardPerReveal * validReveals + penalties;
        pendingFees -= disputeFee;
        totalClaimable += disputeFee + penalties;
        penaltiesReceived += penalties;

        emit DisputeResolved(disputeId, ruling, reason, validReveals, rewardPerReveal, penalties, 0);

        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        for (uint256 j; j < PANEL_SIZE; ++j) {
            uint256 penalty = seats[j].vote == Vote.None ? seatLock : 0;
            registry.releaseSeat(disputeId, seats[j].candidateIndex, penalty);
        }
        uint256 received = stakeToken.balanceOf(address(this)) - balanceBefore;
        if (received != penalties) revert DepositMismatch(penalties, received);
    }

    function _requireDispute(uint256 disputeId) private view returns (Dispute storage dispute) {
        dispute = _disputes[disputeId];
        if (dispute.status == DisputeStatus.None) revert UnknownDispute(disputeId);
    }

    function _requireStatus(uint256 disputeId, DisputeStatus expected) private view returns (Dispute storage dispute) {
        dispute = _requireDispute(disputeId);
        if (dispute.status != expected) revert InvalidDisputeStatus(disputeId, dispute.status);
    }

    function _seatOf(uint256 disputeId, address arbitrator) private view returns (Seat storage) {
        Seat[3] storage seats = _seats[disputeId];
        for (uint256 j; j < PANEL_SIZE; ++j) {
            if (seats[j].arbitrator == arbitrator) return seats[j];
        }
        revert NotPanelist(disputeId, arbitrator);
    }
}
