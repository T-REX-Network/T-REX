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
    function routeFor(bytes32 chainKey) public view returns (address) {
        return TREXMessagingLib.layout().routes[chainKey];
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
    function pinnedRouteFor(uint256 validationId, bytes32 chainKey) public view returns (address) {
        return TREXMessagingLib.layout().pinnedRoutes[validationId][chainKey];
    }

    /// @inheritdoc ITREXMessaging
    function isChainOpen(bytes32 chainKey) public view returns (bool) {
        return TREXMessagingLib.isChainOpen(chainKey);
    }

    /// @dev Whether `gateway` has already delivered `receiveId` to this token.
    function messageReceived(address gateway, bytes32 receiveId) public view returns (bool) {
        return TREXMessagingLib.layout().received[gateway][receiveId];
    }

    /// @inheritdoc ERC7786Recipient
    function _isAuthorizedGateway(address gateway, bytes calldata) internal view override returns (bool) {
        return TREXMessagingLib.layout().registry.isTrusted(gateway);
    }

    /// @inheritdoc ERC7786Recipient
    /// @dev Admission is the library's: attribution to the peer, the replay guard, the expected gateway.
    /// What an admitted message does is the token's, so the hooks are called from here.
    function _processMessage(address gateway, bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        internal
        override
    {
        (MessageTypesLib.Message messageType, bytes32 chainKey, bytes memory body) =
            TREXMessagingLib.acceptMessage(gateway, receiveId, sender, payload);

        // The library admits these two types and reverts on any other.
        if (messageType == MessageTypesLib.Message.SETTLEMENT_NOTIFICATION) {
            _handleSettlement(chainKey, body);
        } else {
            _handleBurnProof(chainKey, body);
        }

        emit EventsLib.ProtocolMessageReceived(messageType, chainKey, receiveId);
    }

    /// @dev Acts on a settlement attributed to this token's peer on `chainKey`.
    ///
    /// Left to the inheriting token, because the destination is something only it knows: its bound
    /// compliance, which owns the slot lifecycle. The body arrives encoded, already known to decode as
    /// a `MessageTypesLib.SettlementNotification`; {TREXMessagingLib-forwardSettlement} delivers it.
    function _handleSettlement(bytes32 chainKey, bytes memory body) internal virtual;

    /// @dev Acts on a burn proof attributed to this token's peer on `chainKey`. The token's recall path.
    /// The body arrives encoded, a `MessageTypesLib.BurnProof`.
    function _handleBurnProof(bytes32 chainKey, bytes memory body) internal virtual;

    /// @dev Called once, from the token's initializer. The registry is the network's and the token
    /// exposes no setter for it, so a token can never resolve trust against a registry of its own.
    function _setTrustedGatewayRegistry(address registry) internal {
        TREXMessagingLib.setTrustedGatewayRegistry(registry);
    }

    function _setRoute(bytes2 chainType, bytes calldata chainReference, address gateway) internal {
        TREXMessagingLib.setRoute(chainType, chainReference, gateway);
    }

    function _setPeer(bytes32 chainKey, bytes calldata peer) internal {
        TREXMessagingLib.setPeer(chainKey, peer);
    }

    /// @dev Sends a compliance validation to this token's peer on `chainKey`, pinning the route it took.
    function _sendComplianceValidation(bytes32 chainKey, uint256 validationId, bytes memory body)
        internal
        returns (bytes32 sendId)
    {
        return TREXMessagingLib.sendComplianceValidation(chainKey, validationId, body);
    }

    /// @dev Sends one protocol message to this token's peer on `chainKey`, through its current route.
    function _sendMessage(bytes32 chainKey, MessageTypesLib.Message messageType, bytes memory body)
        internal
        returns (bytes32 sendId)
    {
        return TREXMessagingLib.sendMessage(chainKey, messageType, body);
    }

}
