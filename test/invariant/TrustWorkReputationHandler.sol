// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {TrustWorkReputation} from "../../src/TrustWorkReputation.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";
import {TransferLedger} from "../utils/TransferLedger.sol";
import {TrustWorkIntegrationHandler} from "./TrustWorkIntegrationHandler.sol";

/// @dev Adds registration and receipts to the Stage 3E integration handler. Expected outcomes come from the parent's
/// ghosts (settlement counts, dispute IDs, panel votes) and expected receipt state from this handler's own ghosts, never
/// from the reputation contract.
contract TrustWorkReputationHandler is TrustWorkIntegrationHandler {
    TrustWorkReputation public immutable reputation;

    mapping(WorkOrder order => ITrustWorkReputation.Outcome) public ghostOutcome;
    mapping(WorkOrder order => uint64) public ghostRegisteredAt;
    mapping(WorkOrder order => bytes32) public ghostFactsHash;
    mapping(address account => mapping(ITrustWorkReputation.Role role => uint256[8])) internal _ghostStats;
    WorkOrder[] public registeredOrders;

    uint256[7] internal _registrationsByOutcome;
    uint256 public rejectedNotFinal;
    uint256 public rejectedNoParticipation;
    uint256 public rejectedDuplicate;
    uint256 public rejectedUnknown;

    mapping(WorkOrder order => mapping(ITrustWorkReputation.Role role => uint256)) public ghostMints;
    mapping(WorkOrder order => uint8) public ghostClaimBits;
    mapping(uint256 tokenId => address) public ghostOwner;
    mapping(address account => uint256) public ghostBalance;
    uint256[] public mintedIds;

    uint256[2] internal _claimsByRole;
    uint256 public burns;
    uint256 public rejectedDuplicateClaims;
    uint256 public rejectedClaimsAfterBurn;
    uint256 public rejectedUnregisteredClaims;
    uint256 public rejectedUnauthorized;
    uint256 public rejectedTransfers;
    uint256 public rejectedApprovals;

    constructor(
        TrustWorkFactory factory_,
        MockPermitUSDC paymentToken_,
        MockPermitUSDC stakeToken_,
        TransferLedger ledger_,
        address client_,
        uint256 clientKey_,
        address freelancer_,
        address feeRecipient_
    )
        TrustWorkIntegrationHandler(
            factory_, paymentToken_, stakeToken_, ledger_, client_, clientKey_, freelancer_, feeRecipient_
        )
    {
        reputation = new TrustWorkReputation(factory_);
    }

    function registerOrder(uint256 orderSeed) external {
        WorkOrder order = _order(orderSeed);
        if (address(order) == address(0)) return;
        _register(order);
    }

    function registerUnknown(uint256 seed) external {
        address[3] memory targets = [donor, address(court), address(registry)];
        address target = targets[seed % 3];
        vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.UnknownOrder.selector, target));
        reputation.register(target);
        ++rejectedUnknown;
    }

    /// @dev Attempts every order once, so campaigns end with every final order registered.
    function registerAll() external {
        for (uint256 i; i < orders.length; ++i) {
            _register(orders[i]);
        }
    }

    /// @dev Mostly registered orders, sometimes any order; the caller is the role holder or another known address.
    function claimReceipt(uint256 orderSeed, uint256 roleSeed, uint256 callerSeed) external {
        WorkOrder order = (orderSeed >> 128) % 4 != 0 && registeredOrders.length != 0
            ? registeredOrders[orderSeed % registeredOrders.length]
            : _order(orderSeed);
        if (address(order) == address(0)) return;
        ITrustWorkReputation.Role role = ITrustWorkReputation.Role(roleSeed % 2);
        _claim(order, role, callerSeed % 2 == 0 ? _holder(role) : _otherCaller(order, callerSeed >> 1));
    }

    function burnReceipt(uint256 idSeed, uint256 callerSeed) external {
        if (mintedIds.length == 0) return;
        uint256 tokenId = mintedIds[idSeed % mintedIds.length];
        address owner = ghostOwner[tokenId];
        address caller = callerSeed % 2 == 0 && owner != address(0) ? owner : _anyCaller(callerSeed >> 1);
        if (owner == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
            ++rejectedUnauthorized;
        } else if (caller != owner) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, caller, tokenId));
            ++rejectedUnauthorized;
        } else {
            ghostOwner[tokenId] = address(0);
            --ghostBalance[owner];
            ++burns;
        }
        vm.prank(caller);
        reputation.burn(tokenId);
    }

    /// @dev The owner of a live receipt tries one of the three transfer entry points or an approval.
    function moveReceipt(uint256 idSeed, uint256 modeSeed, uint256 recipientSeed) external {
        if (mintedIds.length == 0) return;
        uint256 tokenId = mintedIds[idSeed % mintedIds.length];
        address owner = ghostOwner[tokenId];
        if (owner == address(0)) return;
        address to = recipientSeed % 4 == 0 ? owner : _anyCaller(recipientSeed >> 2);
        uint256 mode = modeSeed % 5;
        if (mode < 3) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.ReceiptLocked.selector, tokenId));
            ++rejectedTransfers;
        } else {
            vm.expectRevert(ITrustWorkReputation.ApprovalsDisabled.selector);
            ++rejectedApprovals;
        }
        vm.prank(owner);
        if (mode == 0) reputation.transferFrom(owner, to, tokenId);
        else if (mode == 1) reputation.safeTransferFrom(owner, to, tokenId);
        else if (mode == 2) reputation.safeTransferFrom(owner, to, tokenId, "");
        else if (mode == 3) reputation.approve(to, tokenId);
        else reputation.setApprovalForAll(to, true);
    }

    /// @dev Both role holders claim every unclaimed receipt of every registered order.
    function claimAll() external {
        for (uint256 i; i < registeredOrders.length; ++i) {
            WorkOrder order = registeredOrders[i];
            for (uint256 r; r < 2; ++r) {
                ITrustWorkReputation.Role role = ITrustWorkReputation.Role(r);
                if (ghostMints[order][role] == 0) _claim(order, role, _holder(role));
            }
        }
    }

    function mintedCount() external view returns (uint256) {
        return mintedIds.length;
    }

    function claimsByRole(ITrustWorkReputation.Role role) external view returns (uint256) {
        return _claimsByRole[uint256(role)];
    }

    function registeredCount() external view returns (uint256) {
        return registeredOrders.length;
    }

    function registrationsByOutcome(ITrustWorkReputation.Outcome outcome) external view returns (uint256) {
        return _registrationsByOutcome[uint256(outcome)];
    }

    /// @dev `[registered, completed, deliveryExpired, freelancerWins, clientWins, splits, noPanel, milestonesSettled]`.
    function ghostStatsOf(address account, ITrustWorkReputation.Role role) external view returns (uint256[8] memory) {
        return _ghostStats[account][role];
    }

    function _register(WorkOrder order) internal {
        WorkOrder.OrderStatus status = order.status();
        bytes32 before = _escrowState(order);
        if (ghostOutcome[order] != ITrustWorkReputation.Outcome.None) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.AlreadyRegistered.selector, address(order)));
            reputation.register(address(order));
            ++rejectedDuplicate;
        } else if (status != WorkOrder.OrderStatus.Completed && status != WorkOrder.OrderStatus.Terminated) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.OrderNotFinal.selector, address(order), status));
            reputation.register(address(order));
            ++rejectedNotFinal;
        } else if (ghostDisputeId[order] == 0 && ghostSettled[order] == 0) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NoParticipation.selector, address(order)));
            reputation.register(address(order));
            ++rejectedNoParticipation;
        } else {
            ITrustWorkReputation.Outcome expected = _expectedOutcome(order, status);
            assertEq(uint256(reputation.register(address(order))), uint256(expected));
            _recordGhost(order, expected);
        }
        assertEq(_escrowState(order), before, "registration changed escrow, court or registry state");
    }

    function _claim(WorkOrder order, ITrustWorkReputation.Role role, address caller) internal {
        bytes32 before = _escrowState(order);
        uint8 bit = uint8(1) << uint8(role);
        uint256 tokenId = (uint256(uint160(address(order))) << 1) | uint256(role);
        if (ghostOutcome[order] == ITrustWorkReputation.Outcome.None) {
            vm.expectRevert(abi.encodeWithSelector(ITrustWorkReputation.NotRegistered.selector, address(order)));
            ++rejectedUnregisteredClaims;
        } else if (caller != _holder(role)) {
            vm.expectRevert(
                abi.encodeWithSelector(ITrustWorkReputation.NotRoleHolder.selector, address(order), role, caller)
            );
            ++rejectedUnauthorized;
        } else if (ghostClaimBits[order] & bit != 0) {
            vm.expectRevert(
                abi.encodeWithSelector(ITrustWorkReputation.ReceiptAlreadyClaimed.selector, address(order), role)
            );
            if (ghostOwner[tokenId] == address(0)) ++rejectedClaimsAfterBurn;
            else ++rejectedDuplicateClaims;
        } else {
            ghostClaimBits[order] |= bit;
            ++ghostMints[order][role];
            ghostOwner[tokenId] = caller;
            ++ghostBalance[caller];
            mintedIds.push(tokenId);
            ++_claimsByRole[uint256(role)];
            vm.prank(caller);
            assertEq(reputation.claimReceipt(address(order), role), tokenId);
            assertEq(_escrowState(order), before, "claim changed escrow, court or registry state");
            return;
        }
        vm.prank(caller);
        reputation.claimReceipt(address(order), role);
        assertEq(_escrowState(order), before, "rejected claim changed escrow, court or registry state");
    }

    function _holder(ITrustWorkReputation.Role role) internal view returns (address) {
        return role == ITrustWorkReputation.Role.Client ? client : freelancer;
    }

    /// @dev May coincide with the role holder when the order's fee recipient is the client.
    function _otherCaller(WorkOrder order, uint256 seed) internal view returns (address) {
        if (seed % 6 == 5) return order.feeRecipient();
        return _anyCaller(seed);
    }

    function _anyCaller(uint256 seed) internal view returns (address) {
        address[5] memory callers = [client, freelancer, feeRecipient, actors[0], donor];
        return callers[seed % 5];
    }

    function _expectedOutcome(WorkOrder order, WorkOrder.OrderStatus status)
        internal
        view
        returns (ITrustWorkReputation.Outcome)
    {
        if (status == WorkOrder.OrderStatus.Completed) return ITrustWorkReputation.Outcome.Completed;
        uint256 disputeId = ghostDisputeId[order];
        if (disputeId == 0) return ITrustWorkReputation.Outcome.DeliveryExpired;
        if (!_wasPanel(disputeId)) return ITrustWorkReputation.Outcome.NoPanel;
        uint256 forFreelancer;
        uint256 forClient;
        for (uint256 j; j < 3; ++j) {
            if (_disputes[disputeId].revealed[j] == 1) ++forFreelancer;
            if (_disputes[disputeId].revealed[j] == 2) ++forClient;
        }
        if (forFreelancer >= 2) return ITrustWorkReputation.Outcome.FreelancerWins;
        if (forClient >= 2) return ITrustWorkReputation.Outcome.ClientWins;
        return ITrustWorkReputation.Outcome.Split;
    }

    function _recordGhost(WorkOrder order, ITrustWorkReputation.Outcome outcome) internal {
        ghostOutcome[order] = outcome;
        ghostRegisteredAt[order] = uint64(block.timestamp);
        ITrustWorkReputation.OrderFacts memory facts = reputation.factsOf(address(order));
        assertEq(facts.settledMilestones, ghostSettled[order]);
        assertEq(facts.freelancerAwarded + facts.clientReturned, order.totalAmount());
        ghostFactsHash[order] = keccak256(abi.encode(facts));
        registeredOrders.push(order);
        ++_registrationsByOutcome[uint256(outcome)];
        _countGhost(client, ITrustWorkReputation.Role.Client, outcome, ghostSettled[order]);
        _countGhost(freelancer, ITrustWorkReputation.Role.Freelancer, outcome, ghostSettled[order]);
    }

    function _countGhost(
        address account,
        ITrustWorkReputation.Role role,
        ITrustWorkReputation.Outcome outcome,
        uint256 settled
    ) internal {
        uint256[8] storage stats = _ghostStats[account][role];
        ++stats[0];
        ++stats[uint256(outcome)];
        stats[7] += settled;
    }

    function _escrowState(WorkOrder order) internal view returns (bytes32) {
        bytes32 h = keccak256(
            abi.encode(
                order.status(),
                order.currentMilestone(),
                order.outstandingObligations(),
                order.approvalNonce(),
                order.disputeId(),
                order.directPaid(),
                order.claimsPaid(),
                order.claimable(client),
                order.claimable(freelancer),
                order.claimable(order.feeRecipient())
            )
        );
        h = keccak256(
            abi.encode(
                h,
                court.feesReceived(),
                court.penaltiesReceived(),
                court.claimsPaid(),
                court.pendingFees(),
                court.totalClaimable(),
                court.disputeCount(),
                registry.totalStaked(),
                registry.depositsReceived(),
                registry.withdrawalsPaid(),
                registry.penaltiesSent()
            )
        );
        address[3] memory holders = [address(order), address(court), address(registry)];
        for (uint256 i; i < 3; ++i) {
            h = keccak256(abi.encode(h, paymentToken.balanceOf(holders[i]), stakeToken.balanceOf(holders[i])));
        }
        return h;
    }
}
