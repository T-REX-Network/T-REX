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

    /// @dev Takes in a receipt the token has already attributed to its peer on `originChainKey`.
    ///
    /// The token guarantees three things:
    /// - the delivering bridge is a receipt bridge of the network,
    /// - it is the bridge the half was pinned to, or the chain's current receipt route,
    /// - the message's author is the token's peer on that chain.
    ///
    /// Home records what the receipt reports, because the away token's balances already moved. In order:
    /// - The same receipt again, under the same half, from the same chain: changes nothing (`ReceiptDuplicate`).
    ///   When that receipt is waiting and can now be applied, the repeat applies it (`WaitingReceiptApplied`).
    /// - A still open answer: never takes the half. For an open ticket from its own chain it may raise the ticket's
    ///   `seenValidUntil`, up to valid until plus the chain's full finality delivery and clock lead
    ///   (`TicketStillOpen`), and gives an ask for the receipt back when it does; past that cap it counts as no
    ///   answer. On home's own ask block hash with another valid until it is a bad receipt. Otherwise ignored.
    /// - A second half of an id home has no record of: refused and announced (`ReceiptUnknown`); nothing is written
    ///   and no chain is blocked.
    /// - A first-half receipt that no ticket home sent answers: an id home has no record of, or a move home wrote and
    ///   never sent, waiting for approval or cancelled before it left. It is a bad receipt when another body came for
    ///   the id, when its sender is not on the chain that sent it, when its receiver is not a well formed wallet, when
    ///   an expired answer moved something, or, for a
    ///   ticket home wrote, when it names other wallets. Otherwise it waits like any receipt, while the token is
    ///   stopped, its chain is blocked, its sender has no identity or cannot cover the amount with its away balance
    ///   and the uncounted credit it may carry. Then its hash is written and it is booked: a zero receipt, or one from a
    ///   wallet to itself, ends the id `Done`; any other puts its amount on hold under the sender with no destination,
    ///   gives uncounted credit to a receiver on the same away chain, and blocks nobody (`ReceiptWithoutTicket`). The
    ///   same ask mined again takes it; otherwise anyone cancels it with `cancelHold`.
    /// - A bad receipt: another body for a half that already has one, applied or waiting. For the ticket's own half:
    ///   a chain that is not the sender's, wallets that are not the ticket's, or an expired answer that moved
    ///   something. For a second half, or a half of the cancel of money on hold: a half home never sent, a wallet
    ///   that is not the half's, a chain that is not the one that wallet is on, a sender named, or anything but a
    ///   mint of the money on hold or a zero answer that the half expired; an older half may only answer zero. It is refused (`ReceiptRefused`), nothing is applied,
    ///   and the chain that sent it is blocked.
    /// - A receipt that cannot be applied yet: the token is stopped or its away chain is blocked; for the ticket's own
    ///   half, also the sender's away balance is below its amount. It waits (`ReceiptWaiting`), tagged with `bridge`
    ///   and `senderPeerKey`, for anyone to apply with `applyWaitingReceipt`. It is judged again when it is applied,
    ///   against the record as it is then: a ticket written meanwhile makes a receipt naming other wallets bad.
    /// - A zero receipt for the ticket's own half: the ticket ends `Done` with nothing moved. It is never a bad
    ///   receipt. A zero answer to the latest second half: that half is dead, the money stays on hold, and a new
    ///   half is owed (`sendSecondHalf`).
    /// - Any other receipt for the ticket's own half is applied as it happened. The terms check decides whether the
    ///   chain is also blocked: on home's own ask block hash the receipt must carry home's own terms; on another ask
    ///   block hash it is a copy from a dropped home block (`ReceiptOnOlderTerms`), allowed up to `requestedMax` and
    ///   the away chain's per-ticket cap. A move inside one away chain ends `Done`, and a rule it breaks now is
    ///   announced (`MoveBreachedRule`), never refused. A move to another chain goes `OnHold`, the rules are asked
    ///   again for the receiver, and a receiver at home is minted at once (`Done`); otherwise the second half, a
    ///   `MOVE_OUT`, is sent to the receiver, or back to the sender when the rules refuse it, inside this delivery
    ///   (`SecondHalfSent`). With less gas left than the send needs, the whole delivery reverts and stays
    ///   deliverable (`NotEnoughGasForTheSecondHalf`); a send that fails is caught (`SecondHalfNotSent`) and the
    ///   half stays owed.
    /// - A receipt equal to the latest second half: the money on hold lands on its wallet and the ticket ends
    ///   `Done`. The positions move and the trackers are told once, here, on a move to the receiver only.
    /// A revert, from a tracker module for instance, leaves the message deliverable again.
    /// @param originChainKey The key of the chain the receipt came from.
    /// @param bridge The bridge that delivered it.
    /// @param senderPeerKey The `keccak256` of the peer that sent it.
    /// @param notification The decoded receipt, exactly as the away token sent it.
    function receiveReceipt(
        bytes32 originChainKey,
        address bridge,
        bytes32 senderPeerKey,
        MessageTypesLib.ReceiptMessage calldata notification
    ) external;

}
