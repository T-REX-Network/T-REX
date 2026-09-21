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
        bytes32 name;
    }

    struct RoleAdmin {
        bytes32 name;
        bytes32 admin;
    }

    struct RoleLabel {
        bytes32 name;
        string label;
    }

    struct RoleAssignment {
        address account;
        bytes32 name;
        bytes32 scope;
    }

    struct SharedRevocation {
        address account;
        bytes32 name;
    }

    uint64 internal constant ADMIN_ROLE = 0;

    function setupTokenRoles(IAccessManager accessManager, address token, bytes32 scope) internal {
        _apply(accessManager, token, tokenTable(), scope);
    }

    function setupIdentityRegistryStorageRoles(
        IAccessManager accessManager,
        address identityRegistryStorage,
        bytes32 scope
    ) internal {
        _apply(accessManager, identityRegistryStorage, storageTable(), scope);
    }

    function setupTREXRegistryRoles(IAccessManager accessManager, address registry, bytes32 scope) internal {
        _apply(accessManager, registry, registryTable(), scope);
    }

    function setupModularComplianceRoles(IAccessManager accessManager, address modularCompliance, bytes32 scope)
        internal
    {
        _apply(accessManager, modularCompliance, complianceTable(), scope);
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
        table = new RoleAdmin[](11);
        table[0] = RoleAdmin(RolesLib.AGENT, RolesLib.AGENT_ADMIN);
        table[1] = RoleAdmin(RolesLib.AGENT_MINTER, RolesLib.AGENT_ADMIN);
        table[2] = RoleAdmin(RolesLib.AGENT_BURNER, RolesLib.AGENT_ADMIN);
        table[3] = RoleAdmin(RolesLib.AGENT_PARTIAL_FREEZER, RolesLib.AGENT_ADMIN);
        table[4] = RoleAdmin(RolesLib.AGENT_ADDRESS_FREEZER, RolesLib.AGENT_ADMIN);
        table[5] = RoleAdmin(RolesLib.AGENT_RECOVERY_ADDRESS, RolesLib.AGENT_ADMIN);
        table[6] = RoleAdmin(RolesLib.AGENT_FORCED_TRANSFER, RolesLib.AGENT_ADMIN);
        table[7] = RoleAdmin(RolesLib.AGENT_PAUSER, RolesLib.AGENT_ADMIN);
        table[8] = RoleAdmin(RolesLib.IRS_BINDER, RolesLib.AGENT_ADMIN);
        table[9] = RoleAdmin(RolesLib.TOKEN_MANAGER, RolesLib.SUITE_ADMIN);
        table[10] = RoleAdmin(RolesLib.IDENTITY_MANAGER, RolesLib.SUITE_ADMIN);
    }

    function labelTable() internal pure returns (RoleLabel[] memory table) {
        table = new RoleLabel[](16);
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
        table[14] = RoleLabel(RolesLib.VERSION_MANAGER, "TREX-Suite Manager: Version");
        table[15] = RoleLabel(RolesLib.ASSET_DEPLOYER, "TREX-Suite Asset Deployer");
    }

    function commissionSuite(IAccessManager accessManager, address token) internal {
        commissionSuite(accessManager, token, RolesLib.scopeOf(token));
    }

    function commissionSuite(IAccessManager accessManager, address token, bytes32 scope) internal {
        address registry = _registryOf(token);
        address identityRegistryStorage = _storageOf(registry);
        bytes32 storageScope = RolesLib.scopeOf(identityRegistryStorage);

        accessManager.grantRole(RolesLib.role(scope, RolesLib.AGENT), token, 0);
        accessManager.grantRole(RolesLib.role(storageScope, RolesLib.AGENT), registry, 0);

        setupTokenRoles(accessManager, token, scope);
        setupTREXRegistryRoles(accessManager, registry, scope);
        setupModularComplianceRoles(accessManager, _complianceOf(token), scope);
        setupRoleAdmins(accessManager, scope);
        if (!_isBound(identityRegistryStorage, registry)) {
            IERC3643IdentityRegistryStorage(identityRegistryStorage).bindIdentityRegistry(registry);
        }
        setupIdentityRegistryStorageRoles(accessManager, identityRegistryStorage, storageScope);
        setupRoleAdmins(accessManager, storageScope);
    }

    function migrateSuitesToScopes(
        IAccessManager accessManager,
        address[] memory tokens,
        bytes32[] memory scopes,
        RoleAssignment[] memory assignments,
        SharedRevocation[] memory revocations
    ) internal {
        require(tokens.length == scopes.length, ErrorsLib.ArrayLengthMismatch());
        for (uint256 i = 0; i < assignments.length; i++) {
            _grantFromShared(accessManager, assignments[i].name, assignments[i].scope, assignments[i].account);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            _grantFromShared(accessManager, RolesLib.AGENT, scopes[i], tokens[i]);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            setupTokenRoles(accessManager, tokens[i], scopes[i]);
            setupTREXRegistryRoles(accessManager, _registryOf(tokens[i]), scopes[i]);
            setupModularComplianceRoles(accessManager, _complianceOf(tokens[i]), scopes[i]);
            setupRoleAdmins(accessManager, scopes[i]);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            accessManager.revokeRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT), tokens[i]);
        }
        for (uint256 i = 0; i < revocations.length; i++) {
            if (!_isAdministrative(revocations[i].name)) {
                accessManager.revokeRole(RolesLib.role(RolesLib.SHARED, revocations[i].name), revocations[i].account);
            }
        }
        for (uint256 i = 0; i < revocations.length; i++) {
            if (_isAdministrative(revocations[i].name)) {
                accessManager.revokeRole(RolesLib.role(RolesLib.SHARED, revocations[i].name), revocations[i].account);
            }
        }
    }

    function setupTREXFactoryRoles(IAccessManager accessManager, address trexFactory, bytes32 scope) internal {
        bytes4[] memory functions = new bytes4[](4);
        functions[0] = ITREXFactory.setImplementationAuthority.selector;
        functions[1] = ITREXFactory.setIdFactory.selector;
        functions[2] = ITREXFactory.deployTREXSuite.selector;
        functions[3] = ITREXFactory.deployTREXSuiteIsolated.selector;
        accessManager.setTargetFunctionRole(trexFactory, functions, RolesLib.role(scope, RolesLib.OWNER));
    }

    /// @notice Wires the two prerequisites the {TREXFactory} auto-mint path needs, so a deployer does
    ///         not have to rediscover them. Without both, `deployTREXSuite` reverts with
    ///         `NotAuthorizedForIdentityType` whenever `TokenDetails.ONCHAINID` is left at zero.
    /// @dev Call order does not matter, but both must land before the first auto-mint deploy.
    ///      1. Register the `ASSET` type on the IdentityFactory, gated behind the scoped ASSET_DEPLOYER
    ///         role and with self-deploy off: only a registered factory mints token OIDs, and a token
    ///         must not be able to sign one for itself.
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
    /// @param scope The scope the ASSET_DEPLOYER role is derived in
    function setupIdentityFactoryPolicy(
        IAccessManager accessManager,
        IIdentityFactory identityFactory,
        address trexFactory,
        bytes32 scope
    ) internal {
        uint64 assetDeployer = RolesLib.role(scope, RolesLib.ASSET_DEPLOYER);
        // ASSET is single-binding: a token OID binds to exactly one token and cannot be re-linked.
        identityFactory.setIdentityTypePolicy(IdentityTypes.ASSET, assetDeployer, false, true);
        accessManager.grantRole(assetDeployer, trexFactory, 0);
    }

    function setupTREXImplementationAuthorityRoles(
        IAccessManager accessManager,
        address trexImplementationAuthority,
        bytes32 scope
    ) internal {
        bytes4[] memory functions = new bytes4[](3);
        functions[0] = TREXImplementationAuthority.publish.selector;
        functions[1] = TREXImplementationAuthority.upgrade.selector;
        functions[2] = TREXImplementationAuthority.publishAndUpgrade.selector;
        accessManager.setTargetFunctionRole(
            trexImplementationAuthority, functions, RolesLib.role(scope, RolesLib.VERSION_MANAGER)
        );
    }

    function setupRoleAdmins(IAccessManager accessManager, bytes32 scope) internal {
        RoleAdmin[] memory table = roleAdminTable();
        for (uint256 i = 0; i < table.length; i++) {
            accessManager.setRoleAdmin(RolesLib.role(scope, table[i].name), RolesLib.role(scope, table[i].admin));
        }
    }

    function setupLabels(IAccessManager accessManager, bytes32 scope) internal {
        RoleLabel[] memory table = labelTable();
        for (uint256 i = 0; i < table.length; i++) {
            accessManager.labelRole(RolesLib.role(scope, table[i].name), _label(table[i].label, scope));
        }
    }

    function _grantFromShared(IAccessManager accessManager, bytes32 name, bytes32 scope, address account) private {
        uint64 sharedRole = RolesLib.role(RolesLib.SHARED, name);
        (uint48 since, uint32 executionDelay,, uint48 effect) = accessManager.getAccess(sharedRole, account);
        require(since != 0, ErrorsLib.RoleNotHeld(account, sharedRole));
        require(since <= block.timestamp, ErrorsLib.PendingRoleGrant(account, sharedRole));
        require(effect <= block.timestamp, ErrorsLib.PendingDelayChange(account, sharedRole));
        accessManager.grantRole(RolesLib.role(scope, name), account, executionDelay);
    }

    function _isAdministrative(bytes32 name) private pure returns (bool) {
        return name == RolesLib.AGENT_ADMIN || name == RolesLib.SUITE_ADMIN;
    }

    function _apply(IAccessManager accessManager, address target, SelectorRole[] memory table, bytes32 scope) private {
        for (uint256 i = 0; i < table.length; i++) {
            if (_seenBefore(table, i)) {
                continue;
            }
            bytes32 name = table[i].name;
            accessManager.setTargetFunctionRole(target, _selectorsFor(table, name), RolesLib.role(scope, name));
        }
    }

    function _seenBefore(SelectorRole[] memory table, uint256 index) private pure returns (bool) {
        for (uint256 j = 0; j < index; j++) {
            if (table[j].name == table[index].name) {
                return true;
            }
        }
        return false;
    }

    function _selectorsFor(SelectorRole[] memory table, bytes32 name) private pure returns (bytes4[] memory selectors) {
        uint256 count;
        for (uint256 i = 0; i < table.length; i++) {
            if (table[i].name == name) {
                count++;
            }
        }
        selectors = new bytes4[](count);
        uint256 next;
        for (uint256 i = 0; i < table.length; i++) {
            if (table[i].name == name) {
                selectors[next++] = table[i].selector;
            }
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

    function _isBound(address identityRegistryStorage, address registry) private view returns (bool) {
        address[] memory linked = IERC3643IdentityRegistryStorage(identityRegistryStorage).linkedIdentityRegistries();
        for (uint256 i = 0; i < linked.length; i++) {
            if (linked[i] == registry) {
                return true;
            }
        }
        return false;
    }

    function _label(string memory base, bytes32 scope) private pure returns (string memory) {
        if (scope == RolesLib.SHARED) {
            return base;
        }
        return string.concat(base, " @ ", Strings.toHexString(uint256(scope) >> 96, 8));
    }

}
