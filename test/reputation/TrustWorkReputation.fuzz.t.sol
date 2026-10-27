// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {ReputationTestBase} from "../utils/ReputationTestBase.sol";

abstract contract TrustWorkReputationFuzzTest is ReputationTestBase {
    /// @dev RF-01: sampled amounts, fee, terminal path and position; facts match the independent model and each role's
    /// counters change by exactly one outcome.
    function testFuzz_FactsMatchModel(uint256[3] memory raw, uint256 bps, uint256 pathSeed, uint256 positionSeed)
        public
    {
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            amounts[i] = bound(raw[i], 1, 1e30);
        }
        Scenario memory s = _sampled(amounts, bound(bps, 0, 1000), pathSeed % 7, positionSeed % 3);
        ITrustWorkReputation.Stats memory clientBefore = reputation.statsOf(client, ITrustWorkReputation.Role.Client);

        ITrustWorkReputation.OrderFacts memory facts = _register(s);
        assertEq(facts.freelancerAwarded + facts.clientReturned, facts.totalAmount);

        ITrustWorkReputation.Stats memory clientAfter = reputation.statsOf(client, ITrustWorkReputation.Role.Client);
        assertEq(clientAfter.registered, clientBefore.registered + 1);
        assertEq(clientAfter.milestonesSettled, clientBefore.milestonesSettled + s.settled);
        _assertStats(freelancer, ITrustWorkReputation.Role.Freelancer, _one(s.outcome), s.settled);
    }

    /// @dev RF-02: any claim schedule before registration gives the same classification, facts and counters, and
    /// `registeredAt` is the registration's own timestamp.
    function testFuzz_ClaimScheduleDoesNotChangeFacts(uint256 pathSeed, uint256 claimMask, uint256 delay) public {
        Scenario memory s = _sampled(_defaultAmounts(), FEE_BPS, pathSeed % 7, 1);
        uint256 state = vm.snapshotState();
        reputation.register(address(s.order));
        bytes32 expected = _registrationHash(address(s.order));
        vm.revertToState(state);

        address[3] memory accounts = [client, freelancer, feeRecipient];
        for (uint256 i; i < 3; ++i) {
            if ((claimMask >> i) & 1 == 1 && s.order.claimable(accounts[i]) != 0) s.order.claimPayout(accounts[i]);
        }
        if ((claimMask >> 3) & 1 == 1 && s.disputeId != 0) _claimCourtCredits(s.disputeId);
        vm.warp(block.timestamp + bound(delay, 0, 365 days));
        reputation.register(address(s.order));
        (, uint64 registeredAt,) = reputation.records(address(s.order));
        assertEq(registeredAt, block.timestamp);
        assertEq(_registrationHash(address(s.order)), expected);
    }

    /// @dev RF-03: distinct (address, role) pairs give distinct IDs, including the address boundaries, and no such ID
    /// exists before it is claimed.
    function testFuzz_ReceiptIdInjective(address a, address b, uint8 roleA, uint8 roleB) public {
        ITrustWorkReputation.Role ra = ITrustWorkReputation.Role(roleA % 2);
        ITrustWorkReputation.Role rb = ITrustWorkReputation.Role(roleB % 2);
        uint256 idA = reputation.receiptId(a, ra);
        assertEq(idA >> 1, uint256(uint160(a)));
        assertEq(idA & 1, uint256(ra));
        if (a != b || ra != rb) assertTrue(idA != reputation.receiptId(b, rb));

        address[4] memory bounds = [address(0), address(1), address(type(uint160).max - 1), address(type(uint160).max)];
        uint256[8] memory ids;
        for (uint256 i; i < 8; ++i) {
            ids[i] = reputation.receiptId(bounds[i / 2], ITrustWorkReputation.Role(i % 2));
            for (uint256 j; j < i; ++j) {
                assertTrue(ids[i] != ids[j]);
            }
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ids[i]));
            reputation.receiptOf(ids[i]);
        }
        assertEq(ids[7], (uint256(type(uint160).max) << 1) | 1);
        assertEq(ids[7] >> 161, 0);
    }

    /// @dev RF-04: every minted receipt decodes to its own order and role, and stops decoding once burned.
    function testFuzz_MintedReceiptRoundTrip(uint256 pathSeed, uint256 roleMask, bool burnFirst) public {
        Scenario memory s = _sampled(_defaultAmounts(), FEE_BPS, pathSeed % 7, 1);
        reputation.register(address(s.order));
        uint256 mask = bound(roleMask, 1, 3);
        address[2] memory holders = [client, freelancer];
        uint256[2] memory ids;
        for (uint256 r; r < 2; ++r) {
            if ((mask >> r) & 1 == 0) continue;
            ITrustWorkReputation.Role role = ITrustWorkReputation.Role(r);
            vm.prank(holders[r]);
            ids[r] = reputation.claimReceipt(address(s.order), role);
            (address order, ITrustWorkReputation.Role decoded) = reputation.receiptOf(ids[r]);
            assertEq(order, address(s.order));
            assertEq(uint256(decoded), r);
            assertEq(reputation.receiptId(order, decoded), ids[r]);
            assertEq(reputation.ownerOf(ids[r]), holders[r]);
        }
        (,, uint8 receiptsClaimed) = reputation.records(address(s.order));
        assertEq(receiptsClaimed, mask);

        uint256 burned = mask == 3 ? (burnFirst ? 0 : 1) : mask - 1;
        vm.prank(holders[burned]);
        reputation.burn(ids[burned]);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ids[burned]));
        reputation.receiptOf(ids[burned]);
        (,, receiptsClaimed) = reputation.records(address(s.order));
        assertEq(receiptsClaimed, mask);
        if (mask == 3) {
            (address order, ITrustWorkReputation.Role decoded) = reputation.receiptOf(ids[1 - burned]);
            assertEq(order, address(s.order));
            assertEq(uint256(decoded), 1 - burned);
        }
    }

    /// @dev Path 0 Completed, 1 delivery expiry, 2–6 rulings `Outcome(path - 2)`. Expiry uses position 1 or 2.
    function _sampled(uint256[] memory amounts, uint256 bps, uint256 path, uint256 position)
        private
        returns (Scenario memory s)
    {
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(
            freelancer, paymentToken, feeRecipient, bps, REVIEW_PERIOD, DELIVERY_PERIOD, amounts
        );
        ledger.trackOrder(address(order));
        s.order = order;
        s.amounts = amounts;
        vm.warp(block.timestamp + STEP);
        s.fundedAt = SafeCast.toUint64(block.timestamp);
        _fund(order);
        if (path == 0) {
            _settleFirst(s, 3);
            s.outcome = ITrustWorkReputation.Outcome.Completed;
            s.closedNotBefore = s.lastSubmittedAt;
        } else if (path == 1) {
            uint256 index = position == 0 ? 1 : position;
            uint256 deadline = _settleFirst(s, index) + DELIVERY_PERIOD;
            vm.warp(deadline);
            vm.prank(client);
            order.reclaimAfterDeliveryExpiry();
            s.outcome = ITrustWorkReputation.Outcome.DeliveryExpired;
            s.closedNotBefore = SafeCast.toUint64(deadline);
        } else {
            Outcome ruling = Outcome(path - 2);
            _settleFirst(s, position);
            vm.warp(block.timestamp + STEP);
            s.lastSubmittedAt = SafeCast.toUint64(block.timestamp);
            uint256 openedAt = block.timestamp;
            s.disputeId = _openDispute(order, position);
            vm.warp(block.timestamp + STEP);
            s.closedNotBefore = SafeCast.toUint64(
                ruling == Outcome.NoPanel ? openedAt + PANEL_PERIOD : block.timestamp + COMMIT_PLUS_REVEAL
            );
            _resolveAs(s.disputeId, ruling);
            _applyRuling(order);
            s.outcome = _toReputation(ruling);
        }
    }

    function _registrationHash(address order) private view returns (bytes32) {
        (ITrustWorkReputation.Outcome outcome,, uint8 receiptsClaimed) = reputation.records(order);
        return keccak256(
            abi.encode(
                outcome,
                receiptsClaimed,
                reputation.factsOf(order),
                reputation.statsOf(client, ITrustWorkReputation.Role.Client),
                reputation.statsOf(freelancer, ITrustWorkReputation.Role.Freelancer),
                reputation.ordersOf(client, ITrustWorkReputation.Role.Client, 0, 10),
                reputation.ordersOf(freelancer, ITrustWorkReputation.Role.Freelancer, 0, 10)
            )
        );
    }
}

contract TrustWorkReputationFuzzSharedTokenTest is TrustWorkReputationFuzzTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkReputationFuzzSplitTokenTest is TrustWorkReputationFuzzTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
