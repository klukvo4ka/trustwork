// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Contract wallet that accepts signatures from `signer`, or misbehaves according to `mode`.
contract MockERC1271Wallet is IERC1271 {
    enum Mode {
        Valid,
        WrongMagicValue,
        Reverting
    }

    address public immutable signer;
    Mode public mode;

    error ValidatorReverted();

    constructor(address signer_) {
        signer = signer_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (mode == Mode.Reverting) revert ValidatorReverted();
        if (mode == Mode.WrongMagicValue) return 0xdeadbeef;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}
