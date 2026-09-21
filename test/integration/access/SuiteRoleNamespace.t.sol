// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { KeyManager } from "@onchain-id/solidity/contracts/KeyManager.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { ITREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract SuiteRoleNamespaceTest is TREXSuiteTest {

    uint64 internal constant FOREIGN_ROLE = 4242;
    uint64 internal constant OTHER_FOREIGN_ROLE = 4343;
    Token internal tokenA;
    Token internal tokenB;
    address internal agentA = makeAddr("agentA");
    address internal agentB = makeAddr("agentB");

    function setUp() public override {
        super.setUp();
        tokenA = _deployBare("ns-a", address(0));
        tokenB = _deployBare("ns-b", address(0));
    }

    function test_forSuite_ReturnsTheRoleUnchangedForTheSharedNamespace() public pure {
        assertEq(RolesLib.forSuite(RolesLib.AGENT_MINTER, RolesLib.SHARED), RolesLib.AGENT_MINTER);
        assertEq(RolesLib.forSuite(RolesLib.OWNER, RolesLib.SHARED), RolesLib.OWNER);
    }

    function testFuzz_forSuite_NeverLandsOnAReservedId(uint64 role, bytes32 namespace) public pure {
        vm.assume(namespace != RolesLib.SHARED);
        uint64 id = RolesLib.forSuite(role, namespace);
        assertNotEq(id, 0);
        assertNotEq(id, type(uint64).max);
        assertNotEq(id >> 16, RolesLib.ROLE_PREFIX >> 16);
    }

    function testFuzz_forSuite_IsDeterministicAndDistinctAcrossNamespaces(uint64 role, bytes32 first, bytes32 second)
        public
        pure
    {
        vm.assume(first != RolesLib.SHARED && second != RolesLib.SHARED && first != second);
        assertEq(RolesLib.forSuite(role, first), RolesLib.forSuite(role, first));
        assertNotEq(RolesLib.forSuite(role, first), RolesLib.forSuite(role, second));
    }

    function test_forSuite_DerivesDistinctIdsPerRoleAndNamespace() public view {
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 nsB = RolesLib.namespaceOf(address(tokenB));
        assertNotEq(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), RolesLib.AGENT_MINTER);
        assertNotEq(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), RolesLib.forSuite(RolesLib.AGENT_MINTER, nsB));
        assertNotEq(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), RolesLib.forSuite(RolesLib.AGENT_BURNER, nsA));
        assertEq(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA));
        assertNotEq(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), 0);
        assertNotEq(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), type(uint64).max);
    }

    function test_perSuiteNamespace_AgentOfAOperatesAOnly() public {
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));
        _commission(tokenB, RolesLib.namespaceOf(address(tokenB)));
        _grantAllAgentRoles(agentA, RolesLib.namespaceOf(address(tokenA)));

        vm.startPrank(agentA);
        tokenA.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        tokenA.identityRegistry().registerIdentity(bob, bobIdentity, 0);
        tokenA.unpause();
        tokenA.mint(alice, 100);
        tokenA.burn(alice, 10);
        tokenA.freezePartialTokens(alice, 10);
        tokenA.unfreezePartialTokens(alice, 10);
        tokenA.setAddressFrozen(alice, true);
        tokenA.setAddressFrozen(alice, false);
        tokenA.forcedTransfer(alice, bob, 20);
        vm.stopPrank();
        _allowRecoveryTo(aliceIdentity, another);
        vm.startPrank(agentA);
        tokenA.recoveryAddress(alice, another, address(aliceIdentity));
        tokenA.pause();
        vm.stopPrank();
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(tokenA.balanceOf(another), 70);
        assertEq(tokenA.balanceOf(bob), 20);

        _assertLockedOut(agentA, tokenB);
    }

    function test_perSuiteNamespace_AgentOfBOperatesBOnly() public {
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));
        _commission(tokenB, RolesLib.namespaceOf(address(tokenB)));
        _grantAllAgentRoles(agentB, RolesLib.namespaceOf(address(tokenB)));

        vm.startPrank(agentB);
        tokenB.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        tokenB.unpause();
        tokenB.mint(alice, 5);
        vm.stopPrank();
        assertEq(tokenB.balanceOf(alice), 5);

        _assertLockedOut(agentB, tokenA);
    }

    function test_sharedNamespace_AgentOfAOperatesBWhenOptedIn() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);

        IERC3643IdentityRegistry registryB = tokenB.identityRegistry();
        vm.startPrank(agentA);
        registryB.registerIdentity(alice, aliceIdentity, 0);
        registryB.registerIdentity(bob, bobIdentity, 0);
        tokenB.unpause();
        tokenB.mint(alice, 100);
        tokenB.burn(alice, 10);
        tokenB.freezePartialTokens(alice, 10);
        tokenB.unfreezePartialTokens(alice, 10);
        tokenB.setAddressFrozen(alice, true);
        tokenB.setAddressFrozen(alice, false);
        tokenB.forcedTransfer(alice, bob, 20);
        vm.stopPrank();
        _allowRecoveryTo(aliceIdentity, another);
        vm.startPrank(agentA);
        tokenB.recoveryAddress(alice, another, address(aliceIdentity));
        tokenB.pause();
        vm.stopPrank();
        assertEq(tokenB.balanceOf(another), 70);
        assertEq(tokenB.balanceOf(bob), 20);
    }

    function test_mixedModes_SharedSuiteJoiningAStorageUsesTheStorageNamespace() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("mixed-c", address(irs));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_ADMIN, storageNamespace), address(this), 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), address(this), 0);
        _commission(tokenC, RolesLib.SHARED);

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forSuite(RolesLib.AGENT, storageNamespace)
        );
        _assertBothRegistriesWrite(tokenA, RolesLib.namespaceOf(address(tokenA)), tokenC, RolesLib.SHARED, irs);
        _assertLockedOut(agentA, tokenC);
        _assertLockedOut(agentB, tokenA);
    }

    function test_mixedModes_PerSuiteSuiteJoiningASharedModeStorageUsesTheStorageNamespace() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("mixed-c", address(irs));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        _commission(tokenA, RolesLib.SHARED);
        _grantStorageAdmin(irs);
        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forSuite(RolesLib.AGENT, storageNamespace)
        );
        _assertBothRegistriesWrite(tokenA, RolesLib.SHARED, tokenC, RolesLib.namespaceOf(address(tokenC)), irs);
        _assertLockedOut(agentB, tokenA);
        _assertLockedOut(agentA, tokenC);
    }

    function test_commissionSuite_RevertWhen_StorageWasConfiguredOutsideItsNamespace() public {
        address irs = address(tokenA.identityRegistry().identityStorage());
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, irs, RolesLib.SHARED);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.StorageOutsideItsNamespace.selector, irs));
        this.commissionExternally(address(tokenA), RolesLib.namespaceOf(address(tokenA)));
    }

    function commissionExternally(address target, bytes32 namespace) external {
        AccessManagerSetupLib.commissionSuite(accessManager, target, namespace);
    }

    function test_perSuiteNamespace_SharedStorageIsWritableByBothRegistriesAndAgentsStayApart() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("ns-c", address(irs));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_ADMIN, storageNamespace), address(this), 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), address(this), 0);
        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));
        _grantAllAgentRoles(agentA, RolesLib.namespaceOf(address(tokenA)));
        _grantAllAgentRoles(agentB, RolesLib.namespaceOf(address(tokenC)));

        IERC3643IdentityRegistry registryA = tokenA.identityRegistry();
        IERC3643IdentityRegistry registryC = tokenC.identityRegistry();
        vm.prank(agentA);
        registryA.registerIdentity(alice, aliceIdentity, 0);
        vm.prank(agentB);
        registryC.registerIdentity(bob, bobIdentity, 0);
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertEq(address(irs.storedIdentity(bob)), address(bobIdentity));
        assertTrue(registryC.contains(alice));

        vm.prank(agentA);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentA));
        registryC.deleteIdentity(bob);
        vm.prank(agentA);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentA));
        irs.removeIdentityFromStorage(bob);

        _assertLockedOut(agentA, tokenC);
        _assertLockedOut(agentB, tokenA);
    }

    function test_commissionSuite_DefaultsToTheSuiteNamespace() public {
        AccessManagerSetupLib.commissionSuite(accessManager, address(tokenA));
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA)
        );
        assertNotEq(accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector), RolesLib.AGENT_MINTER);
        _grantAllAgentRoles(agentA, nsA);
        _assertLockedOut(agentA, tokenB);
    }

    function test_commissionSuite_DoesNotLabelRoles_AndExplicitLabelSetupLabelsTheNamespacedRoles() public {
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        vm.recordLogs();
        _commission(tokenA, nsA);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], IAccessManager.RoleLabel.selector);
        }

        string memory suffix = string.concat(" @ ", Strings.toHexString(uint256(nsA) >> 96, 8));
        vm.recordLogs();
        AccessManagerSetupLib.setupLabels(accessManager, nsA);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 14);
        assertEq(uint256(logs[0].topics[1]), RolesLib.forSuite(RolesLib.OWNER, nsA));
        assertEq(abi.decode(logs[0].data, (string)), string.concat("TREX-Suite Owner", suffix));
        assertEq(uint256(logs[1].topics[1]), RolesLib.forSuite(RolesLib.AGENT, nsA));
        assertEq(abi.decode(logs[1].data, (string)), string.concat("TREX-Suite Agent", suffix));
        for (uint256 i = 0; i < logs.length; i++) {
            assertEq(logs[i].topics[0], IAccessManager.RoleLabel.selector);
        }

        vm.expectEmit(true, false, false, true, address(accessManager));
        emit IAccessManager.RoleLabel(RolesLib.VERSION_MANAGER, "TREX-Suite Manager: Version");
        AccessManagerSetupLib.setupGlobalLabels(accessManager);
    }

    function test_commissionSuite_RevertWhen_SuiteIsAlreadyCommissioned() public {
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AlreadyCommissioned.selector, address(tokenA)));
        this.commissionExternally(address(tokenA), RolesLib.SHARED);
    }

    function test_commissionSuite_Success_LeavesACommissionedStoragePolicyUntouched() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("policy-c", address(irs));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));
        uint64 storageAgent = RolesLib.forSuite(RolesLib.AGENT, storageNamespace);
        bytes4[] memory bind = new bytes4[](1);
        bind[0] = IERC3643IdentityRegistryStorage.bindIdentityRegistry.selector;
        accessManager.setTargetFunctionRole(address(irs), bind, OTHER_FOREIGN_ROLE);
        accessManager.setRoleAdmin(storageAgent, FOREIGN_ROLE);
        accessManager.grantRole(FOREIGN_ROLE, address(this), 0);
        accessManager.grantRole(OTHER_FOREIGN_ROLE, address(this), 0);

        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.bindIdentityRegistry.selector
            ),
            OTHER_FOREIGN_ROLE
        );
        assertEq(accessManager.getRoleAdmin(storageAgent), FOREIGN_ROLE);
        (bool registryCWrites,) = accessManager.hasRole(storageAgent, address(tokenC.identityRegistry()));
        assertTrue(registryCWrites);
    }

    function test_commissionSuite_Success_SharedModeLeavesExistingRoleAdministratorsUntouched() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setRoleAdmin(RolesLib.AGENT, FOREIGN_ROLE);
        accessManager.grantRole(FOREIGN_ROLE, address(this), 0);

        _commission(tokenB, RolesLib.SHARED);

        assertEq(accessManager.getRoleAdmin(RolesLib.AGENT), FOREIGN_ROLE);
        (bool tokenBIsAgent,) = accessManager.hasRole(RolesLib.AGENT, address(tokenB));
        assertTrue(tokenBIsAgent);
    }

    function test_commissionSuite_Success_SharedModeKeepsAdministratorsExplicitlySetToAdminRole() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setRoleAdmin(RolesLib.AGENT, 0);
        accessManager.setRoleAdmin(RolesLib.AGENT_MINTER, FOREIGN_ROLE);

        _commission(tokenB, RolesLib.SHARED);

        assertEq(accessManager.getRoleAdmin(RolesLib.AGENT), 0);
        assertEq(accessManager.getRoleAdmin(RolesLib.AGENT_MINTER), FOREIGN_ROLE);
    }

    function test_commissionSuite_Success_KeepsAStorageRestrictedToAdminRole() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("admin-only-c", address(irs));
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));
        bytes4[] memory write = new bytes4[](1);
        write[0] = IERC3643IdentityRegistryStorage.addIdentityToStorage.selector;
        accessManager.setTargetFunctionRole(address(irs), write, 0);
        _grantAllAgentRoles(agentA, RolesLib.namespaceOf(address(tokenA)));
        IERC3643IdentityRegistry registryA = tokenA.identityRegistry();
        vm.prank(agentA);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryA)));
        registryA.registerIdentity(alice, aliceIdentity, 0);

        accessManager.grantRole(
            RolesLib.forSuite(RolesLib.AGENT_ADMIN, RolesLib.namespaceOf(address(irs))), address(this), 0
        );
        accessManager.grantRole(
            RolesLib.forSuite(RolesLib.IRS_BINDER, RolesLib.namespaceOf(address(irs))), address(this), 0
        );
        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            0
        );
        vm.prank(agentA);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryA)));
        registryA.registerIdentity(alice, aliceIdentity, 0);
    }

    function test_setupIdentityRegistryStorageRoles_MarksTheStorageSoCommissioningLeavesItAlone() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("manual-c", address(irs));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs), storageNamespace);
        bytes4[] memory remove = new bytes4[](1);
        remove[0] = IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector;
        accessManager.setTargetFunctionRole(address(irs), remove, 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), address(this), 0);

        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector
            ),
            0
        );
        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forSuite(RolesLib.AGENT, storageNamespace)
        );
        assertTrue(_isBound(irs, address(tokenC.identityRegistry())));
    }

    function test_commissionedMarker_DoesNotCollideWithAnyMappedSelector() public pure {
        _assertNoneIsTheMarker(AccessManagerSetupLib.tokenTable());
        _assertNoneIsTheMarker(AccessManagerSetupLib.registryTable());
        _assertNoneIsTheMarker(AccessManagerSetupLib.storageTable());
        _assertNoneIsTheMarker(AccessManagerSetupLib.complianceTable());
    }

    function _assertNoneIsTheMarker(AccessManagerSetupLib.SelectorRole[] memory table) private pure {
        for (uint256 i = 0; i < table.length; i++) {
            assertNotEq(table[i].selector, RolesLib.COMMISSIONED);
        }
    }

    function test_commissionSuite_BindsAReusedStorageAndRevertsWhenTheCallerCannotBind() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("bind-c", address(irs));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_ADMIN, storageNamespace), address(this), 0);
        assertFalse(_isBound(irs, address(tokenC.identityRegistry())));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        this.commissionExternally(address(tokenC), RolesLib.SHARED);
        assertEq(accessManager.getTargetFunctionRole(address(tokenC), IERC3643.mint.selector), 0);

        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), address(this), 0);
        _commission(tokenC, RolesLib.SHARED);
        assertTrue(_isBound(irs, address(tokenC.identityRegistry())));
    }

    function test_commissionSuite_RevertWhen_NamespaceIsTheStorageNamespace() public {
        address irs = address(tokenA.identityRegistry().identityStorage());

        vm.expectRevert(ErrorsLib.InvalidRoleNamespace.selector);
        this.commissionExternally(address(tokenA), RolesLib.namespaceOf(irs));
    }

    function test_commissionSuite_TwoSuitesInOneExplicitNamespaceShareAgents() public {
        bytes32 shared = RolesLib.namespaceOf(address(tokenA));
        _commission(tokenA, shared);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_ADMIN, shared), address(this), 0);
        _commission(tokenB, shared);
        _grantAllAgentRoles(agentA, shared);

        IERC3643IdentityRegistry registryB = tokenB.identityRegistry();
        vm.startPrank(agentA);
        registryB.registerIdentity(alice, aliceIdentity, 0);
        tokenB.unpause();
        tokenB.mint(alice, 3);
        vm.stopPrank();
        assertEq(tokenB.balanceOf(alice), 3);
    }

    function _isBound(IdentityRegistryStorage irs, address registry) private view returns (bool) {
        address[] memory linked = irs.linkedIdentityRegistries();
        for (uint256 i = 0; i < linked.length; i++) {
            if (linked[i] == registry) {
                return true;
            }
        }
        return false;
    }

    function test_migrate_Success_LocksAgentsOfAOutOfBOnASharedManager() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        _grantAllAgentRoles(agentB, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 nsB = RolesLib.namespaceOf(address(tokenB));

        AccessManagerSetupLib.RoleAssignment[] memory assignments =
            _concat(_assignAgentRoles(agentA, nsA), _assignAgentRoles(agentB, nsB));
        AccessManagerSetupLib.GlobalRevocation[] memory revocations =
            _concat(_revokeAgentRoles(agentA), _revokeAgentRoles(agentB));
        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _both(), _namespaces(nsA, nsB), assignments, revocations
        );

        _assertHoldsEveryAgentRole(agentA, nsA);
        _assertHoldsEveryAgentRole(agentB, nsB);
        _assertHoldsNoAgentRole(agentA, RolesLib.SHARED);
        _assertHoldsNoAgentRole(agentB, RolesLib.SHARED);
        _assertHoldsNoAgentRole(agentA, nsB);
        _assertHoldsNoAgentRole(agentB, nsA);

        IERC3643IdentityRegistry registryA = tokenA.identityRegistry();
        vm.startPrank(agentA);
        registryA.registerIdentity(alice, aliceIdentity, 0);
        tokenA.unpause();
        tokenA.mint(alice, 10);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(alice), 10);

        _assertLockedOut(agentA, tokenB);
        _assertLockedOut(agentB, tokenA);
    }

    function test_migrate_Success_PartialMigrationKeepsGlobalRolesForAnUnmigratedSibling() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        _grantAllAgentRoles(agentB, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), _assignAgentRoles(agentA, nsA), _noRevocations()
        );

        _assertHoldsEveryAgentRole(agentA, nsA);
        _assertHoldsEveryAgentRole(agentA, RolesLib.SHARED);
        _assertHoldsEveryAgentRole(agentB, RolesLib.SHARED);

        IERC3643IdentityRegistry registryB = tokenB.identityRegistry();
        vm.startPrank(agentA);
        registryB.registerIdentity(alice, aliceIdentity, 0);
        tokenB.unpause();
        tokenB.mint(alice, 4);
        vm.stopPrank();
        assertEq(tokenB.balanceOf(alice), 4);

        IERC3643IdentityRegistry registryA = tokenA.identityRegistry();
        vm.startPrank(agentA);
        registryA.registerIdentity(bob, bobIdentity, 0);
        tokenA.unpause();
        tokenA.mint(bob, 2);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(bob), 2);

        _assertLockedOut(agentB, tokenA);
    }

    function test_migrate_Success_ExplicitRevocationRemovesTheGlobalRoleAndKeepsTheNamespacedOne() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 0);
        accessManager.grantRole(RolesLib.AGENT_BURNER, agentA, 0);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](1);
        assignments[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        AccessManagerSetupLib.GlobalRevocation[] memory revocations = new AccessManagerSetupLib.GlobalRevocation[](1);
        revocations[0] = _revoke(agentA, RolesLib.AGENT_MINTER);
        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), assignments, revocations
        );

        (bool namespacedMinter,) = accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), agentA);
        (bool globalMinter,) = accessManager.hasRole(RolesLib.AGENT_MINTER, agentA);
        (bool globalBurner,) = accessManager.hasRole(RolesLib.AGENT_BURNER, agentA);
        (bool namespacedBurner,) = accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT_BURNER, nsA), agentA);
        assertTrue(namespacedMinter);
        assertFalse(globalMinter);
        assertTrue(globalBurner);
        assertFalse(namespacedBurner);
    }

    function test_migrate_Success_SameAccountDifferentRolesOnDifferentSuites() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 nsB = RolesLib.namespaceOf(address(tokenB));

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](6);
        assignments[0] = _assign(agentA, RolesLib.AGENT, nsA);
        assignments[1] = _assign(agentA, RolesLib.AGENT_PAUSER, nsA);
        assignments[2] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        assignments[3] = _assign(agentA, RolesLib.AGENT, nsB);
        assignments[4] = _assign(agentA, RolesLib.AGENT_PAUSER, nsB);
        assignments[5] = _assign(agentA, RolesLib.AGENT_BURNER, nsB);
        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _both(), _namespaces(nsA, nsB), assignments, _revokeAgentRoles(agentA)
        );

        IERC3643IdentityRegistry registryA = tokenA.identityRegistry();
        IERC3643IdentityRegistry registryB = tokenB.identityRegistry();
        vm.startPrank(agentA);
        registryA.registerIdentity(alice, aliceIdentity, 0);
        registryB.registerIdentity(alice, aliceIdentity, 0);
        tokenA.unpause();
        tokenB.unpause();
        tokenA.mint(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentA));
        tokenB.mint(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentA));
        tokenA.burn(alice, 1);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(alice), 5);
        _assertHoldsNoAgentRole(agentA, RolesLib.SHARED);
    }

    function test_migrate_Success_KeepsStructuralGrantsAndExecutionDelays() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 1 hours);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        address registry = address(tokenA.identityRegistry());
        address irs = address(tokenA.identityRegistry().identityStorage());

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](1);
        assignments[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        AccessManagerSetupLib.GlobalRevocation[] memory revocations = new AccessManagerSetupLib.GlobalRevocation[](1);
        revocations[0] = _revoke(agentA, RolesLib.AGENT_MINTER);
        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), assignments, revocations
        );

        (bool isMinter, uint32 delay) = accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), agentA);
        assertTrue(isMinter);
        assertEq(delay, 1 hours);
        (bool tokenIsAgent,) = accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT, nsA), address(tokenA));
        (bool registryWrites,) =
            accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT, RolesLib.namespaceOf(irs)), registry);
        assertTrue(tokenIsAgent);
        assertTrue(registryWrites);
        (bool tokenStillGlobal,) = accessManager.hasRole(RolesLib.AGENT, address(tokenA));
        (bool registryStillGlobal,) = accessManager.hasRole(RolesLib.AGENT, registry);
        assertFalse(tokenStillGlobal);
        assertFalse(registryStillGlobal);
        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA)
        );
    }

    function test_migrate_Success_LeavesASharedStorageAloneSoBothRegistriesKeepWriting() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("batch-c", address(irs));
        _commission(tokenA, RolesLib.SHARED);
        _grantStorageAdmin(irs);
        _commission(tokenC, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        _grantAllAgentRoles(agentB, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));

        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), _assignAgentRoles(agentA, nsA), _revokeAgentRoles(agentA)
        );

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forSuite(RolesLib.AGENT, storageNamespace)
        );
        IERC3643IdentityRegistry registryA = tokenA.identityRegistry();
        IERC3643IdentityRegistry registryC = tokenC.identityRegistry();
        vm.prank(agentA);
        registryA.registerIdentity(alice, aliceIdentity, 0);
        vm.prank(agentB);
        registryC.registerIdentity(bob, bobIdentity, 0);
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertEq(address(irs.storedIdentity(bob)), address(bobIdentity));
        _assertLockedOut(agentA, tokenC);
    }

    function test_migrate_RevertWhen_AssignmentIsInvalid() public {
        _commission(tokenA, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.IRS_BINDER, agentA, 0);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(tokenA.identityRegistry().identityStorage()));
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);

        one[0] = _assign(agentA, RolesLib.IRS_BINDER, nsA);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidRoleForNamespace.selector, RolesLib.IRS_BINDER, nsA));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());

        one[0] = _assign(agentA, RolesLib.AGENT_MINTER, storageNamespace);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AssignmentNamespaceNotMigrated.selector, storageNamespace));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());

        one[0] = _assign(agentA, RolesLib.AGENT_MINTER, RolesLib.namespaceOf(address(tokenB)));
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.AssignmentNamespaceNotMigrated.selector, RolesLib.namespaceOf(address(tokenB))
            )
        );
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());

        one[0] = _assign(agentB, RolesLib.AGENT_MINTER, nsA);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RoleNotHeld.selector, agentB, RolesLib.AGENT_MINTER));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());

        AccessManagerSetupLib.RoleAssignment[] memory twice = new AccessManagerSetupLib.RoleAssignment[](2);
        twice[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        twice[1] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        vm.expectRevert(ErrorsLib.DuplicateMigrationEntry.selector);
        this.migrateExternally(_only(tokenA), _namespaces(nsA), twice, _noRevocations());
    }

    function test_migrate_RevertWhen_RevocationIsInvalid() public {
        _commission(tokenA, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        AccessManagerSetupLib.GlobalRevocation[] memory one = new AccessManagerSetupLib.GlobalRevocation[](1);

        one[0] = _revoke(agentB, RolesLib.AGENT_MINTER);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RoleNotHeld.selector, agentB, RolesLib.AGENT_MINTER));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), one);

        one[0] = _revoke(agentA, RolesLib.VERSION_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.InvalidRoleForNamespace.selector, RolesLib.VERSION_MANAGER, RolesLib.SHARED
            )
        );
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), one);

        AccessManagerSetupLib.GlobalRevocation[] memory twice = new AccessManagerSetupLib.GlobalRevocation[](2);
        twice[0] = _revoke(agentA, RolesLib.AGENT_MINTER);
        twice[1] = _revoke(agentA, RolesLib.AGENT_MINTER);
        vm.expectRevert(ErrorsLib.DuplicateMigrationEntry.selector);
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), twice);
    }

    function test_migrate_RevertWhen_AHolderHasAPendingGlobalGrant() public {
        _commission(tokenA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        accessManager.setGrantDelay(RolesLib.AGENT_MINTER, 1 days);
        accessManager.setGrantDelay(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), 1 days);
        vm.warp(block.timestamp + 6 days);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 0);
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PendingRoleGrant.selector, agentA, RolesLib.AGENT_MINTER));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());
    }

    function test_migrate_RevertWhen_AHolderHasAPendingDelayChange() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 1 hours);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 0);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PendingDelayChange.selector, agentA, RolesLib.AGENT_MINTER));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());
    }

    function test_migrate_RevertWhen_GrantDelayNotPrepared_ThenSucceedsOncePrepared() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 0);
        accessManager.setGrantDelay(RolesLib.AGENT_MINTER, 1 days);
        vm.warp(block.timestamp + 6 days);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        uint64 namespacedMinter = RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA);
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        AccessManagerSetupLib.GlobalRevocation[] memory revoke = new AccessManagerSetupLib.GlobalRevocation[](1);
        revoke[0] = _revoke(agentA, RolesLib.AGENT_MINTER);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GrantDelayNotPrepared.selector, RolesLib.AGENT_MINTER, nsA));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, revoke);

        accessManager.setGrantDelay(namespacedMinter, 1 days);
        vm.warp(block.timestamp + 6 days);
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, _only(tokenA), _namespaces(nsA), one, revoke);

        (bool stillGlobal,) = accessManager.hasRole(RolesLib.AGENT_MINTER, agentA);
        assertFalse(stillGlobal);
        (bool activeYet,) = accessManager.hasRole(namespacedMinter, agentA);
        assertFalse(activeYet);
        vm.warp(block.timestamp + 1 days);
        (bool isMinter,) = accessManager.hasRole(namespacedMinter, agentA);
        assertTrue(isMinter);
    }

    function test_migrate_CannotSeeAPendingGrantDelayChange_PoliciesMustBeSettled() public {
        _commission(tokenA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        uint64 namespacedMinter = RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA);
        accessManager.setGrantDelay(RolesLib.AGENT_MINTER, 2 days);
        accessManager.setGrantDelay(namespacedMinter, 2 days);
        vm.warp(block.timestamp + 6 days);
        accessManager.setGrantDelay(RolesLib.AGENT_MINTER, 1 days);
        assertEq(accessManager.getRoleGrantDelay(RolesLib.AGENT_MINTER), 2 days);

        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations()
        );

        vm.warp(block.timestamp + 6 days);
        assertEq(accessManager.getRoleGrantDelay(RolesLib.AGENT_MINTER), 1 days);
        assertEq(accessManager.getRoleGrantDelay(namespacedMinter), 2 days);
    }

    function test_migrate_RevertWhen_StorageWasReconfiguredOutsideItsNamespace() public {
        _commission(tokenA, RolesLib.SHARED);
        address irs = address(tokenA.identityRegistry().identityStorage());
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, irs, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.StorageOutsideItsNamespace.selector, irs));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations());
    }

    function test_migrate_IgnoresTheGlobalBinderGrantDelay() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setGrantDelay(RolesLib.IRS_BINDER, 1 days);
        vm.warp(block.timestamp + 6 days);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations()
        );
        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA)
        );
    }

    function test_migrate_RevertWhen_GrantDelayNotPreparedForARoleWithoutMembers() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setGrantDelay(RolesLib.AGENT_BURNER, 1 days);
        vm.warp(block.timestamp + 6 days);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GrantDelayNotPrepared.selector, RolesLib.AGENT_BURNER, nsA));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations());

        accessManager.setGrantDelay(RolesLib.forSuite(RolesLib.AGENT_BURNER, nsA), 1 days);
        vm.warp(block.timestamp + 6 days);
        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations()
        );
        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.burn.selector),
            RolesLib.forSuite(RolesLib.AGENT_BURNER, nsA)
        );
    }

    function test_migrate_RevertWhen_TargetNamespaceIsShared() public {
        _commission(tokenA, RolesLib.SHARED);

        vm.expectRevert(ErrorsLib.InvalidRoleNamespace.selector);
        this.migrateExternally(_only(tokenA), _namespaces(RolesLib.SHARED), _noAssignments(), _noRevocations());
    }

    function test_migrate_RevertWhen_ANamespaceIsAStorageNamespace() public {
        _commission(tokenA, RolesLib.SHARED);
        address irs = address(tokenA.identityRegistry().identityStorage());

        vm.expectRevert(ErrorsLib.InvalidRoleNamespace.selector);
        this.migrateExternally(
            _only(tokenA), _namespaces(RolesLib.namespaceOf(irs)), _noAssignments(), _noRevocations()
        );
    }

    function test_migrate_RevertWhen_ATokenOrNamespaceIsListedTwice() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 nsB = RolesLib.namespaceOf(address(tokenB));
        address[] memory twice = new address[](2);
        twice[0] = address(tokenA);
        twice[1] = address(tokenA);

        vm.expectRevert(ErrorsLib.DuplicateMigrationEntry.selector);
        this.migrateExternally(twice, _namespaces(nsA, nsB), _noAssignments(), _noRevocations());

        vm.expectRevert(ErrorsLib.DuplicateMigrationEntry.selector);
        this.migrateExternally(_both(), _namespaces(nsA, nsA), _noAssignments(), _noRevocations());
    }

    function test_migrate_RevertWhen_ASelectorIsCustomised_LeavesNothingChanged() public {
        _commission(tokenA, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        address registry = address(tokenA.identityRegistry());
        bytes4[] memory remove = new bytes4[](1);
        remove[0] = IERC3643IdentityRegistry.deleteIdentity.selector;
        accessManager.setTargetFunctionRole(registry, remove, 0);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.NonStandardPolicy.selector, registry, IERC3643IdentityRegistry.deleteIdentity.selector
            )
        );
        this.migrateExternally(
            _only(tokenA), _namespaces(nsA), _assignAgentRoles(agentA, nsA), _revokeAgentRoles(agentA)
        );

        assertEq(accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector), RolesLib.AGENT_MINTER);
        _assertHoldsEveryAgentRole(agentA, RolesLib.SHARED);
        _assertHoldsNoAgentRole(agentA, nsA);
    }

    function test_migrate_RevertWhen_AnAdministratorIsCustomised() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setRoleAdmin(RolesLib.AGENT_MINTER, FOREIGN_ROLE);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonStandardAdministration.selector, RolesLib.AGENT_MINTER));
        this.migrateExternally(
            _only(tokenA), _namespaces(RolesLib.namespaceOf(address(tokenA))), _noAssignments(), _noRevocations()
        );
    }

    function test_migrate_RevertWhen_AGuardianIsSet() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setRoleGuardian(RolesLib.AGENT_BURNER, RolesLib.SUITE_ADMIN);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonStandardAdministration.selector, RolesLib.AGENT_BURNER));
        this.migrateExternally(
            _only(tokenA), _namespaces(RolesLib.namespaceOf(address(tokenA))), _noAssignments(), _noRevocations()
        );
    }

    function test_migrate_RevertWhen_SuiteWasNotCommissionedShared() public {
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        _commission(tokenA, nsA);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotCommissionedShared.selector, address(tokenA)));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations());
    }

    function test_migrate_RevertWhen_DestinationNamespaceIsAlreadyInUse() public {
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, nsA);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DestinationNamespaceInUse.selector, nsA));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations());
    }

    function test_migrate_RevertWhen_DestinationAdministrationIsPreset() public {
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setRoleGuardian(RolesLib.forSuite(RolesLib.AGENT, nsA), FOREIGN_ROLE);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DestinationNamespaceInUse.selector, nsA));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations());
    }

    function test_migrate_RevertWhen_ARevocationFailsLate_LeavesNothingChanged() public {
        _commission(tokenA, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        accessManager.revokeRole(RolesLib.AGENT_ADMIN, address(this));
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, address(this), RolesLib.AGENT_ADMIN
            )
        );
        this.migrateExternally(
            _only(tokenA), _namespaces(nsA), _assignAgentRoles(agentA, nsA), _revokeAgentRoles(agentA)
        );

        assertEq(accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector), RolesLib.AGENT_MINTER);
        _assertHoldsEveryAgentRole(agentA, RolesLib.SHARED);
        _assertHoldsNoAgentRole(agentA, nsA);
    }

    function test_remainingGlobalHolders_ListsAccountsStillHoldingAnyGlobalSuiteRole() public {
        _commission(tokenA, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.TOKEN_MANAGER, agentB, 0);
        address[] memory candidates = new address[](3);
        candidates[0] = agentA;
        candidates[1] = agentB;
        candidates[2] = another;
        assertEq(AccessManagerSetupLib.remainingGlobalHolders(accessManager, candidates).length, 2);

        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), _assignAgentRoles(agentA, nsA), _revokeAgentRoles(agentA)
        );

        address[] memory holdersAfter = AccessManagerSetupLib.remainingGlobalHolders(accessManager, candidates);
        assertEq(holdersAfter.length, 1);
        assertEq(holdersAfter[0], agentB);
    }

    function migrateExternally(
        address[] memory tokens,
        bytes32[] memory namespaces,
        AccessManagerSetupLib.RoleAssignment[] memory assignments,
        AccessManagerSetupLib.GlobalRevocation[] memory revocations
    ) external {
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, tokens, namespaces, assignments, revocations);
    }

    function _assign(address account, uint64 role, bytes32 namespace)
        private
        pure
        returns (AccessManagerSetupLib.RoleAssignment memory)
    {
        return AccessManagerSetupLib.RoleAssignment({ account: account, role: role, namespace: namespace });
    }

    function _revoke(address account, uint64 role)
        private
        pure
        returns (AccessManagerSetupLib.GlobalRevocation memory)
    {
        return AccessManagerSetupLib.GlobalRevocation({ account: account, role: role });
    }

    function _assignAgentRoles(address account, bytes32 namespace)
        private
        pure
        returns (AccessManagerSetupLib.RoleAssignment[] memory assignments)
    {
        uint64[8] memory roles = _agentRoles();
        assignments = new AccessManagerSetupLib.RoleAssignment[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            assignments[i] = _assign(account, roles[i], namespace);
        }
    }

    function _revokeAgentRoles(address account)
        private
        pure
        returns (AccessManagerSetupLib.GlobalRevocation[] memory revocations)
    {
        uint64[8] memory roles = _agentRoles();
        revocations = new AccessManagerSetupLib.GlobalRevocation[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            revocations[i] = _revoke(account, roles[i]);
        }
    }

    function _concat(
        AccessManagerSetupLib.RoleAssignment[] memory first,
        AccessManagerSetupLib.RoleAssignment[] memory second
    ) private pure returns (AccessManagerSetupLib.RoleAssignment[] memory joined) {
        joined = new AccessManagerSetupLib.RoleAssignment[](first.length + second.length);
        for (uint256 i = 0; i < first.length; i++) {
            joined[i] = first[i];
        }
        for (uint256 i = 0; i < second.length; i++) {
            joined[first.length + i] = second[i];
        }
    }

    function _concat(
        AccessManagerSetupLib.GlobalRevocation[] memory first,
        AccessManagerSetupLib.GlobalRevocation[] memory second
    ) private pure returns (AccessManagerSetupLib.GlobalRevocation[] memory joined) {
        joined = new AccessManagerSetupLib.GlobalRevocation[](first.length + second.length);
        for (uint256 i = 0; i < first.length; i++) {
            joined[i] = first[i];
        }
        for (uint256 i = 0; i < second.length; i++) {
            joined[first.length + i] = second[i];
        }
    }

    function _noAssignments() private pure returns (AccessManagerSetupLib.RoleAssignment[] memory) {
        return new AccessManagerSetupLib.RoleAssignment[](0);
    }

    function _noRevocations() private pure returns (AccessManagerSetupLib.GlobalRevocation[] memory) {
        return new AccessManagerSetupLib.GlobalRevocation[](0);
    }

    function _both() private view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
    }

    function _only(Token target) private pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(target);
    }

    function _namespaces(bytes32 first) private pure returns (bytes32[] memory namespaces) {
        namespaces = new bytes32[](1);
        namespaces[0] = first;
    }

    function _namespaces(bytes32 first, bytes32 second) private pure returns (bytes32[] memory namespaces) {
        namespaces = new bytes32[](2);
        namespaces[0] = first;
        namespaces[1] = second;
    }

    function _assertHoldsEveryAgentRole(address account, bytes32 namespace) private view {
        uint64[8] memory roles = _agentRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            (bool isMember,) = accessManager.hasRole(RolesLib.forSuite(roles[i], namespace), account);
            assertTrue(isMember);
        }
    }

    function _assertHoldsNoAgentRole(address account, bytes32 namespace) private view {
        uint64[8] memory roles = _agentRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            (bool isMember,) = accessManager.hasRole(RolesLib.forSuite(roles[i], namespace), account);
            assertFalse(isMember);
        }
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

    function _assertBothRegistriesWrite(
        Token first,
        bytes32 firstNamespace,
        Token second,
        bytes32 secondNamespace,
        IdentityRegistryStorage irs
    ) private {
        _grantAllAgentRoles(agentA, firstNamespace);
        _grantAllAgentRoles(agentB, secondNamespace);
        IERC3643IdentityRegistry firstRegistry = first.identityRegistry();
        IERC3643IdentityRegistry secondRegistry = second.identityRegistry();
        vm.prank(agentA);
        firstRegistry.registerIdentity(alice, aliceIdentity, 0);
        vm.prank(agentB);
        secondRegistry.registerIdentity(bob, bobIdentity, 0);
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertEq(address(irs.storedIdentity(bob)), address(bobIdentity));
    }

    function _allowRecoveryTo(IIdentity identity, address newWallet) private {
        bytes memory signerData = abi.encodePacked(newWallet);
        vm.prank(alice);
        KeyManager(address(identity)).addKeyWithData(keccak256(signerData), 1, 1, signerData, "");
    }

    function test_commissionSuite_MapsEverySuiteContractIntoTheNamespace() public {
        bytes32 ns = RolesLib.namespaceOf(address(tokenA));
        _commission(tokenA, ns);
        address registry = address(tokenA.identityRegistry());
        address irs = address(tokenA.identityRegistry().identityStorage());
        address mc = address(tokenA.compliance());

        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forSuite(RolesLib.AGENT_MINTER, ns)
        );
        assertEq(
            accessManager.getTargetFunctionRole(registry, IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forSuite(RolesLib.AGENT, ns)
        );
        assertEq(
            accessManager.getTargetFunctionRole(irs, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.forSuite(RolesLib.AGENT, RolesLib.namespaceOf(irs))
        );
        assertEq(
            accessManager.getTargetFunctionRole(mc, IModularCompliance.addModule.selector),
            RolesLib.forSuite(RolesLib.OWNER, ns)
        );
        assertEq(
            accessManager.getRoleAdmin(RolesLib.forSuite(RolesLib.AGENT, ns)),
            RolesLib.forSuite(RolesLib.AGENT_ADMIN, ns)
        );
        (bool tokenIsAgent,) = accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT, ns), address(tokenA));
        (bool registryWrites,) =
            accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT, RolesLib.namespaceOf(irs)), registry);
        assertTrue(tokenIsAgent);
        assertTrue(registryWrites);
    }

    function _assertLockedOut(address agentAccount, Token other) private {
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentAccount);
        IERC3643IdentityRegistry registry = other.identityRegistry();

        vm.startPrank(agentAccount);
        vm.expectRevert(unauthorized);
        registry.registerIdentity(alice, aliceIdentity, 0);
        vm.expectRevert(unauthorized);
        other.unpause();
        vm.expectRevert(unauthorized);
        other.mint(alice, 1);
        vm.expectRevert(unauthorized);
        other.burn(alice, 1);
        vm.expectRevert(unauthorized);
        other.freezePartialTokens(alice, 1);
        vm.expectRevert(unauthorized);
        other.setAddressFrozen(alice, true);
        vm.expectRevert(unauthorized);
        other.forcedTransfer(alice, bob, 1);
        vm.expectRevert(unauthorized);
        other.pause();
        vm.expectRevert(unauthorized);
        other.recoveryAddress(alice, bob, address(aliceIdentity));
        vm.stopPrank();
    }

    function _commission(Token target, bytes32 namespace) private {
        AccessManagerSetupLib.commissionSuite(accessManager, address(target), namespace);
    }

    function _grantStorageAdmin(IdentityRegistryStorage irs) private {
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_ADMIN, storageNamespace), address(this), 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), address(this), 0);
    }

    function _grantAllAgentRoles(address account, bytes32 namespace) private {
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_ADMIN, namespace), address(this), 0);
        uint64[8] memory roles = _agentRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            accessManager.grantRole(RolesLib.forSuite(roles[i], namespace), account, 0);
        }
    }

    function _deployBare(string memory salt, address irs) private returns (Token) {
        ITREXFactory.TokenDetails memory details = ITREXFactory.TokenDetails({
            name: salt,
            symbol: salt,
            decimals: 0,
            irs: irs,
            ONCHAINID: address(0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager),
            accessManagerAdmin: address(0)
        });
        ITREXFactory.ClaimDetails memory claims = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
        _deploySuite(salt, details, claims);
        return Token(trexFactory.getToken(salt));
    }

}
