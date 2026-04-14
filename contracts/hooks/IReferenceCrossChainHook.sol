// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

/// @title IReferenceCrossChainHook
/// @notice Reference-chain hook interface. Called by the Token to ship an authorization
/// message to a bridged chain. Settlement notifications received from the bridged chain are
/// dispatched directly to `Token.onTransferSettled` via the underlying transport — they are
/// not part of this interface.
interface IReferenceCrossChainHook {

    function sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) external;

}
