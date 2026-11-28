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

        // 4. A bad receipt is refused and blocks the chain that sent it.
        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];
        bool withoutTicket = _answersNoTicketHomeSent(ticket, recorded, receipt);
        if (_refusedAsBad(store, ticket, withoutTicket, halfKey, originChainKey, receipt)) return;

        // 5. A first-half receipt that no ticket home sent answers is put on hold under its sender, see {HoldLib}.
        if (withoutTicket) {
            _receiveWithoutTicket(halfKey, receiptHash, originChainKey, bridge, senderPeerKey, receipt, token);
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

    /// @dev See {ITickets-applyWaitingReceipt}. The receipt is applied once its route still admits it, and is judged
    ///  again first: a ticket written since it arrived changes what it must match. A bad one is refused and blocks its
    ///  chain, as at delivery. A revert anywhere below leaves the receipt waiting; the next call tries again.
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
        if (_refusedAsBad(store, ticket, withoutTicket, halfKey, waiting.chainKey, receipt)) return;
        store.receiptHashes[halfKey] = receiptHash;
        emit EventsLib.WaitingReceiptApplied(halfKey, waiting.chainKey);
        if (withoutTicket) {
            _bookWithoutTicket(ticket, waiting.chainKey, receipt, token);
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
    ///  repeat itself passed the route check at delivery. It is judged again first, as {applyWaitingReceipt} judges
    ///  it. Otherwise it is a duplicate and the receipt keeps waiting.
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
        if (_refusedAsBad(store, ticket, withoutTicket, halfKey, originChainKey, receipt)) return;
        store.receiptHashes[halfKey] = receiptHash;
        emit EventsLib.WaitingReceiptApplied(halfKey, originChainKey);
        if (withoutTicket) {
            _bookWithoutTicket(ticket, originChainKey, receipt, token);
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
        bool neverSent = ticket.written && !ticket.sent;
        return receipt.half == 0 && aMove && neverSent;
    }

    /// @dev A good first-half receipt that no ticket home sent answers waits until it can be booked; its hash is
    ///  written before it is booked, so the same receipt again changes nothing.
    function _receiveWithoutTicket(
        bytes32 halfKey,
        bytes32 receiptHash,
        bytes32 originChainKey,
        address bridge,
        bytes32 senderPeerKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        if (!HoldLib.canBeBookedNow(originChainKey, receipt, token)) {
            _keepWaiting(halfKey, receiptHash, originChainKey, bridge, senderPeerKey, receipt);
            return;
        }
        TicketLib.layout().receiptHashes[halfKey] = receiptHash;
        _bookWithoutTicket(TicketLib.layout().validations[receipt.ticketId], originChainKey, receipt, token);
    }

    /// @dev Books a receipt no ticket home sent answers on hold, see {HoldLib-bookWithoutTicket}. For a ticket home
    ///  wrote and never sent, the receipt is first held to that ticket's terms as any receipt is: one that breaks them
    ///  blocks its chain, and is still booked, since the away token already moved the tokens.
    function _bookWithoutTicket(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        bool movesSomething = receipt.amount != 0;
        bool againstAWrittenTicket = ticket.written && movesSomething;
        if (againstAWrittenTicket && _breaksItsTerms(ticket, originChainKey, receipt)) {
            TicketLib.blockAwayChain(originChainKey);
        }
        HoldLib.bookWithoutTicket(originChainKey, receipt, token);
    }

    /// @dev Refuses a bad receipt: nothing is written for its half, so the honest receipt for it still lands, and the
    ///  away chain that sent it is blocked. Judged at delivery and again when a waiting receipt is applied, since a
    ///  ticket written meanwhile changes what the receipt must match.
    /// @param withoutTicket whether the receipt answers no ticket home sent, see {_answersNoTicketHomeSent}
    /// @return refused whether the receipt was bad
    function _refusedAsBad(
        TicketLib.ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bool withoutTicket,
        bytes32 halfKey,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private returns (bool refused) {
        ITickets.ReceiptRefusal reason;
        if (withoutTicket) {
            (refused, reason) = _isBadReceiptWithoutTicket(store, halfKey, originChainKey, receipt);
        }
        if (!withoutTicket) (refused, reason) = _isBadReceipt(store, ticket, halfKey, originChainKey, receipt);
        if (!refused) return false;
        emit EventsLib.ReceiptRefused(receipt.ticketId, originChainKey, receipt.amount, receipt.askBlockHash, reason);
        TicketLib.blockAwayChain(originChainKey);
    }

    /// @dev A first-half receipt that no ticket home sent answers is bad when another body came for the id, when its
    ///  sender is not on the chain it came from, when its receiver is not a well formed wallet, or, for a ticket home
    ///  wrote, when it names other wallets. With no ticket to compare it
    ///  to, a receipt is held to the chain that holds its sender: no other away chain can move that sender's tokens.
    ///  A malformed wallet is refused here, not reverted: nothing may revert the delivery once it is admitted.
    /// @return bad whether the receipt is bad
    /// @return reason why, when it is
    function _isBadReceiptWithoutTicket(
        TicketLib.ValidationStorage storage store,
        bytes32 halfKey,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool bad, ITickets.ReceiptRefusal reason) {
        bool anotherBodyApplied = store.receiptHashes[halfKey] != bytes32(0);
        bool anotherBodyWaiting = store.waitingReceipts[halfKey].bodyHash != bytes32(0);
        if (anotherBodyApplied || anotherBodyWaiting) return (true, ITickets.ReceiptRefusal.AnotherBody);
        (bool fromIsAWallet, bytes2 fromChainType, bytes memory fromChainReference,) =
            WalletKeyLib.tryParse(receipt.from);
        bool fromTheSendersChain =
            fromIsAWallet && MessageTypesLib.chainKey(fromChainType, fromChainReference) == originChainKey;
        if (!fromTheSendersChain) return (true, ITickets.ReceiptRefusal.WrongChain);
        (bool toIsAWallet,,,) = WalletKeyLib.tryParse(receipt.to);
        if (!toIsAWallet) return (true, ITickets.ReceiptRefusal.WrongWallets);

        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];
        if (!TicketLib.isRecorded(store, receipt.ticketId)) return (false, reason);
        bool fromTheTicketsSender = keccak256(receipt.from) == ticket.fromKey;
        bool toTheTicketsReceiver = keccak256(receipt.to) == ticket.toKey;
        bool namesTheTicketsWallets = fromTheTicketsSender && toTheTicketsReceiver;
        return (!namesTheTicketsWallets, ITickets.ReceiptRefusal.WrongWallets);
    }

    /// @dev A still open answer: the away token holds the ticket unexecuted, valid until `seenValidUntil`. It is not
    ///  an answer to an ask for the receipt. Ignored for an id with no open ticket that home sent, from another chain or
    ///  for a second half. On home's own ask block hash it must echo home's own valid until, or it is a bad receipt. Otherwise it
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
        bool ticketSent = !TicketLib.neverSent(ticket);
        bool answersAnOpenTicket = ticketOpen && ticketSent && fromTheChainTheTicketWentTo && answersTheTicket;
        if (!answersAnOpenTicket) return;

        bool onHomesOwnCopy = receipt.askBlockHash == ticket.askBlockHash;
        bool echoesAnotherValidUntil = receipt.seenValidUntil != ticket.validUntil;
        if (onHomesOwnCopy && echoesAnotherValidUntil) {
            emit EventsLib.ReceiptRefused(
                receipt.ticketId,
                originChainKey,
                receipt.amount,
                receipt.askBlockHash,
                ITickets.ReceiptRefusal.AnotherValidUntil
            );
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
    /// @return bad whether the receipt is bad
    /// @return reason why, when it is
    function _isBadReceipt(
        TicketLib.ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bytes32 halfKey,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool bad, ITickets.ReceiptRefusal reason) {
        bool anotherBodyApplied = store.receiptHashes[halfKey] != bytes32(0);
        bool anotherBodyWaiting = store.waitingReceipts[halfKey].bodyHash != bytes32(0);
        if (anotherBodyApplied || anotherBodyWaiting) return (true, ITickets.ReceiptRefusal.AnotherBody);
        bool aBringHome = ticket.kind == ITickets.TicketKind.BRING_HOME;
        bool heldWithoutTicket = !ticket.written;
        bool answers;
        if (aBringHome || heldWithoutTicket) {
            (answers, reason) = _answersTheBringHome(ticket, originChainKey, receipt);
        } else if (receipt.half == 0) {
            (answers, reason) = _answersTheTicket(ticket, originChainKey, receipt);
        } else {
            bytes32 halfWalletKey = _walletTheHalfWentTo(ticket, receipt.half);
            (answers, reason) = _answersASecondHalf(ticket, originChainKey, receipt, halfWalletKey);
        }
        bad = !answers;
    }

    /// @dev The key of the wallet a move's second half went to: the receiver's for a half sent before close by hand
    ///  turned the money on hold back, the latest half's wallet otherwise.
    function _walletTheHalfWentTo(ITickets.Ticket storage ticket, uint8 half) private view returns (bytes32) {
        bool sentBeforeTheTurnBack = half <= ticket.lastHalfToTheReceiver;
        if (sentBeforeTheTurnBack) return ticket.toKey;
        return ticket.secondHalfToKey;
    }

    /// @dev Whether a receipt answers a half home sent for a bring home, or for the cancel of money on hold with no
    ///  ticket, whose halves burn from the receiver, then return what burned. Half 0 is never such an answer. A
    ///  receipt naming no sender answers the move out that returns what was burned, and exists only once that move
    ///  out is due. Any other must come from the burned wallet's chain, name that wallet and no receiver, and either
    ///  burn at most the half's amount for its latest half while it is out, or be a zero answer that a half it sent
    ///  expired unexecuted, the latest included once close by hand ended it. A burn for an older half would be a
    ///  second burn.
    /// @return answers whether it answers such a half
    /// @return reason why not, when it does not
    function _answersTheBringHome(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool answers, ITickets.ReceiptRefusal reason) {
        if (receipt.half == 0) return (false, ITickets.ReceiptRefusal.HalfNotSent);
        bool namesTheBurnedWallet = receipt.from.length != 0;
        if (!namesTheBurnedWallet) {
            // A bring home's two wallets differ, so its wallet says where its half goes; a cancel's may be one wallet.
            bool returnsToTheSender = ticket.cancelReturnsToTheSender;
            if (ticket.written) returnsToTheSender = ticket.secondHalfToKey == ticket.fromKey;
            bool returnsWhatWasBurned = ticket.status == ITickets.TicketStatus.OnHold && returnsToTheSender;
            if (!returnsWhatWasBurned) return (false, ITickets.ReceiptRefusal.WrongMoveOut);
            return _answersASecondHalf(ticket, originChainKey, receipt, ticket.fromKey);
        }
        // A bring home burns from its away wallet; the cancel of money on hold, from the receiver on the same chain.
        bytes32 burnedWalletKey = ticket.fromKey;
        if (!ticket.written) burnedWalletKey = ticket.toKey;
        bool fromTheWalletsChain = originChainKey == ticket.fromChainKey;
        if (!fromTheWalletsChain) return (false, ITickets.ReceiptRefusal.WrongChain);
        bool burnedTheHalfsWallet = keccak256(receipt.from) == burnedWalletKey;
        bool namesNoReceiver = receipt.to.length == 0;
        bool namesItsWallets = burnedTheHalfsWallet && namesNoReceiver;
        if (!namesItsWallets) return (false, ITickets.ReceiptRefusal.WrongWallets);
        bool answersASentHalf = receipt.half <= ticket.half;
        if (!answersASentHalf) return (false, ITickets.ReceiptRefusal.HalfNotSent);

        bool answersTheLatestHalf = TicketLib.aBringHomeIsOut(ticket) && receipt.half == ticket.half;
        bool executed = receipt.answer == MessageTypesLib.ReceiptAnswer.Executed;
        bool burnedAtMostItsAmount = executed && receipt.amount <= ticket.amountMax;
        bool expiredUnexecuted = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired && receipt.amount == 0;
        bool burnedForTheLatestHalf = answersTheLatestHalf && burnedAtMostItsAmount;
        bool answersAHalfRightly = burnedForTheLatestHalf || expiredUnexecuted;
        return (answersAHalfRightly, ITickets.ReceiptRefusal.AboveTheBringHome);
    }

    /// @dev Whether a first-half receipt answers the ticket: from the chain the ticket went to, for the ticket's
    ///  wallets.
    /// @return answers whether it answers the ticket
    /// @return reason why not, when it does not
    function _answersTheTicket(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool answers, ITickets.ReceiptRefusal reason) {
        bool fromTheChainTheTicketWentTo = originChainKey == ticket.fromChainKey;
        if (!fromTheChainTheTicketWentTo) return (false, ITickets.ReceiptRefusal.WrongChain);
        bool fromTheTicketsSender = keccak256(receipt.from) == ticket.fromKey;
        bool toTheTicketsReceiver = keccak256(receipt.to) == ticket.toKey;
        bool namesTheTicketsWallets = fromTheTicketsSender && toTheTicketsReceiver;
        return (namesTheTicketsWallets, ITickets.ReceiptRefusal.WrongWallets);
    }

    /// @dev Whether a receipt answers a second half home sent: the latest half, sent at least once, or an older one;
    ///  for `halfWalletKey`, the wallet that half went to, from the chain that wallet is on; naming no sender; and
    ///  either a mint of the money on hold or a zero answer that the half expired unexecuted. The chain is read off
    ///  the half's own wallet, never off the ticket's sender, so a receiving chain's honest receipt never blocks it,
    ///  and another chain cannot answer its half. An older half can only answer zero: a mint of it would be a second
    ///  mint of one move.
    /// @return answers whether it answers such a half
    /// @return reason why not, when it does not
    function _answersASecondHalf(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        bytes32 halfWalletKey
    ) private view returns (bool answers, ITickets.ReceiptRefusal reason) {
        bool toTheHalfsWallet = keccak256(receipt.to) == halfWalletKey;
        if (!toTheHalfsWallet) return (false, ITickets.ReceiptRefusal.WrongWallets);
        bool fromTheChainTheHalfWentTo = _chainKeyOf(receipt.to) == originChainKey;
        if (!fromTheChainTheHalfWentTo) return (false, ITickets.ReceiptRefusal.WrongChain);
        bool namesNoSender = receipt.from.length == 0;
        if (!namesNoSender) return (false, ITickets.ReceiptRefusal.WrongWallets);

        bool latestHalfLeft = ticket.secondHalfSends != 0;
        bool answersTheLatestHalf = receipt.half == ticket.half && latestHalfLeft;
        bool answersAnOlderHalf = receipt.half < ticket.half;
        bool answersASentHalf = answersTheLatestHalf || answersAnOlderHalf;
        if (!answersASentHalf) return (false, ITickets.ReceiptRefusal.HalfNotSent);

        bool mintedTheHalf = receipt.answer == MessageTypesLib.ReceiptAnswer.Executed
            && receipt.amount == TicketLib.amountOfTheLatestHalf(ticket);
        bool expiredUnexecuted = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired && receipt.amount == 0;
        bool answersTheLatestHalfRightly = answersTheLatestHalf && (mintedTheHalf || expiredUnexecuted);
        bool answersAnOlderHalfRightly = answersAnOlderHalf && expiredUnexecuted;
        bool answersAHalfRightly = answersTheLatestHalfRightly || answersAnOlderHalfRightly;
        return (answersAHalfRightly, ITickets.ReceiptRefusal.WrongMoveOut);
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

        bool breaksItsTerms = _breaksItsTerms(ticket, originChainKey, receipt);

        bool insideOneAwayChain = ticket.toChainKey == ticket.fromChainKey;
        if (insideOneAwayChain) {
            _applyTheMove(ticket, originChainKey, receipt, token);
        } else {
            SecondHalfLib.takeOntoHold(receipt.ticketId, originChainKey, receipt, token);
        }

        if (breaksItsTerms) TicketLib.blockAwayChain(originChainKey);
    }

    /// @dev Whether a receipt that moved something breaks the terms of the ticket home wrote: home's own copy's, or a
    ///  copy's from a home block a reorg dropped, announced with `ReceiptOnOlderTerms`.
    function _breaksItsTerms(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private returns (bool) {
        bool onHomesOwnCopy = receipt.askBlockHash == ticket.askBlockHash;
        if (onHomesOwnCopy) return _breaksHomesOwnTerms(ticket, receipt);
        emit EventsLib.ReceiptOnOlderTerms(receipt.ticketId, originChainKey, receipt.seenMax);
        return _breaksOlderTerms(ticket, originChainKey, receipt);
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
    ///  the away chain's per-ticket cap, the most a dropped copy can carry; the amount by that copy's range. A ticket
    ///  that waited for an approver has no such copy: it left at full finality, so only home's own copy is honest,
    ///  and any other would pass the approver's narrowed amount.
    function _breaksOlderTerms(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private view returns (bool) {
        bool onlyHomesOwnCopyIsHonest = ticket.waitedForApproval;
        uint256 perTicketCap = TicketLib.layout().ticketLimits[originChainKey].perTicketCap;
        bool belowTheMinimum = receipt.amount < ticket.amountMin;
        bool aboveWhatTheCopyAllowed = receipt.amount > receipt.seenMax;
        bool aboveWhatWasAsked = receipt.seenMax > ticket.requestedMax;
        bool aboveThePerTicketCap = receipt.seenMax > perTicketCap;
        bool breaksTheCopysBounds = belowTheMinimum || aboveWhatTheCopyAllowed || aboveWhatWasAsked;
        return onlyHomesOwnCopyIsHonest || breaksTheCopysBounds || aboveThePerTicketCap;
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
            ticket.fromChainKey,
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

    /// @dev Anyone may cancel: an `Open` ticket, sent or not, once an ask for its receipt went unanswered, see
    ///  {_cancelDueAt}; a move waiting for approval once past `validUntil`. One refused id reverts the whole batch.
    ///  No ticket is cancelled while the away chain that owes its receipt is blocked, its peer was replaced as hostile
    ///  less than four waiting times ago, or the token is stopped, a ticket waiting for approval included: its receipt
    ///  may be waiting or on its way, see {TicketLib-requireTicketCanBeDecided}. Nor while that away chain cannot
    ///  deliver its receipt, see {_requireReceiptRouteOpen}: that is {closeByHand}'s. Nor while a receipt for its
    ///  first half waits and can be applied now, a ticket waiting for approval included, see
    ///  {_requireNoWaitingReceiptToApply}.
    /// @param token the token the compliance is bound to
    function cancelTickets(bytes32[] calldata validationIds, address token) external {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        for (uint256 i = 0; i < validationIds.length; i++) {
            bytes32 ticketId = validationIds[i];
            require(TicketLib.isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
            ITickets.Ticket storage ticket = store.validations[ticketId];
            TicketLib.requireTicketCanBeDecided(token, ticket);
            // Nothing was sent for a move waiting for approval: anyone may cancel it once its deadline passed, and the
            // reservation comes back. A copy from a home block a reorg dropped may still be held by the sender's away
            // chain, so on a closed route only a read of that chain decides it, see {closeByHand}. Once the approver
            // opened a ticket, it is cancelled only after an unanswered ask, as any open move is.
            bool waitingForApproval = ticket.status == ITickets.TicketStatus.WaitingForApproval;
            if (waitingForApproval) {
                (bool fromHome,) = WalletKeyLib.isReferenceChain(ticket.fromWallet);
                if (!fromHome) _requireReceiptRouteOpen(token, ticket.fromChainKey);
                _requireNoWaitingReceiptToApply(store, ticketId, ticket, token);
                TicketLib.discardUnanswered(ticketId, token);
                continue;
            }
            // A bring home is never cancelled: its half may still burn, and it is asked for again instead.
            bool anOpenMove = ticket.status == ITickets.TicketStatus.Open && ticket.kind == ITickets.TicketKind.MOVE;
            require(anOpenMove, ErrorsLib.TicketNotCancellable(ticketId, uint8(ticket.status)));
            (bool askedAfterTheReceiptWasDue, uint64 dueAt) = _cancelDueAt(ticket);
            require(askedAfterTheReceiptWasDue, ErrorsLib.CancelNotDue(ticketId, dueAt));
            require(block.timestamp >= dueAt, ErrorsLib.CancelNotDue(ticketId, dueAt));
            _requireReceiptRouteOpen(token, ticket.fromChainKey);
            _requireNoWaitingReceiptToApply(store, ticketId, ticket, token);

            TicketLib.moveTo(ticket, ITickets.TicketStatus.Cancelled, token);

            emit EventsLib.TicketCancelled(ticketId);
        }
    }

    /// @dev A ticket is not cancelled on home's clock while the away chain it was sent to cannot deliver a receipt:
    ///  its receipt route is closed, or its bridge distrusted. The away token may have executed it already, and its
    ///  silence proves nothing. Once the route is closed, {closeByHand} decides it from a read of that chain; under a
    ///  distrusted bridge, the route is closed or set again first.
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
    ///  {TicketLib-waitingEndsAtOf}; the waiting time is sized strictly above the answer's way back. An ask a still
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
        dueAt = askedAt + TicketLib.layout().waitingTimes[ticket.fromChainKey];
    }

    /* ----- Close by hand ----- */

    /// @dev See {ITickets-closeByHand}. The read stands in for the receipt the closed chain cannot deliver: a stored
    ///  receipt goes through the same handler a delivery runs, with no bridge and no peer, since the caller's role
    ///  attests it, and must be applied there: a read home would refuse or keep waiting reverts instead, so a mistake
    ///  in the read never blocks the chain. Without one, only the away chain's own clock in the read lets home decide.
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
            TicketLib.requireAwayChainNotBlocked(chainKey);
            _applyTheStoredReceipt(ticketId, chainKey, reading.storedReceipt, token);
            emit EventsLib.ClosedByHand(ticketId, 0, reading.blockNumber, reading.awayClockTime);
            return;
        }

        // 2. Nothing stored: decided on the away chain's own clock.
        uint256 returnedAmount = _closeOnTheAwayClock(ticketId, receiver, reading, chainKey, token);
        emit EventsLib.ClosedByHand(ticketId, returnedAmount, reading.blockNumber, reading.awayClockTime);
    }

    /// @dev Applies the receipt a read of the closed chain found, through {_receive}. Once it ran, the half must hold
    ///  that very receipt: one judged bad, or kept waiting, reverts the close by hand with nothing written.
    function _applyTheStoredReceipt(
        bytes32 ticketId,
        bytes32 chainKey,
        MessageTypesLib.ReceiptMessage calldata storedReceipt,
        address token
    ) private {
        require(storedReceipt.ticketId == ticketId, ErrorsLib.ValidationBodyMismatch(ticketId));
        _receive(chainKey, address(0), bytes32(0), storedReceipt, token);

        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, storedReceipt.half);
        bytes32 storedReceiptHash = keccak256(abi.encode(chainKey, storedReceipt));
        bool appliedAsRead = TicketLib.layout().receiptHashes[halfKey] == storedReceiptHash;
        require(appliedAsRead, ErrorsLib.ValidationBodyMismatch(ticketId));
    }

    /// @dev The away chain a close by hand reads, once it is known: the chain of the ticket's latest half, or the
    ///  stored receipt's sender's for an id with no record. It must deliver no receipt, and nothing is decided under
    ///  a stop. A block is checked per case: an open move is cancelled on a closed route even while its chain is
    ///  blocked. A hostile change freezes only that cancel, see {_cancelOnTheClosedRoute}.
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
        bool routeClosed = ITREXMessaging(token).receiptRouteFor(chainKey) == address(0);
        require(routeClosed, ErrorsLib.ReceiptRouteNotClosed(chainKey));
        TicketLib.requireTokenRunning(token);
    }

    /// @dev No receipt in the read, so the away chain's own clock decides. A receipt waiting at home on the closed
    ///  route can never be applied there, so it does not hold the close. An open move, or one waiting for approval, is
    ///  cancelled here, whether its chain is blocked or not. Money on hold with no ticket is {HoldLib}'s, and any
    ///  other half {SecondHalfLib}'s, while neither the half's chain nor the sender's is blocked.
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
        require(WalletKeyLib.canonicalKey(receiver) == ticket.toKey, ErrorsLib.ValidationBodyMismatch(ticketId));

        bool openOrWaiting =
            ticket.status == ITickets.TicketStatus.Open || ticket.status == ITickets.TicketStatus.WaitingForApproval;
        bool aMoveNotDecided = openOrWaiting && ticket.kind == ITickets.TicketKind.MOVE;
        if (aMoveNotDecided) {
            _cancelOnTheClosedRoute(store, ticket, ticketId, reading, token);
            return 0;
        }
        TicketLib.requireAwayChainNotBlocked(chainKey);
        TicketLib.requireAwayChainNotBlocked(ticket.fromChainKey);
        if (!ticket.written) return HoldLib.closeHoldByHand(ticketId, receiver, reading.awayClockTime, token);
        return SecondHalfLib.closeHalfByHand(ticketId, reading.awayClockTime, token);
    }

    /// @dev An open move, or one waiting for approval, on a closed route is cancelled once the away chain's clock in
    ///  the read is past every valid until a copy of the ticket can carry there: home's own, moved by up to the chain's
    ///  reorg slot shift for a copy from a home block a reorg dropped that may still be on its way, the one a still
    ///  open answer reported, and the stored copy's. A cancel, so not while a hostile change runs on that chain.
    function _cancelOnTheClosedRoute(
        TicketLib.ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        ITickets.AwayChainReading calldata reading,
        address token
    ) private {
        TicketLib.requireNoHostileChange(token, ticket.fromChainKey);
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
