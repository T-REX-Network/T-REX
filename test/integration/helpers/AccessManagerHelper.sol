// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

/// @notice Shared AccessManager scaffolding for tests, split the way a deployment is: one manager for
///         the platform (factory, implementation authority, gateway registry, identity factory) and one
///         for the suite (token, registry, storage, compliance). Both are administered by the test
///         contract, so a fixture can still set anything up, but a platform key never opens a suite
///         door or the reverse, which is the guarantee the protocol makes. Wires the selector-to-role
///         mappings through AccessManagerSetupLib and exposes role-granting helpers (all grants use
///         execution delay 0 so vm.prank works).
abstract contract AccessManagerHelper is Test {

    uint32 internal constant NO_EXECUTION_DELAY = 0;
    uint32 internal constant DOMAIN = 1;

    /// @notice The suite's manager: the authority of every token, registry, storage and compliance a
    ///         test deploys, and the one `tokenDetails.accessManager` names.
    AccessManager public suiteManager;

    /// @notice The platform's manager: the authority of the factory, the implementation authority, the
    ///         gateway registry and the identity factory. Platform roles live here and nowhere else.
    AccessManager public platformManager;

    /// @notice Deploys the platform AccessManager with the test contract as admin. Platform roles are
    ///         administered by ADMIN_ROLE directly, so no giver hierarchy is wired.
    function _deployPlatformManager() internal returns (AccessManager) {
        platformManager = new AccessManager(address(this));
        return platformManager;
    }

    /// @notice Deploys the suite AccessManager with the test contract as admin, wires the role-giver
    ///         hierarchy (AGENT_ADMIN over the AGENT family, SUITE_ADMIN over the config roles)
    ///         and labels the roles.
    function _deploySuiteManager() internal returns (AccessManager) {
        suiteManager = new AccessManager(address(this));
        AccessManagerSetupLib.setupRoleAdmins(suiteManager, DOMAIN);
        // Operational roles are now administered by the giver roles, not ADMIN_ROLE(0); the test
        // admin needs the givers to be able to grant AGENT/AGENT_* and TOKEN_MANAGER/IDENTITY_MANAGER.
        _grantAgentAdminRole(address(this));
        _grantSuiteAdminRole(address(this));
        return suiteManager;
    }

    /// @notice The two factory roles the tests pick. The suite deployer role is a named platform role, which is
    ///         how a platform mints one without a release; governance stays on the platform OWNER.
    function _suiteDeployerRole() internal pure returns (uint64) {
        return RolesLib.platform(bytes32("TOKEN_ISSUER"));
    }

    function _factoryGovernorRole() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.OWNER);
    }

    function _versionManagerRole() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.VERSION_MANAGER);
    }

    function _interopManagerRole() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.INTEROP_MANAGER);
    }

    function _assetDeployerRole() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.ASSET_DEPLOYER);
    }

    /// @notice Wires the two deploy selectors to the suite deployer role and the three setters to the
    ///         factory governor role.
    function _setupFactoryRoles(address trexFactory) internal {
        AccessManagerSetupLib.setupTREXFactoryRoles(
            platformManager, trexFactory, _suiteDeployerRole(), _factoryGovernorRole()
        );
    }

    /// @notice Wires the TREXImplementationAuthority version selectors to the version manager role for `ia`.
    function _setupImplementationAuthorityRoles(address ia) internal {
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(platformManager, ia, _versionManagerRole());
    }

    /// @notice Wires the selector-to-role mappings for every contract of a deployed TREX suite.
    /// @dev `registry` is the TREXRegistry, which serves as the suite's IR, CTR and TIR.
    function _setupSuiteRoles(address token, address registry, address irs, address mc) internal {
        AccessManagerSetupLib.setupTokenRoles(suiteManager, token, DOMAIN);
        AccessManagerSetupLib.setupTREXRegistryRoles(suiteManager, registry, DOMAIN);
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(suiteManager, irs, DOMAIN);
        AccessManagerSetupLib.setupModularComplianceRoles(suiteManager, mc, DOMAIN);
    }

    function _role(RolesLib.Role role) internal pure returns (uint64) {
        return RolesLib.forDomain(DOMAIN, role);
    }

    /// @notice Grants the suite OWNER role on the suite manager. Platform powers are a separate grant,
    ///         see {_grantPlatformRoles}: one account holding both is a fixture choice, never a default.
    function _grantOwnerRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.OWNER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants factory governance and suite deployment on the platform manager.
    function _grantPlatformRoles(address account) internal {
        _grantFactoryGovernorRole(account);
        _grantSuiteDeployerRole(account);
    }

    function _grantSuiteDeployerRole(address account) internal {
        platformManager.grantRole(_suiteDeployerRole(), account, NO_EXECUTION_DELAY);
    }

    function _grantFactoryGovernorRole(address account) internal {
        platformManager.grantRole(_factoryGovernorRole(), account, NO_EXECUTION_DELAY);
    }

    function _grantStorageWriterRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.IRS_WRITER), account, NO_EXECUTION_DELAY);
    }

    function _grantAgentRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.AGENT), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants VERSION_MANAGER, which gates publish/upgrade on the TREXImplementationAuthority.
    function _grantVersionManagerRole(address account) internal {
        platformManager.grantRole(_versionManagerRole(), account, NO_EXECUTION_DELAY);
    }

    function _grantInteropManagerRole(address account) internal {
        platformManager.grantRole(_interopManagerRole(), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants VALIDATION_KEEPER, which gates the discard of expired validations on ModularCompliance.
    function _grantValidationKeeperRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.VALIDATION_KEEPER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants COMPLIANCE_MANAGER, which gates the validation policy setters on ModularCompliance.
    function _grantComplianceManagerRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.COMPLIANCE_MANAGER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants IRS_BINDER, which gates IdentityRegistryStorage.bindIdentityRegistry.
    function _grantIRSBinderRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.IRS_BINDER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants ASSET_DEPLOYER, which the ONCHAINID IdentityFactory resolves when minting
    ///         IdentityTypes.ASSET identities (the TREXFactory token-OID auto-mint path).
    function _grantAssetDeployerRole(address account) internal {
        platformManager.grantRole(_assetDeployerRole(), account, NO_EXECUTION_DELAY);
    }

    function _grantAgentAdminRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_ADMIN), account, NO_EXECUTION_DELAY);
    }

    function _grantSuiteAdminRole(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.SUITE_ADMIN), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants AGENT plus every granular AGENT_* role to `account`.
    function _grantAllAgentRoles(address account) internal {
        _grantAgentRole(account);
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_MINTER), account, NO_EXECUTION_DELAY);
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_BURNER), account, NO_EXECUTION_DELAY);
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_PARTIAL_FREEZER), account, NO_EXECUTION_DELAY);
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_ADDRESS_FREEZER), account, NO_EXECUTION_DELAY);
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_RECOVERY_ADDRESS), account, NO_EXECUTION_DELAY);
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_FORCED_TRANSFER), account, NO_EXECUTION_DELAY);
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_PAUSER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants the TOKEN_MANAGER and IDENTITY_MANAGER roles to `account`.
    function _grantManagerRoles(address account) internal {
        suiteManager.grantRole(_role(RolesLib.Role.TOKEN_MANAGER), account, NO_EXECUTION_DELAY);
        suiteManager.grantRole(_role(RolesLib.Role.IDENTITY_MANAGER), account, NO_EXECUTION_DELAY);
        _grantComplianceManagerRole(account);
    }

    /// @notice Returns true when `account` holds the AGENT role on the manager.
    function _hasAgentRole(address account) internal view returns (bool) {
        (bool isMember,) = suiteManager.hasRole(_role(RolesLib.Role.AGENT), account);
        return isMember;
    }

}
