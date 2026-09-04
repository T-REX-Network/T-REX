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

import { Version } from "../../libraries/VersionLib.sol";

interface ITREXImplementationAuthority {

    /// types
    struct SuiteImplementations {
        // address of token implementation contract
        address tokenImplementation;
        // address of TREXRegistry (merged registry) implementation contract
        address trexRegistryImplementation;
        // address of IdentityRegistryStorage implementation contract
        address irsImplementation;
        // address of ModularCompliance implementation contract
        address mcImplementation;
    }

    struct SuiteBeacons {
        // address of UpgradeableBeacon for Token
        address tokenBeacon;
        // address of UpgradeableBeacon for TREXRegistry
        address trexRegistryBeacon;
        // address of UpgradeableBeacon for IdentityRegistryStorage
        address irsBeacon;
        // address of UpgradeableBeacon for ModularCompliance
        address mcBeacon;
    }

    /// functions

    /**
     *  @dev archives a new version's implementations without touching any beacon.
     *  The beacons (and therefore every live shared-mode suite) keep pointing at the active version
     *  until a separate `upgrade(version)` call rotates them.
     *  @param version the new version to publish
     *  @param impls the set of implementations corresponding to the new version
     *  reverts if the version was already published
     *  reverts if any implementation address is zero
     *  only VERSION_MANAGER can call
     *  emits a `VersionPublished` event
     */
    function publish(Version version, SuiteImplementations calldata impls) external;

    /**
     *  @dev rotates every beacon to the implementations archived for a previously published version.
     *  Drives every shared-mode suite to that version atomically and marks it as the active version.
     *  Only moves forward: the target must rank above the active version, so a beacon can never be
     *  rolled back onto an older implementation.
     *  @param version the published version to activate
     *  reverts if the version is not greater than the active version
     *  reverts if the version was never published
     *  only VERSION_MANAGER can call
     *  emits a `SuiteUpgraded` event
     */
    function upgrade(Version version) external;

    /**
     *  @dev convenience wrapper that publishes a new version and immediately activates it.
     *  Equivalent to `publish(version, impls)` followed by `upgrade(version)`.
     *  @param version the new version to publish
     *  @param impls the set of implementations corresponding to the new version
     *  reverts if the version is not greater than the active version
     *  reverts if the version was already published
     *  reverts if any implementation address is zero
     *  only VERSION_MANAGER can call
     *  emits `VersionPublished` and `SuiteUpgraded` events
     */
    function publishAndUpgrade(Version version, SuiteImplementations calldata impls) external;

    /**
     *  @dev returns the active version, i.e. the one every beacon currently points at.
     */
    function currentVersion() external view returns (Version);

    /**
     *  @dev returns the 4 beacon addresses driving every shared-mode suite.
     *  beacon addresses never change after construction.
     */
    function beacons() external view returns (SuiteBeacons memory);

    /**
     *  @dev returns the implementations the beacons currently point at.
     */
    function implementations() external view returns (SuiteImplementations memory);

    /**
     *  @dev returns the archived implementations for a given version.
     *  reverts if the version was never published.
     *  @param version the version to query
     */
    function implementationsFor(Version version) external view returns (SuiteImplementations memory);

}
