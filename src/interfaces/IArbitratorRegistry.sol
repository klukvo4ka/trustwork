// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IArbitratorRegistry
/// @notice Stake ledger and per-dispute candidate snapshots used by the arbitration court.
interface IArbitratorRegistry {
    enum CandidateState {
        None,
        Reserved,
        Unselected,
        Locked,
        Released
    }

    enum SnapshotState {
        None,
        Reserved,
        Selected,
        Released
    }

    struct Account {
        uint256 stake;
        uint256 warming;
        uint256 locked;
        uint256 reserved;
        uint64 warmingUntil;
        bool listed;
    }

    struct Candidate {
        address arbitrator;
        CandidateState state;
    }

    event Deposited(address indexed arbitrator, uint256 amount, uint256 warmingUntil);
    event Withdrawn(address indexed arbitrator, uint256 amount);
    event Listed(address indexed arbitrator);
    event Delisted(address indexed arbitrator);
    event CandidatesReserved(uint256 indexed disputeId, address[] candidates);
    event PanelSelected(uint256 indexed disputeId, uint256[3] candidateIndexes);
    event ReservationsReleased(uint256 indexed disputeId);
    event SeatReleased(uint256 indexed disputeId, address indexed arbitrator, uint256 penalty);

    function stakeToken() external view returns (IERC20);
    function court() external view returns (address);
    function seatLock() external view returns (uint256);
    function penaltyRecipient() external view returns (address);
    function totalStaked() external view returns (uint256);
    function depositsReceived() external view returns (uint256);
    function withdrawalsPaid() external view returns (uint256);
    function penaltiesSent() external view returns (uint256);
    function listedCount() external view returns (uint256);
    function listedAccounts() external view returns (address[] memory);
    function accountOf(address arbitrator) external view returns (Account memory);
    function freeStake(address arbitrator) external view returns (uint256);
    function candidatesOf(uint256 disputeId) external view returns (Candidate[] memory);
    function snapshotState(uint256 disputeId) external view returns (SnapshotState);

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;

    function reserveCandidates(uint256 disputeId, address[3] calldata excluded) external returns (uint256 count);
    function selectPanel(uint256 disputeId, bytes32 seed)
        external
        returns (uint256[3] memory candidateIndexes, address[3] memory panel);
    function releaseReservations(uint256 disputeId) external;
    function releaseSeat(uint256 disputeId, uint256 candidateIndex, uint256 penalty) external;
}
