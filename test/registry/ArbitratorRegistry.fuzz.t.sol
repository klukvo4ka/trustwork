// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {PanelSelection} from "../../src/libraries/PanelSelection.sol";
import {RegistryTestBase} from "../utils/RegistryTestBase.sol";

contract ArbitratorRegistryFuzzTest is RegistryTestBase {
    uint256 internal constant ACTORS = 4;

    struct Model {
        uint256 stake;
        uint256 warming;
        uint256 warmingUntil;
        bool listed;
    }

    Model[ACTORS] internal models;
    address[ACTORS] internal actors;
    uint256 internal modelDeposits;
    uint256 internal modelWithdrawals;
    uint256 internal modelPenalties;
    uint256 internal nextDisputeId;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = _arbitrator(i);
        }
    }

    function testFuzz_MatchesReferenceModel(uint256[] memory operations) public {
        vm.assume(operations.length > 0);
        uint256 steps = operations.length > 24 ? 24 : operations.length;
        for (uint256 i; i < steps; ++i) {
            uint256 operation = operations[i];
            uint256 actorIndex = operation % ACTORS;
            uint256 kind = (operation >> 8) % 4;
            uint256 argument = operation >> 16;
            if (kind == 0) _modelDeposit(actorIndex, bound(argument, 1, 3 * SEAT_LOCK));
            else if (kind == 1) _modelWithdraw(actorIndex, argument);
            else if (kind == 2) vm.warp(block.timestamp + bound(argument, 0, 3 days));
            else _modelPenaltyCycle(argument);
            _assertMatchesModel();
        }
    }

    function testFuzz_PanelComesFromStoredSnapshot(
        uint256 listedCount,
        uint256[32] memory stakes,
        uint256 excludedMask,
        bytes32 seed
    ) public {
        listedCount = bound(listedCount, 3, 32);
        address[] memory arbitrators = new address[](listedCount);
        for (uint256 i; i < listedCount; ++i) {
            arbitrators[i] = _arbitrator(i);
            _deposit(arbitrators[i], bound(stakes[i], SEAT_LOCK, 3 * SEAT_LOCK));
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        address[3] memory excluded;
        uint256 excludedCount;
        for (uint256 i; i < listedCount && excludedCount < 3; ++i) {
            if ((excludedMask >> i) & 1 == 1) excluded[excludedCount++] = arbitrators[i];
        }
        vm.assume(listedCount - excludedCount >= 3);

        uint256 count = court.reserveCandidates(1, excluded);
        assertEq(count, listedCount - excludedCount);
        IArbitratorRegistry.Candidate[] memory candidates = registry.candidatesOf(1);
        uint256 cursor;
        for (uint256 i; i < listedCount; ++i) {
            if (_isExcluded(arbitrators[i], excluded)) continue;
            assertEq(candidates[cursor++].arbitrator, arbitrators[i]);
        }

        (uint256[3] memory indexes, address[3] memory panel) = court.selectPanel(1, seed);
        uint256[3] memory expected = _referenceSelection(seed, count);
        for (uint256 j; j < 3; ++j) {
            assertEq(indexes[j], expected[j]);
            assertEq(panel[j], candidates[indexes[j]].arbitrator);
            assertFalse(_isExcluded(panel[j], excluded));
        }
        assertTrue(panel[0] != panel[1] && panel[1] != panel[2] && panel[0] != panel[2]);
        for (uint256 i; i < listedCount; ++i) {
            IArbitratorRegistry.Account memory account = _account(arbitrators[i]);
            bool onPanel = arbitrators[i] == panel[0] || arbitrators[i] == panel[1] || arbitrators[i] == panel[2];
            assertEq(account.reserved, 0);
            assertEq(account.locked, onPanel ? SEAT_LOCK : 0);
        }
    }

    function testFuzz_SelectionFrequenciesAreNearUniform(bytes32 baseSeed) public pure {
        uint256 draws = 300;
        uint256[5] memory hits;
        for (uint256 k; k < draws; ++k) {
            bytes32 seed = keccak256(abi.encode(baseSeed, k));
            uint256[3] memory chosen = PanelSelection.selectIndexes(seed, 5);
            uint256[3] memory expected = _referenceSelection(seed, 5);
            for (uint256 j; j < 3; ++j) {
                assertEq(chosen[j], expected[j]);
                ++hits[chosen[j]];
            }
        }
        for (uint256 i; i < 5; ++i) {
            assertApproxEqAbs(hits[i], draws * 3 / 5, 60);
        }
    }

    function test_PanelSelection_RevertWhen_FewerThanThreeCandidates() public {
        for (uint256 n; n < 3; ++n) {
            vm.expectRevert(abi.encodeWithSelector(PanelSelection.TooFewCandidates.selector, n));
            this.selectIndexes(bytes32(0), n);
        }
        uint256[3] memory chosen = this.selectIndexes(bytes32(0), 3);
        assertEq(chosen[0] + chosen[1] + chosen[2], 3);
    }

    function selectIndexes(bytes32 seed, uint256 candidateCount) external pure returns (uint256[3] memory) {
        return PanelSelection.selectIndexes(seed, candidateCount);
    }

    function _modelDeposit(uint256 actorIndex, uint256 amount) private {
        address actor = actors[actorIndex];
        Model storage model = models[actorIndex];
        _modelMature(model);
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(registry), amount);
        uint256 principal = model.stake + model.warming + amount;
        if (!model.listed && principal < SEAT_LOCK) {
            vm.expectRevert(
                abi.encodeWithSelector(ArbitratorRegistry.BelowListingMinimum.selector, principal, SEAT_LOCK)
            );
            registry.deposit(amount);
            vm.stopPrank();
            return;
        }
        registry.deposit(amount);
        vm.stopPrank();
        model.warming += amount;
        model.warmingUntil = block.timestamp + ACTIVATION_DELAY;
        model.listed = true;
        modelDeposits += amount;
    }

    function _modelWithdraw(uint256 actorIndex, uint256 argument) private {
        address actor = actors[actorIndex];
        Model storage model = models[actorIndex];
        _modelMature(model);
        uint256 available = model.stake;
        uint256 amount = bound(argument, 1, available + 1);
        if (amount > available) {
            vm.expectRevert(
                abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, amount, available)
            );
            _withdraw(actor, amount);
            return;
        }
        _withdraw(actor, amount);
        model.stake -= amount;
        modelWithdrawals += amount;
        if (model.stake + model.warming < SEAT_LOCK) model.listed = false;
    }

    function _modelPenaltyCycle(uint256 argument) private {
        uint256 eligible;
        for (uint256 i; i < ACTORS; ++i) {
            if (models[i].listed && _modelFree(models[i]) >= SEAT_LOCK) ++eligible;
        }
        uint256 disputeId = ++nextDisputeId;
        uint256 count = _reserve(disputeId);
        assertEq(count, eligible);
        if (count < 3) {
            assertEq(uint256(registry.snapshotState(disputeId)), uint256(IArbitratorRegistry.SnapshotState.None));
            return;
        }
        for (uint256 i; i < ACTORS; ++i) {
            if (models[i].listed && _modelFree(models[i]) >= SEAT_LOCK) _modelMature(models[i]);
        }
        (uint256[3] memory indexes, address[3] memory panel) = court.selectPanel(disputeId, bytes32(argument));
        for (uint256 j; j < 3; ++j) {
            uint256 penalty = bound(uint256(keccak256(abi.encode(argument, j))), 0, SEAT_LOCK);
            court.releaseSeat(disputeId, indexes[j], penalty);
            Model storage model = models[_actorIndex(panel[j])];
            model.stake -= penalty;
            modelPenalties += penalty;
            if (model.stake + model.warming < SEAT_LOCK) model.listed = false;
        }
    }

    function _assertMatchesModel() private view {
        uint256 total;
        uint256 listed;
        for (uint256 i; i < ACTORS; ++i) {
            Model memory model = models[i];
            IArbitratorRegistry.Account memory account = _account(actors[i]);
            bool modelMatured = model.warmingUntil <= block.timestamp;
            bool accountMatured = account.warmingUntil <= block.timestamp;
            uint256 modelEffectiveStake = model.stake + (modelMatured ? model.warming : 0);
            uint256 accountEffectiveStake = account.stake + (accountMatured ? account.warming : 0);
            assertEq(accountEffectiveStake, modelEffectiveStake);
            assertEq(account.stake + account.warming, model.stake + model.warming);
            assertEq(account.listed, model.listed);
            assertEq(account.locked, 0);
            assertEq(account.reserved, 0);
            total += model.stake + model.warming;
            if (model.listed) ++listed;
        }
        assertEq(registry.totalStaked(), total);
        assertEq(registry.depositsReceived(), modelDeposits);
        assertEq(registry.withdrawalsPaid(), modelWithdrawals);
        assertEq(registry.penaltiesSent(), modelPenalties);
        assertEq(registry.listedCount(), listed);
        assertEq(token.balanceOf(address(court)), modelPenalties);
    }

    function _modelMature(Model storage model) private {
        if (model.warming != 0 && model.warmingUntil <= block.timestamp) {
            model.stake += model.warming;
            model.warming = 0;
        }
    }

    function _modelFree(Model storage model) private view returns (uint256) {
        return model.stake + (model.warmingUntil <= block.timestamp ? model.warming : 0);
    }

    function _actorIndex(address account) private view returns (uint256) {
        for (uint256 i; i < ACTORS; ++i) {
            if (actors[i] == account) return i;
        }
        revert("unknown actor");
    }

    function _isExcluded(address account, address[3] memory excluded) private pure returns (bool) {
        return account == excluded[0] || account == excluded[1] || account == excluded[2];
    }
}
