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
import { ITREXFactory } from "../factory/ITREXFactory.sol";
import { TREXImplementationAuthority } from "../proxy/beacon/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "../registry/implementation/TREXRegistry.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { RolesLib } from "./RolesLib.sol";

/// @title AccessManagerSetupLib
/// @notice Library for setting up roles and functions in AccessManager for the TREX suite contracts
library AccessManagerSetupLib {

    struct SelectorRole {
        bytes4 selector;
        uint64 role;
    }

    struct RoleAdmin {
        uint64 role;
        uint64 admin;
    }

    struct RoleLabel {
        uint64 role;
        string label;
    }

    struct RoleAssignment {
        address account;
        uint64 role;
        bytes32 namespace;
    }

    struct GlobalRevocation {
        address account;
        uint64 role;
    }

    uint64 internal constant ADMIN_ROLE = 0;

    function setupTokenRoles(IAccessManager accessManager, address token, bytes32 namespace) internal {
        _apply(accessManager, token, tokenTable(), namespace);
        _mark(accessManager, token, namespace);
    }

    function setupIdentityRegistryStorageRoles(
        IAccessManager accessManager,
        address identityRegistryStorage,
        bytes32 namespace
    ) internal {
        _apply(accessManager, identityRegistryStorage, storageTable(), namespace);
        _mark(accessManager, identityRegistryStorage, namespace);
    }

    function setupTREXRegistryRoles(IAccessManager accessManager, address registry, bytes32 namespace) internal {
        _apply(accessManager, registry, registryTable(), namespace);
    }

    function setupModularComplianceRoles(IAccessManager accessManager, address modularCompliance, bytes32 namespace)
        internal
    {
        _apply(accessManager, modularCompliance, complianceTable(), namespace);
    }

    function tokenTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](14);
        table[0] = SelectorRole(IERC3643.setName.selector, RolesLib.TOKEN_MANAGER);
        table[1] = SelectorRole(IERC3643.setSymbol.selector, RolesLib.TOKEN_MANAGER);
        table[2] = SelectorRole(IERC3643.setOnchainID.selector, RolesLib.IDENTITY_MANAGER);
        table[3] = SelectorRole(IERC3643.setIdentityRegistry.selector, RolesLib.IDENTITY_MANAGER);
        table[4] = SelectorRole(IERC3643.setCompliance.selector, RolesLib.IDENTITY_MANAGER);
        table[5] = SelectorRole(IERC3643.mint.selector, RolesLib.AGENT_MINTER);
        table[6] = SelectorRole(IERC3643.burn.selector, RolesLib.AGENT_BURNER);
        table[7] = SelectorRole(IERC3643.freezePartialTokens.selector, RolesLib.AGENT_PARTIAL_FREEZER);
        table[8] = SelectorRole(IERC3643.unfreezePartialTokens.selector, RolesLib.AGENT_PARTIAL_FREEZER);
        table[9] = SelectorRole(IERC3643.setAddressFrozen.selector, RolesLib.AGENT_ADDRESS_FREEZER);
        table[10] = SelectorRole(IERC3643.recoveryAddress.selector, RolesLib.AGENT_RECOVERY_ADDRESS);
        table[11] = SelectorRole(IERC3643.forcedTransfer.selector, RolesLib.AGENT_FORCED_TRANSFER);
        table[12] = SelectorRole(IERC3643.pause.selector, RolesLib.AGENT_PAUSER);
        table[13] = SelectorRole(IERC3643.unpause.selector, RolesLib.AGENT_PAUSER);
    }

    function registryTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](14);
        table[0] = SelectorRole(IERC3643IdentityRegistry.setIdentityRegistryStorage.selector, RolesLib.OWNER);
        table[1] = SelectorRole(TREXRegistry.disableEligibilityChecks.selector, RolesLib.OWNER);
        table[2] = SelectorRole(TREXRegistry.enableEligibilityChecks.selector, RolesLib.OWNER);
        table[3] = SelectorRole(IERC3643TrustedIssuersRegistry.addTrustedIssuer.selector, RolesLib.OWNER);
        table[4] = SelectorRole(IERC3643TrustedIssuersRegistry.removeTrustedIssuer.selector, RolesLib.OWNER);
        table[5] = SelectorRole(IERC3643TrustedIssuersRegistry.updateIssuerClaimTopics.selector, RolesLib.OWNER);
        table[6] = SelectorRole(IERC3643ClaimTopicsRegistry.addClaimTopic.selector, RolesLib.OWNER);
        table[7] = SelectorRole(IERC3643ClaimTopicsRegistry.removeClaimTopic.selector, RolesLib.OWNER);
        table[8] = SelectorRole(TREXRegistry.addClaimTopicForIdentityType.selector, RolesLib.OWNER);
        table[9] = SelectorRole(TREXRegistry.removeClaimTopicForIdentityType.selector, RolesLib.OWNER);
        table[10] = SelectorRole(IERC3643IdentityRegistry.registerIdentity.selector, RolesLib.AGENT);
        table[11] = SelectorRole(IERC3643IdentityRegistry.batchRegisterIdentity.selector, RolesLib.AGENT);
        table[12] = SelectorRole(IERC3643IdentityRegistry.updateIdentity.selector, RolesLib.AGENT);
        table[13] = SelectorRole(IERC3643IdentityRegistry.deleteIdentity.selector, RolesLib.AGENT);
    }

    function storageTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](5);
        table[0] = SelectorRole(IdentityRegistryStorage.bindIdentityRegistry.selector, RolesLib.IRS_BINDER);
        table[1] = SelectorRole(IdentityRegistryStorage.unbindIdentityRegistry.selector, RolesLib.OWNER);
        table[2] = SelectorRole(IERC3643IdentityRegistryStorage.addIdentityToStorage.selector, RolesLib.AGENT);
        table[3] = SelectorRole(IdentityRegistryStorage.modifyStoredIdentity.selector, RolesLib.AGENT);
        table[4] = SelectorRole(IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector, RolesLib.AGENT);
    }

    function complianceTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](6);
        table[0] = SelectorRole(ModularCompliance.removeModule.selector, RolesLib.OWNER);
        table[1] = SelectorRole(ModularCompliance.addAndSetModule.selector, RolesLib.OWNER);
        table[2] = SelectorRole(ModularCompliance.addModule.selector, RolesLib.OWNER);
        table[3] = SelectorRole(ModularCompliance.callModuleFunction.selector, RolesLib.OWNER);
        table[4] = SelectorRole(RolesLib.BIND_UNBIND_TOKEN, RolesLib.OWNER);
        table[5] = SelectorRole(ModularCompliance.refreshModuleCapabilities.selector, RolesLib.OWNER);
    }

    function roleAdminTable() internal pure returns (RoleAdmin[] memory table) {
        table = new RoleAdmin[](14);
        table[0] = RoleAdmin(RolesLib.AGENT, RolesLib.AGENT_ADMIN);
        table[1] = RoleAdmin(RolesLib.AGENT_MINTER, RolesLib.AGENT_ADMIN);
        table[2] = RoleAdmin(RolesLib.AGENT_BURNER, RolesLib.AGENT_ADMIN);
        table[3] = RoleAdmin(RolesLib.AGENT_PARTIAL_FREEZER, RolesLib.AGENT_ADMIN);
        table[4] = RoleAdmin(RolesLib.AGENT_ADDRESS_FREEZER, RolesLib.AGENT_ADMIN);
        table[5] = RoleAdmin(RolesLib.AGENT_RECOVERY_ADDRESS, RolesLib.AGENT_ADMIN);
        table[6] = RoleAdmin(RolesLib.AGENT_FORCED_TRANSFER, RolesLib.AGENT_ADMIN);
        table[7] = RoleAdmin(RolesLib.AGENT_PAUSER, RolesLib.AGENT_ADMIN);
        table[8] = RoleAdmin(RolesLib.OWNER, ADMIN_ROLE);
        table[9] = RoleAdmin(RolesLib.TOKEN_MANAGER, RolesLib.SUITE_ADMIN);
        table[10] = RoleAdmin(RolesLib.IDENTITY_MANAGER, RolesLib.SUITE_ADMIN);
        table[11] = RoleAdmin(RolesLib.AGENT_ADMIN, ADMIN_ROLE);
        table[12] = RoleAdmin(RolesLib.SUITE_ADMIN, ADMIN_ROLE);
        table[13] = RoleAdmin(RolesLib.IRS_BINDER, RolesLib.AGENT_ADMIN);
    }

    function labelTable() internal pure returns (RoleLabel[] memory table) {
        table = new RoleLabel[](14);
        table[0] = RoleLabel(RolesLib.OWNER, "TREX-Suite Owner");
        table[1] = RoleLabel(RolesLib.AGENT, "TREX-Suite Agent");
        table[2] = RoleLabel(RolesLib.AGENT_MINTER, "TREX-Suite Agent: Minter");
        table[3] = RoleLabel(RolesLib.AGENT_BURNER, "TREX-Suite Agent: Burner");
        table[4] = RoleLabel(RolesLib.AGENT_PARTIAL_FREEZER, "TREX-Suite Agent: Partial Freezer");
        table[5] = RoleLabel(RolesLib.AGENT_ADDRESS_FREEZER, "TREX-Suite Agent: Address Freezer");
        table[6] = RoleLabel(RolesLib.AGENT_RECOVERY_ADDRESS, "TREX-Suite Agent: Recovery Address");
        table[7] = RoleLabel(RolesLib.AGENT_FORCED_TRANSFER, "TREX-Suite Agent: Forced Transfer");
        table[8] = RoleLabel(RolesLib.AGENT_PAUSER, "TREX-Suite Agent: Pauser");
        table[9] = RoleLabel(RolesLib.TOKEN_MANAGER, "TREX-Suite Manager: Token");
        table[10] = RoleLabel(RolesLib.IDENTITY_MANAGER, "TREX-Suite Manager: Identity");
        table[11] = RoleLabel(RolesLib.AGENT_ADMIN, "TREX-Suite Admin: Agent");
        table[12] = RoleLabel(RolesLib.SUITE_ADMIN, "TREX-Suite Admin: Suite");
        table[13] = RoleLabel(RolesLib.IRS_BINDER, "TREX-Suite IRS Binder");
    }

    function commissionSuite(IAccessManager accessManager, address token) internal {
        commissionSuite(accessManager, token, RolesLib.namespaceOf(token));
    }

    function commissionSuite(IAccessManager accessManager, address token, bytes32 namespace) internal {
        require(_markOf(accessManager, token) == 0, ErrorsLib.AlreadyCommissioned(token));
        address registry = _registryOf(token);
        address identityRegistryStorage = _storageOf(registry);
        require(namespace != RolesLib.namespaceOf(identityRegistryStorage), ErrorsLib.InvalidRoleNamespace());
        (bytes32 storageNamespace, bool storageCommissioned) =
            _storagePolicy(accessManager, identityRegistryStorage, namespace);

        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT, namespace), token, 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT, storageNamespace), registry, 0);

        setupTokenRoles(accessManager, token, namespace);
        setupTREXRegistryRoles(accessManager, registry, namespace);
        setupModularComplianceRoles(accessManager, _complianceOf(token), namespace);
        _administer(accessManager, namespace);
        if (!_isBound(identityRegistryStorage, registry)) {
            IERC3643IdentityRegistryStorage(identityRegistryStorage).bindIdentityRegistry(registry);
        }
        if (!storageCommissioned) {
            setupIdentityRegistryStorageRoles(accessManager, identityRegistryStorage, storageNamespace);
            _administer(accessManager, storageNamespace);
        }
    }

    function migrateSuitesToNamespaces(
        IAccessManager accessManager,
        address[] memory tokens,
        bytes32[] memory namespaces,
        RoleAssignment[] memory assignments,
        GlobalRevocation[] memory revocations
    ) internal {
        require(tokens.length == namespaces.length, ErrorsLib.ArrayLengthMismatch());
        _requireStandardAdministration(accessManager);
        (address[] memory registries, bytes32[] memory storageNamespaces) =
            _validateBatch(accessManager, tokens, namespaces);
        _validateAssignments(accessManager, assignments, namespaces, storageNamespaces);
        _validateRevocations(accessManager, revocations);

        _grantNamespacedRoles(accessManager, tokens, registries, namespaces, storageNamespaces, assignments);
        _mapNamespaces(accessManager, tokens, registries, namespaces, storageNamespaces);
        _revokeGlobalRoles(accessManager, tokens, registries, revocations);
    }

    function remainingGlobalHolders(IAccessManager accessManager, address[] memory accounts)
        internal
        view
        returns (address[] memory holders)
    {
        uint64[] memory roles = _suiteRoles();
        address[] memory found = new address[](accounts.length);
        uint256 count;
        for (uint256 i = 0; i < accounts.length; i++) {
            if (_holdsAny(accessManager, roles, accounts[i])) {
                found[count++] = accounts[i];
            }
        }
        holders = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            holders[i] = found[i];
        }
    }

    function setupTREXFactoryRoles(IAccessManager accessManager, address trexFactory) internal {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](4);
        functions[0] = ITREXFactory.setImplementationAuthority.selector;
        functions[1] = ITREXFactory.setIdFactory.selector;
        functions[2] = ITREXFactory.deployTREXSuite.selector;
        functions[3] = ITREXFactory.deployTREXSuiteIsolated.selector;
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

    function setupRoleAdmins(IAccessManager accessManager, bytes32 namespace) internal {
        RoleAdmin[] memory table = roleAdminTable();
        for (uint256 i = 0; i < table.length; i++) {
            if (table[i].admin == ADMIN_ROLE) {
                continue;
            }
            accessManager.setRoleAdmin(
                RolesLib.forSuite(table[i].role, namespace), RolesLib.forSuite(table[i].admin, namespace)
            );
        }
        _mark(accessManager, _namespaceTarget(namespace), namespace);
    }

    function setupLabels(IAccessManager accessManager, bytes32 namespace) internal {
        RoleLabel[] memory table = labelTable();
        for (uint256 i = 0; i < table.length; i++) {
            accessManager.labelRole(RolesLib.forSuite(table[i].role, namespace), _label(table[i].label, namespace));
        }
    }

    function setupGlobalLabels(IAccessManager accessManager) internal {
        accessManager.labelRole(RolesLib.VERSION_MANAGER, "TREX-Suite Manager: Version");
        accessManager.labelRole(RolesLib.ASSET_DEPLOYER, "TREX-Suite Asset Deployer");
    }

    function markerTarget(address target) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("TREX-Suite.target", target)))));
    }

    function _validateBatch(IAccessManager accessManager, address[] memory tokens, bytes32[] memory namespaces)
        private
        view
        returns (address[] memory registries, bytes32[] memory storageNamespaces)
    {
        registries = new address[](tokens.length);
        storageNamespaces = new bytes32[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            require(namespaces[i] != RolesLib.SHARED, ErrorsLib.InvalidRoleNamespace());
            for (uint256 j = 0; j < i; j++) {
                require(tokens[j] != tokens[i] && namespaces[j] != namespaces[i], ErrorsLib.DuplicateMigrationEntry());
            }
            registries[i] = _registryOf(tokens[i]);
            address identityRegistryStorage = _storageOf(registries[i]);
            storageNamespaces[i] = RolesLib.namespaceOf(identityRegistryStorage);
            _requireStandardSource(accessManager, tokens[i], registries[i], identityRegistryStorage);
            _requireUnusedDestination(accessManager, namespaces[i]);
            _requireGrantDelaysPrepared(accessManager, _suiteRoles(), namespaces[i]);
            _requireGrantDelaysPrepared(accessManager, _storageRoles(), storageNamespaces[i]);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            require(!_contains(storageNamespaces, namespaces[i]), ErrorsLib.InvalidRoleNamespace());
            address identityRegistryStorage = _storageOf(registries[i]);
            require(
                _allBound(_linkedRegistries(identityRegistryStorage), registries),
                ErrorsLib.StorageSharedOutsideBatch(identityRegistryStorage)
            );
            _requireUnusedDestination(accessManager, storageNamespaces[i]);
        }
    }

    function _validateAssignments(
        IAccessManager accessManager,
        RoleAssignment[] memory assignments,
        bytes32[] memory namespaces,
        bytes32[] memory storageNamespaces
    ) private view {
        for (uint256 i = 0; i < assignments.length; i++) {
            RoleAssignment memory assignment = assignments[i];
            for (uint256 j = 0; j < i; j++) {
                require(!_sameAssignment(assignments[j], assignment), ErrorsLib.DuplicateMigrationEntry());
            }
            bool inSuite = _contains(namespaces, assignment.namespace);
            bool inStorage = _contains(storageNamespaces, assignment.namespace);
            require(inSuite || inStorage, ErrorsLib.AssignmentNamespaceNotMigrated(assignment.namespace));
            bool allowed = inSuite ? _isSuiteRole(assignment.role) : _isStorageRole(assignment.role);
            require(allowed, ErrorsLib.InvalidRoleForNamespace(assignment.role, assignment.namespace));
            _requireActiveGlobal(accessManager, assignment.role, assignment.account);
        }
    }

    function _validateRevocations(IAccessManager accessManager, GlobalRevocation[] memory revocations) private view {
        for (uint256 i = 0; i < revocations.length; i++) {
            GlobalRevocation memory revocation = revocations[i];
            for (uint256 j = 0; j < i; j++) {
                require(!_sameRevocation(revocations[j], revocation), ErrorsLib.DuplicateMigrationEntry());
            }
            require(
                _containsRole(_suiteRoles(), revocation.role),
                ErrorsLib.InvalidRoleForNamespace(revocation.role, RolesLib.SHARED)
            );
            _requireActiveGlobal(accessManager, revocation.role, revocation.account);
        }
    }

    function _grantNamespacedRoles(
        IAccessManager accessManager,
        address[] memory tokens,
        address[] memory registries,
        bytes32[] memory namespaces,
        bytes32[] memory storageNamespaces,
        RoleAssignment[] memory assignments
    ) private {
        for (uint256 i = 0; i < assignments.length; i++) {
            _grantFromGlobal(accessManager, assignments[i].role, assignments[i].namespace, assignments[i].account);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            _grantFromGlobal(accessManager, RolesLib.AGENT, namespaces[i], tokens[i]);
            _grantFromGlobal(accessManager, RolesLib.AGENT, storageNamespaces[i], registries[i]);
        }
    }

    function _mapNamespaces(
        IAccessManager accessManager,
        address[] memory tokens,
        address[] memory registries,
        bytes32[] memory namespaces,
        bytes32[] memory storageNamespaces
    ) private {
        for (uint256 i = 0; i < tokens.length; i++) {
            setupTokenRoles(accessManager, tokens[i], namespaces[i]);
            setupTREXRegistryRoles(accessManager, registries[i], namespaces[i]);
            setupModularComplianceRoles(accessManager, _complianceOf(tokens[i]), namespaces[i]);
            _administer(accessManager, namespaces[i]);
            setupIdentityRegistryStorageRoles(accessManager, _storageOf(registries[i]), storageNamespaces[i]);
            _administer(accessManager, storageNamespaces[i]);
        }
    }

    function _revokeGlobalRoles(
        IAccessManager accessManager,
        address[] memory tokens,
        address[] memory registries,
        GlobalRevocation[] memory revocations
    ) private {
        for (uint256 i = 0; i < tokens.length; i++) {
            accessManager.revokeRole(RolesLib.AGENT, tokens[i]);
            accessManager.revokeRole(RolesLib.AGENT, registries[i]);
        }
        for (uint256 i = 0; i < revocations.length; i++) {
            if (!_isAdministrative(revocations[i].role)) {
                accessManager.revokeRole(revocations[i].role, revocations[i].account);
            }
        }
        for (uint256 i = 0; i < revocations.length; i++) {
            if (_isAdministrative(revocations[i].role)) {
                accessManager.revokeRole(revocations[i].role, revocations[i].account);
            }
        }
    }

    function _requireActiveGlobal(IAccessManager accessManager, uint64 role, address account)
        private
        view
        returns (uint32 executionDelay)
    {
        (uint48 since, uint32 currentDelay,, uint48 effect) = accessManager.getAccess(role, account);
        require(since != 0, ErrorsLib.RoleNotHeld(account, role));
        require(since <= block.timestamp, ErrorsLib.PendingRoleGrant(account, role));
        require(effect <= block.timestamp, ErrorsLib.PendingDelayChange(account, role));
        return currentDelay;
    }

    function _grantFromGlobal(IAccessManager accessManager, uint64 role, bytes32 namespace, address account) private {
        uint32 executionDelay = _requireActiveGlobal(accessManager, role, account);
        accessManager.grantRole(RolesLib.forSuite(role, namespace), account, executionDelay);
    }

    function _holdsAny(IAccessManager accessManager, uint64[] memory roles, address account)
        private
        view
        returns (bool)
    {
        for (uint256 i = 0; i < roles.length; i++) {
            (uint48 since,,,) = accessManager.getAccess(roles[i], account);
            if (since != 0) {
                return true;
            }
        }
        return false;
    }

    function _isAdministrative(uint64 role) private pure returns (bool) {
        return role == RolesLib.AGENT_ADMIN || role == RolesLib.SUITE_ADMIN;
    }

    function _isSuiteRole(uint64 role) private pure returns (bool) {
        if (role == RolesLib.IRS_BINDER) {
            return false;
        }
        return _containsRole(_suiteRoles(), role);
    }

    function _isStorageRole(uint64 role) private pure returns (bool) {
        return _containsRole(_storageRoles(), role);
    }

    function _sameAssignment(RoleAssignment memory a, RoleAssignment memory b) private pure returns (bool) {
        return a.account == b.account && a.role == b.role && a.namespace == b.namespace;
    }

    function _sameRevocation(GlobalRevocation memory a, GlobalRevocation memory b) private pure returns (bool) {
        return a.account == b.account && a.role == b.role;
    }

    function _administer(IAccessManager accessManager, bytes32 namespace) private {
        if (_markOf(accessManager, _namespaceTarget(namespace)) != 0) {
            return;
        }
        setupRoleAdmins(accessManager, namespace);
    }

    function _apply(IAccessManager accessManager, address target, SelectorRole[] memory table, bytes32 namespace)
        private
    {
        for (uint256 i = 0; i < table.length; i++) {
            if (_seenBefore(table, i)) {
                continue;
            }
            uint64 role = table[i].role;
            accessManager.setTargetFunctionRole(target, _selectorsFor(table, role), RolesLib.forSuite(role, namespace));
        }
    }

    function _seenBefore(SelectorRole[] memory table, uint256 index) private pure returns (bool) {
        for (uint256 j = 0; j < index; j++) {
            if (table[j].role == table[index].role) {
                return true;
            }
        }
        return false;
    }

    function _selectorsFor(SelectorRole[] memory table, uint64 role) private pure returns (bytes4[] memory selectors) {
        uint256 count;
        for (uint256 i = 0; i < table.length; i++) {
            if (table[i].role == role) {
                count++;
            }
        }
        selectors = new bytes4[](count);
        uint256 next;
        for (uint256 i = 0; i < table.length; i++) {
            if (table[i].role == role) {
                selectors[next++] = table[i].selector;
            }
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
        _requireStandardMappings(accessManager, token, tokenTable());
        _requireStandardMappings(accessManager, registry, registryTable());
        _requireStandardMappings(accessManager, identityRegistryStorage, storageTable());
        _requireStandardMappings(accessManager, _complianceOf(token), complianceTable());
    }

    function _requireStandardMappings(IAccessManager accessManager, address target, SelectorRole[] memory table)
        private
        view
    {
        for (uint256 i = 0; i < table.length; i++) {
            require(
                accessManager.getTargetFunctionRole(target, table[i].selector) == table[i].role,
                ErrorsLib.NonStandardPolicy(target, table[i].selector)
            );
        }
    }

    function _requireStandardAdministration(IAccessManager accessManager) private view {
        RoleAdmin[] memory table = roleAdminTable();
        for (uint256 i = 0; i < table.length; i++) {
            bool standardAdmin = accessManager.getRoleAdmin(table[i].role) == table[i].admin;
            bool standardGuardian = accessManager.getRoleGuardian(table[i].role) == ADMIN_ROLE;
            require(standardAdmin && standardGuardian, ErrorsLib.NonStandardAdministration(table[i].role));
        }
    }

    function _requireUnusedDestination(IAccessManager accessManager, bytes32 namespace) private view {
        require(
            _markOf(accessManager, _namespaceTarget(namespace)) == 0, ErrorsLib.DestinationNamespaceInUse(namespace)
        );
        uint64[] memory roles = _suiteRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            uint64 role = RolesLib.forSuite(roles[i], namespace);
            bool untouchedAdmin = accessManager.getRoleAdmin(role) == ADMIN_ROLE;
            bool untouchedGuardian = accessManager.getRoleGuardian(role) == ADMIN_ROLE;
            require(untouchedAdmin && untouchedGuardian, ErrorsLib.DestinationNamespaceInUse(namespace));
        }
    }

    function _requireGrantDelaysPrepared(IAccessManager accessManager, uint64[] memory roles, bytes32 namespace)
        private
        view
    {
        for (uint256 i = 0; i < roles.length; i++) {
            uint32 globalDelay = accessManager.getRoleGrantDelay(roles[i]);
            uint32 namespacedDelay = accessManager.getRoleGrantDelay(RolesLib.forSuite(roles[i], namespace));
            require(namespacedDelay == globalDelay, ErrorsLib.GrantDelayNotPrepared(roles[i], namespace));
        }
    }

    function _mark(IAccessManager accessManager, address target, bytes32 namespace) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RolesLib.COMMISSIONED;
        accessManager.setTargetFunctionRole(
            markerTarget(target), selectors, RolesLib.forSuite(RolesLib.OWNER, namespace)
        );
    }

    function _markOf(IAccessManager accessManager, address target) private view returns (uint64) {
        return accessManager.getTargetFunctionRole(markerTarget(target), RolesLib.COMMISSIONED);
    }

    function _namespaceTarget(bytes32 namespace) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("TREX-Suite.namespace", namespace)))));
    }

    function _storagePolicy(IAccessManager accessManager, address identityRegistryStorage, bytes32 suiteNamespace)
        private
        view
        returns (bytes32 storageNamespace, bool commissioned)
    {
        uint64 mark = _markOf(accessManager, identityRegistryStorage);
        bytes32 own = RolesLib.namespaceOf(identityRegistryStorage);
        if (mark == 0) {
            if (suiteNamespace == RolesLib.SHARED) {
                return (RolesLib.SHARED, false);
            }
            return (own, false);
        }
        if (mark == RolesLib.forSuite(RolesLib.OWNER, own)) {
            return (own, true);
        }
        if (mark == RolesLib.OWNER) {
            return (RolesLib.SHARED, true);
        }
        revert ErrorsLib.UnknownStoragePolicy(identityRegistryStorage);
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

    function _linkedRegistries(address identityRegistryStorage) private view returns (address[] memory) {
        return IERC3643IdentityRegistryStorage(identityRegistryStorage).linkedIdentityRegistries();
    }

    function _isBound(address identityRegistryStorage, address registry) private view returns (bool) {
        return _containsAddress(_linkedRegistries(identityRegistryStorage), registry);
    }

    function _allBound(address[] memory linked, address[] memory registries) private pure returns (bool) {
        for (uint256 i = 0; i < linked.length; i++) {
            if (!_containsAddress(registries, linked[i])) {
                return false;
            }
        }
        return true;
    }

    function _contains(bytes32[] memory list, bytes32 item) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) {
                return true;
            }
        }
        return false;
    }

    function _containsAddress(address[] memory list, address item) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) {
                return true;
            }
        }
        return false;
    }

    function _containsRole(uint64[] memory list, uint64 item) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) {
                return true;
            }
        }
        return false;
    }

    function _suiteRoles() private pure returns (uint64[] memory roles) {
        RoleAdmin[] memory table = roleAdminTable();
        roles = new uint64[](table.length);
        for (uint256 i = 0; i < table.length; i++) {
            roles[i] = table[i].role;
        }
    }

    function _storageRoles() private pure returns (uint64[] memory roles) {
        roles = new uint64[](4);
        roles[0] = RolesLib.AGENT;
        roles[1] = RolesLib.OWNER;
        roles[2] = RolesLib.AGENT_ADMIN;
        roles[3] = RolesLib.IRS_BINDER;
    }

    function _label(string memory base, bytes32 namespace) private pure returns (string memory) {
        if (namespace == RolesLib.SHARED) {
            return base;
        }
        return string.concat(base, " @ ", Strings.toHexString(uint256(namespace) >> 96, 8));
    }

}
