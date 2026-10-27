// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {TrustWorkReputation} from "../../src/TrustWorkReputation.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";

/// @dev Wallet whose owner executes calls through it and whose `onERC721Received` would revert or re-enter the
/// reputation contract. `receiverCalls` counts how often the callback ran.
contract MockReceiverWallet is IERC721Receiver {
    enum Mode {
        Revert,
        Reenter
    }

    address public immutable owner;
    Mode public immutable mode;
    uint256 public receiverCalls;

    error NotOwner(address caller);
    error CallFailed(bytes returnData);
    error ReceiverRejected();

    constructor(address owner_, Mode mode_) {
        owner = owner_;
        mode = mode_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) revert CallFailed(returnData);
        return returnData;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        ++receiverCalls;
        if (mode == Mode.Revert) revert ReceiverRejected();
        (address order, ITrustWorkReputation.Role role) = TrustWorkReputation(msg.sender).receiptOf(tokenId);
        TrustWorkReputation(msg.sender).claimReceipt(order, role);
        TrustWorkReputation(msg.sender).register(order);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Contract client with fixed escrow methods only: it can create, fund, approve and reclaim orders, but has no
/// method that calls the reputation contract and no arbitrary-call method.
contract MockEscrowOnlyClient {
    address public immutable operator;

    error NotOperator(address caller);

    constructor(address operator_) {
        operator = operator_;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        _;
    }

    function createOrder(
        TrustWorkFactory factory,
        address freelancer,
        IERC20 token,
        address feeRecipient,
        uint256 feeBps,
        uint256 reviewPeriod,
        uint256 deliveryPeriod,
        uint256[] calldata amounts
    ) external onlyOperator returns (WorkOrder) {
        return factory.createWorkOrder(freelancer, token, feeRecipient, feeBps, reviewPeriod, deliveryPeriod, amounts);
    }

    function fund(WorkOrder order) external onlyOperator {
        order.token().approve(address(order), order.totalAmount());
        order.fund();
    }

    function approveMilestone(WorkOrder order, uint256 index) external onlyOperator {
        order.approveMilestone(index);
    }

    function reclaim(WorkOrder order) external onlyOperator {
        order.reclaimAfterDeliveryExpiry();
    }
}
