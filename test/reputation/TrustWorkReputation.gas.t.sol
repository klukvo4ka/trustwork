// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {ITrustWorkReputation} from "../../src/interfaces/ITrustWorkReputation.sol";
import {ReputationTestBase} from "../utils/ReputationTestBase.sol";

/// @dev Reports `register`, `claimReceipt` and `burn` gas for representative cases; there is no acceptance threshold.
/// The reputation, factory, order and court storage is marked cold with `vm.cool` before the measured call.
contract TrustWorkReputationGasTest is ReputationTestBase {
    function _sharedToken() internal pure override returns (bool) {
        return true;
    }

    function test_Gas_RegisterRepresentativeOutcomes() public {
        string[5] memory labels = ["Completed (3 milestones)", "DeliveryExpired", "FreelancerWins", "Split", "NoPanel"];
        for (uint256 c; c < 5; ++c) {
            uint256 state = vm.snapshotState();
            Scenario memory s = c == 0
                ? _completed(_defaultAmounts())
                : c == 1
                    ? _expired(_defaultAmounts(), 1)
                    : _ruled(
                        _defaultAmounts(),
                        1,
                        c == 2 ? Outcome.FreelancerMajority : c == 3 ? Outcome.SplitByTie : Outcome.NoPanel
                    );
            vm.cool(address(reputation));
            vm.cool(address(factory));
            vm.cool(address(s.order));
            vm.cool(address(court));
            reputation.register(address(s.order));
            console.log(
                string.concat("register, first registration for both accounts, ", labels[c], ":"),
                vm.lastCallGas().gasTotalUsed
            );
            vm.revertToState(state);
        }
        _register(_completed(_defaultAmounts()));
        Scenario memory second = _completed(_defaultAmounts());
        vm.cool(address(reputation));
        vm.cool(address(factory));
        vm.cool(address(second.order));
        vm.cool(address(court));
        reputation.register(address(second.order));
        console.log("register, Completed, accounts already registered once:", vm.lastCallGas().gasTotalUsed);
    }

    function test_Gas_ClaimAndBurnReceipts() public {
        Scenario memory s = _completed(_defaultAmounts());
        reputation.register(address(s.order));
        _coolAll(address(s.order));
        vm.prank(client);
        uint256 clientId = reputation.claimReceipt(address(s.order), ITrustWorkReputation.Role.Client);
        console.log("claimReceipt, client, first receipt of the account:", vm.lastCallGas().gasTotalUsed);
        _coolAll(address(s.order));
        vm.prank(freelancer);
        reputation.claimReceipt(address(s.order), ITrustWorkReputation.Role.Freelancer);
        console.log("claimReceipt, freelancer, first receipt of the account:", vm.lastCallGas().gasTotalUsed);

        Scenario memory second = _completed(_defaultAmounts());
        reputation.register(address(second.order));
        _coolAll(address(second.order));
        vm.prank(client);
        uint256 secondId = reputation.claimReceipt(address(second.order), ITrustWorkReputation.Role.Client);
        console.log("claimReceipt, client, account already holds a receipt:", vm.lastCallGas().gasTotalUsed);

        _coolAll(address(s.order));
        vm.prank(client);
        reputation.burn(clientId);
        console.log("burn, holder keeps another receipt:", vm.lastCallGas().gasTotalUsed);
        _coolAll(address(second.order));
        vm.prank(client);
        reputation.burn(secondId);
        console.log("burn, holder's last receipt:", vm.lastCallGas().gasTotalUsed);
    }

    function _coolAll(address order) private {
        vm.cool(address(reputation));
        vm.cool(address(factory));
        vm.cool(order);
        vm.cool(address(court));
    }
}
