// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

library HashLib {

    function hash(
        uint64 dstChainId,
        address from,
        address to,
        uint256 value,
        uint256 nonce,
        uint64 expiry
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(dstChainId, from, to, value, nonce, expiry));
    }

}
