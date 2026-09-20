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
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643ClaimTopicsRegistry } from "../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ModularCompliance } from "../compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "../factory/TREXFactory.sol";
import { TREXImplementationAuthority } from "../proxy/beacon/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "../registry/implementation/TREXRegistry.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { RolesLib } from "./RolesLib.sol";

/// @title AccessManagerSetupLib
/// @notice Library for setting up roles and functions in AccessManager for the TREX suite contracts
library AccessManagerSetupLib {

    function setupTokenRoles(IAccessManager accessManager, address token, bytes32 namespace) internal {
        (bytes4[] memory selectors, uint64[] memory roles) = tokenTable();
        _apply(accessManager, token, selectors, roles, namespace);
        _mark(accessManager, token, namespace);
    }

    function setupIdentityRegistryStorageRoles(
        IAccessManager accessManager,
        address identityRegistryStorage,
        bytes32 namespace
    ) internal {
        (bytes4[] memory selectors, uint64[] memory roles) = storageTable();
        _apply(accessManager, identityRegistryStorage, selectors, roles, namespace);
        _mark(accessManager, identityRegistryStorage, namespace);
    }

    /// @notice Role wiring for the `TREXRegistry` contract.
    function setupTREXRegistryRoles(IAccessManager accessManager, address registry, bytes32 namespace) internal {
        (bytes4[] memory selectors, uint64[] memory roles) = registryTable();
        _apply(accessManager, registry, selectors, roles, namespace);
    }

    function setupModularComplianceRoles(IAccessManager accessManager, address modularCompliance, bytes32 namespace)
        internal
    {
        (bytes4[] memory selectors, uint64[] memory roles) = complianceTable();
        _apply(accessManager, modularCompliance, selectors, roles, namespace);
    }

    function tokenTable() internal pure returns (bytes4[] memory selectors, uint64[] memory roles) {
        selectors = new bytes4[](14);
        roles = new uint64[](14);
        selectors[0] = IERC3643.setName.selector;
        roles[0] = RolesLib.TOKEN_MANAGER;
        selectors[1] = IERC3643.setSymbol.selector;
        roles[1] = RolesLib.TOKEN_MANAGER;
        selectors[2] = IERC3643.setOnchainID.selector;
        roles[2] = RolesLib.IDENTITY_MANAGER;
        selectors[3] = IERC3643.setIdentityRegistry.selector;
        roles[3] = RolesLib.IDENTITY_MANAGER;
        selectors[4] = IERC3643.setCompliance.selector;
        roles[4] = RolesLib.IDENTITY_MANAGER;
        selectors[5] = IERC3643.mint.selector;
        roles[5] = RolesLib.AGENT_MINTER;
        selectors[6] = IERC3643.burn.selector;
        roles[6] = RolesLib.AGENT_BURNER;
        selectors[7] = IERC3643.freezePartialTokens.selector;
        roles[7] = RolesLib.AGENT_PARTIAL_FREEZER;
        selectors[8] = IERC3643.unfreezePartialTokens.selector;
        roles[8] = RolesLib.AGENT_PARTIAL_FREEZER;
        selectors[9] = IERC3643.setAddressFrozen.selector;
        roles[9] = RolesLib.AGENT_ADDRESS_FREEZER;
        selectors[10] = IERC3643.recoveryAddress.selector;
        roles[10] = RolesLib.AGENT_RECOVERY_ADDRESS;
        selectors[11] = IERC3643.forcedTransfer.selector;
        roles[11] = RolesLib.AGENT_FORCED_TRANSFER;
        selectors[12] = IERC3643.pause.selector;
        roles[12] = RolesLib.AGENT_PAUSER;
        selectors[13] = IERC3643.unpause.selector;
        roles[13] = RolesLib.AGENT_PAUSER;
    }

    function registryTable() internal pure returns (bytes4[] memory selectors, uint64[] memory roles) {
        selectors = new bytes4[](14);
        roles = new uint64[](14);
        selectors[0] = IERC3643IdentityRegistry.setIdentityRegistryStorage.selector;
        selectors[1] = TREXRegistry.disableEligibilityChecks.selector;
        selectors[2] = TREXRegistry.enableEligibilityChecks.selector;
        selectors[3] = IERC3643TrustedIssuersRegistry.addTrustedIssuer.selector;
        selectors[4] = IERC3643TrustedIssuersRegistry.removeTrustedIssuer.selector;
        selectors[5] = IERC3643TrustedIssuersRegistry.updateIssuerClaimTopics.selector;
        selectors[6] = IERC3643ClaimTopicsRegistry.addClaimTopic.selector;
        selectors[7] = IERC3643ClaimTopicsRegistry.removeClaimTopic.selector;
        selectors[8] = TREXRegistry.addClaimTopicForIdentityType.selector;
        selectors[9] = TREXRegistry.removeClaimTopicForIdentityType.selector;
        for (uint256 i = 0; i < 10; i++) {
            roles[i] = RolesLib.OWNER;
        }
        selectors[10] = IERC3643IdentityRegistry.registerIdentity.selector;
        selectors[11] = IERC3643IdentityRegistry.batchRegisterIdentity.selector;
        selectors[12] = IERC3643IdentityRegistry.updateIdentity.selector;
        selectors[13] = IERC3643IdentityRegistry.deleteIdentity.selector;
        for (uint256 i = 10; i < 14; i++) {
            roles[i] = RolesLib.AGENT;
        }
    }

    function storageTable() internal pure returns (bytes4[] memory selectors, uint64[] memory roles) {
        selectors = new bytes4[](5);
        roles = new uint64[](5);
        selectors[0] = IdentityRegistryStorage.bindIdentityRegistry.selector;
        roles[0] = RolesLib.IRS_BINDER;
        selectors[1] = IdentityRegistryStorage.unbindIdentityRegistry.selector;
        roles[1] = RolesLib.OWNER;
        selectors[2] = IERC3643IdentityRegistryStorage.addIdentityToStorage.selector;
        roles[2] = RolesLib.AGENT;
        selectors[3] = IdentityRegistryStorage.modifyStoredIdentity.selector;
        roles[3] = RolesLib.AGENT;
        selectors[4] = IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector;
        roles[4] = RolesLib.AGENT;
    }

    function complianceTable() internal pure returns (bytes4[] memory selectors, uint64[] memory roles) {
        selectors = new bytes4[](6);
        roles = new uint64[](6);
        selectors[0] = ModularCompliance.removeModule.selector;
        selectors[1] = ModularCompliance.addAndSetModule.selector;
        selectors[2] = ModularCompliance.addModule.selector;
        selectors[3] = ModularCompliance.callModuleFunction.selector;
        selectors[4] = RolesLib.BIND_UNBIND_TOKEN;
        selectors[5] = ModularCompliance.refreshModuleCapabilities.selector;
        for (uint256 i = 0; i < 6; i++) {
            roles[i] = RolesLib.OWNER;
        }
    }

    function commissionSuite(IAccessManager accessManager, address token, bytes32 namespace) internal {
        require(_markOf(accessManager, token) == 0, ErrorsLib.AlreadyCommissioned(token));
        address registry = address(IERC3643(token).identityRegistry());
        address identityRegistryStorage = address(IERC3643IdentityRegistry(registry).identityStorage());
        (bytes32 storageNamespace, bool storageCommissioned) =
            _storagePolicy(accessManager, identityRegistryStorage, namespace);

        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT, namespace), token, 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT, storageNamespace), registry, 0);

        setupTokenRoles(accessManager, token, namespace);
        setupTREXRegistryRoles(accessManager, registry, namespace);
        setupModularComplianceRoles(accessManager, address(IERC3643(token).compliance()), namespace);
        _administer(accessManager, namespace);
        if (!storageCommissioned) {
            setupIdentityRegistryStorageRoles(accessManager, identityRegistryStorage, storageNamespace);
            _administer(accessManager, storageNamespace);
        }
    }

    struct Entitlement {
        address account;
        address token;
    }

    function migrateSuitesToNamespaces(
        IAccessManager accessManager,
        address[] memory tokens,
        bytes32[] memory namespaces,
        Entitlement[] memory entitlements
    ) internal {
        require(tokens.length == namespaces.length, ErrorsLib.ArrayLengthMismatch());
        _requireStandardAdministration(accessManager);
        address[] memory registries = new address[](tokens.length);
        bytes32[] memory storageNamespaces = new bytes32[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            require(namespaces[i] != RolesLib.SHARED, ErrorsLib.InvalidRoleNamespace());
            for (uint256 j = 0; j < i; j++) {
                require(tokens[j] != tokens[i] && namespaces[j] != namespaces[i], ErrorsLib.DuplicateMigrationEntry());
            }
            registries[i] = address(IERC3643(tokens[i]).identityRegistry());
            address identityRegistryStorage = address(IERC3643IdentityRegistry(registries[i]).identityStorage());
            storageNamespaces[i] = RolesLib.namespaceOf(identityRegistryStorage);
            _requireStandardSource(accessManager, tokens[i], registries[i], identityRegistryStorage);
            _requireUnusedDestination(accessManager, namespaces[i]);
            _requireGrantDelaysPrepared(accessManager, namespaces[i], false);
            _requireGrantDelaysPrepared(accessManager, storageNamespaces[i], true);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            address identityRegistryStorage = address(IERC3643IdentityRegistry(registries[i]).identityStorage());
            require(
                _allBound(
                    IERC3643IdentityRegistryStorage(identityRegistryStorage).linkedIdentityRegistries(), registries
                ),
                ErrorsLib.StorageSharedOutsideBatch(identityRegistryStorage)
            );
            _requireUnusedDestination(accessManager, storageNamespaces[i]);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            _grantNamespaced(accessManager, RolesLib.AGENT, namespaces[i], tokens[i]);
            _grantNamespaced(accessManager, RolesLib.AGENT, storageNamespaces[i], registries[i]);
        }
        for (uint256 i = 0; i < entitlements.length; i++) {
            uint256 index = _indexOf(tokens, entitlements[i].token);
            _grantNamespacedSuiteRoles(accessManager, namespaces[index], entitlements[i].account);
            _grantNamespaced(accessManager, RolesLib.OWNER, storageNamespaces[index], entitlements[i].account);
            _grantNamespaced(accessManager, RolesLib.AGENT_ADMIN, storageNamespaces[index], entitlements[i].account);
            _grantNamespaced(accessManager, RolesLib.IRS_BINDER, storageNamespaces[index], entitlements[i].account);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            setupTokenRoles(accessManager, tokens[i], namespaces[i]);
            setupTREXRegistryRoles(accessManager, registries[i], namespaces[i]);
            setupModularComplianceRoles(accessManager, address(IERC3643(tokens[i]).compliance()), namespaces[i]);
            _administer(accessManager, namespaces[i]);
            setupIdentityRegistryStorageRoles(
                accessManager, address(IERC3643IdentityRegistry(registries[i]).identityStorage()), storageNamespaces[i]
            );
            _administer(accessManager, storageNamespaces[i]);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            _revokeGlobal(accessManager, RolesLib.AGENT, tokens[i]);
            _revokeGlobal(accessManager, RolesLib.AGENT, registries[i]);
        }
        uint64[8] memory agentRoles = _agentRoles();
        for (uint256 i = 0; i < entitlements.length; i++) {
            for (uint256 j = 0; j < agentRoles.length; j++) {
                _revokeGlobal(accessManager, agentRoles[j], entitlements[i].account);
            }
            _revokeGlobal(accessManager, RolesLib.OWNER, entitlements[i].account);
            _revokeGlobal(accessManager, RolesLib.TOKEN_MANAGER, entitlements[i].account);
            _revokeGlobal(accessManager, RolesLib.IDENTITY_MANAGER, entitlements[i].account);
            _revokeGlobal(accessManager, RolesLib.IRS_BINDER, entitlements[i].account);
        }
        for (uint256 i = 0; i < entitlements.length; i++) {
            _revokeGlobal(accessManager, RolesLib.SUITE_ADMIN, entitlements[i].account);
            _revokeGlobal(accessManager, RolesLib.AGENT_ADMIN, entitlements[i].account);
        }
    }

    function setupTREXFactoryRoles(IAccessManager accessManager, address trexFactory) internal {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](4);
        functions[0] = TREXFactory.setImplementationAuthority.selector;
        functions[1] = TREXFactory.setIdFactory.selector;
        functions[2] = TREXFactory.deployTREXSuite.selector;
        functions[3] = TREXFactory.deployTREXSuiteIsolated.selector;
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
    /// @dev The ASSET module bundle is ONCHAINID configuration, registered on the IdentityFactory
    ///      via `setIdentityTypeModules` as part of its own deployment. An identity minted for a
    ///      type without modules cannot initialize, so that registration must also land before the
    ///      first auto-mint deploy.
    /// @param accessManager The IdentityFactory's authority, where ASSET_DEPLOYER is resolved
    /// @param identityFactory The ONCHAINID IdentityFactory that mints token OIDs
    /// @param trexFactory The TREX factory that calls `createIdentityFor` on the auto-mint path
    function setupIdentityFactoryPolicy(
        IAccessManager accessManager,
        IIdentityFactory identityFactory,
        address trexFactory
    ) internal {
        // ASSET is single-binding: a token OID binds to exactly one token and cannot be re-linked.
        identityFactory.setIdentityTypePolicy(IdentityTypes.ASSET, RolesLib.ASSET_DEPLOYER, false, true);
        accessManager.grantRole(RolesLib.ASSET_DEPLOYER, trexFactory, 0);
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
    function setupRoleAdmins(IAccessManager accessManager, bytes32 namespace) internal {
        (uint64[] memory roles, uint64[] memory admins) = roleAdminTable();
        for (uint256 i = 0; i < roles.length; i++) {
            if (admins[i] != 0) {
                accessManager.setRoleAdmin(
                    RolesLib.forSuite(roles[i], namespace), RolesLib.forSuite(admins[i], namespace)
                );
            }
        }
        _mark(accessManager, _namespaceTarget(namespace), namespace);
    }

    function roleAdminTable() internal pure returns (uint64[] memory roles, uint64[] memory admins) {
        uint64[14] memory suite = _suiteRoles();
        roles = new uint64[](14);
        admins = new uint64[](14);
        for (uint256 i = 0; i < 14; i++) {
            roles[i] = suite[i];
        }
        for (uint256 i = 0; i < 8; i++) {
            admins[i] = RolesLib.AGENT_ADMIN;
        }
        admins[9] = RolesLib.SUITE_ADMIN;
        admins[10] = RolesLib.SUITE_ADMIN;
        admins[13] = RolesLib.AGENT_ADMIN;
    }

    function setupLabels(IAccessManager accessManager, bytes32 namespace) internal {
        accessManager.labelRole(RolesLib.forSuite(RolesLib.OWNER, namespace), _label("TREX-Suite Owner", namespace));

        accessManager.labelRole(RolesLib.forSuite(RolesLib.AGENT, namespace), _label("TREX-Suite Agent", namespace));
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_MINTER, namespace), _label("TREX-Suite Agent: Minter", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_BURNER, namespace), _label("TREX-Suite Agent: Burner", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_PARTIAL_FREEZER, namespace),
            _label("TREX-Suite Agent: Partial Freezer", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_ADDRESS_FREEZER, namespace),
            _label("TREX-Suite Agent: Address Freezer", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_RECOVERY_ADDRESS, namespace),
            _label("TREX-Suite Agent: Recovery Address", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_FORCED_TRANSFER, namespace),
            _label("TREX-Suite Agent: Forced Transfer", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_PAUSER, namespace), _label("TREX-Suite Agent: Pauser", namespace)
        );

        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.TOKEN_MANAGER, namespace), _label("TREX-Suite Manager: Token", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.IDENTITY_MANAGER, namespace), _label("TREX-Suite Manager: Identity", namespace)
        );
        if (namespace == RolesLib.SHARED) {
            accessManager.labelRole(RolesLib.VERSION_MANAGER, "TREX-Suite Manager: Version");
        }

        // Role-givers
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.AGENT_ADMIN, namespace), _label("TREX-Suite Admin: Agent", namespace)
        );
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.SUITE_ADMIN, namespace), _label("TREX-Suite Admin: Suite", namespace)
        );

        // Transient deploy-time role
        accessManager.labelRole(
            RolesLib.forSuite(RolesLib.IRS_BINDER, namespace), _label("TREX-Suite IRS Binder (transient)", namespace)
        );

        // Resolved by the ONCHAINID IdentityFactory, not by any TREX selector mapping
        if (namespace == RolesLib.SHARED) {
            accessManager.labelRole(RolesLib.ASSET_DEPLOYER, "TREX-Suite Asset Deployer");
        }
    }

    function _grantNamespacedSuiteRoles(IAccessManager accessManager, bytes32 namespace, address account) private {
        uint64[8] memory agentRoles = _agentRoles();
        for (uint256 i = 0; i < agentRoles.length; i++) {
            _grantNamespaced(accessManager, agentRoles[i], namespace, account);
        }
        _grantNamespaced(accessManager, RolesLib.OWNER, namespace, account);
        _grantNamespaced(accessManager, RolesLib.TOKEN_MANAGER, namespace, account);
        _grantNamespaced(accessManager, RolesLib.IDENTITY_MANAGER, namespace, account);
        _grantNamespaced(accessManager, RolesLib.AGENT_ADMIN, namespace, account);
        _grantNamespaced(accessManager, RolesLib.SUITE_ADMIN, namespace, account);
    }

    function _grantNamespaced(IAccessManager accessManager, uint64 role, bytes32 namespace, address account) private {
        (uint48 since, uint32 currentDelay, uint32 pendingDelay, uint48 effect) = accessManager.getAccess(role, account);
        if (since == 0) {
            return;
        }
        require(since <= block.timestamp, ErrorsLib.PendingRoleGrant(account, role));
        require(effect <= block.timestamp, ErrorsLib.PendingDelayChange(account, role));
        uint32 executionDelay = effect != 0 ? pendingDelay : currentDelay;
        accessManager.grantRole(RolesLib.forSuite(role, namespace), account, executionDelay);
    }

    function _revokeGlobal(IAccessManager accessManager, uint64 role, address account) private {
        (uint48 since,,,) = accessManager.getAccess(role, account);
        if (since != 0) {
            accessManager.revokeRole(role, account);
        }
    }

    function _administer(IAccessManager accessManager, bytes32 namespace) private {
        address target = _namespaceTarget(namespace);
        if (_markOf(accessManager, target) != 0) {
            return;
        }
        setupRoleAdmins(accessManager, namespace);
        setupLabels(accessManager, namespace);
    }

    function _apply(
        IAccessManager accessManager,
        address target,
        bytes4[] memory selectors,
        uint64[] memory roles,
        bytes32 namespace
    ) private {
        bytes4[] memory one = new bytes4[](1);
        for (uint256 i = 0; i < selectors.length; i++) {
            one[0] = selectors[i];
            accessManager.setTargetFunctionRole(target, one, RolesLib.forSuite(roles[i], namespace));
        }
    }

    function _requireStandardSource(
        IAccessManager accessManager,
        address token,
        address registry,
        address identityRegistryStorage
    ) private view {
        require(_markOf(accessManager, token) == RolesLib.OWNER, ErrorsLib.NotCommissionedShared(token));
        require(
            _markOf(accessManager, identityRegistryStorage) == RolesLib.OWNER,
            ErrorsLib.NotCommissionedShared(identityRegistryStorage)
        );
        (bytes4[] memory selectors, uint64[] memory roles) = tokenTable();
        _requireStandardMappings(accessManager, token, selectors, roles);
        (selectors, roles) = registryTable();
        _requireStandardMappings(accessManager, registry, selectors, roles);
        (selectors, roles) = storageTable();
        _requireStandardMappings(accessManager, identityRegistryStorage, selectors, roles);
        (selectors, roles) = complianceTable();
        _requireStandardMappings(accessManager, address(IERC3643(token).compliance()), selectors, roles);
    }

    function _requireStandardMappings(
        IAccessManager accessManager,
        address target,
        bytes4[] memory selectors,
        uint64[] memory roles
    ) private view {
        for (uint256 i = 0; i < selectors.length; i++) {
            require(
                accessManager.getTargetFunctionRole(target, selectors[i]) == roles[i],
                ErrorsLib.NonStandardPolicy(target, selectors[i])
            );
        }
    }

    function _requireStandardAdministration(IAccessManager accessManager) private view {
        (uint64[] memory roles, uint64[] memory admins) = roleAdminTable();
        for (uint256 i = 0; i < roles.length; i++) {
            require(
                accessManager.getRoleAdmin(roles[i]) == admins[i] && accessManager.getRoleGuardian(roles[i]) == 0,
                ErrorsLib.NonStandardAdministration(roles[i])
            );
        }
    }

    function _requireUnusedDestination(IAccessManager accessManager, bytes32 namespace) private view {
        require(
            _markOf(accessManager, _namespaceTarget(namespace)) == 0, ErrorsLib.DestinationNamespaceInUse(namespace)
        );
        uint64[14] memory roles = _suiteRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            uint64 target = RolesLib.forSuite(roles[i], namespace);
            require(
                accessManager.getRoleAdmin(target) == 0 && accessManager.getRoleGuardian(target) == 0,
                ErrorsLib.DestinationNamespaceInUse(namespace)
            );
        }
    }

    function _mark(IAccessManager accessManager, address target, bytes32 namespace) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RolesLib.COMMISSIONED;
        accessManager.setTargetFunctionRole(target, selectors, RolesLib.forSuite(RolesLib.OWNER, namespace));
    }

    function _markOf(IAccessManager accessManager, address target) private view returns (uint64) {
        return accessManager.getTargetFunctionRole(target, RolesLib.COMMISSIONED);
    }

    function _namespaceTarget(bytes32 namespace) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("TREX-Suite.namespace", namespace)))));
    }

    function _requireGrantDelaysPrepared(IAccessManager accessManager, bytes32 namespace, bool storageOnly)
        private
        view
    {
        uint64[14] memory roles = _suiteRoles();
        uint256 count = storageOnly ? 4 : roles.length;
        for (uint256 i = 0; i < count; i++) {
            uint64 role = storageOnly ? _storageRoles()[i] : roles[i];
            require(
                accessManager.getRoleGrantDelay(RolesLib.forSuite(role, namespace))
                    == accessManager.getRoleGrantDelay(role),
                ErrorsLib.GrantDelayNotPrepared(role, namespace)
            );
        }
    }

    function _storageRoles() private pure returns (uint64[4] memory) {
        return [RolesLib.AGENT, RolesLib.OWNER, RolesLib.AGENT_ADMIN, RolesLib.IRS_BINDER];
    }

    function _suiteRoles() private pure returns (uint64[14] memory) {
        return [
            RolesLib.AGENT,
            RolesLib.AGENT_MINTER,
            RolesLib.AGENT_BURNER,
            RolesLib.AGENT_PARTIAL_FREEZER,
            RolesLib.AGENT_ADDRESS_FREEZER,
            RolesLib.AGENT_RECOVERY_ADDRESS,
            RolesLib.AGENT_FORCED_TRANSFER,
            RolesLib.AGENT_PAUSER,
            RolesLib.OWNER,
            RolesLib.TOKEN_MANAGER,
            RolesLib.IDENTITY_MANAGER,
            RolesLib.AGENT_ADMIN,
            RolesLib.SUITE_ADMIN,
            RolesLib.IRS_BINDER
        ];
    }

    function _allBound(address[] memory linked, address[] memory registries) private pure returns (bool) {
        for (uint256 i = 0; i < linked.length; i++) {
            bool found;
            for (uint256 j = 0; j < registries.length; j++) {
                if (registries[j] == linked[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }
        return true;
    }

    function _indexOf(address[] memory tokens, address token) private pure returns (uint256) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                return i;
            }
        }
        revert ErrorsLib.EntitlementTokenNotMigrated(token);
    }

    function _agentRoles() private pure returns (uint64[8] memory) {
        return [
            RolesLib.AGENT,
            RolesLib.AGENT_MINTER,
            RolesLib.AGENT_BURNER,
            RolesLib.AGENT_PARTIAL_FREEZER,
            RolesLib.AGENT_ADDRESS_FREEZER,
            RolesLib.AGENT_RECOVERY_ADDRESS,
            RolesLib.AGENT_FORCED_TRANSFER,
            RolesLib.AGENT_PAUSER
        ];
    }

    function _storagePolicy(IAccessManager accessManager, address identityRegistryStorage, bytes32 namespace)
        private
        view
        returns (bytes32 storageNamespace, bool commissioned)
    {
        uint64 mark = _markOf(accessManager, identityRegistryStorage);
        bytes32 own = RolesLib.namespaceOf(identityRegistryStorage);
        if (mark == 0) {
            return (namespace == RolesLib.SHARED ? RolesLib.SHARED : own, false);
        }
        if (mark == RolesLib.forSuite(RolesLib.OWNER, own)) {
            return (own, true);
        }
        if (mark == RolesLib.OWNER) {
            return (RolesLib.SHARED, true);
        }
        revert ErrorsLib.UnknownStoragePolicy(identityRegistryStorage);
    }

    function _label(string memory base, bytes32 namespace) private pure returns (string memory) {
        if (namespace == RolesLib.SHARED) {
            return base;
        }
        return string.concat(base, " @ ", Strings.toHexString(uint256(namespace), 32));
    }

}
