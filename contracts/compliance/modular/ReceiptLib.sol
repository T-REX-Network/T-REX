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

import { IReceiptHandler } from "../../interop/IReceiptHandler.sol";
import { ITREXMessaging } from "../../interop/ITREXMessaging.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { ITickets } from "./ITickets.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { TicketLib } from "./TicketLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title ReceiptLib
 * @dev How a ticket ends, deployed once and linked: {receiveReceipt} records what an away token reports it did,
 * {applyWaitingReceipt} applies a receipt that came before its ticket was sent, and {cancelTickets} releases what
 * an away token never did.
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
    ///  receipt is announced first, whatever becomes of it. Only a receipt that is taken in writes the hash of its
    ///  half: a refused one never does, so the honest receipt for that half still lands after it.
    /// @param token the token the compliance is bound to
    function receiveReceipt(bytes32 originChainKey, MessageTypesLib.ReceiptMessage calldata receipt, address token)
        external
        returns (IReceiptHandler.Verdict)
    {
        emit EventsLib.ReceiptReceived(originChainKey, receipt.ticketId, receipt.from, receipt.to, receipt.amount);

        // 1. The same receipt again, from the same chain, changes nothing.
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 halfKey = MessageTypesLib.halfKeyOf(receipt.ticketId, receipt.half);
        bytes32 receiptHash = keccak256(abi.encode(originChainKey, receipt));
        bytes32 storedHash = store.receiptHashes[halfKey];
        if (storedHash == receiptHash) {
            emit EventsLib.ReceiptDuplicate(receipt.ticketId, originChainKey);
            return IReceiptHandler.Verdict.None;
        }

        // 2. A still open answer moves nothing and never takes the half.
        if (receipt.answer == MessageTypesLib.ReceiptAnswer.StillOpen) return IReceiptHandler.Verdict.None;

        // 3. An id home has no record of reverts and stays deliverable at the bridge.
        require(TicketLib.isRecorded(store, receipt.ticketId), ErrorsLib.UnknownTicket(receipt.ticketId));
        ITickets.Ticket storage ticket = store.validations[receipt.ticketId];

        // 4. A bad receipt is refused and blocks the chain that sent it.
        if (_isBadReceipt(ticket, originChainKey, receipt, storedHash)) {
            emit EventsLib.ReceiptRefused(receipt.ticketId, originChainKey, receipt.amount, receipt.askBlockHash);
            return IReceiptHandler.Verdict.PauseChain;
        }
        store.receiptHashes[halfKey] = receiptHash;

        // 5. A receipt for a ticket never sent waits for the ticket to be sent.
        if (ticket.askBlockHash == bytes32(0)) {
            _keepWaiting(originChainKey, receipt);
            return IReceiptHandler.Verdict.None;
        }
        return _apply(ticket, originChainKey, receipt, token);
    }

    /// @dev See {ITickets-applyWaitingReceipt}. The receipt was checked when it arrived, and is applied as it
    ///  would have been then: applied, it is announced; with broken terms, the block reaches the token through
    ///  {IToken-applyVerdict}. A revert anywhere below leaves the receipt waiting; the next call tries again.
    /// @param token the token the compliance is bound to
    function applyWaitingReceipt(bytes32 ticketId, bytes32 chainKey, address token) external {
        MessageTypesLib.ReceiptMessage memory waiting = _takeWaitingReceipt(ticketId, chainKey, token);
        ITickets.Ticket storage ticket = TicketLib.layout().validations[ticketId];
        IReceiptHandler.Verdict verdict = _apply(ticket, chainKey, waiting, token);
        if (verdict == IReceiptHandler.Verdict.None) emit EventsLib.WaitingReceiptApplied(ticketId, chainKey);
        else IToken(token).applyVerdict(chainKey, verdict);
    }

    /// @dev A receipt home cannot take in: another body for a half that already has one, from a chain that is not
    ///  the one the ticket went to, for wallets that are not the ticket's, for a half home never sent, or an
    ///  expired answer that still moved something.
    function _isBadReceipt(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        bytes32 storedHash
    ) private view returns (bool) {
        bool anotherBodyForThisHalf = storedHash != bytes32(0);
        bool fromTheChainTheTicketWentTo = originChainKey == ticket.fromChainKey;
        bool fromTheTicketsSender = keccak256(receipt.from) == ticket.fromKey;
        bool toTheTicketsReceiver = keccak256(receipt.to) == ticket.toKey;
        bool answersTheTicket = receipt.half == 0;
        bool expired = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired;
        bool expiredYetMoved = expired && receipt.amount != 0;
        bool answersTheTicketItWasSent =
            fromTheChainTheTicketWentTo && fromTheTicketsSender && toTheTicketsReceiver && answersTheTicket;
        return anotherBodyForThisHalf || !answersTheTicketItWasSent || expiredYetMoved;
    }

    /// @dev Applies a receipt for a ticket that was sent, open or cancelled, as it happened, and says whether its
    ///  away chain must also be blocked. A zero receipt ends the ticket with nothing moved and is never a bad
    ///  receipt, whatever terms it echoes. Any other receipt is checked against the copy it echoes: home's own,
    ///  or an older one from a home block a reorg dropped.
    function _apply(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage memory receipt,
        address token
    ) private returns (IReceiptHandler.Verdict) {
        if (receipt.amount == 0) {
            TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
            emit EventsLib.ReceiptApplied(receipt.ticketId, originChainKey, 0);
            return IReceiptHandler.Verdict.None;
        }

        bool breaksItsTerms;
        bool onHomesOwnCopy = receipt.askBlockHash == ticket.askBlockHash;
        if (onHomesOwnCopy) {
            breaksItsTerms = _breaksHomesOwnTerms(ticket, receipt);
        } else {
            emit EventsLib.ReceiptOnOlderTerms(receipt.ticketId, originChainKey, receipt.seenMax);
            breaksItsTerms = _breaksOlderTerms(ticket, originChainKey, receipt);
        }

        _applyTheMove(ticket, originChainKey, receipt, token);

        if (breaksItsTerms) return IReceiptHandler.Verdict.PauseChain;
        return IReceiptHandler.Verdict.None;
    }

    /// @dev On home's own ask block hash the away token executed the copy home sent, so the receipt must echo that
    ///  copy's maximum and valid until, and move an amount inside its range.
    function _breaksHomesOwnTerms(ITickets.Ticket storage ticket, MessageTypesLib.ReceiptMessage memory receipt)
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
        MessageTypesLib.ReceiptMessage memory receipt
    ) private view returns (bool) {
        uint256 perTicketCap = TicketLib.layout().ticketLimits[originChainKey].perTicketCap;
        bool belowTheMinimum = receipt.amount < ticket.amountMin;
        bool aboveWhatTheCopyAllowed = receipt.amount > receipt.seenMax;
        bool aboveWhatWasAsked = receipt.seenMax > ticket.requestedMax;
        bool aboveThePerTicketCap = receipt.seenMax > perTicketCap;
        return belowTheMinimum || aboveWhatTheCopyAllowed || aboveWhatWasAsked || aboveThePerTicketCap;
    }

    /// @dev The move as the away token made it: the ticket is done and releases its row, the rules are asked again
    ///  about the state the move lands on, the positions and the token's ledger move, then the trackers are told.
    ///
    ///  A rule the move breaks now is announced, never refused: the tokens already moved on the away chain.
    ///  A tracker that reverts here reverts the delivery, and the delivery stays deliverable: swallowing the revert
    ///  would leave that module's counter silently wrong, while a refused delivery is repaired by
    ///  `forceRemoveModule` and a redelivery.
    function _applyTheMove(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage memory receipt,
        address token
    ) private {
        ticket.moved = receipt.amount;
        TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);

        IModule.TransferContext memory context = _appliedMove(ticket, receipt.from, receipt.to, receipt.amount, token);
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

    /// @dev The move a receipt reports, as the modules are asked about it. Its own function because the receipt
    ///  path holds enough live values without it, and the legacy pipeline runs out of stack there under
    ///  `forge coverage`.
    ///
    ///  A native recipient may have changed owner since the ask, so it is resolved again here, through the
    ///  registry; a wallet the registry no longer names keeps the identity it was asked for. The token has not
    ///  been credited yet at this point, which is why nothing is adjusted for this very move.
    function _appliedMove(
        ITickets.Ticket storage ticket,
        bytes memory from,
        bytes memory to,
        uint256 amount,
        address token
    ) private returns (IModule.TransferContext memory) {
        address toIdentity = ticket.toIdentity;
        (bool toNative, address toWallet) = WalletKeyLib.isReferenceChain(to);
        if (toNative) {
            ITREXRegistry registry = ITREXRegistry(address(IToken(token).identityRegistry()));
            address registryIdentity = address(registry.identity(toWallet));
            if (registryIdentity == address(0)) registryIdentity = toIdentity;
            toIdentity = ComplianceLedgerLib.currentOwner(token, toWallet, registryIdentity, 0);
        }

        return TransferContextLib.settlement(
            address(this),
            ticket.fromIdentity,
            toIdentity,
            WalletKeyLib.walletId(from),
            WalletKeyLib.walletId(to),
            amount,
            ticket.spender
        );
    }

    /// @dev Whether the rules would refuse `amount` now. Asked once the ticket released its row, so the rules judge
    ///  the state the move lands on. A move between two wallets of one identity moves no position, so no
    ///  distribution rule applies to it.
    function _breaksARuleNow(IModule.TransferContext memory context, uint256 amount) private view returns (bool) {
        if (ComplianceLedgerLib.isRelocation(context.fromIdentity, context.toIdentity)) return false;
        return amount > ModuleSetLib.callCheckTransfer(context);
    }

    /* ----- Waiting receipts ----- */

    /// @dev Keeps a receipt for a ticket written and never sent, so that once the ticket is sent
    ///  {applyWaitingReceipt} applies it. Its half already holds its hash, so the same receipt again is a duplicate
    ///  and another one a bad receipt: one receipt waits per ticket at most.
    function _keepWaiting(bytes32 originChainKey, MessageTypesLib.ReceiptMessage calldata receipt) private {
        ITickets.WaitingReceipt storage waiting = TicketLib.layout().waitingReceipts[receipt.ticketId][originChainKey];
        waiting.from = receipt.from;
        waiting.to = receipt.to;
        waiting.amount = receipt.amount;
        waiting.askBlockHash = receipt.askBlockHash;
        waiting.exists = true;
        waiting.seenMax = receipt.seenMax;
        waiting.seenValidUntil = receipt.seenValidUntil;
        emit EventsLib.ReceiptWaiting(receipt.ticketId, originChainKey, receipt.amount, receipt.askBlockHash);
    }

    /// @dev Takes the receipt waiting under `(ticketId, chainKey)` out of storage and hands it back as the receipt
    ///  it was, see {ITickets-applyWaitingReceipt} for the requirements. A revert further on undoes the take.
    function _takeWaitingReceipt(bytes32 ticketId, bytes32 chainKey, address token)
        private
        returns (MessageTypesLib.ReceiptMessage memory receipt)
    {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        ITickets.WaitingReceipt memory waiting = store.waitingReceipts[ticketId][chainKey];
        // A receipt waits under the id for this chain.
        require(waiting.exists, ErrorsLib.NoWaitingReceipt(ticketId, chainKey));
        // The ticket was sent: a record without an ask block hash was sent nowhere, and there is nothing to apply
        // it against.
        require(store.validations[ticketId].askBlockHash != bytes32(0), ErrorsLib.NoWaitingReceipt(ticketId, chainKey));
        TicketLib.requireTokenRunning(token);
        // A receipt delivered from a blocked chain waits at the bridge; a waiting one from it waits here, for the
        // same investigation.
        TicketLib.requireInboundOpen(token, chainKey);
        delete store.waitingReceipts[ticketId][chainKey];
        receipt.ticketId = ticketId;
        receipt.from = waiting.from;
        receipt.to = waiting.to;
        receipt.amount = waiting.amount;
        receipt.askBlockHash = waiting.askBlockHash;
        receipt.seenMax = waiting.seenMax;
        receipt.seenValidUntil = waiting.seenValidUntil;
    }

    /* ----- Cancel ----- */

    /// @dev Each id must be stored `Open` and past `waitingEndsAt`. One refused id reverts the whole batch.
    /// @dev Who may: the keeper from `waitingEndsAt`, anyone from the end of the second window. A cancel turns a
    ///  receipt that lands afterwards into a late one, so during the first window the keeper alone judges that a
    ///  receipt is late rather than slow. Nor is a ticket cancelled while the away chain that owes its receipt is
    ///  blocked on the token, or the token itself is stopped: its receipt may be waiting at that bridge, see
    ///  {TicketLib-requireAwaitedInboundOpen}. Nor while that away chain cannot deliver its receipt, see
    ///  {_requireReceiptRouteOpen}. Nor while a receipt waits under its id, see {_requireNoWaitingReceipt}.
    /// @param token the token the compliance is bound to
    /// @param keeper whether the AccessManager binds the caller to this selector's role
    function cancelTickets(bytes32[] calldata validationIds, address token, bool keeper) external {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        for (uint256 i = 0; i < validationIds.length; i++) {
            bytes32 ticketId = validationIds[i];
            require(TicketLib.isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
            ITickets.Ticket storage ticket = store.validations[ticketId];
            // Nothing was sent for a ticket waiting for approval, so no receipt can be in flight: anyone may
            // cancel it once its deadline passed, and the reservation comes back.
            if (ticket.status == ITickets.TicketStatus.WaitingForApproval) {
                TicketLib.discardUnanswered(ticketId, token);
                continue;
            }
            require(
                ticket.status == ITickets.TicketStatus.Open,
                ErrorsLib.TicketNotCancellable(ticketId, uint8(ticket.status))
            );
            require(block.timestamp > ticket.waitingEndsAt, ErrorsLib.CancelNotDue(ticketId, ticket.waitingEndsAt));
            if (!keeper) {
                uint64 publicAt = _secondWindowEnd(ticket);
                require(block.timestamp > publicAt, ErrorsLib.ValidationNotPubliclyDiscardable(ticketId, publicAt));
            }
            TicketLib.requireAwaitedInboundOpen(token, ticket);
            _requireReceiptRouteOpen(token, ticket.fromChainKey);
            _requireNoWaitingReceipt(store, ticketId, ticket.fromChainKey);

            TicketLib.moveTo(ticket, ITickets.TicketStatus.Cancelled, token);

            emit EventsLib.TicketCancelled(ticketId);
        }
    }

    /// @dev A ticket is not cancelled while the away chain it was sent to cannot deliver a receipt: its receipt
    ///  route is closed, or its bridge distrusted. The away token may have executed it already, and its receipt
    ///  waits until a receipt route is set again; cancelling meanwhile would free what the receipt still moves.
    function _requireReceiptRouteOpen(address token, bytes32 chainKey) private view {
        require(ITREXMessaging(token).isChainOpen(chainKey), ErrorsLib.ChainNotOpen(chainKey));
    }

    /// @dev A ticket is not cancelled over a receipt waiting under its id. The receipt came while the ticket was
    ///  not sent and waits for {applyWaitingReceipt}; cancelling first would release the reservation of a move
    ///  home already holds the receipt of.
    function _requireNoWaitingReceipt(TicketLib.ValidationStorage storage store, bytes32 ticketId, bytes32 chainKey)
        private
        view
    {
        require(
            !store.waitingReceipts[ticketId][chainKey].exists, ErrorsLib.ApplyWaitingReceiptFirst(ticketId, chainKey)
        );
    }

    /// @dev The end of the second window: one more waiting time past `waitingEndsAt`. The public cancel opens here.
    function _secondWindowEnd(ITickets.Ticket storage ticket) private view returns (uint64) {
        return ticket.waitingEndsAt + (ticket.waitingEndsAt - ticket.validUntil);
    }

}
