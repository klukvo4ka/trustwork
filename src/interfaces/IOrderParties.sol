// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Parties the arbitration court reads from a disputing order.
interface IOrderParties {
    function client() external view returns (address);
    function freelancer() external view returns (address);
    function feeRecipient() external view returns (address);
}
