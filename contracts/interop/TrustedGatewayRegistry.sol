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
 * upgradeable and holds nothing but the records. Each bridge has one standing: a ticket bridge with its depth,
 * a receipt bridge, or distrusted. A record is written once, so one bridge can never be both kinds, and a
 * distrusted bridge is never trusted again.
 */
contract TrustedGatewayRegistry is ITrustedGatewayRegistry, AccessManagedOwnable {

    /// @dev The standing of a bridge, and the depth a ticket bridge waits for (zero is full finality).
    struct BridgeRecord {
        BridgeStanding standing;
        uint64 depth;
    }

    mapping(address bridge => BridgeRecord record) private _records;

    constructor(address accessManager) AccessManagedOwnable(accessManager) {
        // The same line `setAuthority` holds later: an address with no code answers no to every `restricted` call.
        require(accessManager.code.length != 0, ErrorsLib.AccessManagerNotAContract(accessManager));
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function trustTicketBridge(address bridge, uint64 depth) external restricted {
        _record(bridge, BridgeStanding.TicketBridge, depth);
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function trustReceiptBridge(address bridge) external restricted {
        _record(bridge, BridgeStanding.ReceiptBridge, 0);
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function distrustBridge(address bridge) external restricted {
        require(bridge != address(0), ErrorsLib.ZeroAddress());
        BridgeRecord storage record = _records[bridge];
        require(record.standing != BridgeStanding.Distrusted, ErrorsLib.BridgeDistrusted(bridge));

        record.standing = BridgeStanding.Distrusted;

        emit EventsLib.BridgeDistrusted(bridge);
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function isTrusted(address bridge) public view returns (bool) {
        BridgeStanding standing = _records[bridge].standing;
        return standing == BridgeStanding.TicketBridge || standing == BridgeStanding.ReceiptBridge;
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function isReceiptBridge(address bridge) external view returns (bool) {
        return _records[bridge].standing == BridgeStanding.ReceiptBridge;
    }

    /// @inheritdoc ITrustedGatewayRegistry
    function depthOf(address bridge) external view returns (uint64) {
        require(isTrusted(bridge), ErrorsLib.BridgeNotTrusted(bridge));
        return _records[bridge].depth;
    }

    /// @dev Writes the one record a bridge ever gets. Distrust is checked before "already recorded", so a
    ///  distrusted bridge is always refused with the reason that matters.
    function _record(address bridge, BridgeStanding standing, uint64 depth) private {
        require(bridge != address(0), ErrorsLib.ZeroAddress());
        BridgeRecord storage record = _records[bridge];
        require(record.standing != BridgeStanding.Distrusted, ErrorsLib.BridgeDistrusted(bridge));
        require(record.standing == BridgeStanding.Unknown, ErrorsLib.BridgeAlreadyRecorded(bridge));

        record.standing = standing;
        record.depth = depth;

        emit EventsLib.BridgeTrusted(bridge, standing, depth);
    }

}
