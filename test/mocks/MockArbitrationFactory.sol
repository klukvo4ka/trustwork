// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {IOrderFactory} from "../../src/interfaces/IOrderFactory.sol";
import {MockDisputableOrder} from "./MockDisputableOrder.sol";

/// @dev Deploys the court (becoming its factory) and recognizes the orders it creates.
contract MockArbitrationFactory is IOrderFactory {
    ArbitrationCourt public immutable court;
    mapping(address order => bool) public isWorkOrder;

    constructor(IERC20 stakeToken, uint256 disputeFee, uint256 seatLock, address penaltyRecipient) {
        court = new ArbitrationCourt(stakeToken, disputeFee, seatLock, penaltyRecipient);
    }

    function createOrder(address client, address freelancer, address feeRecipient)
        external
        returns (MockDisputableOrder order)
    {
        order = new MockDisputableOrder(court, client, freelancer, feeRecipient);
        isWorkOrder[address(order)] = true;
    }
}
