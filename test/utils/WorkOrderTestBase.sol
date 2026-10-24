// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";

abstract contract WorkOrderTestBase is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant DEFAULT_FEE_BPS = 250;
    uint256 internal constant DEFAULT_REVIEW_PERIOD = 7 days;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant APPROVE_MILESTONE_TYPEHASH =
        keccak256("ApproveMilestone(uint256 milestoneIndex,uint256 nonce,uint256 deadline)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address internal client;
    uint256 internal clientKey;
    address internal freelancer = makeAddr("freelancer");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal stranger = makeAddr("stranger");

    TrustWorkFactory internal factory;
    MockUSDC internal usdc;

    function setUp() public virtual {
        (client, clientKey) = makeAddrAndKey("client");
        factory = new TrustWorkFactory();
        usdc = new MockUSDC();
    }

    function _defaultAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = 1000 * USDC;
        amounts[1] = 2500 * USDC;
        amounts[2] = 500 * USDC;
    }

    function _createOrder(IERC20 token, uint256 feeBps, uint256[] memory amounts) internal returns (WorkOrder order) {
        vm.prank(client);
        order = factory.createWorkOrder(freelancer, token, feeRecipient, feeBps, DEFAULT_REVIEW_PERIOD, amounts);
    }

    function _createDefaultOrder() internal returns (WorkOrder) {
        return _createOrder(usdc, DEFAULT_FEE_BPS, _defaultAmounts());
    }

    function _mintAndApprove(MockUSDC token, WorkOrder order, uint256 amount) internal {
        token.mint(client, amount);
        vm.prank(client);
        token.approve(address(order), amount);
    }

    function _fund(WorkOrder order) internal {
        _mintAndApprove(usdc, order, order.totalAmount());
        vm.prank(client);
        order.fund();
    }

    function _submit(WorkOrder order, uint256 index) internal {
        vm.prank(freelancer);
        order.submitMilestone(index);
    }

    function _approve(WorkOrder order, uint256 index) internal {
        vm.prank(client);
        order.approveMilestone(index);
    }

    function _expectedApprovalDigest(address order, uint256 index, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes("TrustWork")), keccak256(bytes("1")), block.chainid, order
            )
        );
        bytes32 structHash = keccak256(abi.encode(APPROVE_MILESTONE_TYPEHASH, index, nonce, deadline));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _signApproval(uint256 signerKey, WorkOrder order, uint256 index, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, _expectedApprovalDigest(address(order), index, nonce, deadline));
        return abi.encodePacked(r, s, v);
    }

    function _signPermit(
        uint256 ownerKey,
        MockPermitUSDC token,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, vm.addr(ownerKey), spender, value, nonce, deadline));
        (v, r, s) = vm.sign(ownerKey, keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), structHash)));
    }
}
