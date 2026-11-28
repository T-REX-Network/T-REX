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

import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";

interface ITREXMessaging {

    event TrustedGatewayRegistrySet(address trustedGatewayRegistry);
    event ChainRegistered(bytes32 indexed chainKey, bytes2 chainType, bytes chainReference);
    event ReceiptRouteSet(
        bytes32 indexed chainKey, address indexed bridge, uint64 awayChainSelector, bytes awayReceiptBridge
    );
    event ReceiptRouteClosed(bytes32 indexed chainKey);
    event TicketRouteSet(bytes32 indexed chainKey, address indexed gateway);
    event PeerSet(bytes32 indexed chainKey, bytes peer);
    event HalfPinned(bytes32 indexed halfKey, bytes32 indexed chainKey, address gateway);
    event ProtocolMessageSent(MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 sendId);

    error AwayChainBlocked(bytes32 chainKey);
    error ChainNotOpen(bytes32 chainKey);
    error ChainNotRegistered(bytes32 chainKey);
    error BridgeNotOnRoute(address gateway, bytes32 chainKey);
    error NotAReceiptBridge(address bridge);
    error BridgeNotTrusted(address gateway);
    error WrongFinality(address bridge, bytes32 chainKey);
    error InvalidChainReference(bytes2 chainType, bytes chainReference);
    error InvalidPeer(bytes peer);
    error MessageAlreadyReceived(address gateway, bytes32 receiveId);
    error MessageTypeNotInbound(MessageTypesLib.Message messageType);
    error PeerChainMismatch(bytes32 chainKey, bytes32 peerChainKey);
    error SenderNotPeer(bytes32 chainKey, bytes sender);
    error UnsupportedMessageVersion(uint8 messageVersion);

    error InteroperableAddressParsingError(bytes);
    error InteroperableAddressEmptyReferenceAndAddress();
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /// @dev Sets the receipt route of an away chain: the receipt bridge that carries this token's money messages
    /// (move out, bring home) to that chain at full finality, and every receipt from it into this token.
    ///
    /// The token asks `bridge` for its receiving policy toward the away chain's receipt bridge, here and again on
    /// every receipt `bridge` delivers, whichever pair the receipt came on, and requires full finality: on CCIP the sending bridge picks a message's finality and only
    /// the receiving policy checks it, so the token reads that policy rather than a label. A receipt route is
    /// never set to zero; `closeReceiptRoute` closes it. Changing the bridge is one call to this setter.
    ///
    /// A change of an open route is a planned change, made on home first: the route and peer the chain had are kept
    /// as its former pair and taken for every receipt during four waiting times of the away chain (read from the
    /// compliance), so the receipts the away token sends before it switches still land. A second change inside that
    /// window drops the older pair: changes are planned at least four waiting times apart, which the token does not
    /// check.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `bridge` must be trusted by the registry at depth zero; otherwise reverts with `NotAReceiptBridge`. A bridge
    ///   at another depth, a distrusted bridge and zero all fail this.
    /// - `chainReference` must be non-empty, with no leading zero byte on EVM; otherwise reverts with
    ///   `InvalidChainReference`.
    /// - The receiving policy of `bridge` for `awayChainSelector` and `awayReceiptBridge` must admit full finality
    ///   only; otherwise reverts with `WrongFinality`.
    ///
    /// Emits `ChainRegistered` on first sight of the prefix, then `ReceiptRouteSet`.
    /// @param chainType The ERC-7930 chain type, `0x0000` for EVM.
    /// @param chainReference The ERC-7930 chain reference, the minimal big-endian chain id on EVM.
    /// @param bridge The receipt bridge on this chain.
    /// @param awayChainSelector The away chain's CCIP selector, as `bridge`'s receiving policy knows it.
    /// @param awayReceiptBridge The bridge on the away chain that sends the receipts, as CCIP reports the sender
    /// (`abi.encode(address)` on EVM).
    function setReceiptRoute(
        bytes2 chainType,
        bytes calldata chainReference,
        address bridge,
        uint64 awayChainSelector,
        bytes calldata awayReceiptBridge
    ) external;

    /// @dev Closes the receipt route of `chainKey`: nothing is sent to that away chain and no receipt is taken from
    /// it, receipts of halves already sent included, until a receipt route is set again. While it is closed no
    /// ticket toward that chain is cancelled, since its receipt may still be on its way; close by hand stays the
    /// way out.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Closing a route already closed changes nothing and emits again. Emits `ReceiptRouteClosed`.
    /// @param chainKey The away chain whose receipt route is closed.
    function closeReceiptRoute(bytes32 chainKey) external;

    /// @dev Sets the ticket route of an away chain: a ticket bridge that relays tickets ahead of that chain's
    /// finality, while everything else keeps the receipt route.
    ///
    /// The two routes of a chain split its traffic by what a reorg can cost:
    /// - the ticket route carries tickets out, and only tickets. A ticket moves nothing on its own.
    /// - the receipt route carries money messages out and is the only route receipts are taken from. The token
    ///   takes deliveries from receipt bridges, trusted at depth zero, only.
    ///
    /// A ticket goes out on the ticket route when it is set and still trusted, otherwise on the receipt route.
    /// The chain must be open on its receipt route either way, and the half is pinned to that receipt route,
    /// which its receipt must come back through (see `pinOf`). The away token on that chain must therefore send
    /// its receipts through its receipt route, not back through the bridge that delivered the ticket.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `bridge` must be trusted by the registry, or zero; otherwise reverts with `BridgeNotTrusted`. Its depth is
    ///   not checked: a ticket moves nothing on its own.
    /// - `chainReference` must be non-empty, with no leading zero byte on EVM; otherwise reverts with
    ///   `InvalidChainReference`.
    ///
    /// Emits `ChainRegistered` on first sight of the prefix, then `TicketRouteSet`.
    /// @param chainType The ERC-7930 chain type, `0x0000` for EVM.
    /// @param chainReference The ERC-7930 chain reference, the minimal big-endian chain id on EVM.
    /// @param bridge The ticket bridge to send tickets through, or zero to send them on the receipt route.
    function setTicketRoute(bytes2 chainType, bytes calldata chainReference, address bridge) external;

    /// @dev Registers this token's Lite on `chainKey`: the outbound recipient and the only accepted
    /// inbound author for that chain.
    ///
    /// Only needed off EVM, or when the Lite is not at the token's own address. Empty restores the default.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - A non-empty `peer` must be a canonical ERC-7930 v1 address with an account part, 20 bytes on EVM,
    ///   and no trailing bytes; otherwise reverts with `InvalidPeer`.
    /// - Its chain prefix must hash to `chainKey`; otherwise reverts with `PeerChainMismatch`.
    ///
    /// A planned change, made on home first. A half already sent keeps its receipt accepted from the peer it was
    /// sent to, as well as from the new one; while the route is open, the former peer is also taken for every receipt
    /// during four waiting times of the away chain. What is sent after the change goes to the new peer.
    ///
    /// A swap that replaces a hostile peer keeps no former pair, a former pair of an earlier planned change included:
    /// home cannot tell a receipt of the hostile peer from an honest one. For four waiting times of the away chain the
    /// compliance takes no ask, sends no ticket, asks for no receipt and cancels nothing for it, so an honest receipt
    /// still on the old pair cannot be beaten by a cancel; receipts still land.
    ///
    /// Emits `ChainRegistered` on first sight of the prefix, then `PeerSet`.
    /// @param chainKey The chain the peer is on.
    /// @param peer The Lite as an ERC-7930 address, or empty to restore the default.
    /// @param replacesAHostilePeer Whether the peer replaced is hostile.
    function setPeer(bytes32 chainKey, bytes calldata peer, bool replacesAHostilePeer) external;

    /// @dev Until when asks, ticket sends and cancels for `chainKey` stay frozen after its peer was replaced as
    /// hostile: four of the chain's waiting times after the change, the waiting time read as it is now. The
    /// compliance reads it. Frozen while the time is before it.
    /// @param chainKey The away chain to look up.
    /// @return The end of the freeze, or zero when the peer was never replaced as hostile.
    function hostileChangeEndsAt(bytes32 chainKey) external view returns (uint64);

    /// @dev The bridge registry this token resolves trust against. It is the network's, wired at
    /// deployment, and no role on the token can move it: distrusting a bridge in the registry severs
    /// every route through it, for every token.
    /// @return The registry address.
    function trustedGatewayRegistry() external view returns (address);

    /// @dev The stored receipt route for `chainKey`, not re-validated: the bridge may have been distrusted
    /// since. Use `isChainOpen` to know whether it can carry traffic.
    /// @param chainKey The chain to look up.
    /// @return The receipt bridge, or zero when the route is closed.
    function receiptRouteFor(bytes32 chainKey) external view returns (address);

    /// @dev The stored ticket route for `chainKey`, not re-validated against the registry.
    /// @param chainKey The chain to look up.
    /// @return The ticket bridge tickets go out through, or zero when they use the receipt route.
    function ticketRouteFor(bytes32 chainKey) external view returns (address);

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

    /// @dev The receipt route and the peer a half left through, written when it first left, even when the ticket
    /// itself travelled on the ticket route. Its receipt is accepted from this pair, from the chain's current one,
    /// or from the chain's former one during the window of a planned change.
    /// @param halfKey The half to look up, see {MessageTypesLib-halfKeyOf}: the ticket id itself for the ticket,
    /// the first half of its move.
    /// @return bridge The pinned receipt bridge, or zero when the half never left.
    /// @return peerKey The `keccak256` of the peer the half was sent to.
    function pinOf(bytes32 halfKey) external view returns (address bridge, bytes32 peerKey);

    /// @dev Whether `chainKey` is routed right now: a receipt route, a peer, and a bridge still trusted at depth zero.
    /// Re-reads the registry, so distrusting a bridge, or setting its depth above zero, closes every chain routed
    /// through it. A blocked
    /// away chain is the compliance's, see `ITickets.isAwayChainBlocked`, and stays open here.
    /// @param chainKey The chain to check.
    /// @return True when the chain has a receipt route, a peer and a receipt bridge.
    function isChainOpen(bytes32 chainKey) external view returns (bool);

    /// @dev Runs the route check a receipt passes at delivery again, for a receipt the compliance kept waiting:
    /// `bridge` must still be trusted by the network at depth zero, the away chain's receipt route must be open, the
    /// pair must be the one the half was pinned to, the chain's current route and peer, or its former ones as long as
    /// the receipt arrived inside the window of their planned change, and the bridge's receiving policy must still
    /// admit that away chain at full finality only. A change of route or peer does not refuse a receipt from its
    /// half's pinned pair, nor one from the former pair that arrived inside its window. A distrusted bridge or a
    /// closed route refuses it; so does, for a pair neither pinned nor former, a current route or peer that differs.
    ///
    /// Reverts with `NotAReceiptBridge`, `ChainNotOpen`, `PeerChanged`, `BridgeNotOnRoute` or
    /// `WrongFinality`; returns nothing when the receipt may be applied.
    /// @param chainKey The away chain the receipt came from.
    /// @param bridge The bridge that delivered it.
    /// @param senderPeerKey The `keccak256` of the peer that sent it.
    /// @param halfKey The half it answers, see {MessageTypesLib-halfKeyOf}.
    /// @param arrivedAt When it was delivered: the former pair is taken if its window still ran then.
    function checkReceiptOrigin(
        bytes32 chainKey,
        address bridge,
        bytes32 senderPeerKey,
        bytes32 halfKey,
        uint64 arrivedAt
    ) external view;

}
