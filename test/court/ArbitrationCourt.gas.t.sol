// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";
import {MockDisputableOrder} from "../mocks/MockDisputableOrder.sol";

/// @dev Gas of court entry points with 32 candidates. Before each measured call the storage of the court, registry,
/// stake token, mock factory and mock order is marked cold with `vm.cool`; address warmth is not reset. Each number is
/// `vm.lastCallGas().gasTotalUsed` of one external call from the test: `MockDisputableOrder.openDispute` (which forwards
/// to the court) for opening, and the court itself for the other entry points. The 21,000 intrinsic cost and calldata
/// are excluded.
abstract contract CourtGasBase is CourtTestBase {
    uint256 internal constant OPEN_TARGET = 2_000_000;
    uint256 internal constant DRAW_TARGET = 800_000;
    uint256 internal constant NO_PANEL_TARGET = 800_000;
    uint256 internal constant PANEL_RESOLVE_TARGET = 400_000;

    function _cool() internal {
        vm.cool(address(court));
        vm.cool(address(registry));
        vm.cool(address(token));
        vm.cool(address(factory));
        vm.cool(address(order));
    }

    function _measuredOpen(MockDisputableOrder target, address payer)
        internal
        returns (uint256 disputeId, uint256 gas)
    {
        token.mint(payer, DISPUTE_FEE);
        vm.prank(payer);
        token.approve(address(court), DISPUTE_FEE);
        _cool();
        disputeId = target.openDispute(0);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    function _measuredCourtCall(bytes memory data) internal returns (uint256) {
        _cool();
        (bool success,) = address(court).call(data);
        assertTrue(success);
        return vm.lastCallGas().gasTotalUsed;
    }

    function _measureOpenDrawAndResolve(string memory fixture) internal {
        (uint256 disputeId, uint256 openGas) = _measuredOpen(order, client);
        assertEq(registry.candidatesOf(disputeId).length, 32);
        for (uint256 i; i < 32; ++i) {
            assertEq(registry.accountOf(_arbitrator(i)).warming, 0);
        }

        _setSeedBlock(disputeId, keccak256("gas seed"));
        uint256 drawGas = _measuredCourtCall(abi.encodeCall(court.drawPanel, (disputeId)));
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.Voting));

        _toResolution(disputeId);
        uint256 faultyResolveGas = _measuredCourtCall(abi.encodeCall(court.resolve, (disputeId)));
        assertEq(court.penaltiesReceived(), 3 * SEAT_LOCK);

        MockDisputableOrder second = factory.createOrder(makeAddr("secondClient"), freelancer, feeRecipient);
        (uint256 revealedId,) = _measuredOpen(second, makeAddr("secondClient"));
        address[3] memory panel = _draw(revealedId);
        for (uint256 j; j < 3; ++j) {
            _commit(revealedId, panel[j], FREELANCER_VOTE);
        }
        _toRevealPhase(revealedId);
        for (uint256 j; j < 3; ++j) {
            _reveal(revealedId, panel[j], FREELANCER_VOTE);
        }
        _toResolution(revealedId);
        uint256 revealedResolveGas = _measuredCourtCall(abi.encodeCall(court.resolve, (revealedId)));

        MockDisputableOrder third = factory.createOrder(makeAddr("thirdClient"), freelancer, feeRecipient);
        (uint256 undrawnId,) = _measuredOpen(third, makeAddr("thirdClient"));
        assertEq(registry.candidatesOf(undrawnId).length, 32);
        vm.warp(court.getDispute(undrawnId).panelDeadline);
        uint256 noPanelGas = _measuredCourtCall(abi.encodeCall(court.resolve, (undrawnId)));

        console.log(fixture);
        console.log("  openDispute, 32 candidates:", openGas);
        console.log("  drawPanel, 32 candidates:", drawGas);
        console.log("  resolve, panel with 3 faulty seats:", faultyResolveGas);
        console.log("  resolve, panel with 3 valid reveals:", revealedResolveGas);
        console.log("  resolve NoPanel from AwaitingSeed, 32 candidates:", noPanelGas);
        assertLe(openGas, OPEN_TARGET);
        assertLe(drawGas, DRAW_TARGET);
        assertLe(faultyResolveGas, PANEL_RESOLVE_TARGET);
        assertLe(revealedResolveGas, PANEL_RESOLVE_TARGET);
        assertLe(noPanelGas, NO_PANEL_TARGET);
    }
}

/// @dev 16 accounts already materialized (by a withdrawal) and 16 holding only matured warming stake.
contract ArbitrationCourtMixedGasTest is CourtGasBase {
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), 3 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        for (uint256 i; i < 16; ++i) {
            vm.prank(_arbitrator(i));
            registry.withdraw(1);
        }
    }

    function test_Gas_CourtEntryPoints() public {
        _measureOpenDrawAndResolve("mixed fixture (16 materialized, 16 matured warming)");
    }
}

/// @dev Every account holds only matured warming stake that the snapshot must materialize.
contract ArbitrationCourtAllWarmingGasTest is CourtGasBase {
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), 3 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
    }

    function test_Gas_CourtEntryPoints() public {
        _measureOpenDrawAndResolve("all-warming fixture (32 matured warming)");
    }
}

/// @dev Successful `retrySnapshot` over 32 candidates.
contract ArbitrationCourtRetryGasTest is CourtGasBase {
    function test_Gas_RetrySnapshotAllWarming() public {
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), SEAT_LOCK);
        }
        (uint256 disputeId,) = _measuredOpen(order, client);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates));
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        uint256 retryGas = _measuredCourtCall(abi.encodeCall(court.retrySnapshot, (disputeId)));

        assertEq(registry.candidatesOf(disputeId).length, 32);
        console.log("retrySnapshot, all-warming fixture (32 matured warming):", retryGas);
        assertLe(retryGas, OPEN_TARGET);
    }

    function test_Gas_RetrySnapshotMixed() public {
        for (uint256 i; i < 16; ++i) {
            _deposit(_arbitrator(i), SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        MockDisputableOrder blocker = factory.createOrder(makeAddr("blockerClient"), freelancer, feeRecipient);
        (uint256 blockingId,) = _measuredOpen(blocker, makeAddr("blockerClient"));
        assertEq(registry.candidatesOf(blockingId).length, 16);
        for (uint256 i = 16; i < 32; ++i) {
            _deposit(_arbitrator(i), SEAT_LOCK);
        }
        vm.warp(block.timestamp + 1);
        (uint256 disputeId,) = _measuredOpen(order, client);
        assertEq(uint256(_status(disputeId)), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates));

        vm.warp(court.getDispute(blockingId).panelDeadline);
        court.resolve(blockingId);
        for (uint256 i; i < 32; ++i) {
            assertEq(registry.accountOf(_arbitrator(i)).warming, i < 16 ? 0 : SEAT_LOCK);
        }

        uint256 retryGas = _measuredCourtCall(abi.encodeCall(court.retrySnapshot, (disputeId)));

        assertEq(registry.candidatesOf(disputeId).length, 32);
        console.log("retrySnapshot, mixed fixture (16 materialized, 16 matured warming):", retryGas);
        assertLe(retryGas, OPEN_TARGET);
    }
}

/// @dev All-warming snapshot when an earlier dispute already made the court's counters and token balance nonzero.
contract ArbitrationCourtSteadyStateGasTest is CourtGasBase {
    function test_Gas_OpenDisputeAllWarmingAfterEarlierDispute() public {
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), 3 * SEAT_LOCK);
        }
        MockDisputableOrder earlierOrder = factory.createOrder(makeAddr("earlierClient"), freelancer, feeRecipient);
        (uint256 earlier,) = _measuredOpen(earlierOrder, makeAddr("earlierClient"));
        assertEq(uint256(_status(earlier)), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates));
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        (uint256 disputeId, uint256 openGas) = _measuredOpen(order, client);

        assertEq(registry.candidatesOf(disputeId).length, 32);
        console.log("openDispute, all-warming fixture after an earlier dispute:", openGas);
        assertLe(openGas, OPEN_TARGET);
    }
}
