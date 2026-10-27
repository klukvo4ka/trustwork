// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";

/// @dev Court stand-in whose dispute records are set by the test, to reach the reputation consistency guards.
contract MockReputationCourt {
    mapping(uint256 disputeId => IArbitrationCourt.Dispute) private _disputes;

    function setDispute(uint256 disputeId, IArbitrationCourt.Dispute calldata dispute) external {
        _disputes[disputeId] = dispute;
    }

    function getDispute(uint256 disputeId) external view returns (IArbitrationCourt.Dispute memory) {
        return _disputes[disputeId];
    }
}

/// @dev Factory stand-in that recognizes whatever the test registers and reports a configurable court.
contract MockReputationFactory {
    IArbitrationCourt public court;
    mapping(address order => bool) public isWorkOrder;

    constructor(IArbitrationCourt court_) {
        court = court_;
    }

    function recognize(address order) external {
        isWorkOrder[order] = true;
    }
}

/// @dev Order stand-in exposing the views the reputation contract reads, with values set by the test. It describes
/// a terminated two-milestone order disputed at milestone 1 unless changed.
contract MockReputationOrder {
    IArbitrationCourt public court;
    WorkOrder.OrderStatus public status = WorkOrder.OrderStatus.Terminated;
    address public client = address(0xC11E);
    address public freelancer = address(0xF4EE);
    IERC20 public token = IERC20(address(0x70CE));
    uint256 public totalAmount = 300;
    uint256 public directPaid = 100;
    uint256 public disputeId = 1;
    uint256 public currentMilestone = 1;
    uint256 public deliveryPeriod = 1 days;
    WorkOrder.Milestone[] private _milestones;

    constructor(IArbitrationCourt court_) {
        court = court_;
        _milestones.push(WorkOrder.Milestone(100, WorkOrder.MilestoneStatus.Settled, 10, 20, 1 days + 5));
        _milestones.push(WorkOrder.Milestone(200, WorkOrder.MilestoneStatus.Disputed, 30, 40, 1 days + 25));
    }

    function setCourt(IArbitrationCourt court_) external {
        court = court_;
    }

    function milestoneCount() external view returns (uint256) {
        return _milestones.length;
    }

    function getMilestone(uint256 index) external view returns (WorkOrder.Milestone memory) {
        return _milestones[index];
    }
}
