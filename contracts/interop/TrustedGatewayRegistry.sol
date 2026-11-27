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

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { AccessManagedOwnable } from "../utils/AccessManagedOwnable.sol";
import { ITrustedGatewayRegistry } from "./ITrustedGatewayRegistry.sol";

/**
 * @title TrustedGatewayRegistry
 * @dev The network's record of reviewed ERC-7786 bridges.
 *
 * A network singleton, deployed once per deployment and shared by every token. It is deliberately not
 * upgradeable and holds nothing but the records: whether each bridge is trusted, and the depth it waits for. A
 * distrusted bridge is never trusted again.
 */
contract TrustedGatewayRegistry is ITrustedGatewayRegistry, AccessManagedOwnable {

    /// @dev Whether a bridge is trusted, whether it was ever distrusted, and the depth it waits for (zero is full
    ///  finality).
    struct BridgeRecord {
        bool trusted;
        bool distrusted;
        uint64 depth;
    }

    mapping(address bridge => BridgeRecord record) private _records;

    constructor(address accessManager) AccessManagedOwnable(accessManager) {
        // The same line `setAuthority` holds later: an address with no code answers no to every `restricted` call.
        require(accessManager.code.length != 0, ErrorsLib.AccessManagerNotAContract(accessManager));
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function setTrustedGateway(address bridge, bool trusted, uint64 depth) external restricted {
        require(bridge != address(0), ErrorsLib.ZeroAddress());
        BridgeRecord storage record = _records[bridge];
        bool trustsADistrustedBridge = trusted && record.distrusted;
        require(!trustsADistrustedBridge, ErrorsLib.BridgeDistrusted(bridge));

        record.trusted = trusted;
        record.depth = depth;
        if (!trusted) record.distrusted = true;

        emit EventsLib.TrustedGatewaySet(bridge, trusted, depth);
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function isTrusted(address bridge) public view returns (bool) {
        return _records[bridge].trusted;
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function depthOf(address bridge) external view returns (uint64) {
        require(isTrusted(bridge), ErrorsLib.BridgeNotTrusted(bridge));
        return _records[bridge].depth;
    }

}
