// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IIdentityRegistryStorage } from "contracts/registry/interface/IIdentityRegistryStorage.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice Commissioning records the full suite without changing its selector permissions or sharing rules.
contract SuiteDomainMetadataTest is TREXSuiteTest {

    TREXAccessManager private domainManager;
    Token private domainToken;
    uint32 private domainId;

    function setUp() public override {
        super.setUp();
        domainManager = TREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TREXAccessManager()),
                    abi.encodeCall(AccessManagerUpgradeable.initialize, (address(this)))
                )
            )
        );
        domainToken = _deployBare("metadata", address(0), address(domainManager));
        domainId = domainManager.createDomain("Metadata fund");
        domainManager.assign(domainId, address(domainToken));
    }

    function test_commissionSuite_RecordsEveryComponentAndEmitsAssignments() public {
        address registry = address(domainToken.identityRegistry());
        address identityStorage = address(domainToken.identityRegistry().identityStorage());
        address compliance = address(domainToken.compliance());

        vm.recordLogs();
        AccessManagerSetupLib.commissionSuite(domainManager, address(domainToken));

        _assertDomainRecords(domainToken);
        address[] memory assignedComponents = new address[](3);
        assignedComponents[0] = identityStorage;
        assignedComponents[1] = registry;
        assignedComponents[2] = compliance;
        _assertAssignmentLogs(vm.getRecordedLogs(), assignedComponents);
    }

    function test_commissionSuite_AcceptsMatchingRecordsWithoutRepeatingAssignments() public {
        domainManager.assign(domainId, address(domainToken.identityRegistry().identityStorage()));
        domainManager.assign(domainId, address(domainToken.identityRegistry()));
        domainManager.assign(domainId, address(domainToken.compliance()));
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN), address(this), 0);

        vm.recordLogs();
        AccessManagerSetupLib.commissionSuite(domainManager, address(domainToken));
        AccessManagerSetupLib.commissionSuite(domainManager, address(domainToken));

        _assertDomainRecords(domainToken);
        assertEq(_assignmentCount(vm.getRecordedLogs()), 0, "matching records must not be reassigned");
    }

    function test_commissionSuite_AllowsTwoTokensToShareARegistryInTheSameDomain() public {
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        AccessManagerSetupLib.commissionSuite(domainManager, address(domainToken));
        bytes32 originalPermissions = _permissionHash(domainManager, domainToken);
        Token sibling = _deployBare("metadata-shared-registry", address(0), address(domainManager));
        domainManager.assign(domainId, address(sibling));
        sibling.setIdentityRegistry(address(domainToken.identityRegistry()));

        vm.recordLogs();
        AccessManagerSetupLib.commissionSuite(domainManager, address(sibling));

        _assertDomainRecords(domainToken);
        _assertDomainRecords(sibling);
        assertEq(_assignmentCount(vm.getRecordedLogs()), 1, "only the sibling's compliance is unassigned");
        assertEq(
            _permissionHash(domainManager, domainToken),
            originalPermissions,
            "shared registry permissions must stay put"
        );
    }

    function test_commissionSuite_AllowsDistinctRegistriesToShareStorageInTheSameDomain() public {
        AccessManagerSetupLib.commissionSuite(domainManager, address(domainToken));
        address identityStorage = address(domainToken.identityRegistry().identityStorage());
        Token sibling = _deployBare("metadata-shared-storage", identityStorage, address(domainManager));
        domainManager.assign(domainId, address(sibling));
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.IRS_BINDER), address(this), 0);

        vm.recordLogs();
        AccessManagerSetupLib.commissionSuite(domainManager, address(sibling));

        _assertDomainRecords(domainToken);
        _assertDomainRecords(sibling);
        assertEq(_assignmentCount(vm.getRecordedLogs()), 2, "the shared storage must not be reassigned");
        assertTrue(
            IIdentityRegistryStorage(identityStorage).isIdentityRegistryBound(address(sibling.identityRegistry())),
            "the sibling registry must be bound to the shared storage"
        );
    }

    function test_commissionSuite_RevertsWithoutPartialWritesWhenRegistryRecordConflicts() public {
        address registry = address(domainToken.identityRegistry());
        uint32 otherDomainId = domainManager.createDomain("Other fund");
        domainManager.assign(otherDomainId, registry);
        _assertCommissionRejected(registry, otherDomainId);
    }

    function test_commissionSuite_RevertsWithoutPartialWritesWhenStorageRecordConflicts() public {
        address identityStorage = address(domainToken.identityRegistry().identityStorage());
        uint32 otherDomainId = domainManager.createDomain("Other fund");
        domainManager.assign(otherDomainId, identityStorage);
        _assertCommissionRejected(identityStorage, otherDomainId);
    }

    function test_commissionSuite_RevertsWithoutPartialWritesWhenComplianceRecordConflicts() public {
        address compliance = address(domainToken.compliance());
        uint32 otherDomainId = domainManager.createDomain("Other fund");
        domainManager.assign(otherDomainId, compliance);
        _assertCommissionRejected(compliance, otherDomainId);
    }

    function test_commissionSuite_PreservesAssignAuthorizationForNewMetadata() public {
        domainManager.assign(domainId, address(domainToken.identityRegistry().identityStorage()));
        uint64 metadataWriter = RolesLib.forDomain(domainId, bytes32("METADATA_WRITER"));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TREXAccessManager.assign.selector;
        domainManager.setTargetFunctionRole(address(domainManager), selectors, metadataWriter);

        _assertCommissionReverts(
            domainToken,
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, address(this), metadataWriter
            )
        );

        // The same caller can commission through the plain manager path, which makes no metadata writes.
        AccessManagerSetupLib.commissionSuite(IAccessManager(address(domainManager)), address(domainToken), domainId);
        (bool tokenIsAgent,) =
            domainManager.hasRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT), address(domainToken));
        assertTrue(tokenIsAgent, "the rejected caller was otherwise authorized to commission the suite");
        assertEq(
            domainManager.domainOf(address(domainToken.identityRegistry())),
            0,
            "plain setup records no registry metadata"
        );
        assertEq(
            domainManager.domainOf(address(domainToken.compliance())), 0, "plain setup records no compliance metadata"
        );
    }

    function test_commissionSuite_RollsBackMetadataAndGrantsWhenSharedStorageBindingFails() public {
        AccessManagerSetupLib.commissionSuite(domainManager, address(domainToken));
        address identityStorage = address(domainToken.identityRegistry().identityStorage());
        Token sibling = _deployBare("metadata-denied-binding", identityStorage, address(domainManager));
        address siblingRegistry = address(sibling.identityRegistry());
        domainManager.assign(domainId, address(sibling));
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        (bool callerIsBinder,) =
            domainManager.hasRole(RolesLib.forDomain(domainId, RolesLib.Role.IRS_BINDER), address(this));
        assertFalse(callerIsBinder, "the commissioner intentionally lacks the storage's binder role");
        assertFalse(
            IIdentityRegistryStorage(identityStorage).isIdentityRegistryBound(siblingRegistry),
            "the sibling registry still needs binding"
        );
        vm.expectCall(
            address(domainManager),
            abi.encodeCall(
                IAccessManager.grantRole, (RolesLib.forDomain(domainId, RolesLib.Role.AGENT), address(sibling), 0)
            )
        );
        vm.expectCall(
            address(domainManager),
            abi.encodeCall(
                IAccessManager.grantRole, (RolesLib.forDomain(domainId, RolesLib.Role.IRS_WRITER), siblingRegistry, 0)
            )
        );
        vm.expectCall(
            identityStorage, abi.encodeCall(IERC3643IdentityRegistryStorage.bindIdentityRegistry, (siblingRegistry))
        );

        _assertCommissionReverts(
            sibling, abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this))
        );
    }

    function test_commissionSuite_RollsBackMetadataWhenStorageSelectorBelongsToAnotherDomain() public {
        _assertSelectorConflict(
            address(domainToken.identityRegistry().identityStorage()),
            IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
        );
    }

    function test_commissionSuite_RollsBackMetadataWhenRegistrySelectorBelongsToAnotherDomain() public {
        _assertSelectorConflict(
            address(domainToken.identityRegistry()), IERC3643IdentityRegistry.registerIdentity.selector
        );
    }

    function test_commissionSuite_RollsBackMetadataWhenComplianceSelectorBelongsToAnotherDomain() public {
        _assertSelectorConflict(address(domainToken.compliance()), IModularCompliance.addModule.selector);
    }

    function test_commissionSuite_MatchesPlainManagerPermissionsAndKeepsTokenOperationsWorking() public {
        AccessManager plainManager = new AccessManager(address(this));
        Token plainToken = _deployBare("metadata-plain-manager", address(0), address(plainManager));

        AccessManagerSetupLib.commissionSuite(domainManager, address(domainToken));
        AccessManagerSetupLib.commissionSuite(IAccessManager(address(plainManager)), address(plainToken), domainId);

        assertEq(
            _permissionHash(domainManager, domainToken),
            _permissionHash(IAccessManager(address(plainManager)), plainToken),
            "metadata recording must preserve all selector roles, role admins and contract grants"
        );
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        domainToken.mint(alice, 100);

        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT), agent, 0);
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_MINTER), agent, 0);
        domainManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_PAUSER), agent, 0);
        vm.startPrank(agent);
        domainToken.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        domainToken.identityRegistry().registerIdentity(bob, bobIdentity, 0);
        domainToken.mint(alice, 100);
        domainToken.unpause();
        vm.stopPrank();
        vm.prank(alice);
        domainToken.transfer(bob, 25);

        assertEq(domainToken.balanceOf(alice), 75, "the sender keeps the untransferred balance");
        assertEq(domainToken.balanceOf(bob), 25, "the recipient receives the transfer");
        assertEq(domainToken.totalSupply(), 100, "metadata must not affect supply");
    }

    function test_metadataBackfill_PreservesCustomizedSelectorPermissions() public {
        AccessManagerSetupLib.commissionSuite(IAccessManager(address(domainManager)), address(domainToken), domainId);
        uint64 customRole = RolesLib.forDomain(domainId, bytes32("CUSTOM_REGISTRATION"));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC3643IdentityRegistry.registerIdentity.selector;
        domainManager.setTargetFunctionRole(address(domainToken.identityRegistry()), selectors, customRole);
        domainManager.grantRole(customRole, agent, 2 hours);
        bytes32 originalPermissions = _permissionHash(domainManager, domainToken);

        // Backfill records directly: recommissioning would restore the standard selector tables.
        domainManager.assign(domainId, address(domainToken.identityRegistry().identityStorage()));
        domainManager.assign(domainId, address(domainToken.identityRegistry()));
        domainManager.assign(domainId, address(domainToken.compliance()));

        _assertDomainRecords(domainToken);
        assertEq(
            _permissionHash(domainManager, domainToken), originalPermissions, "backfill must leave permissions alone"
        );
        (bool holdsRole, uint32 executionDelay) = domainManager.hasRole(customRole, agent);
        assertTrue(holdsRole, "the custom role grant must survive backfill");
        assertEq(executionDelay, 2 hours, "the custom execution delay must survive backfill");
    }

    /// @dev Gives expectRevert an external boundary around the internal commissioning library call.
    function commissionExternally(address suiteToken) external {
        AccessManagerSetupLib.commissionSuite(domainManager, suiteToken);
    }

    function _assertSelectorConflict(address target, bytes4 selector) private {
        uint32 otherDomainId = domainManager.createDomain("Other fund");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        domainManager.setTargetFunctionRole(target, selectors, RolesLib.forDomain(otherDomainId, RolesLib.Role.OWNER));
        _assertCommissionRejected(target, otherDomainId);
    }

    function _assertCommissionRejected(address target, uint32 otherDomainId) private {
        _assertCommissionReverts(
            domainToken, abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, target, otherDomainId)
        );
    }

    function _assertCommissionReverts(Token suiteToken, bytes memory expectedError) private {
        bytes32 originalMetadata = _metadataHash(suiteToken);
        bytes32 originalPermissions = _permissionHash(domainManager, suiteToken);

        vm.expectRevert(expectedError);
        this.commissionExternally(address(suiteToken));

        assertEq(_metadataHash(suiteToken), originalMetadata, "a rejected suite must leave no partial metadata");
        assertEq(
            _permissionHash(domainManager, suiteToken),
            originalPermissions,
            "a rejected suite must preserve permissions"
        );
    }

    function _assertDomainRecords(Token suiteToken) private view {
        assertEq(domainManager.domainOf(address(suiteToken)), domainId, "the token must record its domain");
        assertEq(
            domainManager.domainOf(address(suiteToken.identityRegistry())),
            domainId,
            "the registry must record its domain"
        );
        assertEq(
            domainManager.domainOf(address(suiteToken.identityRegistry().identityStorage())),
            domainId,
            "the storage must record its domain"
        );
        assertEq(
            domainManager.domainOf(address(suiteToken.compliance())), domainId, "the compliance must record its domain"
        );
    }

    function _metadataHash(Token suiteToken) private view returns (bytes32) {
        address registry = address(suiteToken.identityRegistry());
        address identityStorage = address(suiteToken.identityRegistry().identityStorage());
        return keccak256(
            abi.encode(
                domainManager.domainOf(address(suiteToken)),
                domainManager.domainOf(registry),
                domainManager.domainOf(identityStorage),
                domainManager.domainOf(address(suiteToken.compliance())),
                IIdentityRegistryStorage(identityStorage).isIdentityRegistryBound(registry)
            )
        );
    }

    function _permissionHash(IAccessManager manager, Token suiteToken) private view returns (bytes32) {
        address registry = address(suiteToken.identityRegistry());
        bytes32 selectorHash = keccak256(
            abi.encode(
                _functionRoles(manager, address(suiteToken), AccessManagerSetupLib.tokenTable()),
                _functionRoles(manager, registry, AccessManagerSetupLib.registryTable()),
                _functionRoles(
                    manager,
                    address(suiteToken.identityRegistry().identityStorage()),
                    AccessManagerSetupLib.storageTable()
                ),
                _functionRoles(manager, address(suiteToken.compliance()), AccessManagerSetupLib.complianceTable())
            )
        );
        bytes memory roleConfiguration;
        for (uint8 roleIndex = 0; roleIndex <= uint8(type(RolesLib.Role).max); roleIndex++) {
            uint64 role = RolesLib.forDomain(domainId, RolesLib.Role(roleIndex));
            (bool tokenHoldsRole, uint32 tokenDelay) = manager.hasRole(role, address(suiteToken));
            (bool registryHoldsRole, uint32 registryDelay) = manager.hasRole(role, registry);
            roleConfiguration = abi.encode(
                roleConfiguration,
                manager.getRoleAdmin(role),
                tokenHoldsRole,
                tokenDelay,
                registryHoldsRole,
                registryDelay
            );
        }
        return keccak256(abi.encode(selectorHash, roleConfiguration));
    }

    function _functionRoles(IAccessManager manager, address target, AccessManagerSetupLib.SelectorRole[] memory table)
        private
        view
        returns (uint64[] memory roles)
    {
        roles = new uint64[](table.length);
        for (uint256 i = 0; i < table.length; i++) {
            roles[i] = manager.getTargetFunctionRole(target, table[i].selector);
        }
    }

    function _assignmentCount(Vm.Log[] memory logs) private view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(domainManager) && logs[i].topics[0] == EventsLib.DomainAssigned.selector) {
                count++;
            }
        }
    }

    /// @dev The internal library makes several external calls; verify the complete transaction's logs together.
    function _assertAssignmentLogs(Vm.Log[] memory logs, address[] memory assignedComponents) private view {
        uint256 assignmentIndex;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(domainManager) || logs[i].topics[0] != EventsLib.DomainAssigned.selector) {
                continue;
            }
            assertLt(assignmentIndex, assignedComponents.length, "no extra assignment may be emitted");
            assertEq(logs[i].topics.length, 3, "assignment must have the standard topic layout");
            assertEq(logs[i].topics[1], bytes32(uint256(domainId)), "assignment must name the suite domain");
            assertEq(
                logs[i].topics[2],
                bytes32(uint256(uint160(assignedComponents[assignmentIndex]))),
                "assignment must name the expected component"
            );
            assertEq(logs[i].data, bytes(""), "assignment has no non-indexed data");
            assignmentIndex++;
        }
        assertEq(assignmentIndex, assignedComponents.length, "each new component must be assigned once");
    }

    function _deployBare(string memory salt, address identityStorage, address manager) private returns (Token) {
        ITREXFactory.TokenDetails memory details = ITREXFactory.TokenDetails({
            name: salt,
            symbol: "META",
            decimals: 0,
            irs: identityStorage,
            ONCHAINID: address(0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: manager,
            accessManagerAdmin: address(0)
        });
        ITREXFactory.ClaimDetails memory claims = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
        _deploySuite(salt, details, claims);
        return Token(trexFactory.getToken(salt));
    }

}
