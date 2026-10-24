// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {RegistryTestBase} from "../utils/RegistryTestBase.sol";
import {ArbitratorRegistryHandler} from "./ArbitratorRegistryHandler.sol";

contract ArbitratorRegistryInvariantTest is StdInvariant, RegistryTestBase {
    ArbitratorRegistryHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ArbitratorRegistryHandler(court, token, _parties());
        for (uint256 i; i < 4; ++i) {
            handler.deposit(i, 2 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        targetContract(address(handler));
    }

    function invariant_CommitmentsNeverExceedStake() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            IArbitratorRegistry.Account memory account = _account(handler.actors(i));
            assertLe(account.locked + account.reserved, account.stake);
        }
    }

    function invariant_CommitmentsMatchLiveCandidacies() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            IArbitratorRegistry.Account memory account = _account(actor);
            ArbitratorRegistryHandler.Ghost memory ghost = handler.ghostOf(actor);
            assertEq(account.locked, SEAT_LOCK * ghost.lockedSeats);
            assertEq(account.reserved, SEAT_LOCK * ghost.reservations);
        }
    }

    function invariant_TotalStakedIsSumOfPrincipal() public view {
        uint256 accounts;
        uint256 ghosts;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            IArbitratorRegistry.Account memory account = _account(actor);
            ArbitratorRegistryHandler.Ghost memory ghost = handler.ghostOf(actor);
            accounts += account.stake + account.warming;
            ghosts += ghost.stake + ghost.warming;
            assertEq(account.stake + account.warming, ghost.stake + ghost.warming);
        }
        assertEq(registry.totalStaked(), accounts);
        assertEq(registry.totalStaked(), ghosts);
    }

    function invariant_CumulativeFlowsBalance() public view {
        assertEq(
            registry.depositsReceived(), registry.withdrawalsPaid() + registry.penaltiesSent() + registry.totalStaked()
        );
        assertEq(registry.depositsReceived(), handler.ghostDeposits());
        assertEq(registry.withdrawalsPaid(), handler.ghostWithdrawals());
        assertEq(registry.penaltiesSent(), handler.ghostPenalties());
        assertEq(token.balanceOf(address(court)), handler.ghostPenalties());
    }

    function invariant_BalanceIsPrincipalPlusDonations() public view {
        assertEq(token.balanceOf(address(registry)), registry.totalStaked() + handler.ghostDonations());
    }

    function invariant_ListingMatchesPrincipal() public view {
        address[] memory listed = registry.listedAccounts();
        address[] memory expected = handler.ghostListingOrder();
        assertEq(listed.length, expected.length);
        assertLe(listed.length, registry.MAX_ARBITRATORS());
        for (uint256 i; i < listed.length; ++i) {
            assertEq(listed[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertTrue(listed[i] != listed[j]);
            }
        }
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            IArbitratorRegistry.Account memory account = _account(handler.actors(i));
            assertEq(account.listed, account.stake + account.warming >= SEAT_LOCK);
        }
    }

    function invariant_SnapshotsMatchGhostHistory() public view {
        for (uint256 s; s < handler.snapshotCount(); ++s) {
            (uint256 disputeId, address[] memory candidates, IArbitratorRegistry.CandidateState[] memory states) =
                handler.snapshotAt(s);
            IArbitratorRegistry.Candidate[] memory stored = registry.candidatesOf(disputeId);
            assertEq(stored.length, candidates.length);
            for (uint256 i; i < stored.length; ++i) {
                assertEq(stored[i].arbitrator, candidates[i]);
                assertEq(uint256(stored[i].state), uint256(states[i]));
            }
            assertEq(uint256(registry.snapshotState(disputeId)), uint256(handler.ghostSnapshotStateOf(disputeId)));
        }
    }

    function afterInvariant() external view {
        console.log(
            string.concat(
                "registry deposits=",
                vm.toString(handler.deposits()),
                " rejectedDeposits=",
                vm.toString(handler.rejectedDeposits()),
                " listings=",
                vm.toString(handler.listings()),
                " delistings=",
                vm.toString(handler.delistings()),
                " withdrawals=",
                vm.toString(handler.withdrawals()),
                " rejectedWithdrawals=",
                vm.toString(handler.rejectedWithdrawals()),
                string.concat(
                    " snapshots=",
                    vm.toString(handler.snapshots()),
                    " failedSnapshots=",
                    vm.toString(handler.failedSnapshots()),
                    " selections=",
                    vm.toString(handler.selections()),
                    " reservationReleases=",
                    vm.toString(handler.reservationReleases()),
                    " seatReleases=",
                    vm.toString(handler.seatReleases()),
                    " penalized=",
                    vm.toString(handler.penalizedReleases()),
                    " rejectedReleases=",
                    vm.toString(handler.rejectedReleases())
                )
            )
        );
    }
}
