// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {RegistryTestBase} from "../utils/RegistryTestBase.sol";

/// @dev Per-account principal bound: `stake + warming <= type(uint128).max`.
contract ArbitratorRegistryPrincipalTest is RegistryTestBase {
    uint256 internal constant MAX = type(uint128).max;

    function test_MaxPrincipalConstant() public view {
        assertEq(registry.MAX_PRINCIPAL(), MAX);
    }

    function test_PrincipalAtLimit_MaturesAndWithdraws() public {
        address whale = _arbitrator(0);
        _deposit(whale, MAX);
        _deposit(_arbitrator(1), SEAT_LOCK);
        _deposit(_arbitrator(2), SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        assertEq(registry.freeStake(whale), MAX);
        assertEq(_reserve(1), 3);
        assertEq(_account(whale).stake, MAX);
        assertEq(_account(whale).warming, 0);
        court.releaseReservations(1);

        _withdraw(whale, MAX);
        assertEq(token.balanceOf(whale), MAX);
        assertEq(_account(whale).stake, 0);
        assertFalse(_account(whale).listed);
        assertEq(registry.totalStaked(), 2 * SEAT_LOCK);
    }

    function test_RevertWhen_TopUpAtMaturedLimit() public {
        address whale = _arbitrator(0);
        _deposit(whale, MAX);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _mint(whale, 1);

        _expectLimit(whale, 1, 0);

        assertEq(_account(whale).stake + _account(whale).warming, MAX);
        assertEq(registry.freeStake(whale), MAX);
    }

    function test_MixedPrincipal_ExactCapacitySucceedsAndOneMoreFails() public {
        address arbitrator = _arbitrator(0);
        uint256 matured = 2 ** 127;
        uint256 warming = 2 ** 126 + 12_345;
        _deposit(arbitrator, matured);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _deposit(arbitrator, warming);
        assertEq(_account(arbitrator).stake, matured);
        assertEq(_account(arbitrator).warming, warming);
        uint256 capacity = MAX - matured - warming;
        _mint(arbitrator, capacity + 1);

        _expectLimit(arbitrator, capacity + 1, capacity);
        vm.prank(arbitrator);
        registry.deposit(capacity);

        IArbitratorRegistry.Account memory account = _account(arbitrator);
        assertEq(account.stake, matured);
        assertEq(account.warming, warming + capacity);
        assertEq(uint256(account.stake) + account.warming, MAX);
        _expectLimit(arbitrator, 1, 0);
    }

    function test_RepeatedTopUpsCannotBypassLimit() public {
        address arbitrator = _arbitrator(0);
        uint256 half = MAX / 2;
        _deposit(arbitrator, half);
        vm.warp(block.timestamp + 1 days);
        _deposit(arbitrator, half);
        _deposit(arbitrator, 1);
        assertEq(_account(arbitrator).warming, MAX);
        _mint(arbitrator, 2);

        _expectLimit(arbitrator, 1, 0);
        vm.warp(_account(arbitrator).warmingUntil - 1);
        _expectLimit(arbitrator, 1, 0);
        vm.warp(_account(arbitrator).warmingUntil);
        _expectLimit(arbitrator, 1, 0);
        _expectLimit(arbitrator, 2, 0);

        _withdraw(arbitrator, 5);
        assertEq(_account(arbitrator).stake, MAX - 5);
        vm.prank(arbitrator);
        registry.deposit(2);
        _expectLimit(arbitrator, 4, 3);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _expectLimit(arbitrator, 4, 3);
        vm.prank(arbitrator);
        registry.deposit(3);
        assertEq(uint256(_account(arbitrator).stake) + _account(arbitrator).warming, MAX);
    }

    function test_RevertWhen_DepositOversized() public {
        address newcomer = _arbitrator(0);
        vm.startPrank(newcomer);
        token.approve(address(registry), type(uint256).max);
        vm.stopPrank();

        uint256[4] memory amounts = [type(uint256).max, 2 ** 255, MAX + 1, 2 ** 200];
        for (uint256 i; i < amounts.length; ++i) {
            _expectLimit(newcomer, amounts[i], MAX);
        }

        _deposit(newcomer, SEAT_LOCK);
        _expectLimit(newcomer, type(uint256).max, MAX - SEAT_LOCK);
        _expectLimit(newcomer, MAX, MAX - SEAT_LOCK);
        assertFalse(_account(_arbitrator(9)).listed);
    }

    function test_RejectedDeposit_PreservesAllState() public {
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, MAX - 7);
        _deposit(_arbitrator(1), SEAT_LOCK);
        _deposit(_arbitrator(2), 2 * SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _mint(arbitrator, 1000);
        address stranger = _arbitrator(30);
        vm.prank(stranger);
        token.approve(address(registry), type(uint256).max);

        IArbitratorRegistry.Account memory accountBefore = _account(arbitrator);
        address[] memory listedBefore = registry.listedAccounts();
        uint256[6] memory before = _globals(arbitrator);
        uint256 allowanceBefore = token.allowance(arbitrator, address(registry));
        assertEq(accountBefore.warming, MAX - 7);
        assertEq(accountBefore.stake, 0);

        _expectLimit(arbitrator, 8, 7);
        _expectLimit(arbitrator, type(uint256).max, 7);
        _expectLimit(stranger, type(uint256).max, MAX);

        IArbitratorRegistry.Account memory accountAfter = _account(arbitrator);
        assertEq(accountAfter.stake, accountBefore.stake);
        assertEq(accountAfter.warming, accountBefore.warming);
        assertEq(accountAfter.warmingUntil, accountBefore.warmingUntil);
        assertEq(accountAfter.locked, accountBefore.locked);
        assertEq(accountAfter.reserved, accountBefore.reserved);
        assertEq(accountAfter.listed, accountBefore.listed);
        address[] memory listedAfter = registry.listedAccounts();
        assertEq(listedAfter.length, listedBefore.length);
        for (uint256 i; i < listedBefore.length; ++i) {
            assertEq(listedAfter[i], listedBefore[i]);
        }
        uint256[6] memory afterRejection = _globals(arbitrator);
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterRejection[i], before[i]);
        }
        assertEq(token.allowance(arbitrator, address(registry)), allowanceBefore);
        assertFalse(_account(stranger).listed);
    }

    function test_AfterRejectedTopUp_WithdrawalsAndSnapshotsSucceed() public {
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, MAX);
        address[] memory peers = new address[](3);
        for (uint256 i; i < 3; ++i) {
            peers[i] = _arbitrator(i + 1);
            _deposit(peers[i], 2 * SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _mint(arbitrator, 1);
        _expectLimit(arbitrator, 1, 0);

        assertEq(_reserve(1), 4);
        address[] memory candidates = _candidateAddresses(1);
        assertEq(candidates[0], arbitrator);
        for (uint256 i; i < 3; ++i) {
            assertEq(candidates[i + 1], peers[i]);
        }
        (uint256[3] memory chosen,) = court.selectPanel(1, keccak256("after rejection"));
        for (uint256 j; j < 3; ++j) {
            court.releaseSeat(1, chosen[j], 0);
        }

        _withdraw(arbitrator, MAX - SEAT_LOCK);
        _withdraw(peers[0], SEAT_LOCK);
        assertEq(_reserve(2), 4);
        assertEq(token.balanceOf(arbitrator), MAX - SEAT_LOCK + 1);
        assertEq(
            registry.depositsReceived(), registry.withdrawalsPaid() + registry.penaltiesSent() + registry.totalStaked()
        );
    }

    function testFuzz_DepositSequenceStaysWithinLimit(
        uint256[6] memory rawAmounts,
        uint256[6] memory gaps,
        uint256 modes
    ) public {
        address arbitrator = _arbitrator(0);
        vm.prank(arbitrator);
        token.approve(address(registry), type(uint256).max);
        uint256 modelPrincipal;
        bool modelListed;
        uint256 accepted;

        for (uint256 i; i < rawAmounts.length; ++i) {
            vm.warp(block.timestamp + bound(gaps[i], 0, 3 days));
            uint256 capacity = MAX - modelPrincipal;
            uint256 amount = _boundaryAmount(rawAmounts[i], (modes >> (2 * i)) % 4, capacity);
            if (amount > capacity) {
                _expectLimit(arbitrator, amount, capacity);
            } else if (!modelListed && modelPrincipal + amount < SEAT_LOCK) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        ArbitratorRegistry.BelowListingMinimum.selector, modelPrincipal + amount, SEAT_LOCK
                    )
                );
                vm.prank(arbitrator);
                registry.deposit(amount);
            } else {
                token.mint(arbitrator, amount);
                vm.prank(arbitrator);
                registry.deposit(amount);
                modelPrincipal += amount;
                modelListed = true;
                ++accepted;
            }
            IArbitratorRegistry.Account memory account = _account(arbitrator);
            assertEq(uint256(account.stake) + account.warming, modelPrincipal);
            assertLe(uint256(account.stake) + account.warming, MAX);
            assertEq(account.listed, modelListed);
            assertEq(registry.totalStaked(), modelPrincipal);
        }

        vm.warp(block.timestamp + ACTIVATION_DELAY);
        assertEq(registry.freeStake(arbitrator), modelPrincipal);
        if (modelPrincipal != 0) {
            _withdraw(arbitrator, modelPrincipal);
            assertEq(token.balanceOf(arbitrator), modelPrincipal);
        }
        assertEq(registry.totalStaked(), 0);
        assertLe(accepted, rawAmounts.length);
    }

    function testFuzz_OversizedDepositRejectedWithoutChanges(uint256 existing, uint256 firstShare, uint256 amount)
        public
    {
        existing = bound(existing, SEAT_LOCK, MAX);
        uint256 first = bound(firstShare, SEAT_LOCK, existing);
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, first);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        if (existing > first) _deposit(arbitrator, existing - first);
        uint256 capacity = MAX - existing;
        amount = bound(amount, capacity + 1, type(uint256).max);
        _mint(arbitrator, 0);
        IArbitratorRegistry.Account memory before = _account(arbitrator);
        uint256 balance = token.balanceOf(address(registry));

        _expectLimit(arbitrator, amount, capacity);

        IArbitratorRegistry.Account memory afterRejection = _account(arbitrator);
        assertEq(afterRejection.stake, before.stake);
        assertEq(afterRejection.warming, before.warming);
        assertEq(afterRejection.warmingUntil, before.warmingUntil);
        assertEq(registry.totalStaked(), existing);
        assertEq(registry.depositsReceived(), existing);
        assertEq(token.balanceOf(address(registry)), balance);
    }

    function testFuzz_NearLimitAccountStaysUsable(uint256 principal, uint256 firstShare, bytes32 seed) public {
        principal = bound(principal, MAX - 3 * SEAT_LOCK, MAX);
        uint256 first = bound(firstShare, SEAT_LOCK, principal);
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, first);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        if (principal > first) _deposit(arbitrator, principal - first);
        for (uint256 i = 1; i <= 3; ++i) {
            _deposit(_arbitrator(i), SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        assertEq(_reserve(1), 4);
        assertEq(_account(arbitrator).stake, principal);
        (uint256[3] memory chosen,) = court.selectPanel(1, seed);
        for (uint256 j; j < 3; ++j) {
            court.releaseSeat(1, chosen[j], SEAT_LOCK);
        }

        uint256 remaining = _account(arbitrator).stake;
        assertGe(remaining, principal - SEAT_LOCK);
        _withdraw(arbitrator, remaining);
        assertEq(_account(arbitrator).stake, 0);
        assertEq(
            registry.depositsReceived(), registry.withdrawalsPaid() + registry.penaltiesSent() + registry.totalStaked()
        );
    }

    function _boundaryAmount(uint256 raw, uint256 mode, uint256 capacity) private pure returns (uint256) {
        if (mode == 0) {
            uint256 offset = raw % 5;
            if (capacity + offset <= 2) return 1;
            return capacity + offset - 2;
        }
        if (mode == 1) return bound(raw, 1, MAX);
        if (mode == 2) return raw == 0 ? 1 : raw;
        return bound(raw, 1, 3 * SEAT_LOCK);
    }

    function _expectLimit(address depositor, uint256 amount, uint256 capacity) private {
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.PrincipalLimitExceeded.selector, amount, capacity));
        vm.prank(depositor);
        registry.deposit(amount);
    }

    function _mint(address account, uint256 amount) private {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(registry), type(uint256).max);
    }

    function _globals(address arbitrator) private view returns (uint256[6] memory values) {
        values = [
            registry.totalStaked(),
            registry.depositsReceived(),
            registry.withdrawalsPaid(),
            registry.listedCount(),
            token.balanceOf(address(registry)),
            token.balanceOf(arbitrator)
        ];
    }
}
