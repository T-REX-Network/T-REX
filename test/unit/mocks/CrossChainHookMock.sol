// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

contract CrossChainHookMock {

    struct Sent {
        uint64 dstChainId;
        bytes32 hash;
        uint64 expiry;
        address from;
        address to;
        uint256 value;
    }

    Sent[] public sent;

    function sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) external {
        sent.push(Sent({ dstChainId: dstChainId, hash: hash, expiry: expiry, from: from, to: to, value: value }));
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    function lastSent() external view returns (Sent memory) {
        return sent[sent.length - 1];
    }

}
