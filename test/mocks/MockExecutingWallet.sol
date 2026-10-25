// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Contract wallet whose `owner` executes calls through it and whose signatures are the owner's ECDSA signatures.
contract MockExecutingWallet is IERC1271 {
    address public immutable owner;

    error NotOwner(address caller);
    error CallFailed(bytes returnData);

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) revert CallFailed(returnData);
        return returnData;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}
