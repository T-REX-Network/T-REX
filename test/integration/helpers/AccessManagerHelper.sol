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

    AccessManager public accessManager;

    /// @notice Deploys the AccessManager with the test contract as admin, makes AGENT_MANAGER the
    ///         admin role of AGENT and labels the roles.
    function _deployAccessManager() internal returns (AccessManager) {
        accessManager = new AccessManager(address(this));
        AccessManagerSetupLib.setupAgentManagerRole(accessManager);
        AccessManagerSetupLib.setupLabels(accessManager);
        // AGENT is administered by AGENT_MANAGER; the test admin needs it to grant AGENT
        _grantAgentManagerRole(address(this));
        return accessManager;
    }

    /// @notice Wires the factory selectors (deployTREXSuite, setters) to the OWNER role.
    function _setupFactoryRoles(address trexFactory) internal {
        AccessManagerSetupLib.setupTREXFactoryRoles(accessManager, trexFactory);
    }

    /// @notice Wires the selector-to-role mappings for every contract of a deployed TREX suite.
    function _setupSuiteRoles(address token, address ir, address irs, address ctr, address tir, address mc) internal {
        AccessManagerSetupLib.setupTokenRoles(accessManager, token);
        AccessManagerSetupLib.setupIdentityRegistryRoles(accessManager, ir);
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, irs);
        AccessManagerSetupLib.setupClaimTopicsRegistryRoles(accessManager, ctr);
        AccessManagerSetupLib.setupTrustedIssuersRegistryRoles(accessManager, tir);
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, mc);
    }

    function _grantOwnerRole(address account) internal {
        accessManager.grantRole(RolesLib.OWNER, account, NO_EXECUTION_DELAY);
    }

    function _grantAgentRole(address account) internal {
        accessManager.grantRole(RolesLib.AGENT, account, NO_EXECUTION_DELAY);
    }

    function _grantAgentManagerRole(address account) internal {
        accessManager.grantRole(RolesLib.AGENT_MANAGER, account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants AGENT plus every granular AGENT_* role to `account`.
    function _grantAllAgentRoles(address account) internal {
        _grantAgentRole(account);
        accessManager.grantRole(RolesLib.AGENT_MINTER, account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.AGENT_BURNER, account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.AGENT_PARTIAL_FREEZER, account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.AGENT_ADDRESS_FREEZER, account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.AGENT_RECOVERY_ADDRESS, account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.AGENT_FORCED_TRANSFER, account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.AGENT_PAUSER, account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants the TOKEN_ADMIN and IDENTITY_ADMIN roles to `account`.
    function _grantAdminRoles(address account) internal {
        accessManager.grantRole(RolesLib.TOKEN_ADMIN, account, NO_EXECUTION_DELAY);
        accessManager.grantRole(RolesLib.IDENTITY_ADMIN, account, NO_EXECUTION_DELAY);
    }

    /// @notice Returns true when `account` holds the AGENT role on the manager.
    function _hasAgentRole(address account) internal view returns (bool) {
        (bool isMember,) = accessManager.hasRole(RolesLib.AGENT, account);
        return isMember;
    }

}
