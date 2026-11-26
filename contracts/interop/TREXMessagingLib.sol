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

import { IERC7786GatewaySource } from "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { ITickets } from "../compliance/modular/ITickets.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { IReceiptHandler } from "./IReceiptHandler.sol";
import { IReceivingPolicy } from "./IReceivingPolicy.sol";
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

    /// @dev The receipt route and the peer one half left through. A receipt for that half is taken from this
    ///  pair or from the away chain's current one.
    struct Pin {
        address bridge;
        bytes32 peerKey;
    }

    /// @dev The away chain's side of a receipt route: its CCIP selector and the bridge there that sends the
    ///  receipts. The token asks the receipt bridge's receiving policy about exactly this source.
    struct AwayReceiptBridge {
        uint64 chainSelector;
        bytes bridge;
    }

    /// @dev The receipt route and peer an away chain had before a planned change, still taken for every receipt
    ///  until `acceptedUntil`: the away token switches after home, and its receipts sent before it switched arrive
    ///  on this pair. The peer is kept whole so an ask can still reach it, and the away side so the former bridge's
    ///  receiving policy is asked about its own sender.
    struct FormerRoute {
        address bridge;
        uint64 acceptedUntil;
        bytes peer;
        AwayReceiptBridge awayReceiptBridge;
    }

    /// @custom:storage-location erc7201:erc3643.storage.TREXMessaging
    struct MessagingStorage {
        /// The network's record of reviewed bridges this token resolves trust against.
        ITrustedGatewayRegistry registry;

        /// The receipt bridge carrying this token's money messages out and every receipt in, per away chain. Zero
        /// when the route is closed, which only `closeReceiptRoute` does.
        mapping(bytes32 chainKey => address bridge) receiptRoutes;

        /// This token's Lite on each chain, ERC-7930. Empty falls back to the token's own address.
        mapping(bytes32 chainKey => bytes peer) peers;

        /// Transport-level replay guard, for nonzero receive ids. The pinned receiver base keeps no record of its own.
        mapping(address gateway => mapping(bytes32 receiveId => bool)) received;

        /// The prefix each known chain key was derived from, recorded on first sight.
        mapping(bytes32 chainKey => ChainPrefix) chains;

        /// The receipt route and peer each half left through, written when it first leaves and never rewritten.
        mapping(bytes32 halfKey => Pin pin) pins;

        /// The ticket bridge carrying tickets only, per chain, ahead of the chain's finality. Zero sends them on
        /// `receiptRoutes`. Never carries a money message, and never delivers anything to this token.
        mapping(bytes32 chainKey => address bridge) ticketRoutes;

        /// The away side of each receipt route, read back on every receipt to ask the receiving policy again.
        mapping(bytes32 chainKey => AwayReceiptBridge awayReceiptBridge) awayReceiptBridges;

        /// The pair each away chain had before its last planned change of route or peer. Deleted by a hostile change.
        mapping(bytes32 chainKey => FormerRoute formerRoute) formerReceiptRoutes;

        /// Until when asks, ticket sends and cancels for each away chain stay frozen after its peer was replaced as
        /// hostile. The compliance reads it; receipts still land.
        mapping(bytes32 chainKey => uint64 endsAt) hostileChangeEndsAt;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXMessaging")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MESSAGING_STORAGE_LOCATION =
        0x2b7785d97e35cf618b41c256efdda42212baf2d424180e7d549907f2f911e900;

    /// @dev Bytes of an ERC-7930 v1 envelope that are not the chain reference or the account: the
    ///  version, the chain type, and the two length prefixes.
    uint256 private constant ERC7930_V1_FIXED_LENGTH = 6;

    /// @dev The finality a receiving policy names to admit fully finalized messages only: CCIP's
    ///  `WAIT_FOR_FINALITY_FLAG`.
    bytes4 private constant FULL_FINALITY = bytes4(0);

    /// @dev How many waiting times of the away chain a change of route or peer lasts: the former pair is taken that
    ///  long after a planned change, and the away chain is frozen that long after a hostile one.
    uint64 private constant WAITING_TIMES_AFTER_A_CHANGE = 4;

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
        address gateway = s.receiptRoutes[chainKey];

        return gateway != address(0) && s.registry.isReceiptBridge(gateway) && peerFor(chainKey).length > 0;
    }

    /* ----- Configuration ----- */

    /// @dev Called once, from the token's initializer. The registry is the network's and the token
    /// exposes no setter for it, so a token can never resolve trust against a registry of its own.
    function setTrustedGatewayRegistry(address registry) external {
        require(registry != address(0), ErrorsLib.ZeroAddress());

        layout().registry = ITrustedGatewayRegistry(registry);

        emit EventsLib.TrustedGatewayRegistrySet(registry);
    }

    /// @dev See {ITREXMessaging-setReceiptRoute}. Authorization is the caller's.
    function setReceiptRoute(
        bytes2 chainType,
        bytes calldata chainReference,
        address bridge,
        uint64 awayChainSelector,
        bytes calldata awayReceiptBridge
    ) external {
        MessagingStorage storage s = layout();

        // A ticket bridge, a distrusted bridge and zero are all refused here: none is a receipt bridge.
        require(s.registry.isReceiptBridge(bridge), ErrorsLib.NotAReceiptBridge(bridge));
        bytes32 chainKey = _registerChain(s, chainType, chainReference);
        _requireFullFinality(bridge, chainKey, awayChainSelector, awayReceiptBridge);
        _requireNoChangeInsideTheWindow(s, chainKey);

        _keepTheFormerRoute(s, chainKey);
        s.receiptRoutes[chainKey] = bridge;
        AwayReceiptBridge storage awaySide = s.awayReceiptBridges[chainKey];
        awaySide.chainSelector = awayChainSelector;
        awaySide.bridge = awayReceiptBridge;

        emit EventsLib.ReceiptRouteSet(chainKey, bridge, awayChainSelector, awayReceiptBridge);
    }

    /// @dev See {ITREXMessaging-closeReceiptRoute}. Authorization is the caller's.
    function closeReceiptRoute(bytes32 chainKey) external {
        MessagingStorage storage s = layout();
        require(s.receiptRoutes[chainKey] != address(0), ErrorsLib.ChainNotOpen(chainKey));

        delete s.receiptRoutes[chainKey];
        delete s.awayReceiptBridges[chainKey];

        emit EventsLib.ReceiptRouteClosed(chainKey);
    }

    /// @dev See {ITREXMessaging-setTicketRoute}. Authorization is the caller's.
    function setTicketRoute(bytes2 chainType, bytes calldata chainReference, address bridge) external {
        MessagingStorage storage s = layout();

        // A receipt bridge is never a ticket route: a bridge has one record, so it can never carry receipts in
        // for one away chain while it carries tickets ahead of finality for another.
        bool sendsTicketsOnTheReceiptRoute = bridge == address(0);
        bool isTicketBridge = s.registry.isTrusted(bridge) && !s.registry.isReceiptBridge(bridge);
        require(sendsTicketsOnTheReceiptRoute || isTicketBridge, ErrorsLib.NotATicketBridge(bridge));

        bytes32 chainKey = _registerChain(s, chainType, chainReference);
        s.ticketRoutes[chainKey] = bridge;

        emit EventsLib.TicketRouteSet(chainKey, bridge);
    }

    /// @dev See {ITREXMessaging-setPeer}. Authorization is the caller's.
    function setPeer(bytes32 chainKey, bytes calldata peer) external {
        MessagingStorage storage s = layout();
        _requireNoChangeInsideTheWindow(s, chainKey);
        _requireValidPeer(s, chainKey, peer);

        _keepTheFormerRoute(s, chainKey);
        s.peers[chainKey] = peer;

        emit EventsLib.PeerSet(chainKey, peer);
    }

    /// @dev See {ITREXMessaging-replaceHostilePeer}. Authorization is the caller's.
    function replaceHostilePeer(bytes32 chainKey, bytes calldata peer) external {
        MessagingStorage storage s = layout();
        _requireValidPeer(s, chainKey, peer);

        // No former pair: home cannot tell a receipt of the hostile peer from an honest one.
        uint64 endsAt = uint64(block.timestamp) + _changeWindowOf(chainKey);
        delete s.formerReceiptRoutes[chainKey];
        s.hostileChangeEndsAt[chainKey] = endsAt;
        s.peers[chainKey] = peer;

        emit EventsLib.PeerSet(chainKey, peer);
        emit EventsLib.HostilePeerReplaced(chainKey, peer, endsAt);
    }

    /* ----- Outbound ----- */

    /// @dev Sends a ticket to this token's peer on `chainKey`, through the chain's ticket route when one is set and
    /// still trusted, else through its receipt route; pins the half to the receipt route and the peer.
    ///
    /// The chain must be open on its receipt route either way, since that is the route the receipt comes back
    /// through: the first send of a half records the receipt route and the peer, and its receipt is then taken
    /// from that pair, the chain's current one, or its former one inside the window of a planned change, so a later
    /// route or peer change does not strand it. An ask for the receipt goes out through the pinned pair while that
    /// pair is the current one or the former one inside its window, and through the current pair otherwise.
    function sendComplianceValidation(bytes32 chainKey, bytes32 ticketId, bytes memory body)
        external
        returns (bytes32 sendId)
    {
        MessagingStorage storage s = layout();
        (address receiptRoute, bytes memory peer) = _openRoute(s, chainKey);

        // A ticket is the first half of its move.
        Pin storage pin = s.pins[MessageTypesLib.halfKeyOf(ticketId, 0)];
        if (pin.bridge == address(0)) {
            pin.bridge = receiptRoute;
            pin.peerKey = keccak256(peer);

            emit EventsLib.HalfPinned(ticketId, chainKey, receiptRoute);
        } else if (_isTheFormerPairToAsk(s, chainKey, pin)) {
            // The away token that holds the ticket is the one that answers the ask: until the away side switches,
            // that is the former peer, and its answer comes back on the former pair.
            receiptRoute = pin.bridge;
            peer = s.formerReceiptRoutes[chainKey].peer;
        }

        // A ticket moves nothing on its own: sending it ahead of finality risks a ticket the away token executes
        // and this chain then loses to a reorg; the ask mined again takes the same id, and its receipt is applied
        // on older terms, see {IReceiptHandler-receiveReceipt}. A ticket bridge the registry distrusted falls back
        // to the receipt route rather than stranding the ask.
        address ticketRoute = s.ticketRoutes[chainKey];
        bool ticketRouteUsable = ticketRoute != address(0) && s.registry.isTrusted(ticketRoute);
        address sendingGateway = ticketRouteUsable ? ticketRoute : receiptRoute;

        sendId = _send(sendingGateway, peer, chainKey, MessageTypesLib.Message.TICKET, body);
    }

    /// @dev Sends a message for one half of a move on the chain's receipt route, at full finality, and pins the half
    /// to that route and peer at its first send. A half sent again goes to the pair it was pinned to only, while that
    /// pair is still the chain's current one: the away token that holds the half is the one that answers it, so a
    /// send never retargets. A half whose pair was replaced is the compliance's to send again as a new half.
    function sendOnReceiptRoute(
        bytes32 chainKey,
        bytes32 halfKey,
        MessageTypesLib.Message messageType,
        bytes memory body
    ) external returns (bytes32 sendId) {
        MessagingStorage storage s = layout();
        (address receiptRoute, bytes memory peer) = _openRoute(s, chainKey);
        bytes32 peerKey = keccak256(peer);

        Pin storage pin = s.pins[halfKey];
        if (pin.bridge == address(0)) {
            pin.bridge = receiptRoute;
            pin.peerKey = peerKey;

            emit EventsLib.HalfPinned(halfKey, chainKey, receiptRoute);
        } else {
            bool pinnedToTheCurrentPair = pin.bridge == receiptRoute && pin.peerKey == peerKey;
            require(pinnedToTheCurrentPair, ErrorsLib.PeerChanged(chainKey));
        }

        sendId = _send(receiptRoute, peer, chainKey, messageType, body);
    }

    /* ----- Inbound ----- */

    /// @dev Attributes and admits one inbound delivery, and hands back what the token must act on.
    ///
    /// Everything that decides whether a message is accepted happens here: the envelope must decode, a
    /// delivery under a nonzero receive id must be new (and is recorded), the type must be a `RECEIPT`, the only one
    /// a token receives, the author and the bridge must be the ones this message is expected from, and the bridge's
    /// receiving policy must still admit that away chain at full finality only. A receipt comes from the bridge and
    /// peer its half was pinned to, from the chain's current ones, or, inside the window of a planned change, from
    /// its former ones. A blocked away chain is not refused here: its receipts are the compliance's to keep waiting.
    /// Acting on the message is left to the token, since only it knows its compliance. That the bridge is a receipt
    /// bridge is the caller's check, made before this is reached, so a distrusted bridge is refused even when pinned.
    /// @return chainKey The chain the receipt is attributed to.
    /// @return body The still-encoded `ReceiptMessage`.
    function acceptMessage(address gateway, bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        external
        returns (bytes32 chainKey, bytes memory body)
    {
        (bytes2 chainType, bytes calldata chainReference,) = InteroperableAddress.parseV1Calldata(sender);
        chainKey = MessageTypesLib.chainKey(chainType, chainReference);

        MessagingStorage storage s = layout();

        body = _receiptBodyOf(payload);

        // A zero id is a gateway naming no delivery, which ERC-7786 allows; recording it would refuse every later
        // message from that gateway. Its deliveries are still deduplicated by what they carry: a receipt by the hash
        // home keeps per half.
        if (receiveId != bytes32(0)) {
            require(!s.received[gateway][receiveId], ErrorsLib.MessageAlreadyReceived(gateway, receiveId));
            s.received[gateway][receiveId] = true;
        }

        _requireExpectedOrigin(s, gateway, chainKey, sender, _halfKeyOf(body));

        // Everything a token receives reports value that moved, so the bridge must still wait for full finality.
        AwayReceiptBridge storage awaySide = _awaySideOf(s, gateway, chainKey);
        _requireFullFinality(gateway, chainKey, awaySide.chainSelector, awaySide.bridge);
    }

    /// @dev The body of a payload that must be a `RECEIPT`, the only message a token receives.
    function _receiptBodyOf(bytes calldata payload) private pure returns (bytes memory body) {
        MessageTypesLib.Message messageType;
        (messageType, body) = MessageTypesLib.decode(payload);
        require(messageType == MessageTypesLib.Message.RECEIPT, ErrorsLib.MessageTypeNotInbound(messageType));
    }

    /// @dev The half a receipt body answers, see {MessageTypesLib-halfKeyOf}.
    function _halfKeyOf(bytes memory body) private pure returns (bytes32) {
        MessageTypesLib.ReceiptMessage memory receipt = MessageTypesLib.decodeSettlement(body);
        return MessageTypesLib.halfKeyOf(receipt.ticketId, receipt.half);
    }

    /// @dev See {ITREXMessaging-checkReceiptOrigin}: the checks {acceptMessage} ran on the delivery, on the bridge
    ///  and peer the compliance kept, and with the registry and the routes as they are now. The former pair is judged
    ///  at `arrivedAt`: a receipt that came on it inside its window stays applicable after the window ends.
    function checkReceiptOrigin(
        bytes32 chainKey,
        address bridge,
        bytes32 senderPeerKey,
        bytes32 halfKey,
        uint64 arrivedAt
    ) external view {
        MessagingStorage storage s = layout();
        require(s.registry.isReceiptBridge(bridge), ErrorsLib.NotAReceiptBridge(bridge));

        bool fromThePinnedPair = _isFromThePinnedPair(s, bridge, chainKey, senderPeerKey, halfKey);
        bool fromTheFormerPair = _isFromTheFormerPair(s, bridge, chainKey, senderPeerKey, arrivedAt);
        if (!fromThePinnedPair && !fromTheFormerPair) {
            require(senderPeerKey == keccak256(peerFor(chainKey)), ErrorsLib.PeerChanged(chainKey));
            _requireCurrentRoute(s, bridge, chainKey);
        }

        AwayReceiptBridge storage awaySide = _awaySideOf(s, bridge, chainKey);
        _requireFullFinality(bridge, chainKey, awaySide.chainSelector, awaySide.bridge);
    }

    /// @dev Hands an admitted settlement to `handler`, decoded, with the bridge and the peer that delivered it.
    ///
    /// The token calls this from inside its own reentrancy check. Run by DELEGATECALL, so the handler sees the
    /// token as its caller, which is the only caller a compliance accepts.
    /// @param handler The token's bound compliance.
    /// @param body A settlement body, as {acceptMessage} returned it.
    function forwardSettlement(
        address handler,
        bytes32 chainKey,
        address bridge,
        bytes32 senderPeerKey,
        bytes memory body
    ) external {
        IReceiptHandler(handler).receiveReceipt(chainKey, bridge, senderPeerKey, MessageTypesLib.decodeSettlement(body));
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
        gateway = s.receiptRoutes[chainKey];
        require(gateway != address(0) && s.registry.isReceiptBridge(gateway), ErrorsLib.ChainNotOpen(chainKey));

        peer = peerFor(chainKey);
        require(peer.length > 0, ErrorsLib.ChainNotOpen(chainKey));
    }

    /// @dev The pinned bridge and peer of the half the receipt answers, the current ones of the chain it came from,
    ///  or its former ones inside the window of a planned change. A closed chain is refused first, pinned or not:
    ///  closing it stops every receipt from it, and opening the route again lets them be delivered. A half this token
    ///  never sent has no pin and is taken from the current pair: whether it was sent, and to that chain, is the
    ///  receipt handler's question.
    function _requireExpectedOrigin(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        bytes calldata sender,
        bytes32 halfKey
    ) private view {
        bytes32 senderPeerKey = keccak256(sender);
        bool fromThePinnedPair = _isFromThePinnedPair(s, gateway, chainKey, senderPeerKey, halfKey);
        if (fromThePinnedPair) return;
        bool fromTheFormerPair = _isFromTheFormerPair(s, gateway, chainKey, senderPeerKey, uint64(block.timestamp));
        if (fromTheFormerPair) return;

        _requireCurrentPeer(chainKey, sender);
        _requireCurrentRoute(s, gateway, chainKey);
    }

    /// @dev Whether `gateway` and the peer `senderPeerKey` are the pair the half was pinned to. A closed chain is
    ///  refused first, pinned or not.
    function _isFromThePinnedPair(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        bytes32 senderPeerKey,
        bytes32 halfKey
    ) private view returns (bool) {
        require(s.receiptRoutes[chainKey] != address(0), ErrorsLib.ChainNotOpen(chainKey));

        Pin storage pin = s.pins[halfKey];
        return pin.bridge == gateway && pin.peerKey == senderPeerKey;
    }

    function _requireCurrentPeer(bytes32 chainKey, bytes calldata sender) private view {
        require(keccak256(sender) == keccak256(peerFor(chainKey)), ErrorsLib.SenderNotPeer(chainKey, sender));
    }

    /// @dev The receiving policy of `bridge` must admit messages from the away chain's receipt bridge at full
    ///  finality only. A policy that admits less would let a receipt reach home that an away chain reorg can
    ///  still undo, and the token never sees the finality a message used, so it reads the policy itself.
    function _requireFullFinality(
        address bridge,
        bytes32 chainKey,
        uint64 awayChainSelector,
        bytes memory awayReceiptBridge
    ) private view {
        (,,, bytes4 allowedFinality) = IReceivingPolicy(bridge)
            .getCCVsAndFinalityConfig(awayChainSelector, awayReceiptBridge);
        require(allowedFinality == FULL_FINALITY, ErrorsLib.ReceiptBridgeNotFullFinality(bridge, chainKey));
    }

    function _requireCurrentRoute(MessagingStorage storage s, address gateway, bytes32 chainKey) private view {
        require(s.receiptRoutes[chainKey] == gateway, ErrorsLib.BridgeNotOnRoute(gateway, chainKey));
    }

    /// @dev Whether `gateway` and the peer `senderPeerKey` are the away chain's former pair, inside the window of its
    ///  planned change at `arrivedAt`. Taken for every receipt then, whatever pair its half was pinned to.
    function _isFromTheFormerPair(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        bytes32 senderPeerKey,
        uint64 arrivedAt
    ) private view returns (bool) {
        FormerRoute storage former = s.formerReceiptRoutes[chainKey];
        bool sameBridge = former.bridge == gateway;
        bool samePeer = keccak256(former.peer) == senderPeerKey;
        bool insideTheWindow = arrivedAt < former.acceptedUntil;
        return sameBridge && samePeer && insideTheWindow;
    }

    /// @dev Whether an ask for the receipt of the half pinned to `pin` goes to the former pair: the pin is that pair,
    ///  its window still runs, and its bridge is still a receipt bridge, so the answer can land.
    function _isTheFormerPairToAsk(MessagingStorage storage s, bytes32 chainKey, Pin storage pin)
        private
        view
        returns (bool)
    {
        bool pinnedToTheFormerPair = _isFromTheFormerPair(s, pin.bridge, chainKey, pin.peerKey, uint64(block.timestamp));
        return pinnedToTheFormerPair && s.registry.isReceiptBridge(pin.bridge);
    }

    /// @dev The away side to ask `gateway`'s receiving policy about: the former one when the receipt came through the
    ///  former bridge and that bridge is no longer the route, the current one otherwise.
    function _awaySideOf(MessagingStorage storage s, address gateway, bytes32 chainKey)
        private
        view
        returns (AwayReceiptBridge storage)
    {
        FormerRoute storage former = s.formerReceiptRoutes[chainKey];
        bool throughTheFormerBridge = former.bridge == gateway;
        bool formerBridgeReplaced = s.receiptRoutes[chainKey] != gateway;
        if (throughTheFormerBridge && formerBridgeReplaced) return former.awayReceiptBridge;
        return s.awayReceiptBridges[chainKey];
    }

    /// @dev Changes of route or peer on one away chain stay a window apart: a second change would drop the former
    ///  pair while receipts sent on it may still be on their way.
    function _requireNoChangeInsideTheWindow(MessagingStorage storage s, bytes32 chainKey) private view {
        uint64 allowedAt = s.formerReceiptRoutes[chainKey].acceptedUntil;
        require(block.timestamp >= allowedAt, ErrorsLib.RouteChangedTooRecently(chainKey, allowedAt));
    }

    /// @dev Keeps the route and peer an open away chain has now as its former pair, for one window. Home changes
    ///  first: the away token switches after, and the receipts it sent before switching arrive on this pair. A
    ///  closed or never routed chain takes no receipt, so it has nothing to keep.
    function _keepTheFormerRoute(MessagingStorage storage s, bytes32 chainKey) private {
        address currentBridge = s.receiptRoutes[chainKey];
        if (currentBridge == address(0)) return;

        bytes memory currentPeer = peerFor(chainKey);
        uint64 acceptedUntil = uint64(block.timestamp) + _changeWindowOf(chainKey);
        FormerRoute storage former = s.formerReceiptRoutes[chainKey];
        former.bridge = currentBridge;
        former.acceptedUntil = acceptedUntil;
        former.peer = currentPeer;
        former.awayReceiptBridge = s.awayReceiptBridges[chainKey];

        emit EventsLib.FormerRouteKept(chainKey, currentBridge, keccak256(currentPeer), acceptedUntil);
    }

    /// @dev Four waiting times of the away chain, read from the compliance at the change: the compliance owns the
    ///  waiting time, so it is never copied here.
    function _changeWindowOf(bytes32 chainKey) private view returns (uint64) {
        address compliance = address(IERC3643(address(this)).compliance());
        uint64 waitingTime = ITickets(compliance).waitingTimeOf(chainKey);
        return WAITING_TIMES_AFTER_A_CHANGE * waitingTime;
    }

    /// @dev Empty restores the default; anything else must be a canonical envelope for this very chain, whose prefix is
    ///  recorded on first sight. An EVM account is 20 bytes: a gateway reports its sender that way, so any other
    ///  length could never match.
    function _requireValidPeer(MessagingStorage storage s, bytes32 chainKey, bytes calldata peer) private {
        if (peer.length > 0) {
            (bytes2 chainType, bytes calldata chainReference, bytes calldata account) =
                InteroperableAddress.parseV1Calldata(peer);

            bool hasAccount = account.length > 0;
            bool noTrailingBytes = peer.length == ERC7930_V1_FIXED_LENGTH + chainReference.length + account.length;
            bool accountFitsItsChain = chainType != MessageTypesLib.EVM_CHAIN_TYPE || account.length == 20;
            require(hasAccount && noTrailingBytes && accountFitsItsChain, ErrorsLib.InvalidPeer(peer));

            bytes32 peerChainKey = _registerChain(s, chainType, chainReference);
            require(peerChainKey == chainKey, ErrorsLib.PeerChainMismatch(chainKey, peerChainKey));
        } else {
            // Nothing to restore on a chain the token has never seen, and the write would be a noop.
            require(s.chains[chainKey].chainReference.length > 0, ErrorsLib.ChainNotRegistered(chainKey));
        }
    }

}
