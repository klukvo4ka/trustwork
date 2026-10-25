// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";
import {TransferLedger} from "./TransferLedger.sol";

/// @dev Factory, court and registry deployed together. `SharedToken` uses one token for escrow and stake;
/// `SplitToken` uses a separate stake token. Expected fees and credits are computed here without `WorkOrder.feeFor`.
abstract contract IntegrationTestBase is Test {
    enum Outcome {
        FreelancerMajority,
        ClientMajority,
        SplitByTie,
        SplitByZeroReveals,
        NoPanel
    }

    enum Funding {
        Fund,
        Permit,
        FailedPermitWithAllowance
    }

    enum Settlement {
        Direct,
        Signed,
        Timeout
    }

    uint256 internal constant USDC = 1e6;
    uint256 internal constant DISPUTE_FEE = 20 * USDC;
    uint256 internal constant SEAT_LOCK = 100 * USDC;
    uint256 internal constant FEE_BPS = 250;
    uint256 internal constant REVIEW_PERIOD = 7 days;
    uint256 internal constant DELIVERY_PERIOD = 14 days;
    uint256 internal constant ACTIVATION_DELAY = 2 days;
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant START_BLOCK = 1000;
    uint8 internal constant FOR_FREELANCER = 1;
    uint8 internal constant FOR_CLIENT = 2;
    uint8 internal constant NO_VOTE = 0;

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
    address internal penaltyRecipient = makeAddr("penaltyRecipient");
    address internal stranger = makeAddr("stranger");
    address internal donor = makeAddr("donor");

    MockPermitUSDC internal paymentToken;
    MockPermitUSDC internal stakeToken;
    TrustWorkFactory internal factory;
    ArbitrationCourt internal court;
    ArbitratorRegistry internal registry;
    TransferLedger internal ledger;

    function _sharedToken() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.warp(START);
        vm.roll(START_BLOCK);
        (client, clientKey) = makeAddrAndKey("client");
        paymentToken = new MockPermitUSDC();
        stakeToken = _sharedToken() ? paymentToken : new MockPermitUSDC();
        factory = new TrustWorkFactory(stakeToken, DISPUTE_FEE, SEAT_LOCK, penaltyRecipient);
        court = ArbitrationCourt(address(factory.court()));
        registry = ArbitratorRegistry(address(court.registry()));
        ledger = new TransferLedger(paymentToken, stakeToken, address(court), address(registry));
    }

    function _defaultAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = 1000 * USDC;
        amounts[1] = 2500 * USDC;
        amounts[2] = 500 * USDC;
    }

    function _arbitrator(uint256 i) internal returns (address) {
        return makeAddr(string.concat("arbitrator", vm.toString(i)));
    }

    function _stake(address arbitrator, uint256 amount) internal {
        stakeToken.mint(arbitrator, amount);
        vm.prank(arbitrator);
        stakeToken.approve(address(registry), amount);
        ledger.begin();
        vm.prank(arbitrator);
        registry.deposit(amount);
        _end(TransferLedger.Transition.Stake, arbitrator, address(registry), amount);
    }

    function _activateArbitrators(uint256 count, uint256 amount) internal returns (address[] memory arbitrators) {
        arbitrators = new address[](count);
        for (uint256 i; i < count; ++i) {
            arbitrators[i] = _arbitrator(i);
            _stake(arbitrators[i], amount);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
    }

    function _createOrder(address orderClient, address orderFeeRecipient, uint256[] memory amounts)
        internal
        returns (WorkOrder order)
    {
        vm.prank(orderClient);
        order = factory.createWorkOrder(
            freelancer, paymentToken, orderFeeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, amounts
        );
        ledger.trackOrder(address(order));
    }

    function _createDefaultOrder() internal returns (WorkOrder) {
        return _createOrder(client, feeRecipient, _defaultAmounts());
    }

    function _fund(WorkOrder order) internal {
        uint256 total = order.totalAmount();
        paymentToken.mint(order.client(), total);
        vm.prank(order.client());
        paymentToken.approve(address(order), total);
        ledger.begin();
        vm.prank(order.client());
        order.fund();
        _end(TransferLedger.Transition.Fund, order.client(), address(order), total);
    }

    function _submit(WorkOrder order, uint256 index) internal {
        vm.prank(freelancer);
        order.submitMilestone(index);
    }

    function _approve(WorkOrder order, uint256 index) internal {
        uint256 amount = order.getMilestone(index).amount;
        ledger.begin();
        vm.prank(order.client());
        order.approveMilestone(index);
        _endSettlement(order, amount);
    }

    function _submitAndApprove(WorkOrder order, uint256 index) internal {
        _submit(order, index);
        _approve(order, index);
    }

    function _approveCourtFee(address payer) internal {
        stakeToken.mint(payer, DISPUTE_FEE);
        vm.prank(payer);
        stakeToken.approve(address(court), DISPUTE_FEE);
    }

    /// @dev Submits `index`, opens the dispute as the order's client and books the court fee.
    function _openDispute(WorkOrder order, uint256 index) internal returns (uint256 disputeId) {
        _submit(order, index);
        _approveCourtFee(order.client());
        ledger.begin();
        vm.prank(order.client());
        order.openDispute(index);
        _end(TransferLedger.Transition.DisputeFee, order.client(), address(court), DISPUTE_FEE);
        disputeId = order.disputeId();
    }

    function _salt(uint256 disputeId, address arbitrator) internal pure returns (bytes32) {
        return keccak256(abi.encode("integration salt", disputeId, arbitrator));
    }

    function _commitment(uint256 disputeId, address arbitrator, uint8 vote) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("TrustWork.ArbitrationVote.v1"),
                block.chainid,
                address(court),
                disputeId,
                arbitrator,
                vote,
                _salt(disputeId, arbitrator)
            )
        );
    }

    function _drawPanel(uint256 disputeId) internal returns (address[3] memory panel) {
        uint256 selectionBlock = court.getDispute(disputeId).selectionBlock;
        if (block.number <= selectionBlock) vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256(abi.encode("integration seed", disputeId)));
        court.drawPanel(disputeId);
        IArbitrationCourt.Seat[3] memory seats = court.getSeats(disputeId);
        for (uint256 j; j < 3; ++j) {
            panel[j] = seats[j].arbitrator;
        }
    }

    function _votesFor(Outcome outcome) internal pure returns (uint8[3] memory votes) {
        if (outcome == Outcome.FreelancerMajority) votes = [FOR_FREELANCER, FOR_FREELANCER, FOR_CLIENT];
        else if (outcome == Outcome.ClientMajority) votes = [FOR_CLIENT, FOR_CLIENT, FOR_FREELANCER];
        else if (outcome == Outcome.SplitByTie) votes = [FOR_FREELANCER, FOR_CLIENT, NO_VOTE];
        else votes = [NO_VOTE, NO_VOTE, NO_VOTE];
    }

    /// @dev Drives the court to `outcome` and books the penalty transfers it causes. `NoPanel` requires a dispute that
    /// has not been drawn.
    function _resolveAs(uint256 disputeId, Outcome outcome) internal {
        if (outcome == Outcome.NoPanel) {
            vm.warp(court.getDispute(disputeId).panelDeadline);
            ledger.begin();
            court.resolve(disputeId);
            ledger.end(TransferLedger.Transition.Penalty, new TransferLedger.Edge[](0));
            return;
        }
        address[3] memory panel = _drawPanel(disputeId);
        uint8[3] memory votes = _votesFor(outcome);
        for (uint256 j; j < 3; ++j) {
            if (votes[j] == NO_VOTE) continue;
            vm.prank(panel[j]);
            court.commitVote(disputeId, _commitment(disputeId, panel[j], votes[j]));
        }
        vm.warp(court.getDispute(disputeId).commitDeadline);
        for (uint256 j; j < 3; ++j) {
            if (votes[j] == NO_VOTE) continue;
            vm.prank(panel[j]);
            court.revealVote(disputeId, votes[j], _salt(disputeId, panel[j]));
        }
        vm.warp(court.getDispute(disputeId).revealDeadline);
        uint256 faults;
        for (uint256 j; j < 3; ++j) {
            if (votes[j] == NO_VOTE) ++faults;
        }
        TransferLedger.Edge[] memory penalties = new TransferLedger.Edge[](faults);
        uint256 k;
        for (uint256 j; j < 3; ++j) {
            if (votes[j] == NO_VOTE) {
                penalties[k++] = TransferLedger.Edge(address(registry), address(court), SEAT_LOCK);
            }
        }
        ledger.begin();
        court.resolve(disputeId);
        ledger.end(TransferLedger.Transition.Penalty, penalties);
    }

    function _applyRuling(WorkOrder order) internal {
        ledger.begin();
        order.applyRuling();
        ledger.end(TransferLedger.Transition.OrderClaim, new TransferLedger.Edge[](0));
    }

    function _claim(WorkOrder order, address account) internal returns (uint256 amount) {
        uint256 credit = order.claimable(account);
        ledger.begin();
        amount = order.claimPayout(account);
        _end(TransferLedger.Transition.OrderClaim, address(order), account, credit);
        assertEq(amount, credit);
    }

    function _claimCourt(address account) internal returns (uint256 amount) {
        uint256 credit = court.claimable(account);
        ledger.begin();
        amount = court.claimReward(account);
        _end(TransferLedger.Transition.CourtClaim, address(court), account, credit);
    }

    function _donate(IERC20 token, address to, uint256 amount) internal {
        MockPermitUSDC(address(token)).mint(donor, amount);
        ledger.begin();
        vm.prank(donor);
        assertTrue(token.transfer(to, amount));
        _end(TransferLedger.Transition.Donation, donor, to, amount);
    }

    function _end(TransferLedger.Transition transition, address from, address to, uint256 amount) internal {
        TransferLedger.Edge[] memory edges = new TransferLedger.Edge[](1);
        edges[0] = TransferLedger.Edge(from, to, amount);
        ledger.end(transition, edges);
    }

    function _endSettlement(WorkOrder order, uint256 amount) internal {
        uint256 fee = _fee(amount, order.feeBps());
        TransferLedger.Edge[] memory edges = new TransferLedger.Edge[](fee == 0 ? 1 : 2);
        edges[0] = TransferLedger.Edge(address(order), freelancer, amount - fee);
        if (fee != 0) edges[1] = TransferLedger.Edge(address(order), order.feeRecipient(), fee);
        ledger.end(TransferLedger.Transition.Settle, edges);
    }

    function _claimAll(WorkOrder order) internal {
        address[3] memory accounts = [client, freelancer, feeRecipient];
        for (uint256 i; i < 3; ++i) {
            if (order.claimable(accounts[i]) != 0) _claim(order, accounts[i]);
        }
    }

    function _claimCourtCredits(uint256 disputeId) internal {
        IArbitrationCourt.Seat[3] memory seats = court.getSeats(disputeId);
        for (uint256 j; j < 3; ++j) {
            if (seats[j].arbitrator != address(0) && court.claimable(seats[j].arbitrator) != 0) {
                _claimCourt(seats[j].arbitrator);
            }
        }
        if (court.claimable(penaltyRecipient) != 0) _claimCourt(penaltyRecipient);
        if (court.claimable(client) != 0) _claimCourt(client);
    }

    function _fundBy(WorkOrder order, Funding funding) internal {
        uint256 total = order.totalAmount();
        paymentToken.mint(client, total);
        uint256 deadline = block.timestamp + 1 days;
        if (funding == Funding.Fund) {
            vm.prank(client);
            paymentToken.approve(address(order), total);
            ledger.begin();
            vm.prank(client);
            order.fund();
        } else {
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(order), total, deadline);
            if (funding == Funding.FailedPermitWithAllowance) {
                vm.prank(client);
                paymentToken.approve(address(order), total);
                deadline = block.timestamp - 1;
            }
            ledger.begin();
            vm.prank(client);
            order.fundWithPermit(deadline, v, r, s);
        }
        _end(TransferLedger.Transition.Fund, client, address(order), total);
        assertEq(paymentToken.allowance(client, address(order)), 0);
    }

    function _settleBy(WorkOrder order, uint256 index, Settlement settlement) internal {
        uint256 amount = order.getMilestone(index).amount;
        if (settlement == Settlement.Signed) {
            bytes memory signature = _signApproval(order, index, index, block.timestamp);
            ledger.begin();
            vm.prank(stranger);
            order.approveMilestoneBySignature(index, index, block.timestamp, signature);
        } else if (settlement == Settlement.Timeout) {
            vm.warp(order.getMilestone(index).reviewDeadline);
            ledger.begin();
            vm.prank(stranger);
            order.finalizeMilestone(index);
        } else {
            ledger.begin();
            vm.prank(client);
            order.approveMilestone(index);
        }
        _endSettlement(order, amount);
    }

    /// @dev `floor(amount * bps / 10_000)` without overflow and without `Math.mulDiv`.
    function _fee(uint256 amount, uint256 bps) internal pure returns (uint256) {
        uint256 wholeUnits = amount / 10_000;
        uint256 remainder = amount % 10_000;
        return wholeUnits * bps + remainder * bps / 10_000;
    }

    /// @dev Design §11.1 credits for disputed amount `disputed` and remaining amount `remaining`.
    function _expectedCredits(uint256 disputed, uint256 remaining, uint256 bps, Outcome outcome)
        internal
        pure
        returns (uint256 clientCredit, uint256 freelancerCredit, uint256 feeCredit)
    {
        if (outcome == Outcome.ClientMajority) return (disputed + remaining, 0, 0);
        if (outcome == Outcome.SplitByTie || outcome == Outcome.SplitByZeroReveals) {
            uint256 half = disputed / 2;
            feeCredit = _fee(half, bps);
            return (disputed - half + remaining, half - feeCredit, feeCredit);
        }
        feeCredit = _fee(disputed, bps);
        return (remaining, disputed - feeCredit, feeCredit);
    }

    function _expectedRuling(Outcome outcome)
        internal
        pure
        returns (IArbitrationCourt.Ruling ruling, IArbitrationCourt.RulingReason reason)
    {
        if (outcome == Outcome.FreelancerMajority) {
            return (IArbitrationCourt.Ruling.FreelancerWins, IArbitrationCourt.RulingReason.Majority);
        }
        if (outcome == Outcome.ClientMajority) {
            return (IArbitrationCourt.Ruling.ClientWins, IArbitrationCourt.RulingReason.Majority);
        }
        if (outcome == Outcome.NoPanel) {
            return (IArbitrationCourt.Ruling.FreelancerWins, IArbitrationCourt.RulingReason.NoPanel);
        }
        return (IArbitrationCourt.Ruling.Split, IArbitrationCourt.RulingReason.NoDecision);
    }

    function _signApproval(WorkOrder order, uint256 index, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("TrustWork")),
                keccak256(bytes("1")),
                block.chainid,
                address(order)
            )
        );
        bytes32 structHash = keccak256(abi.encode(APPROVE_MILESTONE_TYPEHASH, index, nonce, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(clientKey, keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _signPermit(address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, client, spender, value, paymentToken.nonces(client), deadline));
        (v, r, s) =
            vm.sign(clientKey, keccak256(abi.encodePacked(hex"1901", paymentToken.DOMAIN_SEPARATOR(), structHash)));
    }

    /// @dev Revised nonce invariant (design §5.1), counted from milestone states rather than the order's counters.
    function _assertNonceInvariant(WorkOrder order) internal view {
        uint256 settled;
        for (uint256 i; i < order.milestoneCount(); ++i) {
            if (order.getMilestone(i).status == WorkOrder.MilestoneStatus.Settled) ++settled;
        }
        WorkOrder.OrderStatus status = order.status();
        bool ended = status == WorkOrder.OrderStatus.Disputed || status == WorkOrder.OrderStatus.Terminated;
        assertEq(order.approvalNonce(), settled + (ended ? 1 : 0), "nonce invariant");
    }

    function _assertOrderConservation(WorkOrder order) internal view {
        uint256 funded = order.status() == WorkOrder.OrderStatus.Unfunded ? 0 : order.totalAmount();
        assertEq(funded, order.directPaid() + order.claimsPaid() + order.outstandingObligations(), "order conservation");
    }

    /// @dev Design §11.4 equations for the court and registry, and the ledger's per-contract balance model.
    function _assertProtocolEquations() internal view {
        assertEq(
            court.feesReceived() + court.penaltiesReceived(),
            court.claimsPaid() + court.pendingFees() + court.totalClaimable(),
            "court conservation"
        );
        assertEq(court.penaltiesReceived(), registry.penaltiesSent(), "penalties");
        assertEq(
            registry.depositsReceived(),
            registry.withdrawalsPaid() + registry.penaltiesSent() + registry.totalStaked(),
            "registry conservation"
        );
        assertEq(
            court.pendingFees() + court.totalClaimable(),
            ledger.liability(address(court), address(stakeToken)),
            "court liabilities"
        );
        assertEq(
            registry.totalStaked(), ledger.liability(address(registry), address(stakeToken)), "registry liabilities"
        );
        ledger.assertBalances();
    }

    function _assertOrderLedger(WorkOrder order) internal view {
        assertEq(
            order.outstandingObligations(), ledger.liability(address(order), address(paymentToken)), "order liabilities"
        );
        _assertOrderConservation(order);
        _assertNonceInvariant(order);
    }
}
