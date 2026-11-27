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

    /// @dev Trusts a reviewed bridge at the depth, in blocks, it really waits for before it relays, or distrusts it.
    /// Zero is full finality: a token takes a receipt route, and every message it receives, only from a trusted
    /// bridge at depth zero. A provider with no depth setting is recorded at the depth it really has.
    ///
    /// The registry is shared, so a depth set again applies to every token on the network at once: a token reads the
    /// depth on every use. A distrusted bridge is never trusted again; a repaired bridge is deployed at a new address.
    ///
    /// A token calls `sendMessage` with no value and no attributes, so only a bridge that takes its fee out of
    /// band can carry its traffic. Review covers this too.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `bridge` must not be the zero address; otherwise reverts with `ZeroAddress`.
    /// - To trust `bridge`, it must never have been distrusted; otherwise reverts with `BridgeDistrusted`.
    ///
    /// Emits a `TrustedGatewaySet` event, including when nothing changed.
    /// @param bridge The reviewed ERC-7786 bridge.
    /// @param trusted True to trust the bridge at `depth`, false to distrust it for good.
    /// @param depth The depth, in blocks, the bridge waits for before it relays; zero for full finality.
    function setTrustedGateway(address bridge, bool trusted, uint64 depth) external;

    /// @dev Whether `bridge` is trusted right now. Callers read this when they rely on the bridge rather than
    /// caching it, so that a distrust takes effect at once.
    /// @param bridge The bridge to look up.
    /// @return True when the bridge is trusted.
    function isTrusted(address bridge) external view returns (bool);

    /// @dev The depth, in blocks, a trusted bridge waits for before it relays. Zero is full finality.
    ///
    /// Requirements:
    /// - `bridge` must be trusted; otherwise reverts with `BridgeNotTrusted`, so an unknown bridge is never read as
    ///   one at full finality.
    /// @param bridge The bridge to look up.
    /// @return The recorded depth.
    function depthOf(address bridge) external view returns (uint64);

}
