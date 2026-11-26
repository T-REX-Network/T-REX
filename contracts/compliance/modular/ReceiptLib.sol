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

import { ITREXMessaging } from "../../interop/ITREXMessaging.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { HoldLib } from "./HoldLib.sol";
import { ITickets } from "./ITickets.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { MovementKindLib } from "./MovementKindLib.sol";
import { SecondHalfLib } from "./SecondHalfLib.sol";
import { TicketLib } from "./TicketLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title ReceiptLib
 * @dev How a ticket ends, deployed once and linked: {receiveReceipt} records what an away token reports it did,
 * {applyWaitingReceipt} applies a good receipt that could not be applied when it arrived, and {cancelTickets}
 * releases what an away token never did. A move that leaves its away chain goes on through {SecondHalfLib}; a
 * receipt that no ticket home sent answers is put on hold through {HoldLib}.
 *
 * Home records what a receipt reports, not what home allowed: the away token's balances already moved, and a
 * refused receipt would leave home's records wrong for good. The terms check only decides whether the away chain
 * that sent the receipt is also blocked. Nothing here stops the token.
 *
 * These run once per cross-chain move, never on a native transfer. The compliance reaches them by DELEGATECALL,
 * so the storage is its own namespaces, the token and the modules see the compliance as their caller, and every
 * event is the compliance's. Who the caller is stays the compliance's to establish.
 */
library ReceiptLib {

    /* ----- Receipts ----- */

    /// @dev See {IReceiptHandler-receiveReceipt}, which lists the cases in the order they are told apart here. A
    ///  receipt is announced first, whatever becomes of it. A refused receipt writes nothing, so the honest receipt
    ///  for that half still lands after it.
    /// @param token the token the compliance is bound to
    function receiveReceipt(
        bytes32 originChainKey,
        address bridge,
        bytes32 senderPeerKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) external {
        _receive(originChainKey, bridge, senderPeerKey, receipt, token);
    }

    /// @dev See {receiveReceipt}; also the way {closeByHand} applies a receipt read from a closed away chain.
    function _receive(
        bytes32 originChainKey,
        address bridge,
        bytes32 senderPeerKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        emit EventsLib.ReceiptReceived(originChainKey, receipt.ticketId, receipt.from, receipt.to, receipt.amount);

        // 1. The same receipt again, from the same chain, changes nothing, unless it waits and can now be applied.
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 halfKey = MessageTypesLib.halfKeyOf(receipt.ticketId, receipt.half);
        bytes32 receiptHash = keccak256(abi.encode(originChainKey, receipt));
        if (store.receiptHashes[halfKey] == receiptHash) {
            emit EventsLib.ReceiptDuplicate(receipt.ticketId, originChainKey);
            return;
        }
        if (store.waitingReceipts[halfKey].bodyHash == receiptHash) {
            _receiveTheWaitingReceiptAgain(halfKey, receiptHash, originChainKey, receipt, token);
            return;
        }

        // 2. A still open answer moves nothing and never takes the half: it may only move the ticket's clock.
        if (receipt.answer == MessageTypesLib.ReceiptAnswer.StillOpen) {
            _noteStillOpen(store, originChainKey, receipt);
            return;
        }

        // 3. A second half of an id home has no record of is refused and announced; it blocks nobody.
        bool recorded = TicketLib.isRecorded(store, receipt.ticketId);
        if (!recorded && receipt.half != 0) {
            emit EventsLib.ReceiptUnknown(halfKey, originChainKey);
            return;
        }

        // 4. A first-half receipt that no ticket home sent answers is put on hold under its sender, see {HoldLib}.
        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];
        if (_answersNoTicketHomeSent(ticket, recorded, receipt)) {
            _receiveWithoutTicket(halfKey, receiptHash, originChainKey, bridge, senderPeerKey, receipt, token);
            return;
        }

        // 5. A bad receipt is refused and blocks the chain that sent it.
        if (_isBadReceipt(store, ticket, halfKey, originChainKey, receipt)) {
            emit EventsLib.ReceiptRefused(receipt.ticketId, originChainKey, receipt.amount, receipt.askBlockHash);
            TicketLib.blockAwayChain(originChainKey);
            return;
        }

        // 6. A good receipt that cannot be applied yet waits, tagged with the bridge and peer that delivered it.
        if (!_canBeAppliedNow(originChainKey, receipt, token)) {
            _keepWaiting(halfKey, receiptHash, originChainKey, bridge, senderPeerKey, receipt);
            return;
        }

        // 7. Applied as it happened.
        store.receiptHashes[halfKey] = receiptHash;
        _apply(ticket, originChainKey, receipt, token);
    }

    /// @dev See {ITickets-applyWaitingReceipt}. The receipt was checked when it arrived and is applied as it would
    ///  have been then, once its route still admits it. A revert anywhere below leaves the receipt waiting; the next
    ///  call tries again.
    /// @param token the token the compliance is bound to
    function applyWaitingReceipt(bytes32 halfKey, MessageTypesLib.ReceiptMessage calldata receipt, address token)
        external
    {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        ITickets.WaitingReceipt memory waiting = store.waitingReceipts[halfKey];
        bytes32 receiptHash = keccak256(abi.encode(waiting.chainKey, receipt));
        require(receiptHash == waiting.bodyHash, ErrorsLib.NoWaitingReceipt(halfKey));

        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];
        bool recorded = TicketLib.isRecorded(store, receipt.ticketId);
        bool withoutTicket = _answersNoTicketHomeSent(ticket, recorded, receipt);
        if (withoutTicket) HoldLib.requireCanBeBookedNow(waiting.chainKey, receipt, token);
        if (!withoutTicket) _requireCanBeAppliedNow(receipt, waiting.chainKey, token);
        ITREXMessaging(token)
            .checkReceiptOrigin(waiting.chainKey, waiting.deliveredBy, waiting.peerKey, halfKey, waiting.arrivedAt);

        delete store.waitingReceipts[halfKey];
        store.receiptHashes[halfKey] = receiptHash;
        emit EventsLib.WaitingReceiptApplied(halfKey, waiting.chainKey);
        if (withoutTicket) {
            HoldLib.bookWithoutTicket(waiting.chainKey, receipt, token);
            return;
        }
        _apply(ticket, waiting.chainKey, receipt, token);
    }

    /// @dev See {ITickets-refuseWaitingReceipt}. Only the waiting slot is deleted: no hash was written for the half,
    ///  so the honest receipt for it can still land.
    function refuseWaitingReceipt(bytes32 halfKey) external {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        ITickets.WaitingReceipt storage waiting = store.waitingReceipts[halfKey];
        require(waiting.bodyHash != bytes32(0), ErrorsLib.NoWaitingReceipt(halfKey));
        bytes32 chainKey = waiting.chainKey;
        require(store.blockedAwayChains[chainKey], ErrorsLib.AwayChainNotBlocked(chainKey));

        delete store.waitingReceipts[halfKey];

        emit EventsLib.WaitingReceiptRefused(halfKey);
    }

    /// @dev The receipt that waits under the half came again. When it can now be applied, the repeat applies it: the
    ///  repeat itself passed the route check at delivery. Otherwise it is a duplicate and the receipt keeps waiting.
    function _receiveTheWaitingReceiptAgain(
        bytes32 halfKey,
        bytes32 receiptHash,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];
        bool recorded = TicketLib.isRecorded(store, receipt.ticketId);
        bool withoutTicket = _answersNoTicketHomeSent(ticket, recorded, receipt);
        bool canBeAppliedNow = _canBeAppliedNow(originChainKey, receipt, token);
        if (withoutTicket) canBeAppliedNow = HoldLib.canBeBookedNow(originChainKey, receipt, token);
        if (!canBeAppliedNow) {
            emit EventsLib.ReceiptDuplicate(receipt.ticketId, originChainKey);
            return;
        }

        delete store.waitingReceipts[halfKey];
        store.receiptHashes[halfKey] = receiptHash;
        emit EventsLib.WaitingReceiptApplied(halfKey, originChainKey);
        if (withoutTicket) {
            HoldLib.bookWithoutTicket(originChainKey, receipt, token);
            return;
        }
        _apply(ticket, originChainKey, receipt, token);
    }

    /// @dev Whether a receipt answers no ticket home sent: an id home has no record of, or a first-half receipt for
    ///  a move home wrote and never sent, waiting for approval or cancelled before it left. Such a receipt is never
    ///  applied as a move: it is put on hold, see {HoldLib}.
    function _answersNoTicketHomeSent(
        ITickets.Ticket storage ticket,
        bool recorded,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        if (!recorded) return true;
        bool aMove = ticket.kind == ITickets.TicketKind.MOVE;
        bool neverSent = ticket.written && ticket.askBlockHash == bytes32(0);
        return receipt.half == 0 && aMove && neverSent;
    }

    /// @dev A first-half receipt that no ticket home sent answers. It is a bad receipt, refused and blocking the
    ///  chain that sent it, when another body came for the id, when its sender is not on that chain, when an expired
    ///  answer still moved something, or, for a ticket home wrote, when it names other wallets. A good one waits
    ///  until it can be booked; its hash is written before it is booked, so the same receipt again changes nothing.
    function _receiveWithoutTicket(
        bytes32 halfKey,
        bytes32 receiptHash,
        bytes32 originChainKey,
        address bridge,
        bytes32 senderPeerKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        if (_isBadReceiptWithoutTicket(store, halfKey, originChainKey, receipt)) {
            emit EventsLib.ReceiptRefused(receipt.ticketId, originChainKey, receipt.amount, receipt.askBlockHash);
            TicketLib.blockAwayChain(originChainKey);
            return;
        }
        if (!HoldLib.canBeBookedNow(originChainKey, receipt, token)) {
            _keepWaiting(halfKey, receiptHash, originChainKey, bridge, senderPeerKey, receipt);
            return;
        }
        store.receiptHashes[halfKey] = receiptHash;
        HoldLib.bookWithoutTicket(originChainKey, receipt, token);
    }

    /// @dev See {_receiveWithoutTicket}. With no ticket to compare it to, a receipt is held to the chain that holds its
    ///  sender: no other away chain can move that sender's tokens.
    function _isBadReceiptWithoutTicket(
        TicketLib.ValidationStorage storage store,
        bytes32 halfKey,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        bool anotherBodyApplied =
            store.receiptHashes[halfKey] != bytes32(0);
        bool anotherBodyWaiting = store.waitingReceipts[halfKey].bodyHash != bytes32(0);
        bool fromTheSendersChain = _chainKeyOf(receipt.from) == originChainKey;
        bool expiredYetMoved = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired && receipt.amount != 0;
        if (anotherBodyApplied || anotherBodyWaiting || !fromTheSendersChain || expiredYetMoved) return true;

        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];
        if (!TicketLib.isRecorded(store, receipt.ticketId)) return false;
        bool fromTheTicketsSender = keccak256(receipt.from) == ticket.fromKey;
        bool toTheTicketsReceiver = keccak256(receipt.to) == ticket.toKey;
        return !fromTheTicketsSender || !toTheTicketsReceiver;
    }

    /// @dev A still open answer: the away token holds the ticket unexecuted, valid until `seenValidUntil`. It is not
    ///  an answer to an ask for the receipt. Ignored for an id with no open ticket, from another chain or for a second
    ///  half. On home's own ask block hash it must echo home's own valid until, or it is a bad receipt. Otherwise it
    ///  raises `seenValidUntil`, up to a cap: valid until plus the chain's full finality delivery plus its clock lead,
    ///  the latest an honest copy can be valid until; past the cap it counts as no answer. An answer that moves the
    ///  valid until gives an ask back, so the ticket keeps its asks after the new waiting time.
    function _noteStillOpen(
        TicketLib.ValidationStorage storage store,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private {
        if (!TicketLib.isRecorded(store, receipt.ticketId)) return;
        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];
        bool ticketOpen = ticket.status == ITickets.TicketStatus.Open;
        bool fromTheChainTheTicketWentTo = originChainKey == ticket.fromChainKey;
        bool answersTheTicket = receipt.half == 0;
        bool answersAnOpenTicket = ticketOpen && fromTheChainTheTicketWentTo && answersTheTicket;
        if (!answersAnOpenTicket) return;

        bool onHomesOwnCopy = receipt.askBlockHash == ticket.askBlockHash;
        bool echoesAnotherValidUntil = receipt.seenValidUntil != ticket.validUntil;
        if (onHomesOwnCopy && echoesAnotherValidUntil) {
            emit EventsLib.ReceiptRefused(receipt.ticketId, originChainKey, receipt.amount, receipt.askBlockHash);
            TicketLib.blockAwayChain(originChainKey);
            return;
        }

        ITickets.MeasuredTimes storage times = store.measuredTimes[originChainKey];
        uint64 cap = ticket.validUntil + times.fullFinalityDelivery + times.clockLead;
        if (receipt.seenValidUntil > cap) return;

        uint64 latestValidUntil = ticket.validUntil;
        if (ticket.seenValidUntil > latestValidUntil) latestValidUntil = ticket.seenValidUntil;
        bool movesValidUntil = receipt.seenValidUntil > latestValidUntil;
        if (movesValidUntil) {
            ticket.seenValidUntil = receipt.seenValidUntil;
            if (ticket.asksForReceipt != 0) ticket.asksForReceipt -= 1;
        }
        emit EventsLib.TicketStillOpen(receipt.ticketId, receipt.seenValidUntil);
    }

    /// @dev A receipt home cannot take in: another body for a half that already has one, applied or waiting, or one
    ///  that does not answer the half it names, see {_answersTheTicket}, {_answersASecondHalf} and
    ///  {_answersTheBringHome}. The same body again never reaches here.
    function _isBadReceipt(
        TicketLib.ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bytes32 halfKey,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        bool anotherBodyApplied =
            store.receiptHashes[halfKey] != bytes32(0);
        bool anotherBodyWaiting = store.waitingReceipts[halfKey].bodyHash != bytes32(0);
        if (anotherBodyApplied || anotherBodyWaiting) return true;
        bool aBringHome = ticket.kind == ITickets.TicketKind.BRING_HOME;
        bool heldWithoutTicket = !ticket.written;
        if (aBringHome || heldWithoutTicket) return !_answersTheBringHome(ticket, originChainKey, receipt);
        if (receipt.half == 0) return !_answersTheTicket(ticket, originChainKey, receipt);
        return !_answersASecondHalf(ticket, originChainKey, receipt);
    }

    /// @dev Whether a receipt answers a half home sent for a bring home, or for the cancel of money on hold with no
    ///  ticket, whose halves burn from the receiver, then return what burned. Half 0 is never such an answer. A
    ///  receipt naming no sender answers the move out that returns what was burned, and exists only once that move
    ///  out is due. Any other must come from the burned wallet's chain, name that wallet and no receiver, and either
    ///  burn at most the half's amount for its latest half while it is out, or be a zero answer that a half expired
    ///  unexecuted. A burn for an older half would be a second burn.
    function _answersTheBringHome(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        if (receipt.half == 0) return false;
        bool namesTheBurnedWallet = receipt.from.length != 0;
        if (!namesTheBurnedWallet) {
            bool returnsWhatWasBurned =
                ticket.status == ITickets.TicketStatus.OnHold && ticket.secondHalfToKey == ticket.fromKey;
            return returnsWhatWasBurned && _answersASecondHalf(ticket, originChainKey, receipt);
        }
        // A bring home burns from its away wallet; the cancel of money on hold, from the receiver on the same chain.
        bytes32 burnedWalletKey = ticket.fromKey;
        if (!ticket.written) burnedWalletKey = ticket.toKey;
        bool fromTheWalletsChain = originChainKey == ticket.fromChainKey;
        bool burnedTheHalfsWallet = keccak256(receipt.from) == burnedWalletKey;
        bool namesNoReceiver = receipt.to.length == 0;

        bool answersTheLatestHalf = TicketLib.aBringHomeIsOut(ticket) && receipt.half == ticket.half;
        bool answersAnOlderHalf = receipt.half < ticket.half;
        bool executed = receipt.answer == MessageTypesLib.ReceiptAnswer.Executed;
        bool burnedAtMostItsAmount = executed && receipt.amount <= ticket.amountMax;
        bool expiredUnexecuted = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired && receipt.amount == 0;
        bool answersTheLatestHalfRightly = answersTheLatestHalf && (burnedAtMostItsAmount || expiredUnexecuted);
        bool answersAnOlderHalfRightly = answersAnOlderHalf && expiredUnexecuted;
        bool answersAHalfRightly = answersTheLatestHalfRightly || answersAnOlderHalfRightly;
        return fromTheWalletsChain && burnedTheHalfsWallet && namesNoReceiver && answersAHalfRightly;
    }

    /// @dev Whether a first-half receipt answers the ticket: from the chain the ticket went to, for the ticket's
    ///  wallets, and not an expired answer that still moved something.
    function _answersTheTicket(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        bool fromTheChainTheTicketWentTo = originChainKey == ticket.fromChainKey;
        bool fromTheTicketsSender = keccak256(receipt.from) == ticket.fromKey;
        bool toTheTicketsReceiver = keccak256(receipt.to) == ticket.toKey;
        bool expiredYetMoved = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired && receipt.amount != 0;
        return fromTheChainTheTicketWentTo && fromTheTicketsSender && toTheTicketsReceiver && !expiredYetMoved;
    }

    /// @dev Whether a receipt answers a second half home sent: the latest half, sent at least once, or an older one;
    ///  for the half's wallet, from the chain that wallet is on, which is the chain the half was sent to; naming no
    ///  sender; and either a mint of the money on hold or a zero answer that the half expired unexecuted. The chain
    ///  is read off the half's own wallet, never off the ticket's sender, so a receiving chain's honest receipt never
    ///  blocks it, and another chain cannot answer its half. An older half can only answer zero: a mint of it would
    ///  be a second mint of one move.
    function _answersASecondHalf(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        bool toTheHalfsWallet = keccak256(receipt.to) == ticket.secondHalfToKey;
        if (!toTheHalfsWallet) return false;
        bool fromTheChainTheHalfWentTo = _chainKeyOf(receipt.to) == originChainKey;
        bool namesNoSender = receipt.from.length == 0;

        bool latestHalfLeft = ticket.secondHalfSends != 0;
        bool answersTheLatestHalf = receipt.half == ticket.half && latestHalfLeft;
        bool answersAnOlderHalf = receipt.half < ticket.half;
        bool mintedTheHalf = receipt.answer == MessageTypesLib.ReceiptAnswer.Executed
            && receipt.amount == TicketLib.amountOfTheLatestHalf(ticket);
        bool expiredUnexecuted = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired && receipt.amount == 0;
        bool answersTheLatestHalfRightly = answersTheLatestHalf && (mintedTheHalf || expiredUnexecuted);
        bool answersAnOlderHalfRightly = answersAnOlderHalf && expiredUnexecuted;
        bool answersAHalfRightly = answersTheLatestHalfRightly || answersAnOlderHalfRightly;
        return fromTheChainTheHalfWentTo && namesNoSender && answersAHalfRightly;
    }

    /// @dev Applies a good receipt as it happened. A half of the cancel of money on hold with no ticket is
    ///  {HoldLib}'s, any other second half's receipt, a bring home's included, {SecondHalfLib}'s. A first-half receipt
    ///  for a ticket that was sent, open or cancelled, blocks its away chain
    ///  when it breaks its terms. A zero receipt ends the ticket with nothing moved and is never a bad receipt,
    ///  whatever terms it echoes. Any other receipt is checked against the copy it echoes: home's own, or an older one
    ///  from a home block a reorg dropped. A move inside one away chain is then done; a move to another chain goes on
    ///  hold for its second half.
    function _apply(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        if (!ticket.written) {
            HoldLib.applyHoldReceipt(receipt.ticketId, originChainKey, receipt, token);
            return;
        }
        if (receipt.half != 0) {
            SecondHalfLib.applySecondHalfReceipt(receipt.ticketId, originChainKey, receipt, token);
            return;
        }
        if (receipt.amount == 0) {
            TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
            emit EventsLib.ReceiptApplied(receipt.ticketId, originChainKey, 0);
            return;
        }

        bool breaksItsTerms;
        bool onHomesOwnCopy = receipt.askBlockHash == ticket.askBlockHash;
        if (onHomesOwnCopy) {
            breaksItsTerms = _breaksHomesOwnTerms(ticket, receipt);
        } else {
            emit EventsLib.ReceiptOnOlderTerms(receipt.ticketId, originChainKey, receipt.seenMax);
            breaksItsTerms = _breaksOlderTerms(ticket, originChainKey, receipt);
        }

        bool insideOneAwayChain = ticket.toChainKey == ticket.fromChainKey;
        if (insideOneAwayChain) {
            _applyTheMove(ticket, originChainKey, receipt, token);
        } else {
            SecondHalfLib.takeOntoHold(receipt.ticketId, originChainKey, receipt, token);
        }

        if (breaksItsTerms) TicketLib.blockAwayChain(originChainKey);
    }

    /// @dev On home's own ask block hash the away token executed the copy home sent, so the receipt must echo that
    ///  copy's maximum and valid until, and move an amount inside its range.
    function _breaksHomesOwnTerms(ITickets.Ticket storage ticket, MessageTypesLib.ReceiptMessage calldata receipt)
        private
        view
        returns (bool)
    {
        bool belowTheMinimum = receipt.amount < ticket.amountMin;
        bool aboveTheMaximum = receipt.amount > ticket.amountMax;
        bool echoesAnotherMaximum = receipt.seenMax != ticket.amountMax;
        bool echoesAnotherValidUntil = receipt.seenValidUntil != ticket.validUntil;
        return belowTheMinimum || aboveTheMaximum || echoesAnotherMaximum || echoesAnotherValidUntil;
    }

    /// @dev On another ask block hash the away token executed a copy from a home block a reorg dropped: the same
    ///  request, so the same id and minimum, narrowed differently. Its maximum is bounded by what was asked and by
    ///  the away chain's per-ticket cap, the most a dropped copy can carry; the amount by that copy's range.
    function _breaksOlderTerms(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        uint256 perTicketCap = TicketLib.layout().ticketLimits[originChainKey].perTicketCap;
        bool belowTheMinimum = receipt.amount < ticket.amountMin;
        bool aboveWhatTheCopyAllowed = receipt.amount > receipt.seenMax;
        bool aboveWhatWasAsked = receipt.seenMax > ticket.requestedMax;
        bool aboveThePerTicketCap = receipt.seenMax > perTicketCap;
        return belowTheMinimum || aboveWhatTheCopyAllowed || aboveWhatWasAsked || aboveThePerTicketCap;
    }

    /// @dev A move inside one away chain, as the away token made it: the ticket is done and releases its row, the
    ///  rules are asked again about the state the move lands on, the positions and the token's ledger move, then the
    ///  trackers are told.
    ///
    ///  A rule the move breaks now is announced, never refused: the tokens already moved on the away chain.
    ///  A tracker that reverts here reverts the delivery, and the delivery stays deliverable: swallowing the revert
    ///  would leave that module's counter silently wrong, while a refused delivery is repaired by
    ///  `forceRemoveModule` and a redelivery.
    function _applyTheMove(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        ticket.moved = receipt.amount;
        TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);

        IModule.TransferContext memory context = TransferContextLib.settlement(
            address(this),
            MovementKindLib.CROSS_CHAIN,
            ticket.fromIdentity,
            ticket.toIdentity,
            WalletKeyLib.walletId(receipt.from),
            WalletKeyLib.walletId(receipt.to),
            receipt.amount,
            ticket.spender
        );
        if (_breaksARuleNow(context, receipt.amount)) {
            emit EventsLib.MoveBreachedRule(receipt.ticketId, originChainKey, receipt.amount);
        }

        ComplianceLedgerLib.movePosition(
            context.fromIdentity, context.toIdentity, context.fromWallet, context.toWallet, receipt.amount
        );
        IToken(token).finishMove(receipt.from, receipt.to, receipt.amount, receipt.ticketId);

        emit EventsLib.ReceiptApplied(receipt.ticketId, originChainKey, receipt.amount);
        ModuleSetLib.callAfterTransfer(context);
    }

    /// @dev Whether the rules would refuse `amount` now. Asked once the ticket released its row, so the rules judge
    ///  the state the move lands on. A move between two wallets of one identity moves no position, so no
    ///  distribution rule applies to it.
    function _breaksARuleNow(IModule.TransferContext memory context, uint256 amount) private view returns (bool) {
        if (ComplianceLedgerLib.isRelocation(context.fromIdentity, context.toIdentity)) return false;
        return amount > ModuleSetLib.callCheckTransfer(context);
    }

    /* ----- Waiting receipts ----- */

    /// @dev Whether a good receipt for a ticket home sent can be applied now: the token runs and its away chain is
    ///  not blocked; for a first-half receipt, the sender's away balance covers what it moved. A second half's money
    ///  is already on hold at home, so no away balance is read for it. Otherwise it waits.
    function _canBeAppliedNow(bytes32 chainKey, MessageTypesLib.ReceiptMessage calldata receipt, address token)
        private
        view
        returns (bool)
    {
        bool tokenRunning = !IToken(token).paused();
        bool awayChainBlocked = TicketLib.layout().blockedAwayChains[chainKey];
        bool canBeAppliedNow = tokenRunning && !awayChainBlocked;
        if (receipt.half != 0) return canBeAppliedNow;
        bool awayBalanceCoversIt = receipt.amount <= IToken(token).awayBalanceOf(receipt.from);
        return canBeAppliedNow && awayBalanceCoversIt;
    }

    /// @dev {_canBeAppliedNow} as requirements, each with its own error, for {applyWaitingReceipt}.
    function _requireCanBeAppliedNow(MessageTypesLib.ReceiptMessage calldata receipt, bytes32 chainKey, address token)
        private
        view
    {
        bool answersTheTicket = receipt.half == 0;
        TicketLib.requireTokenRunning(token);
        TicketLib.requireAwayChainNotBlocked(chainKey);
        if (!answersTheTicket) return;
        uint256 awayBalance = IToken(token).awayBalanceOf(receipt.from);
        require(
            receipt.amount <= awayBalance,
            ErrorsLib.InsufficientBridgedBalance(receipt.from, awayBalance, receipt.amount)
        );
    }

    /// @dev Keeps a good receipt that cannot be applied yet under its half: its hash, and the bridge and peer that
    ///  delivered it for the route check {applyWaitingReceipt} runs again. Its bytes go out in the event only.
    ///  The half writes no receipt hash yet, so {refuseWaitingReceipt} can delete it and the honest receipt still
    ///  lands; another body for the half meanwhile is a bad receipt.
    function _keepWaiting(
        bytes32 halfKey,
        bytes32 receiptHash,
        bytes32 originChainKey,
        address bridge,
        bytes32 senderPeerKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private {
        ITickets.WaitingReceipt storage waiting = TicketLib.layout().waitingReceipts[halfKey];
        waiting.bodyHash = receiptHash;
        waiting.chainKey = originChainKey;
        waiting.deliveredBy = bridge;
        waiting.peerKey = senderPeerKey;
        waiting.amount = receipt.amount;
        waiting.arrivedAt = uint64(block.timestamp);
        emit EventsLib.ReceiptWaiting(halfKey, originChainKey, bridge, receipt);
    }

    /* ----- Cancel ----- */

    /// @dev Anyone may cancel: an `Open` ticket once an ask for its receipt went unanswered, see {_cancelDueAt}; a
    ///  ticket `WaitingForApproval` once past `validUntil`. One refused id reverts the whole batch.
    ///  No ticket is cancelled while the away chain that owes its receipt is blocked, its peer was replaced as hostile
    ///  less than four waiting times ago, or the token is stopped, a ticket waiting for approval included: its receipt
    ///  may be waiting or on its way, see {TicketLib-requireTicketCanBeDecided}. Nor while that away chain cannot
    ///  deliver its receipt, see {_requireReceiptRouteOpen}: that is {closeByHand}'s. Nor while a receipt for it waits and can be applied now,
    ///  see {_requireNoWaitingReceiptToApply}.
    /// @param token the token the compliance is bound to
    function cancelTickets(bytes32[] calldata validationIds, address token) external {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        for (uint256 i = 0; i < validationIds.length; i++) {
            bytes32 ticketId = validationIds[i];
            require(TicketLib.isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
            ITickets.Ticket storage ticket = store.validations[ticketId];
            TicketLib.requireTicketCanBeDecided(token, ticket);
            // Nothing was sent for a ticket waiting for approval: anyone may cancel it once its deadline passed,
            // and the reservation comes back.
            if (ticket.status == ITickets.TicketStatus.WaitingForApproval) {
                TicketLib.discardUnanswered(ticketId, token);
                continue;
            }
            // A bring home is never cancelled: its half may still burn, and it is asked for again instead.
            bool anOpenMove = ticket.status == ITickets.TicketStatus.Open && ticket.kind == ITickets.TicketKind.MOVE;
            require(anOpenMove, ErrorsLib.TicketNotCancellable(ticketId, uint8(ticket.status)));
            (bool askedAfterTheReceiptWasDue, uint64 dueAt) = _cancelDueAt(ticket);
            require(askedAfterTheReceiptWasDue, ErrorsLib.CancelNotDue(ticketId, dueAt));
            require(block.timestamp > dueAt, ErrorsLib.CancelNotDue(ticketId, dueAt));
            _requireReceiptRouteOpen(token, ticket.fromChainKey);
            _requireNoWaitingReceiptToApply(store, ticketId, ticket, token);

            TicketLib.moveTo(ticket, ITickets.TicketStatus.Cancelled, token);

            emit EventsLib.TicketCancelled(ticketId);
        }
    }

    /// @dev A ticket is not cancelled on home's clock while the away chain it was sent to cannot deliver a receipt:
    ///  its receipt route is closed, or its bridge distrusted. The away token may have executed it already, and its
    ///  silence proves nothing; {closeByHand} decides it from a read of that chain instead.
    function _requireReceiptRouteOpen(address token, bytes32 chainKey) private view {
        require(ITREXMessaging(token).isChainOpen(chainKey), ErrorsLib.ChainNotOpen(chainKey));
    }

    /// @dev A ticket is not cancelled over a receipt for it that waits and can be applied now: cancelling first
    ///  would release the reservation of a move home already holds the receipt of, and anyone can apply it instead.
    ///  The caller already checked the token runs and the away chain is not blocked. A waiting receipt the sender's
    ///  away balance no longer covers, or whose route check fails, cannot be applied, so it does not hold the
    ///  cancel: it would lock the ticket open.
    function _requireNoWaitingReceiptToApply(
        TicketLib.ValidationStorage storage store,
        bytes32 ticketId,
        ITickets.Ticket storage ticket,
        address token
    ) private view {
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, 0);
        ITickets.WaitingReceipt storage waiting = store.waitingReceipts[halfKey];
        if (waiting.bodyHash == bytes32(0)) return;

        bool awayBalanceCoversIt = waiting.amount <= IToken(token).awayBalanceOf(ticket.fromWallet);
        bool routeStillAdmitsIt = _routeStillAdmits(token, waiting, halfKey);
        bool canBeAppliedNow = awayBalanceCoversIt && routeStillAdmitsIt;
        require(!canBeAppliedNow, ErrorsLib.ApplyWaitingReceiptFirst(ticketId, waiting.chainKey));
    }

    /// @dev Whether the route check of {ITREXMessaging-checkReceiptOrigin} admits the waiting receipt now. A failed
    ///  check names its error. An empty reason is a check that ran out of gas, which a caller could force to skip
    ///  it: that counts as admitted, so the cancel waits rather than passes.
    function _routeStillAdmits(address token, ITickets.WaitingReceipt storage waiting, bytes32 halfKey)
        private
        view
        returns (bool)
    {
        try ITREXMessaging(token)
            .checkReceiptOrigin(waiting.chainKey, waiting.deliveredBy, waiting.peerKey, halfKey, waiting.arrivedAt) {
            return true;
        } catch (bytes memory reason) {
            bool ranOutOfGas = reason.length == 0;
            return ranOutOfGas;
        }
    }

    /// @dev When an open ticket may be cancelled: one waiting time after an ask for its receipt sent at or after
    ///  {TicketLib-waitingEndsAtOf}, strictly after, since the answer may land in that very second. An ask a still
    ///  open answer gave back, or one sent before the valid until moved, does not count: until a new one is out,
    ///  `dueAt` is the earliest a cancel could come.
    function _cancelDueAt(ITickets.Ticket storage ticket)
        private
        view
        returns (bool askedAfterTheReceiptWasDue, uint64 dueAt)
    {
        uint64 waitingEndsAt = TicketLib.waitingEndsAtOf(ticket);
        bool anAskStands = ticket.asksForReceipt != 0;
        bool sentAfterTheReceiptWasDue = ticket.lastSentAt >= waitingEndsAt;
        askedAfterTheReceiptWasDue = anAskStands && sentAfterTheReceiptWasDue;
        uint64 askedAt = waitingEndsAt;
        if (askedAfterTheReceiptWasDue) askedAt = ticket.lastSentAt;
        dueAt = askedAt + ticket.waitingTime;
    }

    /* ----- Close by hand ----- */

    /// @dev See {ITickets-closeByHand}. The read stands in for the receipt the closed chain cannot deliver: a stored
    ///  receipt goes through the same handler a delivery runs, with no bridge and no peer, since the caller's role
    ///  attests it. Without one, only the away chain's own clock in the read lets home decide.
    /// @param token the token the compliance is bound to
    function closeByHand(
        bytes32 ticketId,
        bytes calldata receiver,
        ITickets.AwayChainReading calldata reading,
        address token
    ) external {
        bytes32 chainKey = _requireTheChainIsClosed(ticketId, reading, token);

        // 1. What the away token stored is applied as if it had arrived; nothing is returned.
        if (reading.storedReceipt.amount != 0) {
            require(reading.storedReceipt.ticketId == ticketId, ErrorsLib.ValidationBodyMismatch(ticketId));
            _receive(chainKey, address(0), bytes32(0), reading.storedReceipt, token);
            emit EventsLib.ClosedByHand(ticketId, 0);
            return;
        }

        // 2. Nothing stored: decided on the away chain's own clock.
        uint256 returnedAmount = _closeOnTheAwayClock(ticketId, receiver, reading, chainKey, token);
        emit EventsLib.ClosedByHand(ticketId, returnedAmount);
    }

    /// @dev The away chain a close by hand reads, once it is known: the chain of the ticket's latest half, or the
    ///  stored receipt's sender's for an id with no record. It must deliver no receipt, and nothing is decided under
    ///  a stop, a block or a hostile change.
    /// @return chainKey the away chain read
    function _requireTheChainIsClosed(bytes32 ticketId, ITickets.AwayChainReading calldata reading, address token)
        private
        view
        returns (bytes32 chainKey)
    {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bool recorded = TicketLib.isRecorded(store, ticketId);
        bool storedAReceipt = reading.storedReceipt.amount != 0;
        require(recorded || storedAReceipt, ErrorsLib.UnknownTicket(ticketId));

        if (recorded) chainKey = _chainOfTheLatestHalf(store.validations[ticketId]);
        if (!recorded) chainKey = _chainKeyOf(reading.storedReceipt.from);
        require(!ITREXMessaging(token).isChainOpen(chainKey), ErrorsLib.ReceiptRouteNotClosed(chainKey));
        TicketLib.requireTokenRunning(token);
        TicketLib.requireAwayChainNotBlocked(chainKey);
        TicketLib.requireNoHostileChange(token, chainKey);
    }

    /// @dev No receipt in the read. A receipt waiting at home for the latest half says otherwise, so it is read again
    ///  instead. Then an open move is cancelled here, money on hold with no ticket is {HoldLib}'s, and any other
    ///  half {SecondHalfLib}'s.
    /// @return returnedAmount what goes back to the sender
    function _closeOnTheAwayClock(
        bytes32 ticketId,
        bytes calldata receiver,
        ITickets.AwayChainReading calldata reading,
        bytes32 chainKey,
        address token
    ) private returns (uint256 returnedAmount) {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        ITickets.Ticket storage ticket = store.validations[ticketId];
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, ticket.half);
        bool aReceiptWaits = store.waitingReceipts[halfKey].bodyHash != bytes32(0);
        require(!aReceiptWaits, ErrorsLib.ApplyWaitingReceiptFirst(ticketId, chainKey));
        require(WalletKeyLib.canonicalKey(receiver) == ticket.toKey, ErrorsLib.ValidationBodyMismatch(ticketId));

        bool anOpenMove = ticket.status == ITickets.TicketStatus.Open && ticket.kind == ITickets.TicketKind.MOVE;
        if (anOpenMove) {
            _cancelOnTheClosedRoute(store, ticket, ticketId, reading, token);
            return 0;
        }
        if (!ticket.written) {
            HoldLib.closeHoldByHand(ticketId, receiver, reading.awayClockTime, token);
            return 0;
        }
        return SecondHalfLib.closeHalfByHand(ticketId, reading.awayClockTime, token);
    }

    /// @dev An open move on a closed route is cancelled once the away chain's clock in the read is past every valid
    ///  until a copy of the ticket can carry there: home's own, moved by up to the chain's reorg slot shift for a copy
    ///  from a home block a reorg dropped that may still be on its way, the one a still open answer reported, and the
    ///  stored copy's.
    function _cancelOnTheClosedRoute(
        TicketLib.ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        ITickets.AwayChainReading calldata reading,
        address token
    ) private {
        uint64 reorgSlotShift = store.measuredTimes[ticket.fromChainKey].reorgSlotShift;
        uint64 latestValidUntil = ticket.validUntil + reorgSlotShift;
        if (ticket.seenValidUntil > latestValidUntil) latestValidUntil = ticket.seenValidUntil;
        if (reading.storedTicketValidUntil > latestValidUntil) latestValidUntil = reading.storedTicketValidUntil;
        require(
            reading.awayClockTime >= latestValidUntil,
            ErrorsLib.AwayClockBeforeValidUntil(ticketId, reading.awayClockTime, latestValidUntil)
        );

        TicketLib.moveTo(ticket, ITickets.TicketStatus.Cancelled, token);
        emit EventsLib.TicketCancelled(ticketId);
    }

    /// @dev The away chain the latest half of a ticket went to: the receiver's while its money on hold goes to the
    ///  receiver, the sender's otherwise, the ticket itself included.
    function _chainOfTheLatestHalf(ITickets.Ticket storage ticket) private view returns (bytes32) {
        bool goesToTheReceiver = ticket.status == ITickets.TicketStatus.OnHold && ticket.secondHalfToKey == ticket.toKey;
        if (goesToTheReceiver) return ticket.toChainKey;
        return ticket.fromChainKey;
    }

    function _chainKeyOf(bytes calldata wallet) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) = WalletKeyLib.parse(wallet);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
