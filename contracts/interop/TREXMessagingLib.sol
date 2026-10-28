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

pragma solidity 0.8.30;

import { IERC7786GatewaySource } from "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { TokenLedgerLib } from "../token/TokenLedgerLib.sol";
import { ISettlementHandler } from "./ISettlementHandler.sol";
import { ITrustedGatewayRegistry } from "./ITrustedGatewayRegistry.sol";

/**
 * @title TREXMessagingLib
 * @dev The body of {TREXMessaging}, deployed once and linked.
 *
 * The messaging layer is envelope parsing, payload decoding and gateway calls: a lot of bytecode that
 * every token would otherwise carry, and that pushed the token past EIP-170. It lives here instead, and
 * the token reaches it by DELEGATECALL, which is what keeps everything the token's:
 *
 * - the storage is the token's own ERC-7201 namespace, at the slot it always had,
 * - `address(this)` is the token, so the default peer is still the token's own address,
 * - the gateway sees the token as `msg.sender`, so the wire still has one author,
 * - events are emitted by the token.
 *
 * Nothing here is an entry point. Who may configure a route, who may dispatch and what an accepted
 * message does are decided by the token, in {TREXMessaging} and its inheritor; this library only
 * carries out what it is handed. Its state-changing functions cannot be called on the library itself.
 */
library TREXMessagingLib {

    /// @dev The ERC-7930 prefix behind a `chainKey`, kept so the token can address its own peer there.
    struct ChainPrefix {
        bytes2 chainType;
        bytes chainReference;
    }

    /// @custom:storage-location erc7201:erc3643.storage.TREXMessaging
    struct MessagingStorage {
        /// The network's vetted gateway set this token resolves trust against.
        ITrustedGatewayRegistry registry;

        /// The gateway carrying this token's traffic, per chain. Zero closes the chain.
        mapping(bytes32 chainKey => address gateway) routes;

        /// This token's Lite on each chain, ERC-7930. Empty falls back to the token's own address.
        mapping(bytes32 chainKey => bytes peer) peers;

        /// Transport-level replay guard, for nonzero receive ids. The pinned receiver base keeps no record of its own.
        mapping(address gateway => mapping(bytes32 receiveId => bool)) received;

        /// The prefix each known chain key was derived from, recorded on first sight.
        mapping(bytes32 chainKey => ChainPrefix) chains;

        /// The gateway each validation leg went out through, snapshot at dispatch and never rewritten.
        mapping(uint256 validationId => mapping(bytes32 chainKey => address gateway)) pinnedRoutes;

        /// `keccak256` of the peer each validation leg was sent to, snapshot with its gateway.
        mapping(uint256 validationId => mapping(bytes32 chainKey => bytes32 peerKey)) pinnedPeers;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXMessaging")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MESSAGING_STORAGE_LOCATION =
        0x2b7785d97e35cf618b41c256efdda42212baf2d424180e7d549907f2f911e900;

    /// @dev Bytes of an ERC-7930 v1 envelope that are not the chain reference or the account: the
    ///  version, the chain type, and the two length prefixes.
    uint256 private constant ERC7930_V1_FIXED_LENGTH = 6;

    /* ----- Views ----- */

    /// @dev See {ITREXMessaging-chainOf}.
    function chainOf(bytes32 chainKey) external view returns (bytes2 chainType, bytes memory chainReference) {
        ChainPrefix storage chain = layout().chains[chainKey];
        return (chain.chainType, chain.chainReference);
    }

    /// @dev See {ITREXMessaging-peerFor}.
    function peerFor(bytes32 chainKey) public view returns (bytes memory) {
        MessagingStorage storage s = layout();

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

    /// @dev See {ITREXMessaging-isChainOpen}.
    function isChainOpen(bytes32 chainKey) external view returns (bool) {
        MessagingStorage storage s = layout();
        address gateway = s.routes[chainKey];

        return gateway != address(0) && s.registry.isTrusted(gateway) && peerFor(chainKey).length > 0;
    }

    /* ----- Configuration ----- */

    /// @dev Called once, from the token's initializer. The registry is the network's and the token
    /// exposes no setter for it, so a token can never resolve trust against a registry of its own.
    function setTrustedGatewayRegistry(address registry) external {
        require(registry != address(0), ErrorsLib.ZeroAddress());

        layout().registry = ITrustedGatewayRegistry(registry);

        emit EventsLib.TrustedGatewayRegistrySet(registry);
    }

    /// @dev See {ITREXMessaging-setRoute}. Authorization is the caller's.
    function setRoute(bytes2 chainType, bytes calldata chainReference, address gateway) external {
        MessagingStorage storage s = layout();

        // The zero gateway is how an issuer closes a chain, so it is the one value not vetted.
        require(gateway == address(0) || s.registry.isTrusted(gateway), ErrorsLib.GatewayNotTrusted(gateway));

        bytes32 chainKey = _registerChain(s, chainType, chainReference);
        s.routes[chainKey] = gateway;

        emit EventsLib.RouteSet(chainKey, gateway);
    }

    /// @dev See {ITREXMessaging-setPeer}. Authorization is the caller's.
    function setPeer(bytes32 chainKey, bytes calldata peer) external {
        MessagingStorage storage s = layout();

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
        } else {
            // Nothing to restore on a chain the token has never seen, and the write would be a noop.
            require(s.chains[chainKey].chainReference.length > 0, ErrorsLib.ChainNotRegistered(chainKey));
        }

        s.peers[chainKey] = peer;

        emit EventsLib.PeerSet(chainKey, peer);
    }

    /* ----- Outbound ----- */

    /// @dev Sends a compliance validation to this token's peer on `chainKey`, pinning the route it took.
    ///
    /// The first dispatch of a validation toward a chain records the gateway and the peer; its settlement
    /// legs from that chain are then matched against those alone, so a later peer change does not strand
    /// them. A re-dispatch through the same gateway to the same peer is allowed, so a lost message can be
    /// re-sent.
    function sendComplianceValidation(bytes32 chainKey, uint256 validationId, bytes memory body)
        external
        returns (bytes32 sendId)
    {
        MessagingStorage storage s = layout();
        (address gateway, bytes memory peer) = _openRoute(s, chainKey);

        address pinned = s.pinnedRoutes[validationId][chainKey];
        if (pinned == address(0)) {
            s.pinnedRoutes[validationId][chainKey] = gateway;
            s.pinnedPeers[validationId][chainKey] = keccak256(peer);

            emit EventsLib.ValidationRoutePinned(validationId, chainKey, gateway);
        } else {
            require(
                pinned == gateway && s.pinnedPeers[validationId][chainKey] == keccak256(peer),
                ErrorsLib.ValidationAlreadyRouted(validationId, chainKey, pinned)
            );
        }

        sendId = _send(gateway, peer, chainKey, MessageTypesLib.Message.COMPLIANCE_VALIDATION, body);
    }

    /// @dev Sends one protocol message to this token's peer on `chainKey`, through its current route.
    ///
    /// Fail-closed before anything leaves: a registry must be set, the chain must be routed, the routed
    /// gateway must still be trusted at this instant, and the peer must be addressable.
    function sendMessage(bytes32 chainKey, MessageTypesLib.Message messageType, bytes memory body)
        external
        returns (bytes32 sendId)
    {
        (address gateway, bytes memory peer) = _openRoute(layout(), chainKey);

        sendId = _send(gateway, peer, chainKey, messageType, body);
    }

    /* ----- Inbound ----- */

    /// @dev Attributes and admits one inbound delivery, and hands back what the token must act on.
    ///
    /// Everything that decides whether a message is accepted happens here: the envelope must decode, a
    /// delivery under a nonzero receive id must be new (and is recorded), the type must be one a token receives,
    /// and the author and the gateway must be the ones this message is expected from. A settlement comes from
    /// the peer and gateway its validation was pinned to, or the current ones for an id this token never
    /// dispatched; a burn proof for a recall still open comes from the peer and gateway that recall was
    /// dispatched to, so a later route or peer change cannot strand it, and any other burn proof from the current
    /// peer and route. Acting on the message is left to the token, since only it knows its compliance and its
    /// pause. The gateway's trust is the caller's check, made before this is reached, so a gateway the registry
    /// no longer trusts is refused even when pinned.
    /// @return messageType `SETTLEMENT_NOTIFICATION` or `BURN_PROOF`; anything else reverts.
    /// @return chainKey The chain the message is attributed to.
    /// @return body The still-encoded body, of the type `messageType` names.
    function acceptMessage(address gateway, bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        external
        returns (MessageTypesLib.Message messageType, bytes32 chainKey, bytes memory body)
    {
        (bytes2 chainType, bytes calldata chainReference,) = InteroperableAddress.parseV1Calldata(sender);
        chainKey = MessageTypesLib.chainKey(chainType, chainReference);

        MessagingStorage storage s = layout();

        (messageType, body) = MessageTypesLib.decode(payload);

        // A zero id is a gateway naming no delivery, which ERC-7786 allows; recording it would refuse every later
        // message from that gateway. Its deliveries are still deduplicated by what they carry: a settlement by
        // its validation's status, a burn proof by its recall and the hash of the proof that settled it.
        if (receiveId != bytes32(0)) {
            require(!s.received[gateway][receiveId], ErrorsLib.MessageAlreadyReceived(gateway, receiveId));
            s.received[gateway][receiveId] = true;
        }

        if (messageType == MessageTypesLib.Message.SETTLEMENT_NOTIFICATION) {
            _requireExpectedOrigin(s, gateway, chainKey, sender, MessageTypesLib.decodeSettlement(body).validationId);
        } else if (messageType == MessageTypesLib.Message.BURN_PROOF) {
            _requireRecallOrigin(s, gateway, chainKey, sender, MessageTypesLib.decodeBurnProof(body).recallId);
        } else {
            revert ErrorsLib.MessageTypeNotInbound(messageType);
        }
    }

    /// @dev Hands an admitted settlement to `handler`, decoded, and reports whether the token must halt.
    ///
    /// The token calls this from inside its own pause and reentrancy checks. Run by DELEGATECALL, so
    /// the handler sees the token as its caller, which is the only caller a compliance accepts.
    /// @param handler The token's bound compliance.
    /// @param body A settlement body, as {acceptMessage} returned it.
    /// @return halt Whether the handler reported a replayed or never-issued settlement.
    function forwardSettlement(address handler, bytes32 chainKey, bytes memory body) external returns (bool halt) {
        return ISettlementHandler(handler).handleSettlement(chainKey, MessageTypesLib.decodeSettlement(body));
    }

    /* ----- Storage ----- */

    /// @dev The token's messaging namespace. Internal, so the cheap reads stay in the token itself.
    function layout() internal pure returns (MessagingStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MESSAGING_STORAGE_LOCATION
        }
    }

    /* ----- Private ----- */

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

    function _send(
        address gateway,
        bytes memory peer,
        bytes32 chainKey,
        MessageTypesLib.Message messageType,
        bytes memory body
    ) private returns (bytes32 sendId) {
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
        gateway = s.routes[chainKey];
        require(gateway != address(0) && s.registry.isTrusted(gateway), ErrorsLib.ChainNotOpen(chainKey));

        peer = peerFor(chainKey);
        require(peer.length > 0, ErrorsLib.ChainNotOpen(chainKey));
    }

    /// @dev The pinned peer and gateway when this token dispatched `validationId` toward `chainKey`, else
    ///  the current ones. A closed chain is refused first, pinned or not: closing it stops every settlement
    ///  from it, and reopening the route lets them be delivered again. An id this token never dispatched
    ///  there is not refused here: whether it was never issued, or issued from the reference side, is the
    ///  settlement handler's question.
    function _requireExpectedOrigin(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        bytes calldata sender,
        uint256 validationId
    ) private view {
        require(s.routes[chainKey] != address(0), ErrorsLib.ChainNotOpen(chainKey));

        address pinned = s.pinnedRoutes[validationId][chainKey];
        if (pinned == address(0)) {
            _requireCurrentPeer(chainKey, sender);
            _requireCurrentRoute(s, gateway, chainKey);
            return;
        }
        require(keccak256(sender) == s.pinnedPeers[validationId][chainKey], ErrorsLib.SenderNotPeer(chainKey, sender));
        require(pinned == gateway, ErrorsLib.GatewayNotPinned(gateway, validationId, chainKey));
    }

    function _requireCurrentPeer(bytes32 chainKey, bytes calldata sender) private view {
        require(keccak256(sender) == keccak256(peerFor(chainKey)), ErrorsLib.SenderNotPeer(chainKey, sender));
    }

    /// @dev The peer and gateway the recall was dispatched to while it is open; the current ones once it is not,
    ///  so a settled or never-issued id still reaches the token's duplicate and replay handling.
    function _requireRecallOrigin(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        bytes calldata sender,
        uint256 recallId
    ) private view {
        TokenLedgerLib.PendingRecall storage recall = TokenLedgerLib.layout().recalls[recallId];
        if (recall.amount == 0) {
            _requireCurrentPeer(chainKey, sender);
            _requireCurrentRoute(s, gateway, chainKey);
            return;
        }
        require(keccak256(sender) == recall.peerKey, ErrorsLib.SenderNotPeer(chainKey, sender));
        require(recall.gateway == gateway, ErrorsLib.GatewayNotPinned(gateway, recallId, chainKey));
    }

    function _requireCurrentRoute(MessagingStorage storage s, address gateway, bytes32 chainKey) private view {
        require(s.routes[chainKey] == gateway, ErrorsLib.GatewayNotRouted(gateway, chainKey));
    }

}
