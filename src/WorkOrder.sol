// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IArbitrationCourt} from "./interfaces/IArbitrationCourt.sol";

/// @title WorkOrder
/// @notice Escrow for one client-freelancer engagement paid in ordered milestones.
/// @dev Only tokens that move exactly the requested amount are supported. Fee-on-transfer tokens are
/// rejected at funding; rebasing tokens are unsupported and may leave the order unable to settle.
contract WorkOrder is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum OrderStatus {
        Unfunded,
        Active,
        Disputed,
        Completed,
        Terminated
    }

    enum MilestoneStatus {
        Pending,
        Submitted,
        Settled,
        Disputed
    }

    struct Milestone {
        uint256 amount;
        MilestoneStatus status;
        uint64 submittedAt;
        uint64 reviewDeadline;
        uint64 deliveryDeadline;
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MAX_REVIEW_PERIOD = 30 days;
    uint256 public constant MAX_DELIVERY_PERIOD = 180 days;
    bytes32 public constant APPROVE_MILESTONE_TYPEHASH =
        keccak256("ApproveMilestone(uint256 milestoneIndex,uint256 nonce,uint256 deadline)");

    address public immutable client;
    address public immutable freelancer;
    IERC20 public immutable token;
    address public immutable feeRecipient;
    uint256 public immutable feeBps;
    uint256 public immutable reviewPeriod;
    uint256 public immutable deliveryPeriod;
    uint256 public immutable totalAmount;
    IArbitrationCourt public immutable court;

    OrderStatus public status;
    uint256 public currentMilestone;
    /// @notice Funded amounts not yet paid out: unsettled milestones while active, unclaimed credits once
    /// terminated. Independent of the raw token balance.
    uint256 public outstandingObligations;
    /// @notice Nonce a client approval signature must carry. Incremented by every settlement, by opening a dispute
    /// and by delivery-expiry termination.
    uint256 public approvalNonce;
    /// @notice Court dispute opened by this order; zero until `openDispute`.
    uint256 public disputeId;
    /// @notice Gross milestone amounts paid through settlement, protocol fees included.
    uint256 public directPaid;
    /// @notice Amounts transferred through `claimPayout`.
    uint256 public claimsPaid;
    mapping(address account => uint256) public claimable;

    Milestone[] private _milestones;

    event Funded(address indexed client, uint256 amount);
    event MilestoneSubmitted(uint256 indexed index, uint256 reviewDeadline);
    event MilestoneSettled(
        uint256 indexed index, address indexed settledBy, bool byTimeout, uint256 freelancerPayout, uint256 fee
    );
    event MilestoneApprovedBySignature(
        uint256 indexed index, address indexed client, address indexed relayer, uint256 nonce
    );
    event OrderCompleted();
    event DeliveryExpired(uint256 indexed index, uint256 clientCredit);
    event PayoutClaimed(address indexed account, uint256 amount);
    event DisputeOpened(uint256 indexed index, uint256 indexed disputeId, uint256 consumedNonce);
    event RulingApplied(
        uint256 indexed disputeId,
        IArbitrationCourt.Ruling ruling,
        IArbitrationCourt.RulingReason reason,
        uint256 clientCredit,
        uint256 freelancerCredit,
        uint256 feeCredit
    );

    error ZeroAddress();
    error ClientIsFreelancer();
    error TokenHasNoCode(address token);
    error NoMilestones();
    error ZeroMilestoneAmount(uint256 index);
    error FeeTooHigh(uint256 feeBps);
    error InvalidReviewPeriod(uint256 reviewPeriod);
    error NotClient(address caller);
    error NotFreelancer(address caller);
    error InvalidOrderStatus(OrderStatus status);
    error NotCurrentMilestone(uint256 index, uint256 currentMilestone);
    error InvalidMilestoneStatus(uint256 index, MilestoneStatus status);
    error ReviewPeriodNotElapsed(uint256 index, uint256 reviewDeadline);
    error DepositMismatch(uint256 expected, uint256 received);
    error ApprovalSignatureExpired(uint256 deadline);
    error InvalidApprovalNonce(uint256 nonce, uint256 approvalNonce);
    error InvalidApprovalSignature();
    error FeeRecipientIsOrder();
    error InvalidDeliveryPeriod(uint256 deliveryPeriod);
    error DeliveryPeriodElapsed(uint256 index, uint256 deliveryDeadline);
    error DeliveryPeriodNotElapsed(uint256 index, uint256 deliveryDeadline);
    error NothingToClaim(address account);
    error ReviewPeriodElapsed(uint256 index, uint256 reviewDeadline);
    error RulingNotReady(uint256 disputeId);

    constructor(
        address client_,
        address freelancer_,
        IERC20 token_,
        address feeRecipient_,
        uint256 feeBps_,
        uint256 reviewPeriod_,
        uint256 deliveryPeriod_,
        IArbitrationCourt court_,
        uint256[] memory milestoneAmounts
    ) EIP712("TrustWork", "1") {
        if (
            client_ == address(0) || freelancer_ == address(0) || feeRecipient_ == address(0)
                || address(token_) == address(0) || address(court_) == address(0)
        ) revert ZeroAddress();
        if (client_ == freelancer_) revert ClientIsFreelancer();
        if (feeRecipient_ == address(this)) revert FeeRecipientIsOrder();
        if (address(token_).code.length == 0) revert TokenHasNoCode(address(token_));
        if (milestoneAmounts.length == 0) revert NoMilestones();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (reviewPeriod_ == 0 || reviewPeriod_ > MAX_REVIEW_PERIOD) revert InvalidReviewPeriod(reviewPeriod_);
        if (deliveryPeriod_ == 0 || deliveryPeriod_ > MAX_DELIVERY_PERIOD) {
            revert InvalidDeliveryPeriod(deliveryPeriod_);
        }

        uint256 total;
        for (uint256 i; i < milestoneAmounts.length; ++i) {
            if (milestoneAmounts[i] == 0) revert ZeroMilestoneAmount(i);
            total += milestoneAmounts[i];
            _milestones.push(
                Milestone({
                    amount: milestoneAmounts[i],
                    status: MilestoneStatus.Pending,
                    submittedAt: 0,
                    reviewDeadline: 0,
                    deliveryDeadline: 0
                })
            );
        }

        client = client_;
        freelancer = freelancer_;
        token = token_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        reviewPeriod = reviewPeriod_;
        deliveryPeriod = deliveryPeriod_;
        totalAmount = total;
        court = court_;
    }

    /// @notice Deposits the full budget from the client. Requires prior ERC-20 approval of `totalAmount`.
    /// @dev Reverts unless the order's balance grows by exactly `totalAmount`, which rejects
    /// fee-on-transfer tokens. Tokens already held by the order do not affect the check.
    function fund() external nonReentrant {
        _requireFundable();
        _deposit();
    }

    /// @notice Funds the order after attempting an ERC-2612 permit for exactly `totalAmount` from the client.
    /// @dev The permit is best effort: if it reverts (invalid, expired, already used, or unsupported by the
    /// token), funding proceeds and succeeds only if the client's existing allowance covers `totalAmount`.
    /// A failed permit never authorizes a transfer on its own.
    function fundWithPermit(uint256 deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        _requireFundable();
        try IERC20Permit(address(token)).permit(client, address(this), totalAmount, deadline, v, r, s) {} catch {}
        _deposit();
    }

    /// @notice Marks the current milestone as delivered and starts its review period. Allowed only while
    /// `block.timestamp < deliveryDeadline`.
    function submitMilestone(uint256 index) external nonReentrant {
        if (msg.sender != freelancer) revert NotFreelancer(msg.sender);
        Milestone storage milestone = _currentMilestone(index, MilestoneStatus.Pending);
        if (block.timestamp >= milestone.deliveryDeadline) {
            revert DeliveryPeriodElapsed(index, milestone.deliveryDeadline);
        }

        uint64 deadline = SafeCast.toUint64(block.timestamp + reviewPeriod);
        milestone.status = MilestoneStatus.Submitted;
        milestone.submittedAt = SafeCast.toUint64(block.timestamp);
        milestone.reviewDeadline = deadline;

        emit MilestoneSubmitted(index, deadline);
    }

    /// @notice Client accepts the submitted milestone and releases its payment. Allowed at any time after submission.
    function approveMilestone(uint256 index) external nonReentrant {
        if (msg.sender != client) revert NotClient(msg.sender);
        Milestone storage milestone = _currentMilestone(index, MilestoneStatus.Submitted);
        _settle(index, milestone, false);
    }

    /// @notice Releases a submitted milestone the client has not approved once `block.timestamp >= reviewDeadline`.
    /// Callable by anyone.
    function finalizeMilestone(uint256 index) external nonReentrant {
        Milestone storage milestone = _currentMilestone(index, MilestoneStatus.Submitted);
        if (block.timestamp < milestone.reviewDeadline) {
            revert ReviewPeriodNotElapsed(index, milestone.reviewDeadline);
        }
        _settle(index, milestone, true);
    }

    /// @notice Settles the submitted current milestone using the client's EIP-712 approval. Callable by any relayer,
    /// who pays the gas. Contract clients are verified through ERC-1271.
    /// @dev The signature is accepted while `block.timestamp <= deadline`; this deadline is unrelated to the
    /// milestone's review deadline.
    function approveMilestoneBySignature(uint256 index, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        Milestone storage milestone = _currentMilestone(index, MilestoneStatus.Submitted);
        if (block.timestamp > deadline) revert ApprovalSignatureExpired(deadline);
        if (nonce != approvalNonce) revert InvalidApprovalNonce(nonce, approvalNonce);
        if (!SignatureChecker.isValidSignatureNowCalldata(client, approvalDigest(index, nonce, deadline), signature)) {
            revert InvalidApprovalSignature();
        }

        emit MilestoneApprovedBySignature(index, client, msg.sender, nonce);
        _settle(index, milestone, false);
    }

    /// @notice Terminates the order when the current milestone was not submitted by its delivery deadline, crediting
    /// every unsettled amount to the client. Allowed from `block.timestamp >= deliveryDeadline`.
    /// @dev Moves no tokens; the client, or anyone on its behalf, collects the credit with `claimPayout`.
    function reclaimAfterDeliveryExpiry() external nonReentrant {
        if (msg.sender != client) revert NotClient(msg.sender);
        uint256 index = currentMilestone;
        Milestone storage milestone = _currentMilestone(index, MilestoneStatus.Pending);
        if (block.timestamp < milestone.deliveryDeadline) {
            revert DeliveryPeriodNotElapsed(index, milestone.deliveryDeadline);
        }

        status = OrderStatus.Terminated;
        ++approvalNonce;
        uint256 credit = outstandingObligations;
        claimable[client] += credit;

        emit DeliveryExpired(index, credit);
    }

    /// @notice Disputes the submitted current milestone, which ends the order once the court rules. Allowed only while
    /// `block.timestamp < reviewDeadline`.
    /// @dev The court pulls its dispute fee from the client, so the client must approve `court.disputeFee()` of the
    /// court's stake token to the court. The order is `Disputed` and the nonce consumed before the court is called; a
    /// failed court call reverts the whole transaction.
    function openDispute(uint256 index) external nonReentrant {
        if (msg.sender != client) revert NotClient(msg.sender);
        Milestone storage milestone = _currentMilestone(index, MilestoneStatus.Submitted);
        if (block.timestamp >= milestone.reviewDeadline) revert ReviewPeriodElapsed(index, milestone.reviewDeadline);

        status = OrderStatus.Disputed;
        milestone.status = MilestoneStatus.Disputed;
        uint256 consumedNonce = approvalNonce++;
        uint256 id = court.openDispute(index);
        disputeId = id;

        emit DisputeOpened(index, id, consumedNonce);
    }

    /// @notice Terminates a disputed order with the ruling the court recorded for this order's dispute and credits
    /// the disputed and remaining amounts. Callable by anyone.
    /// @dev Moves no tokens; every party collects its credit with `claimPayout`.
    function applyRuling() external nonReentrant {
        if (status != OrderStatus.Disputed) revert InvalidOrderStatus(status);
        uint256 id = disputeId;
        (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(id);
        if (ruling == IArbitrationCourt.Ruling.None) revert RulingNotReady(id);

        uint256 disputed = _milestones[currentMilestone].amount;
        uint256 remaining = outstandingObligations - disputed;
        uint256 freelancerGross;
        if (ruling == IArbitrationCourt.Ruling.FreelancerWins) freelancerGross = disputed;
        else if (ruling == IArbitrationCourt.Ruling.Split) freelancerGross = disputed / 2;
        uint256 feeCredit = feeFor(freelancerGross);
        uint256 freelancerCredit = freelancerGross - feeCredit;
        uint256 clientCredit = disputed - freelancerGross + remaining;

        status = OrderStatus.Terminated;
        claimable[client] += clientCredit;
        claimable[freelancer] += freelancerCredit;
        claimable[feeRecipient] += feeCredit;

        emit RulingApplied(id, ruling, reason, clientCredit, freelancerCredit, feeCredit);
    }

    /// @notice Transfers the credit of `account` to `account`. Callable by anyone once the order is terminated.
    function claimPayout(address account) external nonReentrant returns (uint256 amount) {
        if (status != OrderStatus.Terminated) revert InvalidOrderStatus(status);
        amount = claimable[account];
        if (amount == 0) revert NothingToClaim(account);

        claimable[account] = 0;
        outstandingObligations -= amount;
        claimsPaid += amount;

        emit PayoutClaimed(account, amount);
        token.safeTransfer(account, amount);
    }

    /// @notice EIP-712 digest the client signs to approve `index` with `nonce` until `deadline`.
    function approvalDigest(uint256 index, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(APPROVE_MILESTONE_TYPEHASH, index, nonce, deadline)));
    }

    function milestoneCount() external view returns (uint256) {
        return _milestones.length;
    }

    function getMilestone(uint256 index) external view returns (Milestone memory) {
        return _milestones[index];
    }

    /// @notice Fee withheld from a milestone payment, rounded down in the freelancer's favor.
    function feeFor(uint256 amount) public view returns (uint256) {
        return Math.mulDiv(amount, feeBps, BPS_DENOMINATOR);
    }

    function _requireFundable() private view {
        if (msg.sender != client) revert NotClient(msg.sender);
        if (status != OrderStatus.Unfunded) revert InvalidOrderStatus(status);
    }

    function _deposit() private {
        status = OrderStatus.Active;
        outstandingObligations = totalAmount;
        _milestones[0].deliveryDeadline = _deliveryDeadlineFromNow();

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(client, address(this), totalAmount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != totalAmount) revert DepositMismatch(totalAmount, received);

        emit Funded(client, totalAmount);
    }

    function _currentMilestone(uint256 index, MilestoneStatus expected) private view returns (Milestone storage) {
        if (status != OrderStatus.Active) revert InvalidOrderStatus(status);
        if (index != currentMilestone) revert NotCurrentMilestone(index, currentMilestone);
        Milestone storage milestone = _milestones[index];
        if (milestone.status != expected) revert InvalidMilestoneStatus(index, milestone.status);
        return milestone;
    }

    function _settle(uint256 index, Milestone storage milestone, bool byTimeout) private {
        uint256 amount = milestone.amount;
        uint256 fee = feeFor(amount);
        uint256 freelancerPayout = amount - fee;

        milestone.status = MilestoneStatus.Settled;
        outstandingObligations -= amount;
        directPaid += amount;
        ++approvalNonce;
        currentMilestone = index + 1;
        bool completed = index + 1 == _milestones.length;
        if (completed) {
            status = OrderStatus.Completed;
        } else {
            _milestones[index + 1].deliveryDeadline = _deliveryDeadlineFromNow();
        }

        emit MilestoneSettled(index, msg.sender, byTimeout, freelancerPayout, fee);
        if (completed) emit OrderCompleted();

        if (fee != 0) token.safeTransfer(feeRecipient, fee);
        token.safeTransfer(freelancer, freelancerPayout);
    }

    function _deliveryDeadlineFromNow() private view returns (uint64) {
        return SafeCast.toUint64(block.timestamp + deliveryPeriod);
    }
}
