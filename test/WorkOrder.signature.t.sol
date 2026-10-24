// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WorkOrder} from "../src/WorkOrder.sol";
import {WorkOrderTestBase} from "./utils/WorkOrderTestBase.sol";
import {BlocklistToken} from "./mocks/BlocklistToken.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract WorkOrderSignatureTest is WorkOrderTestBase {
    event MilestoneApprovedBySignature(
        uint256 indexed index, address indexed client, address indexed relayer, uint256 nonce
    );
    event MilestoneSettled(
        uint256 indexed index, address indexed settledBy, bool byTimeout, uint256 freelancerPayout, uint256 fee
    );

    address internal relayer = makeAddr("relayer");
    uint256 internal deadline;
    WorkOrder internal order;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 days;
        order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
    }

    function test_SignedApproval_SettlesWhenRelayedByUnrelatedAccount() public {
        bytes memory signature = _signApproval(clientKey, order, 0, 0, deadline);

        vm.expectEmit(address(order));
        emit MilestoneApprovedBySignature(0, client, relayer, 0);
        vm.expectEmit(address(order));
        emit MilestoneSettled(0, relayer, false, 975 * USDC, 25 * USDC);
        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, deadline, signature);

        assertEq(usdc.balanceOf(freelancer), 975 * USDC);
        assertEq(usdc.balanceOf(feeRecipient), 25 * USDC);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(order.approvalNonce(), 1);
        assertEq(order.currentMilestone(), 1);
        assertEq(order.outstandingObligations(), 3000 * USDC);
        assertEq(uint256(order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Settled));
    }

    function test_SignedApproval_CompletesOrder() public {
        for (uint256 i; i < 3; ++i) {
            if (i > 0) _submit(order, i);
            bytes memory signature = _signApproval(clientKey, order, i, i, deadline);
            vm.prank(relayer);
            order.approveMilestoneBySignature(i, i, deadline, signature);
        }

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Completed));
        assertEq(order.approvalNonce(), 3);
        assertEq(order.outstandingObligations(), 0);
        assertEq(usdc.balanceOf(freelancer), 3900 * USDC);
        assertEq(usdc.balanceOf(feeRecipient), 100 * USDC);
    }

    function test_ApprovalDigest_MatchesIndependentConstruction() public view {
        assertEq(order.approvalDigest(0, 0, deadline), _expectedApprovalDigest(address(order), 0, 0, deadline));
        assertEq(order.APPROVE_MILESTONE_TYPEHASH(), APPROVE_MILESTONE_TYPEHASH);

        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            order.eip712Domain();
        assertEq(name, "TrustWork");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(order));
    }

    function testFuzz_ApprovalDigest_MatchesIndependentConstruction(uint256 index, uint256 nonce, uint256 deadline_)
        public
        view
    {
        assertEq(
            order.approvalDigest(index, nonce, deadline_),
            _expectedApprovalDigest(address(order), index, nonce, deadline_)
        );
    }

    function test_RevertWhen_SignedByWrongSigner() public {
        (, uint256 freelancerKey) = makeAddrAndKey("freelancer");
        (, uint256 strangerKey) = makeAddrAndKey("stranger");

        _expectInvalidSignature(_signApproval(freelancerKey, order, 0, 0, deadline), 0, 0, deadline);
        _expectInvalidSignature(_signApproval(strangerKey, order, 0, 0, deadline), 0, 0, deadline);
        _assertUnsettled(order, 0);
    }

    function test_RevertWhen_SignatureMalformed() public {
        bytes memory valid = _signApproval(clientKey, order, 0, 0, deadline);
        (bytes32 r, bytes32 s, uint8 v) = _split(valid);

        _expectInvalidSignature("", 0, 0, deadline);
        _expectInvalidSignature(abi.encodePacked(r, s), 0, 0, deadline);
        _expectInvalidSignature(abi.encodePacked(valid, uint8(0)), 0, 0, deadline);
        _expectInvalidSignature(abi.encodePacked(r, s, uint8(0)), 0, 0, deadline);
        _expectInvalidSignature(abi.encodePacked(bytes32(0), bytes32(0), v), 0, 0, deadline);

        uint8 flippedV = v == 27 ? 28 : 27;
        bytes32 highS = bytes32(SECP256K1_ORDER - uint256(s));
        _expectInvalidSignature(abi.encodePacked(r, highS, flippedV), 0, 0, deadline);

        _assertUnsettled(order, 0);
    }

    function test_RevertWhen_SignatureExpired() public {
        uint256 expiredDeadline = block.timestamp - 1;
        bytes memory signature = _signApproval(clientKey, order, 0, 0, expiredDeadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.ApprovalSignatureExpired.selector, expiredDeadline));
        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, expiredDeadline, signature);

        _assertUnsettled(order, 0);
    }

    function test_RevertWhen_SignatureUsedOneSecondAfterDeadline() public {
        bytes memory signature = _signApproval(clientKey, order, 0, 0, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.ApprovalSignatureExpired.selector, deadline));
        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, deadline, signature);
    }

    function test_SignedApproval_ValidExactlyAtDeadline() public {
        bytes memory signature = _signApproval(clientKey, order, 0, 0, deadline);
        vm.warp(deadline);

        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, deadline, signature);

        assertEq(order.approvalNonce(), 1);
    }

    function test_SignedApproval_DeadlineIndependentOfReviewDeadline() public {
        uint256 reviewDeadline = order.getMilestone(0).reviewDeadline;
        uint256 longDeadline = reviewDeadline + 30 days;
        bytes memory signature = _signApproval(clientKey, order, 0, 0, longDeadline);
        vm.warp(reviewDeadline + 1 days);

        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, longDeadline, signature);

        assertEq(order.currentMilestone(), 1);
    }

    function test_RevertWhen_NonceIncorrect() public {
        bytes memory signature = _signApproval(clientKey, order, 0, 1, deadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidApprovalNonce.selector, 1, 0));
        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 1, deadline, signature);

        _assertUnsettled(order, 0);
    }

    function test_RevertWhen_NonceAlreadyConsumed() public {
        bytes memory first = _signApproval(clientKey, order, 0, 0, deadline);
        bytes memory nextWithStaleNonce = _signApproval(clientKey, order, 1, 0, deadline);
        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, deadline, first);
        _submit(order, 1);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotCurrentMilestone.selector, 0, 1));
        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, deadline, first);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidApprovalNonce.selector, 0, 1));
        vm.prank(relayer);
        order.approveMilestoneBySignature(1, 0, deadline, nextWithStaleNonce);

        _assertUnsettled(order, 1);
        assertEq(order.approvalNonce(), 1);
    }

    function test_RevertWhen_SignedFieldsAltered() public {
        _expectInvalidSignature(_signApproval(clientKey, order, 1, 0, deadline), 0, 0, deadline);
        _expectInvalidSignature(_signApproval(clientKey, order, 0, 1, deadline), 0, 0, deadline);
        _expectInvalidSignature(_signApproval(clientKey, order, 0, 0, deadline + 1), 0, 0, deadline);

        _assertUnsettled(order, 0);
    }

    function test_RevertWhen_ReplayedOnAnotherWorkOrder() public {
        WorkOrder other = _createDefaultOrder();
        _fund(other);
        _submit(other, 0);
        bytes memory signatureForOrder = _signApproval(clientKey, order, 0, 0, deadline);

        vm.expectRevert(WorkOrder.InvalidApprovalSignature.selector);
        vm.prank(relayer);
        other.approveMilestoneBySignature(0, 0, deadline, signatureForOrder);

        _assertUnsettled(other, 0);
        assertTrue(other.approvalDigest(0, 0, deadline) != order.approvalDigest(0, 0, deadline));
    }

    function test_RevertWhen_ReplayedOnAnotherChain() public {
        bytes memory signature = _signApproval(clientKey, order, 0, 0, deadline);
        bytes32 digestOnOriginalChain = order.approvalDigest(0, 0, deadline);

        vm.chainId(8453);

        assertTrue(order.approvalDigest(0, 0, deadline) != digestOnOriginalChain);
        assertEq(order.approvalDigest(0, 0, deadline), _expectedApprovalDigest(address(order), 0, 0, deadline));
        vm.expectRevert(WorkOrder.InvalidApprovalSignature.selector);
        vm.prank(relayer);
        order.approveMilestoneBySignature(0, 0, deadline, signature);

        _assertUnsettled(order, 0);
    }

    function test_RevertWhen_SignedApprovalBeforeFunding() public {
        WorkOrder unfunded = _createDefaultOrder();
        bytes memory signature = _signApproval(clientKey, unfunded, 0, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Unfunded));
        vm.prank(relayer);
        unfunded.approveMilestoneBySignature(0, 0, deadline, signature);
    }

    function test_RevertWhen_SignedApprovalBeforeSubmission() public {
        WorkOrder unsubmitted = _createDefaultOrder();
        _fund(unsubmitted);
        bytes memory signature = _signApproval(clientKey, unsubmitted, 0, 0, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(WorkOrder.InvalidMilestoneStatus.selector, 0, WorkOrder.MilestoneStatus.Pending)
        );
        vm.prank(relayer);
        unsubmitted.approveMilestoneBySignature(0, 0, deadline, signature);

        assertEq(unsubmitted.approvalNonce(), 0);
    }

    function test_RevertWhen_SignedApprovalAfterCompletion() public {
        _approve(order, 0);
        _submit(order, 1);
        _approve(order, 1);
        _submit(order, 2);
        _approve(order, 2);
        bytes memory signature = _signApproval(clientKey, order, 2, 3, deadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Completed));
        vm.prank(relayer);
        order.approveMilestoneBySignature(2, 3, deadline, signature);

        assertEq(order.approvalNonce(), 3);
    }

    function test_DirectApproval_InvalidatesOutstandingSignature() public {
        bytes memory signatureForNext = _signApproval(clientKey, order, 1, 0, deadline);

        _approve(order, 0);
        assertEq(order.approvalNonce(), 1);
        _submit(order, 1);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidApprovalNonce.selector, 0, 1));
        vm.prank(relayer);
        order.approveMilestoneBySignature(1, 0, deadline, signatureForNext);
    }

    function test_TimeoutFinalization_InvalidatesOutstandingSignature() public {
        uint256 longDeadline = block.timestamp + 60 days;
        bytes memory signatureForNext = _signApproval(clientKey, order, 1, 0, longDeadline);

        vm.warp(order.getMilestone(0).reviewDeadline);
        vm.prank(stranger);
        order.finalizeMilestone(0);
        assertEq(order.approvalNonce(), 1);
        _submit(order, 1);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidApprovalNonce.selector, 0, 1));
        vm.prank(relayer);
        order.approveMilestoneBySignature(1, 0, longDeadline, signatureForNext);
    }

    function test_SignedApproval_ContractClientWithValidERC1271() public {
        (address walletSigner, uint256 walletSignerKey) = makeAddrAndKey("walletSigner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletSigner);
        WorkOrder walletOrder = _createWalletOrder(wallet);
        bytes memory signature = _signApproval(walletSignerKey, walletOrder, 0, 0, deadline);

        vm.expectEmit(address(walletOrder));
        emit MilestoneApprovedBySignature(0, address(wallet), relayer, 0);
        vm.prank(relayer);
        walletOrder.approveMilestoneBySignature(0, 0, deadline, signature);

        assertEq(usdc.balanceOf(freelancer), 975 * USDC);
        assertEq(walletOrder.approvalNonce(), 1);
    }

    function test_RevertWhen_ContractClientSignedByOtherKey() public {
        (address walletSigner,) = makeAddrAndKey("walletSigner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletSigner);
        WorkOrder walletOrder = _createWalletOrder(wallet);
        bytes memory signature = _signApproval(clientKey, walletOrder, 0, 0, deadline);

        vm.expectRevert(WorkOrder.InvalidApprovalSignature.selector);
        vm.prank(relayer);
        walletOrder.approveMilestoneBySignature(0, 0, deadline, signature);
    }

    function test_RevertWhen_ContractClientReturnsWrongMagicValue() public {
        (address walletSigner, uint256 walletSignerKey) = makeAddrAndKey("walletSigner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletSigner);
        WorkOrder walletOrder = _createWalletOrder(wallet);
        bytes memory signature = _signApproval(walletSignerKey, walletOrder, 0, 0, deadline);
        wallet.setMode(MockERC1271Wallet.Mode.WrongMagicValue);

        vm.expectRevert(WorkOrder.InvalidApprovalSignature.selector);
        vm.prank(relayer);
        walletOrder.approveMilestoneBySignature(0, 0, deadline, signature);

        _assertUnsettled(walletOrder, 0);
    }

    function test_RevertWhen_ContractClientValidatorReverts() public {
        (address walletSigner, uint256 walletSignerKey) = makeAddrAndKey("walletSigner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletSigner);
        WorkOrder walletOrder = _createWalletOrder(wallet);
        bytes memory signature = _signApproval(walletSignerKey, walletOrder, 0, 0, deadline);
        wallet.setMode(MockERC1271Wallet.Mode.Reverting);

        vm.expectRevert(WorkOrder.InvalidApprovalSignature.selector);
        vm.prank(relayer);
        walletOrder.approveMilestoneBySignature(0, 0, deadline, signature);

        _assertUnsettled(walletOrder, 0);
    }

    function test_RevertWhen_SignedApprovalPayoutFails() public {
        BlocklistToken token = new BlocklistToken();
        WorkOrder blockedOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        token.mint(client, blockedOrder.totalAmount());
        vm.startPrank(client);
        token.approve(address(blockedOrder), blockedOrder.totalAmount());
        blockedOrder.fund();
        vm.stopPrank();
        _submit(blockedOrder, 0);
        bytes memory signature = _signApproval(clientKey, blockedOrder, 0, 0, deadline);
        token.setBlocked(freelancer, true);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, freelancer));
        vm.prank(relayer);
        blockedOrder.approveMilestoneBySignature(0, 0, deadline, signature);

        _assertUnsettled(blockedOrder, 0);
        assertEq(blockedOrder.outstandingObligations(), 4000 * USDC);
        assertEq(token.balanceOf(address(blockedOrder)), 4000 * USDC);

        token.setBlocked(freelancer, false);
        vm.prank(relayer);
        blockedOrder.approveMilestoneBySignature(0, 0, deadline, signature);
        assertEq(blockedOrder.approvalNonce(), 1);
        assertEq(token.balanceOf(freelancer), 975 * USDC);
    }

    function test_Reentrancy_SignedApprovalDuringPayoutIsBlocked() public {
        ReentrantToken token = new ReentrantToken();
        WorkOrder reentrantOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        token.mint(client, reentrantOrder.totalAmount());
        vm.startPrank(client);
        token.approve(address(reentrantOrder), reentrantOrder.totalAmount());
        reentrantOrder.fund();
        vm.stopPrank();
        _submit(reentrantOrder, 0);

        bytes memory signature = _signApproval(clientKey, reentrantOrder, 0, 0, deadline);
        bytes memory nextSignature = _signApproval(clientKey, reentrantOrder, 1, 1, deadline);
        token.arm(
            address(reentrantOrder),
            abi.encodeCall(WorkOrder.approveMilestoneBySignature, (1, 1, deadline, nextSignature))
        );

        vm.prank(relayer);
        reentrantOrder.approveMilestoneBySignature(0, 0, deadline, signature);

        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertEq(
            token.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(reentrantOrder.approvalNonce(), 1);
        assertEq(reentrantOrder.currentMilestone(), 1);
        assertEq(token.balanceOf(freelancer), 975 * USDC);
    }

    function _createWalletOrder(MockERC1271Wallet wallet) private returns (WorkOrder walletOrder) {
        vm.prank(address(wallet));
        walletOrder = factory.createWorkOrder(
            freelancer,
            usdc,
            feeRecipient,
            DEFAULT_FEE_BPS,
            DEFAULT_REVIEW_PERIOD,
            DEFAULT_DELIVERY_PERIOD,
            _defaultAmounts()
        );
        usdc.mint(address(wallet), walletOrder.totalAmount());
        vm.startPrank(address(wallet));
        usdc.approve(address(walletOrder), walletOrder.totalAmount());
        walletOrder.fund();
        vm.stopPrank();
        _submit(walletOrder, 0);
    }

    function _expectInvalidSignature(bytes memory signature, uint256 index, uint256 nonce, uint256 deadline_) private {
        vm.expectRevert(WorkOrder.InvalidApprovalSignature.selector);
        vm.prank(relayer);
        order.approveMilestoneBySignature(index, nonce, deadline_, signature);
    }

    function _assertUnsettled(WorkOrder target, uint256 index) private view {
        assertEq(uint256(target.getMilestone(index).status), uint256(WorkOrder.MilestoneStatus.Submitted));
        assertEq(target.currentMilestone(), index);
        assertEq(target.approvalNonce(), index);
    }

    function _split(bytes memory signature) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
    }
}
