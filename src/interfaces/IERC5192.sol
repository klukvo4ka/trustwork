// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IERC5192
/// @notice Minimal soulbound extension of ERC-721 (ERC-5192). Interface ID `0xb45a3c0e`.
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}
