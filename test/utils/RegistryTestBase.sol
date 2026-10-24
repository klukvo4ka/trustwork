// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {RegistryCourtHarness} from "../mocks/RegistryCourtHarness.sol";

abstract contract RegistryTestBase is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant SEAT_LOCK = 100 * USDC;
    uint256 internal constant ACTIVATION_DELAY = 2 days;
    uint256 internal constant START = 1_700_000_000;

    address internal penaltyRecipient = makeAddr("penaltyRecipient");
    address internal client = makeAddr("client");
    address internal freelancer = makeAddr("freelancer");
    address internal feeRecipient = makeAddr("feeRecipient");

    MockUSDC internal token;
    RegistryCourtHarness internal court;
    ArbitratorRegistry internal registry;

    function setUp() public virtual {
        vm.warp(START);
        token = new MockUSDC();
        court = new RegistryCourtHarness(token, SEAT_LOCK, penaltyRecipient);
        registry = court.registry();
    }

    function _arbitrator(uint256 i) internal returns (address) {
        return makeAddr(string.concat("arbitrator", vm.toString(i)));
    }

    function _deposit(address arbitrator, uint256 amount) internal {
        _depositTo(registry, token, arbitrator, amount);
    }

    function _depositTo(ArbitratorRegistry target, MockUSDC stakeToken, address arbitrator, uint256 amount) internal {
        stakeToken.mint(arbitrator, amount);
        vm.startPrank(arbitrator);
        stakeToken.approve(address(target), amount);
        target.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Deposits `amount` for each of `count` arbitrators and waits for activation.
    function _activeArbitrators(uint256 count, uint256 amount) internal returns (address[] memory arbitrators) {
        arbitrators = new address[](count);
        for (uint256 i; i < count; ++i) {
            arbitrators[i] = _arbitrator(i);
            _deposit(arbitrators[i], amount);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
    }

    function _parties() internal view returns (address[3] memory) {
        return [client, freelancer, feeRecipient];
    }

    function _reserve(uint256 disputeId) internal returns (uint256) {
        return court.reserveCandidates(disputeId, _parties());
    }

    function _withdraw(address arbitrator, uint256 amount) internal {
        vm.prank(arbitrator);
        registry.withdraw(amount);
    }

    function _account(address arbitrator) internal view returns (IArbitratorRegistry.Account memory) {
        return registry.accountOf(arbitrator);
    }

    function _candidateAddresses(uint256 disputeId) internal view returns (address[] memory addresses) {
        IArbitratorRegistry.Candidate[] memory candidates = registry.candidatesOf(disputeId);
        addresses = new address[](candidates.length);
        for (uint256 i; i < candidates.length; ++i) {
            addresses[i] = candidates[i].arbitrator;
        }
    }

    function _candidateState(uint256 disputeId, uint256 index)
        internal
        view
        returns (IArbitratorRegistry.CandidateState)
    {
        return registry.candidatesOf(disputeId)[index].state;
    }

    /// @dev Independent reimplementation of the design's partial Fisher–Yates selection (design section 7.3).
    function _referenceSelection(bytes32 seed, uint256 candidateCount)
        internal
        pure
        returns (uint256[3] memory chosen)
    {
        uint256[] memory order = new uint256[](candidateCount);
        for (uint256 i; i < candidateCount; ++i) {
            order[i] = i;
        }
        for (uint256 j; j < 3; ++j) {
            uint256 remaining = candidateCount - j;
            uint256 pick = j + uint256(keccak256(abi.encode(seed, j))) % remaining;
            uint256 swapped = order[pick];
            order[pick] = order[j];
            order[j] = swapped;
            chosen[j] = swapped;
        }
    }

    /// @dev First seed `keccak256(salt, k)` whose reference selection includes candidate `index`.
    function _seedSelecting(uint256 index, uint256 candidateCount, bool wantSelected) internal pure returns (bytes32) {
        for (uint256 k; k < 1000; ++k) {
            bytes32 seed = keccak256(abi.encode("seed", k));
            uint256[3] memory chosen = _referenceSelection(seed, candidateCount);
            bool selected = chosen[0] == index || chosen[1] == index || chosen[2] == index;
            if (selected == wantSelected) return seed;
        }
        revert("no seed found");
    }
}
