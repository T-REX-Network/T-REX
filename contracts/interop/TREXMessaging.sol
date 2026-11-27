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

// T-REX Smart Contracts
// The ERC-3643 token suite of the T-REX ecosystem.
//
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.30;

import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";

import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { ITREXMessaging } from "./ITREXMessaging.sol";
import { TREXMessagingLib } from "./TREXMessagingLib.sol";

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
 *
 * The work itself is in {TREXMessagingLib}, a linked library run by DELEGATECALL, so the token does not
 * carry that bytecode and stays under EIP-170. The token is still the recipient, the sender the gateway
 * sees, the owner of the storage and the emitter of every event; what stays in this contract is what
 * must be the token's own: the entry point, the hooks, and the reads cheap enough not to be worth a call.
 */
abstract contract TREXMessaging is ITREXMessaging, ERC7786Recipient {

    /// @inheritdoc ITREXMessaging
    function trustedGatewayRegistry() public view returns (address) {
        return address(TREXMessagingLib.layout().registry);
    }

    /// @inheritdoc ITREXMessaging
    function receiptRouteFor(bytes32 chainKey) public view returns (address) {
        return TREXMessagingLib.layout().receiptRoutes[chainKey];
    }

    /// @inheritdoc ITREXMessaging
    function ticketRouteFor(bytes32 chainKey) public view returns (address) {
        return TREXMessagingLib.layout().ticketRoutes[chainKey];
    }

    /// @inheritdoc ITREXMessaging
    function chainOf(bytes32 chainKey) public view returns (bytes2 chainType, bytes memory chainReference) {
        return TREXMessagingLib.chainOf(chainKey);
    }

    /// @inheritdoc ITREXMessaging
    function peerFor(bytes32 chainKey) public view returns (bytes memory) {
        return TREXMessagingLib.peerFor(chainKey);
    }

    /// @inheritdoc ITREXMessaging
    function pinOf(bytes32 halfKey) public view returns (address bridge, bytes32 peerKey) {
        TREXMessagingLib.Pin storage pin = TREXMessagingLib.layout().pins[halfKey];
        return (pin.bridge, pin.peerKey);
    }

    /// @inheritdoc ITREXMessaging
    function hostileChangeEndsAt(bytes32 chainKey) public view returns (uint64) {
        return TREXMessagingLib.layout().hostileChangeEndsAt[chainKey];
    }

    /// @inheritdoc ITREXMessaging
    function isChainOpen(bytes32 chainKey) public view returns (bool) {
        return TREXMessagingLib.isChainOpen(chainKey);
    }

    /// @inheritdoc ITREXMessaging
    function checkReceiptOrigin(
        bytes32 chainKey,
        address bridge,
        bytes32 senderPeerKey,
        bytes32 halfKey,
        uint64 arrivedAt
    ) external view {
        TREXMessagingLib.checkReceiptOrigin(chainKey, bridge, senderPeerKey, halfKey, arrivedAt);
    }

    /// @dev Whether `gateway` has already delivered `receiveId` to this token. Always false for a zero id, which
    ///  names no delivery and is never recorded.
    function messageReceived(address gateway, bytes32 receiveId) public view returns (bool) {
        return TREXMessagingLib.layout().received[gateway][receiveId];
    }

    /// @inheritdoc ERC7786Recipient
    /// @dev Everything a token receives reports value that moved, so only a receipt bridge, trusted at depth zero,
    ///  delivers to it. A ticket bridge relays before finality and is refused here, whichever away chain it serves.
    ///  The refusal reverts with OpenZeppelin's `ERC7786RecipientUnauthorizedGateway`: it is the design's
    ///  `WrongRoute`, and the message stays deliverable through a receipt bridge.
    function _isAuthorizedGateway(address gateway, bytes calldata) internal view override returns (bool) {
        return TREXMessagingLib.isReceiptBridge(gateway);
    }

    /// @inheritdoc ERC7786Recipient
    /// @dev Admission is the library's: attribution to the peer, the replay guard, the expected gateway.
    /// What an admitted message does is the token's, so the hook is called from here. A receipt, the only message a
    /// token receives, is handed on with the bridge and the peer that delivered it, so the compliance can keep it
    /// waiting and check that route again when it is applied later.
    function _processMessage(address gateway, bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        internal
        override
    {
        (bytes32 chainKey, bytes memory body) = TREXMessagingLib.acceptMessage(gateway, receiveId, sender, payload);

        _handleSettlement(chainKey, gateway, keccak256(sender), body);

        emit EventsLib.ProtocolMessageReceived(MessageTypesLib.Message.RECEIPT, chainKey, receiveId);
    }

    /// @dev Acts on a settlement attributed to this token's peer on `chainKey`, delivered by `bridge` from the peer
    /// whose `keccak256` is `senderPeerKey`.
    ///
    /// Left to the inheriting token, because the destination is something only it knows: its bound
    /// compliance, which owns the slot lifecycle. The body arrives encoded, already known to decode as
    /// a `MessageTypesLib.ReceiptMessage`; {TREXMessagingLib-forwardSettlement} delivers it.
    function _handleSettlement(bytes32 chainKey, address bridge, bytes32 senderPeerKey, bytes memory body)
        internal
        virtual;

    /// @dev Called once, from the token's initializer. The registry is the network's and the token
    /// exposes no setter for it, so a token can never resolve trust against a registry of its own.
    function _setTrustedGatewayRegistry(address registry) internal {
        TREXMessagingLib.setTrustedGatewayRegistry(registry);
    }

    function _setReceiptRoute(
        bytes2 chainType,
        bytes calldata chainReference,
        address bridge,
        uint64 awayChainSelector,
        bytes calldata awayReceiptBridge
    ) internal {
        TREXMessagingLib.setReceiptRoute(chainType, chainReference, bridge, awayChainSelector, awayReceiptBridge);
    }

    function _closeReceiptRoute(bytes32 chainKey) internal {
        TREXMessagingLib.closeReceiptRoute(chainKey);
    }

    function _setTicketRoute(bytes2 chainType, bytes calldata chainReference, address bridge) internal {
        TREXMessagingLib.setTicketRoute(chainType, chainReference, bridge);
    }

    function _setPeer(bytes32 chainKey, bytes calldata peer) internal {
        TREXMessagingLib.setPeer(chainKey, peer);
    }

    function _replaceHostilePeer(bytes32 chainKey, bytes calldata peer) internal {
        TREXMessagingLib.replaceHostilePeer(chainKey, peer);
    }

    /// @dev Sends a ticket to this token's peer on `chainKey`, on its ticket route when set, pinning the half to
    /// its receipt route and peer.
    function _sendComplianceValidation(bytes32 chainKey, bytes32 ticketId, bytes memory body)
        internal
        returns (bytes32 sendId)
    {
        return TREXMessagingLib.sendComplianceValidation(chainKey, ticketId, body);
    }

}
