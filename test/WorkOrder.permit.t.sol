// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WorkOrder} from "../src/WorkOrder.sol";
import {WorkOrderTestBase} from "./utils/WorkOrderTestBase.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {MockPermitUSDC} from "./mocks/MockPermitUSDC.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract WorkOrderPermitTest is WorkOrderTestBase {
    event Funded(address indexed client, uint256 amount);

    MockPermitUSDC internal permitToken;
    WorkOrder internal order;
    uint256 internal total;
    uint256 internal permitDeadline;

    function setUp() public override {
        super.setUp();
        permitToken = new MockPermitUSDC();
        order = _createOrder(permitToken, DEFAULT_FEE_BPS, _defaultAmounts());
        total = order.totalAmount();
        permitDeadline = block.timestamp + 1 hours;
        permitToken.mint(client, total);
    }

    function test_MockPermitUSDC_UsesSixDecimals() public view {
        assertEq(permitToken.decimals(), 6);
    }

    function test_FundWithPermit_FundsExactTotal() public {
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);

        vm.expectEmit(address(order));
        emit Funded(client, total);
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Active));
        assertEq(permitToken.balanceOf(address(order)), total);
        assertEq(permitToken.balanceOf(client), 0);
        assertEq(order.outstandingObligations(), total);
    }

    function test_FundWithPermit_ConsumesPermitNonceAndAllowance() public {
        assertEq(permitToken.nonces(client), 0);
        assertEq(permitToken.allowance(client, address(order)), 0);
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);

        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(permitToken.nonces(client), 1);
        assertEq(permitToken.allowance(client, address(order)), 0);
    }

    function test_FundWithPermit_FullStateFlowAfterFunding() public {
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        _submit(order, 0);
        _approve(order, 0);

        assertEq(permitToken.balanceOf(freelancer), 975 * USDC);
        assertEq(order.outstandingObligations(), 3000 * USDC);
    }

    function test_RevertWhen_PermitSignedForDifferentValueAndNoAllowance() public {
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total + 1, 0, permitDeadline);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(order), 0, total)
        );
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(permitToken.nonces(client), 0);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Unfunded));
    }

    function test_RevertWhen_FundWithPermitCalledByNonClient() public {
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.NotClient.selector, stranger));
        vm.prank(stranger);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(permitToken.nonces(client), 0);
        assertEq(permitToken.allowance(client, address(order)), 0);
    }

    function test_RevertWhen_FundWithPermitAfterFunding() public {
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);
        permitToken.mint(client, total);
        (v, r, s) = _clientPermit(total, 1, permitDeadline);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Active));
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(permitToken.nonces(client), 1);
        assertEq(permitToken.balanceOf(address(order)), total);
    }

    function test_RevertWhen_FundAfterFundWithPermit() public {
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, WorkOrder.OrderStatus.Active));
        vm.prank(client);
        order.fund();
    }

    function test_FundWithPermit_SucceedsWhenPermitAlreadySubmittedToToken() public {
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);
        vm.prank(stranger);
        permitToken.permit(client, address(order), total, permitDeadline, v, r, s);
        assertEq(permitToken.allowance(client, address(order)), total);

        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(permitToken.balanceOf(address(order)), total);
        assertEq(permitToken.nonces(client), 1);
        assertEq(permitToken.allowance(client, address(order)), 0);
    }

    function test_RevertWhen_PermitExpiredAndNoAllowance() public {
        uint256 expired = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, expired);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(order), 0, total)
        );
        vm.prank(client);
        order.fundWithPermit(expired, v, r, s);

        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Unfunded));
        assertEq(permitToken.balanceOf(client), total);
    }

    function test_RevertWhen_PermitSignedByWrongKeyAndNoAllowance() public {
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(strangerKey, permitToken, address(order), total, 0, permitDeadline);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(order), 0, total)
        );
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(permitToken.nonces(client), 0);
    }

    function test_RevertWhen_PermitAllowanceInsufficient() public {
        vm.prank(client);
        permitToken.approve(address(order), total - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(order), total - 1, total)
        );
        vm.prank(client);
        order.fundWithPermit(permitDeadline, 27, bytes32(0), bytes32(0));
    }

    function test_FundWithPermit_FailedPermitFallsBackToExistingAllowance() public {
        vm.prank(client);
        permitToken.approve(address(order), total);
        uint256 expired = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, expired);

        vm.prank(client);
        order.fundWithPermit(expired, v, r, s);

        assertEq(permitToken.balanceOf(address(order)), total);
        assertEq(permitToken.nonces(client), 0);
        assertEq(order.outstandingObligations(), total);
    }

    function test_RevertWhen_PermitValidButBalanceInsufficient() public {
        vm.prank(client);
        assertTrue(permitToken.transfer(stranger, 1));
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, client, total - 1, total)
        );
        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(permitToken.nonces(client), 0);
        assertEq(permitToken.allowance(client, address(order)), 0);
        assertEq(uint256(order.status()), uint256(WorkOrder.OrderStatus.Unfunded));
    }

    function test_FundWithPermit_ToleratesPriorDonation() public {
        permitToken.mint(address(order), 55 * USDC);
        (uint8 v, bytes32 r, bytes32 s) = _clientPermit(total, 0, permitDeadline);

        vm.prank(client);
        order.fundWithPermit(permitDeadline, v, r, s);

        assertEq(order.outstandingObligations(), total);
        assertEq(permitToken.balanceOf(address(order)), total + 55 * USDC);
    }

    function test_Fund_StillWorksWithPermitToken() public {
        vm.startPrank(client);
        permitToken.approve(address(order), total);
        order.fund();
        vm.stopPrank();

        assertEq(permitToken.balanceOf(address(order)), total);
        assertEq(permitToken.nonces(client), 0);
    }

    function test_FundWithPermit_TokenWithoutPermitUsesAllowance() public {
        WorkOrder plainOrder = _createDefaultOrder();
        _mintAndApprove(usdc, plainOrder, plainOrder.totalAmount());

        vm.prank(client);
        plainOrder.fundWithPermit(permitDeadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));

        assertEq(usdc.balanceOf(address(plainOrder)), plainOrder.totalAmount());
        assertEq(uint256(plainOrder.status()), uint256(WorkOrder.OrderStatus.Active));
    }

    function test_RevertWhen_TokenWithoutPermitAndNoAllowance() public {
        WorkOrder plainOrder = _createDefaultOrder();
        uint256 plainTotal = plainOrder.totalAmount();
        usdc.mint(client, plainTotal);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(plainOrder), 0, plainTotal)
        );
        vm.prank(client);
        plainOrder.fundWithPermit(permitDeadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_Fund_TokenWithoutPermitSupport() public {
        WorkOrder plainOrder = _createDefaultOrder();
        _fund(plainOrder);

        assertEq(usdc.balanceOf(address(plainOrder)), plainOrder.totalAmount());
        assertEq(plainOrder.outstandingObligations(), plainOrder.totalAmount());
    }

    function test_RevertWhen_FundWithPermitReceivesInexactAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        WorkOrder feeOrder = _createOrder(feeToken, DEFAULT_FEE_BPS, _defaultAmounts());
        uint256 feeTotal = feeOrder.totalAmount();
        uint256 received = feeTotal - feeTotal * feeToken.TRANSFER_FEE_BPS() / 10_000;
        feeToken.mint(client, feeTotal);
        vm.prank(client);
        feeToken.approve(address(feeOrder), feeTotal);

        vm.expectRevert(abi.encodeWithSelector(WorkOrder.DepositMismatch.selector, feeTotal, received));
        vm.prank(client);
        feeOrder.fundWithPermit(permitDeadline, 27, bytes32(0), bytes32(0));

        assertEq(uint256(feeOrder.status()), uint256(WorkOrder.OrderStatus.Unfunded));
        assertEq(feeOrder.outstandingObligations(), 0);
        assertEq(feeToken.balanceOf(client), feeTotal);
    }

    function test_Reentrancy_DuringFundWithPermitIsBlocked() public {
        ReentrantToken token = new ReentrantToken();
        WorkOrder reentrantOrder = _createOrder(token, DEFAULT_FEE_BPS, _defaultAmounts());
        uint256 reentrantTotal = reentrantOrder.totalAmount();
        token.mint(client, 2 * reentrantTotal);
        vm.prank(client);
        token.approve(address(reentrantOrder), 2 * reentrantTotal);
        token.arm(
            address(reentrantOrder),
            abi.encodeCall(WorkOrder.fundWithPermit, (permitDeadline, 27, bytes32(0), bytes32(0)))
        );

        vm.prank(client);
        reentrantOrder.fundWithPermit(permitDeadline, 27, bytes32(0), bytes32(0));

        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertEq(
            token.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(token.balanceOf(address(reentrantOrder)), reentrantTotal);
        assertEq(reentrantOrder.outstandingObligations(), reentrantTotal);
    }

    function _clientPermit(uint256 value, uint256 nonce, uint256 deadline)
        private
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return _signPermit(clientKey, permitToken, address(order), value, nonce, deadline);
    }
}
