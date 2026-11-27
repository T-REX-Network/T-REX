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

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { ITickets } from "./ITickets.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { MovementKindLib } from "./MovementKindLib.sol";
import { SecondHalfLib } from "./SecondHalfLib.sol";
import { TicketLib } from "./TicketLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title HoldLib
 * @dev Money on hold with no ticket, deployed once and linked: a first-half receipt that no ticket home sent answers.
 * After a home reorg deeper than the ticket route waits for, or from a hostile away token, a receipt can name an id
 * home has no record of, or a ticket home wrote and never sent. Home blocks nobody for it: it puts the amount on hold
 * under the sender, with no destination, and when the tokens stayed on the away chain the receiver gets uncounted
 * credit, tokens it holds there that home does not count for it yet and that it can never ask to move.
 *
 * The same ask mined again takes that money and finishes the move. If nobody takes it within four waiting times of
 * the sender's away chain, anyone cancels it: a `BRING_HOME` on the receiver for at most its uncounted credit, then a
 * `MOVE_OUT` of what burned back to the sender. A bring home that burns less than it asked is a short cancel: the rest
 * stays on hold, and is not sent again until carried credit comes back.
 *
 * Two related asks a reorg dropped (Alice to Bob, then Bob to Carol) give two receipts with no ticket, and Bob spent
 * tokens that are only his uncounted credit. His receipt is booked anyway: his money on hold carries that much of
 * Alice's credit, and the two are linked. Cancels run last in, first out, so Bob's move is undone before Alice's, and
 * the tokens it brings back to Bob are uncounted credit again, still Alice's to cancel. When Alice's ask is mined
 * again and taken, the carried part becomes Bob's own money on hold, and only then may Bob's ask take his.
 *
 * The token's ledger: the money on hold of a ticket holds its sender's own part; a carried part stays in the earlier
 * money on hold until that one is taken.
 *
 * The compliance reaches this by DELEGATECALL, from {ReceiptLib} and {TicketLib} or from its own entry point, so the
 * storage is its own namespaces, the token and the modules see the compliance as their caller, and every event is the
 * compliance's.
 */
library HoldLib {

    /* ----- A receipt with no ticket ----- */

    /// @dev See {IReceiptHandler-receiveReceipt}: books a good first-half receipt that no ticket home sent answers,
    ///  once {canBeBookedNow} holds and its hash is written. A receipt that moved nothing, or moved tokens from a wallet
    ///  to itself, ends the id `Done`, so it can never be asked. Any other puts its amount on hold under the sender with
    ///  no destination, and gives uncounted credit to a receiver on the same away chain. A ticket home wrote and never
    ///  sent gives back what its ask reserved first: no copy of home's was executed, so it is never applied as a move.
    /// @param token the token the compliance is bound to
    function bookWithoutTicket(bytes32 originChainKey, MessageTypesLib.ReceiptMessage calldata receipt, address token)
        external
    {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 ticketId = receipt.ticketId;
        ITickets.Ticket storage ticket = store.validations[ticketId];
        bool movesNothing = _movesNothing(receipt);
        ITickets.TicketStatus next = ITickets.TicketStatus.OnHold;
        if (movesNothing) next = ITickets.TicketStatus.Done;

        // Step 1: the record.
        if (TicketLib.isRecorded(store, ticketId)) {
            TicketLib.moveTo(ticket, next, token);
        } else {
            _writeTheRecord(ticket, originChainKey, receipt, token);
            ticket.status = next;
        }
        ticket.written = false;
        if (movesNothing) {
            emit EventsLib.ReceiptApplied(ticketId, originChainKey, 0);
            return;
        }

        // Step 2: the money on hold, with no destination, waiting for the ask mined again or for its cancel. What the
        // sender's away balance does not cover is credit it carries from the money on hold that gave it.
        uint256 amount = receipt.amount;
        _keepTheHeldReceipt(store, ticket, originChainKey, receipt);
        uint256 awayBalance = IToken(token).awayBalanceOf(receipt.from);
        uint256 carried = 0;
        if (amount > awayBalance) carried = amount - awayBalance;
        if (carried != 0) _carryTheCredit(store, ticket, ticketId, carried);
        TicketLib.reserveTheHold(ticket);

        // Step 3: a receiver on the same away chain holds the tokens there.
        bool insideOneAwayChain = ticket.toChainKey == originChainKey;
        if (insideOneAwayChain) {
            store.uncountedCredit[ticket.toKey] += amount;
            store.uncountedCreditFrom[ticket.toKey] = ticketId;
        }
        emit EventsLib.ReceiptWithoutTicket(ticketId, originChainKey, receipt.from, receipt.to, amount);

        IToken(token).putOnHold(receipt.from, amount - carried, ticketId);
    }

    /// @dev Whether a good receipt with no ticket can be booked now: the token runs, its away chain is not blocked,
    ///  and, when it moved something, its sender resolves to an identity and can cover the amount, see
    ///  {_whatTheSenderMaySpend}. Otherwise it waits.
    /// @param token the token the compliance is bound to
    function canBeBookedNow(bytes32 originChainKey, MessageTypesLib.ReceiptMessage calldata receipt, address token)
        internal
        view
        returns (bool)
    {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bool tokenRunning = !IToken(token).paused();
        bool awayChainBlocked = store.blockedAwayChains[originChainKey];
        if (!tokenRunning || awayChainBlocked) return false;
        if (_movesNothing(receipt)) return true;
        bool senderHasAnIdentity = _identityOf(receipt.from, token) != address(0);
        bool senderCoversIt = receipt.amount <= _whatTheSenderMaySpend(store, receipt.from, token);
        return senderHasAnIdentity && senderCoversIt;
    }

    /// @dev {canBeBookedNow} as requirements, each with its own error, for {ReceiptLib-applyWaitingReceipt}.
    /// @param token the token the compliance is bound to
    function requireCanBeBookedNow(
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) internal view {
        TicketLib.requireTokenRunning(token);
        TicketLib.requireAwayChainNotBlocked(originChainKey);
        if (_movesNothing(receipt)) return;
        require(_identityOf(receipt.from, token) != address(0), ErrorsLib.UnverifiedWallet(receipt.from));
        uint256 spendable = _whatTheSenderMaySpend(TicketLib.layout(), receipt.from, token);
        require(
            receipt.amount <= spendable, ErrorsLib.InsufficientBridgedBalance(receipt.from, spendable, receipt.amount)
        );
    }

    /// @dev Whether the ask mined again may take the money on hold of `ticket`: a record a receipt created, still on
    ///  hold with no destination, and no cancel of it started.
    function isATakeableHold(ITickets.Ticket storage ticket) internal view returns (bool) {
        bool heldWithoutTicket = !ticket.written && ticket.status == ITickets.TicketStatus.OnHold;
        bool noCancelStarted = ticket.secondHalfToKey == bytes32(0) && !ticket.shortCancel;
        return heldWithoutTicket && noCancelStarted;
    }

    /* ----- The ask mined again ----- */

    /// @dev See {ITickets-askToMove}: the ask mined again takes the money on hold under its id. The held receipt must
    ///  name the ask's wallets, and keep the terms of the ask and the away chain's per-ticket cap, as a receipt on
    ///  older terms must. A move inside
    ///  one away chain is applied when the receiver may take it now and its hold is cancelled otherwise; a move out of
    ///  the away chain is decided as a first-half receipt is, see {SecondHalfLib-takeTheHold}.
    /// @param token the token the compliance is bound to
    function take(
        bytes32 ticketId,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes32 salt,
        address token
    ) external {
        ITickets.Ticket storage ticket = TicketLib.layout().validations[ticketId];

        // Checks
        _requireTheHeldReceiptNamesTheAsksWallets(ticket, ticketId, from, to);
        _requireTheHoldCanBeTaken(ticket, ticketId, requestedMin, requestedMax, token);
        IModule.TransferContext memory move = _theMoveAsAsked(ticket, from, to, spender, token);
        if (_insideOneAwayChain(ticket) && !_receiverMayTakeItNow(move, to, token)) {
            _cancel(ticket, ticketId, to, token);
            return;
        }

        // Effects: the record becomes the ask's ticket.
        ticket.written = true;
        ticket.toIdentity = move.toIdentity;
        ticket.relocation = ComplianceLedgerLib.isRelocation(move.fromIdentity, move.toIdentity);
        ticket.amountMin = requestedMin;
        ticket.requestedMax = requestedMax;
        ticket.spender = spender;
        ticket.salt = salt;
        emit EventsLib.HoldTaken(ticketId);

        if (!_insideOneAwayChain(ticket)) {
            SecondHalfLib.takeTheHold(ticketId, from, to, token);
            return;
        }
        _applyTheMoveInsideOneAwayChain(ticket, ticketId, move, from, to, token);
    }

    /* ----- The cancel ----- */

    /// @dev See {ITickets-cancelHold}. Anyone may cancel: the tokens are on hold under their sender, and the cancel
    ///  only gives back what the away token says it burned.
    /// @param token the token the compliance is bound to
    function cancelHold(bytes32 ticketId, bytes calldata receiver, address token) external {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        require(TicketLib.isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        ITickets.Ticket storage ticket = store.validations[ticketId];
        bool heldWithoutTicket = !ticket.written && ticket.status == ITickets.TicketStatus.OnHold;
        require(heldWithoutTicket, ErrorsLib.TicketNotCancellable(ticketId, uint8(ticket.status)));
        require(WalletKeyLib.canonicalKey(receiver) == ticket.toKey, ErrorsLib.ValidationBodyMismatch(ticketId));
        TicketLib.requireTicketCanBeDecided(token, ticket);

        bool cancelStarted = ticket.secondHalfToKey != bytes32(0);
        if (!cancelStarted) {
            require(block.timestamp >= ticket.stopWaitingAt, ErrorsLib.CancelNotDue(ticketId, ticket.stopWaitingAt));
        }
        if (cancelStarted) {
            bool nextBringHomeOwed = ticket.secondHalfToKey == ticket.toKey && ticket.secondHalfOwed;
            require(nextBringHomeOwed, ErrorsLib.TicketNotCancellable(ticketId, uint8(ticket.status)));
        }

        _cancel(ticket, ticketId, receiver, token);
    }

    /* ----- Close by hand ----- */

    /// @dev See {ITickets-closeByHand}: {ReceiptLib-closeByHand} found no stored receipt in the read of the closed
    ///  chain the money moved inside. The tokens never left that chain, so nothing is minted to the sender: what the
    ///  receiver still holds as uncounted credit is applied as the move it was, and a bring home of the cancel that is
    ///  out burned nothing once that chain's clock is past its valid until. Last in, first out: never while a later
    ///  hold carries this one's credit, and the earlier move this one carries from is applied first for that part.
    ///  Each move is applied as a move inside one chain is: to the identity its receiver has now, never the one read
    ///  at booking.
    /// @param receiver the receiver's wallet, checked by the caller
    /// @param awayClockTime the timestamp of the block read on the closed chain
    /// @param token the token the compliance is bound to
    function closeHoldByHand(bytes32 ticketId, bytes calldata receiver, uint64 awayClockTime, address token) external {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        ITickets.Ticket storage ticket = store.validations[ticketId];

        // Checks
        bool aBringHomeIsOut = _requireTheHoldCanBeClosedByHand(ticket, ticketId, awayClockTime);
        address receiverIdentity = _identityNowOf(receiver, token);
        bool carriesAnEarlierMove = ticket.carriedFrom != bytes32(0);
        address senderIdentity;
        if (carriesAnEarlierMove) senderIdentity = _identityNowOf(ticket.fromWallet, token);

        // Effects and interactions: what the bring home took from the receiver's credit is back, since it burned
        // nothing; the records name the receivers' identities of now; then the moves the away token made, the earlier
        // one first.
        if (aBringHomeIsOut) store.uncountedCredit[ticket.toKey] += ticket.amountMax;
        ticket.toIdentity = receiverIdentity;
        if (carriesAnEarlierMove) {
            store.validations[ticket.carriedFrom].toIdentity = senderIdentity;
            _applyTheCarriedPartFirst(ticket, ticketId, token);
        }
        _applyWhatTheReceiverHolds(ticket, ticketId, receiver, token);
    }

    /* ----- The halves of a cancel landed ----- */

    /// @dev See {IReceiptHandler-receiveReceipt}: a good receipt for a half of the cancel of money on hold with no
    ///  ticket, checked by {ReceiptLib}. Only the latest half moves anything. A receipt naming the wallet it burned
    ///  answers the bring home on the receiver; one naming no sender answers the move out back to the sender.
    /// @param token the token the compliance is bound to
    function applyHoldReceipt(
        bytes32 ticketId,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) external {
        ITickets.Ticket storage ticket = TicketLib.layout().validations[ticketId];
        emit EventsLib.ReceiptApplied(ticketId, originChainKey, receipt.amount);

        bool answersTheLatestHalf = receipt.half == ticket.half;
        if (!answersTheLatestHalf) return;
        bool answersTheBringHome = receipt.from.length != 0;
        if (answersTheBringHome) {
            // Once close by hand ended the bring home, its late zero answer changes nothing: the credit is back.
            if (TicketLib.aBringHomeIsOut(ticket)) _applyTheBringHomeAnswer(ticket, ticketId, receipt, token);
            return;
        }
        _applyTheMoveOutAnswer(ticket, ticketId, receipt, token);
    }

    /* ----- Private: booking ----- */

    /// @dev Whether a receipt moved nothing at home's level: nothing at all, or from a wallet to itself.
    function _movesNothing(MessageTypesLib.ReceiptMessage calldata receipt) private pure returns (bool) {
        bool nothingMoved = receipt.amount == 0;
        bool toItself = keccak256(receipt.from) == keccak256(receipt.to);
        return nothingMoved || toItself;
    }

    /// @dev Writes a record for an id home has no record of: the wallets and identities the receipt names. The sender's
    ///  chain is the one the receipt came from, checked by {ReceiptLib}.
    function _writeTheRecord(
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        ITREXRegistry registry = _registryOf(token);
        ticket.fromChainKey = originChainKey;
        ticket.toChainKey = _chainKeyOf(receipt.to);
        ticket.fromKey = WalletKeyLib.canonicalKey(receipt.from);
        ticket.toKey = WalletKeyLib.canonicalKey(receipt.to);
        ticket.fromWallet = receipt.from;
        ticket.fromIdentity = address(registry.resolveIdentity(receipt.from));
        ticket.toIdentity = address(registry.resolveIdentity(receipt.to));
    }

    /// @dev Keeps what the receipt says the away token did, for the ask mined again to check, and starts the clock: home
    ///  waits four waiting times of the sender's away chain before anyone may cancel.
    function _keepTheHeldReceipt(
        TicketLib.ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt
    ) private {
        uint64 waitingTime = store.waitingTimes[originChainKey];
        ticket.moved = receipt.amount;
        ticket.amountMax = receipt.seenMax;
        ticket.seenValidUntil = receipt.seenValidUntil;
        ticket.askBlockHash = receipt.askBlockHash;
        ticket.waitingTime = waitingTime;
        ticket.stopWaitingAt = uint64(block.timestamp) + 4 * waitingTime;
        if (ticket.stopWaitingAt > store.latestStopWaitingAt) store.latestStopWaitingAt = ticket.stopWaitingAt;
    }

    /// @dev The sender spent `carried` more than its away balance: that much of its uncounted credit, which the latest
    ///  money on hold that gave it backs. The two are linked, so neither ends before the other allows it.
    function _carryTheCredit(
        TicketLib.ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        uint256 carried
    ) private {
        bytes32 senderKey = ticket.fromKey;
        bytes32 earlierHoldId = store.uncountedCreditFrom[senderKey];
        store.uncountedCredit[senderKey] -= carried;
        ticket.carriedFrom = earlierHoldId;
        ticket.carriedAmount = carried;
        store.validations[earlierHoldId].carriedBy = ticketId;
    }

    /// @dev What a receipt with no ticket may spend from `wallet`: its away balance, plus the uncounted credit it may
    ///  carry now, see {_creditToCarry}.
    function _whatTheSenderMaySpend(TicketLib.ValidationStorage storage store, bytes calldata wallet, address token)
        private
        view
        returns (uint256)
    {
        uint256 awayBalance = IToken(token).awayBalanceOf(wallet);
        return awayBalance + _creditToCarry(store, WalletKeyLib.canonicalKey(wallet));
    }

    /// @dev The uncounted credit of a wallet a receipt with no ticket may carry: at most the latest money on hold that
    ///  gave it holds of its own, not what that hold itself carries, while that money is still on hold with no ticket,
    ///  none of its cancel's halves is out, and no other hold carries from it. Otherwise none, and the receipt waits.
    ///  A hold that owns nothing gives nothing: its close by hand would find nothing on hold to apply from.
    function _creditToCarry(TicketLib.ValidationStorage storage store, bytes32 walletKey)
        private
        view
        returns (uint256)
    {
        ITickets.Ticket storage earlierHold = store.validations[store.uncountedCreditFrom[walletKey]];
        bool stillHeldWithoutTicket = !earlierHold.written && earlierHold.status == ITickets.TicketStatus.OnHold;
        bool noHalfOut = !TicketLib.aBringHomeIsOut(earlierHold) && earlierHold.secondHalfToKey != earlierHold.fromKey;
        bool carriedByNone = earlierHold.carriedBy == bytes32(0);
        if (!stillHeldWithoutTicket || !noHalfOut || !carriedByNone) return 0;
        uint256 credit = store.uncountedCredit[walletKey];
        uint256 ownOnHold = earlierHold.moved - earlierHold.carriedAmount;
        if (credit > ownOnHold) credit = ownOnHold;
        return credit;
    }

    /* ----- Private: the take ----- */

    /// @dev Whether the ask may take the money on hold now: the token runs, the sender's chain is not blocked and has
    ///  no hostile change running, the money carries no earlier hold's credit (the tokens the sender spent are not
    ///  its own yet), and the held receipt keeps the terms of the ask, as a receipt on older terms must: the amount
    ///  inside the asked range and below the maximum it echoed, that maximum within what was asked and the away
    ///  chain's per-ticket cap.
    function _requireTheHoldCanBeTaken(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        uint256 requestedMin,
        uint256 requestedMax,
        address token
    ) private view {
        TicketLib.requireTicketCanBeDecided(token, ticket);
        bytes32 earlierHoldId = ticket.carriedFrom;
        require(earlierHoldId == bytes32(0), ErrorsLib.LaterHoldStillCarries(earlierHoldId, ticketId));

        uint256 seenMax = ticket.amountMax;
        uint256 perTicketCap = TicketLib.layout().ticketLimits[ticket.fromChainKey].perTicketCap;
        require(ticket.moved >= requestedMin, ErrorsLib.HeldReceiptBreaksItsTerms(ticketId));
        require(ticket.moved <= seenMax, ErrorsLib.HeldReceiptBreaksItsTerms(ticketId));
        require(seenMax <= requestedMax, ErrorsLib.HeldReceiptBreaksItsTerms(ticketId));
        require(seenMax <= perTicketCap, ErrorsLib.HeldReceiptBreaksItsTerms(ticketId));
    }

    /// @dev The held receipt must name the wallets of the ask: the id names them, but a hostile away token chooses
    ///  the wallets its receipt names, and could book another holder's money under the asker's id.
    function _requireTheHeldReceiptNamesTheAsksWallets(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes calldata from,
        bytes calldata to
    ) private view {
        bool heldFromTheAsksSender = WalletKeyLib.canonicalKey(from) == ticket.fromKey;
        bool heldForTheAsksReceiver = WalletKeyLib.canonicalKey(to) == ticket.toKey;
        require(heldFromTheAsksSender, ErrorsLib.HeldReceiptBreaksItsTerms(ticketId));
        require(heldForTheAsksReceiver, ErrorsLib.HeldReceiptBreaksItsTerms(ticketId));
    }

    /// @dev The move the ask names, for the money on hold, as the rules and the trackers are told it.
    function _theMoveAsAsked(
        ITickets.Ticket storage ticket,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        address token
    ) private view returns (IModule.TransferContext memory) {
        return TransferContextLib.settlement(
            ticket.fromChainKey,
            MovementKindLib.CROSS_CHAIN,
            ticket.fromIdentity,
            address(_registryOf(token).resolveIdentity(to)),
            WalletKeyLib.walletId(from),
            WalletKeyLib.walletId(to),
            ticket.moved,
            spender
        );
    }

    /// @dev Whether the away token moved the tokens to a wallet on its own chain.
    function _insideOneAwayChain(ITickets.Ticket storage ticket) private view returns (bool) {
        return ticket.toChainKey == ticket.fromChainKey;
    }

    /// @dev Whether the receiver may take the move now: it is eligible, and the rules allow the amount unless both
    ///  wallets are one identity's.
    function _receiverMayTakeItNow(IModule.TransferContext memory move, bytes calldata to, address token)
        private
        view
        returns (bool)
    {
        bool receiverEligible = _registryOf(token).isWalletVerified(to);
        bool rulesAllowIt = ComplianceLedgerLib.isRelocation(move.fromIdentity, move.toIdentity);
        if (!rulesAllowIt) rulesAllowIt = move.amountMax <= ModuleSetLib.callCheckTransfer(move);
        return receiverEligible && rulesAllowIt;
    }

    /// @dev The move inside one away chain, as the away token made it: the ticket is done, the receiver's uncounted
    ///  credit becomes its away balance, the positions move and the trackers are told. A later hold that carried part
    ///  of that credit holds it now as its sender's own money.
    function _applyTheMoveInsideOneAwayChain(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        IModule.TransferContext memory move,
        bytes calldata from,
        bytes calldata to,
        address token
    ) private {
        // Effects
        bytes32 laterHoldId = ticket.carriedBy;
        uint256 carriedByTheLaterHold = _endTheCarry(ticket);
        TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
        ComplianceLedgerLib.movePosition(
            move.fromIdentity, move.toIdentity, move.fromWallet, move.toWallet, move.amountMax
        );

        // Interactions
        IToken(token).finishMove(from, to, move.amountMax, ticketId);
        if (carriedByTheLaterHold != 0) IToken(token).putOnHold(to, carriedByTheLaterHold, laterHoldId);
        ModuleSetLib.callAfterTransfer(move);
    }

    /// @dev The receiver's uncounted credit from this money on hold becomes counted, and a later hold that carried part
    ///  of it no longer carries: that part is its sender's own money now.
    /// @return carriedByTheLaterHold the part the later hold carried, which goes on its hold
    function _endTheCarry(ITickets.Ticket storage ticket) private returns (uint256 carriedByTheLaterHold) {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 laterHoldId = ticket.carriedBy;
        ITickets.Ticket storage laterHold = store.validations[laterHoldId];
        carriedByTheLaterHold = laterHold.carriedAmount;
        store.uncountedCredit[ticket.toKey] -= ticket.moved - carriedByTheLaterHold;
        if (laterHoldId == bytes32(0)) return carriedByTheLaterHold;
        laterHold.carriedFrom = bytes32(0);
        laterHold.carriedAmount = 0;
        ticket.carriedBy = bytes32(0);
    }

    /* ----- Private: the cancel ----- */

    /// @dev Starts the cancel, or sends its next bring home. Last in, first out: never while a later hold carries this
    ///  one's credit. Tokens that left the away chain go back to the sender at once; tokens that stayed there are
    ///  brought home from the receiver first.
    function _cancel(ITickets.Ticket storage ticket, bytes32 ticketId, bytes calldata receiver, address token) private {
        bytes32 laterHoldId = ticket.carriedBy;
        require(laterHoldId == bytes32(0), ErrorsLib.LaterHoldStillCarries(ticketId, laterHoldId));
        if (ticket.secondHalfToKey == bytes32(0)) emit EventsLib.HoldCancelled(ticketId);

        if (_insideOneAwayChain(ticket)) {
            _sendTheBringHome(ticket, ticketId, receiver, token);
            return;
        }
        ticket.secondHalfToKey = ticket.fromKey;
        ticket.amountMax = ticket.moved;
        SecondHalfLib.takeANewHalf(ticket, ticketId);
        SecondHalfLib.sendTheLatestHalf(ticket, ticketId, ticket.fromWallet, token);
    }

    /// @dev The cancel's `BRING_HOME` on the receiver, for at most its uncounted credit, which it takes until the
    ///  answer gives back what did not burn. With no credit left there is nothing to burn: a short cancel at once.
    function _sendTheBringHome(ITickets.Ticket storage ticket, bytes32 ticketId, bytes calldata receiver, address token)
        private
    {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 receiverKey = ticket.toKey;
        uint256 credit = store.uncountedCredit[receiverKey];
        uint256 amount = ticket.moved;
        if (credit < amount) amount = credit;
        ticket.secondHalfToKey = receiverKey;
        if (amount == 0) {
            ticket.secondHalfOwed = false;
            ticket.shortCancel = true;
            emit EventsLib.CancelHoldShort(ticketId, ticket.moved);
            return;
        }

        store.uncountedCredit[receiverKey] = credit - amount;
        ticket.amountMax = amount;
        SecondHalfLib.takeANewHalf(ticket, ticketId);
        SecondHalfLib.sendTheLatestHalf(ticket, ticketId, receiver, token);
    }

    /// @dev The answer to the cancel's bring home. What it did not burn is the receiver's uncounted credit again. A
    ///  bring home that expired unexecuted is dead: {cancelHold} sends the next one. One that burned less than the
    ///  money on hold is a short cancel: the rest stays on hold, announced, and is not sent again. What it burned goes
    ///  back to the sender by a move out inside this delivery.
    function _applyTheBringHomeAnswer(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        uint256 burned = receipt.amount;
        bytes32 receiverKey = ticket.toKey;
        store.uncountedCredit[receiverKey] += ticket.amountMax - burned;
        store.uncountedCreditFrom[receiverKey] = ticketId;

        bool expiredUnexecuted = receipt.answer == MessageTypesLib.ReceiptAnswer.Expired;
        if (expiredUnexecuted) {
            ticket.secondHalfOwed = true;
            return;
        }
        uint256 missing = ticket.moved - burned;
        if (missing != 0) emit EventsLib.CancelHoldShort(ticketId, missing);
        if (burned == 0) {
            ticket.shortCancel = true;
            return;
        }

        ticket.amountMax = burned;
        ticket.secondHalfToKey = ticket.fromKey;
        ticket.newHalves = 0;
        SecondHalfLib.takeANewHalf(ticket, ticketId);
        SecondHalfLib.trySendInsideTheDelivery(ticket, ticketId, ticket.fromWallet, token);
    }

    /// @dev The answer to the cancel's move out back to the sender. One that expired unexecuted makes a new half owed,
    ///  sent with `sendSecondHalf`. One that minted gives the sender back what it carried as uncounted credit, still
    ///  the earlier money on hold's to cancel, and the rest as its away balance. The money on hold is then done, or
    ///  its rest waits short for carried credit to come back.
    function _applyTheMoveOutAnswer(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        bool expiredUnexecuted = receipt.amount == 0;
        if (expiredUnexecuted) {
            ticket.secondHalfOwed = true;
            return;
        }

        uint256 returned = ticket.amountMax;
        uint256 creditBack = ticket.carriedAmount;
        if (returned < creditBack) creditBack = returned;
        uint256 ownBack = returned - creditBack;

        // Effects
        if (creditBack != 0) _giveTheCarriedCreditBack(ticket, creditBack);
        ticket.moved -= returned;
        ComplianceLedgerLib.releasePendingTotal(returned);
        bool nothingLeftOnHold = ticket.moved == 0;
        if (nothingLeftOnHold) TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
        if (!nothingLeftOnHold) {
            ticket.secondHalfToKey = ticket.toKey;
            ticket.shortCancel = true;
        }

        // Interactions
        if (ownBack != 0) IToken(token).finishMove(ticket.fromWallet, ticket.fromWallet, ownBack, ticketId);
    }

    /// @dev Gives the sender back `amount` of the credit its money on hold carried. The earlier money on hold backs it
    ///  again, and is unlinked once nothing is carried; a cancel of it that came back short resumes, since credit it
    ///  could not burn is back on the wallet it burns from.
    function _giveTheCarriedCreditBack(ITickets.Ticket storage ticket, uint256 amount) private {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 senderKey = ticket.fromKey;
        bytes32 earlierHoldId = ticket.carriedFrom;
        ITickets.Ticket storage earlierHold = store.validations[earlierHoldId];

        store.uncountedCredit[senderKey] += amount;
        store.uncountedCreditFrom[senderKey] = earlierHoldId;
        ticket.carriedAmount -= amount;
        if (ticket.carriedAmount == 0) {
            ticket.carriedFrom = bytes32(0);
            earlierHold.carriedBy = bytes32(0);
        }
        if (earlierHold.shortCancel) {
            earlierHold.shortCancel = false;
            earlierHold.secondHalfOwed = true;
        }
    }

    /* ----- Private: close by hand ----- */

    /// @dev The checks of {closeHoldByHand} on the hold itself: on hold inside one away chain with no return to its
    ///  sender, no later hold carrying its credit, its cancel due, and a bring home that is out past its valid until
    ///  on the closed chain's clock.
    /// @return aBringHomeIsOut whether a bring home of the hold's cancel is out
    function _requireTheHoldCanBeClosedByHand(ITickets.Ticket storage ticket, bytes32 ticketId, uint64 awayClockTime)
        private
        view
        returns (bool aBringHomeIsOut)
    {
        bool onHold = ticket.status == ITickets.TicketStatus.OnHold;
        bool noReturnToTheSender = ticket.secondHalfToKey != ticket.fromKey;
        bool closable = onHold && _insideOneAwayChain(ticket) && noReturnToTheSender;
        require(closable, ErrorsLib.TicketNotCancellable(ticketId, uint8(ticket.status)));
        bytes32 laterHoldId = ticket.carriedBy;
        require(laterHoldId == bytes32(0), ErrorsLib.LaterHoldStillCarries(ticketId, laterHoldId));
        bool cancelStarted = ticket.secondHalfToKey != bytes32(0);
        if (!cancelStarted) {
            require(block.timestamp >= ticket.stopWaitingAt, ErrorsLib.CancelNotDue(ticketId, ticket.stopWaitingAt));
        }
        aBringHomeIsOut = TicketLib.aBringHomeIsOut(ticket);
        if (aBringHomeIsOut) {
            uint64 validUntil = ticket.secondHalfValidUntil;
            require(
                awayClockTime >= validUntil, ErrorsLib.AwayClockBeforeValidUntil(ticketId, awayClockTime, validUntil)
            );
        }
    }

    /// @dev This hold's sender spent tokens that were the earlier hold's uncounted credit: that earlier move happened
    ///  for the carried part, so it is applied first, from the earlier hold to this sender, and the part joins this
    ///  hold as its sender's own money. The earlier hold keeps the rest, and ends once nothing is left of it.
    function _applyTheCarriedPartFirst(ITickets.Ticket storage ticket, bytes32 ticketId, address token) private {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 earlierHoldId = ticket.carriedFrom;
        ITickets.Ticket storage earlierHold = store.validations[earlierHoldId];
        uint256 carried = ticket.carriedAmount;
        IModule.TransferContext memory move = TransferContextLib.settlement(
            earlierHold.fromChainKey,
            MovementKindLib.CROSS_CHAIN,
            earlierHold.fromIdentity,
            earlierHold.toIdentity,
            WalletKeyLib.walletId(earlierHold.fromWallet),
            WalletKeyLib.walletId(ticket.fromWallet),
            carried,
            ""
        );

        // Effects
        ticket.carriedFrom = bytes32(0);
        ticket.carriedAmount = 0;
        earlierHold.carriedBy = bytes32(0);
        earlierHold.moved -= carried;
        ComplianceLedgerLib.releasePendingTotal(carried);
        if (earlierHold.moved == 0) TicketLib.moveTo(earlierHold, ITickets.TicketStatus.Done, token);
        if (_breaksARuleNow(move, carried)) {
            emit EventsLib.MoveBreachedRule(earlierHoldId, earlierHold.fromChainKey, carried);
        }
        ComplianceLedgerLib.movePosition(move.fromIdentity, move.toIdentity, move.fromWallet, move.toWallet, carried);

        // Interactions
        IToken(token).finishMove(earlierHold.fromWallet, ticket.fromWallet, carried, earlierHoldId);
        IToken(token).putOnHold(ticket.fromWallet, carried, ticketId);
        ModuleSetLib.callAfterTransfer(move);
    }

    /// @dev The move inside the closed chain, as far as the receiver still holds its tokens there as uncounted credit:
    ///  that credit becomes the receiver's away balance out of this hold, the positions move and the trackers are
    ///  told. What the receiver no longer holds stays on hold, short, as a cancel that burned less would leave it.
    function _applyWhatTheReceiverHolds(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes calldata receiver,
        address token
    ) private {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bytes32 receiverKey = ticket.toKey;
        uint256 credit = store.uncountedCredit[receiverKey];
        uint256 applied = ticket.moved;
        if (credit < applied) applied = credit;
        IModule.TransferContext memory move = TransferContextLib.settlement(
            ticket.fromChainKey,
            MovementKindLib.CROSS_CHAIN,
            ticket.fromIdentity,
            ticket.toIdentity,
            WalletKeyLib.walletId(ticket.fromWallet),
            WalletKeyLib.walletId(receiver),
            applied,
            ""
        );

        // Effects
        store.uncountedCredit[receiverKey] = credit - applied;
        ticket.moved -= applied;
        ComplianceLedgerLib.releasePendingTotal(applied);
        bool nothingLeftOnHold = ticket.moved == 0;
        if (nothingLeftOnHold) TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
        if (!nothingLeftOnHold) {
            ticket.secondHalfToKey = receiverKey;
            ticket.secondHalfOwed = false;
            ticket.shortCancel = true;
            emit EventsLib.CancelHoldShort(ticketId, ticket.moved);
        }
        if (_breaksARuleNow(move, applied)) emit EventsLib.MoveBreachedRule(ticketId, ticket.fromChainKey, applied);
        ComplianceLedgerLib.movePosition(move.fromIdentity, move.toIdentity, move.fromWallet, move.toWallet, applied);

        // Interactions
        if (applied == 0) return;
        IToken(token).finishMove(ticket.fromWallet, receiver, applied, ticketId);
        ModuleSetLib.callAfterTransfer(move);
    }

    /* ----- Private ----- */

    /// @dev Whether the rules would refuse `amount` now, asked once the hold released it so they judge the state the
    ///  move lands on. Announced, never refused: the away token already made the move. A move between two wallets of
    ///  one identity moves no position, so no distribution rule applies to it.
    function _breaksARuleNow(IModule.TransferContext memory move, uint256 amount) private view returns (bool) {
        if (ComplianceLedgerLib.isRelocation(move.fromIdentity, move.toIdentity)) return false;
        return amount > ModuleSetLib.callCheckTransfer(move);
    }

    /// @dev The identity a wallet resolves to, zero when none.
    function _identityOf(bytes calldata wallet, address token) private view returns (address) {
        return address(_registryOf(token).resolveIdentity(wallet));
    }

    /// @dev The identity a wallet resolves to now; a wallet linked to none cannot take a move.
    function _identityNowOf(bytes memory wallet, address token) private view returns (address identity) {
        identity = address(_registryOf(token).resolveIdentity(wallet));
        require(identity != address(0), ErrorsLib.UnverifiedWallet(wallet));
    }

    /// @dev The registry of the token the compliance is bound to.
    function _registryOf(address token) private view returns (ITREXRegistry) {
        return ITREXRegistry(address(IToken(token).identityRegistry()));
    }

    function _chainKeyOf(bytes calldata wallet) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) = WalletKeyLib.parse(wallet);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
