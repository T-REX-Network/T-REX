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

import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";

contract TREXAccessManager is AccessManagerUpgradeable {

    /// @custom:storage-location erc7201:erc3643.storage.TREXAccessManager
    struct NamespaceStorage {
        uint32 count;
        mapping(uint32 namespaceId => string name) names;
        mapping(address target => uint32 namespaceId) namespaceOf;
    }

    bytes32 private constant NAMESPACE_STORAGE_LOCATION =
        0x9ee5333472569314e77d439560942818930bfd1bd85e664704fdf0ed68f91e00;

    modifier onlyAdmin() {
        (bool isAdmin, uint32 executionDelay) = hasRole(ADMIN_ROLE, _msgSender());
        require(
            isAdmin && executionDelay == 0, IAccessManager.AccessManagerUnauthorizedAccount(_msgSender(), ADMIN_ROLE)
        );
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function createNamespace(string calldata name) external onlyAdmin returns (uint32 namespaceId) {
        NamespaceStorage storage $ = _getNamespaceStorage();
        namespaceId = ++$.count;
        $.names[namespaceId] = name;
        emit EventsLib.NamespaceCreated(namespaceId, name);
    }

    function assign(uint32 namespaceId, address target) external onlyAdmin {
        NamespaceStorage storage $ = _getNamespaceStorage();
        require(namespaceId != 0 && namespaceId <= $.count, ErrorsLib.NamespaceNotFound(namespaceId));
        require(target != address(0), ErrorsLib.ZeroAddress());
        $.namespaceOf[target] = namespaceId;
        emit EventsLib.NamespaceAssigned(namespaceId, target);
    }

    function namespaceOf(address target) external view returns (uint32) {
        return _getNamespaceStorage().namespaceOf[target];
    }

    function namespaceName(uint32 namespaceId) external view returns (string memory) {
        return _getNamespaceStorage().names[namespaceId];
    }

    function namespaceCount() external view returns (uint32) {
        return _getNamespaceStorage().count;
    }

    function _getNamespaceStorage() private pure returns (NamespaceStorage storage $) {
        assembly ("memory-safe") {
            $.slot := NAMESPACE_STORAGE_LOCATION
        }
    }

}
