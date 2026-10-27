// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {MockExecutingWallet} from "../mocks/MockExecutingWallet.sol";
import {MockEscrowOnlyClient, MockReceiverWallet} from "../mocks/MockReceiptWallets.sol";
import {ReputationTestBase} from "../utils/ReputationTestBase.sol";

abstract contract TrustWorkReputationReceiptsTest is ReputationTestBase {
    event Locked(uint256 tokenId);
    event ReceiptClaimed(
        address indexed order, ITrustWorkReputation.Role role, address indexed holder, uint256 tokenId
    );

    ITrustWorkReputation.Role internal constant CLIENT_ROLE = ITrustWorkReputation.Role.Client;
    ITrustWorkReputation.Role internal constant FREELANCER_ROLE = ITrustWorkReputation.Role.Freelancer;
    bytes32 internal constant LOCKED_TOPIC = keccak256("Locked(uint256)");
    bytes32 internal constant UNLOCKED_TOPIC = keccak256("Unlocked(uint256)");
    bytes32 internal constant RECEIPT_CLAIMED_TOPIC = keccak256("ReceiptClaimed(address,uint8,address,uint256)");

    /// @dev RR-01, RR-05, RR-06: both roles claim for every eligible outcome; exact IDs, ownership, events and
    /// unchanged registration facts.
    function test_Claim_BothRolesForEveryOutcome() public {
        for (uint256 o; o < 7; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory s = _scenario(o);
            reputation.register(address(s.order));
            bytes32 before = _registrationState(address(s.order));
            (, uint64 registeredAt,) = reputation.records(address(s.order));

            uint256 clientId = _claimAndCheckEvents(address(s.order), client, CLIENT_ROLE);
            _assertClaimBits(address(s.order), 1);
            uint256 freelancerId = _claimAndCheckEvents(address(s.order), freelancer, FREELANCER_ROLE);
            _assertClaimBits(address(s.order), 3);

            assertEq(clientId, _expectedId(address(s.order), 0));
            assertEq(freelancerId, _expectedId(address(s.order), 1));
            assertEq(reputation.ownerOf(clientId), client);
            assertEq(reputation.ownerOf(freelancerId), freelancer);
            assertEq(reputation.balanceOf(client), 1);
            assertEq(reputation.balanceOf(freelancer), 1);
            _assertReceiptOf(clientId, address(s.order), CLIENT_ROLE);
            _assertReceiptOf(freelancerId, address(s.order), FREELANCER_ROLE);
            assertTrue(reputation.locked(clientId));
            assertTrue(reputation.locked(freelancerId));
            assertEq(_registrationState(address(s.order)), before);
            (ITrustWorkReputation.Outcome outcome, uint64 registeredAtAfter,) = reputation.records(address(s.order));
            assertEq(uint256(outcome), uint256(s.outcome));
            assertEq(registeredAtAfter, registeredAt);
            vm.revertToState(state);
        }
    }

    /// @dev RG-05: nobody but the role holder can claim; fee-recipient overlap grants nothing extra.
    function test_RevertWhen_ClaimedByNonHolder() public {
        Scenario memory s = _ruled(_defaultAmounts(), 1, Outcome.ClientMajority);
        reputation.register(address(s.order));
        address[3] memory others = [client, feeRecipient, stranger];
        for (uint256 i; i < 3; ++i) {
            _expectNotHolder(address(s.order), FREELANCER_ROLE, others[i]);
        }
        address[3] memory notClients = [freelancer, feeRecipient, stranger];
        for (uint256 i; i < 3; ++i) {
            _expectNotHolder(address(s.order), CLIENT_ROLE, notClients[i]);
        }
        assertEq(reputation.balanceOf(freelancer), 0);
        assertEq(reputation.balanceOf(client), 0);
        _assertClaimBits(address(s.order), 0);

        address[2] memory overlaps = [client, freelancer];
        for (uint256 i; i < 2; ++i) {
            Scenario memory overlap = _ruledWith(overlaps[i], _defaultAmounts(), 1, Outcome.FreelancerMajority);
            reputation.register(address(overlap.order));
            vm.prank(client);
            reputation.claimReceipt(address(overlap.order), CLIENT_ROLE);
            vm.prank(freelancer);
            reputation.claimReceipt(address(overlap.order), FREELANCER_ROLE);
            _expectAlreadyClaimed(address(overlap.order), CLIENT_ROLE, client);
            _expectAlreadyClaimed(address(overlap.order), FREELANCER_ROLE, freelancer);
            _expectNotHolder(address(overlap.order), overlaps[i] == client ? FREELANCER_ROLE : CLIENT_ROLE, overlaps[i]);
        }
        assertEq(reputation.balanceOf(client), 2);
        assertEq(reputation.balanceOf(freelancer), 2);
    }

    /// @dev RR-02, RR-03, RR-06: one lifetime receipt per pair; burning neither clears the bit nor allows reissue.
    function test_RevertWhen_ClaimedTwiceBeforeOrAfterBurn() public {
        Scenario memory s = _completed(_defaultAmounts());
        reputation.register(address(s.order));
        uint256 id = _claim(address(s.order), client, CLIENT_ROLE);
        _expectAlreadyClaimed(address(s.order), CLIENT_ROLE, client);
        bytes32 before = _registrationState(address(s.order));

        vm.prank(client);
        reputation.burn(id);
        _assertClaimBits(address(s.order), 1);
        _expectAlreadyClaimed(address(s.order), CLIENT_ROLE, client);
        assertEq(_registrationState(address(s.order)), before);
        assertEq(reputation.balanceOf(client), 0);
        _expectNonexistent(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        reputation.ownerOf(id);
    }

    /// @dev RR-04: IDs are distinct across many orders and both roles; `receiptOf` inverts them.
    function test_ReceiptIds_DistinctAcrossOrders() public {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 5; ++i) {
            Scenario memory s = _completed(_defaultAmounts());
            reputation.register(address(s.order));
            ids[2 * i] = _claim(address(s.order), client, CLIENT_ROLE);
            ids[2 * i + 1] = _claim(address(s.order), freelancer, FREELANCER_ROLE);
            _assertReceiptOf(ids[2 * i], address(s.order), CLIENT_ROLE);
            _assertReceiptOf(ids[2 * i + 1], address(s.order), FREELANCER_ROLE);
        }
        for (uint256 i; i < 10; ++i) {
            for (uint256 j; j < i; ++j) {
                assertTrue(ids[i] != ids[j]);
            }
        }
        assertEq(reputation.balanceOf(client), 5);
        assertEq(reputation.balanceOf(freelancer), 5);
    }

    /// @dev RR-07: claims need a registered order; nonexistent IDs have no decoding, including aliasing high bits.
    function test_RevertWhen_ClaimUnregisteredOrDecodeNonexistent() public {
        Scenario memory s = _completed(_defaultAmounts());
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NotRegistered.selector, address(s.order)));
        vm.prank(client);
        reputation.claimReceipt(address(s.order), CLIENT_ROLE);
        assertEq(reputation.receiptId(address(s.order), CLIENT_ROLE), _expectedId(address(s.order), 0));
        _expectNonexistent(reputation.receiptId(address(s.order), CLIENT_ROLE));

        reputation.register(address(s.order));
        uint256 id = _claim(address(s.order), client, CLIENT_ROLE);
        _expectNonexistent(id | (uint256(1) << 161));
        _expectNonexistent(id | (uint256(1) << 255));
        _expectNonexistent(id ^ 1);
        _expectNonexistent(0);
        _expectNonexistent(type(uint256).max);
    }

    /// @dev RT-01, RT-02: every transfer entry point fails; ownership never changes and no transfer can mint.
    function test_RevertWhen_TransferAttempted() public {
        Scenario memory s = _completed(_defaultAmounts());
        reputation.register(address(s.order));
        uint256 id = _claim(address(s.order), client, CLIENT_ROLE);
        bytes memory locked = abi.encodeWithSelector(ITrustWorkReputation.ReceiptLocked.selector, id);
        address[2] memory recipients = [stranger, client];
        for (uint256 r; r < 2; ++r) {
            _expectTransferReverts(client, client, recipients[r], id, locked);
        }
        _expectTransferReverts(
            client,
            client,
            address(0),
            id,
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0))
        );
        _expectTransferReverts(
            stranger,
            client,
            stranger,
            id,
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, id)
        );
        assertEq(reputation.ownerOf(id), client);
        assertEq(reputation.balanceOf(client), 1);

        uint256 unminted = reputation.receiptId(address(s.order), FREELANCER_ROLE);
        _expectTransferReverts(
            freelancer,
            address(0),
            freelancer,
            unminted,
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted)
        );
        _expectNonexistent(unminted);
        assertEq(reputation.balanceOf(freelancer), 0);

        vm.prank(client);
        reputation.burn(id);
        _expectTransferReverts(
            client, client, stranger, id, abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id)
        );
        _expectNonexistent(id);
    }

    /// @dev RT-03: approvals are disabled; queries report no approval.
    function test_RevertWhen_ApprovalAttempted() public {
        Scenario memory s = _completed(_defaultAmounts());
        reputation.register(address(s.order));
        uint256 id = _claim(address(s.order), client, CLIENT_ROLE);
        address[2] memory callers = [client, stranger];
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(ITrustWorkReputation.ApprovalsDisabled.selector);
            vm.prank(callers[i]);
            reputation.approve(stranger, id);
            vm.expectRevert(ITrustWorkReputation.ApprovalsDisabled.selector);
            vm.prank(callers[i]);
            reputation.setApprovalForAll(stranger, true);
        }
        assertEq(reputation.getApproved(id), address(0));
        assertFalse(reputation.isApprovedForAll(client, stranger));
        uint256 unminted = reputation.receiptId(address(s.order), FREELANCER_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        reputation.getApproved(unminted);
    }

    /// @dev RT-04, RT-05: holder-only burn; afterwards the ID is gone everywhere and nothing else changes.
    function test_Burn_HolderOnlyAndPermanent() public {
        Scenario memory s = _ruled(_defaultAmounts(), 1, Outcome.NoPanel);
        reputation.register(address(s.order));
        uint256 id = _claim(address(s.order), freelancer, FREELANCER_ROLE);
        bytes32 before = _registrationState(address(s.order));
        bytes32 escrowBefore = _escrowState(s.order);

        address[3] memory others = [client, feeRecipient, stranger];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, others[i], id));
            vm.prank(others[i]);
            reputation.burn(id);
        }

        vm.expectEmit(address(reputation));
        emit IERC721.Transfer(freelancer, address(0), id);
        vm.prank(freelancer);
        reputation.burn(id);

        assertEq(reputation.balanceOf(freelancer), 0);
        _expectNonexistent(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        reputation.ownerOf(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        reputation.tokenURI(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        vm.prank(freelancer);
        reputation.burn(id);
        uint256 unminted = reputation.receiptId(address(s.order), CLIENT_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        vm.prank(client);
        reputation.burn(unminted);

        _assertClaimBits(address(s.order), 2);
        assertEq(_registrationState(address(s.order)), before);
        assertEq(_escrowState(s.order), escrowBefore);
        _expectAlreadyClaimed(address(s.order), FREELANCER_ROLE, freelancer);
    }

    /// @dev RC-01 … RC-04.
    function test_Interfaces_MetadataAndLockStatus() public {
        assertEq(type(IERC5192).interfaceId, bytes4(0xb45a3c0e));
        assertEq(type(IERC721).interfaceId, bytes4(0x80ac58cd));
        assertEq(type(IERC721Metadata).interfaceId, bytes4(0x5b5e139f));
        assertEq(type(IERC165).interfaceId, bytes4(0x01ffc9a7));
        assertTrue(reputation.supportsInterface(0x01ffc9a7));
        assertTrue(reputation.supportsInterface(0x80ac58cd));
        assertTrue(reputation.supportsInterface(0x5b5e139f));
        assertTrue(reputation.supportsInterface(0xb45a3c0e));
        assertFalse(reputation.supportsInterface(0xffffffff));
        assertFalse(reputation.supportsInterface(0x780e9d63));
        assertFalse(reputation.supportsInterface(0x12345678));
        assertEq(reputation.name(), "TrustWork Receipt");
        assertEq(reputation.symbol(), "TWR");

        Scenario memory s = _completed(_defaultAmounts());
        reputation.register(address(s.order));
        uint256 id = _claim(address(s.order), client, CLIENT_ROLE);
        assertTrue(reputation.locked(id));
        assertEq(reputation.tokenURI(id), "");
        uint256 unminted = reputation.receiptId(address(s.order), FREELANCER_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        reputation.locked(unminted);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        reputation.tokenURI(unminted);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOwner.selector, address(0)));
        reputation.balanceOf(address(0));
    }

    /// @dev RW-01: a contract client without `IERC721Receiver` claims through its own wallet call.
    function test_ContractWalletWithoutReceiver_ClaimsReceipt() public {
        MockExecutingWallet wallet = new MockExecutingWallet(client);
        WorkOrder order = _walletOrder(address(wallet));
        reputation.register(address(order));
        vm.prank(client);
        bytes memory result = wallet.execute(
            address(reputation), abi.encodeCall(ITrustWorkReputation.claimReceipt, (address(order), CLIENT_ROLE))
        );
        uint256 id = abi.decode(result, (uint256));
        assertEq(reputation.ownerOf(id), address(wallet));
        assertTrue(reputation.locked(id));
        _expectNotHolder(address(order), CLIENT_ROLE, client);
    }

    /// @dev RW-02: receiver callbacks that would revert or re-enter are never called.
    function test_ReceiverCallbackNeverCalled() public {
        for (uint256 m; m < 2; ++m) {
            MockReceiverWallet wallet = new MockReceiverWallet(client, MockReceiverWallet.Mode(m));
            WorkOrder order = _walletOrder(address(wallet));
            reputation.register(address(order));
            vm.prank(client);
            bytes memory result = wallet.execute(
                address(reputation), abi.encodeCall(ITrustWorkReputation.claimReceipt, (address(order), CLIENT_ROLE))
            );
            uint256 id = abi.decode(result, (uint256));
            assertEq(wallet.receiverCalls(), 0);
            assertEq(reputation.ownerOf(id), address(wallet));
            assertEq(reputation.balanceOf(address(wallet)), 1);
            _assertClaimBits(address(order), 1);
        }
    }

    /// @dev RW-03: a contract client that cannot call the reputation contract cannot be claimed for, while
    /// registration, escrow and payout claims keep working.
    function test_EscrowOnlyContractClient_CannotBeClaimedFor() public {
        MockEscrowOnlyClient escrowClient = new MockEscrowOnlyClient(client);
        vm.prank(client);
        WorkOrder order = escrowClient.createOrder(
            factory, freelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        ledger.trackOrder(address(order));
        paymentToken.mint(address(escrowClient), order.totalAmount());
        vm.prank(client);
        escrowClient.fund(order);
        _submit(order, 0);
        vm.prank(client);
        escrowClient.approveMilestone(order, 0);
        vm.warp(order.getMilestone(1).deliveryDeadline);
        vm.prank(client);
        escrowClient.reclaim(order);

        reputation.register(address(order));
        address[3] memory others = [client, freelancer, stranger];
        for (uint256 i; i < 3; ++i) {
            _expectNotHolder(address(order), CLIENT_ROLE, others[i]);
        }
        assertEq(order.claimPayout(address(escrowClient)), 3000 * USDC);
        assertEq(paymentToken.balanceOf(address(escrowClient)), 3000 * USDC);
        assertEq(reputation.balanceOf(address(escrowClient)), 0);
        _claim(address(order), freelancer, FREELANCER_ROLE);
        _assertClaimBits(address(order), 2);
        assertEq(
            uint256(reputation.factsOf(address(order)).outcome), uint256(ITrustWorkReputation.Outcome.DeliveryExpired)
        );
    }

    /// @dev RU-01 (receipt part): claims and burns move no payment or stake token and change no escrow, court or
    /// registry state.
    function test_Receipts_LeaveEscrowCourtAndRegistryUnchanged() public {
        for (uint256 o; o < 7; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory s = _scenario(o);
            reputation.register(address(s.order));
            bytes32 before = _escrowState(s.order);
            vm.recordLogs();
            uint256 clientId = _claim(address(s.order), client, CLIENT_ROLE);
            uint256 freelancerId = _claim(address(s.order), freelancer, FREELANCER_ROLE);
            vm.prank(client);
            reputation.burn(clientId);
            vm.prank(freelancer);
            reputation.burn(freelancerId);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                bool erc20 = logs[i].emitter == address(paymentToken) || logs[i].emitter == address(stakeToken);
                assertFalse(erc20, "receipt operation touched an escrow or stake token");
            }
            assertEq(_escrowState(s.order), before);
            vm.revertToState(state);
        }
    }

    /// @dev RU-03 (receipt part): order and court claims succeed before and after receipt claims, in either order.
    function test_Receipts_DoNotAffectFinancialClaims() public {
        for (uint256 first; first < 2; ++first) {
            uint256 state = vm.snapshotState();
            Scenario memory s = _ruled(_defaultAmounts(), 1, Outcome.FreelancerMajority);
            reputation.register(address(s.order));
            uint256 freelancerCredit = s.order.claimable(freelancer);
            if (first == 0) _claim(address(s.order), freelancer, FREELANCER_ROLE);
            assertEq(s.order.claimPayout(freelancer), freelancerCredit);
            _claimCourtCredits(s.disputeId);
            if (first == 1) _claim(address(s.order), freelancer, FREELANCER_ROLE);
            _claim(address(s.order), client, CLIENT_ROLE);
            assertEq(s.order.claimPayout(client), 500 * USDC);
            assertEq(s.order.outstandingObligations(), s.order.claimable(feeRecipient));
            vm.revertToState(state);
        }
    }

    /// @dev Scenario `o`: 0 Completed, 1 DeliveryExpired, 2–6 the rulings FreelancerWins, ClientWins, Split by tie,
    /// Split by zero reveals and NoPanel at the middle milestone.
    function _scenario(uint256 o) internal returns (Scenario memory) {
        if (o == 0) return _completed(_defaultAmounts());
        if (o == 1) return _expired(_defaultAmounts(), 1);
        return _ruled(_defaultAmounts(), 1, Outcome(o - 2));
    }

    function _claim(address order, address holder, ITrustWorkReputation.Role role) internal returns (uint256 id) {
        vm.prank(holder);
        id = reputation.claimReceipt(order, role);
    }

    /// @dev Claims and requires exactly `Transfer(0, holder, id)`, `Locked(id)`, `ReceiptClaimed`, in that order.
    function _claimAndCheckEvents(address order, address holder, ITrustWorkReputation.Role role)
        internal
        returns (uint256 id)
    {
        vm.recordLogs();
        id = _claim(order, holder, role);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(logs[i].emitter, address(reputation));
            assertTrue(logs[i].topics[0] != UNLOCKED_TOPIC);
        }
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(holder))));
        assertEq(logs[0].topics[3], bytes32(id));
        assertEq(logs[1].topics[0], LOCKED_TOPIC);
        assertEq(abi.decode(logs[1].data, (uint256)), id);
        assertEq(logs[2].topics[0], RECEIPT_CLAIMED_TOPIC);
        assertEq(logs[2].topics[1], bytes32(uint256(uint160(order))));
        assertEq(logs[2].topics[2], bytes32(uint256(uint160(holder))));
        (ITrustWorkReputation.Role loggedRole, uint256 loggedId) =
            abi.decode(logs[2].data, (ITrustWorkReputation.Role, uint256));
        assertEq(uint256(loggedRole), uint256(role));
        assertEq(loggedId, id);
    }

    function _expectedId(address order, uint256 role) internal pure returns (uint256) {
        return uint256(uint160(order)) * 2 + role;
    }

    function _assertReceiptOf(uint256 id, address order, ITrustWorkReputation.Role role) internal view {
        (address decodedOrder, ITrustWorkReputation.Role decodedRole) = reputation.receiptOf(id);
        assertEq(decodedOrder, order);
        assertEq(uint256(decodedRole), uint256(role));
    }

    function _assertClaimBits(address order, uint8 expected) internal view {
        (,, uint8 receiptsClaimed) = reputation.records(order);
        assertEq(receiptsClaimed, expected);
    }

    function _expectNotHolder(address order, ITrustWorkReputation.Role role, address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NotRoleHolder.selector, order, role, caller));
        vm.prank(caller);
        reputation.claimReceipt(order, role);
    }

    function _expectAlreadyClaimed(address order, ITrustWorkReputation.Role role, address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.ReceiptAlreadyClaimed.selector, order, role));
        vm.prank(caller);
        reputation.claimReceipt(order, role);
    }

    function _expectNonexistent(uint256 id) internal {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        reputation.receiptOf(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        reputation.locked(id);
    }

    /// @dev `transferFrom` and both `safeTransferFrom` overloads, each in its own state snapshot.
    function _expectTransferReverts(address caller, address from, address to, uint256 id, bytes memory reason)
        internal
    {
        bytes[3] memory calls = [
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, bytes("data"))
        ];
        for (uint256 i; i < 3; ++i) {
            vm.prank(caller);
            (bool success, bytes memory returned) = address(reputation).call(calls[i]);
            assertFalse(success);
            assertEq(returned, reason);
        }
    }

    function _registrationState(address order) internal view returns (bytes32) {
        (ITrustWorkReputation.Outcome outcome, uint64 registeredAt,) = reputation.records(order);
        return keccak256(
            abi.encode(
                outcome,
                registeredAt,
                reputation.factsOf(order),
                reputation.statsOf(client, CLIENT_ROLE),
                reputation.statsOf(freelancer, FREELANCER_ROLE),
                reputation.ordersOf(client, CLIENT_ROLE, 0, type(uint256).max),
                reputation.ordersOf(freelancer, FREELANCER_ROLE, 0, type(uint256).max)
            )
        );
    }

    /// @dev Completed order whose client is `wallet`, created and funded through the wallet's own `execute`.
    function _walletOrder(address wallet) internal returns (WorkOrder order) {
        vm.prank(client);
        bytes memory created = MockExecutingWallet(wallet)
            .execute(
                address(factory),
                abi.encodeWithSignature(
                    "createWorkOrder(address,address,address,uint256,uint256,uint256,uint256[])",
                    freelancer,
                    address(paymentToken),
                    feeRecipient,
                    FEE_BPS,
                    REVIEW_PERIOD,
                    DELIVERY_PERIOD,
                    _defaultAmounts()
                )
            );
        order = abi.decode(created, (WorkOrder));
        ledger.trackOrder(address(order));
        uint256 total = order.totalAmount();
        paymentToken.mint(wallet, total);
        vm.startPrank(client);
        MockExecutingWallet(wallet)
            .execute(address(paymentToken), abi.encodeWithSignature("approve(address,uint256)", address(order), total));
        MockExecutingWallet(wallet).execute(address(order), abi.encodeCall(WorkOrder.fund, ()));
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            _submit(order, i);
            vm.prank(client);
            MockExecutingWallet(wallet).execute(address(order), abi.encodeCall(WorkOrder.approveMilestone, (i)));
        }
    }
}

contract TrustWorkReputationReceiptsSharedTokenTest is TrustWorkReputationReceiptsTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkReputationReceiptsSplitTokenTest is TrustWorkReputationReceiptsTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
