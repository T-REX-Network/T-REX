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

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { TokenLedgerLib } from "../token/TokenLedgerLib.sol";
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

        /// Chains whose messages are refused, and left deliverable, until the pauser lifts it.
        mapping(bytes32 chainKey => bool paused) inboundPaused;

        /// The ticket bridge carrying tickets only, per chain, ahead of the chain's finality. Zero sends them on
        /// `receiptRoutes`. Never carries a money message, and never delivers anything to this token.
        mapping(bytes32 chainKey => address bridge) ticketRoutes;

        /// The away side of each receipt route, read back on every receipt to ask the receiving policy again.
        mapping(bytes32 chainKey => AwayReceiptBridge awayReceiptBridge) awayReceiptBridges;
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

        // Empty restores the default; anything else must be a canonical envelope for this very chain. An EVM
        // account is 20 bytes: a gateway reports its sender that way, so any other length could never match.
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

        s.peers[chainKey] = peer;

        emit EventsLib.PeerSet(chainKey, peer);
    }

    /// @dev See {ITREXMessaging-setInboundPaused}. Authorization is the caller's. Idempotent: the same state again
    /// changes nothing and emits nothing. A chain registered by a route or a peer is never deregistered, and a
    /// message is attributed only to a registered chain, so the token's own call on a verdict never meets the
    /// registration refusal; it is there for a pauser's typo.
    function setInboundPaused(bytes32 chainKey, bool pause) external {
        MessagingStorage storage s = layout();
        require(s.chains[chainKey].chainReference.length > 0, ErrorsLib.ChainNotRegistered(chainKey));
        if (s.inboundPaused[chainKey] == pause) return;
        s.inboundPaused[chainKey] = pause;
        if (pause) emit EventsLib.InboundPaused(chainKey);
        else emit EventsLib.InboundUnpaused(chainKey);
    }

    /* ----- Outbound ----- */

    /// @dev Sends a ticket to this token's peer on `chainKey`, through the chain's ticket route when one is set and
    /// still trusted, else through its receipt route; pins the half to the receipt route and the peer.
    ///
    /// The chain must be open on its receipt route either way, since that is the route the receipt comes back
    /// through: the first send of a half records the receipt route and the peer, and its receipt is then taken
    /// from that pair or from the chain's current one, so a later route or peer change does not strand it. Sending
    /// again is allowed while the receipt route and the peer are still the pinned ones, so a lost message can be
    /// sent again.
    function sendComplianceValidation(bytes32 chainKey, bytes32 ticketId, bytes memory body)
        external
        returns (bytes32 sendId)
    {
        MessagingStorage storage s = layout();
        (address receiptRoute, bytes memory peer) = _openRoute(s, chainKey);

        // A ticket is the first half of its move.
        Pin storage pin = s.pins[MessageTypesLib.halfKeyOf(ticketId, 0)];
        bytes32 peerKey = keccak256(peer);
        if (pin.bridge == address(0)) {
            pin.bridge = receiptRoute;
            pin.peerKey = peerKey;

            emit EventsLib.HalfPinned(ticketId, chainKey, receiptRoute);
        } else {
            bool sameReceiptRoute = pin.bridge == receiptRoute;
            bool samePeer = pin.peerKey == peerKey;
            require(sameReceiptRoute, ErrorsLib.ValidationAlreadyRouted(ticketId, chainKey, pin.bridge));
            require(samePeer, ErrorsLib.ValidationAlreadyRouted(ticketId, chainKey, pin.bridge));
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

    /// @dev Sends one protocol message to this token's peer on `chainKey`, through its current receipt route. The
    /// ticket route is never used here: a money message moves value, so it waits for the chain's finality.
    ///
    /// Fail-closed before anything leaves: a registry must be set, the chain must be routed, the routed
    /// bridge must still be a receipt bridge at this instant, and the peer must be addressable.
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
    /// the author and the bridge must be the ones this message is expected from, and the bridge's receiving policy
    /// must still admit that away chain at full finality only. A receipt comes from the bridge and peer its half
    /// was pinned to, or from the chain's current ones; a burn proof for a recall still open comes from the peer
    /// and bridge that recall was sent to, so a later route or peer change cannot strand it, and any other burn
    /// proof from the current peer and route. A chain whose inbound is paused is refused last, once the message is
    /// attributed to it, so the revert undoes the replay guard's record and the delivery stays deliverable. Acting
    /// on the message is left to the token, since only it knows its compliance and its pause. That the bridge is a
    /// receipt bridge is the caller's check, made before this is reached, so a distrusted bridge is refused even
    /// when pinned.
    /// @return messageType `RECEIPT` or `BURN_PROOF`; anything else reverts.
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
        // message from that gateway. Its deliveries are still deduplicated by what they carry: a receipt by
        // the hash home keeps per half, a burn proof by its recall and the hash of the proof that settled it.
        if (receiveId != bytes32(0)) {
            require(!s.received[gateway][receiveId], ErrorsLib.MessageAlreadyReceived(gateway, receiveId));
            s.received[gateway][receiveId] = true;
        }

        if (messageType == MessageTypesLib.Message.RECEIPT) {
            MessageTypesLib.ReceiptMessage memory receipt = MessageTypesLib.decodeSettlement(body);
            _requireExpectedOrigin(
                s, gateway, chainKey, sender, MessageTypesLib.halfKeyOf(receipt.ticketId, receipt.half)
            );
        } else if (messageType == MessageTypesLib.Message.BURN_PROOF) {
            _requireRecallOrigin(s, gateway, chainKey, sender, MessageTypesLib.decodeBurnProof(body).recallId);
        } else {
            revert ErrorsLib.MessageTypeNotInbound(messageType);
        }

        // Everything a token receives reports value that moved, so the bridge must still wait for full finality.
        AwayReceiptBridge storage awaySide = s.awayReceiptBridges[chainKey];
        _requireFullFinality(gateway, chainKey, awaySide.chainSelector, awaySide.bridge);

        require(!s.inboundPaused[chainKey], ErrorsLib.AwayChainBlocked(chainKey));
    }

    /// @dev Hands an admitted settlement to `handler`, decoded, and reports the handler's verdict.
    ///
    /// The token calls this from inside its own pause and reentrancy checks. Run by DELEGATECALL, so
    /// the handler sees the token as its caller, which is the only caller a compliance accepts.
    /// @param handler The token's bound compliance.
    /// @param body A settlement body, as {acceptMessage} returned it.
    /// @return verdict `None`, or the block of the sending away chain the handler asks for on a bad receipt.
    function forwardSettlement(address handler, bytes32 chainKey, bytes memory body)
        external
        returns (IReceiptHandler.Verdict verdict)
    {
        return IReceiptHandler(handler).receiveReceipt(chainKey, MessageTypesLib.decodeSettlement(body));
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

    /// @dev The pinned bridge and peer of the half the receipt answers, or the current ones of the chain it came
    ///  from. A closed chain is refused first, pinned or not: closing it stops every receipt from it, and opening
    ///  the route again lets them be delivered. A half this token never sent has no pin and is taken from the
    ///  current pair: whether it was sent, and to that chain, is the receipt handler's question.
    function _requireExpectedOrigin(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        bytes calldata sender,
        bytes32 halfKey
    ) private view {
        require(s.receiptRoutes[chainKey] != address(0), ErrorsLib.ChainNotOpen(chainKey));

        Pin storage pin = s.pins[halfKey];
        bool fromThePinnedPair = pin.bridge == gateway && pin.peerKey == keccak256(sender);
        if (fromThePinnedPair) return;

        _requireCurrentPeer(chainKey, sender);
        _requireCurrentRoute(s, gateway, chainKey);
    }

    function _requireCurrentPeer(bytes32 chainKey, bytes calldata sender) private view {
        require(keccak256(sender) == keccak256(peerFor(chainKey)), ErrorsLib.SenderNotPeer(chainKey, sender));
    }

    /// @dev The peer and gateway the recall was dispatched to while it is open; the current ones once it is not,
    ///  so a settled id still reaches the token's duplicate and replay handling. A closed chain is
    ///  refused first, as for a settlement: closing it stops every proof from it until a route is set again.
    function _requireRecallOrigin(
        MessagingStorage storage s,
        address gateway,
        bytes32 chainKey,
        bytes calldata sender,
        uint256 recallId
    ) private view {
        require(s.receiptRoutes[chainKey] != address(0), ErrorsLib.ChainNotOpen(chainKey));

        TokenLedgerLib.PendingRecall storage recall = TokenLedgerLib.layout().recalls[recallId];
        if (recall.amount == 0) {
            _requireCurrentPeer(chainKey, sender);
            _requireCurrentRoute(s, gateway, chainKey);
            return;
        }
        require(keccak256(sender) == recall.peerKey, ErrorsLib.SenderNotPeer(chainKey, sender));
        require(recall.gateway == gateway, ErrorsLib.BridgeNotPinned(gateway, bytes32(recallId), chainKey));
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

}
