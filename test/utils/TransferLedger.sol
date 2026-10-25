// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Observes every ERC-20 `Transfer` of the payment and stake tokens during one protocol action, requires the
/// observed transfers to equal the edges the caller's own model expects for that action's transition (design §11.4),
/// and keeps an independent per-contract, per-token ledger of liabilities and unsolicited balance.
contract TransferLedger is Test {
    enum Transition {
        Fund,
        Settle,
        OrderClaim,
        DisputeFee,
        Stake,
        Unstake,
        Penalty,
        CourtClaim,
        Donation
    }

    struct Edge {
        address from;
        address to;
        uint256 amount;
    }

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    IERC20 public immutable paymentToken;
    IERC20 public immutable stakeToken;
    address public immutable court;
    address public immutable registry;

    mapping(address account => bool) public isOrder;
    address[] private _contracts;
    mapping(address account => mapping(address token => uint256)) public liability;
    mapping(address account => mapping(address token => uint256)) public unsolicited;
    mapping(Transition transition => uint256) public observed;
    bool private _recording;

    constructor(IERC20 paymentToken_, IERC20 stakeToken_, address court_, address registry_) {
        paymentToken = paymentToken_;
        stakeToken = stakeToken_;
        court = court_;
        registry = registry_;
        _contracts.push(court_);
        _contracts.push(registry_);
    }

    function trackOrder(address order) external {
        if (isOrder[order]) return;
        isOrder[order] = true;
        _contracts.push(order);
    }

    function begin() external {
        require(!_recording, "ledger already recording");
        _recording = true;
        vm.recordLogs();
    }

    /// @dev Ends the observation window started by `begin`, requires the observed transfers to equal `expected` as a
    /// multiset, and books them under `transition`.
    function end(Transition transition, Edge[] memory expected) external {
        require(_recording, "ledger not recording");
        _recording = false;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool[] memory matched = new bool[](expected.length);
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length != 3 || entry.topics[0] != TRANSFER_TOPIC) continue;
            address token = entry.emitter;
            if (token != address(paymentToken) && token != address(stakeToken)) continue;
            address from = address(uint160(uint256(entry.topics[1])));
            address to = address(uint160(uint256(entry.topics[2])));
            uint256 amount = abi.decode(entry.data, (uint256));
            ++transfers;
            bool found;
            for (uint256 j; j < expected.length; ++j) {
                if (matched[j]) continue;
                Edge memory edge = expected[j];
                if (edge.from == from && edge.to == to && edge.amount == amount) {
                    matched[j] = true;
                    found = true;
                    break;
                }
            }
            assertTrue(found, "transfer not produced by the authorized transition");
            _book(transition, token, from, to, amount);
        }
        assertEq(transfers, expected.length, "authorized transfer missing");
        ++observed[transition];
    }

    /// @dev Each protocol contract's balance equals its booked liabilities plus unsolicited transfers, per token.
    function assertBalances() external view {
        for (uint256 i; i < _contracts.length; ++i) {
            address account = _contracts[i];
            _assertBalance(account, address(paymentToken));
            if (address(stakeToken) != address(paymentToken)) _assertBalance(account, address(stakeToken));
        }
    }

    function _assertBalance(address account, address token) private view {
        assertEq(
            IERC20(token).balanceOf(account),
            liability[account][token] + unsolicited[account][token],
            "balance differs from liabilities plus unsolicited transfers"
        );
    }

    function _book(Transition transition, address token, address from, address to, uint256 amount) private {
        if (transition == Transition.Fund) {
            assertTrue(isOrder[to] && token == address(paymentToken), "funding must reach an order");
            liability[to][token] += amount;
        } else if (transition == Transition.Settle || transition == Transition.OrderClaim) {
            assertTrue(isOrder[from] && token == address(paymentToken), "order payout must leave an order");
            liability[from][token] -= amount;
            _receiveUnsolicited(to, token, amount);
        } else if (transition == Transition.DisputeFee) {
            assertTrue(to == court && token == address(stakeToken), "dispute fee must reach the court");
            liability[to][token] += amount;
        } else if (transition == Transition.Stake) {
            assertTrue(to == registry && token == address(stakeToken), "stake must reach the registry");
            liability[to][token] += amount;
        } else if (transition == Transition.Unstake) {
            assertTrue(from == registry && token == address(stakeToken), "withdrawal must leave the registry");
            liability[from][token] -= amount;
            _receiveUnsolicited(to, token, amount);
        } else if (transition == Transition.Penalty) {
            assertTrue(from == registry && to == court && token == address(stakeToken), "penalty is registry to court");
            liability[from][token] -= amount;
            liability[to][token] += amount;
        } else if (transition == Transition.CourtClaim) {
            assertTrue(from == court && token == address(stakeToken), "court payout must leave the court");
            liability[from][token] -= amount;
            _receiveUnsolicited(to, token, amount);
        } else {
            _receiveUnsolicited(to, token, amount);
        }
    }

    function _receiveUnsolicited(address to, address token, uint256 amount) private {
        if (isOrder[to] || to == court || to == registry) unsolicited[to][token] += amount;
    }
}
