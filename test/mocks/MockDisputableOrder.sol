// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";

/// @dev Exposes the parties the court reads and forwards `openDispute` from any caller.
contract MockDisputableOrder {
    IArbitrationCourt public immutable court;
    address public immutable client;
    address public immutable freelancer;
    address public immutable feeRecipient;

    constructor(IArbitrationCourt court_, address client_, address freelancer_, address feeRecipient_) {
        court = court_;
        client = client_;
        freelancer = freelancer_;
        feeRecipient = feeRecipient_;
    }

    function openDispute(uint256 milestoneIndex) external returns (uint256) {
        return court.openDispute(milestoneIndex);
    }
}
