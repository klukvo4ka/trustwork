// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {TrustWorkFactory} from "../../src/TrustWorkFactory.sol";
import {WorkOrder} from "../../src/WorkOrder.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {MockPermitUSDC} from "../mocks/MockPermitUSDC.sol";
import {TransferLedger} from "../utils/TransferLedger.sol";

/// @dev Drives orders, the court and the registry together. Every action that can move tokens runs inside a
/// `TransferLedger` window with the edges this handler's own model expects; credits, rulings and penalties are
/// predicted from the handler's ghosts, never read back from the counters the invariants check.
contract TrustWorkIntegrationHandler is Test {
    uint256 public constant ACTOR_COUNT = 5;
    uint256 public constant MAX_ORDERS = 6;
    uint256 internal constant USDC = 1e6;
    uint256 internal constant FEE_BPS = 250;
    uint256 internal constant REVIEW_PERIOD = 7 days;
    uint256 internal constant DELIVERY_PERIOD = 14 days;
    uint256 internal constant SELECTION_DELAY_BLOCKS = 10;
    uint256 internal constant BLOCKHASH_WINDOW = 256;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct GhostDispute {
        WorkOrder order;
        IArbitrationCourt.DisputeStatus status;
        uint8[3] committed;
        uint8[3] revealed;
    }

    TrustWorkFactory public immutable factory;
    ArbitrationCourt public immutable court;
    ArbitratorRegistry public immutable registry;
    MockPermitUSDC public immutable paymentToken;
    MockPermitUSDC public immutable stakeToken;
    TransferLedger public immutable ledger;
    uint256 public immutable fee;
    uint256 public immutable seatLock;
    address public immutable client;
    uint256 private immutable _clientKey;
    address public immutable freelancer;
    address public immutable feeRecipient;
    address public immutable penaltyRecipient;
    address public immutable donor;

    address[ACTOR_COUNT] public actors;
    WorkOrder[] public orders;
    address[] internal _accounts;

    mapping(WorkOrder order => uint256) public ghostSettled;
    mapping(WorkOrder order => uint256) public ghostDisputeId;
    mapping(WorkOrder order => mapping(address account => uint256)) public ghostOrderCredit;
    mapping(address account => uint256) public ghostCourtCredit;
    uint256 public disputeTotal;
    mapping(uint256 disputeId => GhostDispute) internal _disputes;
    mapping(uint256 disputeId => address[]) internal _candidates;
    mapping(uint256 disputeId => address[3]) internal _panels;

    uint256 public fundedDirectly;
    uint256 public fundedWithPermit;
    uint256 public fundedByPermitFallback;
    uint256 public settledByClient;
    uint256 public settledBySignature;
    uint256 public settledByTimeout;
    uint256 public completedOrders;
    uint256 public expiredOrders;
    uint256 public disputesOpened;
    uint256 public pendingCandidates;
    uint256 public retries;
    uint256 public draws;
    uint256 public rearms;
    uint256 public reveals;
    uint256 public faults;
    uint256 public rulingsFreelancerMajority;
    uint256 public rulingsClientMajority;
    uint256 public rulingsSplit;
    uint256 public rulingsNoPanel;
    uint256 public rulingsApplied;
    uint256 public orderClaims;
    uint256 public courtClaims;
    uint256 public rejectedStaleSignatures;
    uint256 public rejectedExpiredSubmissions;
    uint256 public rejectedEarlyRulings;
    uint256 public rejectedClaims;
    uint256 public stakeDeposits;
    uint256 public stakeWithdrawals;
    uint256 public donations;

    constructor(
        TrustWorkFactory factory_,
        MockPermitUSDC paymentToken_,
        MockPermitUSDC stakeToken_,
        TransferLedger ledger_,
        address client_,
        uint256 clientKey_,
        address freelancer_,
        address feeRecipient_
    ) {
        factory = factory_;
        court = ArbitrationCourt(address(factory_.court()));
        registry = ArbitratorRegistry(address(court.registry()));
        paymentToken = paymentToken_;
        stakeToken = stakeToken_;
        ledger = ledger_;
        fee = court.disputeFee();
        seatLock = court.seatLock();
        client = client_;
        _clientKey = clientKey_;
        freelancer = freelancer_;
        feeRecipient = feeRecipient_;
        penaltyRecipient = court.penaltyRecipient();
        donor = makeAddr("integrationDonor");
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string.concat("integrationArbitrator", vm.toString(i)));
            _accounts.push(actors[i]);
        }
        _accounts.push(client_);
        _accounts.push(freelancer_);
        _accounts.push(feeRecipient_);
        _accounts.push(penaltyRecipient);
    }

    function createOrder(uint256 amountSeed, uint256 roleSeed) external {
        if (orders.length >= MAX_ORDERS) return;
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            amounts[i] = _bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, 1000 * USDC);
        }
        uint256 role = roleSeed % 3;
        address orderFeeRecipient = role == 0 ? feeRecipient : role == 1 ? client : actors[ACTOR_COUNT - 1];
        vm.prank(client);
        WorkOrder order = factory.createWorkOrder(
            freelancer, paymentToken, orderFeeRecipient, FEE_BPS, REVIEW_PERIOD, DELIVERY_PERIOD, amounts
        );
        orders.push(order);
        ledger.trackOrder(address(order));
    }

    function fund(uint256 orderSeed, uint256 fundingSeed) external {
        WorkOrder order = _order(orderSeed);
        if (address(order) == address(0) || order.status() != WorkOrder.OrderStatus.Unfunded) return;
        uint256 total = order.totalAmount();
        paymentToken.mint(client, total);
        uint256 path = fundingSeed % 3;
        uint256 deadline = block.timestamp + 1 days;
        if (path == 0) {
            vm.prank(client);
            paymentToken.approve(address(order), total);
            ledger.begin();
            vm.prank(client);
            order.fund();
            ++fundedDirectly;
        } else {
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(order), total, deadline);
            if (path == 2) {
                vm.prank(client);
                paymentToken.approve(address(order), total);
                deadline = block.timestamp - 1;
                ++fundedByPermitFallback;
            } else {
                ++fundedWithPermit;
            }
            ledger.begin();
            vm.prank(client);
            order.fundWithPermit(deadline, v, r, s);
        }
        _endOne(TransferLedger.Transition.Fund, client, address(order), total);
    }

    function submit(uint256 orderSeed) external {
        WorkOrder order = _order(orderSeed);
        if (!_currentIs(order, WorkOrder.MilestoneStatus.Pending)) return;
        uint256 index = order.currentMilestone();
        uint256 deadline = order.getMilestone(index).deliveryDeadline;
        if (block.timestamp >= deadline) {
            vm.expectRevert(abi.encodeWithSelector(WorkOrder.DeliveryPeriodElapsed.selector, index, deadline));
            vm.prank(freelancer);
            order.submitMilestone(index);
            ++rejectedExpiredSubmissions;
            return;
        }
        vm.prank(freelancer);
        order.submitMilestone(index);
    }

    function settle(uint256 orderSeed, uint256 pathSeed) external {
        WorkOrder order = _order(orderSeed);
        if (!_currentIs(order, WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        WorkOrder.Milestone memory milestone = order.getMilestone(index);
        uint256 path = pathSeed % 3;
        if (path == 1) {
            uint256 nonce = order.approvalNonce();
            bytes memory signature = _signApproval(order, index, nonce, block.timestamp);
            ledger.begin();
            order.approveMilestoneBySignature(index, nonce, block.timestamp, signature);
            ++settledBySignature;
        } else if (path == 2) {
            if (block.timestamp < milestone.reviewDeadline) vm.warp(milestone.reviewDeadline);
            ledger.begin();
            order.finalizeMilestone(index);
            ++settledByTimeout;
        } else {
            ledger.begin();
            vm.prank(client);
            order.approveMilestone(index);
            ++settledByClient;
        }
        uint256 milestoneFee = _fee(milestone.amount);
        TransferLedger.Edge[] memory edges = new TransferLedger.Edge[](milestoneFee == 0 ? 1 : 2);
        edges[0] = TransferLedger.Edge(address(order), freelancer, milestone.amount - milestoneFee);
        if (milestoneFee != 0) edges[1] = TransferLedger.Edge(address(order), order.feeRecipient(), milestoneFee);
        ledger.end(TransferLedger.Transition.Settle, edges);
        ++ghostSettled[order];
        if (ghostSettled[order] == 3) ++completedOrders;
    }

    function reclaim(uint256 orderSeed, uint256 advanceSeed) external {
        WorkOrder order = _order(orderSeed);
        if (!_currentIs(order, WorkOrder.MilestoneStatus.Pending)) return;
        uint256 deadline = order.getMilestone(order.currentMilestone()).deliveryDeadline;
        if (block.timestamp < deadline) {
            if (advanceSeed % 4 != 0) return;
            vm.warp(deadline);
        }
        uint256 credit = _unsettled(order);
        ledger.begin();
        vm.prank(client);
        order.reclaimAfterDeliveryExpiry();
        ledger.end(TransferLedger.Transition.OrderClaim, new TransferLedger.Edge[](0));
        ghostOrderCredit[order][client] += credit;
        ++expiredOrders;
    }

    function openDispute(uint256 orderSeed) external {
        WorkOrder order = _order(orderSeed);
        if (!_currentIs(order, WorkOrder.MilestoneStatus.Submitted)) return;
        uint256 index = order.currentMilestone();
        if (block.timestamp >= order.getMilestone(index).reviewDeadline) return;
        address[] memory expected = _eligible(order);
        stakeToken.mint(client, fee);
        vm.prank(client);
        stakeToken.approve(address(court), fee);
        ledger.begin();
        vm.prank(client);
        order.openDispute(index);
        _endOne(TransferLedger.Transition.DisputeFee, client, address(court), fee);

        uint256 disputeId = ++disputeTotal;
        assertEq(order.disputeId(), disputeId);
        ghostDisputeId[order] = disputeId;
        _disputes[disputeId].order = order;
        _recordSnapshot(disputeId, expected);
        ++disputesOpened;
    }

    function retrySnapshot(uint256 idSeed) external {
        uint256 disputeId = _pickDispute(idSeed, IArbitrationCourt.DisputeStatus.AwaitingCandidates);
        if (disputeId == 0) return;
        if (block.timestamp >= court.getDispute(disputeId).panelDeadline) return;
        address[] memory expected = _eligible(_disputes[disputeId].order);
        court.retrySnapshot(disputeId);
        _recordSnapshot(disputeId, expected);
        ++retries;
    }

    /// @dev Unless `expire`, three draws in four are followed by the whole panel voting on time with `votes`.
    function drawPanel(uint256 idSeed, bool expire, bytes32 votes) external {
        uint256 disputeId = _pickDispute(idSeed, IArbitrationCourt.DisputeStatus.AwaitingSeed);
        if (disputeId == 0) return;
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        if (block.timestamp >= dispute.panelDeadline) return;
        uint256 selectionBlock = dispute.selectionBlock;
        if (expire || block.number > selectionBlock + BLOCKHASH_WINDOW) {
            if (block.number <= selectionBlock + BLOCKHASH_WINDOW) vm.roll(selectionBlock + BLOCKHASH_WINDOW + 1);
            court.drawPanel(disputeId);
            assertEq(court.getDispute(disputeId).selectionBlock, block.number + SELECTION_DELAY_BLOCKS);
            ++rearms;
            return;
        }
        if (block.number <= selectionBlock) vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, keccak256(abi.encode("integration handler seed", disputeId)));
        court.drawPanel(disputeId);
        _disputes[disputeId].status = IArbitrationCourt.DisputeStatus.Voting;
        IArbitrationCourt.Seat[3] memory seats = court.getSeats(disputeId);
        for (uint256 j; j < 3; ++j) {
            assertEq(_candidates[disputeId][seats[j].candidateIndex], seats[j].arbitrator);
            _panels[disputeId][j] = seats[j].arbitrator;
        }
        ++draws;
        if (uint8(votes[31]) % 4 != 0) _castVotes(disputeId, votes);
    }

    /// @dev Seat `j` uses byte `j` of `pattern` modulo 8: 0 skip, 1–3 Freelancer, 4–6 Client, 7 a vote that can never
    /// be revealed.
    function commitVote(uint256 idSeed, bytes32 pattern) external {
        uint256 disputeId = _pickDispute(idSeed, IArbitrationCourt.DisputeStatus.Voting);
        if (disputeId == 0 || block.timestamp >= court.getDispute(disputeId).commitDeadline) return;
        _commit(disputeId, pattern);
    }

    function _commit(uint256 disputeId, bytes32 pattern) internal {
        GhostDispute storage ghost = _disputes[disputeId];
        for (uint256 j; j < 3; ++j) {
            uint8 code = uint8(pattern[j]) % 8;
            if (code == 0 || ghost.committed[j] != 0) continue;
            uint8 vote = code <= 3 ? 1 : code <= 6 ? 2 : 7;
            ghost.committed[j] = vote;
            address arbitrator = _panels[disputeId][j];
            vm.prank(arbitrator);
            court.commitVote(disputeId, _commitment(disputeId, arbitrator, vote));
        }
    }

    /// @dev Seat `j` is skipped when bits `2j, 2j+1` of `pattern` are zero. A dispute still in its commit period is
    /// first warped to its commit deadline, unless a seat is uncommitted and `pattern`'s top bit is set.
    function revealVote(uint256 idSeed, uint256 pattern) external {
        uint256 disputeId = _pickDispute(idSeed, IArbitrationCourt.DisputeStatus.Voting);
        if (disputeId == 0) return;
        _reveal(disputeId, pattern);
    }

    function _reveal(uint256 disputeId, uint256 pattern) internal {
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        if (block.timestamp >= dispute.revealDeadline) return;
        GhostDispute storage ghost = _disputes[disputeId];
        if (block.timestamp < dispute.commitDeadline) {
            bool allCommitted = ghost.committed[0] != 0 && ghost.committed[1] != 0 && ghost.committed[2] != 0;
            if (!allCommitted && pattern >> 255 != 0) return;
            vm.warp(dispute.commitDeadline);
        }
        for (uint256 j; j < 3; ++j) {
            uint8 vote = ghost.committed[j];
            if ((pattern >> (2 * j)) % 4 == 0 || vote == 0 || ghost.revealed[j] != 0) continue;
            address arbitrator = _panels[disputeId][j];
            if (vote > 2) {
                vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidVote.selector, vote));
                vm.prank(arbitrator);
                court.revealVote(disputeId, vote, _salt(disputeId, arbitrator));
                continue;
            }
            vm.prank(arbitrator);
            court.revealVote(disputeId, vote, _salt(disputeId, arbitrator));
            ghost.revealed[j] = vote;
            ++reveals;
        }
    }

    /// @dev The whole panel acts on time: commits with `pattern` as in `commitVote`, then reveals every committed seat.
    function castVotes(uint256 idSeed, bytes32 pattern) external {
        uint256 disputeId = _pickDispute(idSeed, IArbitrationCourt.DisputeStatus.Voting);
        if (disputeId == 0 || block.timestamp >= court.getDispute(disputeId).commitDeadline) return;
        _castVotes(disputeId, pattern);
    }

    function _castVotes(uint256 disputeId, bytes32 pattern) internal {
        _commit(disputeId, pattern);
        vm.warp(court.getDispute(disputeId).commitDeadline);
        _reveal(disputeId, type(uint256).max >> 1);
    }

    function resolve(uint256 idSeed, uint256 advanceSeed) external {
        if (disputeTotal == 0) return;
        uint256 disputeId = idSeed % disputeTotal + 1;
        GhostDispute storage ghost = _disputes[disputeId];
        if (ghost.status == IArbitrationCourt.DisputeStatus.Resolved) return;
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        bool voting = ghost.status == IArbitrationCourt.DisputeStatus.Voting;
        uint256 deadline = voting ? dispute.revealDeadline : dispute.panelDeadline;
        if (block.timestamp < deadline) {
            if (advanceSeed % 3 != 0) return;
            vm.warp(deadline);
        }
        _resolve(disputeId);
    }

    function applyRuling(uint256 orderSeed) external {
        WorkOrder order = _order(orderSeed);
        if (address(order) == address(0) || order.status() != WorkOrder.OrderStatus.Disputed) return;
        uint256 disputeId = ghostDisputeId[order];
        GhostDispute storage ghost = _disputes[disputeId];
        if (ghost.status != IArbitrationCourt.DisputeStatus.Resolved) {
            vm.expectRevert(abi.encodeWithSelector(WorkOrder.RulingNotReady.selector, disputeId));
            order.applyRuling();
            ++rejectedEarlyRulings;
            return;
        }
        _applyRuling(order, disputeId);
    }

    function claimOrder(uint256 orderSeed, uint256 accountSeed) external {
        WorkOrder order = _order(orderSeed);
        if (address(order) == address(0)) return;
        address account = _accounts[accountSeed % _accounts.length];
        WorkOrder.OrderStatus status = order.status();
        if (status != WorkOrder.OrderStatus.Terminated) {
            vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, status));
            order.claimPayout(account);
            ++rejectedClaims;
            return;
        }
        _claimOrder(order, account);
    }

    function claimCourt(uint256 accountSeed) external {
        address account = _accounts[accountSeed % _accounts.length];
        uint256 credit = ghostCourtCredit[account];
        if (credit == 0) {
            vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NothingToClaim.selector, account));
            court.claimReward(account);
            ++rejectedClaims;
            return;
        }
        ledger.begin();
        court.claimReward(account);
        _endOne(TransferLedger.Transition.CourtClaim, address(court), account, credit);
        ghostCourtCredit[account] = 0;
        ++courtClaims;
    }

    /// @dev Pre-signed approvals for the disputed or terminated order's current milestone and the next one.
    function replayStaleSignature(uint256 orderSeed) external {
        WorkOrder order = _order(orderSeed);
        if (address(order) == address(0)) return;
        WorkOrder.OrderStatus status = order.status();
        if (status != WorkOrder.OrderStatus.Disputed && status != WorkOrder.OrderStatus.Terminated) return;
        uint256 index = order.currentMilestone();
        uint256 nonce = order.approvalNonce();
        uint256[2] memory indexes = [index, index + 1];
        uint256[2] memory nonces = [nonce - 1, nonce];
        for (uint256 k; k < 2; ++k) {
            bytes memory signature = _signApproval(order, indexes[k], nonces[k], block.timestamp);
            vm.expectRevert(abi.encodeWithSelector(WorkOrder.InvalidOrderStatus.selector, status));
            order.approveMilestoneBySignature(indexes[k], nonces[k], block.timestamp, signature);
            ++rejectedStaleSignatures;
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        IArbitratorRegistry.Account memory account = registry.accountOf(actor);
        uint256 minimum = account.listed ? 1 : seatLock;
        amount = _bound(amount, minimum, 3 * seatLock);
        stakeToken.mint(actor, amount);
        vm.prank(actor);
        stakeToken.approve(address(registry), amount);
        ledger.begin();
        vm.prank(actor);
        registry.deposit(amount);
        _endOne(TransferLedger.Transition.Stake, actor, address(registry), amount);
        ++stakeDeposits;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 available = registry.freeStake(actor);
        if (available == 0) return;
        amount = _bound(amount, 1, available);
        ledger.begin();
        vm.prank(actor);
        registry.withdraw(amount);
        _endOne(TransferLedger.Transition.Unstake, address(registry), actor, amount);
        ++stakeWithdrawals;
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 1, 2 days));
    }

    function roll(uint256 blocksSeed) external {
        vm.roll(block.number + _bound(blocksSeed, 1, 300));
    }

    function donate(uint256 targetSeed, bool useStakeToken, uint256 amount) external {
        uint256 targets = orders.length + 2;
        uint256 pick = targetSeed % targets;
        address target = pick == 0 ? address(court) : pick == 1 ? address(registry) : address(orders[pick - 2]);
        MockPermitUSDC token = useStakeToken ? stakeToken : paymentToken;
        amount = _bound(amount, 1, 100 * USDC);
        token.mint(donor, amount);
        ledger.begin();
        vm.prank(donor);
        assertTrue(token.transfer(target, amount));
        _endOne(TransferLedger.Transition.Donation, donor, target, amount);
        ++donations;
    }

    /// @dev Passes every deadline, resolves every dispute, applies every ruling and claims every credit.
    function settleEverything() external {
        vm.warp(block.timestamp + 10 days);
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (_disputes[id].status != IArbitrationCourt.DisputeStatus.Resolved) _resolve(id);
        }
        for (uint256 i; i < orders.length; ++i) {
            WorkOrder order = orders[i];
            if (order.status() == WorkOrder.OrderStatus.Disputed) _applyRuling(order, ghostDisputeId[order]);
            if (order.status() != WorkOrder.OrderStatus.Terminated) continue;
            for (uint256 k; k < _accounts.length; ++k) {
                if (ghostOrderCredit[order][_accounts[k]] != 0) _claimOrder(order, _accounts[k]);
            }
        }
        for (uint256 k; k < _accounts.length; ++k) {
            if (ghostCourtCredit[_accounts[k]] != 0) this.claimCourt(k);
        }
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }

    function accountCount() external view returns (uint256) {
        return _accounts.length;
    }

    function accountAt(uint256 i) external view returns (address) {
        return _accounts[i];
    }

    function ghostDisputeOf(uint256 disputeId) external view returns (GhostDispute memory) {
        return _disputes[disputeId];
    }

    function ghostCandidatesOf(uint256 disputeId) external view returns (address[] memory) {
        return _candidates[disputeId];
    }

    function ghostPanelOf(uint256 disputeId) external view returns (address[3] memory) {
        return _panels[disputeId];
    }

    /// @dev Sum of unsettled milestone amounts, from the order's terms and the handler's settlement count.
    function unsettledOf(WorkOrder order) external view returns (uint256) {
        return _unsettled(order);
    }

    function _resolve(uint256 disputeId) internal {
        GhostDispute storage ghost = _disputes[disputeId];
        bool voting = ghost.status == IArbitrationCourt.DisputeStatus.Voting;
        if (!voting) {
            ledger.begin();
            court.resolve(disputeId);
            ledger.end(TransferLedger.Transition.Penalty, new TransferLedger.Edge[](0));
            ghostCourtCredit[ghost.order.client()] += fee;
            ghost.status = IArbitrationCourt.DisputeStatus.Resolved;
            ++rulingsNoPanel;
            return;
        }
        uint256 forFreelancer;
        uint256 forClient;
        for (uint256 j; j < 3; ++j) {
            if (ghost.revealed[j] == 1) ++forFreelancer;
            if (ghost.revealed[j] == 2) ++forClient;
        }
        uint256 revealed = forFreelancer + forClient;
        uint256 faulty = 3 - revealed;
        TransferLedger.Edge[] memory penalties = new TransferLedger.Edge[](faulty);
        for (uint256 k; k < faulty; ++k) {
            penalties[k] = TransferLedger.Edge(address(registry), address(court), seatLock);
        }
        ledger.begin();
        court.resolve(disputeId);
        ledger.end(TransferLedger.Transition.Penalty, penalties);

        uint256 share = revealed == 0 ? 0 : fee / revealed;
        for (uint256 j; j < 3; ++j) {
            if (ghost.revealed[j] != 0) ghostCourtCredit[_panels[disputeId][j]] += share;
        }
        ghostCourtCredit[penaltyRecipient] += fee - share * revealed + faulty * seatLock;
        faults += faulty;
        ghost.status = IArbitrationCourt.DisputeStatus.Resolved;
        if (forFreelancer >= 2) ++rulingsFreelancerMajority;
        else if (forClient >= 2) ++rulingsClientMajority;
        else ++rulingsSplit;
    }

    function _applyRuling(WorkOrder order, uint256 disputeId) internal {
        GhostDispute storage ghost = _disputes[disputeId];
        uint256 disputed = order.getMilestone(ghostSettled[order]).amount;
        uint256 remaining = _unsettled(order) - disputed;
        uint256 freelancerGross;
        if (_wasPanel(disputeId)) {
            uint256 forFreelancer;
            uint256 forClient;
            for (uint256 j; j < 3; ++j) {
                if (ghost.revealed[j] == 1) ++forFreelancer;
                if (ghost.revealed[j] == 2) ++forClient;
            }
            if (forFreelancer >= 2) freelancerGross = disputed;
            else if (forClient < 2) freelancerGross = disputed / 2;
        } else {
            freelancerGross = disputed;
        }
        uint256 feeCredit = _fee(freelancerGross);

        ledger.begin();
        order.applyRuling();
        ledger.end(TransferLedger.Transition.OrderClaim, new TransferLedger.Edge[](0));
        ghostOrderCredit[order][client] += disputed - freelancerGross + remaining;
        ghostOrderCredit[order][freelancer] += freelancerGross - feeCredit;
        ghostOrderCredit[order][order.feeRecipient()] += feeCredit;
        ++rulingsApplied;
    }

    function _claimOrder(WorkOrder order, address account) internal {
        uint256 credit = ghostOrderCredit[order][account];
        if (credit == 0) {
            vm.expectRevert(abi.encodeWithSelector(WorkOrder.NothingToClaim.selector, account));
            order.claimPayout(account);
            ++rejectedClaims;
            return;
        }
        ledger.begin();
        order.claimPayout(account);
        _endOne(TransferLedger.Transition.OrderClaim, address(order), account, credit);
        ghostOrderCredit[order][account] = 0;
        ++orderClaims;
    }

    function _wasPanel(uint256 disputeId) internal view returns (bool) {
        return _panels[disputeId][0] != address(0);
    }

    function _recordSnapshot(uint256 disputeId, address[] memory expected) internal {
        IArbitratorRegistry.Candidate[] memory stored = registry.candidatesOf(disputeId);
        if (expected.length < 3) {
            assertEq(stored.length, 0);
            _disputes[disputeId].status = IArbitrationCourt.DisputeStatus.AwaitingCandidates;
            ++pendingCandidates;
            return;
        }
        assertEq(stored.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(stored[i].arbitrator, expected[i]);
            _candidates[disputeId].push(expected[i]);
        }
        _disputes[disputeId].status = IArbitrationCourt.DisputeStatus.AwaitingSeed;
    }

    function _eligible(WorkOrder order) internal view returns (address[] memory eligible) {
        address[] memory listed = registry.listedAccounts();
        bool[] memory qualifies = new bool[](listed.length);
        uint256 count;
        for (uint256 i; i < listed.length; ++i) {
            address account = listed[i];
            bool isParty = account == order.client() || account == order.freelancer() || account == order.feeRecipient();
            qualifies[i] = !isParty && registry.freeStake(account) >= seatLock;
            if (qualifies[i]) ++count;
        }
        eligible = new address[](count);
        count = 0;
        for (uint256 i; i < listed.length; ++i) {
            if (qualifies[i]) eligible[count++] = listed[i];
        }
    }

    function _order(uint256 seed) internal view returns (WorkOrder) {
        if (orders.length == 0) return WorkOrder(address(0));
        return orders[seed % orders.length];
    }

    function _currentIs(WorkOrder order, WorkOrder.MilestoneStatus expected) internal view returns (bool) {
        if (address(order) == address(0) || order.status() != WorkOrder.OrderStatus.Active) return false;
        return order.getMilestone(order.currentMilestone()).status == expected;
    }

    function _pickDispute(uint256 idSeed, IArbitrationCourt.DisputeStatus status) internal view returns (uint256) {
        uint256 matching;
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (_disputes[id].status == status) ++matching;
        }
        if (matching == 0) return 0;
        uint256 target = idSeed % matching;
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (_disputes[id].status != status) continue;
            if (target == 0) return id;
            --target;
        }
        return 0;
    }

    function _unsettled(WorkOrder order) internal view returns (uint256 total) {
        for (uint256 i = ghostSettled[order]; i < 3; ++i) {
            total += order.getMilestone(i).amount;
        }
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        uint256 wholeUnits = amount / 10_000;
        uint256 remainder = amount % 10_000;
        return wholeUnits * FEE_BPS + remainder * FEE_BPS / 10_000;
    }

    function _endOne(TransferLedger.Transition transition, address from, address to, uint256 amount) internal {
        TransferLedger.Edge[] memory edges = new TransferLedger.Edge[](1);
        edges[0] = TransferLedger.Edge(from, to, amount);
        ledger.end(transition, edges);
    }

    function _salt(uint256 disputeId, address arbitrator) internal pure returns (bytes32) {
        return keccak256(abi.encode("integration handler salt", disputeId, arbitrator));
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

    function _signApproval(WorkOrder order, uint256 index, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = order.approvalDigest(index, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_clientKey, digest);
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
            vm.sign(_clientKey, keccak256(abi.encodePacked(hex"1901", paymentToken.DOMAIN_SEPARATOR(), structHash)));
    }
}
