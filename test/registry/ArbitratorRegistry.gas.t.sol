// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {RegistryTestBase} from "../utils/RegistryTestBase.sol";

/// @dev Gas of court calls with 32 candidates. Storage of the registry and the court harness is marked cold with
/// `vm.cool` before each measured call, so setup writes do not warm the measured slots. Reported numbers are the
/// external call from the test into the harness (including the harness forwarding call), excluding the 21,000
/// intrinsic transaction cost and calldata. Address warmth is not reset by `vm.cool`.
abstract contract RegistryGasBase is RegistryTestBase {
    uint256 internal constant SNAPSHOT_TARGET = 2_000_000;
    uint256 internal constant SELECT_TARGET = 800_000;
    uint256 internal constant RELEASE_RESERVATIONS_TARGET = 800_000;

    function _measureAll(string memory fixture) internal {
        uint256 snapshotGas = _coldCall(abi.encodeCall(court.reserveCandidates, (1, _parties())));
        assertEq(registry.candidatesOf(1).length, 32);
        for (uint256 i; i < 32; ++i) {
            assertEq(_account(_arbitrator(i)).warming, 0);
        }

        uint256 selectGas = _coldCall(abi.encodeCall(court.selectPanel, (1, keccak256("seed"))));
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.Selected));

        _reserve(2);
        uint256 releaseGas = _coldCall(abi.encodeCall(court.releaseReservations, (2)));
        assertEq(uint256(registry.snapshotState(2)), uint256(IArbitratorRegistry.SnapshotState.Released));

        console.log(fixture);
        console.log("  reserveCandidates, 32 candidates:", snapshotGas);
        console.log("  selectPanel, 32 candidates:", selectGas);
        console.log("  releaseReservations, 32 candidates:", releaseGas);
        assertLe(snapshotGas, SNAPSHOT_TARGET);
        assertLe(selectGas, SELECT_TARGET);
        assertLe(releaseGas, RELEASE_RESERVATIONS_TARGET);
    }

    function _coldCall(bytes memory data) private returns (uint256) {
        vm.cool(address(registry));
        vm.cool(address(court));
        (bool success,) = address(court).call(data);
        assertTrue(success);
        return vm.lastCallGas().gasTotalUsed;
    }
}

/// @dev Half of the accounts hold matured warming stake the snapshot must materialize; half were already materialized
/// by an earlier withdrawal.
contract ArbitratorRegistryGasTest is RegistryGasBase {
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), 2 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        for (uint256 i; i < 16; ++i) {
            _withdraw(_arbitrator(i), 1);
        }
        for (uint256 i; i < 32; ++i) {
            assertEq(_account(_arbitrator(i)).warming, i < 16 ? 0 : 2 * SEAT_LOCK);
        }
    }

    function test_Gas_SnapshotSelectAndRelease() public {
        _measureAll("mixed fixture (16 matured warming, 16 materialized)");
    }
}

/// @dev Every candidate holds only matured warming stake, so the snapshot materializes all 32 accounts.
contract ArbitratorRegistryAllWarmingGasTest is RegistryGasBase {
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), 2 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        for (uint256 i; i < 32; ++i) {
            IArbitratorRegistry.Account memory account = _account(_arbitrator(i));
            assertEq(account.stake, 0);
            assertEq(account.warming, 2 * SEAT_LOCK);
        }
    }

    function test_Gas_SnapshotSelectAndRelease() public {
        _measureAll("all-warming fixture (32 matured warming)");
    }
}
