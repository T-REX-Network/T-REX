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

    // ---- Scopes: every role id is derived from a scope and a role name ----

    // The explicit opt-in to one set of agents across every suite of a manager.
    bytes32 constant SHARED = keccak256("TREX-Suite.scope.shared");

    // ---- Operational roles (gate contract functions: "what you can do") ----

    bytes32 constant OWNER = keccak256("TREX-Suite.role.OWNER");

    bytes32 constant AGENT = keccak256("TREX-Suite.role.AGENT");
    bytes32 constant AGENT_MINTER = keccak256("TREX-Suite.role.AGENT_MINTER");
    bytes32 constant AGENT_BURNER = keccak256("TREX-Suite.role.AGENT_BURNER");
    bytes32 constant AGENT_PARTIAL_FREEZER = keccak256("TREX-Suite.role.AGENT_PARTIAL_FREEZER");
    bytes32 constant AGENT_ADDRESS_FREEZER = keccak256("TREX-Suite.role.AGENT_ADDRESS_FREEZER");
    bytes32 constant AGENT_RECOVERY_ADDRESS = keccak256("TREX-Suite.role.AGENT_RECOVERY_ADDRESS");
    bytes32 constant AGENT_FORCED_TRANSFER = keccak256("TREX-Suite.role.AGENT_FORCED_TRANSFER");
    bytes32 constant AGENT_PAUSER = keccak256("TREX-Suite.role.AGENT_PAUSER");

    bytes32 constant TOKEN_MANAGER = keccak256("TREX-Suite.role.TOKEN_MANAGER");
    bytes32 constant IDENTITY_MANAGER = keccak256("TREX-Suite.role.IDENTITY_MANAGER");

    // Gates publishing a suite version on TREXImplementationAuthority and rotating the beacons onto it.
    bytes32 constant VERSION_MANAGER = keccak256("TREX-Suite.role.VERSION_MANAGER");

    // ---- Role-giver roles (administer the operational roles via setRoleAdmin) ----
    // `*_ADMIN` always means "grants/revokes the same-named family of roles", matching
    // AccessManager's setRoleAdmin semantics. They let grants be delegated without
    // handing out the AccessManager ADMIN_ROLE (0).

    // Admin of AGENT and every granular AGENT_* role.
    bytes32 constant AGENT_ADMIN = keccak256("TREX-Suite.role.AGENT_ADMIN");

    // Admin of the token-config roles TOKEN_MANAGER and IDENTITY_MANAGER.
    bytes32 constant SUITE_ADMIN = keccak256("TREX-Suite.role.SUITE_ADMIN");

    // ---- Storage binding ----

    // Gates IdentityRegistryStorage.bindIdentityRegistry, so an issuer can bind a new IR onto a reused
    // IRS without standing OWNER. The factory never holds it: it deploys against a reused IRS without
    // binding, and the issuer binds afterwards.
    bytes32 constant IRS_BINDER = keccak256("TREX-Suite.role.IRS_BINDER");

    // ---- Roles resolved against the ONCHAINID IdentityFactory's authority ----

    // Gates minting of IdentityTypes.ASSET identities on the ONCHAINID IdentityFactory, which resolves
    // the per-type role against its own authority. TREXFactory must hold this role there to auto-mint a
    // token OID during deployTREXSuite; suites that always supply tokenDetails.ONCHAINID do not need it.
    bytes32 constant ASSET_DEPLOYER = keccak256("TREX-Suite.role.ASSET_DEPLOYER");

    function scopeOf(address target) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(target)));
    }

    function role(bytes32 scope, bytes32 name) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode("TREX-Suite", scope, name))));
    }

}
