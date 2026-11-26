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

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

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
import { MovementKindLib } from "./MovementKindLib.sol";
import { TicketLib } from "./TicketLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title SecondHalfLib
 * @dev The second half of a move between chains, deployed once and linked. A move that leaves its away chain is done
 * in halves, one after the other, never at the same time: the away token's execution of the ticket is the first
 * half, home's `MOVE_OUT` is the second.
 *
 * When the first half's receipt lands, the money goes on hold at home. In the same transaction home asks the rules
 * again for the receiver and decides where it goes: to the receiver, minted at once when it is a home wallet, or
 * back to the sender when the rules refuse it; a return never asks the rules. A home wallet that moves out is the
 * same move with no first half: its tokens are burned at home and go on hold in the ask itself.
 *
 * A second half has its own valid until and its own pin. Its receipt, equal to it, ends the move `Done`, and only
 * then are the positions moved and the trackers told, once. A half answered zero after its valid until is dead and a
 * new half is owed; the number of new halves per money on hold is bounded, so a wrong waiting time costs a bounded
 * number of sends.
 *
 * A bring home is a ticket whose first half is home's: a `BRING_HOME` that burns an away wallet's tokens, with its own
 * valid until, sent again the same way. Its receipt mints what was burned at the home wallet of the same identity, or
 * sends it back to the away wallet by a move out when that home wallet is no longer the identity's.
 *
 * The compliance reaches this by DELEGATECALL, from {ReceiptLib} and {TicketLib} or from its own entry point, so the
 * storage is its own namespaces, the token and the modules see the compliance as their caller, and every event is
 * the compliance's.
 */
library SecondHalfLib {

    /// @dev The most sends of one second half: its first send and two sends again.
    uint8 internal constant MAX_SENDS_PER_HALF = 3;

    /// @dev The most second halves one money on hold may have.
    uint8 internal constant MAX_NEW_HALVES = 4;

    /// @dev The gas a second half's send needs inside its receipt's delivery: below it the whole delivery reverts and
    ///  stays deliverable, so no relayer can make the send fail on purpose. From the plan's figure for one send on
    ///  the receipt route; to be replaced by a measured run.
    uint256 internal constant SECOND_HALF_SEND_GAS = 288_000;

    /* ----- The first half landed ----- */

    /// @dev See {IReceiptHandler-receiveReceipt}: a first-half receipt for a ticket whose receiver is on another
    ///  chain. Three steps, in one transaction, so the receiver's room is never left unreserved in between.
    /// @param token the token the compliance is bound to
    function takeOntoHold(
        bytes32 ticketId,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) external {
        ITickets.Ticket storage ticket = TicketLib.layout().validations[ticketId];
        uint256 amount = receipt.amount;

        // Step 1: the money goes on hold and the ask's row is released, so the rules judge the receiver without it.
        ticket.moved = amount;
        TicketLib.moveTo(ticket, ITickets.TicketStatus.OnHold, token);
        IToken(token).putOnHold(receipt.from, amount, ticketId);
        emit EventsLib.ReceiptApplied(ticketId, originChainKey, amount);

        // Step 2: forward to the receiver when it may take the money now, back to the sender otherwise.
        bool forward = _receiverMayTakeIt(ticket, receipt.to, amount, token);
        ticket.secondHalfToKey = ticket.fromKey;
        if (forward) ticket.secondHalfToKey = ticket.toKey;
        TicketLib.reserveTheHold(ticket);

        // Step 3: a home receiver is minted now; any other wallet gets its move out inside this delivery.
        (bool receiverAtHome,) = WalletKeyLib.isReferenceChain(receipt.to);
        if (forward && receiverAtHome) {
            _finish(ticket, ticketId, receipt.to, token);
            return;
        }
        bytes calldata wallet = receipt.from;
        if (forward) wallet = receipt.to;
        _takeANewHalf(ticket, ticketId);
        _trySendInsideTheDelivery(ticket, ticketId, wallet, token);
    }

    /// @dev See {ITickets-askToMove}: a home wallet that moves out. The ticket is written and its rules were asked at
    ///  the ask, which is the destination decision. The amount is burned at home onto hold and the move out leaves in
    ///  the same transaction; a send that fails reverts the whole ask.
    /// @param to the receiver's wallet, as asked
    /// @param token the token the compliance is bound to
    function moveOutFromHome(bytes32 ticketId, bytes calldata to, address token) external {
        ITickets.Ticket storage ticket = TicketLib.layout().validations[ticketId];
        (, address homeWallet) = WalletKeyLib.isReferenceChain(ticket.fromWallet);
        require(!IToken(token).isFrozen(homeWallet), ErrorsLib.FrozenWallet(homeWallet));
        // The ledger counts the wallet's balance under the owner it credited: a funded wallet relinked to another
        // identity is refused here, before its tokens leave, as a transfer out of it would be.
        ComplianceLedgerLib.currentOwner(token, homeWallet, ticket.fromIdentity, 0);

        uint256 amount = ticket.amountMax;
        ticket.moved = amount;
        TicketLib.moveTo(ticket, ITickets.TicketStatus.OnHold, token);
        ticket.secondHalfToKey = ticket.toKey;
        TicketLib.reserveTheHold(ticket);
        _takeANewHalf(ticket, ticketId);

        IToken(token).burnOntoHold(ticket.fromWallet, amount, ticketId);
        _sendTheLatestHalf(ticket, ticketId, to, token);
    }

    /* ----- A bring home ----- */

    /// @dev See {ITickets-bringHome}. Everything is checked first, then the ticket is written and its amount reserved,
    ///  then its half leaves: a send that fails reverts the whole bring home.
    /// @param token the token the compliance is bound to
    /// @return ticketId the id of the request, see {TicketLib-ticketIdOf}
    function bringHome(bytes calldata awayWallet, uint256 amount, address homeWallet, bytes32 salt, address token)
        external
        returns (bytes32 ticketId)
    {
        // Checks
        address identity;
        (ticketId, identity) = _checkTheBringHome(awayWallet, amount, homeWallet, salt, token);

        // Effects
        ITickets.Ticket storage ticket = _writeTheBringHome(ticketId, awayWallet, amount, homeWallet, identity);
        ticket.salt = salt;
        _announceTheBringHome(ticket, ticketId);
        _takeANewHalf(ticket, ticketId);
        _writeTheFirstSend(ticket, ticket.fromChainKey);

        // Interactions
        IToken(token).reserveForTicket(awayWallet, amount);
        _send(ticket, ticketId, ticket.fromChainKey, awayWallet, token);
    }

    /* ----- Anyone ----- */

    /// @dev See {ITickets-sendSecondHalf}.
    /// @param token the token the compliance is bound to
    function sendSecondHalf(bytes32 ticketId, bytes calldata wallet, address token) external {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        require(TicketLib.isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        ITickets.Ticket storage ticket = store.validations[ticketId];
        bool onHoldWithAHalf = ticket.status == ITickets.TicketStatus.OnHold && ticket.half != 0;
        bool anOpenBringHome = _isAnOpenBringHome(ticket);
        require(onHoldWithAHalf || anOpenBringHome, ErrorsLib.SecondHalfNotOwed(ticketId));
        require(WalletKeyLib.canonicalKey(wallet) == ticket.secondHalfToKey, ErrorsLib.ValidationBodyMismatch(ticketId));
        bytes32 chainKey = _chainKeyOf(wallet);
        TicketLib.requireTokenRunning(token);
        TicketLib.requireAwayChainNotBlocked(chainKey);
        TicketLib.requireNoHostileChange(token, chainKey);

        if (ticket.secondHalfOwed) {
            // A half whose send failed never left: it goes under its own number. A dead half is replaced.
            bool latestHalfLeft = ticket.secondHalfSends != 0;
            if (latestHalfLeft) _takeANewHalf(ticket, ticketId);
            _sendTheLatestHalf(ticket, ticketId, wallet, token);
            return;
        }

        require(ticket.secondHalfSends < MAX_SENDS_PER_HALF, ErrorsLib.SecondHalfNotOwed(ticketId));
        uint64 dueAt = _nextSendDueAt(ticket, store.waitingTimes[chainKey]);
        require(block.timestamp >= dueAt, ErrorsLib.SendNotDue(ticketId, dueAt));

        // Past its valid until by now: a half pinned to a pair the chain no longer has goes to the current pair, as a
        // new half, since its old away token can no longer be asked.
        if (!_pinnedToTheCurrentPair(ticketId, ticket.half, chainKey, token)) {
            _takeANewHalf(ticket, ticketId);
            _sendTheLatestHalf(ticket, ticketId, wallet, token);
            return;
        }

        ticket.secondHalfSends += 1;
        _send(ticket, ticketId, chainKey, wallet, token);
    }

    /* ----- The second half landed ----- */

    /// @dev See {IReceiptHandler-receiveReceipt}: a good receipt for a second half, see {ReceiptLib}. A zero answer to
    ///  the latest half says it arrived after its valid until and was never executed: the half is dead, the money
    ///  stays on hold, and a new half is owed. A receipt equal to the latest half ends the move. A zero answer to an
    ///  older half changes nothing: that half is dead already. A receipt naming the wallet it burned answers a bring
    ///  home, see {_applyBringHomeReceipt}: only a bring home burns.
    /// @param token the token the compliance is bound to
    function applySecondHalfReceipt(
        bytes32 ticketId,
        bytes32 originChainKey,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) external {
        ITickets.Ticket storage ticket = TicketLib.layout().validations[ticketId];
        emit EventsLib.ReceiptApplied(ticketId, originChainKey, receipt.amount);

        bool answersABringHome = receipt.from.length != 0;
        if (answersABringHome) {
            _applyBringHomeReceipt(ticket, ticketId, receipt, token);
            return;
        }

        bool answersTheLatestHalf = receipt.half == ticket.half;
        if (!answersTheLatestHalf) return;
        if (receipt.amount == 0) {
            ticket.secondHalfOwed = true;
            return;
        }
        _finish(ticket, ticketId, receipt.to, token);
    }

    /* ----- Private: a bring home ----- */

    /// @dev Everything a bring home is checked for, see {ITickets-bringHome}, before anything is written. The amount
    ///  must fit in what the away wallet has free, so no ticket and no bring home ever count on the same tokens.
    /// @return ticketId the id of the request
    /// @return identity the identity both wallets are linked to
    function _checkTheBringHome(
        bytes calldata awayWallet,
        uint256 amount,
        address homeWallet,
        bytes32 salt,
        address token
    ) private view returns (bytes32 ticketId, address identity) {
        require(amount != 0, ErrorsLib.ZeroValue());
        bytes32 walletKey = WalletKeyLib.satelliteKey(awayWallet);
        _requireChainTakesTheHalf(_chainKeyOf(awayWallet), token);
        identity = _identityOfBoth(awayWallet, homeWallet, token);
        bytes32 openTicketId = TicketLib.layout().openBringHome[walletKey];
        require(openTicketId == bytes32(0), ErrorsLib.BringHomeAlreadyOpen(walletKey, openTicketId));
        uint256 free = IToken(token).availableOf(awayWallet);
        require(amount <= free, ErrorsLib.RequestAboveBalance(awayWallet, free, amount));
        ticketId = _bringHomeIdOf(walletKey, amount, homeWallet, salt);
        require(!TicketLib.isRecorded(TicketLib.layout(), ticketId), ErrorsLib.TicketAlreadyWritten(ticketId));
    }

    /// @dev The away chain a bring home's half goes to: the token runs, the chain is not blocked and has no hostile
    ///  change running, and it has a waiting time to give the half its valid until.
    function _requireChainTakesTheHalf(bytes32 chainKey, address token) private view {
        TicketLib.requireTokenRunning(token);
        TicketLib.requireAwayChainNotBlocked(chainKey);
        TicketLib.requireNoHostileChange(token, chainKey);
        uint64 waitingTime = TicketLib.layout().waitingTimes[chainKey];
        require(waitingTime != 0, ErrorsLib.WaitingTimeNotSet(chainKey));
    }

    /// @dev The one identity both wallets are linked to: a bring home moves place, never owner. A revoked away wallet
    ///  still resolves, since a bring home is how a revoked position comes home.
    function _identityOfBoth(bytes calldata awayWallet, address homeWallet, address token)
        private
        view
        returns (address identity)
    {
        ITREXRegistry registry = _registryOf(token);
        identity = address(registry.identity(homeWallet));
        bool linkedToAnIdentity = identity != address(0);
        bool linkedToTheSameIdentity = identity == address(registry.resolveIdentity(awayWallet));
        require(linkedToAnIdentity && linkedToTheSameIdentity, ErrorsLib.WalletsNotLinked(homeWallet, awayWallet));
    }

    /// @dev The id of a bring home: the id of a ticket built from the request under the kind `BRING_HOME`, with no
    ///  spender and no minimum, since the away token burns what the wallet still holds.
    function _bringHomeIdOf(bytes32 walletKey, uint256 amount, address homeWallet, bytes32 salt)
        private
        view
        returns (bytes32)
    {
        bytes32 homeWalletKey = WalletKeyLib.canonicalKey(_homeEnvelopeOf(homeWallet));
        bytes32 noSpender = keccak256("");
        return
            TicketLib.ticketIdOf(ITickets.TicketKind.BRING_HOME, walletKey, homeWalletKey, noSpender, 0, amount, salt);
    }

    /// @dev Writes an open bring home: the away wallet is its sender, the home wallet its receiver, and its half goes
    ///  to the away wallet. One identity's two wallets, so nothing is reserved against identities, only the ledger's
    ///  total.
    ///  It counts as one of the identity's open tickets, which every ticket leaving its open row gives back, and is
    ///  never refused by the limits on asks: they bound what a holder asks. Home waits for it four waiting times after
    ///  its valid until, as for any ticket.
    function _writeTheBringHome(
        bytes32 ticketId,
        bytes calldata awayWallet,
        uint256 amount,
        address homeWallet,
        address identity
    ) private returns (ITickets.Ticket storage ticket) {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        ticket = store.validations[ticketId];
        bytes32 chainKey = _chainKeyOf(awayWallet);
        uint64 waitingTime = store.waitingTimes[chainKey];
        uint64 validUntil = uint64(block.timestamp) + waitingTime;

        ticket.kind = ITickets.TicketKind.BRING_HOME;
        ticket.homeWallet = homeWallet;
        ticket.amountMax = amount;
        ticket.requestedMax = amount;
        ticket.validUntil = validUntil;
        ticket.waitingTime = waitingTime;
        ticket.stopWaitingAt = validUntil + 4 * waitingTime;
        ticket.fromChainKey = chainKey;
        ticket.toChainKey = _chainKeyOf(_homeEnvelopeOf(homeWallet));
        ticket.fromKey = WalletKeyLib.canonicalKey(awayWallet);
        ticket.fromWallet = awayWallet;
        ticket.toKey = WalletKeyLib.canonicalKey(_homeEnvelopeOf(homeWallet));
        ticket.fromIdentity = identity;
        ticket.toIdentity = identity;
        ticket.status = ITickets.TicketStatus.Open;
        ticket.secondHalfToKey = ticket.fromKey;
        ticket.relocation = !ComplianceLedgerLib.reservePending(identity, identity, amount);

        if (ticket.stopWaitingAt > store.latestStopWaitingAt) store.latestStopWaitingAt = ticket.stopWaitingAt;
        store.identityAsks[identity].openTickets += 1;
        store.openBringHome[ticket.fromKey] = ticketId;
    }

    /// @dev Announces a written bring home as a ticket from the away wallet to the home wallet. It names no ask block
    ///  hash: no ticket copy leaves for it.
    function _announceTheBringHome(ITickets.Ticket storage ticket, bytes32 ticketId) private {
        emit EventsLib.TicketWritten(
            ticketId,
            ticket.fromWallet,
            _homeEnvelopeOf(ticket.homeWallet),
            "",
            0,
            ticket.amountMax,
            ticket.requestedMax,
            ticket.validUntil,
            bytes32(0),
            ticket.salt
        );
    }

    /// @dev A receipt for one of a bring home's halves, checked by {ReceiptLib}. Only the open bring home's latest half
    ///  moves anything; a zero answer to an older half changes nothing. The bring home is no longer open once its
    ///  latest half is answered. Nothing burned ends it `Done` with nothing moved, whether the half expired or burned
    ///  zero, and it is not sent again. What was burned is minted at the home wallet when that wallet is still the
    ///  identity's and verified, and sent back to the away wallet otherwise.
    function _applyBringHomeReceipt(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        MessageTypesLib.ReceiptMessage calldata receipt,
        address token
    ) private {
        bool answersTheOpenHalf =
            ticket.status == ITickets.TicketStatus.Open && receipt.half == ticket.half;
        if (!answersTheOpenHalf) return;
        delete TicketLib.layout().openBringHome[ticket.fromKey];

        bool nothingBurned = receipt.amount == 0;
        if (nothingBurned) {
            TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
            return;
        }

        ticket.moved = receipt.amount;
        if (_homeWalletStillTheirs(ticket, token)) {
            _mintAtHome(ticket, ticketId, token);
            return;
        }
        _sendBackToTheAwayWallet(ticket, ticketId, receipt.from, token);
    }

    /// @dev Whether the bring home's home wallet is still linked to the identity it was asked for, and verified.
    function _homeWalletStillTheirs(ITickets.Ticket storage ticket, address token) private view returns (bool) {
        ITREXRegistry registry = _registryOf(token);
        address homeWallet = ticket.homeWallet;
        bool linkedToTheSameIdentity = address(registry.identity(homeWallet)) == ticket.fromIdentity;
        bool verified = registry.isVerified(homeWallet);
        return linkedToTheSameIdentity && verified;
    }

    /// @dev Ends a bring home at its home wallet: what was burned leaves the away wallet and is minted there. The
    ///  position keeps its owner, so only the trackers are told, as a `RECALL`. A funded home wallet the ledger counts
    ///  under another identity reverts the delivery, which stays deliverable, as a transfer into it would be refused.
    function _mintAtHome(ITickets.Ticket storage ticket, bytes32 ticketId, address token) private {
        address homeWallet = ticket.homeWallet;
        address identity = ticket.fromIdentity;
        uint256 amount = ticket.moved;
        TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
        ComplianceLedgerLib.currentOwner(token, homeWallet, identity, 0);
        IToken(token).finishMove(ticket.fromWallet, _homeEnvelopeOf(homeWallet), amount, ticketId);

        bytes32 homeWalletId = WalletKeyLib.walletId(homeWallet);
        IModule.TransferContext memory context = TransferContextLib.settlement(
            address(this), MovementKindLib.RECALL, identity, identity, homeWalletId, homeWalletId, amount, ""
        );
        ModuleSetLib.callAfterTransfer(context);
    }

    /// @dev The home wallet is no longer the identity's, or not verified: what was burned goes on hold and back to the
    ///  away wallet by a move out, with no rule asked, since a return is an undo. It is new money on hold, so its
    ///  halves are counted from zero.
    function _sendBackToTheAwayWallet(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes calldata awayWallet,
        address token
    ) private {
        TicketLib.moveTo(ticket, ITickets.TicketStatus.OnHold, token);
        IToken(token).putOnHold(awayWallet, ticket.moved, ticketId);
        TicketLib.reserveTheHold(ticket);
        ticket.newHalves = 0;
        _takeANewHalf(ticket, ticketId);
        _trySendInsideTheDelivery(ticket, ticketId, awayWallet, token);
    }

    /// @dev Whether the ticket is a bring home whose half is still out: its half burns, every other half mints.
    function _isAnOpenBringHome(ITickets.Ticket storage ticket) private view returns (bool) {
        bool aBringHome = ticket.kind == ITickets.TicketKind.BRING_HOME;
        bool open = ticket.status == ITickets.TicketStatus.Open;
        return aBringHome && open;
    }

    /// @dev The ERC-7930 envelope of a wallet on this chain.
    function _homeEnvelopeOf(address homeWallet) private view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, homeWallet);
    }

    /* ----- Private ----- */

    /// @dev Ends the move on `toWallet` and the ticket `Done`. On a forward move the positions move and the trackers
    ///  are told, once, here: the sender's total owned counted the money on hold until now. A return moves no
    ///  position and tells no tracker: it is an undo.
    function _finish(ITickets.Ticket storage ticket, bytes32 ticketId, bytes calldata toWallet, address token) private {
        bool forward = ticket.secondHalfToKey == ticket.toKey;
        uint256 amount = ticket.moved;
        TicketLib.moveTo(ticket, ITickets.TicketStatus.Done, token);
        if (!forward) {
            IToken(token).finishMove(ticket.fromWallet, toWallet, amount, ticketId);
            return;
        }

        address toIdentity = _receiverIdentityNow(ticket, toWallet, token);
        IModule.TransferContext memory context = _doneMove(ticket, toWallet, toIdentity);
        ComplianceLedgerLib.movePosition(
            context.fromIdentity, context.toIdentity, context.fromWallet, context.toWallet, amount
        );
        IToken(token).finishMove(ticket.fromWallet, toWallet, amount, ticketId);
        ModuleSetLib.callAfterTransfer(context);
    }

    /// @dev The move as the trackers are told it, for the money on hold.
    function _doneMove(ITickets.Ticket storage ticket, bytes calldata toWallet, address toIdentity)
        private
        view
        returns (IModule.TransferContext memory)
    {
        return TransferContextLib.settlement(
            address(this),
            _kindOf(ticket),
            ticket.fromIdentity,
            toIdentity,
            WalletKeyLib.walletId(ticket.fromWallet),
            WalletKeyLib.walletId(toWallet),
            ticket.moved,
            ticket.spender
        );
    }

    /// @dev A home wallet's move out is a `DELEGATION`, any other move a `CROSS_CHAIN`.
    function _kindOf(ITickets.Ticket storage ticket) private view returns (uint8) {
        (bool senderAtHome,) = WalletKeyLib.isReferenceChain(ticket.fromWallet);
        if (senderAtHome) return MovementKindLib.DELEGATION;
        return MovementKindLib.CROSS_CHAIN;
    }

    /// @dev The receiver's identity when the move is done. A home receiver may have changed owner since the ask, so it
    ///  is resolved again through the registry; a wallet the registry no longer names keeps the identity it was
    ///  asked for. The token has not minted to it yet, which is why nothing is adjusted for this very move.
    function _receiverIdentityNow(ITickets.Ticket storage ticket, bytes calldata toWallet, address token)
        private
        returns (address)
    {
        address askedIdentity = ticket.toIdentity;
        (bool receiverAtHome, address homeReceiver) = WalletKeyLib.isReferenceChain(toWallet);
        if (!receiverAtHome) return askedIdentity;
        address registryIdentity = address(_registryOf(token).identity(homeReceiver));
        if (registryIdentity == address(0)) registryIdentity = askedIdentity;
        return ComplianceLedgerLib.currentOwner(token, homeReceiver, registryIdentity, 0);
    }

    /// @dev Whether the receiver may take the money now: it is eligible, its chain takes second halves (a home wallet
    ///  needs none), and the rules allow the amount, unless both wallets are one identity's.
    function _receiverMayTakeIt(ITickets.Ticket storage ticket, bytes calldata to, uint256 amount, address token)
        private
        view
        returns (bool)
    {
        bool receiverEligible = _registryOf(token).isWalletVerified(to);
        (bool receiverAtHome,) = WalletKeyLib.isReferenceChain(to);
        bool chainTakesIt = receiverAtHome || _awayChainTakesHalves(ticket.toChainKey, token);
        bool rulesAllowIt = ComplianceLedgerLib.isRelocation(ticket.fromIdentity, ticket.toIdentity);
        if (!rulesAllowIt) rulesAllowIt = amount <= ModuleSetLib.callCheckTransfer(_askedMove(ticket, to, amount));
        return receiverEligible && chainTakesIt && rulesAllowIt;
    }

    /// @dev The move as the rules are asked about it at the receipt.
    function _askedMove(ITickets.Ticket storage ticket, bytes calldata to, uint256 amount)
        private
        view
        returns (IModule.TransferContext memory)
    {
        return TransferContextLib.settlement(
            address(this),
            MovementKindLib.CROSS_CHAIN,
            ticket.fromIdentity,
            ticket.toIdentity,
            WalletKeyLib.walletId(ticket.fromWallet),
            WalletKeyLib.walletId(to),
            amount,
            ticket.spender
        );
    }

    /// @dev Whether an away chain takes a second half now: its receipt route is open, it is not blocked, and it has a
    ///  waiting time to give the half its valid until.
    function _awayChainTakesHalves(bytes32 chainKey, address token) private view returns (bool) {
        TicketLib.ValidationStorage storage store = TicketLib.layout();
        bool routeOpen = ITREXMessaging(token).isChainOpen(chainKey);
        bool blocked = store.blockedAwayChains[chainKey];
        bool hasAWaitingTime = store.waitingTimes[chainKey] != 0;
        return routeOpen && !blocked && hasAWaitingTime;
    }

    /// @dev Numbers a new second half, within the bound of new halves per money on hold, and announces the last one.
    function _takeANewHalf(ITickets.Ticket storage ticket, bytes32 ticketId) private {
        require(ticket.newHalves < MAX_NEW_HALVES, ErrorsLib.NoNewHalfLeft(ticketId));
        ticket.newHalves += 1;
        ticket.half += 1;
        if (ticket.newHalves == MAX_NEW_HALVES) emit EventsLib.NewHalfLimitReached(ticketId);
    }

    /// @dev Writes the first send of the latest half: its valid until is now plus its chain's waiting time.
    function _writeTheFirstSend(ITickets.Ticket storage ticket, bytes32 chainKey) private {
        uint64 waitingTime = TicketLib.layout().waitingTimes[chainKey];
        ticket.secondHalfValidUntil = uint64(block.timestamp) + waitingTime;
        ticket.secondHalfSends = 1;
        ticket.secondHalfOwed = false;
    }

    /// @dev Sends the latest half for the first time. A send that reverts reverts the caller's transaction.
    function _sendTheLatestHalf(ITickets.Ticket storage ticket, bytes32 ticketId, bytes calldata wallet, address token)
        private
    {
        bytes32 chainKey = _chainKeyOf(wallet);
        _writeTheFirstSend(ticket, chainKey);
        _send(ticket, ticketId, chainKey, wallet, token);
    }

    /// @dev Sends the latest half for the first time inside a receipt's delivery. Below `SECOND_HALF_SEND_GAS` the
    ///  whole delivery reverts and stays deliverable. A send that fails is caught: the receipt stays applied, and the
    ///  half stays owed under its own number for anyone to send.
    function _trySendInsideTheDelivery(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes calldata wallet,
        address token
    ) private {
        bytes32 chainKey = _chainKeyOf(wallet);
        _writeTheFirstSend(ticket, chainKey);
        bytes memory body = _moveOutBody(ticket, ticketId, wallet);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, ticket.half);

        uint256 gasLeft = gasleft();
        require(gasLeft >= SECOND_HALF_SEND_GAS, ErrorsLib.NotEnoughGasForTheSecondHalf(gasLeft, SECOND_HALF_SEND_GAS));
        try IToken(token).sendOnReceiptRoute(chainKey, halfKey, MessageTypesLib.Message.MOVE_OUT, body) {
            emit EventsLib.SecondHalfSent(
                ticketId, ticket.half, chainKey, wallet, ticket.moved, ticket.secondHalfValidUntil
            );
        } catch {
            ticket.secondHalfSends = 0;
            ticket.secondHalfOwed = true;
            emit EventsLib.SecondHalfNotSent(ticketId, ticket.half);
        }
    }

    /// @dev Sends the latest half as recorded: its number, its wallet, its amount and its valid until. The half of an
    ///  open bring home burns what it may take; any other half mints the money on hold.
    function _send(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes32 chainKey,
        bytes calldata wallet,
        address token
    ) private {
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, ticket.half);

        if (_isAnOpenBringHome(ticket)) {
            emit EventsLib.SecondHalfSent(
                ticketId, ticket.half, chainKey, wallet, ticket.amountMax, ticket.secondHalfValidUntil
            );
            bytes memory bringHomeBody = _bringHomeBody(ticket, ticketId, wallet);
            IToken(token).sendOnReceiptRoute(chainKey, halfKey, MessageTypesLib.Message.BRING_HOME, bringHomeBody);
            return;
        }

        emit EventsLib.SecondHalfSent(
            ticketId, ticket.half, chainKey, wallet, ticket.moved, ticket.secondHalfValidUntil
        );
        bytes memory moveOutBody = _moveOutBody(ticket, ticketId, wallet);
        IToken(token).sendOnReceiptRoute(chainKey, halfKey, MessageTypesLib.Message.MOVE_OUT, moveOutBody);
    }

    /// @dev The `BRING_HOME` of an open bring home's latest half, encoded.
    function _bringHomeBody(ITickets.Ticket storage ticket, bytes32 ticketId, bytes calldata wallet)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(
            MessageTypesLib.BringHomeMessage({
                ticketId: ticketId,
                half: ticket.half,
                wallet: wallet,
                amount: ticket.amountMax,
                validUntil: ticket.secondHalfValidUntil
            })
        );
    }

    /// @dev The `MOVE_OUT` of the latest half, encoded.
    function _moveOutBody(ITickets.Ticket storage ticket, bytes32 ticketId, bytes calldata wallet)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(
            MessageTypesLib.MoveOutMessage({
                ticketId: ticketId,
                half: ticket.half,
                toWallet: wallet,
                amount: ticket.moved,
                validUntil: ticket.secondHalfValidUntil
            })
        );
    }

    /// @dev When the latest half may be sent again: one waiting time after its valid until for the second send, two
    ///  more for the third. Fixed times, never counted from the last send, so a late send does not push the next one.
    function _nextSendDueAt(ITickets.Ticket storage ticket, uint64 waitingTime) private view returns (uint64) {
        uint64 sends = ticket.secondHalfSends;
        uint64 waitingTimesAfterValidUntil = sends * (sends + 1) / 2;
        return ticket.secondHalfValidUntil + waitingTimesAfterValidUntil * waitingTime;
    }

    /// @dev Whether the half is still pinned to the chain's current receipt route and peer.
    function _pinnedToTheCurrentPair(bytes32 ticketId, uint8 half, bytes32 chainKey, address token)
        private
        view
        returns (bool)
    {
        ITREXMessaging messaging = ITREXMessaging(token);
        (address pinnedBridge, bytes32 pinnedPeerKey) = messaging.pinOf(MessageTypesLib.halfKeyOf(ticketId, half));
        bool sameBridge = pinnedBridge == messaging.receiptRouteFor(chainKey);
        bool samePeer = pinnedPeerKey == keccak256(messaging.peerFor(chainKey));
        return sameBridge && samePeer;
    }

    /// @dev The registry of the token the compliance is bound to.
    function _registryOf(address token) private view returns (ITREXRegistry) {
        return ITREXRegistry(address(IToken(token).identityRegistry()));
    }

    function _chainKeyOf(bytes memory wallet) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) = WalletKeyLib.parse(wallet);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
