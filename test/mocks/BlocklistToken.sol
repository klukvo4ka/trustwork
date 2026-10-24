// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Reverts any transfer to a blocked account, similar to USDC's blacklist.
contract BlocklistToken is ERC20 {
    mapping(address account => bool) public blocked;

    error RecipientBlocked(address account);

    constructor() ERC20("Blocklist Token", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert RecipientBlocked(to);
        super._update(from, to, value);
    }
}
