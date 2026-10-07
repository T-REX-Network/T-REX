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

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643ClaimTopicsRegistry } from "../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ITransferValidation } from "../compliance/modular/ITransferValidation.sol";
import { ModularCompliance } from "../compliance/modular/ModularCompliance.sol";
import { ITREXFactory } from "../factory/ITREXFactory.sol";
import { ITREXMessaging } from "../interop/ITREXMessaging.sol";
import { TrustedGatewayRegistry } from "../interop/TrustedGatewayRegistry.sol";
import { TREXImplementationAuthority } from "../proxy/beacon/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "../registry/implementation/TREXRegistry.sol";
import { IIdentityRegistryStorage } from "../registry/interface/IIdentityRegistryStorage.sol";
import { IToken } from "../token/IToken.sol";
import { TREXAccessManager } from "../utils/TREXAccessManager.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { RolesLib } from "./RolesLib.sol";

/// @title AccessManagerSetupLib
/// @notice Library for setting up roles and functions in AccessManager for the TREX suite contracts
library AccessManagerSetupLib {

    struct SelectorRole {
        bytes4 selector;
        RolesLib.Role role;
    }

    struct RoleAdmin {
        RolesLib.Role role;
        RolesLib.Role admin;
    }

    struct RoleAssignment {
        address account;
        RolesLib.Role role;
        uint32 domainId;
    }

    struct RoleRevocation {
        address account;
        RolesLib.Role role;
    }

    uint64 internal constant ADMIN_ROLE = 0;
    uint64 internal constant PUBLIC_ROLE = RolesLib.PUBLIC_ROLE;

    function setupTokenRoles(IAccessManager accessManager, address token, uint32 domainId) internal {
        _apply(accessManager, token, tokenTable(), domainId);
    }

    function setupIdentityRegistryStorageRoles(
        IAccessManager accessManager,
        address identityRegistryStorage,
        uint32 domainId
    ) internal {
        _apply(accessManager, identityRegistryStorage, storageTable(), domainId);
    }

    function setupTREXRegistryRoles(IAccessManager accessManager, address registry, uint32 domainId) internal {
        _apply(accessManager, registry, registryTable(), domainId);
    }

    function setupModularComplianceRoles(IAccessManager accessManager, address modularCompliance, uint32 domainId)
        internal
    {
        _apply(accessManager, modularCompliance, complianceTable(), domainId);
    }

    function tokenTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](18);
        table[0] = SelectorRole(IERC3643.setName.selector, RolesLib.Role.TOKEN_MANAGER);
        table[1] = SelectorRole(IERC3643.setSymbol.selector, RolesLib.Role.TOKEN_MANAGER);
        table[2] = SelectorRole(IERC3643.setOnchainID.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[3] = SelectorRole(IERC3643.setIdentityRegistry.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[4] = SelectorRole(IERC3643.setCompliance.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[5] = SelectorRole(ITREXMessaging.setRoute.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[6] = SelectorRole(ITREXMessaging.setPeer.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[7] = SelectorRole(IToken.dispatchMintInstruction.selector, RolesLib.Role.AGENT);
        table[8] = SelectorRole(IToken.dispatchRecallInstruction.selector, RolesLib.Role.AGENT);
        table[9] = SelectorRole(IERC3643.mint.selector, RolesLib.Role.AGENT_MINTER);
        table[10] = SelectorRole(IERC3643.burn.selector, RolesLib.Role.AGENT_BURNER);
        table[11] = SelectorRole(IERC3643.freezePartialTokens.selector, RolesLib.Role.AGENT_PARTIAL_FREEZER);
        table[12] = SelectorRole(IERC3643.unfreezePartialTokens.selector, RolesLib.Role.AGENT_PARTIAL_FREEZER);
        table[13] = SelectorRole(IERC3643.setAddressFrozen.selector, RolesLib.Role.AGENT_ADDRESS_FREEZER);
        table[14] = SelectorRole(IERC3643.recoveryAddress.selector, RolesLib.Role.AGENT_RECOVERY_ADDRESS);
        table[15] = SelectorRole(IERC3643.forcedTransfer.selector, RolesLib.Role.AGENT_FORCED_TRANSFER);
        table[16] = SelectorRole(IERC3643.pause.selector, RolesLib.Role.AGENT_PAUSER);
        table[17] = SelectorRole(IERC3643.unpause.selector, RolesLib.Role.AGENT_PAUSER);
    }

    function registryTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](14);
        table[0] = SelectorRole(IERC3643IdentityRegistry.setIdentityRegistryStorage.selector, RolesLib.Role.OWNER);
        table[1] = SelectorRole(TREXRegistry.disableEligibilityChecks.selector, RolesLib.Role.OWNER);
        table[2] = SelectorRole(TREXRegistry.enableEligibilityChecks.selector, RolesLib.Role.OWNER);
        table[3] = SelectorRole(IERC3643TrustedIssuersRegistry.addTrustedIssuer.selector, RolesLib.Role.OWNER);
        table[4] = SelectorRole(IERC3643TrustedIssuersRegistry.removeTrustedIssuer.selector, RolesLib.Role.OWNER);
        table[5] = SelectorRole(IERC3643TrustedIssuersRegistry.updateIssuerClaimTopics.selector, RolesLib.Role.OWNER);
        table[6] = SelectorRole(IERC3643ClaimTopicsRegistry.addClaimTopic.selector, RolesLib.Role.OWNER);
        table[7] = SelectorRole(IERC3643ClaimTopicsRegistry.removeClaimTopic.selector, RolesLib.Role.OWNER);
        table[8] = SelectorRole(TREXRegistry.addClaimTopicForIdentityType.selector, RolesLib.Role.OWNER);
        table[9] = SelectorRole(TREXRegistry.removeClaimTopicForIdentityType.selector, RolesLib.Role.OWNER);
        table[10] = SelectorRole(IERC3643IdentityRegistry.registerIdentity.selector, RolesLib.Role.AGENT);
        table[11] = SelectorRole(IERC3643IdentityRegistry.batchRegisterIdentity.selector, RolesLib.Role.AGENT);
        table[12] = SelectorRole(IERC3643IdentityRegistry.updateIdentity.selector, RolesLib.Role.AGENT);
        table[13] = SelectorRole(IERC3643IdentityRegistry.deleteIdentity.selector, RolesLib.Role.AGENT);
    }

    function storageTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](5);
        table[0] = SelectorRole(IdentityRegistryStorage.bindIdentityRegistry.selector, RolesLib.Role.IRS_BINDER);
        table[1] = SelectorRole(IdentityRegistryStorage.unbindIdentityRegistry.selector, RolesLib.Role.OWNER);
        table[2] = SelectorRole(IERC3643IdentityRegistryStorage.addIdentityToStorage.selector, RolesLib.Role.IRS_WRITER);
        table[3] = SelectorRole(IdentityRegistryStorage.modifyStoredIdentity.selector, RolesLib.Role.IRS_WRITER);
        table[4] =
            SelectorRole(IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector, RolesLib.Role.IRS_WRITER);
    }

    function complianceTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](14);
        table[0] = SelectorRole(ModularCompliance.removeModule.selector, RolesLib.Role.OWNER);
        table[1] = SelectorRole(ModularCompliance.forceRemoveModule.selector, RolesLib.Role.OWNER);
        table[2] = SelectorRole(ModularCompliance.addAndSetModule.selector, RolesLib.Role.OWNER);
        table[3] = SelectorRole(ModularCompliance.addModule.selector, RolesLib.Role.OWNER);
        table[4] = SelectorRole(ModularCompliance.callModuleFunction.selector, RolesLib.Role.OWNER);
        table[5] = SelectorRole(RolesLib.BIND_UNBIND_TOKEN, RolesLib.Role.OWNER);
        table[6] = SelectorRole(ModularCompliance.resyncModuleTypes.selector, RolesLib.Role.OWNER);
        table[7] = SelectorRole(ModularCompliance.setDefaultValidityWindow.selector, RolesLib.Role.COMPLIANCE_MANAGER);
        table[8] = SelectorRole(ModularCompliance.setReconciliationWindow.selector, RolesLib.Role.COMPLIANCE_MANAGER);
        table[9] = SelectorRole(ModularCompliance.setIssuancePaused.selector, RolesLib.Role.COMPLIANCE_MANAGER);
        table[10] = SelectorRole(ITransferValidation.requestTransferValidation.selector, RolesLib.Role.AGENT);
        table[11] = SelectorRole(ModularCompliance.discardExpiredValidations.selector, RolesLib.Role.VALIDATION_KEEPER);
        table[12] = SelectorRole(ModularCompliance.resolveStuckValidation.selector, RolesLib.Role.VALIDATION_KEEPER);
        table[13] = SelectorRole(ModularCompliance.fixPosition.selector, RolesLib.Role.OWNER);
    }

    function roleAdminTable() internal pure returns (RoleAdmin[] memory table) {
        table = new RoleAdmin[](13);
        table[0] = RoleAdmin(RolesLib.Role.AGENT, RolesLib.Role.AGENT_ADMIN);
        table[1] = RoleAdmin(RolesLib.Role.AGENT_MINTER, RolesLib.Role.AGENT_ADMIN);
        table[2] = RoleAdmin(RolesLib.Role.AGENT_BURNER, RolesLib.Role.AGENT_ADMIN);
        table[3] = RoleAdmin(RolesLib.Role.AGENT_PARTIAL_FREEZER, RolesLib.Role.AGENT_ADMIN);
        table[4] = RoleAdmin(RolesLib.Role.AGENT_ADDRESS_FREEZER, RolesLib.Role.AGENT_ADMIN);
        table[5] = RoleAdmin(RolesLib.Role.AGENT_RECOVERY_ADDRESS, RolesLib.Role.AGENT_ADMIN);
        table[6] = RoleAdmin(RolesLib.Role.AGENT_FORCED_TRANSFER, RolesLib.Role.AGENT_ADMIN);
        table[7] = RoleAdmin(RolesLib.Role.AGENT_PAUSER, RolesLib.Role.AGENT_ADMIN);
        table[8] = RoleAdmin(RolesLib.Role.IRS_BINDER, RolesLib.Role.AGENT_ADMIN);
        table[9] = RoleAdmin(RolesLib.Role.VALIDATION_KEEPER, RolesLib.Role.AGENT_ADMIN);
        table[10] = RoleAdmin(RolesLib.Role.TOKEN_MANAGER, RolesLib.Role.SUITE_ADMIN);
        table[11] = RoleAdmin(RolesLib.Role.IDENTITY_MANAGER, RolesLib.Role.SUITE_ADMIN);
        table[12] = RoleAdmin(RolesLib.Role.COMPLIANCE_MANAGER, RolesLib.Role.SUITE_ADMIN);
    }

    function setupSuite(TREXAccessManager accessManager, address token) internal {
        uint32 domainId = accessManager.domainOf(token);
        require(domainId != 0, ErrorsLib.NotAssigned(token));
        address registry = _registryOf(token);
        address identityRegistryStorage = _storageOf(registry);
        uint32 storageDomainId = accessManager.domainOf(identityRegistryStorage);
        if (storageDomainId == 0) {
            accessManager.assign(domainId, identityRegistryStorage);
            storageDomainId = domainId;
        }
        _setupSuite(accessManager, token, registry, identityRegistryStorage, domainId, storageDomainId);
    }

    function setupSuite(IAccessManager accessManager, address token, uint32 domainId, uint32 storageDomainId) internal {
        address registry = _registryOf(token);
        _setupSuite(accessManager, token, registry, _storageOf(registry), domainId, storageDomainId);
    }

    function moveSuitesToDomains(
        TREXAccessManager accessManager,
        address[] memory tokens,
        uint32 fromDomainId,
        uint32[] memory toDomainIds,
        RoleAssignment[] memory assignments,
        RoleRevocation[] memory revocations
    ) internal {
        require(tokens.length == toDomainIds.length, ErrorsLib.ArrayLengthMismatch());
        for (uint256 i = 0; i < tokens.length; i++) {
            accessManager.assign(toDomainIds[i], tokens[i]);
        }
        migrateSuitesToDomains(
            IAccessManager(accessManager), tokens, fromDomainId, toDomainIds, assignments, revocations
        );
    }

    function migrateSuitesToDomains(
        IAccessManager accessManager,
        address[] memory tokens,
        uint32 fromDomainId,
        uint32[] memory toDomainIds,
        RoleAssignment[] memory assignments,
        RoleRevocation[] memory revocations
    ) internal {
        require(tokens.length == toDomainIds.length, ErrorsLib.ArrayLengthMismatch());
        for (uint256 i = 0; i < assignments.length; i++) {
            _grantFrom(
                accessManager, fromDomainId, assignments[i].role, assignments[i].domainId, assignments[i].account
            );
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            _grantFrom(accessManager, fromDomainId, RolesLib.Role.AGENT, toDomainIds[i], tokens[i]);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            setupTokenRoles(accessManager, tokens[i], toDomainIds[i]);
            setupTREXRegistryRoles(accessManager, _registryOf(tokens[i]), toDomainIds[i]);
            setupModularComplianceRoles(accessManager, _complianceOf(tokens[i]), toDomainIds[i]);
            setupRoleAdmins(accessManager, toDomainIds[i]);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            accessManager.revokeRole(RolesLib.forDomain(fromDomainId, RolesLib.Role.AGENT), tokens[i]);
        }
        for (uint256 i = 0; i < revocations.length; i++) {
            if (!_isAdministrative(revocations[i].role)) {
                accessManager.revokeRole(RolesLib.forDomain(fromDomainId, revocations[i].role), revocations[i].account);
            }
        }
        for (uint256 i = 0; i < revocations.length; i++) {
            if (_isAdministrative(revocations[i].role)) {
                accessManager.revokeRole(RolesLib.forDomain(fromDomainId, revocations[i].role), revocations[i].account);
            }
        }
    }

    /// @notice Maps the factory's two concerns to two roles governance picks. `suiteDeployerRole` uses the
    ///         factory: it deploys suites. `factoryConfigRole` configures it: it repoints the implementation
    ///         authority, the identity factory, the gateway registry and the suite profile, the four settings
    ///         every later suite is wired to or shaped by. The ids are data, not constants: any role of the
    ///         manager works, a {RolesLib.PlatformRole}, a name through {RolesLib.platform(bytes32)} or a raw id.
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

        bytes4[] memory configFunctions = new bytes4[](4);
        configFunctions[0] = ITREXFactory.setImplementationAuthority.selector;
        configFunctions[1] = ITREXFactory.setIdFactory.selector;
        configFunctions[2] = ITREXFactory.setTrustedGatewayRegistry.selector;
        configFunctions[3] = ITREXFactory.setSuiteProfile.selector;
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

    function setupRoleAdmins(IAccessManager accessManager, uint32 domainId) internal {
        RoleAdmin[] memory table = roleAdminTable();
        for (uint256 i = 0; i < table.length; i++) {
            accessManager.setRoleAdmin(
                RolesLib.forDomain(domainId, table[i].role), RolesLib.forDomain(domainId, table[i].admin)
            );
        }
    }

    function _setupSuite(
        IAccessManager accessManager,
        address token,
        address registry,
        address identityRegistryStorage,
        uint32 domainId,
        uint32 storageDomainId
    ) private {
        accessManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT), token, 0);
        accessManager.grantRole(RolesLib.forDomain(storageDomainId, RolesLib.Role.IRS_WRITER), registry, 0);

        setupTokenRoles(accessManager, token, domainId);
        setupTREXRegistryRoles(accessManager, registry, domainId);
        setupModularComplianceRoles(accessManager, _complianceOf(token), domainId);
        setupRoleAdmins(accessManager, domainId);
        if (!IIdentityRegistryStorage(identityRegistryStorage).isIdentityRegistryBound(registry)) {
            IERC3643IdentityRegistryStorage(identityRegistryStorage).bindIdentityRegistry(registry);
        }
        setupIdentityRegistryStorageRoles(accessManager, identityRegistryStorage, storageDomainId);
        if (storageDomainId != domainId) {
            setupRoleAdmins(accessManager, storageDomainId);
        }
    }

    function _grantFrom(
        IAccessManager accessManager,
        uint32 fromDomainId,
        RolesLib.Role role,
        uint32 toDomainId,
        address account
    ) private {
        uint64 sourceRole = RolesLib.forDomain(fromDomainId, role);
        (uint48 since, uint32 executionDelay,, uint48 effect) = accessManager.getAccess(sourceRole, account);
        require(since != 0, ErrorsLib.RoleNotHeld(account, sourceRole));
        require(since <= block.timestamp, ErrorsLib.PendingRoleGrant(account, sourceRole));
        require(effect <= block.timestamp, ErrorsLib.PendingDelayChange(account, sourceRole));
        accessManager.grantRole(RolesLib.forDomain(toDomainId, role), account, executionDelay);
    }

    function _isAdministrative(RolesLib.Role role) private pure returns (bool) {
        RoleAdmin[] memory table = roleAdminTable();
        for (uint256 i = 0; i < table.length; i++) {
            if (table[i].admin == role) {
                return true;
            }
        }
        return false;
    }

    /// @dev Walks `table` as runs of consecutive same-role entries and maps each run with one
    ///  `setTargetFunctionRole`. The tables above keep every role's selectors consecutive; a table that
    ///  interleaves roles still maps every selector correctly, since the manager writes per selector, it
    ///  only spends one extra call per extra run.
    function _apply(IAccessManager accessManager, address target, SelectorRole[] memory table, uint32 domainId)
        private
    {
        uint256 start;
        while (start < table.length) {
            RolesLib.Role role = table[start].role;
            uint256 end = start;
            while (end < table.length && table[end].role == role) {
                end++;
            }
            bytes4[] memory selectors = new bytes4[](end - start);
            for (uint256 i = start; i < end; i++) {
                selectors[i - start] = table[i].selector;
            }
            accessManager.setTargetFunctionRole(target, selectors, RolesLib.forDomain(domainId, role));
            start = end;
        }
    }

    function _registryOf(address token) private view returns (address) {
        return address(IERC3643(token).identityRegistry());
    }

    function _storageOf(address registry) private view returns (address) {
        return address(IERC3643IdentityRegistry(registry).identityStorage());
    }

    function _complianceOf(address token) private view returns (address) {
        return address(IERC3643(token).compliance());
    }

}
