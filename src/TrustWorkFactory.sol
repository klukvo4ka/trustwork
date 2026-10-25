// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitrationCourt} from "./ArbitrationCourt.sol";
import {IArbitrationCourt} from "./interfaces/IArbitrationCourt.sol";
import {IOrderFactory} from "./interfaces/IOrderFactory.sol";
import {WorkOrder} from "./WorkOrder.sol";

/// @title TrustWorkFactory
/// @notice Deploys independent WorkOrder escrows bound to the arbitration court this factory deploys. The caller
/// becomes the order's client.
/// @dev Order input validation is enforced by the WorkOrder constructor and court parameter validation by the court
/// and registry constructors, so their custom errors bubble up from here.
contract TrustWorkFactory is IOrderFactory {
    IArbitrationCourt public immutable court;
    address private immutable _penaltyRecipient;

    /// @notice Orders created by this factory; the court accepts disputes only from these.
    mapping(address order => bool) public isWorkOrder;

    event WorkOrderCreated(
        address indexed order,
        address indexed client,
        address indexed freelancer,
        address token,
        uint256 totalAmount,
        uint256 deliveryPeriod
    );

    error PenaltyRecipientIsParty(address penaltyRecipient);

    constructor(IERC20 stakeToken, uint256 disputeFee, uint256 seatLock, address penaltyRecipient) {
        court = new ArbitrationCourt(stakeToken, disputeFee, seatLock, penaltyRecipient);
        _penaltyRecipient = penaltyRecipient;
    }

    function createWorkOrder(
        address freelancer,
        IERC20 token,
        address feeRecipient,
        uint256 feeBps,
        uint256 reviewPeriod,
        uint256 deliveryPeriod,
        uint256[] calldata milestoneAmounts
    ) external returns (WorkOrder order) {
        if (msg.sender == _penaltyRecipient || freelancer == _penaltyRecipient || feeRecipient == _penaltyRecipient) {
            revert PenaltyRecipientIsParty(_penaltyRecipient);
        }
        order = new WorkOrder(
            msg.sender, freelancer, token, feeRecipient, feeBps, reviewPeriod, deliveryPeriod, court, milestoneAmounts
        );
        isWorkOrder[address(order)] = true;
        emit WorkOrderCreated(
            address(order), msg.sender, freelancer, address(token), order.totalAmount(), deliveryPeriod
        );
    }
}
