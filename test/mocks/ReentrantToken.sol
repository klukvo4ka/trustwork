// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Once armed, the next transfer out of `target` (or into it, for funding) calls back into
/// `target` with `callData`, the way a token with transfer hooks would. The outcome is recorded
/// instead of bubbled so tests can inspect it.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public callData;
    bool public armed;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    constructor() ERC20("Reentrant Token", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata callData_) external {
        target = target_;
        callData = callData_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && (from == target || to == target)) {
            armed = false;
            reentryAttempted = true;
            (reentrySucceeded, reentryRevertData) = target.call(callData);
        }
    }
}
