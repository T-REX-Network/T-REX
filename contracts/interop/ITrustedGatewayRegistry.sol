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

interface ITrustedGatewayRegistry {

    /// @dev What the network recorded about a bridge after reviewing it. A record is written once: a bridge whose
    /// behaviour changes is a new bridge, deployed at a new address and reviewed again.
    enum BridgeStanding {
        /// Never reviewed: it carries nothing for any token.
        Unknown,
        /// Carries tickets out, possibly before home's finality, at the depth it was recorded with. Never delivers
        /// anything to a token.
        TicketBridge,
        /// Carries money messages out and receipts in, only at full finality.
        ReceiptBridge,
        /// Distrusted for good: it is never trusted again.
        Distrusted
    }

    /// @dev Records a reviewed bridge that carries tickets, and the depth, in blocks, it really waits for before
    /// it relays. Zero is full finality. A provider with no depth setting is recorded at the depth it really has.
    ///
    /// A ticket moves nothing on its own, so a ticket bridge may relay before finality. It never delivers anything
    /// to a token: a token takes every incoming message through a receipt bridge only.
    ///
    /// A token calls `sendMessage` with no value and no attributes, so only a bridge that takes its fee out of
    /// band can carry its traffic. Review covers this too.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `bridge` must not be the zero address; otherwise reverts with `ZeroAddress`.
    /// - `bridge` must never have been distrusted; otherwise reverts with `BridgeDistrusted`.
    /// - `bridge` must not be recorded yet; otherwise reverts with `BridgeAlreadyRecorded`.
    ///
    /// Emits a `BridgeTrusted` event.
    /// @param bridge The reviewed ERC-7786 bridge.
    /// @param depth The depth, in blocks, the bridge waits for before it relays; zero for full finality.
    function trustTicketBridge(address bridge, uint64 depth) external;

    /// @dev Records a reviewed bridge that carries money messages out and receipts in. It waits for full finality
    /// by definition, so there is no depth to get wrong; a token still reads the bridge's own receiving policy.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `bridge` must not be the zero address; otherwise reverts with `ZeroAddress`.
    /// - `bridge` must never have been distrusted; otherwise reverts with `BridgeDistrusted`.
    /// - `bridge` must not be recorded yet; otherwise reverts with `BridgeAlreadyRecorded`.
    ///
    /// Emits a `BridgeTrusted` event.
    /// @param bridge The reviewed ERC-7786 bridge.
    function trustReceiptBridge(address bridge) external;

    /// @dev Distrusts `bridge` for good. An emergency lever: it severs every token route through the bridge with
    /// no further call, because routes are checked against this registry on use, not on write. A distrusted
    /// address is never trusted again; a repaired bridge is deployed at a new address.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `bridge` must not be the zero address; otherwise reverts with `ZeroAddress`.
    /// - `bridge` must not be distrusted already; otherwise reverts with `BridgeDistrusted`.
    ///
    /// Emits a `BridgeDistrusted` event.
    /// @param bridge The bridge to distrust.
    function distrustBridge(address bridge) external;

    /// @dev Whether `bridge` is a ticket bridge or a receipt bridge right now. Callers read this when they rely
    /// on the bridge rather than caching it, so that a distrust takes effect at once.
    /// @param bridge The bridge to look up.
    /// @return True when the bridge is recorded as a ticket bridge or a receipt bridge.
    function isTrusted(address bridge) external view returns (bool);

    /// @dev Whether `bridge` is a receipt bridge right now: the only kind a token takes a message from.
    /// @param bridge The bridge to look up.
    /// @return True when the bridge is recorded as a receipt bridge and not distrusted.
    function isReceiptBridge(address bridge) external view returns (bool);

    /// @dev The depth, in blocks, a trusted bridge waits for before it relays. Zero is full finality, and a
    /// receipt bridge always answers zero. For the off-chain tools that size the waiting times.
    ///
    /// Requirements:
    /// - `bridge` must be a ticket bridge or a receipt bridge; otherwise reverts with `BridgeNotTrusted`, so an
    ///   unknown bridge is never read as one at full finality.
    /// @param bridge The bridge to look up.
    /// @return The recorded depth.
    function depthOf(address bridge) external view returns (uint64);

}
