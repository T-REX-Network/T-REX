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
/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma solidity 0.8.30;

import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";

/**
 * @title ISettlementHandler
 * @dev The compliance contract's inbound entry point for satellite settlements.
 *
 * A settlement notification arrives at the token, which proves who sent it and forwards the body here
 * untouched.
 * The processing itself belongs to the compliance-slot lifecycle; only the entry point lives here.
 */
interface ISettlementHandler {

    /// @dev What the token does once a handler has judged an inbound message it could not apply.
    enum Verdict {
        /// The message was applied, or was a harmless duplicate: nothing for the token to do.
        Applied,
        /// The message names something the token issued but already accounted for, so that chain's reports can no
        /// longer be trusted: the token pauses its inbound from that chain only.
        PauseChain,
        /// The message names something the token never issued, so nothing attributes it to a chain's history: the
        /// token pauses itself.
        HaltToken
    }

    /// @dev Acts on a settlement the token has already attributed to its peer on `originChainKey`.
    ///
    /// The token guarantees three things:
    /// - the delivering gateway is trusted by the network,
    /// - it is the gateway the validation was dispatched through toward `originChainKey` (or the current
    /// route when the token never dispatched that id there),
    /// - the message's author is the token's peer on that chain.
    ///
    /// The notification is decoded and passed on as is; classifying it is this handler's job, against the
    /// validation it issued: the token and the wallets must be the issued ones, the leg must come from the chain
    /// recorded for its side, and the amount must sit inside the issued bounds. A leg that fails any of these
    /// reverts, which leaves the message deliverable again. A leg for a `Pending` validation settles it, whatever
    /// the clock says; one for a `Discarded` validation reconciles it late: applied anyway, since the satellite
    /// execution is final, the modules caught up with no live reservation, `LateReconciliation` emitted and the
    /// leg's chain paused for issuance until the manager unpauses it.
    /// A silent failure would instead leave the message marked as received and unretryable.
    ///
    /// Two emergencies never revert and return a verdict instead, both meaning a trusted gateway delivered
    /// something the protocol cannot account for. A leg already consumed, including one arriving after the keeper
    /// resolved the pair, is `PauseChain`: the validation is known, so the fault is pinned to the chain that sent
    /// it, and the token stops taking that chain's messages until an agent has investigated. An id that was never
    /// issued is `HaltToken`: nothing ties it to any chain's history, so the token pauses itself.
    /// @param originChainKey The key of the chain the notification came from.
    /// @param notification The decoded settlement leg, exactly as the satellite sent it.
    /// @return verdict `Applied`, `PauseChain` on a replayed leg, `HaltToken` on a never-issued id.
    function handleSettlement(bytes32 originChainKey, MessageTypesLib.SettlementNotification calldata notification)
        external
        returns (Verdict verdict);

}
