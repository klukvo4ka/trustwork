// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IntegrationTestBase} from "../utils/IntegrationTestBase.sol";

/// @dev `WorkOrder.openDispute` through the production factory, order and court with 32 candidates that hold only
/// matured warming stake. Storage of the order, court, registry, factory and both tokens is marked cold with
/// `vm.cool` before the measured call; the figure is `vm.lastCallGas().gasTotalUsed` of the client's call and excludes
/// the 21,000 intrinsic cost and calldata.
abstract contract TrustWorkIntegrationGasTest is IntegrationTestBase {
    uint256 internal constant OPEN_TARGET = 2_000_000;

    WorkOrder internal order;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 32; ++i) {
            _stake(_arbitrator(i), 3 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        order = _createDefaultOrder();
        _fund(order);
        _submit(order, 0);
        _approveCourtFee(client);
    }

    function test_Gas_OrderOpenDisputeAllWarming() public {
        vm.cool(address(order));
        vm.cool(address(court));
        vm.cool(address(registry));
        vm.cool(address(factory));
        vm.cool(address(paymentToken));
        vm.cool(address(stakeToken));
        vm.prank(client);
        order.openDispute(0);
        uint256 gas = vm.lastCallGas().gasTotalUsed;

        assertEq(registry.candidatesOf(order.disputeId()).length, 32);
        for (uint256 i; i < 32; ++i) {
            assertEq(registry.accountOf(_arbitrator(i)).warming, 0);
        }
        console.log("WorkOrder.openDispute, 32 matured-warming candidates:", gas);
        assertLe(gas, OPEN_TARGET);
    }
}

contract TrustWorkIntegrationSharedTokenGasTest is TrustWorkIntegrationGasTest {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }
}

contract TrustWorkIntegrationSplitTokenGasTest is TrustWorkIntegrationGasTest {
    function _sharedToken() internal pure override returns (bool) {
        return false;
    }
}
