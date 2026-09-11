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

pragma solidity ^0.8.30;

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
    ///
    /// Two emergencies never revert and return `haltToken` instead: a leg already consumed, and an id that was
    /// never issued. Both mean a trusted gateway delivered something the protocol cannot account for, so the
    /// token pauses itself until an agent has investigated.
    /// @param originChainKey The key of the chain the notification came from, `keccak256(chainType, chainReference)`.
    /// @param notification The decoded settlement leg, exactly as the satellite sent it.
    /// @return haltToken Whether the token must pause itself: a replayed or never-issued settlement.
    function handleSettlement(bytes32 originChainKey, MessageTypesLib.SettlementNotification calldata notification)
        external
        returns (bool haltToken);

}
