// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title PanelSelection
/// @notice Deterministic choice of three distinct candidate indexes from a seed (partial Fisher–Yates).
/// @dev Uniform only to the extent that the seed is; it provides no randomness of its own.
library PanelSelection {
    uint256 internal constant PANEL_SIZE = 3;

    error TooFewCandidates(uint256 candidateCount);

    function selectIndexes(bytes32 seed, uint256 candidateCount)
        internal
        pure
        returns (uint256[PANEL_SIZE] memory selected)
    {
        if (candidateCount < PANEL_SIZE) revert TooFewCandidates(candidateCount);
        uint256[] memory order = new uint256[](candidateCount);
        for (uint256 i; i < candidateCount; ++i) {
            order[i] = i;
        }
        for (uint256 j; j < PANEL_SIZE; ++j) {
            uint256 pick = j + uint256(keccak256(abi.encode(seed, j))) % (candidateCount - j);
            (order[j], order[pick]) = (order[pick], order[j]);
            selected[j] = order[j];
        }
    }
}
