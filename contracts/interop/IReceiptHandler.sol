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

/**
 * @title IReceiptHandler
 * @dev The compliance contract's entry point for receipts from away chains.
 *
 * A receipt arrives at the token, which proves who sent it and forwards the body here untouched. What the receipt
 * does to the ticket belongs to the compliance; only the entry point lives here.
 */
interface IReceiptHandler {

    /// @dev What the token does once the handler took in a receipt.
    enum Verdict {
        /// Nothing for the token to do.
        None,
        /// The receipt is bad: the token blocks the away chain that sent it, and that chain alone. The token itself
        /// is never stopped by a receipt.
        PauseChain
    }

    /// @dev Takes in a receipt the token has already attributed to its peer on `originChainKey`.
    ///
    /// The token guarantees three things:
    /// - the delivering bridge is a receipt bridge of the network,
    /// - it is the bridge the half was pinned to, or the chain's current receipt route,
    /// - the message's author is the token's peer on that chain.
    ///
    /// Home records what the receipt reports, because the away token's balances already moved. In order:
    /// - The same receipt again, under the same half, from the same chain: changes nothing (`ReceiptDuplicate`).
    /// - A still open answer: changes nothing.
    /// - An id home has no record of: reverts with `UnknownTicket`, and stays deliverable at the bridge.
    /// - A bad receipt: another body for a half that already has one, a chain that is not the sender's, wallets
    ///   that are not the ticket's, a half the ticket never sent, or an expired answer that moved something. It is
    ///   refused (`ReceiptRefused`), nothing is applied, and the chain that sent it is blocked.
    /// - A receipt for a ticket never sent: kept as a waiting receipt (`ReceiptWaiting`).
    /// - A zero receipt: the ticket ends `Done` with nothing moved. It is never a bad receipt.
    /// - Any other receipt is applied as it happened and the ticket ends `Done`. A rule the move breaks now is
    ///   announced (`MoveBreachedRule`), never refused. The terms check then decides whether the chain is also
    ///   blocked: on home's own ask block hash the receipt must carry home's own terms; on another ask block hash it
    ///   is a copy from a dropped home block (`ReceiptOnOlderTerms`), allowed up to `requestedMax` and the away
    ///   chain's per-ticket cap.
    /// A revert, from a tracker module for instance, leaves the message deliverable again.
    /// @param originChainKey The key of the chain the receipt came from.
    /// @param notification The decoded receipt, exactly as the away token sent it.
    /// @return verdict `PauseChain` when the sending chain must be blocked, `None` otherwise.
    function receiveReceipt(bytes32 originChainKey, MessageTypesLib.ReceiptMessage calldata notification)
        external
        returns (Verdict verdict);

}
