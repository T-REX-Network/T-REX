// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

/// @notice Shared AccessManager scaffolding for tests: deploys a manager administered by the test
///         contract, wires the TREX suite selector-to-role mappings through AccessManagerSetupLib
///         and exposes role-granting helpers (all grants use execution delay 0 so vm.prank works).
abstract contract AccessManagerHelper is Test {

    uint32 internal constant NO_EXECUTION_DELAY = 0;
    uint32 internal constant NS = 1;

    AccessManager public accessManager;

    /// @notice Deploys the AccessManager with the test contract as admin, wires the role-giver
    ///         hierarchy (AGENT_ADMIN over the AGENT family, SUITE_ADMIN over the config roles)
    ///         and labels the roles.
    function _deployAccessManager() internal returns (AccessManager) {
        accessManager = new AccessManager(address(this));
        AccessManagerSetupLib.setupRoleAdmins(accessManager, NS);
        // Operational roles are now administered by the giver roles, not ADMIN_ROLE(0); the test
        // admin needs the givers to be able to grant AGENT/AGENT_* and TOKEN_MANAGER/IDENTITY_MANAGER.
        _grantAgentAdminRole(address(this));
        _grantSuiteAdminRole(address(this));
        return accessManager;
    }

    /// @notice Wires the factory selectors (deployTREXSuite, setters) to the OWNER role.
    function _setupFactoryRoles(address trexFactory) internal {
        AccessManagerSetupLib.setupTREXFactoryRoles(accessManager, trexFactory);
    }

    /// @notice Wires the TREXImplementationAuthority governance selectors to the OWNER role for `ia`.
    function _authorizeIAGovernance(address ia) internal {
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, ia);
    }

    /// @notice Wires the selector-to-role mappings for every contract of a deployed TREX suite.
    /// @dev `registry` is the TREXRegistry, which serves as the suite's IR, CTR and TIR.
    function _setupSuiteRoles(address token, address registry, address irs, address mc) internal {
        AccessManagerSetupLib.setupTokenRoles(accessManager, token, NS);
        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, registry, NS);
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, irs, NS);
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, mc, NS);
    }

    function _role(RolesLib.Role role) internal pure returns (uint64) {
        return RolesLib.forNamespace(NS, role);
    }

    function _grantOwnerRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.OWNER), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.platform(RolesLib.PlatformRole.OWNER), account, NO_EXECUTION_DELAY);
    }

    function _grantStorageWriterRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.IRS_WRITER), account, NO_EXECUTION_DELAY);
    }

    function _grantAgentRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.AGENT), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants VERSION_MANAGER, which gates publish/upgrade on the TREXImplementationAuthority.
    function _grantVersionManagerRole(address account) internal {
        accessManager.grantRole(RolesLib.platform(RolesLib.PlatformRole.VERSION_MANAGER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants IRS_BINDER, which gates IdentityRegistryStorage.bindIdentityRegistry.
    function _grantIRSBinderRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.IRS_BINDER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants ASSET_DEPLOYER, which the ONCHAINID IdentityFactory resolves when minting
    ///         IdentityTypes.ASSET identities (the TREXFactory token-OID auto-mint path).
    function _grantTokenOidMinterRole(address account) internal {
        accessManager.grantRole(RolesLib.platform(RolesLib.PlatformRole.ASSET_DEPLOYER), account, NO_EXECUTION_DELAY);
    }

    function _grantAgentAdminRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.AGENT_ADMIN), account, NO_EXECUTION_DELAY);
    }

    function _grantSuiteAdminRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.SUITE_ADMIN), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants AGENT plus every granular AGENT_* role to `account`.
    function _grantAllAgentRoles(address account) internal {
        _grantAgentRole(account);
        accessManager.grantRole(_role(RolesLib.Role.AGENT_MINTER), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(_role(RolesLib.Role.AGENT_BURNER), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(_role(RolesLib.Role.AGENT_PARTIAL_FREEZER), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(_role(RolesLib.Role.AGENT_ADDRESS_FREEZER), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(_role(RolesLib.Role.AGENT_RECOVERY_ADDRESS), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(_role(RolesLib.Role.AGENT_FORCED_TRANSFER), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(_role(RolesLib.Role.AGENT_PAUSER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants the TOKEN_MANAGER and IDENTITY_MANAGER roles to `account`.
    function _grantManagerRoles(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.TOKEN_MANAGER), account, NO_EXECUTION_DELAY);
        accessManager.grantRole(_role(RolesLib.Role.IDENTITY_MANAGER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Returns true when `account` holds the AGENT role on the manager.
    function _hasAgentRole(address account) internal view returns (bool) {
        (bool isMember,) = accessManager.hasRole(_role(RolesLib.Role.AGENT), account);
        return isMember;
    }

}
