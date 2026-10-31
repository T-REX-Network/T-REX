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
        /// Nothing for the token to do: the message was applied, or was a harmless duplicate.
        None,
        /// The message names something the token issued but already accounted for, so that chain's reports can no
        /// longer be trusted: the token pauses its inbound from that chain only.
        PauseChain,
        /// The message names a recall the token never issued. The transport says which chain sent it, but not why
        /// the id is unknown: a peer inventing ids, or the token's own records no longer matching what it dispatched
        /// (a token reset with instructions in flight). The second is local and taints what every chain reports,
        /// and the message cannot tell the two apart, so the token pauses itself. The price, accepted: a trusted
        /// peer can halt the token with one such proof; the remedy is to distrust its gateway. A settlement never
        /// returns this: a validation id is a function of the request, so an unknown one is the leg's chain's
        /// problem, see {handleSettlement}.
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
    /// validation it issued. The gate is substantive: the wallets must be the issued ones, the leg must come from
    /// the chain recorded for its side, and the amount must sit inside the issued bounds. A leg that passes it for
    /// a `Pending` validation settles it, whatever the clock says; one for a `Discarded` validation reconciles it
    /// late: applied anyway, since the satellite execution is final, the modules caught up with no live
    /// reservation, `LateReconciliation` emitted and the leg's chain paused for issuance until the manager
    /// unpauses it. The hash the leg carries is evidence, never the gate: a leg inside the terms settles whatever
    /// hash it names (`SettlementBodyDiverged` when it is not the issued one).
    ///
    /// Nothing on this path reverts for good. A validation may travel to a satellite before this chain's finality,
    /// so a leg the token cannot account for has a reorg as a possible cause as well as a Lite breaking a rule,
    /// and the two are given the same outcome: nothing applied, the delivery consumed, and `PauseChain`, so the
    /// token stops taking that chain's messages until an agent has investigated. The burden is the Lite's: one
    /// that executes before finality owns the reorg exposure, and the token bounds it to that chain. Four cases:
    /// - An id with no issued body: the leg is parked under its id and origin chain (`SettlementParked`), so the
    ///   request, sent again with the same salt, issues the same id, and `settleParkedLeg` then judges it as any
    ///   leg. A second leg from the same chain for a parked id is a replay.
    /// - A leg already accounted for, including one arriving after the keeper resolved the pair, or for a
    ///   validation ended `Orphaned`: a replay (`ReplayedSettlement`).
    /// - A leg outside the issued terms carrying the issued hash: the Lite broke a rule on the body this chain
    ///   issued (`SettlementRejected`); the validation stands, the discard and resolution paths still apply.
    /// - A leg outside the issued terms carrying another hash, from a chain the validation involves: the satellite
    ///   executed a body this chain never canonically issued (`ValidationOrphaned`). While `Pending` the validation
    ///   ends `Orphaned` and its reservation is released; otherwise it stands. From any other chain the leg is
    ///   rejected whatever hash it names: that chain could not have executed anything under the id.
    /// A revert, from a tracker module for instance, leaves the message deliverable again; a silent failure would
    /// instead leave it marked as received and unretryable.
    /// @param originChainKey The key of the chain the notification came from.
    /// @param notification The decoded settlement leg, exactly as the satellite sent it.
    /// @return verdict `None` when applied, `PauseChain` on every leg the token could not account for.
    function handleSettlement(bytes32 originChainKey, MessageTypesLib.SettlementNotification calldata notification)
        external
        returns (Verdict verdict);

}
