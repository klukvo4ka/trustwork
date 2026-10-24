// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Burns `TRANSFER_FEE_BPS` of every transfer between two nonzero accounts.
contract FeeOnTransferToken is ERC20 {
    uint256 public constant TRANSFER_FEE_BPS = 100;

    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 burned = value * TRANSFER_FEE_BPS / 10_000;
        super._update(from, address(0), burned);
        super._update(from, to, value - burned);
    }
}
