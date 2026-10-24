// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {RegistryCourtHarness} from "../mocks/RegistryCourtHarness.sol";

contract ArbitratorRegistryHandler is Test {
    uint256 public constant ACTOR_COUNT = 6;
    uint256 internal constant ACTIVATION_DELAY = 2 days;

    struct Ghost {
        uint256 stake;
        uint256 warming;
        uint256 warmingUntil;
        uint256 reservations;
        uint256 lockedSeats;
        bool listed;
    }

    struct Seat {
        uint256 disputeId;
        uint256 index;
    }

    RegistryCourtHarness public immutable court;
    ArbitratorRegistry public immutable registry;
    MockUSDC public immutable token;
    uint256 public immutable seatLock;

    address[ACTOR_COUNT] public actors;
    address[3] internal parties;
    mapping(address actor => Ghost) internal ghosts;
    address[] internal ghostListing;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostPenalties;
    uint256 public ghostDonations;

    uint256 internal nextDisputeId;
    uint256[] internal snapshotIds;
    mapping(uint256 disputeId => address[]) internal ghostCandidates;
    mapping(uint256 disputeId => IArbitratorRegistry.CandidateState[]) internal ghostStates;
    mapping(uint256 disputeId => IArbitratorRegistry.SnapshotState) internal ghostSnapshotState;
    uint256[] internal reservedSnapshots;
    Seat[] internal lockedSeats;
    Seat[] internal finishedSeats;

    uint256 public deposits;
    uint256 public rejectedDeposits;
    uint256 public listings;
    uint256 public delistings;
    uint256 public withdrawals;
    uint256 public rejectedWithdrawals;
    uint256 public snapshots;
    uint256 public failedSnapshots;
    uint256 public selections;
    uint256 public reservationReleases;
    uint256 public seatReleases;
    uint256 public penalizedReleases;
    uint256 public rejectedReleases;

    constructor(RegistryCourtHarness court_, MockUSDC token_, address[3] memory parties_) {
        court = court_;
        registry = court_.registry();
        token = token_;
        seatLock = registry.seatLock();
        parties = parties_;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string.concat("registryActor", vm.toString(i)));
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        Ghost storage ghost = ghosts[actor];
        amount = bound(amount, 1, 3 * seatLock);
        _matureGhost(ghost);
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(registry), amount);
        uint256 principal = ghost.stake + ghost.warming + amount;
        if (!ghost.listed && principal < seatLock) {
            vm.expectRevert(
                abi.encodeWithSelector(ArbitratorRegistry.BelowListingMinimum.selector, principal, seatLock)
            );
            registry.deposit(amount);
            vm.stopPrank();
            ++rejectedDeposits;
            return;
        }
        registry.deposit(amount);
        vm.stopPrank();
        ghost.warming += amount;
        ghost.warmingUntil = block.timestamp + ACTIVATION_DELAY;
        ghostDeposits += amount;
        ++deposits;
        if (!ghost.listed) {
            ghost.listed = true;
            ghostListing.push(actor);
            ++listings;
        }
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        Ghost storage ghost = ghosts[actor];
        _matureGhost(ghost);
        uint256 available = ghost.stake - (ghost.reservations + ghost.lockedSeats) * seatLock;
        uint256 amount = bound(amountSeed, 1, available + 1);
        vm.prank(actor);
        if (amount > available) {
            vm.expectRevert(
                abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, amount, available)
            );
            registry.withdraw(amount);
            ++rejectedWithdrawals;
            return;
        }
        registry.withdraw(amount);
        ghost.stake -= amount;
        ghostWithdrawals += amount;
        ++withdrawals;
        _delistGhostIfBelowMinimum(actor, ghost);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 3 days));
    }

    function reserve() external {
        uint256 disputeId = ++nextDisputeId;
        address[] memory eligible = new address[](ghostListing.length);
        uint256 eligibleCount;
        for (uint256 i; i < ghostListing.length; ++i) {
            if (_ghostFree(ghosts[ghostListing[i]]) >= seatLock) eligible[eligibleCount++] = ghostListing[i];
        }

        uint256 count = court.reserveCandidates(disputeId, parties);
        assertEq(count, eligibleCount);
        if (count < 3) {
            ++failedSnapshots;
            return;
        }
        for (uint256 i; i < count; ++i) {
            Ghost storage ghost = ghosts[eligible[i]];
            _matureGhost(ghost);
            ++ghost.reservations;
            ghostCandidates[disputeId].push(eligible[i]);
            ghostStates[disputeId].push(IArbitratorRegistry.CandidateState.Reserved);
        }
        ghostSnapshotState[disputeId] = IArbitratorRegistry.SnapshotState.Reserved;
        snapshotIds.push(disputeId);
        reservedSnapshots.push(disputeId);
        ++snapshots;
    }

    function select(uint256 pick, bytes32 seed) external {
        if (reservedSnapshots.length == 0) return;
        uint256 disputeId = _takeReservedSnapshot(pick);
        (uint256[3] memory indexes, address[3] memory panel) = court.selectPanel(disputeId, seed);
        address[] storage candidates = ghostCandidates[disputeId];
        for (uint256 i; i < candidates.length; ++i) {
            --ghosts[candidates[i]].reservations;
            ghostStates[disputeId][i] = IArbitratorRegistry.CandidateState.Unselected;
        }
        for (uint256 j; j < 3; ++j) {
            assertEq(panel[j], candidates[indexes[j]]);
            ++ghosts[panel[j]].lockedSeats;
            ghostStates[disputeId][indexes[j]] = IArbitratorRegistry.CandidateState.Locked;
            lockedSeats.push(Seat({disputeId: disputeId, index: indexes[j]}));
        }
        ghostSnapshotState[disputeId] = IArbitratorRegistry.SnapshotState.Selected;
        ++selections;
    }

    function releaseReservations(uint256 pick) external {
        if (reservedSnapshots.length == 0) return;
        uint256 disputeId = _takeReservedSnapshot(pick);
        court.releaseReservations(disputeId);
        address[] storage candidates = ghostCandidates[disputeId];
        for (uint256 i; i < candidates.length; ++i) {
            --ghosts[candidates[i]].reservations;
            ghostStates[disputeId][i] = IArbitratorRegistry.CandidateState.Released;
        }
        ghostSnapshotState[disputeId] = IArbitratorRegistry.SnapshotState.Released;
        ++reservationReleases;
    }

    function releaseSeat(uint256 pick, uint256 penaltySeed) external {
        if (lockedSeats.length == 0) return;
        uint256 position = pick % lockedSeats.length;
        Seat memory seat = lockedSeats[position];
        lockedSeats[position] = lockedSeats[lockedSeats.length - 1];
        lockedSeats.pop();
        uint256 penalty = bound(penaltySeed, 0, seatLock);
        address arbitrator = ghostCandidates[seat.disputeId][seat.index];

        court.releaseSeat(seat.disputeId, seat.index, penalty);

        Ghost storage ghost = ghosts[arbitrator];
        --ghost.lockedSeats;
        ghost.stake -= penalty;
        ghostPenalties += penalty;
        ghostStates[seat.disputeId][seat.index] = IArbitratorRegistry.CandidateState.Released;
        finishedSeats.push(seat);
        ++seatReleases;
        if (penalty != 0) ++penalizedReleases;
        _delistGhostIfBelowMinimum(arbitrator, ghost);
    }

    function releaseFinishedSeatAgain(uint256 pick) external {
        if (finishedSeats.length == 0) return;
        Seat memory seat = finishedSeats[pick % finishedSeats.length];
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.UnknownSeat.selector, seat.disputeId, seat.index));
        court.releaseSeat(seat.disputeId, seat.index, 0);
        ++rejectedReleases;
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1000 * seatLock);
        token.mint(address(registry), amount);
        ghostDonations += amount;
    }

    function ghostOf(address actor) external view returns (Ghost memory) {
        return ghosts[actor];
    }

    function ghostListingOrder() external view returns (address[] memory) {
        return ghostListing;
    }

    function snapshotCount() external view returns (uint256) {
        return snapshotIds.length;
    }

    function snapshotAt(uint256 position)
        external
        view
        returns (uint256 disputeId, address[] memory candidates, IArbitratorRegistry.CandidateState[] memory states)
    {
        disputeId = snapshotIds[position];
        return (disputeId, ghostCandidates[disputeId], ghostStates[disputeId]);
    }

    function ghostSnapshotStateOf(uint256 disputeId) external view returns (IArbitratorRegistry.SnapshotState) {
        return ghostSnapshotState[disputeId];
    }

    function _takeReservedSnapshot(uint256 pick) private returns (uint256 disputeId) {
        uint256 position = pick % reservedSnapshots.length;
        disputeId = reservedSnapshots[position];
        reservedSnapshots[position] = reservedSnapshots[reservedSnapshots.length - 1];
        reservedSnapshots.pop();
    }

    function _matureGhost(Ghost storage ghost) private {
        if (ghost.warming != 0 && ghost.warmingUntil <= block.timestamp) {
            ghost.stake += ghost.warming;
            ghost.warming = 0;
        }
    }

    function _ghostFree(Ghost storage ghost) private view returns (uint256) {
        uint256 matured = ghost.warmingUntil <= block.timestamp ? ghost.warming : 0;
        return ghost.stake + matured - (ghost.reservations + ghost.lockedSeats) * seatLock;
    }

    function _delistGhostIfBelowMinimum(address actor, Ghost storage ghost) private {
        if (!ghost.listed || ghost.stake + ghost.warming >= seatLock) return;
        for (uint256 i; i < ghostListing.length; ++i) {
            if (ghostListing[i] == actor) {
                ghostListing[i] = ghostListing[ghostListing.length - 1];
                ghostListing.pop();
                break;
            }
        }
        ghost.listed = false;
        ++delistings;
    }
}
