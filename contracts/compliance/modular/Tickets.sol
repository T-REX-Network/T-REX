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
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedger } from "./ComplianceLedger.sol";
import { ITickets } from "./ITickets.sol";
import { TicketLib } from "./TicketLib.sol";

/**
 * @title Tickets
 * @dev The compliance's issuance layer for satellite movements: the two windows, the per-chain pause, the record
 * of every issued validation, the issuance itself, the pending reservation it writes, settlement, discard and the
 * late-reconciliation surface. Own ERC-7201 namespace, so the module registry's layout is untouched.
 *
 * Three flows, each readable top to bottom, each in a library deployed once and linked so the compliance stays
 * under the contract size limit: {TicketLib-request} issues, {ReceiptLib-receiveReceipt}
 * applies what a satellite executed, or parks what it executed under an id nothing is issued under,
 * {ReceiptLib-cancelTickets} rolls back what it never did. What stays here is the entry points of the first, the views and the settings. The reservation involves no
 * module: issuance writes the pending amounts into the ledger and the other two flows release them once.
 *
 * `from` is always a satellite wallet, never a native one: the Lite that executes a validation has to physically
 * hold the position it moves, where a native balance stays free to leave between issuance and settlement. A native
 * position reaches a satellite through delegation-out instead, which burns before it instructs.
 *
 * `validUntil` is the satellite's hard deadline; `validUntil + reconciliationWindow` is when T-REX may release the
 * reservation, never a refusal of a late leg. Validations expire; settlements never do.
 */
abstract contract Tickets is ITickets, ComplianceLedger {

    /* ----- Issuance ----- */

    /// @inheritdoc ITickets
    /// @dev The questions asked before anything is written, and the issuance, live in
    ///  {TicketLib-request}. A chain that already reported a leg under this id, parked while nothing
    ///  was issued, is not sent to; the parked leg is settled by {applyWaitingReceipt}, its own call, so nothing it
    ///  may revert on can keep the request from issuing.
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
    /// @dev The answer, the narrowing and the legs live in {TicketLib-answerApproval}; a leg parked
    ///  under the id waits for {applyWaitingReceipt} once it is issued, and stays parked when it is refused.
    function answerApproval(bytes32 ticketId, uint256 approvedMax) external {
        TicketLib.answerApproval(ticketId, approvedMax, address(_boundToken()));
    }

    /// @inheritdoc ITickets
    /// @dev The record does not keep `to`, which the caller supplies again with `spender`; the rebuilt leg
    ///  must hash to what was issued, see {TicketLib-resend}. Nothing is written: the
    ///  reservation, the id and the pinned route are those of the issuance, and the token refuses the send once
    ///  the leg's pinned gateway or peer is no longer the chain's.
    function sendTicket(bytes32 ticketId, bytes32 chainKey, bytes calldata to, bytes calldata spender) external {
        TicketLib.resend(
            ticketId,
            chainKey,
            to,
            spender,
            address(_boundToken()),
            _canCallSelector(msg.sender, this.sendTicket.selector)
        );
    }

    /* ----- Views ----- */

    /// @inheritdoc ITickets
    function defaultValidityWindow() public view returns (uint64) {
        return _validationStorage().defaultValidityWindow;
    }

    /// @inheritdoc ITickets
    function waitingTimeOf(bytes32 chainKey) public view returns (uint64) {
        return _validationStorage().waitingTimes[chainKey];
    }

    /// @inheritdoc ITickets
    function isIssuancePaused(bytes32 chainKey) public view returns (bool) {
        return _validationStorage().issuancePaused[chainKey];
    }

    /// @inheritdoc ITickets
    function waitingReceiptOf(bytes32 ticketId, bytes32 chainKey) public view returns (WaitingReceipt memory) {
        return _validationStorage().waitingReceipts[ticketId][chainKey];
    }

    /// @inheritdoc ITickets
    function ticketOf(bytes32 ticketId) public view returns (Ticket memory) {
        return _validationStorage().validations[ticketId];
    }

    /// @inheritdoc ITickets
    function statusOf(bytes32 ticketId) public view returns (TicketStatus) {
        TicketLib.ValidationStorage storage store = _validationStorage();
        require(TicketLib.isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        Ticket storage validation = store.validations[ticketId];
        // `Expired` is the one status never stored: it is `Open` once the clock has passed `waitingEndsAt`, or
        // `WaitingForApproval` once its deadline for an answer passed. Either way it can now be discarded. Every
        // other state is returned as it stands, including which leg a pair is still waiting for.
        bool pendingPastRelease = validation.status == TicketStatus.Open && block.timestamp > validation.waitingEndsAt;
        bool unansweredPastDeadline =
            validation.status == TicketStatus.WaitingForApproval && block.timestamp >= validation.validUntil;
        if (pendingPastRelease || unansweredPastDeadline) return TicketStatus.Expired;
        return validation.status;
    }

    /* ----- Settings ----- */

    function _setDefaultValidityWindow(uint64 duration) internal {
        require(duration != 0, ErrorsLib.ZeroDuration());
        _validationStorage().defaultValidityWindow = duration;
        emit EventsLib.DefaultValidityWindowSet(duration);
    }

    function _setReconciliationWindow(bytes32 chainKey, uint64 duration) internal {
        require(duration != 0, ErrorsLib.ZeroDuration());
        _validationStorage().waitingTimes[chainKey] = duration;
        emit EventsLib.WaitingTimeSet(chainKey, duration);
    }

    /* ----- What the compliance provides ----- */

    /// @dev The token this compliance is bound to.
    function _boundToken() internal view virtual returns (IToken);

    /// @dev The AccessManager of this compliance.
    function _authority() internal view virtual returns (address);

    /// @dev Whether the AccessManager lets `caller` call `selector` on this contract now.
    function _canCallSelector(address caller, bytes4 selector) internal view virtual returns (bool);

    function _validationStorage() internal pure returns (TicketLib.ValidationStorage storage) {
        return TicketLib.layout();
    }

}
