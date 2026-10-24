// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RegistryTestBase} from "../utils/RegistryTestBase.sol";

/// @dev Matrix M0: the Sybil example of design section 7.6, observed through the registry's own selection.
contract ArbitratorRegistryMatrixTest is RegistryTestBase {
    function test_MatrixM0_SplitStakeGainsSeats() public {
        _activeArbitrators(5, SEAT_LOCK);
        bool[32] memory seen;
        uint256 distinctTriples;
        uint256[4] memory triplesByOwnerSeats;
        uint256 disputeId;

        for (uint256 k; k < 500 && distinctTriples < 10; ++k) {
            bytes32 seed = keccak256(abi.encode("matrix", k));
            ++disputeId;
            _reserve(disputeId);
            (uint256[3] memory chosen,) = court.selectPanel(disputeId, seed);
            uint256[3] memory expected = _referenceSelection(seed, 5);
            uint256 mask;
            for (uint256 j; j < 3; ++j) {
                assertEq(chosen[j], expected[j]);
                mask += 2 ** chosen[j];
                court.releaseSeat(disputeId, chosen[j], 0);
            }
            if (seen[mask]) continue;
            seen[mask] = true;
            ++distinctTriples;
            uint256 ownerSeats = _popCount(mask & 0x7);
            ++triplesByOwnerSeats[ownerSeats];
        }

        assertEq(distinctTriples, 10);
        assertEq(triplesByOwnerSeats[0], 0);
        assertEq(triplesByOwnerSeats[1], 3);
        assertEq(triplesByOwnerSeats[2], 6);
        assertEq(triplesByOwnerSeats[3], 1);
        uint256 totalOwnerSeats = 1 * triplesByOwnerSeats[1] + 2 * triplesByOwnerSeats[2] + 3 * triplesByOwnerSeats[3];
        assertEq(totalOwnerSeats * 10 / distinctTriples, 18);
        assertEq(triplesByOwnerSeats[2] + triplesByOwnerSeats[3], 7);
        assertEq(registry.totalStaked(), 5 * SEAT_LOCK);
    }

    function test_MatrixM0_UnsplitStakeHoldsOneSeat() public {
        address owner = _arbitrator(0);
        _deposit(owner, 3 * SEAT_LOCK);
        _deposit(_arbitrator(1), SEAT_LOCK);
        _deposit(_arbitrator(2), SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        for (uint256 k; k < 10; ++k) {
            uint256 disputeId = k + 1;
            assertEq(_reserve(disputeId), 3);
            (, address[3] memory panel) = court.selectPanel(disputeId, keccak256(abi.encode("unsplit", k)));
            uint256 ownerSeats;
            for (uint256 j; j < 3; ++j) {
                if (panel[j] == owner) ++ownerSeats;
            }
            assertEq(ownerSeats, 1);
            for (uint256 j; j < 3; ++j) {
                court.releaseSeat(disputeId, j, 0);
            }
        }
    }

    function _popCount(uint256 value) private pure returns (uint256 count) {
        for (; value != 0; value >>= 1) {
            count += value & 1;
        }
    }
}
