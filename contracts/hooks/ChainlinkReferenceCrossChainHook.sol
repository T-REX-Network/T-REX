// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { CCIPReceiver } from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { AbstractReferenceCrossChainHook } from "./AbstractReferenceCrossChainHook.sol";

/// @title ChainlinkReferenceCrossChainHook
/// @notice Reference-chain hook that ships authorizations to bridged chains via CCIP and
/// dispatches inbound settlement notifications to the token.
contract ChainlinkReferenceCrossChainHook is AbstractReferenceCrossChainHook, CCIPReceiver {

    LinkTokenInterface internal immutable _linkToken;
    uint200 internal _gasLimit = 200_000;

    /// @dev dstChainId (CCIP selector) → bridged hook address (encoded as bytes32 for symmetry).
    mapping(uint64 dstChainId => bytes32 bridgedHook) internal _bridgedHooks;

    constructor(address router, address link, address accessManager_, address token_)
        AbstractReferenceCrossChainHook(accessManager_, token_)
        CCIPReceiver(router)
    {
        _linkToken = LinkTokenInterface(link);
    }

    // ----- Admin -----

    function configureBridgedHook(uint64 dstChainId, bytes32 bridgedHookAddress) external restricted {
        _bridgedHooks[dstChainId] = bridgedHookAddress;
        emit EventsLib.BridgedHookConfigured(dstChainId, bridgedHookAddress);
    }

    function setGasLimit(uint200 gasLimit) external restricted {
        _gasLimit = gasLimit;
    }

    function bridgedHook(uint64 dstChainId) external view returns (bytes32) {
        return _bridgedHooks[dstChainId];
    }

    // ----- Outbound -----

    function _sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) internal override {
        bytes32 peer = _bridgedHooks[dstChainId];
        require(peer != bytes32(0), ErrorsLib.DestinationChainNotConfigured(dstChainId));

        Client.EVM2AnyMessage memory request = Client.EVM2AnyMessage({
            receiver: abi.encode(peer),
            data: abi.encode(hash, expiry, from, to, value),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({ gasLimit: _gasLimit, allowOutOfOrderExecution: true })
            ),
            feeToken: address(_linkToken)
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fees = router.getFee(dstChainId, request);
        _linkToken.approve(address(router), fees);
        router.ccipSend(dstChainId, request);
    }

    // ----- Inbound -----

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        bytes32 expected = _bridgedHooks[message.sourceChainSelector];
        bytes32 sender = abi.decode(message.sender, (bytes32));
        require(expected != bytes32(0) && sender == expected, ErrorsLib.UnauthorizedHookCaller());

        bytes32 hash = abi.decode(message.data, (bytes32));
        _onSettlement(hash);
    }

}
