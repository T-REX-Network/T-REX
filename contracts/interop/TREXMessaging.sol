// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//
/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma solidity ^0.8.30;

pragma solidity 0.8.30;

import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";
import { IERC7786GatewaySource } from "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { ITREXMessaging } from "./ITREXMessaging.sol";
import { ITrustedGatewayRegistry } from "./ITrustedGatewayRegistry.sol";

/**
 * @title TREXMessaging
 * @dev The token's half of the interop boundary: the second of the protocol's two levels of trust.
 *
 * The first level is the network's, and lives in `TrustedGatewayRegistry`: which messaging
 * implementations are sound enough to attest who sent a message. This level is the issuer's: of those
 * gateways, which one carries this token's traffic to a given chain, and which peer it will talk to
 * there.
 *
 * A token and its Lite on each satellite are messaging peers, and nothing sits between them. The token
 * sends through its route, addressed to its peer; it accepts inbound only from that same pair. There is
 * no shared per-chain intermediary on either side, and none is needed.
 *
 * Everything here fails closed. A token opens no chain by default, refuses to send to a chain it was
 * not explicitly opened for, and re-reads the registry on every use, so an emergency gateway removal
 * severs its routes with no call on the token at all.
 *
 * Storage sits in its own ERC-7201 namespace rather than in the token's, so the messaging layer stays
 * independently reviewable and the token's ledger layout is never disturbed by it.
 */
abstract contract TREXMessaging is ITREXMessaging, ERC7786Recipient {

    /// @dev The ERC-7930 prefix behind a `chainKey`, kept so the token can address its own peer there.
    struct ChainPrefix {
        bytes2 chainType;
        bytes chainReference;
    }

    /// @custom:storage-location erc7201:ERC3643.storage.TREXMessaging
    struct MessagingStorage {
        /// The network's vetted gateway set this token resolves trust against.
        ITrustedGatewayRegistry registry;

        /// The gateway carrying this token's traffic, per chain. Zero closes the chain.
        mapping(bytes32 chainKey => address gateway) routes;

        /// This token's Lite on each chain, ERC-7930. Empty falls back to the token's own address.
        mapping(bytes32 chainKey => bytes peer) peers;

        /// Transport-level replay guard. The pinned receiver base keeps no record of its own.
        mapping(address gateway => mapping(bytes32 receiveId => bool)) received;

        /// The prefix each known chain key was derived from, recorded on first sight.
        mapping(bytes32 chainKey => ChainPrefix) chains;

        /// The gateway each validation leg went out through, snapshot at dispatch and never rewritten.
        mapping(uint256 validationId => mapping(bytes32 chainKey => address gateway)) pinnedRoutes;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.TREXMessaging")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MESSAGING_STORAGE_LOCATION =
        0x6781593751868cc4363b89c5315b7498ab1a563f1f060d4f48327b74abb92100;

    /// @dev Bytes of an ERC-7930 v1 envelope that are not the chain reference or the account: the
    ///  version, the chain type, and the two length prefixes.
    uint256 private constant ERC7930_V1_FIXED_LENGTH = 6;

    /// @inheritdoc ITREXMessaging
    function trustedGatewayRegistry() public view returns (address) {
        return address(_messagingStorage().registry);
    }

    /// @inheritdoc ITREXMessaging
    function routeFor(bytes32 chainKey) public view returns (address) {
        return _messagingStorage().routes[chainKey];
    }

    /// @inheritdoc ITREXMessaging
    function chainOf(bytes32 chainKey) public view returns (bytes2 chainType, bytes memory chainReference) {
        ChainPrefix storage chain = _messagingStorage().chains[chainKey];
        return (chain.chainType, chain.chainReference);
    }

    /// @inheritdoc ITREXMessaging
    function peerFor(bytes32 chainKey) public view returns (bytes memory) {
        MessagingStorage storage s = _messagingStorage();

        bytes memory peer = s.peers[chainKey];
        if (peer.length > 0) {
            return peer;
        }

        ChainPrefix storage chain = s.chains[chainKey];
        if (chain.chainType != MessageTypesLib.EVM_CHAIN_TYPE || chain.chainReference.length == 0) {
            return "";
        }

        return InteroperableAddress.formatV1(chain.chainType, chain.chainReference, abi.encodePacked(address(this)));
    }

    /// @inheritdoc ITREXMessaging
    function pinnedRouteFor(uint256 validationId, bytes32 chainKey) public view returns (address) {
        return _messagingStorage().pinnedRoutes[validationId][chainKey];
    }

    /// @inheritdoc ITREXMessaging
    function isChainOpen(bytes32 chainKey) public view returns (bool) {
        MessagingStorage storage s = _messagingStorage();
        address gateway = s.routes[chainKey];

        return gateway != address(0) && address(s.registry) != address(0) && s.registry.isTrusted(gateway)
            && peerFor(chainKey).length > 0;
    }

    /// @dev Whether `gateway` has already delivered `receiveId` to this token.
    function messageReceived(address gateway, bytes32 receiveId) public view returns (bool) {
        return _messagingStorage().received[gateway][receiveId];
    }

    /// @inheritdoc ERC7786Recipient
    function _isAuthorizedGateway(address gateway, bytes calldata) internal view override returns (bool) {
        ITrustedGatewayRegistry registry = _messagingStorage().registry;

        return address(registry) != address(0) && registry.isTrusted(gateway);
    }

    /// @inheritdoc ERC7786Recipient
    function _processMessage(address gateway, bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        internal
        override
    {
        (bytes2 chainType, bytes calldata chainReference,) = InteroperableAddress.parseV1Calldata(sender);
        bytes32 chainKey = MessageTypesLib.chainKey(chainType, chainReference);

        MessagingStorage storage s = _messagingStorage();

        require(keccak256(sender) == keccak256(peerFor(chainKey)), ErrorsLib.SenderNotPeer(chainKey, sender));

        (uint8 messageType, bytes memory body) = MessageTypesLib.decode(payload);

        require(!s.received[gateway][receiveId], ErrorsLib.MessageAlreadyReceived(gateway, receiveId));
        s.received[gateway][receiveId] = true;

        if (messageType == MessageTypesLib.SETTLEMENT_NOTIFICATION) {
            MessageTypesLib.SettlementNotification memory notification = MessageTypesLib.decodeSettlement(body);
            _requireExpectedGateway(s, gateway, chainKey, notification.validationId);
            _handleSettlement(chainKey, notification);
        } else if (messageType == MessageTypesLib.BURN_PROOF) {
            _requireCurrentRoute(s, gateway, chainKey);
            _handleBurnProof(chainKey, MessageTypesLib.decodeBurnProof(body));
        } else {
            revert ErrorsLib.MessageTypeNotInbound(messageType);
        }

        emit EventsLib.ProtocolMessageReceived(messageType, chainKey, receiveId);
    }

    /// @dev Acts on a settlement attributed to this token's peer on `chainKey`.
    ///
    /// Left to the inheriting token, because the destination is something only it knows: its bound
    /// compliance, which owns the slot lifecycle.
    function _handleSettlement(bytes32 chainKey, MessageTypesLib.SettlementNotification memory notification)
        internal
        virtual;

    /// @dev Acts on a burn proof attributed to this token's peer on `chainKey`. The token's recall path.
    function _handleBurnProof(bytes32 chainKey, MessageTypesLib.BurnProof memory proof) internal virtual;

    /// @dev Shared by `setTrustedGatewayRegistry` and any deployment-time wiring.
    function _setTrustedGatewayRegistry(address registry) internal {
        require(registry != address(0), ErrorsLib.ZeroAddress());

        _messagingStorage().registry = ITrustedGatewayRegistry(registry);

        emit EventsLib.TrustedGatewayRegistrySet(registry);
    }

    function _setRoute(bytes2 chainType, bytes calldata chainReference, address gateway) internal {
        MessagingStorage storage s = _messagingStorage();
        require(address(s.registry) != address(0), ErrorsLib.RegistryNotSet());

        // The zero gateway is how an issuer closes a chain, so it is the one value not vetted.
        require(gateway == address(0) || s.registry.isTrusted(gateway), ErrorsLib.GatewayNotTrusted(gateway));

        bytes32 chainKey = _registerChain(s, chainType, chainReference);
        s.routes[chainKey] = gateway;

        emit EventsLib.RouteSet(chainKey, gateway);
    }

    function _setPeer(bytes32 chainKey, bytes calldata peer) internal {
        MessagingStorage storage s = _messagingStorage();

        // Empty restores the default; anything else must be a canonical envelope for this very chain.
        if (peer.length > 0) {
            (bytes2 chainType, bytes calldata chainReference, bytes calldata account) =
                InteroperableAddress.parseV1Calldata(peer);

            require(
                account.length > 0 && peer.length == ERC7930_V1_FIXED_LENGTH + chainReference.length + account.length,
                ErrorsLib.InvalidPeer(peer)
            );

            bytes32 peerChainKey = _registerChain(s, chainType, chainReference);
            require(peerChainKey == chainKey, ErrorsLib.PeerChainMismatch(chainKey, peerChainKey));
        }

        s.peers[chainKey] = peer;

        emit EventsLib.PeerSet(chainKey, peer);
    }

    /// @dev Records the prefix behind a chain key the first time it is seen, and returns the key.
    function _registerChain(MessagingStorage storage s, bytes2 chainType, bytes calldata chainReference)
        private
        returns (bytes32 chainKey)
    {
        require(
            chainReference.length > 0 && (chainType != MessageTypesLib.EVM_CHAIN_TYPE || chainReference[0] != 0x00),
            ErrorsLib.InvalidChainReference(chainType, chainReference)
        );

        chainKey = MessageTypesLib.chainKey(chainType, chainReference);

        ChainPrefix storage chain = s.chains[chainKey];
        if (chain.chainReference.length == 0) {
            chain.chainType = chainType;
            chain.chainReference = chainReference;

            emit EventsLib.ChainRegistered(chainKey, chainType, chainReference);
        }
    }

    /// @dev Sends a compliance validation to this token's peer on `chainKey`, pinning the route it took.
    ///
    /// The first dispatch of a validation toward a chain records the gateway; its settlement legs from
    /// that chain are then matched against that gateway alone. A re-dispatch through the same gateway
    /// is allowed, so a lost message can be re-sent.
    function _sendComplianceValidation(bytes32 chainKey, uint256 validationId, bytes memory body)
        internal
        returns (bytes32 sendId)
    {
        MessagingStorage storage s = _messagingStorage();
        (address gateway, bytes memory peer) = _openRoute(s, chainKey);

        address pinned = s.pinnedRoutes[validationId][chainKey];
        if (pinned == address(0)) {
            s.pinnedRoutes[validationId][chainKey] = gateway;

            emit EventsLib.ValidationRoutePinned(validationId, chainKey, gateway);
        } else {
            require(pinned == gateway, ErrorsLib.ValidationAlreadyRouted(validationId, chainKey, pinned));
        }

        sendId = _send(gateway, peer, chainKey, MessageTypesLib.COMPLIANCE_VALIDATION, body);
    }

    /// @dev Sends one protocol message to this token's peer on `chainKey`, through its current route.
    ///
    /// Fail-closed before anything leaves: a registry must be set, the chain must be routed, the routed
    /// gateway must still be trusted at this instant, and the peer must be addressable.
    function _sendMessage(bytes32 chainKey, uint8 messageType, bytes memory body) internal returns (bytes32 sendId) {
        (address gateway, bytes memory peer) = _openRoute(_messagingStorage(), chainKey);

        sendId = _send(gateway, peer, chainKey, messageType, body);
    }

    function _send(address gateway, bytes memory peer, bytes32 chainKey, uint8 messageType, bytes memory body)
        private
        returns (bytes32 sendId)
    {
        sendId = IERC7786GatewaySource(gateway)
            .sendMessage(peer, MessageTypesLib.encode(messageType, body), new bytes[](0));

        emit EventsLib.ProtocolMessageSent(messageType, chainKey, sendId);
    }

    /// @dev Resolves the gateway and peer for `chainKey`
    function _openRoute(MessagingStorage storage s, bytes32 chainKey)
        private
        view
        returns (address gateway, bytes memory peer)
    {
        require(address(s.registry) != address(0), ErrorsLib.RegistryNotSet());

        gateway = s.routes[chainKey];
        require(gateway != address(0) && s.registry.isTrusted(gateway), ErrorsLib.ChainNotOpen(chainKey));

        peer = peerFor(chainKey);
        require(peer.length > 0, ErrorsLib.ChainNotOpen(chainKey));
    }

    /// @dev The pinned gateway when this token dispatched `validationId` toward `chainKey`, else the
    ///  current route. An id this token never dispatched there is not refused here: whether it was
    ///  never issued, or issued from the reference side, is the settlement handler's question.
    function _requireExpectedGateway(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        uint256 validationId
    ) private view {
        address pinned = s.pinnedRoutes[validationId][chainKey];
        if (pinned == address(0)) {
            _requireCurrentRoute(s, gateway, chainKey);
        } else {
            require(pinned == gateway, ErrorsLib.GatewayNotPinned(gateway, validationId, chainKey));
        }
    }

    function _requireCurrentRoute(MessagingStorage storage s, address gateway, bytes32 chainKey) private view {
        require(s.routes[chainKey] == gateway, ErrorsLib.GatewayNotRouted(gateway, chainKey));
    }

    function _messagingStorage() private pure returns (MessagingStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MESSAGING_STORAGE_LOCATION
        }
    }

}
