// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";

contract WorkOrderHandler is Test {
    bytes32 private constant APPROVE_MILESTONE_TYPEHASH =
        keccak256("ApproveMilestone(uint256 milestoneIndex,uint256 nonce,uint256 deadline)");
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    WorkOrder public immutable order;
    MockPermitUSDC public immutable token;
    uint256 private immutable clientKey;

    uint256 public settledTotal;
    uint256 public donatedTotal;
    uint256 public donatedBeforeFunding;

    uint256 public fundedDirectly;
    uint256 public fundedWithPermit;
    uint256 public fundedByPermitFallback;
    uint256 public settledByClient;
    uint256 public settledBySignature;
    uint256 public settledByTimeout;
    uint256 public rejectedStaleSignatures;
    uint256 public rejectedExpiredSubmissions;
    uint256 public rejectedEmptyClaims;
    uint256 public reclaimedAtIndex;
    uint256 public reclaims;
    uint256 public creditedTotal;
    uint256 public claimedTotal;
    uint256 public claims;

    constructor(WorkOrder order_, MockPermitUSDC token_, uint256 clientKey_) {
        order = order_;
        token = token_;
        clientKey = clientKey_;
    }

    function fund(uint256 path) external {
        if (order.status() != WorkOrder.OrderStatus.Unfunded) return;
        address client = order.client();
        uint256 total = order.totalAmount();
        uint256 deadline = block.timestamp + 1 hours;
        token.mint(client, total);

        path %= 3;
        if (path == 0) {
            vm.startPrank(client);
            token.approve(address(order), total);
            order.fund();
            vm.stopPrank();
            ++fundedDirectly;
        } else if (path == 1) {
            bytes32 structHash =
                keccak256(abi.encode(PERMIT_TYPEHASH, client, address(order), total, token.nonces(client), deadline));
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(clientKey, keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), structHash)));
            vm.prank(client);
            order.fundWithPermit(deadline, v, r, s);
            ++fundedWithPermit;
        } else {
            vm.startPrank(client);
            token.approve(address(order), total);
            order.fundWithPermit(deadline, 27, bytes32(0), bytes32(0));
            vm.stopPrank();
            ++fundedByPermitFallback;
        }
    }

    function submit() external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Pending)) return;
        uint256 index = order.currentMilestone();
        uint256 deliveryDeadline = order.getMilestone(index).deliveryDeadline;
        address freelancer = order.freelancer();
        if (block.timestamp >= deliveryDeadline) {
            vm.expectRevert(abi.encodeWithSelector(WorkOrder.DeliveryPeriodElapsed.selector, index, deliveryDeadline));
            ++rejectedExpiredSubmissions;
        }
        vm.prank(freelancer);
        order.submitMilestone(index);
    }

    function reclaim() external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Pending)) return;
        uint256 index = order.currentMilestone();
        if (block.timestamp < order.getMilestone(index).deliveryDeadline) return;
        address client = order.client();
        uint256 credit = order.outstandingObligations();
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();
        creditedTotal += credit;
        reclaimedAtIndex = index;
        ++reclaims;
    }

    function claimClientCredit(address caller) external {
        if (order.status() != WorkOrder.OrderStatus.Terminated) return;
        address client = order.client();
        if (order.claimable(client) == 0) return;
        uint256 balanceBefore = token.balanceOf(client);
        vm.prank(caller);
        order.claimPayout(client);
        claimedTotal += token.balanceOf(client) - balanceBefore;
        ++claims;
    }

    function claimWithoutCredit(bool freelancerAccount, address caller) external {
        if (order.status() != WorkOrder.OrderStatus.Terminated) return;
        address account = freelancerAccount ? order.freelancer() : order.feeRecipient();
        if (order.claimable(account) != 0) return;
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, account));
        vm.prank(caller);
        order.claimPayout(account);
        ++rejectedEmptyClaims;
    }

    function approve() external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        settledTotal += order.getMilestone(index).amount;
        ++settledByClient;
        address client = order.client();
        vm.prank(client);
        order.approveMilestone(index);
    }

    function approveBySignature(address relayer, uint256 validity) external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        uint256 nonce = order.approvalNonce();
        uint256 deadline = block.timestamp + bound(validity, 0, 30 days);
        bytes memory signature = _signApproval(index, nonce, deadline);
        settledTotal += order.getMilestone(index).amount;
        ++settledBySignature;
        vm.prank(relayer);
        order.approveMilestoneBySignature(index, nonce, deadline, signature);
    }

    function replayStaleSignature(address relayer) external {
        uint256 nonce = order.approvalNonce();
        if (nonce == 0 || !_currentIs(WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        uint256 deadline = block.timestamp;
        bytes memory signature = _signApproval(index, nonce - 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidApprovalNonce.selector, nonce - 1, nonce));
        vm.prank(relayer);
        order.approveMilestoneBySignature(index, nonce - 1, deadline, signature);
        ++rejectedStaleSignatures;
    }

    function finalize(address caller) external {
        if (!_currentIs(WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        WorkOrder.Milestone memory milestone = order.getMilestone(index);
        if (block.timestamp < milestone.reviewDeadline) return;
        settledTotal += milestone.amount;
        ++settledByTimeout;
        vm.prank(caller);
        order.finalizeMilestone(index);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 10 days));
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1e9 * 1e6);
        donatedTotal += amount;
        if (order.status() == WorkOrder.OrderStatus.Unfunded) donatedBeforeFunding += amount;
        token.mint(address(order), amount);
    }

    function settlementCount() external view returns (uint256) {
        return settledByClient + settledBySignature + settledByTimeout;
    }

    function fundingCount() external view returns (uint256) {
        return fundedDirectly + fundedWithPermit + fundedByPermitFallback;
    }

    function _signApproval(uint256 index, uint256 nonce, uint256 deadline) private view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("TrustWork")),
                keccak256(bytes("1")),
                block.chainid,
                address(order)
            )
        );
        bytes32 structHash = keccak256(abi.encode(APPROVE_MILESTONE_TYPEHASH, index, nonce, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(clientKey, keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _currentIs(WorkOrder.MilestoneStatus expected) private view returns (bool) {
        return order.status() == WorkOrder.OrderStatus.Active
            && order.getMilestone(order.currentMilestone()).status == expected;
    }
}
