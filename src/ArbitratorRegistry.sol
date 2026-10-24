// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IArbitratorRegistry} from "./interfaces/IArbitratorRegistry.sol";
import {PanelSelection} from "./libraries/PanelSelection.sol";

/// @title ArbitratorRegistry
/// @notice Holds arbitrator stake, lists eligible accounts and stores per-dispute candidate snapshots whose collateral
/// is reserved before any selection seed exists. The deploying contract is the only court.
/// @dev Exact-transfer tokens only. Liabilities are tracked in storage; tokens sent directly to the registry create no
/// principal and cannot be withdrawn.
contract ArbitratorRegistry is IArbitratorRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACTIVATION_DELAY = 2 days;
    uint256 public constant MAX_ARBITRATORS = 32;
    uint256 public constant PANEL_SIZE = PanelSelection.PANEL_SIZE;

    IERC20 public immutable stakeToken;
    address public immutable court;
    uint256 public immutable seatLock;
    uint128 private immutable _seatLock;
    address public immutable penaltyRecipient;

    uint256 public totalStaked;
    uint256 public depositsReceived;
    uint256 public withdrawalsPaid;
    uint256 public penaltiesSent;

    /// @dev Packed so that a reservation and the maturation it triggers usually rewrite slots that are already
    /// nonzero: `stake` with `reserved`, `warming` with `locked`, and `warmingUntil` with `listed`.
    struct Ledger {
        uint128 stake;
        uint128 reserved;
        uint128 warming;
        uint128 locked;
        uint64 warmingUntil;
        bool listed;
    }

    mapping(address arbitrator => Ledger) private _accounts;
    mapping(address arbitrator => uint256) private _listPosition;
    address[] private _listed;

    mapping(uint256 disputeId => Candidate[]) private _candidates;
    mapping(uint256 disputeId => SnapshotState) public snapshotState;

    error ZeroAddress();
    error TokenHasNoCode(address token);
    error ZeroSeatLock();
    error PenaltyRecipientIsProtocol(address penaltyRecipient);
    error NotCourt(address caller);
    error PenaltyRecipientCannotStake();
    error ZeroAmount();
    error BelowListingMinimum(uint256 principal, uint256 seatLock);
    error RegistryFull();
    error InsufficientFreeStake(uint256 requested, uint256 available);
    error DepositMismatch(uint256 expected, uint256 received);
    error InvalidSnapshotState(uint256 disputeId, SnapshotState state);
    error UnknownSeat(uint256 disputeId, uint256 candidateIndex);
    error PenaltyTooHigh(uint256 penalty, uint256 seatLock);

    /// @param seatLock_ Stake reserved or locked per candidacy; must fit in `uint128`.
    /// @param penaltyRecipient_ Final beneficiary of penalties forwarded by the court; must not be the court or the
    /// registry itself.
    constructor(IERC20 stakeToken_, uint256 seatLock_, address penaltyRecipient_) {
        if (address(stakeToken_) == address(0) || penaltyRecipient_ == address(0)) revert ZeroAddress();
        if (address(stakeToken_).code.length == 0) revert TokenHasNoCode(address(stakeToken_));
        if (seatLock_ == 0) revert ZeroSeatLock();
        if (penaltyRecipient_ == msg.sender || penaltyRecipient_ == address(this)) {
            revert PenaltyRecipientIsProtocol(penaltyRecipient_);
        }

        stakeToken = stakeToken_;
        court = msg.sender;
        seatLock = seatLock_;
        _seatLock = SafeCast.toUint128(seatLock_);
        penaltyRecipient = penaltyRecipient_;
    }

    /// @notice Adds `amount` to the caller's warming stake, which can back candidacies from
    /// `block.timestamp + ACTIVATION_DELAY`. A new deposit restarts the delay for all stake still warming.
    /// @dev An unlisted account is listed only if its principal reaches `seatLock` and a slot is free.
    function deposit(uint256 amount) external nonReentrant {
        if (msg.sender == penaltyRecipient) revert PenaltyRecipientCannotStake();
        if (amount == 0) revert ZeroAmount();

        Ledger storage account = _accounts[msg.sender];
        _mature(account);
        bool listing = !account.listed;
        if (listing) {
            uint256 principal = uint256(account.stake) + account.warming + amount;
            if (principal < seatLock) revert BelowListingMinimum(principal, seatLock);
            if (_listed.length == MAX_ARBITRATORS) revert RegistryFull();
        }

        uint64 warmingUntil = SafeCast.toUint64(block.timestamp + ACTIVATION_DELAY);
        account.warming += SafeCast.toUint128(amount);
        account.warmingUntil = warmingUntil;
        totalStaked += amount;
        depositsReceived += amount;
        if (listing) _list(msg.sender, account);

        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakeToken.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert DepositMismatch(amount, received);

        emit Deposited(msg.sender, amount, warmingUntil);
    }

    /// @notice Withdraws matured stake that backs no reservation or seat.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Ledger storage account = _accounts[msg.sender];
        _mature(account);
        uint256 available = account.stake - account.locked - account.reserved;
        if (amount > available) revert InsufficientFreeStake(amount, available);

        account.stake -= SafeCast.toUint128(amount);
        totalStaked -= amount;
        withdrawalsPaid += amount;
        _delistIfBelowMinimum(msg.sender, account);

        emit Withdrawn(msg.sender, amount);
        stakeToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Stores the listed accounts that are not excluded and have at least `seatLock` of free matured stake, in
    /// listing order, and reserves `seatLock` from each. Writes nothing if fewer than `PANEL_SIZE` qualify.
    function reserveCandidates(uint256 disputeId, address[3] calldata excluded)
        external
        nonReentrant
        returns (uint256 count)
    {
        _requireCourt();
        _requireSnapshotState(disputeId, SnapshotState.None);

        uint256 listedLength = _listed.length;
        address[] memory eligible = new address[](listedLength);
        for (uint256 i; i < listedLength; ++i) {
            address arbitrator = _listed[i];
            if (arbitrator == excluded[0] || arbitrator == excluded[1] || arbitrator == excluded[2]) continue;
            if (_free(_accounts[arbitrator]) >= seatLock) eligible[count++] = arbitrator;
        }
        if (count < PANEL_SIZE) return count;

        address[] memory reserved = new address[](count);
        Candidate[] storage candidates = _candidates[disputeId];
        for (uint256 i; i < count; ++i) {
            address arbitrator = eligible[i];
            Ledger storage account = _accounts[arbitrator];
            _mature(account);
            account.reserved += _seatLock;
            candidates.push(Candidate({arbitrator: arbitrator, state: CandidateState.Reserved}));
            reserved[i] = arbitrator;
        }
        snapshotState[disputeId] = SnapshotState.Reserved;

        emit CandidatesReserved(disputeId, reserved);
    }

    /// @notice Locks the three candidates chosen by `PanelSelection` from `seed` and releases every other reservation.
    /// @dev The seed is supplied by the court; the registry does not fetch or schedule randomness.
    function selectPanel(uint256 disputeId, bytes32 seed)
        external
        nonReentrant
        returns (uint256[3] memory candidateIndexes, address[3] memory panel)
    {
        _requireCourt();
        _requireSnapshotState(disputeId, SnapshotState.Reserved);

        Candidate[] storage candidates = _candidates[disputeId];
        uint256 candidateCount = candidates.length;
        candidateIndexes = PanelSelection.selectIndexes(seed, candidateCount);

        for (uint256 i; i < candidateCount; ++i) {
            Candidate storage candidate = candidates[i];
            Ledger storage account = _accounts[candidate.arbitrator];
            account.reserved -= _seatLock;
            if (i == candidateIndexes[0] || i == candidateIndexes[1] || i == candidateIndexes[2]) {
                candidate.state = CandidateState.Locked;
                account.locked += _seatLock;
            } else {
                candidate.state = CandidateState.Unselected;
            }
        }
        for (uint256 j; j < PANEL_SIZE; ++j) {
            panel[j] = candidates[candidateIndexes[j]].arbitrator;
        }
        snapshotState[disputeId] = SnapshotState.Selected;

        emit PanelSelected(disputeId, candidateIndexes);
    }

    /// @notice Releases every reservation of a snapshot that never formed a panel.
    function releaseReservations(uint256 disputeId) external nonReentrant {
        _requireCourt();
        _requireSnapshotState(disputeId, SnapshotState.Reserved);

        Candidate[] storage candidates = _candidates[disputeId];
        uint256 candidateCount = candidates.length;
        for (uint256 i; i < candidateCount; ++i) {
            Candidate storage candidate = candidates[i];
            _accounts[candidate.arbitrator].reserved -= _seatLock;
            candidate.state = CandidateState.Released;
        }
        snapshotState[disputeId] = SnapshotState.Released;

        emit ReservationsReleased(disputeId);
    }

    /// @notice Releases one locked seat and forfeits `penalty` of its stake to the court.
    function releaseSeat(uint256 disputeId, uint256 candidateIndex, uint256 penalty) external nonReentrant {
        _requireCourt();
        Candidate[] storage candidates = _candidates[disputeId];
        if (candidateIndex >= candidates.length || candidates[candidateIndex].state != CandidateState.Locked) {
            revert UnknownSeat(disputeId, candidateIndex);
        }
        if (penalty > seatLock) revert PenaltyTooHigh(penalty, seatLock);

        Candidate storage candidate = candidates[candidateIndex];
        address arbitrator = candidate.arbitrator;
        Ledger storage account = _accounts[arbitrator];
        candidate.state = CandidateState.Released;
        account.locked -= _seatLock;
        account.stake -= SafeCast.toUint128(penalty);
        totalStaked -= penalty;
        penaltiesSent += penalty;
        _delistIfBelowMinimum(arbitrator, account);

        emit SeatReleased(disputeId, arbitrator, penalty);
        if (penalty != 0) stakeToken.safeTransfer(court, penalty);
    }

    function listedCount() external view returns (uint256) {
        return _listed.length;
    }

    function listedAccounts() external view returns (address[] memory) {
        return _listed;
    }

    function accountOf(address arbitrator) external view returns (Account memory) {
        Ledger storage account = _accounts[arbitrator];
        return Account({
            stake: account.stake,
            warming: account.warming,
            locked: account.locked,
            reserved: account.reserved,
            warmingUntil: account.warmingUntil,
            listed: account.listed
        });
    }

    /// @notice Matured stake, including warming stake past its activation time, not backing a reservation or seat.
    function freeStake(address arbitrator) external view returns (uint256) {
        return _free(_accounts[arbitrator]);
    }

    function candidatesOf(uint256 disputeId) external view returns (Candidate[] memory) {
        return _candidates[disputeId];
    }

    function _requireCourt() private view {
        if (msg.sender != court) revert NotCourt(msg.sender);
    }

    function _requireSnapshotState(uint256 disputeId, SnapshotState expected) private view {
        SnapshotState current = snapshotState[disputeId];
        if (current != expected) revert InvalidSnapshotState(disputeId, current);
    }

    function _free(Ledger storage account) private view returns (uint256) {
        uint256 matured = account.warmingUntil <= block.timestamp ? account.warming : 0;
        return uint256(account.stake) + matured - account.locked - account.reserved;
    }

    function _mature(Ledger storage account) private {
        if (account.warming != 0 && account.warmingUntil <= block.timestamp) {
            account.stake += account.warming;
            account.warming = 0;
        }
    }

    function _list(address arbitrator, Ledger storage account) private {
        account.listed = true;
        _listPosition[arbitrator] = _listed.length;
        _listed.push(arbitrator);
        emit Listed(arbitrator);
    }

    function _delistIfBelowMinimum(address arbitrator, Ledger storage account) private {
        if (!account.listed || uint256(account.stake) + account.warming >= seatLock) return;
        uint256 position = _listPosition[arbitrator];
        address last = _listed[_listed.length - 1];
        _listed[position] = last;
        _listPosition[last] = position;
        _listed.pop();
        delete _listPosition[arbitrator];
        account.listed = false;
        emit Delisted(arbitrator);
    }
}
