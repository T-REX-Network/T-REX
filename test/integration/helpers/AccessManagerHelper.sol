// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { TestTREXAccessManager } from "test/integration/mocks/TestTREXAccessManager.sol";

/// @notice Shared AccessManager scaffolding for tests: deploys a `TREXAccessManager` administered by the
///         test contract with one domain, sets suites or single suite contracts up in that domain,
///         and exposes role-granting helpers (all grants use execution delay 0 so vm.prank works).
abstract contract AccessManagerHelper is Test {

    uint32 internal constant NO_EXECUTION_DELAY = 0;
    /// @dev The first domain a fresh manager creates, where every suite of the fixture is set up.
    uint32 internal constant DOMAIN = 1;

    /// @dev The real manager plus one test-only entry point, {TestTREXAccessManager.setupSuiteContracts}, used by
    ///      the single-contract helpers below.
    TestTREXAccessManager public accessManager;

    /// @dev Placeholders for the suite contracts a single-contract unit test does not deploy. Setting a suite
    ///      up reads nothing from the addresses it is given, so mapping roles onto placeholders is inert.
    address internal unusedToken = makeAddr("unused token");
    address internal unusedRegistry = makeAddr("unused registry");
    address internal unusedIdentityStorage = makeAddr("unused identity storage");
    address internal unusedCompliance = makeAddr("unused compliance");

    /// @notice Deploys the manager with the test contract as admin, creates the fixture's domain, and makes
    ///         the test contract a giver of both role families so it can grant AGENT/AGENT_* and the manager
    ///         roles once a suite is set up.
    function _deployAccessManager() internal returns (TREXAccessManager) {
        accessManager = TestTREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TestTREXAccessManager()),
                    abi.encodeCall(AccessManagerUpgradeable.initialize, (address(this)))
                )
            )
        );
        accessManager.createDomain("test suite");
        _grantAgentAdminRole(address(this));
        _grantSuiteAdminRole(address(this));
        return accessManager;
    }

    /// @notice Deploys a `TREXAccessManager` behind an ERC-1967 proxy with `admin` as its only admin and no
    ///         domain yet, the shape an issuer gets when they run a manager themselves.
    function _newTREXAccessManager(address admin) internal returns (TREXAccessManager) {
        return TREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TREXAccessManager()), abi.encodeCall(AccessManagerUpgradeable.initialize, (admin))
                )
            )
        );
    }

    /// @notice Sets up the suite of a deployed `token` in the fixture's domain, through the production
    ///         `setupSuite`, which reads the registry, storage and compliance from the token.
    function _setupSuiteRoles(address token) internal {
        accessManager.setupSuite(DOMAIN, token);
    }

    function _setupTokenRoles(address token) internal {
        accessManager.setupSuiteContracts(DOMAIN, token, unusedRegistry, unusedIdentityStorage, unusedCompliance);
    }

    function _setupRegistryRoles(address registry) internal {
        accessManager.setupSuiteContracts(DOMAIN, unusedToken, registry, unusedIdentityStorage, unusedCompliance);
    }

    function _setupStorageRoles(address identityStorage) internal {
        accessManager.setupSuiteContracts(DOMAIN, unusedToken, unusedRegistry, identityStorage, unusedCompliance);
    }

    function _setupComplianceRoles(address compliance) internal {
        accessManager.setupSuiteContracts(DOMAIN, unusedToken, unusedRegistry, unusedIdentityStorage, compliance);
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
            accessManager, trexFactory, _suiteDeployerRole(), _factoryGovernorRole()
        );
    }

    /// @notice Wires the TREXImplementationAuthority version selectors to the version manager role for `ia`.
    function _setupImplementationAuthorityRoles(address ia) internal {
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, ia, _versionManagerRole());
    }

    function _role(RolesLib.Role role) internal pure returns (uint64) {
        return RolesLib.forDomain(DOMAIN, role);
    }

    /// @notice Full-powers test account: suite OWNER, factory governance and suite deployment.
    function _grantOwnerRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.OWNER), account, NO_EXECUTION_DELAY);
        _grantFactoryGovernorRole(account);
        _grantSuiteDeployerRole(account);
    }

    function _grantSuiteDeployerRole(address account) internal {
        accessManager.grantRole(_suiteDeployerRole(), account, NO_EXECUTION_DELAY);
    }

    function _grantFactoryGovernorRole(address account) internal {
        accessManager.grantRole(_factoryGovernorRole(), account, NO_EXECUTION_DELAY);
    }

    function _grantStorageWriterRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.IRS_WRITER), account, NO_EXECUTION_DELAY);
    }

    function _grantAgentRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.AGENT), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants VERSION_MANAGER, which gates publish/upgrade on the TREXImplementationAuthority.
    function _grantVersionManagerRole(address account) internal {
        accessManager.grantRole(_versionManagerRole(), account, NO_EXECUTION_DELAY);
    }

    function _grantInteropManagerRole(address account) internal {
        accessManager.grantRole(_interopManagerRole(), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants VALIDATION_KEEPER, which gates the discard of expired validations on ModularCompliance.
    function _grantValidationKeeperRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.VALIDATION_KEEPER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants COMPLIANCE_MANAGER, which gates the validation policy setters on ModularCompliance.
    function _grantComplianceManagerRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.COMPLIANCE_MANAGER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants IRS_BINDER, which gates IdentityRegistryStorage.bindIdentityRegistry.
    function _grantIRSBinderRole(address account) internal {
        accessManager.grantRole(_role(RolesLib.Role.IRS_BINDER), account, NO_EXECUTION_DELAY);
    }

    /// @notice Grants ASSET_DEPLOYER, which the ONCHAINID IdentityFactory resolves when minting
    ///         IdentityTypes.ASSET identities (the TREXFactory token-OID auto-mint path).
    function _grantAssetDeployerRole(address account) internal {
        accessManager.grantRole(_assetDeployerRole(), account, NO_EXECUTION_DELAY);
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
        _grantComplianceManagerRole(account);
    }

    /// @notice Returns true when `account` holds the AGENT role on the manager.
    function _hasAgentRole(address account) internal view returns (bool) {
        (bool isMember,) = accessManager.hasRole(_role(RolesLib.Role.AGENT), account);
        return isMember;
    }

}
