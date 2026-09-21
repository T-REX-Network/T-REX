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

import { ErrorsLib } from "./ErrorsLib.sol";

library RolesLib {

    bytes4 constant BIND_UNBIND_TOKEN = bytes4(0x6f7cc304);

    // ---- Suite roles. A role id is a namespace id in the upper 32 bits and a role number below ----

    enum Role {
        OWNER,
        AGENT,
        AGENT_MINTER,
        AGENT_BURNER,
        AGENT_PARTIAL_FREEZER,
        AGENT_ADDRESS_FREEZER,
        AGENT_RECOVERY_ADDRESS,
        AGENT_FORCED_TRANSFER,
        AGENT_PAUSER,
        TOKEN_MANAGER,
        IDENTITY_MANAGER,
        AGENT_ADMIN,
        SUITE_ADMIN,
        IRS_BINDER,
        IRS_WRITER
    }

    // ---- Platform roles: factory, implementation authority and identity factory governance ----

    enum PlatformRole {
        OWNER,
        VERSION_MANAGER,
        ASSET_DEPLOYER
    }

    uint32 constant PLATFORM_NAMESPACE = type(uint32).max;

    // Role numbers start at 1 so no standard role packs to a zero role number.
    uint32 constant ROLE_NUMBER_OFFSET = 1;

    // Custom roles hash their name into the upper half of the role number, so a decoder can tell them apart.
    uint32 constant CUSTOM_ROLE_FLAG = 0x80000000;

    function forNamespace(uint32 namespaceId, Role role) internal pure returns (uint64) {
        return _pack(namespaceId, uint32(role) + ROLE_NUMBER_OFFSET);
    }

    function forNamespace(uint32 namespaceId, bytes32 customName) internal pure returns (uint64) {
        return _pack(namespaceId, uint32(uint256(keccak256(abi.encode(customName)))) | CUSTOM_ROLE_FLAG);
    }

    function platform(PlatformRole role) internal pure returns (uint64) {
        return _pack(PLATFORM_NAMESPACE, uint32(role) + ROLE_NUMBER_OFFSET);
    }

    function decode(uint64 roleId) internal pure returns (uint32 namespaceId, uint32 roleNumber, bool custom) {
        namespaceId = uint32(roleId >> 32);
        roleNumber = uint32(roleId);
        custom = roleNumber & CUSTOM_ROLE_FLAG != 0;
    }

    function _pack(uint32 namespaceId, uint32 roleNumber) private pure returns (uint64 roleId) {
        require(namespaceId != 0, ErrorsLib.InvalidNamespace());
        roleId = (uint64(namespaceId) << 32) | roleNumber;
        require(roleId != type(uint64).max, ErrorsLib.InvalidNamespace());
    }

}
