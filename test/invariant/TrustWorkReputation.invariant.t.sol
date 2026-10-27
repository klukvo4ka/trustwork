// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {console} from "forge-std/console.sol";
import {TrustWorkReputation} from "../../src/TrustWorkReputation.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {TrustWorkIntegrationHandler} from "./TrustWorkIntegrationHandler.sol";
import {TrustWorkIntegrationInvariantTest} from "./TrustWorkIntegration.invariant.t.sol";
import {TrustWorkReputationHandler} from "./TrustWorkReputationHandler.sol";

/// @dev The Stage 3E integration campaign with registrations and receipt operations interleaved. The inherited II-01 …
/// II-08 invariants keep running (RI-06); this contract adds RI-01 … RI-05.
abstract contract TrustWorkReputationInvariantTest is TrustWorkIntegrationInvariantTest {
    TrustWorkReputationHandler internal reputationHandler;
    TrustWorkReputation internal reputation;
    bool private _interleaveRegistrations;
    bool private _interleaveReceipts;

    function _deployHandler() internal override returns (TrustWorkIntegrationHandler) {
        reputationHandler = new TrustWorkReputationHandler(
            factory, paymentToken, stakeToken, ledger, client, clientKey, freelancer, feeRecipient
        );
        reputation = reputationHandler.reputation();
        return reputationHandler;
    }

    function _targetSelectors() internal view override returns (bytes4[] memory selectors) {
        bytes4[] memory base = super._targetSelectors();
        selectors = new bytes4[](base.length + 9);
        for (uint256 i; i < base.length; ++i) {
            selectors[i] = base[i];
        }
        selectors[base.length] = reputationHandler.registerOrder.selector;
        selectors[base.length + 1] = reputationHandler.registerOrder.selector;
        selectors[base.length + 2] = reputationHandler.registerOrder.selector;
        selectors[base.length + 3] = reputationHandler.registerUnknown.selector;
        selectors[base.length + 4] = reputationHandler.claimReceipt.selector;
        selectors[base.length + 5] = reputationHandler.claimReceipt.selector;
        selectors[base.length + 6] = reputationHandler.claimReceipt.selector;
        selectors[base.length + 7] = reputationHandler.burnReceipt.selector;
        selectors[base.length + 8] = reputationHandler.moveReceipt.selector;
    }

    /// @dev RI-01.
    function invariant_CountersPartitionRegistrations() public view {
        for (uint256 k; k < handler.accountCount(); ++k) {
            address account = handler.accountAt(k);
            for (uint256 r; r < 2; ++r) {
                ITrustWorkReputation.Role role = ITrustWorkReputation.Role(r);
                ITrustWorkReputation.Stats memory stats = reputation.statsOf(account, role);
                uint256[8] memory ghost = reputationHandler.ghostStatsOf(account, role);
                assertEq(
                    stats.completed + stats.deliveryExpired + stats.freelancerWins + stats.clientWins + stats.splits
                        + stats.noPanel,
                    stats.registered
                );
                assertEq(stats.registered, reputation.orderCount(account, role));
                assertEq(
                    keccak256(abi.encode(stats)),
                    keccak256(
                        abi.encode(ghost[0], ghost[1], ghost[2], ghost[3], ghost[4], ghost[5], ghost[6], ghost[7])
                    )
                );
            }
        }
    }

    /// @dev RI-02.
    function invariant_RegisteredOrdersWereEligible() public view {
        for (uint256 i; i < reputationHandler.registeredCount(); ++i) {
            WorkOrder order = reputationHandler.registeredOrders(i);
            assertTrue(factory.isWorkOrder(address(order)));
            WorkOrder.OrderStatus status = order.status();
            assertTrue(status == WorkOrder.OrderStatus.Completed || status == WorkOrder.OrderStatus.Terminated);
            assertTrue(order.getMilestone(0).status != WorkOrder.MilestoneStatus.Pending);
            (ITrustWorkReputation.Outcome outcome,,) = reputation.records(address(order));
            assertEq(uint256(outcome), uint256(reputationHandler.ghostOutcome(order)));
        }
    }

    /// @dev RI-03: records and facts never change except for the claim bits, which follow lifetime issuance and
    /// survive burns.
    function invariant_RecordsAndFactsNeverChange() public view {
        for (uint256 i; i < reputationHandler.registeredCount(); ++i) {
            WorkOrder order = reputationHandler.registeredOrders(i);
            (, uint64 registeredAt, uint8 receiptsClaimed) = reputation.records(address(order));
            assertEq(registeredAt, reputationHandler.ghostRegisteredAt(order));
            assertEq(receiptsClaimed, reputationHandler.ghostClaimBits(order));
            assertEq(keccak256(abi.encode(reputation.factsOf(address(order)))), reputationHandler.ghostFactsHash(order));
        }
    }

    /// @dev RI-04: every live receipt is locked, decodes to its pair and is owned by that role's holder; burned
    /// receipts are gone; balances match the ghost.
    function invariant_LiveReceiptsLockedWithRoleHolder() public view {
        for (uint256 i; i < reputationHandler.mintedCount(); ++i) {
            uint256 tokenId = reputationHandler.mintedIds(i);
            address order = address(SafeCast.toUint160(tokenId >> 1));
            ITrustWorkReputation.Role role = ITrustWorkReputation.Role(tokenId & 1);
            address owner = reputationHandler.ghostOwner(tokenId);
            if (owner == address(0)) {
                try reputation.ownerOf(tokenId) returns (address) {
                    revert("burned receipt still owned");
                } catch {}
                continue;
            }
            assertEq(owner, role == ITrustWorkReputation.Role.Client ? handler.client() : handler.freelancer());
            assertEq(reputation.ownerOf(tokenId), owner);
            assertTrue(reputation.locked(tokenId));
            (address decodedOrder, ITrustWorkReputation.Role decodedRole) = reputation.receiptOf(tokenId);
            assertEq(decodedOrder, order);
            assertEq(uint256(decodedRole), uint256(role));
        }
        for (uint256 k; k < handler.accountCount(); ++k) {
            address account = handler.accountAt(k);
            assertEq(reputation.balanceOf(account), reputationHandler.ghostBalance(account));
        }
    }

    /// @dev RI-05: at most one receipt is ever minted per (order, role), only for registered orders, and the claim
    /// bit is set exactly when it was.
    function invariant_AtMostOneReceiptPerOrderRole() public view {
        for (uint256 i; i < handler.orderCount(); ++i) {
            WorkOrder order = handler.orders(i);
            (ITrustWorkReputation.Outcome outcome,, uint8 receiptsClaimed) = reputation.records(address(order));
            for (uint256 r; r < 2; ++r) {
                uint256 mints = reputationHandler.ghostMints(order, ITrustWorkReputation.Role(r));
                assertLe(mints, 1);
                assertEq((receiptsClaimed >> r) & 1, mints);
                if (mints != 0) assertTrue(outcome != ITrustWorkReputation.Outcome.None);
            }
            assertLe(receiptsClaimed, 3);
        }
        uint256 minted = reputationHandler.mintedCount();
        assertEq(
            minted,
            reputationHandler.claimsByRole(ITrustWorkReputation.Role.Client)
                + reputationHandler.claimsByRole(ITrustWorkReputation.Role.Freelancer)
        );
        for (uint256 i; i < minted; ++i) {
            for (uint256 j; j < i; ++j) {
                assertTrue(reputationHandler.mintedIds(i) != reputationHandler.mintedIds(j));
            }
        }
    }

    function afterInvariant() public override {
        super.afterInvariant();
        reputationHandler.registerAll();
        reputationHandler.claimAll();
        this.checkReputationInvariants();
        _logRegistrations();
        _logReceipts();
    }

    /// @dev Replays 32 fixed campaigns with registrations interleaved, checks every Stage 3E and reputation invariant
    /// after each call, registers every order at the end, and requires every outcome and rejection reason.
    function test_RandomCampaignsRegisterEveryOutcome() public {
        vm.pauseGasMetering();
        _interleaveRegistrations = true;
        uint256[11] memory totals;
        for (uint256 campaign; campaign < 32; ++campaign) {
            uint256 state = vm.snapshotState();
            for (uint256 step; step < 128; ++step) {
                _randomCall(uint256(keccak256(abi.encode("reputation", campaign, step))));
                this.checkInvariants();
                this.checkReputationInvariants();
            }
            handler.settleEverything();
            reputationHandler.registerAll();
            this.checkInvariants();
            this.checkReputationInvariants();
            uint256[11] memory counts = _registrationCounts();
            for (uint256 k; k < 11; ++k) {
                totals[k] += counts[k];
            }
            vm.revertToState(state);
        }
        string[11] memory names = [
            "registered",
            "Completed",
            "DeliveryExpired",
            "FreelancerWins",
            "ClientWins",
            "Split",
            "NoPanel",
            "rejectedNotFinal",
            "rejectedNoParticipation",
            "rejectedDuplicate",
            "rejectedUnknown"
        ];
        for (uint256 k; k < 11; ++k) {
            console.log(names[k], totals[k]);
        }
        for (uint256 k; k < 11; ++k) {
            assertGt(totals[k], 0, names[k]);
        }
    }

    /// @dev Replays 32 fixed campaigns with registrations and receipt operations interleaved, then registers every
    /// final order and runs 32 receipt operations on them, checks every invariant after each call, claims everything
    /// at the end, and requires every receipt transition.
    function test_RandomCampaignsExerciseReceipts() public {
        vm.pauseGasMetering();
        _interleaveRegistrations = true;
        _interleaveReceipts = true;
        uint256[8] memory totals;
        for (uint256 campaign; campaign < 32; ++campaign) {
            uint256 state = vm.snapshotState();
            for (uint256 step; step < 128; ++step) {
                _randomCall(uint256(keccak256(abi.encode("receipts", campaign, step))));
                this.checkInvariants();
                this.checkReputationInvariants();
            }
            handler.settleEverything();
            reputationHandler.registerAll();
            for (uint256 step; step < 32; ++step) {
                _receiptCall(uint256(keccak256(abi.encode("final receipts", campaign, step))));
                this.checkReputationInvariants();
            }
            reputationHandler.claimAll();
            this.checkInvariants();
            this.checkReputationInvariants();
            uint256[8] memory counts = _receiptCounts();
            for (uint256 k; k < 8; ++k) {
                totals[k] += counts[k];
            }
            vm.revertToState(state);
        }
        string[8] memory names = [
            "clientClaims",
            "freelancerClaims",
            "burns",
            "rejectedDuplicateClaims",
            "rejectedClaimsAfterBurn",
            "rejectedUnauthorized",
            "rejectedTransfers",
            "rejectedApprovals"
        ];
        for (uint256 k; k < 8; ++k) {
            console.log(names[k], totals[k]);
        }
        for (uint256 k; k < 8; ++k) {
            assertGt(totals[k], 0, names[k]);
        }
    }

    function checkReputationInvariants() external view {
        invariant_CountersPartitionRegistrations();
        invariant_RegisteredOrdersWereEligible();
        invariant_RecordsAndFactsNeverChange();
        invariant_LiveReceiptsLockedWithRoleHolder();
        invariant_AtMostOneReceiptPerOrderRole();
    }

    /// @dev Only the reputation replays interleave registrations and receipt operations; the inherited Stage 3E replay
    /// keeps its call mix, and the registration replay keeps its own.
    function _randomCall(uint256 seed) internal override {
        if (_interleaveReceipts && seed % 8 == 1) {
            _receiptCall(seed);
            return;
        }
        if (_interleaveRegistrations && seed % 8 == 0) {
            uint256 a = uint256(keccak256(abi.encode(seed, 3)));
            if ((seed >> 8) % 6 == 0) reputationHandler.registerUnknown(a);
            else reputationHandler.registerOrder(a);
            return;
        }
        super._randomCall(seed);
    }

    function _registrationCounts() internal view returns (uint256[11] memory counts) {
        counts[0] = reputationHandler.registeredCount();
        for (uint256 o = 1; o <= 6; ++o) {
            counts[o] = reputationHandler.registrationsByOutcome(ITrustWorkReputation.Outcome(o));
        }
        counts[7] = reputationHandler.rejectedNotFinal();
        counts[8] = reputationHandler.rejectedNoParticipation();
        counts[9] = reputationHandler.rejectedDuplicate();
        counts[10] = reputationHandler.rejectedUnknown();
    }

    function _receiptCall(uint256 seed) internal {
        uint256 a = uint256(keccak256(abi.encode(seed, 4)));
        uint256 b = uint256(keccak256(abi.encode(seed, 5)));
        uint256 c = uint256(keccak256(abi.encode(seed, 6)));
        uint256 action = (seed >> 8) % 5;
        if (action < 3) reputationHandler.claimReceipt(a, b, c);
        else if (action < 4) reputationHandler.burnReceipt(a, b);
        else reputationHandler.moveReceipt(a, b, c);
    }

    function _receiptCounts() internal view returns (uint256[8] memory counts) {
        counts[0] = reputationHandler.claimsByRole(ITrustWorkReputation.Role.Client);
        counts[1] = reputationHandler.claimsByRole(ITrustWorkReputation.Role.Freelancer);
        counts[2] = reputationHandler.burns();
        counts[3] = reputationHandler.rejectedDuplicateClaims();
        counts[4] = reputationHandler.rejectedClaimsAfterBurn();
        counts[5] = reputationHandler.rejectedUnauthorized();
        counts[6] = reputationHandler.rejectedTransfers();
        counts[7] = reputationHandler.rejectedApprovals();
    }

    function _logReceipts() internal view {
        uint256[8] memory c = _receiptCounts();
        console.log(
            string.concat(
                "receipts clientClaims=",
                vm.toString(c[0]),
                " freelancerClaims=",
                vm.toString(c[1]),
                " burns=",
                vm.toString(c[2]),
                " duplicate=",
                vm.toString(c[3]),
                " afterBurn=",
                vm.toString(c[4]),
                " unauthorized=",
                vm.toString(c[5]),
                " transfers=",
                vm.toString(c[6]),
                " approvals=",
                vm.toString(c[7]),
                " unregistered=",
                vm.toString(reputationHandler.rejectedUnregisteredClaims())
            )
        );
    }

    function _logRegistrations() internal view {
        uint256[11] memory c = _registrationCounts();
        console.log(
            string.concat(
                "reputation registered=",
                vm.toString(c[0]),
                " completed=",
                vm.toString(c[1]),
                " expired=",
                vm.toString(c[2]),
                " freelancerWins=",
                vm.toString(c[3]),
                " clientWins=",
                vm.toString(c[4]),
                " splits=",
                vm.toString(c[5]),
                " noPanel=",
                vm.toString(c[6]),
                string.concat(
                    " notFinal=",
                    vm.toString(c[7]),
                    " noParticipation=",
                    vm.toString(c[8]),
                    " duplicate=",
                    vm.toString(c[9]),
                    " unknown=",
                    vm.toString(c[10])
                )
            )
        );
    }
}

contract TrustWorkReputationSharedTokenInvariantTest is TrustWorkReputationInvariantTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkReputationSplitTokenInvariantTest is TrustWorkReputationInvariantTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
