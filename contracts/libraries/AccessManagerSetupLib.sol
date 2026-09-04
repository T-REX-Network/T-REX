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

import { ModularCompliance } from "../compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "../factory/TREXFactory.sol";
import { TrustedGatewayRegistry } from "../interop/TrustedGatewayRegistry.sol";
import { TREXImplementationAuthority } from "../proxy/beacon/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "../registry/implementation/TREXRegistry.sol";
import { Token } from "../token/Token.sol";
import { RolesLib } from "./RolesLib.sol";

/// @title AccessManagerSetupLib
/// @notice Library for setting up roles and functions in AccessManager for the TREX suite contracts
library AccessManagerSetupLib {

    function setupTokenRoles(IAccessManager accessManager, address token) internal {
        // ------ TOKEN_MANAGER role ------
        bytes4[] memory functions = new bytes4[](2);
        functions[0] = Token.setName.selector;
        functions[1] = Token.setSymbol.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.TOKEN_MANAGER);

        // ------ IDENTITY_MANAGER role ------
        // Also owns the interop wiring: which registry the token resolves gateway trust against, and
        // which gateway and peer each chain uses. Same concern as the registry and compliance it points at.
        functions = new bytes4[](6);
        functions[0] = Token.setOnchainID.selector;
        functions[1] = Token.setIdentityRegistry.selector;
        functions[2] = Token.setCompliance.selector;
        functions[3] = Token.setTrustedGatewayRegistry.selector;
        functions[4] = Token.setRoute.selector;
        functions[5] = Token.setPeer.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.IDENTITY_MANAGER);

        // ------ AGENT role ------
        // Outbound interop dispatch is an operation, not configuration: it sends, it does not rewire.
        // The bound compliance reaches dispatchComplianceValidation without a role; this is the human path.
        functions = new bytes4[](2);
        functions[0] = Token.dispatchComplianceValidation.selector;
        functions[1] = Token.dispatchMintInstruction.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT);

        // ------ AGENT_MINTER role ------
        functions = new bytes4[](1);
        functions[0] = Token.mint.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_MINTER);

        // ------ AGENT_BURNER role ------
        functions[0] = Token.burn.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_BURNER);

        // ------ AGENT_PARTIAL_FREEZER role ------
        functions = new bytes4[](2);
        functions[0] = Token.freezePartialTokens.selector;
        functions[1] = Token.unfreezePartialTokens.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_PARTIAL_FREEZER);

        // ------ AGENT_ADDRESS_FREEZER role ------
        functions = new bytes4[](1);
        functions[0] = Token.setAddressFrozen.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_ADDRESS_FREEZER);

        // ------ AGENT_RECOVERY_ADDRESS role ------
        functions[0] = Token.recoveryAddress.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_RECOVERY_ADDRESS);

        // ------ AGENT_FORCED_TRANSFER role ------
        functions[0] = Token.forcedTransfer.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_FORCED_TRANSFER);

        // ------ AGENT_PAUSER role ------
        functions = new bytes4[](2);
        functions[0] = Token.pause.selector;
        functions[1] = Token.unpause.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_PAUSER);
    }

    function setupIdentityRegistryStorageRoles(IAccessManager accessManager, address identityRegistryStorage) internal {
        // ------ IRS_BINDER role ------
        bytes4[] memory functions = new bytes4[](1);
        functions[0] = IdentityRegistryStorage.bindIdentityRegistry.selector;
        accessManager.setTargetFunctionRole(identityRegistryStorage, functions, RolesLib.IRS_BINDER);

        // ------ OWNER role ------
        functions[0] = IdentityRegistryStorage.unbindIdentityRegistry.selector;
        accessManager.setTargetFunctionRole(identityRegistryStorage, functions, RolesLib.OWNER);

        // ------ AGENT role ------
        functions = new bytes4[](4);
        functions[0] = IdentityRegistryStorage.addIdentityToStorage.selector;
        functions[1] = IdentityRegistryStorage.modifyStoredIdentity.selector;
        functions[2] = IdentityRegistryStorage.modifyStoredInvestorCountry.selector;
        functions[3] = IdentityRegistryStorage.removeIdentityFromStorage.selector;
        accessManager.setTargetFunctionRole(identityRegistryStorage, functions, RolesLib.AGENT);
    }

    /// @notice Role wiring for the `TREXRegistry` contract.
    function setupTREXRegistryRoles(IAccessManager accessManager, address registry) internal {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](8);
        functions[0] = TREXRegistry.setIdentityRegistryStorage.selector;
        functions[1] = TREXRegistry.disableEligibilityChecks.selector;
        functions[2] = TREXRegistry.enableEligibilityChecks.selector;
        functions[3] = TREXRegistry.addTrustedIssuer.selector;
        functions[4] = TREXRegistry.removeTrustedIssuer.selector;
        functions[5] = TREXRegistry.updateIssuerClaimTopics.selector;
        functions[6] = TREXRegistry.addClaimTopic.selector;
        functions[7] = TREXRegistry.removeClaimTopic.selector;
        accessManager.setTargetFunctionRole(registry, functions, RolesLib.OWNER);

        // ------ AGENT role ------
        functions = new bytes4[](5);
        functions[0] = TREXRegistry.registerIdentity.selector;
        functions[1] = TREXRegistry.batchRegisterIdentity.selector;
        functions[2] = TREXRegistry.updateIdentity.selector;
        functions[3] = TREXRegistry.updateCountry.selector;
        functions[4] = TREXRegistry.deleteIdentity.selector;
        accessManager.setTargetFunctionRole(registry, functions, RolesLib.AGENT);
    }

    function setupModularComplianceRoles(IAccessManager accessManager, address modularCompliance) internal {
        // ------ OWNER role ------
        // bindToken/unbindToken are not `restricted`; they self-check via the shared BIND_UNBIND_TOKEN
        // capability, so that single selector is registered here rather than each real selector separately.
        bytes4[] memory functions = new bytes4[](6);
        functions[0] = ModularCompliance.removeModule.selector;
        functions[1] = ModularCompliance.addAndSetModule.selector;
        functions[2] = ModularCompliance.addModule.selector;
        functions[3] = ModularCompliance.callModuleFunction.selector;
        functions[4] = RolesLib.BIND_UNBIND_TOKEN;
        functions[5] = ModularCompliance.refreshModuleCapabilities.selector;
        accessManager.setTargetFunctionRole(modularCompliance, functions, RolesLib.OWNER);
    }

    function setupTREXFactoryRoles(IAccessManager accessManager, address trexFactory) internal {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](5);
        functions[0] = TREXFactory.setImplementationAuthority.selector;
        functions[1] = TREXFactory.setIdFactory.selector;
        functions[2] = TREXFactory.setIdentityModules.selector;
        functions[3] = TREXFactory.deployTREXSuite.selector;
        functions[4] = TREXFactory.deployTREXSuiteIsolated.selector;
        accessManager.setTargetFunctionRole(trexFactory, functions, RolesLib.OWNER);
    }

    /// @notice Wires the two prerequisites the {TREXFactory} auto-mint path needs, so a deployer does
    ///         not have to rediscover them. Without both, `deployTREXSuite` reverts with
    ///         `NotAuthorizedForIdentityType` whenever `TokenDetails.ONCHAINID` is left at zero.
    /// @dev Call order does not matter, but both must land before the first auto-mint deploy.
    ///      1. Register the `ASSET` type on the IdentityFactory, gated behind ASSET_DEPLOYER and
    ///         with self-deploy off: only a registered factory mints token OIDs, and a token must not
    ///         be able to sign one for itself.
    ///      2. Grant ASSET_DEPLOYER to the TREX factory.
    /// @dev `accessManager` MUST be the IdentityFactory's own authority, which is not necessarily the
    ///      suite AccessManager: `createIdentityFor` resolves the role against `authority()` on the
    ///      IdentityFactory. Granting the role on the wrong manager leaves the auto-mint path reverting.
    /// @dev The caller must be able to reach both calls: `setIdentityTypePolicy` is `restricted` on the
    ///      IdentityFactory, and `grantRole` requires the caller to be ASSET_DEPLOYER's role admin.
    /// @param accessManager The IdentityFactory's authority, where ASSET_DEPLOYER is resolved
    /// @param identityFactory The ONCHAINID IdentityFactory that mints token OIDs
    /// @param trexFactory The TREX factory that calls `createIdentityFor` on the auto-mint path
    function setupIdentityFactoryPolicy(
        IAccessManager accessManager,
        IIdentityFactory identityFactory,
        address trexFactory
    ) internal {
        identityFactory.setIdentityTypePolicy(IdentityTypes.ASSET, RolesLib.ASSET_DEPLOYER, false);
        accessManager.grantRole(RolesLib.ASSET_DEPLOYER, trexFactory, 0);
    }

    function setupTrustedGatewayRegistryRoles(IAccessManager accessManager, address trustedGatewayRegistry) internal {
        // ------ INTEROP_MANAGER role ------
        bytes4[] memory functions = new bytes4[](1);
        functions[0] = TrustedGatewayRegistry.setTrustedGateway.selector;
        accessManager.setTargetFunctionRole(trustedGatewayRegistry, functions, RolesLib.INTEROP_MANAGER);
    }

    function setupTREXImplementationAuthorityRoles(IAccessManager accessManager, address trexImplementationAuthority)
        internal
    {
        // ------ VERSION_MANAGER role ------
        bytes4[] memory functions = new bytes4[](3);
        functions[0] = TREXImplementationAuthority.publish.selector;
        functions[1] = TREXImplementationAuthority.upgrade.selector;
        functions[2] = TREXImplementationAuthority.publishAndUpgrade.selector;
        accessManager.setTargetFunctionRole(trexImplementationAuthority, functions, RolesLib.VERSION_MANAGER);
    }

    /// @notice Wires the role-giver hierarchy. Call once, before any operational grant.
    ///         AGENT_ADMIN administers AGENT and every granular AGENT_* role; SUITE_ADMIN
    ///         administers TOKEN_MANAGER and IDENTITY_MANAGER. OWNER is intentionally left
    ///         under ADMIN_ROLE (0) so only the governance multisig can grant it.
    function setupRoleAdmins(IAccessManager accessManager) internal {
        // ------ AGENT_ADMIN administers the AGENT family ------
        accessManager.setRoleAdmin(RolesLib.AGENT, RolesLib.AGENT_ADMIN);
        accessManager.setRoleAdmin(RolesLib.AGENT_MINTER, RolesLib.AGENT_ADMIN);
        accessManager.setRoleAdmin(RolesLib.AGENT_BURNER, RolesLib.AGENT_ADMIN);
        accessManager.setRoleAdmin(RolesLib.AGENT_PARTIAL_FREEZER, RolesLib.AGENT_ADMIN);
        accessManager.setRoleAdmin(RolesLib.AGENT_ADDRESS_FREEZER, RolesLib.AGENT_ADMIN);
        accessManager.setRoleAdmin(RolesLib.AGENT_RECOVERY_ADDRESS, RolesLib.AGENT_ADMIN);
        accessManager.setRoleAdmin(RolesLib.AGENT_FORCED_TRANSFER, RolesLib.AGENT_ADMIN);
        accessManager.setRoleAdmin(RolesLib.AGENT_PAUSER, RolesLib.AGENT_ADMIN);

        // ------ SUITE_ADMIN administers the token-config roles ------
        accessManager.setRoleAdmin(RolesLib.TOKEN_MANAGER, RolesLib.SUITE_ADMIN);
        accessManager.setRoleAdmin(RolesLib.IDENTITY_MANAGER, RolesLib.SUITE_ADMIN);

        // ------ AGENT_ADMIN administers the transient IRS_BINDER role ------
        accessManager.setRoleAdmin(RolesLib.IRS_BINDER, RolesLib.AGENT_ADMIN);
    }

    function setupLabels(IAccessManager accessManager) internal {
        accessManager.labelRole(RolesLib.OWNER, "TREX-Suite Owner");

        accessManager.labelRole(RolesLib.AGENT, "TREX-Suite Agent");
        accessManager.labelRole(RolesLib.AGENT_MINTER, "TREX-Suite Agent: Minter");
        accessManager.labelRole(RolesLib.AGENT_BURNER, "TREX-Suite Agent: Burner");
        accessManager.labelRole(RolesLib.AGENT_PARTIAL_FREEZER, "TREX-Suite Agent: Partial Freezer");
        accessManager.labelRole(RolesLib.AGENT_ADDRESS_FREEZER, "TREX-Suite Agent: Address Freezer");
        accessManager.labelRole(RolesLib.AGENT_RECOVERY_ADDRESS, "TREX-Suite Agent: Recovery Address");
        accessManager.labelRole(RolesLib.AGENT_FORCED_TRANSFER, "TREX-Suite Agent: Forced Transfer");
        accessManager.labelRole(RolesLib.AGENT_PAUSER, "TREX-Suite Agent: Pauser");

        accessManager.labelRole(RolesLib.TOKEN_MANAGER, "TREX-Suite Manager: Token");
        accessManager.labelRole(RolesLib.IDENTITY_MANAGER, "TREX-Suite Manager: Identity");
        accessManager.labelRole(RolesLib.VERSION_MANAGER, "TREX-Suite Manager: Version");

        // Role-givers
        accessManager.labelRole(RolesLib.AGENT_ADMIN, "TREX-Suite Admin: Agent");
        accessManager.labelRole(RolesLib.SUITE_ADMIN, "TREX-Suite Admin: Suite");

        // Transient deploy-time role
        accessManager.labelRole(RolesLib.IRS_BINDER, "TREX-Suite IRS Binder (transient)");

        // Resolved by the ONCHAINID IdentityFactory, not by any TREX selector mapping
        accessManager.labelRole(RolesLib.ASSET_DEPLOYER, "TREX-Suite Asset Deployer");
    }

}
