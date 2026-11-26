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
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedger } from "./ComplianceLedger.sol";
import { ITickets } from "./ITickets.sol";
import { SecondHalfLib } from "./SecondHalfLib.sol";
import { TicketLib } from "./TicketLib.sol";

/**
 * @title Tickets
 * @dev The compliance's issuance layer for satellite movements: the validity windows, the waiting times and their
 * floors, the limits on asks, the block of an away chain, the record of every ticket, the ask itself, the pending
 * reservation it writes, the ask for the receipt, the receipt and the cancel. Own ERC-7201 namespace, so the module registry's layout is untouched.
 *
 * Four flows, each readable top to bottom, each in a library deployed once and linked so the compliance stays
 * under the contract size limit: {TicketLib-request} issues, {ReceiptLib-receiveReceipt} records what an away
 * token reports it did, {SecondHalfLib} carries a move that leaves its away chain through home, and
 * {ReceiptLib-cancelTickets} rolls back what an away token never did. What stays here is the entry points, the views
 * and the settings. The reservation involves no module: issuance writes the pending amounts into the ledger and the
 * other flows release them once.
 *
 * A ticket goes to the sender's away chain only: the away token that executes it physically holds the position it
 * moves. A home wallet has no ticket to execute: its move out burns at home in the ask and is a second half only.
 *
 * `validUntil` is the satellite's hard deadline. One waiting time later anyone may ask the away token for the
 * receipt, and one waiting time after an unanswered ask anyone may cancel the ticket, never a refusal of a late
 * receipt. Tickets expire; receipts never do.
 */
abstract contract Tickets is ITickets, ComplianceLedger {

    /* ----- Issuance ----- */

    /// @inheritdoc ITickets
    /// @dev The questions asked before anything is written, and the issuance, live in {TicketLib-request}.
    function askToMove(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender,
        bytes32 salt
    ) external returns (bytes32 ticketId) {
        return TicketLib.request(
            from, to, requestedMin, requestedMax, spender, salt, address(_boundToken()), _authority()
        );
    }

    /// @inheritdoc ITickets
    /// @dev The answer and the narrowing live in {TicketLib-answerApproval}; the first send is anyone's, with
    ///  {sendTicket}. A receipt that came before the first send is put on hold, never applied as the ticket's move.
    function answerApproval(bytes32 ticketId, uint256 approvedMax) external {
        TicketLib.answerApproval(ticketId, approvedMax, address(_boundToken()));
    }

    /// @inheritdoc ITickets
    /// @dev Not `restricted`: anyone makes the first send of an approved ticket, and anyone asks for a receipt at the
    ///  times the ticket's clock gives, see {TicketLib-sendTicket}. The reservation, the id and the route are those of
    ///  the ask.
    function sendTicket(bytes32 ticketId, bytes32 chainKey, bytes calldata to, bytes calldata spender) external {
        TicketLib.sendTicket(ticketId, chainKey, to, spender, address(_boundToken()));
    }

    /// @inheritdoc ITickets
    /// @dev Not `restricted`: anyone may send an owed second half, at the times its clock gives, see
    ///  {SecondHalfLib-sendSecondHalf}.
    function sendSecondHalf(bytes32 ticketId, bytes calldata wallet) external {
        SecondHalfLib.sendSecondHalf(ticketId, wallet, address(_boundToken()));
    }

    /* ----- Views ----- */

    /// @inheritdoc ITickets
    function validityWindows() public view returns (ValidityWindows memory) {
        return _validationStorage().validityWindows;
    }

    /// @inheritdoc ITickets
    function measuredTimesOf(bytes32 chainKey) public view returns (MeasuredTimes memory) {
        return _validationStorage().measuredTimes[chainKey];
    }

    /// @inheritdoc ITickets
    function areAsksPaused() public view returns (bool) {
        return _validationStorage().asksPaused;
    }

    /// @inheritdoc ITickets
    function askLimits() public view returns (AskLimits memory) {
        return _validationStorage().askLimits;
    }

    /// @inheritdoc ITickets
    function askLimitOf(address identity) public view returns (uint32) {
        return TicketLib.askLimitOf(_validationStorage(), identity);
    }

    /// @inheritdoc ITickets
    function waitingTimeOf(bytes32 chainKey) public view returns (uint64) {
        return _validationStorage().waitingTimes[chainKey];
    }

    /// @inheritdoc ITickets
    function isAwayChainBlocked(bytes32 chainKey) public view returns (bool) {
        return _validationStorage().blockedAwayChains[chainKey];
    }

    /// @inheritdoc ITickets
    function ticketLimitsOf(bytes32 chainKey) public view returns (TicketLimits memory) {
        return _validationStorage().ticketLimits[chainKey];
    }

    /// @inheritdoc ITickets
    function waitingReceiptOf(bytes32 halfKey) public view returns (WaitingReceipt memory) {
        return _validationStorage().waitingReceipts[halfKey];
    }

    /// @inheritdoc ITickets
    function ticketOf(bytes32 ticketId) public view returns (Ticket memory) {
        return _validationStorage().validations[ticketId];
    }

    /// @inheritdoc ITickets
    function uncountedCreditOf(bytes calldata wallet) public view returns (uint256) {
        return _validationStorage().uncountedCredit[WalletKeyLib.canonicalKey(wallet)];
    }

    /// @inheritdoc ITickets
    function statusOf(bytes32 ticketId) public view returns (TicketStatus) {
        TicketLib.ValidationStorage storage store = _validationStorage();
        require(TicketLib.isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        return store.validations[ticketId].status;
    }

    /* ----- Settings ----- */

    function _setAsksPaused(bool paused) internal {
        _validationStorage().asksPaused = paused;
        emit EventsLib.AsksPausedSet(paused);
    }

    function _setAskLimits(AskLimits calldata limits) internal {
        require(limits.askWindow != 0, ErrorsLib.ZeroDuration());
        _validationStorage().askLimits = limits;
        emit EventsLib.AskLimitsSet(limits);
    }

    function _setAskLimitOf(address identity, uint32 asksPerWindow) internal {
        _validationStorage().askLimitOverrides[identity] = asksPerWindow;
        emit EventsLib.AskLimitOfSet(identity, asksPerWindow);
    }

    function _setTicketLimits(bytes32 chainKey, uint256 perTicketCap, uint256 perWindowCap) internal {
        TicketLib.ValidationStorage storage store = _validationStorage();
        TicketLimits storage limits = store.ticketLimits[chainKey];
        bool lowersThePerTicketCap = perTicketCap < limits.perTicketCap;
        if (lowersThePerTicketCap) {
            uint64 allowedAt = store.latestValidUntilSent[chainKey];
            require(block.timestamp >= allowedAt, ErrorsLib.PerTicketCapLoweredTooEarly(chainKey, allowedAt));
        }
        limits.perTicketCap = perTicketCap;
        limits.perWindowCap = perWindowCap;
        emit EventsLib.TicketLimitsSet(chainKey, perTicketCap, perWindowCap);
    }

    /* ----- What the compliance provides ----- */

    /// @dev The token this compliance is bound to.
    function _boundToken() internal view virtual returns (IToken);

    /// @dev The AccessManager of this compliance.
    function _authority() internal view virtual returns (address);

    function _validationStorage() internal pure returns (TicketLib.ValidationStorage storage) {
        return TicketLib.layout();
    }

}
