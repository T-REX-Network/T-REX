// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

library Utils {

    function erc7201(string memory namespaceId) internal pure returns (bytes32) {
        // ERC-7201: keccak256(abi.encode(uint256(keccak256(namespaceId)) - 1)) & ~bytes32(uint256(0xff))
        return keccak256(abi.encode(uint256(keccak256(bytes(namespaceId))) - 1)) & ~bytes32(uint256(0xff));
    }

}
