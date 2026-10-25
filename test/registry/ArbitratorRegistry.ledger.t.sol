// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {RegistryTestBase} from "../utils/RegistryTestBase.sol";

/// @dev Accounts that hold matured stake and warming stake at the same time, which the stored principal must keep
/// apart: only matured stake backs reservations, seats, withdrawals and penalties.
contract ArbitratorRegistryLedgerTest is RegistryTestBase {
    uint256 internal constant MAX = type(uint128).max;

    function test_MixedBuckets_OnlyMaturedStakeBacksCommitments() public {
        address mixed = _arbitrator(0);
        _activeArbitrators(3, SEAT_LOCK);
        uint256 warmingUntil = block.timestamp + ACTIVATION_DELAY;
        _deposit(mixed, 2 * SEAT_LOCK);
        _assertBuckets(mixed, SEAT_LOCK, 2 * SEAT_LOCK, 0, 0);
        assertEq(_account(mixed).warmingUntil, warmingUntil);
        assertEq(registry.freeStake(mixed), SEAT_LOCK);

        assertEq(_reserve(1), 3);
        _assertBuckets(mixed, SEAT_LOCK, 2 * SEAT_LOCK, 0, SEAT_LOCK);
        assertEq(registry.freeStake(mixed), 0);
        _expectInsufficient(mixed, 1, 0);

        court.selectPanel(1, keccak256("seed"));
        _assertBuckets(mixed, SEAT_LOCK, 2 * SEAT_LOCK, SEAT_LOCK, 0);
        court.releaseSeat(1, 0, SEAT_LOCK);
        _assertBuckets(mixed, 0, 2 * SEAT_LOCK, 0, 0);
        assertTrue(_account(mixed).listed);
        assertEq(registry.totalStaked(), 4 * SEAT_LOCK);
        assertEq(registry.freeStake(mixed), 0);
        _expectInsufficient(mixed, 1, 0);

        vm.warp(warmingUntil);
        assertEq(registry.freeStake(mixed), 2 * SEAT_LOCK);
        _assertBuckets(mixed, 0, 2 * SEAT_LOCK, 0, 0);
        _withdraw(mixed, SEAT_LOCK);
        _assertBuckets(mixed, SEAT_LOCK, 0, 0, 0);
        assertTrue(_account(mixed).listed);
        assertEq(registry.totalStaked(), 3 * SEAT_LOCK);
    }

    function test_ConcurrentCommitments_StayCollateralizedAcrossTopUps() public {
        address arbitrator = _arbitrator(0);
        _activeArbitrators(4, 2 * SEAT_LOCK);
        _reserve(1);
        _reserve(2);
        _assertBuckets(arbitrator, 2 * SEAT_LOCK, 0, 0, 2 * SEAT_LOCK);
        _deposit(arbitrator, 3 * SEAT_LOCK);
        assertEq(registry.freeStake(arbitrator), 0);
        _expectInsufficient(arbitrator, 1, 0);

        vm.warp(block.timestamp + ACTIVATION_DELAY);
        assertEq(registry.freeStake(arbitrator), 3 * SEAT_LOCK);
        assertEq(_reserve(3), 1);
        assertEq(registry.candidatesOf(3).length, 0);
        _assertBuckets(arbitrator, 2 * SEAT_LOCK, 3 * SEAT_LOCK, 0, 2 * SEAT_LOCK);

        court.selectPanel(1, _seedSelecting(0, 4, true));
        court.releaseReservations(2);
        _assertBuckets(arbitrator, 2 * SEAT_LOCK, 3 * SEAT_LOCK, SEAT_LOCK, 0);
        court.releaseSeat(1, 0, SEAT_LOCK);
        _assertBuckets(arbitrator, SEAT_LOCK, 3 * SEAT_LOCK, 0, 0);
        assertEq(registry.freeStake(arbitrator), 4 * SEAT_LOCK);

        uint256 total;
        for (uint256 i; i < 4; ++i) {
            IArbitratorRegistry.Account memory account = _account(_arbitrator(i));
            assertLe(account.locked + account.reserved, account.stake);
            total += account.stake + account.warming;
        }
        assertEq(registry.totalStaked(), total);
        assertEq(registry.penaltiesSent(), SEAT_LOCK);
    }

    function test_NearLimitMixedAccount_PenaltyRestoresOnlyItsCapacity() public {
        address whale = _arbitrator(0);
        _deposit(whale, MAX - SEAT_LOCK);
        _deposit(_arbitrator(1), SEAT_LOCK);
        _deposit(_arbitrator(2), SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _deposit(whale, SEAT_LOCK);
        _assertBuckets(whale, MAX - SEAT_LOCK, SEAT_LOCK, 0, 0);
        _expectLimit(whale, 1, 0);

        assertEq(_reserve(1), 3);
        court.selectPanel(1, keccak256("seed"));
        court.releaseSeat(1, 0, SEAT_LOCK);
        _assertBuckets(whale, MAX - 2 * SEAT_LOCK, SEAT_LOCK, 0, 0);
        _expectLimit(whale, SEAT_LOCK + 1, SEAT_LOCK);
        _deposit(whale, SEAT_LOCK);
        _assertBuckets(whale, MAX - 2 * SEAT_LOCK, 2 * SEAT_LOCK, 0, 0);
        _expectLimit(whale, 1, 0);

        vm.warp(block.timestamp + ACTIVATION_DELAY);
        assertEq(registry.freeStake(whale), MAX);
        _withdraw(whale, MAX);
        _assertBuckets(whale, 0, 0, 0, 0);
        assertFalse(_account(whale).listed);
        assertEq(registry.totalStaked(), 2 * SEAT_LOCK);
    }

    function test_FailedSnapshot_LeavesMaturedWarmingUnwritten() public {
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, SEAT_LOCK);
        _deposit(_arbitrator(1), SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        assertEq(_reserve(1), 2);
        _assertBuckets(arbitrator, 0, SEAT_LOCK, 0, 0);
        assertEq(registry.freeStake(arbitrator), SEAT_LOCK);

        _deposit(_arbitrator(2), SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        assertEq(_reserve(1), 3);
        _assertBuckets(arbitrator, SEAT_LOCK, 0, 0, SEAT_LOCK);
    }

    function _assertBuckets(address arbitrator, uint256 stake, uint256 warming, uint256 locked, uint256 reserved)
        private
        view
    {
        IArbitratorRegistry.Account memory account = _account(arbitrator);
        assertEq(account.stake, stake, "stake");
        assertEq(account.warming, warming, "warming");
        assertEq(account.locked, locked, "locked");
        assertEq(account.reserved, reserved, "reserved");
    }

    function _expectInsufficient(address arbitrator, uint256 amount, uint256 available) private {
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, amount, available));
        vm.prank(arbitrator);
        registry.withdraw(amount);
    }

    function _expectLimit(address depositor, uint256 amount, uint256 capacity) private {
        token.mint(depositor, amount);
        vm.startPrank(depositor);
        token.approve(address(registry), amount);
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.PrincipalLimitExceeded.selector, amount, capacity));
        registry.deposit(amount);
        vm.stopPrank();
    }
}
