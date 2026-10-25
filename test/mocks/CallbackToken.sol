// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Once armed, the next transfer from or to `trigger` calls `target` with `callData`, the way a token with
/// transfer hooks would. The outcome is recorded instead of bubbled so tests can inspect it.
contract CallbackToken is ERC20 {
    address public trigger;
    address public target;
    bytes public callData;
    bool public armed;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackRevertData;

    constructor() ERC20("Callback Token", "CB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address trigger_, address target_, bytes calldata callData_) external {
        trigger = trigger_;
        target = target_;
        callData = callData_;
        armed = true;
        callbackAttempted = false;
        callbackSucceeded = false;
        delete callbackRevertData;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && (from == trigger || to == trigger)) {
            armed = false;
            callbackAttempted = true;
            (callbackSucceeded, callbackRevertData) = target.call(callData);
        }
    }
}
