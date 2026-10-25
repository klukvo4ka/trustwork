// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {MockArbitrationFactory} from "../mocks/MockArbitrationFactory.sol";
import {MockDisputableOrder} from "../mocks/MockDisputableOrder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

abstract contract CourtTestBase is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant DISPUTE_FEE = 20 * USDC;
    uint256 internal constant SEAT_LOCK = 100 * USDC;
    uint256 internal constant ACTIVATION_DELAY = 2 days;
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant START_BLOCK = 1000;
    uint8 internal constant FREELANCER_VOTE = 1;
    uint8 internal constant CLIENT_VOTE = 2;

    address internal client = makeAddr("client");
    address internal freelancer = makeAddr("freelancer");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal penaltyRecipient = makeAddr("penaltyRecipient");

    MockUSDC internal token;
    MockArbitrationFactory internal factory;
    ArbitrationCourt internal court;
    ArbitratorRegistry internal registry;
    MockDisputableOrder internal order;

    function setUp() public virtual {
        vm.warp(START);
        vm.roll(START_BLOCK);
        token = new MockUSDC();
        factory = new MockArbitrationFactory(token, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        court = factory.court();
        registry = ArbitratorRegistry(address(court.registry()));
        order = factory.createOrder(client, freelancer, feeRecipient);
    }

    function _arbitrator(uint256 i) internal returns (address) {
        return makeAddr(string.concat("arbitrator", vm.toString(i)));
    }

    function _deposit(address arbitrator, uint256 amount) internal {
        token.mint(arbitrator, amount);
        vm.startPrank(arbitrator);
        token.approve(address(registry), amount);
        registry.deposit(amount);
        vm.stopPrank();
    }

    function _activeArbitrators(uint256 count, uint256 amount) internal returns (address[] memory arbitrators) {
        arbitrators = new address[](count);
        for (uint256 i; i < count; ++i) {
            arbitrators[i] = _arbitrator(i);
            _deposit(arbitrators[i], amount);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
    }

    function _open() internal returns (uint256) {
        return _openFor(order, client);
    }

    function _openFor(MockDisputableOrder target, address payer) internal returns (uint256) {
        token.mint(payer, DISPUTE_FEE);
        vm.prank(payer);
        token.approve(address(court), DISPUTE_FEE);
        return target.openDispute(0);
    }

    function _setSeedBlock(uint256 disputeId, bytes32 blockHash) internal {
        uint256 selectionBlock = court.getDispute(disputeId).selectionBlock;
        vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, blockHash);
    }

    function _draw(uint256 disputeId) internal returns (address[3] memory panel) {
        _setSeedBlock(disputeId, keccak256(abi.encode("blockhash", disputeId)));
        court.drawPanel(disputeId);
        IArbitrationCourt.Seat[3] memory seats = court.getSeats(disputeId);
        for (uint256 j; j < 3; ++j) {
            panel[j] = seats[j].arbitrator;
        }
    }

    function _salt(address arbitrator, uint256 disputeId) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", arbitrator, disputeId));
    }

    /// @dev Independent encoding of design section 9.1.
    function _expectedCommitment(
        uint256 chainId,
        address courtAddress,
        uint256 disputeId,
        address arbitrator,
        uint8 vote,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("TrustWork.ArbitrationVote.v1"), chainId, courtAddress, disputeId, arbitrator, vote, salt
            )
        );
    }

    function _commit(uint256 disputeId, address arbitrator, uint8 vote) internal {
        bytes32 commitment = _expectedCommitment(
            block.chainid, address(court), disputeId, arbitrator, vote, _salt(arbitrator, disputeId)
        );
        vm.prank(arbitrator);
        court.commitVote(disputeId, commitment);
    }

    function _reveal(uint256 disputeId, address arbitrator, uint8 vote) internal {
        vm.prank(arbitrator);
        court.revealVote(disputeId, vote, _salt(arbitrator, disputeId));
    }

    function _toRevealPhase(uint256 disputeId) internal {
        vm.warp(court.getDispute(disputeId).commitDeadline);
    }

    function _toResolution(uint256 disputeId) internal {
        vm.warp(court.getDispute(disputeId).revealDeadline);
    }

    /// @dev Independent reimplementation of design section 7.3.
    function _expectedSelection(bytes32 seed, uint256 candidateCount) internal pure returns (uint256[3] memory chosen) {
        uint256[] memory positions = new uint256[](candidateCount);
        for (uint256 i; i < candidateCount; ++i) {
            positions[i] = i;
        }
        for (uint256 j; j < 3; ++j) {
            uint256 pick = j + uint256(keccak256(abi.encode(seed, j))) % (candidateCount - j);
            uint256 chosenIndex = positions[pick];
            positions[pick] = positions[j];
            positions[j] = chosenIndex;
            chosen[j] = chosenIndex;
        }
    }

    function _status(uint256 disputeId) internal view returns (IArbitrationCourt.DisputeStatus) {
        return court.getDispute(disputeId).status;
    }

    function _assertCourtBalanced() internal view {
        assertEq(
            court.feesReceived() + court.penaltiesReceived(),
            court.claimsPaid() + court.pendingFees() + court.totalClaimable()
        );
        assertEq(court.penaltiesReceived(), registry.penaltiesSent());
    }
}
