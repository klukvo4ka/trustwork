// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";

/// @dev Stands in for the arbitration court: deploys the registry, forwards court-only calls and receives penalties.
contract RegistryCourtHarness {
    ArbitratorRegistry public immutable registry;

    constructor(IERC20 stakeToken, uint256 seatLock, address penaltyRecipient) {
        registry = new ArbitratorRegistry(stakeToken, seatLock, penaltyRecipient);
    }

    function reserveCandidates(uint256 disputeId, address[3] calldata excluded) external returns (uint256) {
        return registry.reserveCandidates(disputeId, excluded);
    }

    function selectPanel(uint256 disputeId, bytes32 seed)
        external
        returns (uint256[3] memory candidateIndexes, address[3] memory panel)
    {
        return registry.selectPanel(disputeId, seed);
    }

    function releaseReservations(uint256 disputeId) external {
        registry.releaseReservations(disputeId);
    }

    function releaseSeat(uint256 disputeId, uint256 candidateIndex, uint256 penalty) external {
        registry.releaseSeat(disputeId, candidateIndex, penalty);
    }
}
