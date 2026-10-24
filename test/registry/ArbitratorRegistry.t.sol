// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {IArbitratorRegistry} from "../../src/interfaces/IArbitratorRegistry.sol";
import {RegistryTestBase} from "../utils/RegistryTestBase.sol";
import {BlocklistToken} from "../mocks/BlocklistToken.sol";
import {FeeOnTransferToken} from "../mocks/FeeOnTransferToken.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {RegistryCourtHarness} from "../mocks/RegistryCourtHarness.sol";

contract ArbitratorRegistryTest is RegistryTestBase {
    event Deposited(address indexed arbitrator, uint256 amount, uint256 warmingUntil);
    event Withdrawn(address indexed arbitrator, uint256 amount);
    event Listed(address indexed arbitrator);
    event Delisted(address indexed arbitrator);
    event CandidatesReserved(uint256 indexed disputeId, address[] candidates);
    event PanelSelected(uint256 indexed disputeId, uint256[3] candidateIndexes);
    event ReservationsReleased(uint256 indexed disputeId);
    event SeatReleased(uint256 indexed disputeId, address indexed arbitrator, uint256 penalty);

    function test_Constructor_StoresTermsAndDeployerIsCourt() public view {
        assertEq(registry.court(), address(court));
        assertEq(address(registry.stakeToken()), address(token));
        assertEq(registry.seatLock(), SEAT_LOCK);
        assertEq(registry.penaltyRecipient(), penaltyRecipient);
        assertEq(registry.ACTIVATION_DELAY(), 2 days);
        assertEq(registry.MAX_ARBITRATORS(), 32);
        assertEq(registry.PANEL_SIZE(), 3);
    }

    function test_RevertWhen_ConstructorInputsInvalid() public {
        vm.expectRevert(ArbitratorRegistry.ZeroAddress.selector);
        new ArbitratorRegistry(IERC20(address(0)), SEAT_LOCK, penaltyRecipient);

        vm.expectRevert(ArbitratorRegistry.ZeroAddress.selector);
        new ArbitratorRegistry(token, SEAT_LOCK, address(0));

        address eoa = makeAddr("notAToken");
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.TokenHasNoCode.selector, eoa));
        new ArbitratorRegistry(IERC20(eoa), SEAT_LOCK, penaltyRecipient);

        vm.expectRevert(ArbitratorRegistry.ZeroSeatLock.selector);
        new ArbitratorRegistry(token, 0, penaltyRecipient);
    }

    function test_RevertWhen_SeatLockExceedsUint128() public {
        uint256 tooLarge = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooLarge));
        new ArbitratorRegistry(token, tooLarge, penaltyRecipient);
    }

    function test_RevertWhen_PenaltyRecipientIsCourt() public {
        address predictedHarness = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(
            abi.encodeWithSelector(ArbitratorRegistry.PenaltyRecipientIsProtocol.selector, predictedHarness)
        );
        new RegistryCourtHarness(token, SEAT_LOCK, predictedHarness);
    }

    function test_RevertWhen_PenaltyRecipientIsRegistry() public {
        address predictedHarness = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedRegistry = vm.computeCreateAddress(predictedHarness, 1);

        vm.expectRevert(
            abi.encodeWithSelector(ArbitratorRegistry.PenaltyRecipientIsProtocol.selector, predictedRegistry)
        );
        new RegistryCourtHarness(token, SEAT_LOCK, predictedRegistry);
    }

    function test_Constructor_AcceptsContractPenaltyRecipient() public {
        MockUSDC unrelatedContract = new MockUSDC();
        RegistryCourtHarness other = new RegistryCourtHarness(token, SEAT_LOCK, address(unrelatedContract));

        assertEq(other.registry().penaltyRecipient(), address(unrelatedContract));
    }

    function test_Deposit_AddsWarmingStakeAndLists() public {
        address arbitrator = _arbitrator(0);
        token.mint(arbitrator, SEAT_LOCK);
        vm.startPrank(arbitrator);
        token.approve(address(registry), SEAT_LOCK);

        vm.expectEmit(address(registry));
        emit Listed(arbitrator);
        vm.expectEmit(address(registry));
        emit Deposited(arbitrator, SEAT_LOCK, START + ACTIVATION_DELAY);
        registry.deposit(SEAT_LOCK);
        vm.stopPrank();

        IArbitratorRegistry.Account memory account = _account(arbitrator);
        assertEq(account.stake, 0);
        assertEq(account.warming, SEAT_LOCK);
        assertEq(account.warmingUntil, START + ACTIVATION_DELAY);
        assertTrue(account.listed);
        assertEq(registry.totalStaked(), SEAT_LOCK);
        assertEq(registry.depositsReceived(), SEAT_LOCK);
        assertEq(token.balanceOf(address(registry)), SEAT_LOCK);
        assertEq(registry.listedCount(), 1);
    }

    function test_RevertWhen_DepositZero() public {
        vm.expectRevert(ArbitratorRegistry.ZeroAmount.selector);
        vm.prank(_arbitrator(0));
        registry.deposit(0);
    }

    function test_RevertWhen_DepositReceivesInexactAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        RegistryCourtHarness feeCourt = new RegistryCourtHarness(feeToken, SEAT_LOCK, penaltyRecipient);
        ArbitratorRegistry feeRegistry = feeCourt.registry();
        address arbitrator = _arbitrator(0);
        feeToken.mint(arbitrator, SEAT_LOCK);
        vm.startPrank(arbitrator);
        feeToken.approve(address(feeRegistry), SEAT_LOCK);

        vm.expectRevert(
            abi.encodeWithSelector(ArbitratorRegistry.DepositMismatch.selector, SEAT_LOCK, SEAT_LOCK * 99 / 100)
        );
        feeRegistry.deposit(SEAT_LOCK);
        vm.stopPrank();

        assertEq(feeRegistry.totalStaked(), 0);
        assertEq(feeRegistry.listedCount(), 0);
    }

    function test_Admission_RequiresListingMinimum() public {
        address arbitrator = _arbitrator(0);
        token.mint(arbitrator, SEAT_LOCK);
        vm.startPrank(arbitrator);
        token.approve(address(registry), SEAT_LOCK);
        vm.expectRevert(
            abi.encodeWithSelector(ArbitratorRegistry.BelowListingMinimum.selector, SEAT_LOCK - 1, SEAT_LOCK)
        );
        registry.deposit(SEAT_LOCK - 1);
        vm.stopPrank();
        assertEq(registry.listedCount(), 0);
        assertEq(registry.totalStaked(), 0);

        _deposit(arbitrator, SEAT_LOCK);
        assertTrue(_account(arbitrator).listed);
    }

    function test_Admission_DelistedRemainderCanRelist() public {
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, 150 * USDC);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _withdraw(arbitrator, 100 * USDC);
        assertFalse(_account(arbitrator).listed);
        assertEq(_account(arbitrator).stake, 50 * USDC);

        _deposit(arbitrator, 50 * USDC);

        assertTrue(_account(arbitrator).listed);
        assertEq(_account(arbitrator).stake + _account(arbitrator).warming, SEAT_LOCK);
    }

    function test_RevertWhen_RegistryFull() public {
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), SEAT_LOCK);
        }
        address extra = _arbitrator(32);
        token.mint(extra, SEAT_LOCK);
        vm.startPrank(extra);
        token.approve(address(registry), SEAT_LOCK);
        vm.expectRevert(ArbitratorRegistry.RegistryFull.selector);
        registry.deposit(SEAT_LOCK);
        vm.stopPrank();

        _deposit(_arbitrator(5), 1);
        assertEq(registry.listedCount(), 32);
        assertEq(_account(_arbitrator(5)).warming, SEAT_LOCK + 1);
    }

    function test_RevertWhen_PenaltyRecipientDeposits() public {
        vm.expectRevert(ArbitratorRegistry.PenaltyRecipientCannotStake.selector);
        vm.prank(penaltyRecipient);
        registry.deposit(SEAT_LOCK);
    }

    function test_Activation_ExactBoundary() public {
        _activeArbitrators(3, 2 * SEAT_LOCK);
        address late = _arbitrator(9);
        _deposit(late, SEAT_LOCK);
        uint256 activation = _account(late).warmingUntil;

        vm.warp(activation - 1);
        assertEq(registry.freeStake(late), 0);
        assertEq(_reserve(1), 3);
        assertEq(_candidateAddresses(1).length, 3);

        vm.warp(activation);
        assertEq(registry.freeStake(late), SEAT_LOCK);
        assertEq(_reserve(2), 4);
        assertEq(_candidateAddresses(2)[3], late);
        assertEq(_account(late).stake, SEAT_LOCK);
        assertEq(_account(late).warming, 0);
    }

    function test_TopUp_RestartsWarmingBucketOnly() public {
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, SEAT_LOCK);
        vm.warp(START + 1 days);
        _deposit(arbitrator, SEAT_LOCK);
        assertEq(_account(arbitrator).warming, 2 * SEAT_LOCK);
        assertEq(_account(arbitrator).warmingUntil, START + 3 days);

        vm.warp(START + 2 days);
        assertEq(registry.freeStake(arbitrator), 0);

        vm.warp(START + 3 days);
        assertEq(registry.freeStake(arbitrator), 2 * SEAT_LOCK);
        _deposit(arbitrator, 50 * USDC);
        IArbitratorRegistry.Account memory account = _account(arbitrator);
        assertEq(account.stake, 2 * SEAT_LOCK);
        assertEq(account.warming, 50 * USDC);
        assertEq(account.warmingUntil, START + 5 days);
        assertEq(registry.freeStake(arbitrator), 2 * SEAT_LOCK);
    }

    function test_Withdraw_TransfersExactAmount() public {
        address arbitrator = _activeArbitrators(1, 3 * SEAT_LOCK)[0];

        vm.expectEmit(address(registry));
        emit Withdrawn(arbitrator, SEAT_LOCK);
        _withdraw(arbitrator, SEAT_LOCK);

        assertEq(token.balanceOf(arbitrator), SEAT_LOCK);
        assertEq(_account(arbitrator).stake, 2 * SEAT_LOCK);
        assertEq(registry.totalStaked(), 2 * SEAT_LOCK);
        assertEq(registry.withdrawalsPaid(), SEAT_LOCK);
        assertTrue(_account(arbitrator).listed);
    }

    function test_RevertWhen_WithdrawInvalidAmount() public {
        address arbitrator = _arbitrator(0);
        _deposit(arbitrator, SEAT_LOCK);

        vm.expectRevert(ArbitratorRegistry.ZeroAmount.selector);
        _withdraw(arbitrator, 0);
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, 1, 0));
        _withdraw(arbitrator, 1);

        vm.warp(block.timestamp + ACTIVATION_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, SEAT_LOCK + 1, SEAT_LOCK)
        );
        _withdraw(arbitrator, SEAT_LOCK + 1);
        assertEq(registry.totalStaked(), SEAT_LOCK);
    }

    function test_Withdraw_DelistsWithSwapAndPopAndFreesSlot() public {
        address[] memory arbitrators = _activeArbitrators(4, SEAT_LOCK);

        vm.expectEmit(address(registry));
        emit Delisted(arbitrators[1]);
        _withdraw(arbitrators[1], SEAT_LOCK);

        address[] memory listed = registry.listedAccounts();
        assertEq(listed.length, 3);
        assertEq(listed[0], arbitrators[0]);
        assertEq(listed[1], arbitrators[3]);
        assertEq(listed[2], arbitrators[2]);
        assertFalse(_account(arbitrators[1]).listed);

        _withdraw(arbitrators[3], SEAT_LOCK);
        listed = registry.listedAccounts();
        assertEq(listed.length, 2);
        assertEq(listed[0], arbitrators[0]);
        assertEq(listed[1], arbitrators[2]);

        address newcomer = _arbitrator(7);
        _deposit(newcomer, SEAT_LOCK);
        assertEq(registry.listedAccounts()[2], newcomer);
        _withdraw(arbitrators[0], SEAT_LOCK);
        listed = registry.listedAccounts();
        assertEq(listed[0], newcomer);
        assertEq(listed[1], arbitrators[2]);
    }

    function test_Capacity_DelistedSlotIsReusableWhenFull() public {
        for (uint256 i; i < 32; ++i) {
            _deposit(_arbitrator(i), SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _withdraw(_arbitrator(10), SEAT_LOCK);
        assertEq(registry.listedCount(), 31);

        _deposit(_arbitrator(40), SEAT_LOCK);

        assertEq(registry.listedCount(), 32);
        assertEq(registry.listedAccounts()[10], _arbitrator(31));
        assertEq(registry.listedAccounts()[31], _arbitrator(40));
    }

    function test_FullPenalty_RemovesExhaustedAccount() public {
        address[] memory arbitrators = _activeArbitrators(3, SEAT_LOCK);
        _reserve(1);
        court.selectPanel(1, bytes32(0));
        assertEq(_account(arbitrators[0]).locked, SEAT_LOCK);
        assertEq(_account(arbitrators[0]).stake, SEAT_LOCK);

        vm.expectEmit(address(registry));
        emit Delisted(arbitrators[0]);
        vm.expectEmit(address(registry));
        emit SeatReleased(1, arbitrators[0], SEAT_LOCK);
        court.releaseSeat(1, 0, SEAT_LOCK);

        IArbitratorRegistry.Account memory account = _account(arbitrators[0]);
        assertEq(account.stake, 0);
        assertEq(account.locked, 0);
        assertFalse(account.listed);
        assertEq(uint256(_candidateState(1, 0)), uint256(IArbitratorRegistry.CandidateState.Released));
        assertEq(registry.penaltiesSent(), SEAT_LOCK);
        assertEq(registry.totalStaked(), 2 * SEAT_LOCK);
        assertEq(token.balanceOf(address(court)), SEAT_LOCK);
        assertEq(registry.listedCount(), 2);
    }

    function test_PartialPenalty_KeepsOtherReservation() public {
        address[] memory arbitrators = _activeArbitrators(3, 250 * USDC);
        _reserve(1);
        court.selectPanel(1, bytes32(0));
        _reserve(2);
        assertEq(_account(arbitrators[0]).locked, SEAT_LOCK);
        assertEq(_account(arbitrators[0]).reserved, SEAT_LOCK);

        court.releaseSeat(1, 0, SEAT_LOCK);

        IArbitratorRegistry.Account memory account = _account(arbitrators[0]);
        assertEq(account.stake, 150 * USDC);
        assertEq(account.locked, 0);
        assertEq(account.reserved, SEAT_LOCK);
        assertTrue(account.listed);
        assertEq(uint256(_candidateState(2, 0)), uint256(IArbitratorRegistry.CandidateState.Reserved));
        assertEq(registry.freeStake(arbitrators[0]), 50 * USDC);
    }

    function test_PenaltyBelowMinimum_DelistsAndRemainderIsWithdrawable() public {
        address[] memory arbitrators = _activeArbitrators(3, 150 * USDC);
        _reserve(1);
        court.selectPanel(1, bytes32(0));

        court.releaseSeat(1, 0, SEAT_LOCK);

        IArbitratorRegistry.Account memory account = _account(arbitrators[0]);
        assertEq(account.stake, 50 * USDC);
        assertEq(account.locked, 0);
        assertEq(account.reserved, 0);
        assertFalse(account.listed);
        _withdraw(arbitrators[0], 50 * USDC);
        assertEq(token.balanceOf(arbitrators[0]), 50 * USDC);
        assertEq(_account(arbitrators[0]).stake, 0);
    }

    function test_RevertWhen_CourtFunctionsCalledByOthers() public {
        bytes memory notCourt = abi.encodeWithSelector(ArbitratorRegistry.NotCourt.selector, address(this));

        vm.expectRevert(notCourt);
        registry.reserveCandidates(1, _parties());
        vm.expectRevert(notCourt);
        registry.selectPanel(1, bytes32(0));
        vm.expectRevert(notCourt);
        registry.releaseReservations(1);
        vm.expectRevert(notCourt);
        registry.releaseSeat(1, 0, 0);
    }

    function test_Snapshot_StoresEligibleListedAccountsInOrder() public {
        address[] memory arbitrators = new address[](5);
        for (uint256 i; i < 5; ++i) {
            arbitrators[i] = _arbitrator(i);
            _deposit(arbitrators[i], i == 1 ? SEAT_LOCK : 2 * SEAT_LOCK);
        }
        _deposit(client, 5 * SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        address warming = _arbitrator(8);
        _deposit(warming, 3 * SEAT_LOCK);
        court.reserveCandidates(1, [arbitrators[2], arbitrators[3], arbitrators[4]]);
        assertEq(registry.freeStake(arbitrators[1]), 0);

        address[] memory expected = new address[](4);
        expected[0] = arbitrators[0];
        expected[1] = arbitrators[2];
        expected[2] = arbitrators[3];
        expected[3] = arbitrators[4];
        vm.expectEmit(address(registry));
        emit CandidatesReserved(2, expected);
        assertEq(_reserve(2), 4);

        _assertSnapshot(2, expected, IArbitratorRegistry.CandidateState.Reserved);
        assertEq(_account(arbitrators[0]).reserved, 2 * SEAT_LOCK);
        assertEq(_account(arbitrators[2]).reserved, SEAT_LOCK);
        assertEq(_account(arbitrators[1]).reserved, SEAT_LOCK);
        assertEq(_account(client).reserved, SEAT_LOCK);
        assertEq(_account(warming).reserved, 0);
    }

    function test_RevertWhen_TooFewCandidatesWritesNothing() public {
        address[] memory arbitrators = _activeArbitrators(2, SEAT_LOCK);
        address maturedUnmaterialized = _arbitrator(5);
        _deposit(maturedUnmaterialized, SEAT_LOCK);
        _deposit(client, SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        IArbitratorRegistry.Account memory before = _account(maturedUnmaterialized);
        assertEq(before.stake, 0);
        assertEq(before.warming, SEAT_LOCK);

        vm.recordLogs();
        uint256 count = court.reserveCandidates(1, [client, maturedUnmaterialized, feeRecipient]);

        assertEq(count, 2);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.None));
        assertEq(registry.candidatesOf(1).length, 0);
        IArbitratorRegistry.Account memory afterScan = _account(maturedUnmaterialized);
        assertEq(afterScan.stake, before.stake);
        assertEq(afterScan.warming, before.warming);
        assertEq(_account(arbitrators[0]).reserved, 0);

        assertEq(_reserve(1), 3);
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.Reserved));
        assertEq(_account(maturedUnmaterialized).stake, SEAT_LOCK);
        assertEq(_account(maturedUnmaterialized).reserved, SEAT_LOCK);
    }

    function test_RevertWhen_SnapshotTakenTwice() public {
        _activeArbitrators(3, 2 * SEAT_LOCK);
        _reserve(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitratorRegistry.InvalidSnapshotState.selector, 1, IArbitratorRegistry.SnapshotState.Reserved
            )
        );
        _reserve(1);
        assertEq(_account(_arbitrator(0)).reserved, SEAT_LOCK);
    }

    function test_Snapshot_UnaffectedByLaterRegistryActivity() public {
        address[] memory arbitrators = _activeArbitrators(4, 2 * SEAT_LOCK);
        _reserve(1);
        address[] memory stored = _candidateAddresses(1);

        address newcomer = _arbitrator(9);
        _deposit(newcomer, 3 * SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        _assertSnapshot(1, stored, IArbitratorRegistry.CandidateState.Reserved);

        _withdraw(arbitrators[0], SEAT_LOCK);
        _assertSnapshot(1, stored, IArbitratorRegistry.CandidateState.Reserved);

        _reserve(2);
        court.selectPanel(2, bytes32(0));
        court.releaseSeat(2, 1, SEAT_LOCK);
        _assertSnapshot(1, stored, IArbitratorRegistry.CandidateState.Reserved);

        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, SEAT_LOCK, 0));
        _withdraw(arbitrators[0], SEAT_LOCK);
        assertTrue(_account(arbitrators[0]).listed);
        _assertSnapshot(1, stored, IArbitratorRegistry.CandidateState.Reserved);
        for (uint256 i; i < stored.length; ++i) {
            assertGe(_account(stored[i]).reserved, SEAT_LOCK);
        }
    }

    function test_RevertWhen_WithdrawingReservedStake() public {
        address[] memory arbitrators = _activeArbitrators(3, SEAT_LOCK);
        _reserve(1);
        IArbitratorRegistry.Account memory before = _account(arbitrators[0]);

        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, 1, 0));
        _withdraw(arbitrators[0], 1);

        IArbitratorRegistry.Account memory afterAttempt = _account(arbitrators[0]);
        assertEq(afterAttempt.stake, before.stake);
        assertEq(afterAttempt.reserved, before.reserved);
        assertTrue(afterAttempt.listed);
    }

    function test_Concurrency_CollateralBacksOneObligationEach() public {
        _activeArbitrators(2, 10 * SEAT_LOCK);
        address limited = _arbitrator(5);
        _deposit(limited, 3 * SEAT_LOCK);
        _deposit(_arbitrator(6), 10 * SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        _reserve(1);
        assertEq(_candidateAddresses(1)[2], limited);
        court.selectPanel(1, _seedSelecting(2, 4, true));
        _reserve(2);
        _reserve(3);
        IArbitratorRegistry.Account memory account = _account(limited);
        assertEq(account.locked, SEAT_LOCK);
        assertEq(account.reserved, 2 * SEAT_LOCK);
        assertEq(registry.freeStake(limited), 0);

        _reserve(4);
        address[] memory fourth = _candidateAddresses(4);
        assertEq(fourth.length, 3);
        for (uint256 i; i < fourth.length; ++i) {
            assertTrue(fourth[i] != limited);
        }
        account = _account(limited);
        assertEq(account.locked + account.reserved, account.stake);

        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, 1, 0));
        _withdraw(limited, 1);
    }

    function test_SelectPanel_LocksSelectedAndReleasesOthers() public {
        address[] memory arbitrators = _activeArbitrators(5, SEAT_LOCK);
        _reserve(1);
        uint256 balanceBefore = token.balanceOf(address(registry));
        bytes32 seed = keccak256("panel");
        uint256[3] memory expected = _referenceSelection(seed, 5);

        vm.expectEmit(address(registry));
        emit PanelSelected(1, expected);
        (uint256[3] memory indexes, address[3] memory panel) = court.selectPanel(1, seed);

        for (uint256 j; j < 3; ++j) {
            assertEq(indexes[j], expected[j]);
            assertEq(panel[j], arbitrators[expected[j]]);
        }
        assertTrue(indexes[0] != indexes[1] && indexes[1] != indexes[2] && indexes[0] != indexes[2]);
        for (uint256 i; i < 5; ++i) {
            bool selected = i == indexes[0] || i == indexes[1] || i == indexes[2];
            IArbitratorRegistry.Account memory account = _account(arbitrators[i]);
            assertEq(account.reserved, 0);
            assertEq(account.locked, selected ? SEAT_LOCK : 0);
            assertEq(
                uint256(_candidateState(1, i)),
                uint256(
                    selected ? IArbitratorRegistry.CandidateState.Locked : IArbitratorRegistry.CandidateState.Unselected
                )
            );
        }
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.Selected));
        assertEq(token.balanceOf(address(registry)), balanceBefore);
        assertEq(registry.totalStaked(), 5 * SEAT_LOCK);
    }

    function test_SelectPanel_CanSelectFirstMiddleAndLastCandidates() public {
        _activeArbitrators(7, 4 * SEAT_LOCK);
        uint256[3] memory targets = [uint256(0), 3, 6];
        for (uint256 t; t < targets.length; ++t) {
            uint256 disputeId = t + 1;
            _reserve(disputeId);
            (uint256[3] memory indexes,) = court.selectPanel(disputeId, _seedSelecting(targets[t], 7, true));
            assertTrue(indexes[0] == targets[t] || indexes[1] == targets[t] || indexes[2] == targets[t]);
            assertEq(
                uint256(_candidateState(disputeId, targets[t])), uint256(IArbitratorRegistry.CandidateState.Locked)
            );
        }
    }

    function test_RevertWhen_SnapshotStateTransitionRepeated() public {
        _activeArbitrators(3, 3 * SEAT_LOCK);
        _reserve(1);
        court.selectPanel(1, bytes32(0));
        _reserve(2);
        court.releaseReservations(2);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitratorRegistry.InvalidSnapshotState.selector, 1, IArbitratorRegistry.SnapshotState.Selected
            )
        );
        court.selectPanel(1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitratorRegistry.InvalidSnapshotState.selector, 1, IArbitratorRegistry.SnapshotState.Selected
            )
        );
        court.releaseReservations(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitratorRegistry.InvalidSnapshotState.selector, 2, IArbitratorRegistry.SnapshotState.Released
            )
        );
        court.selectPanel(2, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitratorRegistry.InvalidSnapshotState.selector, 3, IArbitratorRegistry.SnapshotState.None
            )
        );
        court.selectPanel(3, bytes32(0));
    }

    function test_RevertWhen_ReleaseSeatUnknownOrNotLocked() public {
        _activeArbitrators(4, 3 * SEAT_LOCK);
        _reserve(1);
        _reserve(2);
        bytes32 seed = _seedSelecting(3, 4, false);
        court.selectPanel(2, seed);

        _expectUnknownSeat(1, 0);
        _expectUnknownSeat(2, 3);
        _expectUnknownSeat(2, 4);
        _expectUnknownSeat(99, 0);

        uint256[3] memory chosen = _referenceSelection(seed, 4);
        court.releaseSeat(2, chosen[0], 0);
        _expectUnknownSeat(2, chosen[0]);

        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.PenaltyTooHigh.selector, SEAT_LOCK + 1, SEAT_LOCK));
        court.releaseSeat(2, chosen[1], SEAT_LOCK + 1);

        assertEq(uint256(_candidateState(1, 0)), uint256(IArbitratorRegistry.CandidateState.Reserved));
        assertEq(uint256(_candidateState(2, chosen[1])), uint256(IArbitratorRegistry.CandidateState.Locked));
        assertEq(registry.penaltiesSent(), 0);
    }

    function test_ZeroPenaltyRelease_MovesNoTokens() public {
        address[] memory arbitrators = _activeArbitrators(3, SEAT_LOCK);
        _reserve(1);
        court.selectPanel(1, bytes32(0));
        uint256 registryBalance = token.balanceOf(address(registry));

        court.releaseSeat(1, 1, 0);

        assertEq(token.balanceOf(address(registry)), registryBalance);
        assertEq(token.balanceOf(address(court)), 0);
        assertEq(registry.totalStaked(), 3 * SEAT_LOCK);
        assertEq(_account(arbitrators[1]).locked, 0);
        assertEq(_account(arbitrators[1]).stake, SEAT_LOCK);
        assertTrue(_account(arbitrators[1]).listed);
    }

    function test_ReleaseReservations_ReturnsEveryReservation() public {
        address[] memory arbitrators = _activeArbitrators(4, SEAT_LOCK);
        _reserve(1);
        uint256 registryBalance = token.balanceOf(address(registry));

        vm.expectEmit(address(registry));
        emit ReservationsReleased(1);
        court.releaseReservations(1);

        for (uint256 i; i < 4; ++i) {
            assertEq(_account(arbitrators[i]).reserved, 0);
            assertEq(uint256(_candidateState(1, i)), uint256(IArbitratorRegistry.CandidateState.Released));
        }
        assertEq(uint256(registry.snapshotState(1)), uint256(IArbitratorRegistry.SnapshotState.Released));
        assertEq(token.balanceOf(address(registry)), registryBalance);
        assertEq(registry.totalStaked(), 4 * SEAT_LOCK);
    }

    function test_SlotReuse_SnapshotKeepsOriginalIdentities() public {
        address[] memory arbitrators = _activeArbitrators(4, SEAT_LOCK);
        _reserve(1);
        address[] memory stored = _candidateAddresses(1);
        court.selectPanel(1, _seedSelecting(0, 4, false));
        assertEq(uint256(_candidateState(1, 0)), uint256(IArbitratorRegistry.CandidateState.Unselected));

        _withdraw(arbitrators[0], SEAT_LOCK);
        assertFalse(_account(arbitrators[0]).listed);
        address newcomer = _arbitrator(9);
        _deposit(newcomer, SEAT_LOCK);
        _deposit(arbitrators[0], SEAT_LOCK);

        address[] memory listed = registry.listedAccounts();
        assertEq(listed[0], arbitrators[3]);
        assertEq(listed[3], newcomer);
        assertEq(listed[4], arbitrators[0]);
        address[] memory afterReuse = _candidateAddresses(1);
        for (uint256 i; i < stored.length; ++i) {
            assertEq(afterReuse[i], stored[i]);
        }
        assertEq(uint256(_candidateState(1, 0)), uint256(IArbitratorRegistry.CandidateState.Unselected));
    }

    function test_Donations_CreateNoPrincipal() public {
        _activeArbitrators(3, SEAT_LOCK);
        token.mint(address(registry), 77 * USDC);

        assertEq(registry.totalStaked(), 3 * SEAT_LOCK);
        assertEq(token.balanceOf(address(registry)), 3 * SEAT_LOCK + 77 * USDC);
        address outsider = _arbitrator(20);
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, 1, 0));
        _withdraw(outsider, 1);
        vm.expectRevert(
            abi.encodeWithSelector(ArbitratorRegistry.InsufficientFreeStake.selector, SEAT_LOCK + 1, SEAT_LOCK)
        );
        _withdraw(_arbitrator(0), SEAT_LOCK + 1);
        assertEq(
            registry.depositsReceived(), registry.withdrawalsPaid() + registry.penaltiesSent() + registry.totalStaked()
        );
    }

    function test_RevertWhen_WithdrawTransferFailsRollsBackDelisting() public {
        BlocklistToken blockToken = new BlocklistToken();
        RegistryCourtHarness blockCourt = new RegistryCourtHarness(blockToken, SEAT_LOCK, penaltyRecipient);
        ArbitratorRegistry blockRegistry = blockCourt.registry();
        address arbitrator = _arbitrator(0);
        _depositBlocklist(blockRegistry, blockToken, arbitrator, SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        blockToken.setBlocked(arbitrator, true);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, arbitrator));
        vm.prank(arbitrator);
        blockRegistry.withdraw(SEAT_LOCK);

        IArbitratorRegistry.Account memory account = blockRegistry.accountOf(arbitrator);
        assertTrue(account.listed);
        assertEq(account.stake, 0);
        assertEq(account.warming, SEAT_LOCK);
        assertEq(blockRegistry.listedCount(), 1);
        assertEq(blockRegistry.withdrawalsPaid(), 0);
        assertEq(blockRegistry.totalStaked(), SEAT_LOCK);
    }

    function test_RevertWhen_PenaltyTransferFailsRollsBackRelease() public {
        BlocklistToken blockToken = new BlocklistToken();
        RegistryCourtHarness blockCourt = new RegistryCourtHarness(blockToken, SEAT_LOCK, penaltyRecipient);
        ArbitratorRegistry blockRegistry = blockCourt.registry();
        for (uint256 i; i < 3; ++i) {
            _depositBlocklist(blockRegistry, blockToken, _arbitrator(i), SEAT_LOCK);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        blockCourt.reserveCandidates(1, _parties());
        blockCourt.selectPanel(1, bytes32(0));
        blockToken.setBlocked(address(blockCourt), true);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.RecipientBlocked.selector, address(blockCourt)));
        blockCourt.releaseSeat(1, 0, SEAT_LOCK);

        IArbitratorRegistry.Account memory account = blockRegistry.accountOf(_arbitrator(0));
        assertEq(account.stake, SEAT_LOCK);
        assertEq(account.locked, SEAT_LOCK);
        assertTrue(account.listed);
        assertEq(uint256(blockRegistry.candidatesOf(1)[0].state), uint256(IArbitratorRegistry.CandidateState.Locked));
        assertEq(blockRegistry.penaltiesSent(), 0);
        assertEq(blockRegistry.totalStaked(), 3 * SEAT_LOCK);

        blockToken.setBlocked(address(blockCourt), false);
        blockCourt.releaseSeat(1, 0, SEAT_LOCK);
        assertFalse(blockRegistry.accountOf(_arbitrator(0)).listed);
    }

    function test_Reentrancy_DuringDepositWithdrawAndPenaltyIsBlocked() public {
        ReentrantToken reentrant = new ReentrantToken();
        RegistryCourtHarness reentrantCourt = new RegistryCourtHarness(reentrant, SEAT_LOCK, penaltyRecipient);
        ArbitratorRegistry reentrantRegistry = reentrantCourt.registry();
        for (uint256 i; i < 3; ++i) {
            address arbitrator = _arbitrator(i);
            reentrant.mint(arbitrator, 3 * SEAT_LOCK);
            vm.prank(arbitrator);
            reentrant.approve(address(reentrantRegistry), type(uint256).max);
        }

        reentrant.arm(address(reentrantRegistry), abi.encodeCall(ArbitratorRegistry.deposit, (SEAT_LOCK)));
        vm.prank(_arbitrator(0));
        reentrantRegistry.deposit(2 * SEAT_LOCK);
        _assertReentryBlocked(reentrant);
        vm.prank(_arbitrator(1));
        reentrantRegistry.deposit(2 * SEAT_LOCK);
        vm.prank(_arbitrator(2));
        reentrantRegistry.deposit(2 * SEAT_LOCK);
        vm.warp(block.timestamp + ACTIVATION_DELAY);

        reentrant.arm(address(reentrantRegistry), abi.encodeCall(ArbitratorRegistry.withdraw, (SEAT_LOCK)));
        vm.prank(_arbitrator(0));
        reentrantRegistry.withdraw(SEAT_LOCK);
        _assertReentryBlocked(reentrant);
        assertEq(reentrantRegistry.accountOf(_arbitrator(0)).stake, SEAT_LOCK);

        reentrantCourt.reserveCandidates(1, _parties());
        reentrantCourt.selectPanel(1, bytes32(0));
        reentrant.arm(address(reentrantRegistry), abi.encodeCall(ArbitratorRegistry.releaseSeat, (1, 1, SEAT_LOCK)));
        reentrantCourt.releaseSeat(1, 0, SEAT_LOCK);
        _assertReentryBlocked(reentrant);
        assertEq(
            uint256(reentrantRegistry.candidatesOf(1)[1].state), uint256(IArbitratorRegistry.CandidateState.Locked)
        );
        assertEq(reentrantRegistry.penaltiesSent(), SEAT_LOCK);
        assertEq(reentrant.balanceOf(address(reentrantCourt)), SEAT_LOCK);
    }

    function _assertSnapshot(uint256 disputeId, address[] memory expected, IArbitratorRegistry.CandidateState state)
        private
        view
    {
        IArbitratorRegistry.Candidate[] memory candidates = registry.candidatesOf(disputeId);
        assertEq(candidates.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(candidates[i].arbitrator, expected[i]);
            assertEq(uint256(candidates[i].state), uint256(state));
        }
    }

    function _expectUnknownSeat(uint256 disputeId, uint256 index) private {
        vm.expectRevert(abi.encodeWithSelector(ArbitratorRegistry.UnknownSeat.selector, disputeId, index));
        court.releaseSeat(disputeId, index, 0);
    }

    function _assertReentryBlocked(ReentrantToken reentrant) private view {
        assertTrue(reentrant.reentryAttempted());
        assertFalse(reentrant.reentrySucceeded());
        assertEq(
            reentrant.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function _depositBlocklist(ArbitratorRegistry target, BlocklistToken blockToken, address arbitrator, uint256 amount)
        private
    {
        blockToken.mint(arbitrator, amount);
        vm.startPrank(arbitrator);
        blockToken.approve(address(target), amount);
        target.deposit(amount);
        vm.stopPrank();
    }
}
