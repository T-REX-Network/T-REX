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

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { Version } from "../../libraries/VersionLib.sol";
import { AccessManagedOwnable } from "../../utils/AccessManagedOwnable.sol";
import { ITREXImplementationAuthority } from "./ITREXImplementationAuthority.sol";

contract TREXImplementationAuthority is ITREXImplementationAuthority, AccessManagedOwnable {

    /// @dev addresses of the 4 beacons. set once in the constructor, never modified.
    address private immutable _TOKEN_BEACON;
    address private immutable _TREX_REGISTRY_BEACON;
    address private immutable _IRS_BEACON;
    address private immutable _MC_BEACON;

    /// @dev implementations per published version.
    mapping(Version version => SuiteImplementations implementations) private _implementations;

    /// @dev active version
    Version private _currentVersion;

    constructor(address accessManager, Version v0, SuiteImplementations memory impls)
        AccessManagedOwnable(accessManager)
    {
        require(accessManager != address(0), ErrorsLib.ZeroAddress());
        require(
            impls.tokenImplementation != address(0) && impls.trexRegistryImplementation != address(0)
                && impls.irsImplementation != address(0) && impls.mcImplementation != address(0),
            ErrorsLib.EmptyImplementations()
        );

        _TOKEN_BEACON = address(new UpgradeableBeacon(impls.tokenImplementation, address(this)));
        _TREX_REGISTRY_BEACON = address(new UpgradeableBeacon(impls.trexRegistryImplementation, address(this)));
        _IRS_BEACON = address(new UpgradeableBeacon(impls.irsImplementation, address(this)));
        _MC_BEACON = address(new UpgradeableBeacon(impls.mcImplementation, address(this)));

        _implementations[v0] = impls;
        _currentVersion = v0;

        emit EventsLib.BeaconsDeployed(_assembleBeacons());
        emit EventsLib.VersionPublished(v0, impls);
        emit EventsLib.SuiteUpgraded(v0, impls);
    }

    /// @inheritdoc ITREXImplementationAuthority
    function publish(Version version, SuiteImplementations calldata impls) external restricted {
        _publish(version, impls);
    }

    /// @inheritdoc ITREXImplementationAuthority
    function upgrade(Version version) external restricted {
        _upgrade(version);
    }

    /// @inheritdoc ITREXImplementationAuthority
    function publishAndUpgrade(Version version, SuiteImplementations calldata impls) external restricted {
        _publish(version, impls);
        _upgrade(version);
    }

    /// @inheritdoc ITREXImplementationAuthority
    function currentVersion() external view returns (Version) {
        return _currentVersion;
    }

    /// @inheritdoc ITREXImplementationAuthority
    function beacons() external view returns (SuiteBeacons memory) {
        return _assembleBeacons();
    }

    /// @inheritdoc ITREXImplementationAuthority
    function implementations() external view returns (SuiteImplementations memory) {
        return _implementations[_currentVersion];
    }

    /// @inheritdoc ITREXImplementationAuthority
    function implementationsFor(Version version) external view returns (SuiteImplementations memory) {
        SuiteImplementations memory impls = _implementations[version];
        require(impls.tokenImplementation != address(0), ErrorsLib.UnknownVersion());
        return impls;
    }

    /// @dev archives `impls` under `version` without touching a beacon.
    ///  reverts if the version was already published or if any implementation address is zero.
    function _publish(Version version, SuiteImplementations calldata impls) private {
        require(_implementations[version].tokenImplementation == address(0), ErrorsLib.VersionAlreadyPublished());
        require(
            impls.tokenImplementation != address(0) && impls.trexRegistryImplementation != address(0)
                && impls.irsImplementation != address(0) && impls.mcImplementation != address(0),
            ErrorsLib.EmptyImplementations()
        );

        _implementations[version] = impls;

        emit EventsLib.VersionPublished(version, impls);
    }

    /// @dev rotates the 4 beacons to the implementations archived for `version` and marks it active.
    ///  reverts if the version does not move forward or was never published.
    function _upgrade(Version version) private {
        require(version > _currentVersion, ErrorsLib.VersionNotNewer());

        SuiteImplementations memory impls = _implementations[version];
        require(impls.tokenImplementation != address(0), ErrorsLib.UnknownVersion());

        UpgradeableBeacon(_TOKEN_BEACON).upgradeTo(impls.tokenImplementation);
        UpgradeableBeacon(_TREX_REGISTRY_BEACON).upgradeTo(impls.trexRegistryImplementation);
        UpgradeableBeacon(_IRS_BEACON).upgradeTo(impls.irsImplementation);
        UpgradeableBeacon(_MC_BEACON).upgradeTo(impls.mcImplementation);

        _currentVersion = version;

        emit EventsLib.SuiteUpgraded(version, impls);
    }

    /// @dev assembles the 4 immutable beacon addresses into a `SuiteBeacons` struct.
    function _assembleBeacons() private view returns (SuiteBeacons memory) {
        return SuiteBeacons({
            tokenBeacon: _TOKEN_BEACON,
            trexRegistryBeacon: _TREX_REGISTRY_BEACON,
            irsBeacon: _IRS_BEACON,
            mcBeacon: _MC_BEACON
        });
    }

}
