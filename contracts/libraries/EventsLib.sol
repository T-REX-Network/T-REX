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

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ITREXImplementationAuthority } from "../proxy/beacon/ITREXImplementationAuthority.sol";
import { MessageTypesLib } from "./MessageTypesLib.sol";
import { Version } from "./VersionLib.sol";

library EventsLib {

    // Common Events

    event ImplementationAuthoritySet(address implementationAuthority);

    // Token Events

    /// @notice Emitted on a delegation-out. Carries the full envelope so indexers need no reverse key table.
    event DelegatedOut(address indexed holder, bytes32 indexed toKey, bytes toWallet, uint256 amount);
    /// @notice Emitted on a recall from a satellite wallet onto a native wallet.
    event Recalled(bytes32 indexed fromKey, address indexed holder, bytes fromWallet, uint256 amount);
    /// @notice Emitted on a settled movement between two satellite wallets, under the validation it consumed.
    event BridgedTransfer(
        bytes32 indexed fromKey,
        bytes32 indexed toKey,
        uint256 indexed validationId,
        bytes from,
        bytes to,
        uint256 amount
    );

    // ModularCompliance Events

    event ModuleInteraction(address indexed target, bytes data);
    event ModuleAdded(address indexed module);
    event ModuleCapabilitiesRecorded(address indexed module, uint256 capabilities);
    event ModuleRemoved(address indexed module);

    // AbstractModule / AbstractModuleUpgradeable Events

    event ComplianceBound(address indexed compliance);
    event ComplianceUnbound(address indexed compliance);

    // IdentityRegistry / IdentityRegistryStorage Events
    // ClaimTopicsRegistry Events

    event ClaimTopicAddedForIdentityType(uint256 indexed identityType, uint256 indexed claimTopic);
    event ClaimTopicRemovedForIdentityType(uint256 indexed identityType, uint256 indexed claimTopic);

    // IdentityRegistry Events

    event EligibilityChecksDisabled();
    event EligibilityChecksEnabled();
    event InvestorIdentityChanged(address indexed investor);
    event IdentityOverridden(
        address indexed investor, IIdentity indexed globalIdentity, IIdentity indexed localIdentity
    );
    event IdentityOverrideReleased(
        address indexed investor, IIdentity indexed localIdentity, IIdentity indexed globalIdentity
    );

    // Token Events
    event ForcedTransfer(address indexed agent);
    event IdentityTransfer(address indexed identity, address indexed from, address indexed to, uint256 amount);

    // TREXFactory Events

    event Deployed(address indexed addr);
    event IdFactorySet(address idFactory);

    event TREXSuiteDeployed(address indexed token, address registry, address irs, address mc, string salt);
    event IsolatedSuiteDeployed(address indexed token, ITREXImplementationAuthority.SuiteBeacons beacons);

    // TrustedGatewayRegistry Events

    event TrustedGatewaySet(address indexed gateway, bool trusted);

    // TREXMessaging Events

    /// @notice Emitted by the factory when its registry pointer moves, and by a token once, at deployment.
    event TrustedGatewayRegistrySet(address trustedGatewayRegistry);
    /// @notice Emitted the first time a token learns the ERC-7930 prefix behind a `chainKey`.
    event ChainRegistered(bytes32 indexed chainKey, bytes2 chainType, bytes chainReference);
    event RouteSet(bytes32 indexed chainKey, address indexed gateway);
    event PeerSet(bytes32 indexed chainKey, bytes peer);
    /// @notice Emitted when a validation's leg toward `chainKey` is pinned to the gateway that carried it.
    event ValidationRoutePinned(uint256 indexed validationId, bytes32 indexed chainKey, address gateway);
    event ProtocolMessageSent(MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 sendId);
    event ProtocolMessageReceived(
        MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 receiveId
    );
    /// @notice Emitted by the token when an attributed burn proof reaches its recall path.
    event BurnProofReceived(
        bytes32 indexed originChainKey, bytes burnedWallet, address indexed nativeWallet, uint256 amount
    );

    // ModularCompliance Interop Events

    /// @notice Emitted by the compliance when the token hands it an attributed settlement notification.
    event SettlementNotified(
        bytes32 indexed originChainKey, uint256 indexed validationId, bytes from, bytes to, uint256 amount
    );

    // TREXImplementationAuthority Events

    event BeaconsDeployed(ITREXImplementationAuthority.SuiteBeacons beacons);
    event VersionPublished(Version version, ITREXImplementationAuthority.SuiteImplementations implementations);
    event SuiteUpgraded(Version version, ITREXImplementationAuthority.SuiteImplementations implementations);

}
