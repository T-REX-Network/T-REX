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
    Token internal tokenA;
    Token internal tokenB;
    address internal agentA = makeAddr("agentA");
    address internal agentB = makeAddr("agentB");

    function setUp() public override {
        super.setUp();
        tokenA = _deployBare("ns-a", address(0));
        tokenB = _deployBare("ns-b", address(0));
    }

    function testFuzz_role_IsDeterministicAndDistinctAcrossScopes(bytes32 name, bytes32 first, bytes32 second)
        public
        pure
    {
        vm.assume(first != second);
        assertEq(RolesLib.role(first, name), RolesLib.role(first, name));
        assertNotEq(RolesLib.role(first, name), RolesLib.role(second, name));
    }

    function test_role_DerivesDistinctIdsPerNameAndScope() public view {
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        bytes32 nsB = RolesLib.scopeOf(address(tokenB));
        assertNotEq(RolesLib.role(nsA, RolesLib.AGENT_MINTER), RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER));
        assertNotEq(RolesLib.role(nsA, RolesLib.AGENT_MINTER), RolesLib.role(nsB, RolesLib.AGENT_MINTER));
        assertNotEq(RolesLib.role(nsA, RolesLib.AGENT_MINTER), RolesLib.role(nsA, RolesLib.AGENT_BURNER));
    }

    function test_perSuiteNamespace_AgentOfAOperatesAOnly() public {
        _commission(tokenA, RolesLib.scopeOf(address(tokenA)));
        _commission(tokenB, RolesLib.scopeOf(address(tokenB)));
        _grantAllAgentRoles(agentA, RolesLib.scopeOf(address(tokenA)));

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
        _commission(tokenA, RolesLib.scopeOf(address(tokenA)));
        _commission(tokenB, RolesLib.scopeOf(address(tokenB)));
        _grantAllAgentRoles(agentB, RolesLib.scopeOf(address(tokenB)));

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

    function test_mixedModes_PerSuiteSuiteJoiningASharedModeStorageUsesTheStorageNamespace() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("mixed-c", address(irs));
        bytes32 storageNamespace = RolesLib.scopeOf(address(irs));
        _commission(tokenA, RolesLib.SHARED);
        _grantStorageAdmin(irs);
        _commission(tokenC, RolesLib.scopeOf(address(tokenC)));

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.role(storageNamespace, RolesLib.AGENT)
        );
        _assertBothRegistriesWrite(tokenA, RolesLib.SHARED, tokenC, RolesLib.scopeOf(address(tokenC)), irs);
        _assertLockedOut(agentB, tokenA);
        _assertLockedOut(agentA, tokenC);
    }

    function commissionExternally(address target, bytes32 namespace) external {
        AccessManagerSetupLib.commissionSuite(accessManager, target, namespace);
    }

    function test_perSuiteNamespace_SharedStorageIsWritableByBothRegistriesAndAgentsStayApart() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("ns-c", address(irs));
        bytes32 storageNamespace = RolesLib.scopeOf(address(irs));
        _commission(tokenA, RolesLib.scopeOf(address(tokenA)));
        accessManager.grantRole(RolesLib.role(storageNamespace, RolesLib.AGENT_ADMIN), address(this), 0);
        accessManager.grantRole(RolesLib.role(storageNamespace, RolesLib.IRS_BINDER), address(this), 0);
        _commission(tokenC, RolesLib.scopeOf(address(tokenC)));
        _grantAllAgentRoles(agentA, RolesLib.scopeOf(address(tokenA)));
        _grantAllAgentRoles(agentB, RolesLib.scopeOf(address(tokenC)));

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
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));

        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.role(nsA, RolesLib.AGENT_MINTER)
        );
        assertNotEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER)
        );
        _grantAllAgentRoles(agentA, nsA);
        _assertLockedOut(agentA, tokenB);
    }

    function test_commissionSuite_DoesNotLabelRoles_AndExplicitLabelSetupLabelsTheScopedRoles() public {
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
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
        assertEq(logs.length, 16);
        assertEq(uint256(logs[0].topics[1]), RolesLib.role(nsA, RolesLib.OWNER));
        assertEq(abi.decode(logs[0].data, (string)), string.concat("TREX-Suite Owner", suffix));
        assertEq(uint256(logs[1].topics[1]), RolesLib.role(nsA, RolesLib.AGENT));
        assertEq(abi.decode(logs[1].data, (string)), string.concat("TREX-Suite Agent", suffix));
        for (uint256 i = 0; i < logs.length; i++) {
            assertEq(logs[i].topics[0], IAccessManager.RoleLabel.selector);
        }
    }

    function test_commissionSuite_BindsAReusedStorageAndRevertsWhenTheCallerCannotBind() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("bind-c", address(irs));
        bytes32 storageNamespace = RolesLib.scopeOf(address(irs));
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.role(storageNamespace, RolesLib.AGENT_ADMIN), address(this), 0);
        assertFalse(_isBound(irs, address(tokenC.identityRegistry())));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        this.commissionExternally(address(tokenC), RolesLib.SHARED);
        assertEq(accessManager.getTargetFunctionRole(address(tokenC), IERC3643.mint.selector), 0);

        accessManager.grantRole(RolesLib.role(storageNamespace, RolesLib.IRS_BINDER), address(this), 0);
        _commission(tokenC, RolesLib.SHARED);
        assertTrue(_isBound(irs, address(tokenC.identityRegistry())));
    }

    function test_commissionSuite_TwoSuitesInOneExplicitNamespaceShareAgents() public {
        bytes32 shared = RolesLib.scopeOf(address(tokenA));
        _commission(tokenA, shared);
        accessManager.grantRole(RolesLib.role(shared, RolesLib.AGENT_ADMIN), address(this), 0);
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
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        bytes32 nsB = RolesLib.scopeOf(address(tokenB));

        AccessManagerSetupLib.migrateSuitesToScopes(
            accessManager, _both(), _namespaces(nsA, nsB), _assignAgentRoles(agentA, nsA), _revokeAgentRoles(agentA)
        );
        _grantAllAgentRoles(agentB, nsB);

        _assertHoldsEveryAgentRole(agentA, nsA);
        _assertHoldsNoAgentRole(agentA, RolesLib.SHARED);
        _assertHoldsNoAgentRole(agentA, nsB);
        _assertHoldsEveryAgentRole(agentB, RolesLib.SHARED);
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
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));

        AccessManagerSetupLib.migrateSuitesToScopes(
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
        accessManager.grantRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER), agentA, 0);
        accessManager.grantRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_BURNER), agentA, 0);
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](1);
        assignments[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        AccessManagerSetupLib.SharedRevocation[] memory revocations = new AccessManagerSetupLib.SharedRevocation[](1);
        revocations[0] = _revoke(agentA, RolesLib.AGENT_MINTER);
        AccessManagerSetupLib.migrateSuitesToScopes(
            accessManager, _only(tokenA), _namespaces(nsA), assignments, revocations
        );

        (bool namespacedMinter,) = accessManager.hasRole(RolesLib.role(nsA, RolesLib.AGENT_MINTER), agentA);
        (bool globalMinter,) = accessManager.hasRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER), agentA);
        (bool globalBurner,) = accessManager.hasRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_BURNER), agentA);
        (bool namespacedBurner,) = accessManager.hasRole(RolesLib.role(nsA, RolesLib.AGENT_BURNER), agentA);
        assertTrue(namespacedMinter);
        assertFalse(globalMinter);
        assertTrue(globalBurner);
        assertFalse(namespacedBurner);
    }

    function test_migrate_Success_SameAccountDifferentRolesOnDifferentSuites() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        bytes32 nsB = RolesLib.scopeOf(address(tokenB));

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](6);
        assignments[0] = _assign(agentA, RolesLib.AGENT, nsA);
        assignments[1] = _assign(agentA, RolesLib.AGENT_PAUSER, nsA);
        assignments[2] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        assignments[3] = _assign(agentA, RolesLib.AGENT, nsB);
        assignments[4] = _assign(agentA, RolesLib.AGENT_PAUSER, nsB);
        assignments[5] = _assign(agentA, RolesLib.AGENT_BURNER, nsB);
        AccessManagerSetupLib.migrateSuitesToScopes(
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
        accessManager.grantRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER), agentA, 1 hours);
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        address registry = address(tokenA.identityRegistry());
        address irs = address(tokenA.identityRegistry().identityStorage());

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](1);
        assignments[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);
        AccessManagerSetupLib.SharedRevocation[] memory revocations = new AccessManagerSetupLib.SharedRevocation[](1);
        revocations[0] = _revoke(agentA, RolesLib.AGENT_MINTER);
        AccessManagerSetupLib.migrateSuitesToScopes(
            accessManager, _only(tokenA), _namespaces(nsA), assignments, revocations
        );

        (bool isMinter, uint32 delay) = accessManager.hasRole(RolesLib.role(nsA, RolesLib.AGENT_MINTER), agentA);
        assertTrue(isMinter);
        assertEq(delay, 1 hours);
        (bool tokenIsAgent,) = accessManager.hasRole(RolesLib.role(nsA, RolesLib.AGENT), address(tokenA));
        (bool registryWrites,) = accessManager.hasRole(RolesLib.role(RolesLib.scopeOf(irs), RolesLib.AGENT), registry);
        assertTrue(tokenIsAgent);
        assertTrue(registryWrites);
        (bool tokenStillGlobal,) =
            accessManager.hasRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT), address(tokenA));
        (bool registryStillGlobal,) = accessManager.hasRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT), registry);
        assertFalse(tokenStillGlobal);
        assertFalse(registryStillGlobal);
        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.role(nsA, RolesLib.AGENT_MINTER)
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
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        bytes32 storageNamespace = RolesLib.scopeOf(address(irs));

        AccessManagerSetupLib.migrateSuitesToScopes(
            accessManager, _only(tokenA), _namespaces(nsA), _assignAgentRoles(agentA, nsA), _revokeAgentRoles(agentA)
        );

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.role(storageNamespace, RolesLib.AGENT)
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

    function test_migrate_RevertWhen_AssignmentIsNotHeld() public {
        _commission(tokenA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentB, RolesLib.AGENT_MINTER, nsA);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.RoleNotHeld.selector, agentB, RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER)
            )
        );
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());
    }

    function test_migrate_RevertWhen_AHolderHasAPendingGlobalGrant() public {
        _commission(tokenA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        accessManager.setGrantDelay(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER), 1 days);
        accessManager.setGrantDelay(RolesLib.role(nsA, RolesLib.AGENT_MINTER), 1 days);
        vm.warp(block.timestamp + 6 days);
        accessManager.grantRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER), agentA, 0);
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.PendingRoleGrant.selector, agentA, RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER)
            )
        );
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());
    }

    function test_migrate_RevertWhen_AHolderHasAPendingDelayChange() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER), agentA, 1 hours);
        accessManager.grantRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER), agentA, 0);
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentA, RolesLib.AGENT_MINTER, nsA);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.PendingDelayChange.selector, agentA, RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER)
            )
        );
        this.migrateExternally(_only(tokenA), _namespaces(nsA), one, _noRevocations());
    }

    function test_migrate_RevertWhen_TokenHoldsNoSharedAgentRole() public {
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));
        _commission(tokenA, nsA);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.RoleNotHeld.selector, address(tokenA), RolesLib.role(RolesLib.SHARED, RolesLib.AGENT)
            )
        );
        this.migrateExternally(_only(tokenA), _namespaces(nsA), _noAssignments(), _noRevocations());
    }

    function test_migrate_RevertWhen_ARevocationFailsLate_LeavesNothingChanged() public {
        _commission(tokenA, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        accessManager.revokeRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_ADMIN), address(this));
        bytes32 nsA = RolesLib.scopeOf(address(tokenA));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                address(this),
                RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_ADMIN)
            )
        );
        this.migrateExternally(
            _only(tokenA), _namespaces(nsA), _assignAgentRoles(agentA, nsA), _revokeAgentRoles(agentA)
        );

        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.role(RolesLib.SHARED, RolesLib.AGENT_MINTER)
        );
        _assertHoldsEveryAgentRole(agentA, RolesLib.SHARED);
        _assertHoldsNoAgentRole(agentA, nsA);
    }

    function migrateExternally(
        address[] memory tokens,
        bytes32[] memory namespaces,
        AccessManagerSetupLib.RoleAssignment[] memory assignments,
        AccessManagerSetupLib.SharedRevocation[] memory revocations
    ) external {
        AccessManagerSetupLib.migrateSuitesToScopes(accessManager, tokens, namespaces, assignments, revocations);
    }

    function _assign(address account, bytes32 name, bytes32 scope)
        private
        pure
        returns (AccessManagerSetupLib.RoleAssignment memory)
    {
        return AccessManagerSetupLib.RoleAssignment({ account: account, name: name, scope: scope });
    }

    function _revoke(address account, bytes32 name)
        private
        pure
        returns (AccessManagerSetupLib.SharedRevocation memory)
    {
        return AccessManagerSetupLib.SharedRevocation({ account: account, name: name });
    }

    function _assignAgentRoles(address account, bytes32 scope)
        private
        pure
        returns (AccessManagerSetupLib.RoleAssignment[] memory assignments)
    {
        bytes32[8] memory names = _agentRoles();
        assignments = new AccessManagerSetupLib.RoleAssignment[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            assignments[i] = _assign(account, names[i], scope);
        }
    }

    function _revokeAgentRoles(address account)
        private
        pure
        returns (AccessManagerSetupLib.SharedRevocation[] memory revocations)
    {
        bytes32[8] memory names = _agentRoles();
        revocations = new AccessManagerSetupLib.SharedRevocation[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            revocations[i] = _revoke(account, names[i]);
        }
    }

    function _noAssignments() private pure returns (AccessManagerSetupLib.RoleAssignment[] memory) {
        return new AccessManagerSetupLib.RoleAssignment[](0);
    }

    function _noRevocations() private pure returns (AccessManagerSetupLib.SharedRevocation[] memory) {
        return new AccessManagerSetupLib.SharedRevocation[](0);
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

    function _assertHoldsEveryAgentRole(address account, bytes32 scope) private view {
        bytes32[8] memory names = _agentRoles();
        for (uint256 i = 0; i < names.length; i++) {
            (bool isMember,) = accessManager.hasRole(RolesLib.role(scope, names[i]), account);
            assertTrue(isMember);
        }
    }

    function _assertHoldsNoAgentRole(address account, bytes32 scope) private view {
        bytes32[8] memory names = _agentRoles();
        for (uint256 i = 0; i < names.length; i++) {
            (bool isMember,) = accessManager.hasRole(RolesLib.role(scope, names[i]), account);
            assertFalse(isMember);
        }
    }

    function _agentRoles() private pure returns (bytes32[8] memory) {
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
        bytes32 ns = RolesLib.scopeOf(address(tokenA));
        _commission(tokenA, ns);
        address registry = address(tokenA.identityRegistry());
        address irs = address(tokenA.identityRegistry().identityStorage());
        address mc = address(tokenA.compliance());

        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.role(ns, RolesLib.AGENT_MINTER)
        );
        assertEq(
            accessManager.getTargetFunctionRole(registry, IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.role(ns, RolesLib.AGENT)
        );
        assertEq(
            accessManager.getTargetFunctionRole(irs, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.role(RolesLib.scopeOf(irs), RolesLib.AGENT)
        );
        assertEq(
            accessManager.getTargetFunctionRole(mc, IModularCompliance.addModule.selector),
            RolesLib.role(ns, RolesLib.OWNER)
        );
        assertEq(accessManager.getRoleAdmin(RolesLib.role(ns, RolesLib.AGENT)), RolesLib.role(ns, RolesLib.AGENT_ADMIN));
        (bool tokenIsAgent,) = accessManager.hasRole(RolesLib.role(ns, RolesLib.AGENT), address(tokenA));
        (bool registryWrites,) = accessManager.hasRole(RolesLib.role(RolesLib.scopeOf(irs), RolesLib.AGENT), registry);
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
        bytes32 storageNamespace = RolesLib.scopeOf(address(irs));
        accessManager.grantRole(RolesLib.role(storageNamespace, RolesLib.AGENT_ADMIN), address(this), 0);
        accessManager.grantRole(RolesLib.role(storageNamespace, RolesLib.IRS_BINDER), address(this), 0);
    }

    function _grantAllAgentRoles(address account, bytes32 scope) private {
        accessManager.grantRole(RolesLib.role(scope, RolesLib.AGENT_ADMIN), address(this), 0);
        bytes32[8] memory names = _agentRoles();
        for (uint256 i = 0; i < names.length; i++) {
            accessManager.grantRole(RolesLib.role(scope, names[i]), account, 0);
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
