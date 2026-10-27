// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {TrustWorkReputation} from "../../src/TrustWorkReputation.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";
import {MockReputationCourt, MockReputationFactory, MockReputationOrder} from "../mocks/MockReputationSources.sol";
import {ReputationTestBase} from "../utils/ReputationTestBase.sol";

abstract contract TrustWorkReputationTest is ReputationTestBase {
    event OrderRegistered(
        address indexed order, ITrustWorkReputation.Outcome outcome, address indexed client, address indexed freelancer
    );

    ITrustWorkReputation.Role internal constant CLIENT_ROLE = ITrustWorkReputation.Role.Client;
    ITrustWorkReputation.Role internal constant FREELANCER_ROLE = ITrustWorkReputation.Role.Freelancer;

    /// @dev RA-01.
    function test_Constructor_BindsFactoryAndHasNoAdministration() public {
        assertEq(address(reputation.factory()), address(factory));
        assertLt(address(reputation).code.length, 24_576);
        vm.expectRevert(ITrustWorkReputation.ZeroFactory.selector);
        new TrustWorkReputation(TrustWorkFactory(address(0)));
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.FactoryHasNoCode.selector, stranger));
        new TrustWorkReputation(TrustWorkFactory(stranger));

        bytes[5] memory administrative = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("transferOwnership(address)", stranger),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setFactory(address)", stranger),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", stranger, "")
        ];
        for (uint256 i; i < administrative.length; ++i) {
            (bool success,) = address(reputation).call(administrative[i]);
            assertFalse(success);
        }
    }

    /// @dev RA-02.
    function test_Register_AcceptsEligibleFactoryOrder() public {
        Scenario memory s = _completed(_defaultAmounts());
        vm.expectEmit(address(reputation));
        emit OrderRegistered(address(s.order), ITrustWorkReputation.Outcome.Completed, client, freelancer);
        _register(s);
    }

    /// @dev RA-03, RA-04, RA-05.
    function test_RevertWhen_OrderNotCreatedByBoundFactory() public {
        IArbitrationCourt orderCourt = factory.court();
        WorkOrder direct = new WorkOrder(
            client,
            freelancer,
            paymentToken,
            feeRecipient,
            FEE_BPS,
            REVIEW_PERIOD,
            DELIVERY_PERIOD,
            orderCourt,
            _defaultAmounts()
        );
        _expectUnknown(address(direct));

        TrustWorkFactory other = new TrustWorkFactory(stakeToken, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        vm.prank(client);
        WorkOrder foreign = other.createWorkOrder(
            freelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        _expectUnknown(address(foreign));

        _expectUnknown(stranger);
        _expectUnknown(address(court));
        _expectUnknown(address(registry));
        _expectUnknown(address(0));

        MockReputationOrder mimic = new MockReputationOrder(factory.court());
        vm.expectCall(address(mimic), "", 0);
        _expectUnknown(address(mimic));
    }

    /// @dev RA-06.
    function test_RevertWhen_FactsOfUnregisteredOrder() public {
        WorkOrder order = _createDefaultOrder();
        address[3] memory targets = [address(order), stranger, address(0)];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NotRegistered.selector, targets[i]));
            reputation.factsOf(targets[i]);
        }
    }

    /// @dev RE-01, RE-02, RG-03.
    function test_RevertWhen_OrderUnfundedOrActive() public {
        WorkOrder order = _createDefaultOrder();
        _expectNotFinal(order, WorkOrder.OrderStatus.Unfunded);
        _fund(order);
        _expectNotFinal(order, WorkOrder.OrderStatus.Active);
        _submit(order, 0);
        _expectNotFinal(order, WorkOrder.OrderStatus.Active);
        _approve(order, 0);
        _submit(order, 1);
        _expectNotFinal(order, WorkOrder.OrderStatus.Active);
    }

    /// @dev RE-03, RE-04.
    function test_RevertWhen_OrderDisputedUntilRulingApplied() public {
        Scenario memory pending = _start(_arbitrator(0), _defaultAmounts());
        uint256 pendingId = _openDispute(pending.order, 0);
        assertEq(
            uint256(court.getDispute(pendingId).status), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates)
        );
        _expectNotFinal(pending.order, WorkOrder.OrderStatus.Disputed);

        Scenario memory s = _start(feeRecipient, _defaultAmounts());
        uint256 disputeId = _openDispute(s.order, 0);
        assertEq(uint256(court.getDispute(disputeId).status), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
        _expectNotFinal(s.order, WorkOrder.OrderStatus.Disputed);
        _drawPanel(disputeId);
        assertEq(uint256(court.getDispute(disputeId).status), uint256(IArbitrationCourt.DisputeStatus.Voting));
        _expectNotFinal(s.order, WorkOrder.OrderStatus.Disputed);

        vm.warp(court.getDispute(disputeId).revealDeadline);
        court.resolve(disputeId);
        assertEq(uint256(court.getDispute(disputeId).status), uint256(IArbitrationCourt.DisputeStatus.Resolved));
        _expectNotFinal(s.order, WorkOrder.OrderStatus.Disputed);
        assertEq(uint256(s.order.status()), uint256(WorkOrder.OrderStatus.Disputed));

        s.order.applyRuling();
        assertEq(uint256(reputation.register(address(s.order))), uint256(ITrustWorkReputation.Outcome.Split));
    }

    /// @dev RE-05, RE-14.
    function test_Register_Completed() public {
        Scenario memory s = _completed(_defaultAmounts());
        _register(s);
        _assertStats(client, CLIENT_ROLE, _one(ITrustWorkReputation.Outcome.Completed), 3);
        _assertStats(freelancer, FREELANCER_ROLE, _one(ITrustWorkReputation.Outcome.Completed), 3);
    }

    /// @dev RE-06, RE-16 (Pending), RG-01.
    function test_RevertWhen_ExpiredBeforeAnySubmission() public {
        Scenario memory s = _expired(_defaultAmounts(), 0);
        assertEq(uint256(s.order.status()), uint256(WorkOrder.OrderStatus.Terminated));
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NoParticipation.selector, address(s.order)));
        reputation.register(address(s.order));
        _assertStats(freelancer, FREELANCER_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
        _assertStats(client, CLIENT_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
    }

    /// @dev RE-07, RG-04.
    function test_Register_DeliveryExpiredAfterParticipation() public {
        for (uint256 index = 1; index < 3; ++index) {
            uint256 state = vm.snapshotState();
            Scenario memory s = _expired(_defaultAmounts(), index);
            _register(s);
            _assertStats(freelancer, FREELANCER_ROLE, _one(ITrustWorkReputation.Outcome.DeliveryExpired), index);
            vm.revertToState(state);
        }
    }

    /// @dev RE-08 … RE-11, RE-16 (`Disputed` first milestone): every supported ruling and reason.
    function test_Register_EveryRulingOutcome() public {
        for (uint256 o; o < 5; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory s = _ruled(_defaultAmounts(), 1, Outcome(o));
            _register(s);
            ITrustWorkReputation.Outcome expected = _toReputation(Outcome(o));
            _assertStats(freelancer, FREELANCER_ROLE, _one(expected), 1);
            _assertStats(client, CLIENT_ROLE, _one(expected), 1);
            vm.revertToState(state);
        }
    }

    /// @dev RE-11: `NoPanel` from `AwaitingCandidates` and from `AwaitingSeed`; never counted as a win.
    function test_Register_NoPanelFromBothWaitingStates() public {
        address[2] memory feeRecipients = [_arbitrator(0), feeRecipient];
        for (uint256 i; i < 2; ++i) {
            uint256 state = vm.snapshotState();
            Scenario memory s = _ruledWith(feeRecipients[i], _defaultAmounts(), 0, Outcome.NoPanel);
            assertEq(uint256(s.order.getMilestone(0).status), uint256(WorkOrder.MilestoneStatus.Disputed));
            _register(s);
            ITrustWorkReputation.Stats memory stats = _statsOf(freelancer, FREELANCER_ROLE);
            assertEq(stats.noPanel, 1);
            assertEq(stats.freelancerWins, 0);
            vm.revertToState(state);
        }
    }

    /// @dev RE-12: every feasible terminal position.
    function test_Register_EveryFeasibleTerminalPosition() public {
        uint256 cases;
        for (uint256 o; o < 5; ++o) {
            for (uint256 index; index < 3; ++index) {
                uint256 state = vm.snapshotState();
                _register(_ruled(_defaultAmounts(), index, Outcome(o)));
                vm.revertToState(state);
                ++cases;
            }
        }
        for (uint256 index = 1; index < 3; ++index) {
            uint256 state = vm.snapshotState();
            _register(_expired(_defaultAmounts(), index));
            vm.revertToState(state);
            ++cases;
        }
        uint256 completedState = vm.snapshotState();
        _register(_completed(_defaultAmounts()));
        vm.revertToState(completedState);
        ++cases;
        assertEq(cases, 18);
    }

    /// @dev RE-13: registering before, between or after claims gives the same classification, facts, counters and
    /// lists; full records match when registration time is the same.
    function test_Register_IndependentOfClaimTiming() public {
        for (uint256 o; o < 6; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory s = o == 5 ? _expired(_defaultAmounts(), 1) : _ruled(_defaultAmounts(), 1, Outcome(o));
            bytes32[3] memory factsHash;
            bytes32[3] memory statsHash;
            uint256 registrationTime = block.timestamp + 1 days;
            for (uint256 schedule; schedule < 3; ++schedule) {
                uint256 inner = vm.snapshotState();
                if (schedule >= 1) _claimIfCredited(s.order, freelancer);
                if (schedule == 2) {
                    _claimIfCredited(s.order, client);
                    _claimIfCredited(s.order, feeRecipient);
                    if (s.disputeId != 0) _claimCourtCredits(s.disputeId);
                }
                vm.warp(registrationTime + schedule);
                reputation.register(address(s.order));
                (, uint64 registeredAt,) = reputation.records(address(s.order));
                assertEq(registeredAt, registrationTime + schedule);
                factsHash[schedule] = keccak256(abi.encode(reputation.factsOf(address(s.order))));
                statsHash[schedule] = keccak256(
                    abi.encode(
                        _statsOf(client, CLIENT_ROLE),
                        _statsOf(freelancer, FREELANCER_ROLE),
                        reputation.ordersOf(client, CLIENT_ROLE, 0, 10),
                        reputation.ordersOf(freelancer, FREELANCER_ROLE, 0, 10)
                    )
                );
                vm.revertToState(inner);
            }
            assertEq(factsHash[0], factsHash[1]);
            assertEq(factsHash[0], factsHash[2]);
            assertEq(statsHash[0], statsHash[1]);
            assertEq(statsHash[0], statsHash[2]);

            uint256 sameTime = vm.snapshotState();
            vm.warp(registrationTime);
            reputation.register(address(s.order));
            bytes32 beforeClaims = _recordHash(address(s.order));
            vm.revertToState(sameTime);
            _claimIfCredited(s.order, client);
            _claimIfCredited(s.order, freelancer);
            vm.warp(registrationTime);
            reputation.register(address(s.order));
            assertEq(_recordHash(address(s.order)), beforeClaims);
            vm.revertToState(state);
        }
    }

    /// @dev RE-15: a submission at block timestamp 0 stores `submittedAt == 0` but still proves participation.
    function test_Register_ZeroTimestampSubmissionIsParticipation() public {
        vm.warp(0);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 * USDC;
        amounts[1] = 200 * USDC;
        WorkOrder order = _createOrder(client, feeRecipient, amounts);
        _fund(order);
        _submit(order, 0);
        assertEq(order.getMilestone(0).submittedAt, 0);
        _approve(order, 0);
        vm.warp(10);
        _submit(order, 1);
        _approve(order, 1);

        reputation.register(address(order));
        ITrustWorkReputation.OrderFacts memory facts = reputation.factsOf(address(order));
        assertEq(uint256(facts.outcome), uint256(ITrustWorkReputation.Outcome.Completed));
        assertEq(facts.fundedAt, 0);
        assertEq(facts.lastSubmittedAt, 10);

        WorkOrder expired = _createOrder(client, feeRecipient, amounts);
        vm.warp(0);
        _fund(expired);
        _submit(expired, 0);
        _approve(expired, 0);
        vm.warp(DELIVERY_PERIOD);
        vm.prank(client);
        expired.reclaimAfterDeliveryExpiry();
        reputation.register(address(expired));
        facts = reputation.factsOf(address(expired));
        assertEq(uint256(facts.outcome), uint256(ITrustWorkReputation.Outcome.DeliveryExpired));
        assertEq(facts.lastSubmittedAt, 0);
    }

    /// @dev RG-02: unsolicited orders naming a victim who never acts cannot touch the victim's record.
    function test_UnsolicitedOrders_NeverAffectInactiveVictim() public {
        address victim = freelancer;
        for (uint256 i; i < 10; ++i) {
            address sender = makeAddr(string.concat("unsolicitedClient", vm.toString(i)));
            WorkOrder order = _createOrder(sender, feeRecipient, _defaultAmounts());
            uint256 total = order.totalAmount();
            paymentToken.mint(sender, total);
            vm.prank(sender);
            paymentToken.approve(address(order), total);
            vm.prank(sender);
            order.fund();
            vm.warp(order.getMilestone(0).deliveryDeadline);
            vm.prank(sender);
            order.reclaimAfterDeliveryExpiry();
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NoParticipation.selector, address(order)));
            reputation.register(address(order));
        }
        _assertStats(victim, FREELANCER_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
        assertEq(reputation.ordersOf(victim, FREELANCER_ROLE, 0, 100).length, 0);
    }

    /// @dev RG-06: the losing freelancer can neither prevent nor repeat the registration.
    function test_Hiding_LosingPartyCannotBlockOrUndo() public {
        Scenario memory s = _ruled(_defaultAmounts(), 1, Outcome.ClientMajority);
        uint256 state = vm.snapshotState();
        vm.prank(client);
        reputation.register(address(s.order));
        vm.revertToState(state);
        vm.prank(stranger);
        reputation.register(address(s.order));
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.AlreadyRegistered.selector, address(s.order)));
        vm.prank(freelancer);
        reputation.register(address(s.order));
        assertEq(_statsOf(freelancer, FREELANCER_ROLE).clientWins, 1);
    }

    /// @dev RG-07, RG-08: wash orders in a worthless token and one-unit milestones register like any other order.
    function test_WashAndNegligibleOrders_RegisterWithInspectableFacts() public {
        MockPermitUSDC worthless = new MockPermitUSDC();
        address controllerClient = makeAddr("controllerClient");
        uint256[] memory units = new uint256[](2);
        units[0] = 1;
        units[1] = 1;
        vm.prank(controllerClient);
        WorkOrder wash = factory.createWorkOrder(
            freelancer, worthless, controllerClient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, units
        );
        worthless.mint(controllerClient, 2);
        vm.prank(controllerClient);
        worthless.approve(address(wash), 2);
        vm.prank(controllerClient);
        wash.fund();
        for (uint256 i; i < 2; ++i) {
            vm.prank(freelancer);
            wash.submitMilestone(i);
            vm.prank(controllerClient);
            wash.approveMilestone(i);
        }
        reputation.register(address(wash));
        ITrustWorkReputation.OrderFacts memory facts = reputation.factsOf(address(wash));
        assertEq(facts.token, address(worthless));
        assertEq(facts.totalAmount, 2);
        assertEq(facts.client, controllerClient);
        assertEq(_statsOf(freelancer, FREELANCER_ROLE).completed, 1);
    }

    /// @dev RS-01, RS-10: the worked examples of design §5.4 with literal expected amounts.
    function test_WorkedExamples() public {
        uint256[7] memory awarded = [uint256(4000), 1000, 3500, 1000, 2250, 3500, 2250];
        uint256[7] memory returned = [uint256(0), 3000, 500, 3000, 1750, 500, 1750];
        for (uint256 row; row < 7; ++row) {
            uint256 state = vm.snapshotState();
            Scenario memory s;
            if (row == 0) s = _completed(_defaultAmounts());
            else if (row == 1) s = _expired(_defaultAmounts(), 1);
            else s = _ruled(_defaultAmounts(), 1, _workedExampleRuling(row));
            ITrustWorkReputation.OrderFacts memory facts = _register(s);
            assertEq(facts.freelancerAwarded, awarded[row] * USDC);
            assertEq(facts.clientReturned, returned[row] * USDC);
            assertEq(facts.settledAmount, row == 0 ? 4000 * USDC : 1000 * USDC);
            assertEq(facts.disputedAmount, row >= 2 ? 2500 * USDC : 0);
            vm.revertToState(state);
        }

        uint256[] memory odd = new uint256[](2);
        odd[0] = 7;
        odd[1] = 3000 * USDC;
        ITrustWorkReputation.OrderFacts memory split = _register(_ruled(odd, 0, Outcome.SplitByTie));
        assertEq(split.freelancerAwarded, 3);
        assertEq(split.clientReturned, 4 + 3000 * USDC);
    }

    /// @dev RS-02: a second registration of every outcome reverts and changes nothing.
    function test_RevertWhen_RegisteredTwice() public {
        for (uint256 o; o < 6; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory s = o == 5 ? _completed(_defaultAmounts()) : _ruled(_defaultAmounts(), 1, Outcome(o));
            reputation.register(address(s.order));
            bytes32 before = _reputationState(address(s.order));
            vm.warp(block.timestamp + 1 days);
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.AlreadyRegistered.selector, address(s.order)));
            reputation.register(address(s.order));
            assertEq(_reputationState(address(s.order)), before);
            vm.revertToState(state);
        }
    }

    /// @dev RS-03: the fee-recipient position grants no extra entitlement.
    function test_RoleOverlap_FeeRecipientPositionGrantsNothing() public {
        Scenario memory plain = _ruled(_defaultAmounts(), 1, Outcome.FreelancerMajority);
        reputation.register(address(plain.order));
        Scenario memory clientCollects = _ruledWith(client, _defaultAmounts(), 1, Outcome.FreelancerMajority);
        reputation.register(address(clientCollects.order));
        Scenario memory freelancerCollects = _ruledWith(freelancer, _defaultAmounts(), 1, Outcome.FreelancerMajority);
        reputation.register(address(freelancerCollects.order));

        uint256[6] memory three = [uint256(0), 0, 3, 0, 0, 0];
        _assertStats(client, CLIENT_ROLE, three, 3);
        _assertStats(freelancer, FREELANCER_ROLE, three, 3);
        _assertStats(client, FREELANCER_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
        _assertStats(freelancer, CLIENT_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
        _assertStats(feeRecipient, CLIENT_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
        _assertStats(feeRecipient, FREELANCER_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
        assertEq(
            keccak256(abi.encode(reputation.factsOf(address(clientCollects.order)))),
            keccak256(abi.encode(_withOrder(reputation.factsOf(address(plain.order)), clientCollects)))
        );
    }

    /// @dev RS-04: one account in two roles keeps separate statistics.
    function test_RoleStatistics_SeparatePerRole() public {
        reputation.register(address(_completed(_defaultAmounts()).order));
        address otherFreelancer = makeAddr("otherFreelancer");
        vm.prank(freelancer);
        WorkOrder asClient = factory.createWorkOrder(
            otherFreelancer, paymentToken, feeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, _defaultAmounts()
        );
        ledger.trackOrder(address(asClient));
        _fund(asClient);
        for (uint256 i; i < 3; ++i) {
            vm.prank(otherFreelancer);
            asClient.submitMilestone(i);
            vm.prank(freelancer);
            asClient.approveMilestone(i);
        }
        reputation.register(address(asClient));
        _assertStats(freelancer, FREELANCER_ROLE, _one(ITrustWorkReputation.Outcome.Completed), 3);
        _assertStats(freelancer, CLIENT_ROLE, _one(ITrustWorkReputation.Outcome.Completed), 3);
        assertEq(reputation.ordersOf(freelancer, CLIENT_ROLE, 0, 10)[0], address(asClient));
        _assertStats(otherFreelancer, FREELANCER_ROLE, _one(ITrustWorkReputation.Outcome.Completed), 3);
    }

    /// @dev RS-05, RS-06, RS-07, RS-09: a mixed sequence of every outcome.
    function test_Statistics_PartitionMilestonesAndDerivedShares() public {
        uint256[6] memory counts;
        uint256 milestones;
        address[] memory registered = new address[](8);
        Scenario[8] memory scenarios = [
            _completed(_defaultAmounts()),
            _completed(_defaultAmounts()),
            _expired(_defaultAmounts(), 2),
            _ruled(_defaultAmounts(), 0, Outcome.FreelancerMajority),
            _ruled(_defaultAmounts(), 1, Outcome.FreelancerMajority),
            _ruled(_defaultAmounts(), 2, Outcome.ClientMajority),
            _ruled(_defaultAmounts(), 1, Outcome.SplitByTie),
            _ruled(_defaultAmounts(), 1, Outcome.NoPanel)
        ];
        for (uint256 i; i < 8; ++i) {
            vm.expectEmit(address(reputation));
            emit OrderRegistered(address(scenarios[i].order), scenarios[i].outcome, client, freelancer);
            reputation.register(address(scenarios[i].order));
            ++counts[uint256(scenarios[i].outcome) - 1];
            milestones += scenarios[i].settled;
            registered[i] = address(scenarios[i].order);
        }
        _assertStats(freelancer, FREELANCER_ROLE, counts, milestones);
        _assertStats(client, CLIENT_ROLE, counts, milestones);
        assertEq(milestones, 3 + 3 + 2 + 0 + 1 + 2 + 1 + 1);

        ITrustWorkReputation.Stats memory stats = _statsOf(freelancer, FREELANCER_ROLE);
        assertEq(stats.completed * 10_000 / stats.registered, 2500);
        assertEq(stats.freelancerWins * 10_000 / (stats.freelancerWins + stats.clientWins), 6666);
        address[] memory listed = reputation.ordersOf(freelancer, FREELANCER_ROLE, 0, 8);
        for (uint256 i; i < 8; ++i) {
            assertEq(listed[i], registered[i]);
        }
        ITrustWorkReputation.Stats memory empty = _statsOf(stranger, FREELANCER_ROLE);
        assertEq(empty.freelancerWins + empty.clientWins, 0);
    }

    /// @dev RS-08, RS-11, RS-12: paging boundaries, including `type(uint256).max` inputs.
    function test_OrdersOf_PagingBoundaries() public {
        address[] memory registered = new address[](3);
        for (uint256 i; i < 3; ++i) {
            Scenario memory s = _completed(_defaultAmounts());
            reputation.register(address(s.order));
            registered[i] = address(s.order);
        }
        uint256 max = type(uint256).max;
        uint256[2][9] memory requests = [
            [uint256(0), 0],
            [uint256(0), 2],
            [uint256(1), 2],
            [uint256(0), 3],
            [uint256(2), 5],
            [uint256(3), 1],
            [max, 1],
            [uint256(1), max],
            [max, max]
        ];
        uint256[9] memory lengths = [uint256(0), 2, 2, 3, 1, 0, 0, 2, 0];
        for (uint256 r; r < requests.length; ++r) {
            address[] memory page = reputation.ordersOf(freelancer, FREELANCER_ROLE, requests[r][0], requests[r][1]);
            assertEq(page.length, lengths[r]);
            for (uint256 i; i < page.length; ++i) {
                assertEq(page[i], registered[requests[r][0] + i]);
            }
        }
        assertEq(reputation.ordersOf(stranger, CLIENT_ROLE, 0, max).length, 0);
        _assertStats(stranger, CLIENT_ROLE, [uint256(0), 0, 0, 0, 0, 0], 0);
    }

    /// @dev RU-01: registration changes no escrow, court or registry state and moves no token.
    function test_Register_LeavesEscrowCourtAndRegistryUnchanged() public {
        for (uint256 o; o < 7; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory s = o == 5
                ? _completed(_defaultAmounts())
                : o == 6 ? _expired(_defaultAmounts(), 1) : _ruled(_defaultAmounts(), 1, Outcome(o));
            bytes32 before = _escrowState(s.order);
            _registerWithoutTransfers(address(s.order));
            assertEq(_escrowState(s.order), before);
            reputation.factsOf(address(s.order));
            assertEq(_escrowState(s.order), before);
            vm.revertToState(state);
        }
    }

    /// @dev RU-02, RU-03: claims behave identically with or without a registration, before or after it.
    function test_Claims_IdenticalWithOrWithoutRegistration() public {
        for (uint256 o; o < 5; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory s = _ruled(_defaultAmounts(), 1, Outcome(o));
            uint256 branch = vm.snapshotState();
            _claimEverything(s);
            bytes32 withoutRegistration = _escrowState(s.order);
            vm.revertToState(branch);
            reputation.register(address(s.order));
            _claimEverything(s);
            assertEq(_escrowState(s.order), withoutRegistration);
            vm.revertToState(branch);
            _claimIfCredited(s.order, client);
            reputation.register(address(s.order));
            _claimIfCredited(s.order, freelancer);
            _claimIfCredited(s.order, feeRecipient);
            _claimCourtCredits(s.disputeId);
            assertEq(_escrowState(s.order), withoutRegistration);
            vm.revertToState(state);
        }
    }

    /// @dev RN-01, RN-02: near-maximum totals register exactly, twice for the same accounts, with no aggregate to
    /// overflow.
    function test_NearMaximumTotals_RegisterWithoutOverflow() public {
        uint256 total = (type(uint256).max - 1e15) / 2;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000 * USDC;
        amounts[1] = (total - amounts[0]) / 2 + 1;
        amounts[2] = total - amounts[0] - amounts[1];
        Outcome[3] memory rulings = [Outcome.SplitByTie, Outcome.FreelancerMajority, Outcome.ClientMajority];
        for (uint256 o; o < 3; ++o) {
            uint256 state = vm.snapshotState();
            Scenario memory first = _ruled(amounts, 1, rulings[o]);
            Scenario memory second = _ruled(amounts, 1, rulings[o]);
            ITrustWorkReputation.OrderFacts memory facts = _register(first);
            _register(second);
            assertEq(facts.totalAmount, total);
            assertEq(facts.freelancerAwarded + facts.clientReturned, total);
            ITrustWorkReputation.Stats memory stats = _statsOf(freelancer, FREELANCER_ROLE);
            assertEq(stats.registered, 2);
            vm.revertToState(state);
        }
        Scenario memory completedFirst = _completed(amounts);
        Scenario memory completedSecond = _completed(amounts);
        _register(completedFirst);
        _register(completedSecond);
        assertEq(_statsOf(client, CLIENT_ROLE).completed, 2);
    }

    /// @dev RN-03: one-unit milestones and the fee bounds.
    function test_UnitMilestonesAndFeeBounds() public {
        uint256[] memory units = new uint256[](3);
        units[0] = 1;
        units[1] = 1;
        units[2] = 1;
        uint256[2] memory bpsValues = [uint256(0), 1000];
        for (uint256 b; b < 2; ++b) {
            vm.prank(client);
            WorkOrder order = factory.createWorkOrder(
                freelancer, paymentToken, feeRecipient, bpsValues[b], REVIEW_PERIOD, DELIVERY_PERIOD, units
            );
            ledger.trackOrder(address(order));
            _fund(order);
            _submitAndApprove(order, 0);
            _openDispute(order, 1);
            _resolveAs(order.disputeId(), Outcome.SplitByTie);
            _applyRuling(order);
            reputation.register(address(order));
            ITrustWorkReputation.OrderFacts memory facts = reputation.factsOf(address(order));
            assertEq(facts.settledAmount, 1);
            assertEq(facts.disputedAmount, 1);
            assertEq(facts.freelancerAwarded, 1);
            assertEq(facts.clientReturned, 2);
        }
    }

    /// @dev RN-04: an order with 50 milestones.
    function test_ManyMilestones_Completed() public {
        uint256[] memory amounts = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            amounts[i] = (i + 1) * USDC;
        }
        Scenario memory s = _completed(amounts);
        _register(s);
        _assertStats(freelancer, FREELANCER_ROLE, _one(ITrustWorkReputation.Outcome.Completed), 50);
    }

    /// @dev Rows 2–6 of design §5.4: FreelancerWins, ClientWins, Split by tie, NoPanel, Split by zero reveals.
    function _workedExampleRuling(uint256 row) private pure returns (Outcome) {
        if (row == 5) return Outcome.NoPanel;
        if (row == 6) return Outcome.SplitByZeroReveals;
        return Outcome(row - 2);
    }

    function _expectUnknown(address target) private {
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.UnknownOrder.selector, target));
        reputation.register(target);
    }

    function _expectNotFinal(WorkOrder order, WorkOrder.OrderStatus status) private {
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.OrderNotFinal.selector, address(order), status));
        reputation.register(address(order));
    }

    function _claimIfCredited(WorkOrder order, address account) private {
        if (order.claimable(account) != 0) order.claimPayout(account);
    }

    function _claimEverything(Scenario memory s) private {
        _claimIfCredited(s.order, client);
        _claimIfCredited(s.order, freelancer);
        _claimIfCredited(s.order, feeRecipient);
        _claimCourtCredits(s.disputeId);
    }

    function _recordHash(address order) private view returns (bytes32) {
        (ITrustWorkReputation.Outcome outcome, uint64 registeredAt, uint8 receiptsClaimed) = reputation.records(order);
        return keccak256(abi.encode(outcome, registeredAt, receiptsClaimed));
    }

    function _reputationState(address order) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _recordHash(order),
                reputation.factsOf(order),
                _statsOf(client, CLIENT_ROLE),
                _statsOf(freelancer, FREELANCER_ROLE),
                reputation.ordersOf(client, CLIENT_ROLE, 0, type(uint256).max),
                reputation.ordersOf(freelancer, FREELANCER_ROLE, 0, type(uint256).max)
            )
        );
    }

    /// @dev Facts of `baseline` with the time fields and dispute ID of `s`, for comparing structurally equal orders.
    function _withOrder(ITrustWorkReputation.OrderFacts memory baseline, Scenario memory s)
        private
        pure
        returns (ITrustWorkReputation.OrderFacts memory)
    {
        baseline.disputeId = s.disputeId;
        baseline.fundedAt = s.fundedAt;
        baseline.lastSubmittedAt = s.lastSubmittedAt;
        baseline.closedNotBefore = s.closedNotBefore;
        return baseline;
    }
}

contract TrustWorkReputationSharedTokenTest is TrustWorkReputationTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkReputationSplitTokenTest is TrustWorkReputationTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}

/// @dev RA-07, RA-08, RA-09: consistency guards that the accepted contracts cannot trigger, reached with mocks.
contract TrustWorkReputationGuardTest is ReputationTestBase {
    MockReputationCourt internal mockCourt;
    MockReputationFactory internal mockFactory;
    TrustWorkReputation internal guarded;

    function _sharedToken() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        mockCourt = new MockReputationCourt();
        mockFactory = new MockReputationFactory(IArbitrationCourt(address(mockCourt)));
        guarded = new TrustWorkReputation(TrustWorkFactory(address(mockFactory)));
    }

    function test_RevertWhen_OrderCourtDiffersFromFactoryCourt() public {
        MockReputationOrder order = new MockReputationOrder(IArbitrationCourt(address(court)));
        mockFactory.recognize(address(order));
        vm.expectRevert(
            abi.encodeWithSelector(ITrustWorkReputation.CourtMismatch.selector, address(order), address(court))
        );
        guarded.register(address(order));
    }

    function test_RevertWhen_DisputeRecordInconsistent() public {
        MockReputationOrder order = _mockOrder();
        IArbitrationCourt.Dispute memory dispute = _dispute(address(order), 1);
        dispute.order = stranger;
        mockCourt.setDispute(1, dispute);
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.InconsistentDispute.selector, address(order), 1));
        guarded.register(address(order));

        mockCourt.setDispute(1, _dispute(address(order), 0));
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.InconsistentDispute.selector, address(order), 1));
        guarded.register(address(order));

        mockCourt.setDispute(1, _dispute(address(order), 1));
        assertEq(uint256(guarded.register(address(order))), uint256(ITrustWorkReputation.Outcome.FreelancerWins));
    }

    function test_RevertWhen_RulingReasonPairUnsupported() public {
        uint256 supported;
        for (uint256 r; r < 4; ++r) {
            for (uint256 q; q < 4; ++q) {
                IArbitrationCourt.Ruling ruling = IArbitrationCourt.Ruling(r);
                IArbitrationCourt.RulingReason reason = IArbitrationCourt.RulingReason(q);
                bool isSupported = (r == 1 && (q == 1 || q == 2)) || (r == 2 && q == 1) || (r == 3 && q == 3);
                MockReputationOrder order = _mockOrder();
                IArbitrationCourt.Dispute memory dispute = _dispute(address(order), 1);
                dispute.ruling = ruling;
                dispute.reason = reason;
                mockCourt.setDispute(1, dispute);
                if (isSupported) {
                    guarded.register(address(order));
                    ++supported;
                } else {
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            ITrustWorkReputation.UnsupportedRuling.selector, address(order), ruling, reason
                        )
                    );
                    guarded.register(address(order));
                }
            }
        }
        assertEq(supported, 4);
    }

    function _mockOrder() private returns (MockReputationOrder order) {
        order = new MockReputationOrder(IArbitrationCourt(address(mockCourt)));
        mockFactory.recognize(address(order));
    }

    function _dispute(address order, uint256 milestoneIndex) private pure returns (IArbitrationCourt.Dispute memory d) {
        d.order = order;
        d.milestoneIndex = milestoneIndex;
        d.status = IArbitrationCourt.DisputeStatus.Resolved;
        d.ruling = IArbitrationCourt.Ruling.FreelancerWins;
        d.reason = IArbitrationCourt.RulingReason.Majority;
        d.panelDeadline = 100;
        d.revealDeadline = 200;
    }
}
