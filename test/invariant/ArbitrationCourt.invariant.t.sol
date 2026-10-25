// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";
import {ArbitrationCourtHandler} from "./ArbitrationCourtHandler.sol";

/// @dev The handler's actors start with matured stake for three seats each so that campaigns reach snapshots, panels,
/// votes and resolutions instead of only pending disputes.
contract ArbitrationCourtInvariantTest is StdInvariant, CourtTestBase {
    ArbitrationCourtHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ArbitrationCourtHandler(factory, token);
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            handler.deposit(i, 3 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = handler.openDispute.selector;
        selectors[1] = handler.retrySnapshot.selector;
        selectors[2] = handler.drawPanel.selector;
        selectors[3] = handler.drawPanel.selector;
        selectors[4] = handler.drawPanel.selector;
        selectors[5] = handler.commitVote.selector;
        selectors[6] = handler.commitVote.selector;
        selectors[7] = handler.commitVote.selector;
        selectors[8] = handler.commitVote.selector;
        selectors[9] = handler.revealVote.selector;
        selectors[10] = handler.revealVote.selector;
        selectors[11] = handler.revealVote.selector;
        selectors[12] = handler.resolve.selector;
        selectors[13] = handler.resolve.selector;
        selectors[14] = handler.claimReward.selector;
        selectors[15] = handler.claimReward.selector;
        selectors[16] = handler.deposit.selector;
        selectors[17] = handler.withdraw.selector;
        selectors[18] = handler.warp.selector;
        selectors[19] = handler.roll.selector;
        selectors[20] = handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev CI-01.
    function invariant_CourtFlowsBalance() public view {
        assertEq(
            court.feesReceived() + court.penaltiesReceived(),
            court.claimsPaid() + court.pendingFees() + court.totalClaimable()
        );
        assertEq(court.feesReceived(), handler.ghostFees());
        assertEq(court.penaltiesReceived(), handler.ghostPenalties());
        assertEq(court.claimsPaid(), handler.ghostClaims());
    }

    /// @dev CI-02.
    function invariant_BalanceIsLiabilitiesPlusDonations() public view {
        assertEq(
            token.balanceOf(address(court)), court.pendingFees() + court.totalClaimable() + handler.ghostDonations()
        );
    }

    /// @dev CI-03.
    function invariant_PendingFeesMatchUnresolvedDisputes() public view {
        uint256 unresolved;
        for (uint256 id = 1; id <= handler.disputeTotal(); ++id) {
            if (court.getDispute(id).status != IArbitrationCourt.DisputeStatus.Resolved) ++unresolved;
        }
        assertEq(court.pendingFees(), DISPUTE_FEE * unresolved);
    }

    /// @dev CI-04.
    function invariant_PenaltiesMatchRegistry() public view {
        assertEq(court.penaltiesReceived(), registry.penaltiesSent());
    }

    /// @dev CI-05: commitments derived from each dispute's ghost snapshot and panel.
    function invariant_RegistryCommitmentsMatchDisputes() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            uint256 reservations;
            uint256 seats;
            for (uint256 id = 1; id <= handler.disputeTotal(); ++id) {
                IArbitrationCourt.DisputeStatus status = handler.ghostDisputeOf(id).status;
                if (status == IArbitrationCourt.DisputeStatus.AwaitingSeed) {
                    address[] memory candidates = handler.ghostCandidatesOf(id);
                    for (uint256 k; k < candidates.length; ++k) {
                        if (candidates[k] == actor) ++reservations;
                    }
                } else if (status == IArbitrationCourt.DisputeStatus.Voting) {
                    address[3] memory panel = handler.ghostPanelOf(id);
                    for (uint256 j; j < 3; ++j) {
                        if (panel[j] == actor) ++seats;
                    }
                }
            }
            IArbitratorRegistry.Account memory account = registry.accountOf(actor);
            assertEq(account.reserved, SEAT_LOCK * reservations);
            assertEq(account.locked, SEAT_LOCK * seats);
            assertLe(account.locked + account.reserved, account.stake);
        }
    }

    /// @dev CI-06, plus status and stored snapshots against the ghost history.
    function invariant_RulingsAndSnapshotsMatchHistory() public view {
        for (uint256 id = 1; id <= handler.disputeTotal(); ++id) {
            ArbitrationCourtHandler.GhostDispute memory ghost = handler.ghostDisputeOf(id);
            IArbitrationCourt.Dispute memory dispute = court.getDispute(id);
            (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason) = court.rulingOf(id);
            assertEq(uint256(dispute.status), uint256(ghost.status));
            assertEq(uint256(ruling), uint256(ghost.ruling));
            assertEq(uint256(reason), uint256(ghost.reason));
            bool resolved = ghost.status == IArbitrationCourt.DisputeStatus.Resolved;
            assertEq(ruling == IArbitrationCourt.Ruling.None, !resolved);
            assertEq(reason == IArbitrationCourt.RulingReason.None, !resolved);

            address[] memory candidates = handler.ghostCandidatesOf(id);
            IArbitratorRegistry.Candidate[] memory stored = registry.candidatesOf(id);
            assertEq(stored.length, candidates.length);
            for (uint256 k; k < stored.length; ++k) {
                assertEq(stored[k].arbitrator, candidates[k]);
            }
        }
    }

    function invariant_CreditsMatchGhosts() public view {
        uint256 total;
        for (uint256 i; i < handler.accountCount(); ++i) {
            address account = handler.accountAt(i);
            assertEq(court.claimable(account), handler.ghostCredit(account));
            total += handler.ghostCredit(account);
        }
        assertEq(court.totalClaimable(), total);
    }

    /// @dev CI-07: every dispute resolves once all deadlines have passed, after which nothing stays committed in the
    /// registry and claiming every credit leaves only donations in the court.
    function afterInvariant() external {
        _logTransitions();
        handler.resolveAll();
        for (uint256 id = 1; id <= handler.disputeTotal(); ++id) {
            assertEq(uint256(court.getDispute(id).status), uint256(IArbitrationCourt.DisputeStatus.Resolved));
        }
        assertEq(court.pendingFees(), 0);
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            IArbitratorRegistry.Account memory account = registry.accountOf(handler.actors(i));
            assertEq(account.locked, 0);
            assertEq(account.reserved, 0);
        }
        invariant_CourtFlowsBalance();
        invariant_CreditsMatchGhosts();
        invariant_PenaltiesMatchRegistry();

        handler.claimAll();
        assertEq(court.totalClaimable(), 0);
        assertEq(token.balanceOf(address(court)), handler.ghostDonations());
        assertEq(court.feesReceived() + court.penaltiesReceived(), court.claimsPaid());
    }

    /// @dev Replays 64 pseudo-random campaigns of 64 handler calls with the invariant checks after every call, and
    /// reports the summed transition counts, which the fuzzer's per-run log cannot aggregate.
    function test_RandomCampaignsReachEveryTransition() public {
        vm.pauseGasMetering();
        uint256[12] memory totals;
        for (uint256 campaign; campaign < 64; ++campaign) {
            uint256 state = vm.snapshotState();
            for (uint256 step; step < 64; ++step) {
                _randomCall(uint256(keccak256(abi.encode(campaign, step))));
                this.checkInvariants();
            }
            handler.resolveAll();
            this.checkInvariants();
            handler.claimAll();
            this.checkInvariants();
            totals[0] += handler.opened();
            totals[1] += handler.successfulRetries();
            totals[2] += handler.draws();
            totals[3] += handler.rearms();
            totals[4] += handler.validCommits();
            totals[5] += handler.unrevealableCommits();
            totals[6] += handler.reveals();
            totals[7] += handler.noPanelResolutions();
            totals[8] += handler.majorityResolutions();
            totals[9] += handler.noDecisionResolutions();
            totals[10] += handler.penalizedSeats();
            totals[11] += handler.claims();
            vm.revertToState(state);
        }
        console.log("totals opened, successfulRetries, draws, rearms:");
        console.log(totals[0], totals[1], totals[2], totals[3]);
        console.log("totals validCommits, unrevealableCommits, reveals:");
        console.log(totals[4], totals[5], totals[6]);
        console.log("totals noPanel, majority, noDecision:");
        console.log(totals[7], totals[8], totals[9]);
        console.log("totals penalizedSeats, claims:");
        console.log(totals[10], totals[11]);
        for (uint256 i; i < totals.length; ++i) {
            assertGt(totals[i], 0);
        }
    }

    function _randomCall(uint256 seed) internal {
        uint256 a = uint256(keccak256(abi.encode(seed, 1)));
        uint256 b = uint256(keccak256(abi.encode(seed, 2)));
        uint256 action = seed % 21;
        if (action < 1) handler.openDispute(a, b);
        else if (action < 2) handler.retrySnapshot(a);
        else if (action < 5) handler.drawPanel(a, bytes32(b), (seed >> 16) % 8 == 0);
        else if (action < 9) handler.commitVote(a, bytes32(b));
        else if (action < 12) handler.revealVote(a, b);
        else if (action < 14) handler.resolve(a, b);
        else if (action < 16) handler.claimReward(a);
        else if (action < 17) handler.deposit(a, b);
        else if (action < 18) handler.withdraw(a, b);
        else if (action < 19) handler.warp(a);
        else if (action < 20) handler.roll(a);
        else handler.donate(a);
    }

    function checkInvariants() external view {
        invariant_CourtFlowsBalance();
        invariant_BalanceIsLiabilitiesPlusDonations();
        invariant_PendingFeesMatchUnresolvedDisputes();
        invariant_PenaltiesMatchRegistry();
        invariant_RegistryCommitmentsMatchDisputes();
        invariant_RulingsAndSnapshotsMatchHistory();
        invariant_CreditsMatchGhosts();
    }

    function _logTransitions() internal view {
        console.log(
            string.concat(
                "court opened=",
                vm.toString(handler.opened()),
                " pendingCandidates=",
                vm.toString(handler.pendingCandidates()),
                " retries=",
                vm.toString(handler.retries()),
                " successfulRetries=",
                vm.toString(handler.successfulRetries()),
                " rejectedRetries=",
                vm.toString(handler.rejectedRetries()),
                " draws=",
                vm.toString(handler.draws()),
                " rearms=",
                vm.toString(handler.rearms()),
                string.concat(
                    " validCommits=",
                    vm.toString(handler.validCommits()),
                    " unrevealableCommits=",
                    vm.toString(handler.unrevealableCommits()),
                    " reveals=",
                    vm.toString(handler.reveals()),
                    " rejectedReveals=",
                    vm.toString(handler.rejectedReveals()),
                    " noPanel=",
                    vm.toString(handler.noPanelResolutions()),
                    " majority=",
                    vm.toString(handler.majorityResolutions()),
                    " noDecision=",
                    vm.toString(handler.noDecisionResolutions())
                ),
                string.concat(
                    " penalizedSeats=",
                    vm.toString(handler.penalizedSeats()),
                    " earlyResolveRejections=",
                    vm.toString(handler.earlyResolveRejections()),
                    " repeatedResolveRejections=",
                    vm.toString(handler.repeatedResolveRejections()),
                    " claims=",
                    vm.toString(handler.claims()),
                    " emptyClaims=",
                    vm.toString(handler.emptyClaims()),
                    " deposits=",
                    vm.toString(handler.deposits()),
                    " withdrawals=",
                    vm.toString(handler.withdrawals()),
                    " donations=",
                    vm.toString(handler.donations())
                )
            )
        );
    }
}
