// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TrustWorkReputation} from "../../src/TrustWorkReputation.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {TrustWorkIntegrationHandler} from "./TrustWorkIntegrationHandler.sol";
import {TrustWorkIntegrationInvariantTest} from "./TrustWorkIntegration.invariant.t.sol";
import {TrustWorkReputationHandler} from "./TrustWorkReputationHandler.sol";

/// @dev The Stage 3E integration campaign with registrations interleaved. The inherited II-01 … II-08 invariants keep
/// running (RI-06); this contract adds RI-01 … RI-03.
abstract contract TrustWorkReputationInvariantTest is TrustWorkIntegrationInvariantTest {
    TrustWorkReputationHandler internal reputationHandler;
    TrustWorkReputation internal reputation;
    bool private _interleaveRegistrations;

    function _deployHandler() internal override returns (TrustWorkIntegrationHandler) {
        reputationHandler = new TrustWorkReputationHandler(
            factory, paymentToken, stakeToken, ledger, client, clientKey, freelancer, feeRecipient
        );
        reputation = reputationHandler.reputation();
        return reputationHandler;
    }

    function _targetSelectors() internal view override returns (bytes4[] memory selectors) {
        bytes4[] memory base = super._targetSelectors();
        selectors = new bytes4[](base.length + 4);
        for (uint256 i; i < base.length; ++i) {
            selectors[i] = base[i];
        }
        selectors[base.length] = reputationHandler.registerOrder.selector;
        selectors[base.length + 1] = reputationHandler.registerOrder.selector;
        selectors[base.length + 2] = reputationHandler.registerOrder.selector;
        selectors[base.length + 3] = reputationHandler.registerUnknown.selector;
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

    /// @dev RI-03.
    function invariant_RecordsAndFactsNeverChange() public view {
        for (uint256 i; i < reputationHandler.registeredCount(); ++i) {
            WorkOrder order = reputationHandler.registeredOrders(i);
            (, uint64 registeredAt, uint8 receiptsClaimed) = reputation.records(address(order));
            assertEq(registeredAt, reputationHandler.ghostRegisteredAt(order));
            assertEq(receiptsClaimed, 0);
            assertEq(keccak256(abi.encode(reputation.factsOf(address(order)))), reputationHandler.ghostFactsHash(order));
        }
    }

    function afterInvariant() public override {
        super.afterInvariant();
        reputationHandler.registerAll();
        this.checkReputationInvariants();
        _logRegistrations();
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

    function checkReputationInvariants() external view {
        invariant_CountersPartitionRegistrations();
        invariant_RegisteredOrdersWereEligible();
        invariant_RecordsAndFactsNeverChange();
    }

    /// @dev Only the reputation replay interleaves registrations; the inherited Stage 3E replay keeps its call mix.
    function _randomCall(uint256 seed) internal override {
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
