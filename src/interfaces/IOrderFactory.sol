// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What the arbitration court needs from the factory that deployed it.
interface IOrderFactory {
    function isWorkOrder(address order) external view returns (bool);
}
