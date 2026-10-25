// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbitrationCourt} from "../../src/ArbitrationCourt.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitrationCourt} from "../../src/interfaces/IArbitrationCourt.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {MockArbitrationFactory} from "../mocks/MockArbitrationFactory.sol";
import {MockDisputableOrder} from "../mocks/MockDisputableOrder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract ArbitrationCourtHandler is Test {
    uint256 public constant ACTOR_COUNT = 6;
    uint256 public constant ORDER_COUNT = 4;
    uint256 public constant MAX_DISPUTES = 16;
    uint256 internal constant ACTIVATION_DELAY = 2 days;
    uint256 internal constant SELECTION_DELAY_BLOCKS = 10;
    uint256 internal constant BLOCKHASH_WINDOW = 256;

    enum CommitKind {
        None,
        Revealable,
        Unrevealable
    }

    struct GhostSeat {
        CommitKind kind;
        uint8 committedVote;
        uint8 revealedVote;
    }

    struct GhostDispute {
        MockDisputableOrder order;
        IArbitrationCourt.DisputeStatus status;
        IArbitrationCourt.Ruling ruling;
        IArbitrationCourt.RulingReason reason;
        bool hasSnapshot;
    }

    ArbitrationCourt public immutable court;
    ArbitratorRegistry public immutable registry;
    MockUSDC public immutable token;
    uint256 public immutable fee;
    uint256 public immutable seatLock;
    address public immutable penaltyRecipient;

    address[ACTOR_COUNT] public actors;
    MockDisputableOrder[ORDER_COUNT] public orders;
    address[] internal accounts;

    uint256 public disputeTotal;
    mapping(uint256 disputeId => GhostDispute) internal ghostDisputes;
    mapping(uint256 disputeId => address[]) internal ghostCandidates;
    mapping(uint256 disputeId => address[3]) internal ghostPanel;
    mapping(uint256 disputeId => GhostSeat[3]) internal ghostSeats;
    mapping(address account => uint256) public ghostCredit;

    uint256 public ghostFees;
    uint256 public ghostPenalties;
    uint256 public ghostClaims;
    uint256 public ghostDonations;

    uint256 public opened;
    uint256 public pendingCandidates;
    uint256 public retries;
    uint256 public successfulRetries;
    uint256 public rejectedRetries;
    uint256 public draws;
    uint256 public rearms;
    uint256 public validCommits;
    uint256 public unrevealableCommits;
    uint256 public reveals;
    uint256 public rejectedReveals;
    uint256 public noPanelResolutions;
    uint256 public majorityResolutions;
    uint256 public noDecisionResolutions;
    uint256 public penalizedSeats;
    uint256 public earlyResolveRejections;
    uint256 public repeatedResolveRejections;
    uint256 public claims;
    uint256 public emptyClaims;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public donations;

    constructor(MockArbitrationFactory factory, MockUSDC token_) {
        court = factory.court();
        registry = ArbitratorRegistry(address(court.registry()));
        token = token_;
        fee = court.disputeFee();
        seatLock = registry.seatLock();
        penaltyRecipient = court.penaltyRecipient();

        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string.concat("courtActor", vm.toString(i)));
            accounts.push(actors[i]);
        }
        address outsiderClient = makeAddr("outsiderClient");
        address outsiderFreelancer = makeAddr("outsiderFreelancer");
        address outsiderFeeRecipient = makeAddr("outsiderFeeRecipient");
        accounts.push(outsiderClient);
        accounts.push(outsiderFreelancer);
        accounts.push(outsiderFeeRecipient);
        accounts.push(penaltyRecipient);

        orders[0] = factory.createOrder(outsiderClient, outsiderFreelancer, outsiderFeeRecipient);
        orders[1] = factory.createOrder(actors[0], outsiderFreelancer, outsiderFeeRecipient);
        orders[2] = factory.createOrder(outsiderClient, actors[1], outsiderFeeRecipient);
        orders[3] = factory.createOrder(outsiderClient, outsiderFreelancer, actors[2]);
    }

    function openDispute(uint256 orderSeed, uint256 milestoneSeed) external {
        if (disputeTotal >= MAX_DISPUTES) return;
        MockDisputableOrder order = orders[orderSeed % ORDER_COUNT];
        address client = order.client();
        address[] memory expected = _eligible(order);

        token.mint(client, fee);
        vm.prank(client);
        token.approve(address(court), fee);
        uint256 disputeId = order.openDispute(milestoneSeed % 8);

        assertEq(disputeId, ++disputeTotal);
        ghostFees += fee;
        ++opened;
        GhostDispute storage ghost = ghostDisputes[disputeId];
        ghost.order = order;
        _recordSnapshot(disputeId, ghost, expected);
    }

    function retrySnapshot(uint256 idSeed) external {
        if (disputeTotal == 0) return;
        uint256 disputeId = _pick(idSeed, IArbitrationCourt.DisputeStatus.AwaitingCandidates);
        GhostDispute storage ghost = ghostDisputes[disputeId];
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        ++retries;
        if (ghost.status != IArbitrationCourt.DisputeStatus.AwaitingCandidates) {
            vm.expectRevert(
                abi.encodeWithSelector(ArbitrationCourt.InvalidDisputeStatus.selector, disputeId, ghost.status)
            );
            court.retrySnapshot(disputeId);
            ++rejectedRetries;
            return;
        }
        if (block.timestamp >= dispute.panelDeadline) {
            vm.expectRevert(
                abi.encodeWithSelector(ArbitrationCourt.PanelPeriodElapsed.selector, disputeId, dispute.panelDeadline)
            );
            court.retrySnapshot(disputeId);
            ++rejectedRetries;
            return;
        }
        address[] memory expected = _eligible(ghost.order);
        court.retrySnapshot(disputeId);
        _recordSnapshot(disputeId, ghost, expected);
        if (ghost.hasSnapshot) ++successfulRetries;
    }

    function drawPanel(uint256 idSeed, bytes32 blockHash, bool expire) external {
        if (disputeTotal == 0) return;
        uint256 disputeId = _pick(idSeed, IArbitrationCourt.DisputeStatus.AwaitingSeed);
        if (ghostDisputes[disputeId].status != IArbitrationCourt.DisputeStatus.AwaitingSeed) return;
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        if (block.timestamp >= dispute.panelDeadline) return;
        uint256 selectionBlock = dispute.selectionBlock;

        if (expire || block.number > selectionBlock + BLOCKHASH_WINDOW) {
            if (block.number <= selectionBlock + BLOCKHASH_WINDOW) vm.roll(selectionBlock + BLOCKHASH_WINDOW + 1);
            court.drawPanel(disputeId);
            IArbitrationCourt.Dispute memory rearmed = court.getDispute(disputeId);
            assertEq(uint256(rearmed.status), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
            assertEq(rearmed.selectionBlock, block.number + SELECTION_DELAY_BLOCKS);
            ++rearms;
            return;
        }

        if (blockHash == bytes32(0)) blockHash = keccak256(abi.encode(disputeId, selectionBlock));
        if (block.number <= selectionBlock) vm.roll(selectionBlock + 1);
        vm.setBlockhash(selectionBlock, blockHash);
        court.drawPanel(disputeId);

        ghostDisputes[disputeId].status = IArbitrationCourt.DisputeStatus.Voting;
        IArbitrationCourt.Seat[3] memory seats = court.getSeats(disputeId);
        address[] storage candidates = ghostCandidates[disputeId];
        for (uint256 j; j < 3; ++j) {
            assertEq(candidates[seats[j].candidateIndex], seats[j].arbitrator);
            for (uint256 k; k < j; ++k) {
                assertTrue(seats[j].candidateIndex != seats[k].candidateIndex);
            }
            ghostPanel[disputeId][j] = seats[j].arbitrator;
        }
        ++draws;
    }

    /// @dev Seat `j` uses byte `j` of `pattern`: low two bits 0 skip, 1 Freelancer, 2 Client, 3 a vote outside
    /// `{1, 2}` taken from the upper bits.
    function commitVote(uint256 idSeed, bytes32 pattern) external {
        if (disputeTotal == 0) return;
        uint256 disputeId = _pickVoting(idSeed, true);
        if (ghostDisputes[disputeId].status != IArbitrationCourt.DisputeStatus.Voting) return;
        if (block.timestamp >= court.getDispute(disputeId).commitDeadline) return;
        for (uint256 j; j < 3; ++j) {
            uint8 code = uint8(pattern[j]);
            GhostSeat storage seat = ghostSeats[disputeId][j];
            if (code % 4 == 0 || seat.kind != CommitKind.None) continue;
            uint8 vote = code % 4;
            if (vote == 3) {
                vote = code >> 2 == 1 || code >> 2 == 2 ? 0 : code >> 2;
                seat.kind = CommitKind.Unrevealable;
                ++unrevealableCommits;
            } else {
                seat.kind = CommitKind.Revealable;
                ++validCommits;
            }
            seat.committedVote = vote;
            address arbitrator = ghostPanel[disputeId][j];
            vm.prank(arbitrator);
            court.commitVote(disputeId, _commitment(disputeId, arbitrator, vote));
        }
    }

    /// @dev Seat `j` uses nibble `j` of `pattern`: 0 skips the seat, 1 first submits a wrong salt. A dispute still in
    /// its commit period first warps to its commit deadline, unless a seat is uncommitted and `pattern`'s top bit is 1.
    function revealVote(uint256 idSeed, uint256 pattern) external {
        if (disputeTotal == 0) return;
        uint256 disputeId = _pickVoting(idSeed, false);
        if (ghostDisputes[disputeId].status != IArbitrationCourt.DisputeStatus.Voting) return;
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        if (block.timestamp >= dispute.revealDeadline) return;
        if (block.timestamp < dispute.commitDeadline) {
            GhostSeat[3] storage seats = ghostSeats[disputeId];
            bool allCommitted = seats[0].kind != CommitKind.None && seats[1].kind != CommitKind.None
                && seats[2].kind != CommitKind.None;
            if (!allCommitted && pattern >> 255 != 0) return;
            vm.warp(dispute.commitDeadline);
        }
        for (uint256 j; j < 3; ++j) {
            uint256 code = (pattern >> (4 * j)) % 16;
            GhostSeat storage seat = ghostSeats[disputeId][j];
            if (code == 0 || seat.kind == CommitKind.None || seat.revealedVote != 0) continue;
            _revealSeat(disputeId, ghostPanel[disputeId][j], seat, code == 1);
        }
    }

    function _revealSeat(uint256 disputeId, address arbitrator, GhostSeat storage seat, bool tryWrongSaltFirst)
        internal
    {
        if (seat.kind == CommitKind.Unrevealable) {
            vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidVote.selector, seat.committedVote));
            vm.prank(arbitrator);
            court.revealVote(disputeId, seat.committedVote, _salt(disputeId, arbitrator));
            ++rejectedReveals;
            return;
        }
        if (tryWrongSaltFirst) {
            vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidReveal.selector, disputeId, arbitrator));
            vm.prank(arbitrator);
            court.revealVote(disputeId, seat.committedVote, keccak256("wrong salt"));
            ++rejectedReveals;
        }
        vm.prank(arbitrator);
        court.revealVote(disputeId, seat.committedVote, _salt(disputeId, arbitrator));
        seat.revealedVote = seat.committedVote;
        ++reveals;
    }

    /// @dev One call in four first warps to the dispute's resolution time.
    function resolve(uint256 idSeed, uint256 advanceSeed) external {
        if (disputeTotal == 0) return;
        _resolve(_pickUnresolved(idSeed), advanceSeed % 4 == 0);
    }

    function claimReward(uint256 accountSeed) external {
        address account = accounts[accountSeed % accounts.length];
        uint256 credit = ghostCredit[account];
        if (credit == 0) {
            vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.NothingToClaim.selector, account));
            court.claimReward(account);
            ++emptyClaims;
            return;
        }
        uint256 balanceBefore = token.balanceOf(account);
        assertEq(court.claimReward(account), credit);
        assertEq(token.balanceOf(account) - balanceBefore, credit);
        ghostCredit[account] = 0;
        ghostClaims += credit;
        ++claims;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        IArbitratorRegistry.Account memory account = registry.accountOf(actor);
        uint256 minimum = account.listed || account.stake + account.warming >= seatLock ? 1 : seatLock;
        amount = _bound(amount, minimum, 3 * seatLock);
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(registry), amount);
        registry.deposit(amount);
        vm.stopPrank();
        ++deposits;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 available = registry.freeStake(actor);
        if (available == 0) return;
        amount = _bound(amount, 1, available);
        vm.prank(actor);
        registry.withdraw(amount);
        ++withdrawals;
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 1, 1 days));
    }

    function roll(uint256 blocksSeed) external {
        vm.roll(block.number + _bound(blocksSeed, 1, 300));
    }

    function donate(uint256 amount) external {
        amount = _bound(amount, 1, 50 * fee);
        token.mint(address(court), amount);
        ghostDonations += amount;
        ++donations;
    }

    /// @dev CI-07: moves past every deadline and resolves each open dispute.
    function resolveAll() external {
        vm.warp(block.timestamp + 6 days + 1);
        for (uint256 disputeId = 1; disputeId <= disputeTotal; ++disputeId) {
            if (ghostDisputes[disputeId].status != IArbitrationCourt.DisputeStatus.Resolved) {
                _resolve(disputeId, false);
            }
        }
    }

    function claimAll() external {
        for (uint256 i; i < accounts.length; ++i) {
            if (ghostCredit[accounts[i]] != 0) this.claimReward(i);
        }
    }

    function ghostDisputeOf(uint256 disputeId) external view returns (GhostDispute memory) {
        return ghostDisputes[disputeId];
    }

    function ghostCandidatesOf(uint256 disputeId) external view returns (address[] memory) {
        return ghostCandidates[disputeId];
    }

    function ghostPanelOf(uint256 disputeId) external view returns (address[3] memory) {
        return ghostPanel[disputeId];
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    function accountAt(uint256 i) external view returns (address) {
        return accounts[i];
    }

    function _resolve(uint256 disputeId, bool advanceTime) internal {
        GhostDispute storage ghost = ghostDisputes[disputeId];
        IArbitrationCourt.Dispute memory dispute = court.getDispute(disputeId);
        IArbitrationCourt.DisputeStatus status = ghost.status;

        if (status == IArbitrationCourt.DisputeStatus.Resolved) {
            vm.expectRevert(abi.encodeWithSelector(ArbitrationCourt.InvalidDisputeStatus.selector, disputeId, status));
            court.resolve(disputeId);
            ++repeatedResolveRejections;
            return;
        }

        bool voting = status == IArbitrationCourt.DisputeStatus.Voting;
        uint256 deadline = voting ? dispute.revealDeadline : dispute.panelDeadline;
        if (block.timestamp < deadline) {
            if (!advanceTime) {
                bytes4 selector =
                    voting ? ArbitrationCourt.RevealPeriodActive.selector : ArbitrationCourt.PanelPeriodActive.selector;
                vm.expectRevert(abi.encodeWithSelector(selector, disputeId, deadline));
                court.resolve(disputeId);
                ++earlyResolveRejections;
                return;
            }
            vm.warp(deadline);
        }

        court.resolve(disputeId);
        ghost.status = IArbitrationCourt.DisputeStatus.Resolved;
        if (voting) {
            _creditPanel(disputeId, ghost);
        } else {
            ghost.ruling = IArbitrationCourt.Ruling.FreelancerWins;
            ghost.reason = IArbitrationCourt.RulingReason.NoPanel;
            ghostCredit[ghost.order.client()] += fee;
            ++noPanelResolutions;
        }
    }

    function _creditPanel(uint256 disputeId, GhostDispute storage ghost) internal {
        GhostSeat[3] storage seats = ghostSeats[disputeId];
        uint256 forFreelancer;
        uint256 forClient;
        for (uint256 j; j < 3; ++j) {
            if (seats[j].revealedVote == 1) ++forFreelancer;
            if (seats[j].revealedVote == 2) ++forClient;
        }
        uint256 revealed = forFreelancer + forClient;
        uint256 faulty = 3 - revealed;
        uint256 share = revealed == 0 ? 0 : fee / revealed;
        for (uint256 j; j < 3; ++j) {
            if (seats[j].revealedVote != 0) ghostCredit[ghostPanel[disputeId][j]] += share;
        }
        ghostCredit[penaltyRecipient] += fee - share * revealed + faulty * seatLock;
        ghostPenalties += faulty * seatLock;
        penalizedSeats += faulty;

        if (forFreelancer >= 2) {
            ghost.ruling = IArbitrationCourt.Ruling.FreelancerWins;
            ghost.reason = IArbitrationCourt.RulingReason.Majority;
            ++majorityResolutions;
        } else if (forClient >= 2) {
            ghost.ruling = IArbitrationCourt.Ruling.ClientWins;
            ghost.reason = IArbitrationCourt.RulingReason.Majority;
            ++majorityResolutions;
        } else {
            ghost.ruling = IArbitrationCourt.Ruling.Split;
            ghost.reason = IArbitrationCourt.RulingReason.NoDecision;
            ++noDecisionResolutions;
        }
    }

    function _recordSnapshot(uint256 disputeId, GhostDispute storage ghost, address[] memory expected) internal {
        IArbitratorRegistry.Candidate[] memory stored = registry.candidatesOf(disputeId);
        IArbitrationCourt.DisputeStatus status = court.getDispute(disputeId).status;
        if (expected.length < 3) {
            assertEq(stored.length, 0);
            assertEq(uint256(status), uint256(IArbitrationCourt.DisputeStatus.AwaitingCandidates));
            ghost.status = IArbitrationCourt.DisputeStatus.AwaitingCandidates;
            ++pendingCandidates;
            return;
        }
        assertEq(uint256(status), uint256(IArbitrationCourt.DisputeStatus.AwaitingSeed));
        assertEq(court.getDispute(disputeId).selectionBlock, block.number + SELECTION_DELAY_BLOCKS);
        assertEq(stored.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(stored[i].arbitrator, expected[i]);
            ghostCandidates[disputeId].push(expected[i]);
        }
        ghost.status = IArbitrationCourt.DisputeStatus.AwaitingSeed;
        ghost.hasSnapshot = true;
    }

    function _eligible(MockDisputableOrder order) internal view returns (address[] memory eligible) {
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

    /// @dev Picks among disputes in `status` when there are any, otherwise among all disputes.
    function _pick(uint256 idSeed, IArbitrationCourt.DisputeStatus status) internal view returns (uint256) {
        uint256 matching;
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (ghostDisputes[id].status == status) ++matching;
        }
        if (matching == 0 || idSeed % 4 == 0) return idSeed % disputeTotal + 1;
        uint256 target = idSeed % matching;
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (ghostDisputes[id].status != status) continue;
            if (target == 0) return id;
            --target;
        }
        return 0;
    }

    /// @dev Picks among disputes in their commit (`committing`) or reveal period, otherwise among all disputes.
    function _pickVoting(uint256 idSeed, bool committing) internal view returns (uint256) {
        uint256[] memory open = new uint256[](disputeTotal);
        uint256 count;
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (ghostDisputes[id].status != IArbitrationCourt.DisputeStatus.Voting) continue;
            IArbitrationCourt.Dispute memory dispute = court.getDispute(id);
            bool inPhase = committing
                ? block.timestamp < dispute.commitDeadline
                : block.timestamp >= dispute.commitDeadline && block.timestamp < dispute.revealDeadline;
            if (inPhase) open[count++] = id;
        }
        if (count == 0 || idSeed % 4 == 0) return idSeed % disputeTotal + 1;
        return open[idSeed % count];
    }

    function _pickUnresolved(uint256 idSeed) internal view returns (uint256) {
        uint256 unresolved;
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (ghostDisputes[id].status != IArbitrationCourt.DisputeStatus.Resolved) ++unresolved;
        }
        if (unresolved == 0 || idSeed % 4 == 0) return idSeed % disputeTotal + 1;
        uint256 target = idSeed % unresolved;
        for (uint256 id = 1; id <= disputeTotal; ++id) {
            if (ghostDisputes[id].status == IArbitrationCourt.DisputeStatus.Resolved) continue;
            if (target == 0) return id;
            --target;
        }
        return 0;
    }

    function _salt(uint256 disputeId, address arbitrator) internal pure returns (bytes32) {
        return keccak256(abi.encode("court invariant salt", disputeId, arbitrator));
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
}
