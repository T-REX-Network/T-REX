// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import { IToken } from "../token/IToken.sol";
import { IReferenceCrossChainHook } from "./IReferenceCrossChainHook.sol";

/// @title AbstractReferenceCrossChainHook
/// @notice Reference-chain hook base. Subclasses implement `_sendAuthorization` for the outbound
/// transport and call `_onSettlement` from the inbound receive path.
abstract contract AbstractReferenceCrossChainHook is IReferenceCrossChainHook, AccessManaged {

    IToken internal immutable _token;

    constructor(address accessManager_, address token_) AccessManaged(accessManager_) {
        _token = IToken(token_);
    }

    function token() external view returns (address) {
        return address(_token);
    }

    /// @inheritdoc IReferenceCrossChainHook
    function sendAuthorization(uint64 dstChainId, bytes32 hash, uint64 expiry, address from, address to, uint256 value)
        external
        restricted
    {
        _sendAuthorization(dstChainId, hash, expiry, from, to, value);
    }

    /// @dev Subclasses ship the message via their transport.
    function _sendAuthorization(uint64 dstChainId, bytes32 hash, uint64 expiry, address from, address to, uint256 value)
        internal
        virtual;

    /// @dev Subclasses call this from their receive path to dispatch a settlement to the token.
    function _onSettlement(bytes32 hash) internal {
        _token.onTransferSettled(hash);
    }

}
