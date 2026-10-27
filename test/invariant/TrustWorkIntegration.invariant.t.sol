// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {IntegrationTestBase} from "../utils/IntegrationTestBase.sol";
import {TrustWorkIntegrationHandler} from "./TrustWorkIntegrationHandler.sol";

/// @dev The handler's arbitrators start with matured stake for three seats each and two orders exist, so campaigns
/// reach funding, disputes, panels, rulings and claims rather than only order creation.
abstract contract TrustWorkIntegrationInvariantTest is StdInvariant, IntegrationTestBase {
    TrustWorkIntegrationHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        handler = _deployHandler();
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            handler.deposit(i, 3 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        handler.createOrder(1, 0);
        handler.createOrder(2, 1);

        bytes4[] memory selectors = _targetSelectors();
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _deployHandler() internal virtual returns (TrustWorkIntegrationHandler) {
        return new TrustWorkIntegrationHandler(
            factory, paymentToken, stakeToken, ledger, client, clientKey, freelancer, feeRecipient
        );
    }

    function _targetSelectors() internal view virtual returns (bytes4[] memory selectors) {
        selectors = new bytes4[](31);
        selectors[0] = handler.createOrder.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.submit.selector;
        selectors[4] = handler.submit.selector;
        selectors[5] = handler.submit.selector;
        selectors[6] = handler.submit.selector;
        selectors[7] = handler.settle.selector;
        selectors[8] = handler.settle.selector;
        selectors[9] = handler.settle.selector;
        selectors[10] = handler.settle.selector;
        selectors[11] = handler.reclaim.selector;
        selectors[12] = handler.openDispute.selector;
        selectors[13] = handler.openDispute.selector;
        selectors[14] = handler.retrySnapshot.selector;
        selectors[15] = handler.drawPanel.selector;
        selectors[16] = handler.drawPanel.selector;
        selectors[17] = handler.commitVote.selector;
        selectors[18] = handler.revealVote.selector;
        selectors[19] = handler.castVotes.selector;
        selectors[20] = handler.castVotes.selector;
        selectors[21] = handler.resolve.selector;
        selectors[22] = handler.applyRuling.selector;
        selectors[23] = handler.claimOrder.selector;
        selectors[24] = handler.claimCourt.selector;
        selectors[25] = handler.replayStaleSignature.selector;
        selectors[26] = handler.deposit.selector;
        selectors[27] = handler.withdraw.selector;
        selectors[28] = handler.warp.selector;
        selectors[29] = handler.roll.selector;
        selectors[30] = handler.donate.selector;
    }

    /// @dev II-01.
    function invariant_OrderFundsConserved() public view {
        for (uint256 i; i < handler.orderCount(); ++i) {
            _assertOrderConservation(handler.orders(i));
        }
    }

    /// @dev II-02 and II-07: every contract's balance is its booked liabilities plus unsolicited transfers, and its
    /// liability counters equal the liabilities booked from observed, authorized transfers.
    function invariant_BalancesAndProvenance() public view {
        for (uint256 i; i < handler.orderCount(); ++i) {
            WorkOrder order = handler.orders(i);
            assertEq(order.outstandingObligations(), ledger.liability(address(order), address(paymentToken)));
        }
        _assertProtocolEquations();
    }

    /// @dev II-03.
    function invariant_OutstandingMatchesStatus() public view {
        for (uint256 i; i < handler.orderCount(); ++i) {
            WorkOrder order = handler.orders(i);
            WorkOrder.OrderStatus status = order.status();
            uint256 expected;
            if (status == WorkOrder.OrderStatus.Active || status == WorkOrder.OrderStatus.Disputed) {
                expected = handler.unsettledOf(order);
            } else if (status == WorkOrder.OrderStatus.Terminated) {
                for (uint256 k; k < handler.accountCount(); ++k) {
                    expected += handler.ghostOrderCredit(order, handler.accountAt(k));
                }
            }
            assertEq(order.outstandingObligations(), expected);
            if (status == WorkOrder.OrderStatus.Terminated) {
                for (uint256 k; k < handler.accountCount(); ++k) {
                    address account = handler.accountAt(k);
                    assertEq(order.claimable(account), handler.ghostOrderCredit(order, account));
                }
            }
        }
    }

    /// @dev II-04.
    function invariant_NonceInvariant() public view {
        for (uint256 i; i < handler.orderCount(); ++i) {
            WorkOrder order = handler.orders(i);
            _assertNonceInvariant(order);
            assertEq(order.currentMilestone(), handler.ghostSettled(order));
        }
    }

    /// @dev II-05: CI-01, CI-02 (in `invariant_BalancesAndProvenance`) and CI-04, plus court credits per account.
    function invariant_CourtAccounting() public view {
        assertEq(
            court.feesReceived() + court.penaltiesReceived(),
            court.claimsPaid() + court.pendingFees() + court.totalClaimable()
        );
        assertEq(court.penaltiesReceived(), registry.penaltiesSent());
        uint256 unresolved;
        for (uint256 id = 1; id <= handler.disputeTotal(); ++id) {
            if (handler.ghostDisputeOf(id).status != IArbitrationCourt.DisputeStatus.Resolved) ++unresolved;
        }
        assertEq(court.pendingFees(), DISPUTE_FEE * unresolved);
        for (uint256 k; k < handler.accountCount(); ++k) {
            address account = handler.accountAt(k);
            assertEq(court.claimable(account), handler.ghostCourtCredit(account));
        }
    }

    /// @dev II-06: RI-01 … RI-06.
    function invariant_RegistryAccounting() public view {
        uint256 principal;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            IArbitratorRegistry.Account memory account = registry.accountOf(actor);
            assertLe(account.locked + account.reserved, account.stake);
            (uint256 reservations, uint256 seats) = _commitmentsOf(actor);
            assertEq(account.reserved, SEAT_LOCK * reservations);
            assertEq(account.locked, SEAT_LOCK * seats);
            assertEq(account.listed, account.stake + account.warming >= SEAT_LOCK);
            principal += account.stake + account.warming;
        }
        assertEq(registry.totalStaked(), principal);
        assertEq(
            registry.depositsReceived(), registry.withdrawalsPaid() + registry.penaltiesSent() + registry.totalStaked()
        );
        address[] memory listed = registry.listedAccounts();
        for (uint256 i; i < listed.length; ++i) {
            assertTrue(registry.accountOf(listed[i]).listed);
        }
    }

    /// @dev II-08.
    function invariant_AtMostOneDisputePerOrder() public view {
        for (uint256 i; i < handler.orderCount(); ++i) {
            WorkOrder order = handler.orders(i);
            uint256 disputeId = order.disputeId();
            assertEq(disputeId, handler.ghostDisputeId(order));
            WorkOrder.OrderStatus status = order.status();
            bool byRuling = status == WorkOrder.OrderStatus.Terminated
                && order.getMilestone(order.currentMilestone()).status == WorkOrder.MilestoneStatus.Disputed;
            assertEq(disputeId != 0, status == WorkOrder.OrderStatus.Disputed || byRuling);
            if (disputeId != 0) {
                assertEq(court.getDispute(disputeId).order, address(order));
                for (uint256 j; j < i; ++j) {
                    assertTrue(handler.orders(j).disputeId() != disputeId);
                }
            }
        }
    }

    function afterInvariant() public virtual {
        _logTransitions();
        handler.settleEverything();
        assertEq(court.pendingFees(), 0);
        assertEq(court.totalClaimable(), 0);
        for (uint256 i; i < handler.orderCount(); ++i) {
            WorkOrder.OrderStatus status = handler.orders(i).status();
            assertTrue(status != WorkOrder.OrderStatus.Disputed);
            if (status == WorkOrder.OrderStatus.Terminated || status == WorkOrder.OrderStatus.Completed) {
                assertEq(handler.orders(i).outstandingObligations(), 0);
            }
        }
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            IArbitratorRegistry.Account memory account = registry.accountOf(handler.actors(i));
            assertEq(account.locked, 0);
            assertEq(account.reserved, 0);
        }
        this.checkInvariants();
    }

    /// @dev Replays 32 pseudo-random campaigns of 128 handler calls with every invariant checked after each call and
    /// asserts that each funding, settlement, ruling, terminal and rejection transition was reached.
    function test_RandomCampaignsReachEveryTransition() public {
        vm.pauseGasMetering();
        uint256[21] memory totals;
        for (uint256 campaign; campaign < 32; ++campaign) {
            uint256 state = vm.snapshotState();
            for (uint256 step; step < 128; ++step) {
                _randomCall(uint256(keccak256(abi.encode(campaign, step))));
                this.checkInvariants();
            }
            handler.settleEverything();
            this.checkInvariants();
            uint256[21] memory counts = _counts();
            for (uint256 k; k < 21; ++k) {
                totals[k] += counts[k];
            }
            vm.revertToState(state);
        }
        string[21] memory names = [
            "fundedDirectly",
            "fundedWithPermit",
            "fundedByPermitFallback",
            "settledByClient",
            "settledBySignature",
            "settledByTimeout",
            "completedOrders",
            "expiredOrders",
            "disputesOpened",
            "rulingsFreelancerMajority",
            "rulingsClientMajority",
            "rulingsSplit",
            "rulingsNoPanel",
            "rulingsApplied",
            "rejectedStaleSignatures",
            "orderClaims",
            "retries",
            "draws",
            "rearms",
            "reveals",
            "faults"
        ];
        for (uint256 k; k < 21; ++k) {
            console.log(names[k], totals[k]);
        }
        for (uint256 k; k < 21; ++k) {
            assertGt(totals[k], 0, names[k]);
        }
    }

    function checkInvariants() external view {
        invariant_OrderFundsConserved();
        invariant_BalancesAndProvenance();
        invariant_OutstandingMatchesStatus();
        invariant_NonceInvariant();
        invariant_CourtAccounting();
        invariant_RegistryAccounting();
        invariant_AtMostOneDisputePerOrder();
    }

    function _randomCall(uint256 seed) internal virtual {
        uint256 a = uint256(keccak256(abi.encode(seed, 1)));
        uint256 b = uint256(keccak256(abi.encode(seed, 2)));
        uint256 action = seed % 31;
        if (action < 1) handler.createOrder(a, b);
        else if (action < 3) handler.fund(a, b);
        else if (action < 7) handler.submit(a);
        else if (action < 11) handler.settle(a, b);
        else if (action < 12) handler.reclaim(a, b);
        else if (action < 14) handler.openDispute(a);
        else if (action < 15) handler.retrySnapshot(a);
        else if (action < 17) handler.drawPanel(a, (seed >> 16) % 8 == 0, bytes32(b));
        else if (action < 18) handler.commitVote(a, bytes32(b));
        else if (action < 19) handler.revealVote(a, b);
        else if (action < 21) handler.castVotes(a, bytes32(b));
        else if (action < 22) handler.resolve(a, b);
        else if (action < 23) handler.applyRuling(a);
        else if (action < 24) handler.claimOrder(a, b);
        else if (action < 25) handler.claimCourt(a);
        else if (action < 26) handler.replayStaleSignature(a);
        else if (action < 27) handler.deposit(a, b);
        else if (action < 28) handler.withdraw(a, b);
        else if (action < 29) handler.warp(a);
        else if (action < 30) handler.roll(a);
        else handler.donate(a, (seed >> 24) % 2 == 0, b);
    }

    function _counts() internal view returns (uint256[21] memory counts) {
        counts = [
            handler.fundedDirectly(),
            handler.fundedWithPermit(),
            handler.fundedByPermitFallback(),
            handler.settledByClient(),
            handler.settledBySignature(),
            handler.settledByTimeout(),
            handler.completedOrders(),
            handler.expiredOrders(),
            handler.disputesOpened(),
            handler.rulingsFreelancerMajority(),
            handler.rulingsClientMajority(),
            handler.rulingsSplit(),
            handler.rulingsNoPanel(),
            handler.rulingsApplied(),
            handler.rejectedStaleSignatures(),
            handler.orderClaims(),
            handler.retries(),
            handler.draws(),
            handler.rearms(),
            handler.reveals(),
            handler.faults()
        ];
    }

    function _commitmentsOf(address actor) internal view returns (uint256 reservations, uint256 seats) {
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
    }

    function _logTransitions() internal view {
        uint256[21] memory counts = _counts();
        console.log(
            string.concat(
                "integration funded=",
                vm.toString(counts[0] + counts[1] + counts[2]),
                " settled=",
                vm.toString(counts[3] + counts[4] + counts[5]),
                " completed=",
                vm.toString(counts[6]),
                " expired=",
                vm.toString(counts[7]),
                " disputes=",
                vm.toString(counts[8]),
                " rulingsApplied=",
                vm.toString(counts[13]),
                " staleSignatures=",
                vm.toString(counts[14]),
                " orderClaims=",
                vm.toString(counts[15])
            )
        );
    }
}

contract TrustWorkIntegrationSharedTokenInvariantTest is TrustWorkIntegrationInvariantTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkIntegrationSplitTokenInvariantTest is TrustWorkIntegrationInvariantTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
