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

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { ITREXFactory } from "../factory/ITREXFactory.sol";
import { TrustedGatewayRegistry } from "../interop/TrustedGatewayRegistry.sol";
import { TREXImplementationAuthority } from "../proxy/beacon/TREXImplementationAuthority.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { RolesLib } from "./RolesLib.sol";

/// @title AccessManagerSetupLib
/// @notice Wires the platform contracts (factory, implementation authority, gateway registry, identity
///         factory) to the roles governance picks. Run once, by the platform deployment, never by a
///         contract. Suite roles are not here: a {TREXAccessManager} lays out its own suite when it is
///         initialized or when a suite is set up in it.
library AccessManagerSetupLib {

    uint64 internal constant ADMIN_ROLE = 0;
    uint64 internal constant PUBLIC_ROLE = RolesLib.PUBLIC_ROLE;

    /// @notice Maps the factory's two concerns to two roles governance picks. `suiteDeployerRole` deploys suites;
    ///         `factoryConfigRole` repoints the implementation authority, the identity factory and the gateway
    ///         registry, which every later suite is wired to. The ids are data, not constants: any role of
    ///         the manager works, a {RolesLib.PlatformRole}, a name through {RolesLib.platform(bytes32)} or
    ///         a raw id.
    /// @dev Refuses the three shapes that recreate the problem the split exists for: one role for both, so
    ///      every account allowed to deploy a token could reconfigure the factory for everyone; `ADMIN_ROLE`
    ///      as the suite deployer, so every deployer could remap the config selectors or grant itself the
    ///      config role; and the public role for either, so anyone could. `ADMIN_ROLE` as the config role is
    ///      fine, since admins can do everything anyway.
    /// @dev This is a check on the ids, not a separation guarantee: the role hierarchy the manager keeps
    ///      (`getRoleAdmin`) can later make the suite deployer role the admin of the config role, and
    ///      nothing here can prevent that.
    function setupTREXFactoryRoles(
        IAccessManager accessManager,
        address trexFactory,
        uint64 suiteDeployerRole,
        uint64 factoryConfigRole
    ) internal {
        require(suiteDeployerRole != factoryConfigRole, ErrorsLib.SuiteDeployerCannotConfigureFactory());
        require(suiteDeployerRole != ADMIN_ROLE, ErrorsLib.SuiteDeployerCannotConfigureFactory());
        _requireNotPublicRole(suiteDeployerRole);
        _requireNotPublicRole(factoryConfigRole);

        bytes4[] memory deployFunctions = new bytes4[](2);
        deployFunctions[0] = ITREXFactory.deployTREXSuite.selector;
        deployFunctions[1] = ITREXFactory.deployTREXSuiteIsolated.selector;
        accessManager.setTargetFunctionRole(trexFactory, deployFunctions, suiteDeployerRole);

        bytes4[] memory configFunctions = new bytes4[](3);
        configFunctions[0] = ITREXFactory.setImplementationAuthority.selector;
        configFunctions[1] = ITREXFactory.setIdFactory.selector;
        configFunctions[2] = ITREXFactory.setTrustedGatewayRegistry.selector;
        accessManager.setTargetFunctionRole(trexFactory, configFunctions, factoryConfigRole);
    }

    /// @notice Maps `setTrustedGateway` to `interopManagerRole`, the role governance picks for interop configuration.
    function setupTrustedGatewayRegistryRoles(
        IAccessManager accessManager,
        address trustedGatewayRegistry,
        uint64 interopManagerRole
    ) internal {
        _requireNotPublicRole(interopManagerRole);
        bytes4[] memory functions = new bytes4[](1);
        functions[0] = TrustedGatewayRegistry.setTrustedGateway.selector;
        accessManager.setTargetFunctionRole(trustedGatewayRegistry, functions, interopManagerRole);
    }

    /// @notice Wires the two prerequisites the {TREXFactory} auto-mint path needs, so a deployer does
    ///         not have to rediscover them. Without both, `deployTREXSuite` reverts with
    ///         `NotAuthorizedForIdentityType` whenever `TokenDetails.ONCHAINID` is left at zero.
    /// @dev Call order does not matter, but both must land before the first auto-mint deploy.
    ///      1. Register the `ASSET` type on the IdentityFactory, gated behind `assetDeployerRole` and with
    ///         self-deploy off: only a registered factory mints token OIDs, and a token must not be able
    ///         to sign one for itself.
    ///      2. Grant that role to the TREX factory.
    /// @dev `accessManager` MUST be the IdentityFactory's own authority, which is not necessarily the
    ///      suite AccessManager: `createIdentityFor` resolves the role against `authority()` on the
    ///      IdentityFactory. Granting the role on the wrong manager leaves the auto-mint path reverting.
    /// @dev The caller must be able to reach both calls: `setIdentityTypePolicy` is `restricted` on the
    ///      IdentityFactory, and `grantRole` requires the caller to be the role's admin.
    /// @dev The ASSET module bundle is ONCHAINID configuration, registered on the IdentityFactory
    ///      via `setIdentityTypeModules` as part of its own deployment. An identity minted for a
    ///      type without modules cannot initialize, so that registration must also land before the
    ///      first auto-mint deploy.
    /// @param accessManager The IdentityFactory's authority, where the role is resolved
    /// @param identityFactory The ONCHAINID IdentityFactory that mints token OIDs
    /// @param trexFactory The TREX factory that calls `createIdentityFor` on the auto-mint path
    /// @param assetDeployerRole The role governance picks for minting ASSET identities; meant for the
    ///        factory contract, not for people, since any holder can bind an ASSET identity to any address
    function setupIdentityFactoryPolicy(
        IAccessManager accessManager,
        IIdentityFactory identityFactory,
        address trexFactory,
        uint64 assetDeployerRole
    ) internal {
        _requireNotPublicRole(assetDeployerRole);
        // ASSET is single-binding: a token OID binds to exactly one token and cannot be re-linked.
        identityFactory.setIdentityTypePolicy(IdentityTypes.ASSET, assetDeployerRole, false, true);
        accessManager.grantRole(assetDeployerRole, trexFactory, 0);
    }

    /// @notice Maps `publish`, `upgrade` and `publishAndUpgrade` to `versionManagerRole`, the role governance picks
    ///         for publishing suite versions.
    function setupTREXImplementationAuthorityRoles(
        IAccessManager accessManager,
        address trexImplementationAuthority,
        uint64 versionManagerRole
    ) internal {
        _requireNotPublicRole(versionManagerRole);
        bytes4[] memory functions = new bytes4[](3);
        functions[0] = TREXImplementationAuthority.publish.selector;
        functions[1] = TREXImplementationAuthority.upgrade.selector;
        functions[2] = TREXImplementationAuthority.publishAndUpgrade.selector;
        accessManager.setTargetFunctionRole(trexImplementationAuthority, functions, versionManagerRole);
    }

    /// @dev Every platform function configures something all suites depend on; none may be open to anyone.
    function _requireNotPublicRole(uint64 role) private pure {
        require(role != PUBLIC_ROLE, ErrorsLib.PlatformRoleCannotBePublic());
    }

}
