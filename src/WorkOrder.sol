// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title WorkOrder
/// @notice Escrow for one client-freelancer engagement paid in ordered milestones.
/// @dev Only tokens that move exactly the requested amount are supported. Fee-on-transfer tokens are
/// rejected at funding; rebasing tokens are unsupported and may leave the order unable to settle.
contract WorkOrder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum OrderStatus {
        Unfunded,
        Active,
        Completed
    }

    enum MilestoneStatus {
        Pending,
        Submitted,
        Settled
    }

    struct Milestone {
        uint256 amount;
        MilestoneStatus status;
        uint64 submittedAt;
        uint64 reviewDeadline;
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MAX_REVIEW_PERIOD = 30 days;

    address public immutable client;
    address public immutable freelancer;
    IERC20 public immutable token;
    address public immutable feeRecipient;
    uint256 public immutable feeBps;
    uint256 public immutable reviewPeriod;
    uint256 public immutable totalAmount;

    OrderStatus public status;
    uint256 public currentMilestone;
    /// @notice Funded milestone amounts not yet settled. Independent of the raw token balance.
    uint256 public outstandingObligations;

    Milestone[] private _milestones;

    event Funded(address indexed client, uint256 amount);
    event MilestoneSubmitted(uint256 indexed index, uint256 reviewDeadline);
    event MilestoneSettled(
        uint256 indexed index, address indexed settledBy, bool byTimeout, uint256 freelancerPayout, uint256 fee
    );
    event OrderCompleted();

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

    constructor(
        address client_,
        address freelancer_,
        IERC20 token_,
        address feeRecipient_,
        uint256 feeBps_,
        uint256 reviewPeriod_,
        uint256[] memory milestoneAmounts
    ) {
        if (
            client_ == address(0) || freelancer_ == address(0) || feeRecipient_ == address(0)
                || address(token_) == address(0)
        ) revert ZeroAddress();
        if (client_ == freelancer_) revert ClientIsFreelancer();
        if (address(token_).code.length == 0) revert TokenHasNoCode(address(token_));
        if (milestoneAmounts.length == 0) revert NoMilestones();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (reviewPeriod_ == 0 || reviewPeriod_ > MAX_REVIEW_PERIOD) revert InvalidReviewPeriod(reviewPeriod_);

        uint256 total;
        for (uint256 i; i < milestoneAmounts.length; ++i) {
            if (milestoneAmounts[i] == 0) revert ZeroMilestoneAmount(i);
            total += milestoneAmounts[i];
            _milestones.push(
                Milestone({
                    amount: milestoneAmounts[i], status: MilestoneStatus.Pending, submittedAt: 0, reviewDeadline: 0
                })
            );
        }

        client = client_;
        freelancer = freelancer_;
        token = token_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        reviewPeriod = reviewPeriod_;
        totalAmount = total;
    }

    /// @notice Deposits the full budget from the client. Requires prior ERC-20 approval of `totalAmount`.
    /// @dev Reverts unless the order's balance grows by exactly `totalAmount`, which rejects
    /// fee-on-transfer tokens. Tokens already held by the order do not affect the check.
    function fund() external nonReentrant {
        if (msg.sender != client) revert NotClient(msg.sender);
        if (status != OrderStatus.Unfunded) revert InvalidOrderStatus(status);

        status = OrderStatus.Active;
        outstandingObligations = totalAmount;

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), totalAmount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != totalAmount) revert DepositMismatch(totalAmount, received);

        emit Funded(msg.sender, totalAmount);
    }

    /// @notice Marks the current milestone as delivered and starts its review period.
    function submitMilestone(uint256 index) external nonReentrant {
        if (msg.sender != freelancer) revert NotFreelancer(msg.sender);
        Milestone storage milestone = _currentMilestone(index, MilestoneStatus.Pending);

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
        currentMilestone = index + 1;
        bool completed = index + 1 == _milestones.length;
        if (completed) status = OrderStatus.Completed;

        emit MilestoneSettled(index, msg.sender, byTimeout, freelancerPayout, fee);
        if (completed) emit OrderCompleted();

        if (fee != 0) token.safeTransfer(feeRecipient, fee);
        token.safeTransfer(freelancer, freelancerPayout);
    }
}
