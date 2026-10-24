// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev 6-decimal token with OpenZeppelin's ERC-2612 implementation. Not a model of any deployed USDC contract.
contract MockPermitUSDC is ERC20Permit {
    constructor() ERC20("Mock Permit USD Coin", "pUSDC") ERC20Permit("Mock Permit USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
