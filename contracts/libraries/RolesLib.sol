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

library RolesLib {

    bytes4 constant BIND_UNBIND_TOKEN = bytes4(0x6f7cc304);

    uint64 constant ROLE_PREFIX = uint64(uint256(keccak256("TREX-Suite"))) << 16;

    // ---- Operational roles (gate contract functions: "what you can do") ----

    uint64 constant OWNER = ROLE_PREFIX + 1;

    uint64 constant AGENT = ROLE_PREFIX + 2;
    uint64 constant AGENT_MINTER = ROLE_PREFIX + 3;
    uint64 constant AGENT_BURNER = ROLE_PREFIX + 4;
    uint64 constant AGENT_PARTIAL_FREEZER = ROLE_PREFIX + 5;
    uint64 constant AGENT_ADDRESS_FREEZER = ROLE_PREFIX + 6;
    uint64 constant AGENT_RECOVERY_ADDRESS = ROLE_PREFIX + 7;
    uint64 constant AGENT_FORCED_TRANSFER = ROLE_PREFIX + 8;
    uint64 constant AGENT_PAUSER = ROLE_PREFIX + 9;

    uint64 constant TOKEN_MANAGER = ROLE_PREFIX + 10;
    uint64 constant IDENTITY_MANAGER = ROLE_PREFIX + 11;

    // ---- Role-giver roles (administer the operational roles via setRoleAdmin) ----
    // `*_ADMIN` always means "grants/revokes the same-named family of roles", matching
    // AccessManager's setRoleAdmin semantics. They let grants be delegated without
    // handing out the AccessManager ADMIN_ROLE (0).

    // Admin of AGENT and every granular AGENT_* role.
    uint64 constant AGENT_ADMIN = ROLE_PREFIX + 12;

    // Admin of the token-config roles TOKEN_MANAGER and IDENTITY_MANAGER.
    uint64 constant SUITE_ADMIN = ROLE_PREFIX + 13;

    // ---- Deploy-time transient roles (self-granted for a single call, revoked before returning) ----

    // Gates IdentityRegistryStorage.bindIdentityRegistry so the factory can bind a new IR onto a reused
    // IRS during deployTREXSuite without standing OWNER. Unassigned at rest, self-granted for the bind call
    // and revoked before returning. Not a hard boundary: the factory's AGENT_ADMIN admins it and can re-grant.
    uint64 constant IRS_BINDER = ROLE_PREFIX + 14;

}
