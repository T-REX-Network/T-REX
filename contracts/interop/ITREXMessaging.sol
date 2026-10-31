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

import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";

interface ITREXMessaging {

    event TrustedGatewayRegistrySet(address trustedGatewayRegistry);
    event ChainRegistered(bytes32 indexed chainKey, bytes2 chainType, bytes chainReference);
    event RouteSet(bytes32 indexed chainKey, address indexed gateway);
    event PeerSet(bytes32 indexed chainKey, bytes peer);
    event ValidationRoutePinned(bytes32 indexed validationId, bytes32 indexed chainKey, address gateway);
    event ProtocolMessageSent(MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 sendId);
    event InboundPaused(bytes32 indexed chainKey);
    event InboundUnpaused(bytes32 indexed chainKey);
    event BurnProofReceived(
        bytes32 indexed originChainKey, uint256 indexed recallId, bytes burnedWallet, uint256 amount
    );

    error ChainInboundPaused(bytes32 chainKey);
    error ChainNotOpen(bytes32 chainKey);
    error ChainNotRegistered(bytes32 chainKey);
    error GatewayNotRouted(address gateway, bytes32 chainKey);
    error GatewayNotPinned(address gateway, bytes32 validationId, bytes32 chainKey);
    error GatewayNotTrusted(address gateway);
    error InvalidChainReference(bytes2 chainType, bytes chainReference);
    error InvalidPeer(bytes peer);
    error MessageAlreadyReceived(address gateway, bytes32 receiveId);
    error MessageTypeNotInbound(MessageTypesLib.Message messageType);
    error PeerChainMismatch(bytes32 chainKey, bytes32 peerChainKey);
    error SenderNotPeer(bytes32 chainKey, bytes sender);
    error ValidationAlreadyRouted(bytes32 validationId, bytes32 chainKey, address gateway);
    error UnsupportedMessageVersion(uint8 messageVersion);

    error InteroperableAddressParsingError(bytes);
    error InteroperableAddressEmptyReferenceAndAddress();
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /// @dev Routes this token's traffic to and from a chain through `gateway`.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `gateway` must be registry-trusted or zero; otherwise reverts with `GatewayNotTrusted`.
    /// - `chainReference` must be non-empty, with no leading zero byte on EVM; otherwise reverts with
    ///   `InvalidChainReference`.
    ///
    /// Emits `ChainRegistered` on first sight of the prefix, then `RouteSet`.
    /// @param chainType The ERC-7930 chain type, `0x0000` for EVM.
    /// @param chainReference The ERC-7930 chain reference, the minimal big-endian chain id on EVM.
    /// @param gateway The trusted gateway to route through, or zero to close the chain.
    function setRoute(bytes2 chainType, bytes calldata chainReference, address gateway) external;

    /// @dev Registers this token's Lite on `chainKey`: the outbound recipient and the only accepted
    /// inbound author for that chain.
    ///
    /// Only needed off EVM, or when the Lite is not at the token's own address. Empty restores the default.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - A non-empty `peer` must be a canonical ERC-7930 v1 address with an account part and no
    ///   trailing bytes; otherwise reverts with `InvalidPeer`.
    /// - Its chain prefix must hash to `chainKey`; otherwise reverts with `PeerChainMismatch`.
    ///
    /// Emits `ChainRegistered` on first sight of the prefix, then `PeerSet`.
    /// @param chainKey The chain the peer is on.
    /// @param peer The Lite as an ERC-7930 address, or empty to restore the default.
    function setPeer(bytes32 chainKey, bytes calldata peer) external;

    /// @dev Stops taking messages from `chainKey`, or resumes. While paused, every settlement and burn proof
    /// attributed to that chain reverts with `ChainInboundPaused` and stays deliverable, so the chain's reports
    /// wait at the gateway; nothing else on the token is affected, native transfers and every other chain
    /// included. The token sets it on its own when a chain reports a settlement or a burn proof for something
    /// already accounted for, see `ISettlementHandler.Verdict`; lifting it is the pauser's, after an investigation.
    ///
    /// What waits with the chain: a delegation toward it is refused with `ChainInboundPaused`, so no more supply
    /// reaches a chain whose reports are suspect, and the compliance neither issues a validation toward it nor
    /// resends one, nor discards or resolves a validation still awaiting that chain's leg, since the held reports
    /// may answer it. A recall instruction and an instruction resend still go out; the proof that answers a recall
    /// lands once the pause is lifted. To abandon a chain for good, distrust its gateway or close its route, then
    /// lift the pause so its validations can be discarded and resolved.
    ///
    /// Whether a refused delivery can be delivered again is the gateway's: this contract assumes an ERC-7786
    /// gateway that keeps a reverted execution retryable. One that marks it failed for good loses the message,
    /// and its author has to send it again.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - The chain must have been registered by a route or a peer; otherwise reverts with `ChainNotRegistered`.
    ///
    /// Emits `InboundPaused` or `InboundUnpaused` when the state changes; nothing when it does not.
    /// @param chainKey The chain whose messages are refused or taken again.
    /// @param pause True to refuse, false to take again.
    function setInboundPaused(bytes32 chainKey, bool pause) external;

    /// @dev The gateway registry this token resolves trust against. It is the network's, wired at
    /// deployment, and no role on the token can move it: removing a gateway from the registry severs
    /// every route through it, for every token.
    /// @return The registry address.
    function trustedGatewayRegistry() external view returns (address);

    /// @dev The stored route for `chainKey`, not re-validated: the gateway may have been untrusted
    /// since. Use `isChainOpen` to know whether it can carry traffic.
    /// @param chainKey The chain to look up.
    /// @return The routed gateway, or zero when the chain is closed.
    function routeFor(bytes32 chainKey) external view returns (address);

    /// @dev The ERC-7930 prefix recorded for `chainKey`.
    /// @param chainKey The chain to look up.
    /// @return chainType The recorded chain type.
    /// @return chainReference The recorded chain reference, empty when the chain was never seen.
    function chainOf(bytes32 chainKey) external view returns (bytes2 chainType, bytes memory chainReference);

    /// @dev This token's peer on `chainKey`: the registered one, else the token's own address on a
    /// known EVM chain, else empty.
    /// @param chainKey The chain to look up.
    /// @return The peer as an ERC-7930 address, or empty when the chain cannot be addressed.
    function peerFor(bytes32 chainKey) external view returns (bytes memory);

    /// @dev The gateway a validation's leg toward `chainKey` went out through, snapshot at dispatch.
    /// Settlements of that validation from that chain are accepted from this gateway only, so a route
    /// switch affects new validations and never orphans a leg in flight.
    /// @param validationId The validation to look up.
    /// @param chainKey The chain the leg was dispatched toward.
    /// @return The pinned gateway, or zero when the leg never went out.
    function pinnedRouteFor(bytes32 validationId, bytes32 chainKey) external view returns (address);

    /// @dev Whether `chainKey` is routed right now: a route, a peer, and a still-trusted gateway. Re-reads the
    /// registry, so an emergency gateway removal closes every chain routed through it. The inbound pause is a
    /// separate state, see `isInboundPaused`: a paused chain stays open for the instructions that still go out
    /// while its deliveries are refused.
    /// @param chainKey The chain to check.
    /// @return True when the chain has a route, a peer and a trusted gateway.
    function isChainOpen(bytes32 chainKey) external view returns (bool);

    /// @dev Whether messages from `chainKey` are currently refused, see `setInboundPaused`.
    /// @param chainKey The chain to check.
    /// @return True while that chain's inbound is paused.
    function isInboundPaused(bytes32 chainKey) external view returns (bool);

}
