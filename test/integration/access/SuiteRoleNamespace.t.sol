// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { KeyManager } from "@onchain-id/solidity/contracts/KeyManager.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

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

    function test_mixedModes_SharedSuiteJoiningAPerSuiteStorageKeepsTheStoragePerSuite() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("mixed-c", address(irs));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        _commission(tokenA, RolesLib.namespaceOf(address(tokenA)));
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_ADMIN, storageNamespace), address(this), 0);
        _commission(tokenC, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), address(this), 0);
        irs.bindIdentityRegistry(address(tokenC.identityRegistry()));

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

    function test_mixedModes_PerSuiteSuiteJoiningASharedStorageKeepsTheStorageShared() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("mixed-c", address(irs));
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));
        _grantIRSBinderRole(address(this));
        irs.bindIdentityRegistry(address(tokenC.identityRegistry()));

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.AGENT
        );
        _assertBothRegistriesWrite(tokenA, RolesLib.SHARED, tokenC, RolesLib.namespaceOf(address(tokenC)), irs);
        _assertLockedOut(agentB, tokenA);
        _assertLockedOut(agentA, tokenC);
    }

    function test_commissionSuite_RevertWhen_StorageCarriesAnUnknownPolicy() public {
        address irs = address(tokenA.identityRegistry().identityStorage());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RolesLib.COMMISSIONED;
        accessManager.setTargetFunctionRole(irs, selectors, 4242);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownStoragePolicy.selector, irs));
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
        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), address(this), 0);
        irs.bindIdentityRegistry(address(tokenC.identityRegistry()));
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

    function test_migrateSuitesToNamespaces_Success_LocksAgentsOfAOutOfBOnASharedManager() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        _grantAllAgentRoles(agentB, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 nsB = RolesLib.namespaceOf(address(tokenB));

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](2);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenA) });
        entitlements[1] = AccessManagerSetupLib.Entitlement({ account: agentB, token: address(tokenB) });
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, _both(), _namespaces(nsA, nsB), entitlements);

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

    function test_migrateSuitesToNamespaces_Success_HolderEntitledOnBothSuitesKeepsBoth() public {
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenB, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 nsB = RolesLib.namespaceOf(address(tokenB));

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](2);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenA) });
        entitlements[1] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenB) });
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, _both(), _namespaces(nsA, nsB), entitlements);

        _assertHoldsEveryAgentRole(agentA, nsA);
        _assertHoldsEveryAgentRole(agentA, nsB);
        _assertHoldsNoAgentRole(agentA, RolesLib.SHARED);

        IERC3643IdentityRegistry registryA = tokenA.identityRegistry();
        IERC3643IdentityRegistry registryB = tokenB.identityRegistry();
        vm.startPrank(agentA);
        registryA.registerIdentity(alice, aliceIdentity, 0);
        registryB.registerIdentity(alice, aliceIdentity, 0);
        tokenA.unpause();
        tokenB.unpause();
        tokenA.mint(alice, 1);
        tokenB.mint(alice, 2);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(alice), 1);
        assertEq(tokenB.balanceOf(alice), 2);
    }

    function test_migrateSuitesToNamespaces_Success_MovesOwnersAndAdministrators() public {
        _commission(tokenA, RolesLib.SHARED);
        address owner = makeAddr("owner");
        accessManager.grantRole(RolesLib.OWNER, owner, 0);
        accessManager.grantRole(RolesLib.AGENT_ADMIN, owner, 0);
        accessManager.grantRole(RolesLib.SUITE_ADMIN, owner, 0);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](1);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: owner, token: address(tokenA) });
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, _only(tokenA), _namespaces(nsA), entitlements);

        (bool globalOwner,) = accessManager.hasRole(RolesLib.OWNER, owner);
        (bool globalAgentAdmin,) = accessManager.hasRole(RolesLib.AGENT_ADMIN, owner);
        (bool globalSuiteAdmin,) = accessManager.hasRole(RolesLib.SUITE_ADMIN, owner);
        assertFalse(globalOwner);
        assertFalse(globalAgentAdmin);
        assertFalse(globalSuiteAdmin);

        TREXRegistry registryA = TREXRegistry(address(tokenA.identityRegistry()));
        vm.startPrank(owner);
        registryA.addClaimTopic(42);
        tokenA.compliance();
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), agentA, 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.TOKEN_MANAGER, nsA), agentA, 0);
        vm.stopPrank();
        assertEq(registryA.getClaimTopics().length, 1);
        (bool minter,) = accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), agentA);
        (bool tokenManager,) = accessManager.hasRole(RolesLib.forSuite(RolesLib.TOKEN_MANAGER, nsA), agentA);
        assertTrue(minter);
        assertTrue(tokenManager);

        IdentityRegistryStorage irs = IdentityRegistryStorage(address(registryA.identityStorage()));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));
        vm.startPrank(owner);
        irs.unbindIdentityRegistry(address(registryA));
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), agentA, 0);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.AGENT, storageNamespace), agentA, 0);
        vm.stopPrank();
        assertEq(irs.linkedIdentityRegistries().length, 0);
        vm.prank(agentA);
        irs.bindIdentityRegistry(address(registryA));
        assertEq(irs.linkedIdentityRegistries().length, 1);
        vm.prank(agentA);
        irs.addIdentityToStorage(alice, aliceIdentity, 0);
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
    }

    function test_migrateSuitesToNamespaces_Success_KeepsStructuralGrantsAndExecutionDelays() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 1 hours);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        address registry = address(tokenA.identityRegistry());
        address irs = address(tokenA.identityRegistry().identityStorage());

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](1);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenA) });
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, _only(tokenA), _namespaces(nsA), entitlements);

        (bool isMinter, uint32 delay) = accessManager.hasRole(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), agentA);
        assertTrue(isMinter);
        assertEq(delay, 1 hours);
        (bool stillGlobal,) = accessManager.hasRole(RolesLib.AGENT_MINTER, agentA);
        assertFalse(stillGlobal);

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

    function test_migrateSuitesToNamespaces_RevertWhen_TargetNamespaceIsShared() public {
        _commission(tokenA, RolesLib.SHARED);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidRoleNamespace.selector));
        this.migrateExternally(_only(tokenA), _namespaces(RolesLib.SHARED), new AccessManagerSetupLib.Entitlement[](0));
    }

    function test_migrateSuitesToNamespaces_RevertWhen_AHolderHasAPendingGlobalGrant() public {
        _commission(tokenA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        accessManager.setGrantDelay(RolesLib.AGENT_MINTER, 1 days);
        accessManager.setGrantDelay(RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA), 1 days);
        vm.warp(block.timestamp + 6 days);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 0);
        (bool activeYet,) = accessManager.hasRole(RolesLib.AGENT_MINTER, agentA);
        assertFalse(activeYet);

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](1);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenA) });
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PendingRoleGrant.selector, agentA, RolesLib.AGENT_MINTER));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), entitlements);
    }

    function test_migrateSuitesToNamespaces_RevertWhen_EntitlementNamesAnUnmigratedToken() public {
        _commission(tokenA, RolesLib.SHARED);
        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](1);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenB) });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EntitlementTokenNotMigrated.selector, address(tokenB)));
        this.migrateExternally(_only(tokenA), _namespaces(RolesLib.namespaceOf(address(tokenA))), entitlements);
    }

    function test_migrateSuitesToNamespaces_RevertWhen_ARevokeFailsAfterMutationsBegan_LeavesNothingChanged() public {
        _commission(tokenA, RolesLib.SHARED);
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        accessManager.setRoleAdmin(RolesLib.AGENT_PAUSER, 4242);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](1);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenA) });
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, address(this), 4242)
        );
        this.migrateExternally(_only(tokenA), _namespaces(nsA), entitlements);

        assertEq(accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector), RolesLib.AGENT_MINTER);
        _assertHoldsEveryAgentRole(agentA, RolesLib.SHARED);
        _assertHoldsNoAgentRole(agentA, nsA);
    }

    function test_migrateSuitesToNamespaces_Success_MovesASharedStorageWhenEverySuiteBoundToItIsInTheBatch() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("batch-c", address(irs));
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenC, RolesLib.SHARED);
        _grantIRSBinderRole(address(this));
        irs.bindIdentityRegistry(address(tokenC.identityRegistry()));
        address owner = makeAddr("owner");
        accessManager.grantRole(RolesLib.OWNER, owner, 0);
        accessManager.grantRole(RolesLib.AGENT_ADMIN, owner, 0);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        bytes32 nsC = RolesLib.namespaceOf(address(tokenC));
        bytes32 storageNamespace = RolesLib.namespaceOf(address(irs));

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](2);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: owner, token: address(tokenA) });
        entitlements[1] = AccessManagerSetupLib.Entitlement({ account: owner, token: address(tokenC) });
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, tokens, _namespaces(nsA, nsC), entitlements);

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forSuite(RolesLib.AGENT, storageNamespace)
        );
        (bool registryAWrites,) = accessManager.hasRole(
            RolesLib.forSuite(RolesLib.AGENT, storageNamespace), address(tokenA.identityRegistry())
        );
        (bool registryCWrites,) = accessManager.hasRole(
            RolesLib.forSuite(RolesLib.AGENT, storageNamespace), address(tokenC.identityRegistry())
        );
        assertTrue(registryAWrites);
        assertTrue(registryCWrites);
        (bool globalOwner,) = accessManager.hasRole(RolesLib.OWNER, owner);
        assertFalse(globalOwner);

        address registryC = address(tokenC.identityRegistry());
        vm.startPrank(owner);
        irs.unbindIdentityRegistry(registryC);
        accessManager.grantRole(RolesLib.forSuite(RolesLib.IRS_BINDER, storageNamespace), agentA, 0);
        vm.stopPrank();
        assertEq(irs.linkedIdentityRegistries().length, 1);
        vm.prank(agentA);
        irs.bindIdentityRegistry(registryC);
        assertEq(irs.linkedIdentityRegistries().length, 2);
    }

    function test_migrateSuitesToNamespaces_RevertWhen_GrantDelayNotPrepared_ThenSucceedsOncePrepared() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agentA, 0);
        accessManager.setGrantDelay(RolesLib.AGENT_MINTER, 1 days);
        vm.warp(block.timestamp + 6 days);
        assertEq(accessManager.getRoleGrantDelay(RolesLib.AGENT_MINTER), 1 days);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        uint64 namespacedMinter = RolesLib.forSuite(RolesLib.AGENT_MINTER, nsA);

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](1);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenA) });
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GrantDelayNotPrepared.selector, RolesLib.AGENT_MINTER, nsA));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), entitlements);

        accessManager.setGrantDelay(namespacedMinter, 1 days);
        vm.warp(block.timestamp + 6 days);
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, _only(tokenA), _namespaces(nsA), entitlements);

        assertEq(accessManager.getRoleGrantDelay(namespacedMinter), 1 days);
        (bool stillGlobal,) = accessManager.hasRole(RolesLib.AGENT_MINTER, agentA);
        assertFalse(stillGlobal);
        (bool activeYet,) = accessManager.hasRole(namespacedMinter, agentA);
        (uint48 since,,,) = accessManager.getAccess(namespacedMinter, agentA);
        assertFalse(activeYet);
        assertEq(since, block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days);
        (bool isMinter,) = accessManager.hasRole(namespacedMinter, agentA);
        assertTrue(isMinter);
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
        accessManager.setTargetFunctionRole(address(irs), bind, 4343);
        accessManager.setRoleAdmin(storageAgent, 4242);
        accessManager.grantRole(4242, address(this), 0);

        _commission(tokenC, RolesLib.namespaceOf(address(tokenC)));

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.bindIdentityRegistry.selector
            ),
            4343
        );
        assertEq(accessManager.getRoleAdmin(storageAgent), 4242);
        (bool registryCWrites,) = accessManager.hasRole(storageAgent, address(tokenC.identityRegistry()));
        assertTrue(registryCWrites);
    }

    function test_migrateSuitesToNamespaces_RevertWhen_StorageIsSharedWithASuiteOutsideTheBatch() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("outside-c", address(irs));
        _commission(tokenA, RolesLib.SHARED);
        _commission(tokenC, RolesLib.SHARED);
        _grantIRSBinderRole(address(this));
        irs.bindIdentityRegistry(address(tokenC.identityRegistry()));
        _grantAllAgentRoles(agentA, RolesLib.SHARED);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));

        AccessManagerSetupLib.Entitlement[] memory entitlements = new AccessManagerSetupLib.Entitlement[](1);
        entitlements[0] = AccessManagerSetupLib.Entitlement({ account: agentA, token: address(tokenA) });
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.StorageSharedOutsideBatch.selector, address(irs)));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), entitlements);

        assertEq(accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector), RolesLib.AGENT_MINTER);
        _assertHoldsEveryAgentRole(agentA, RolesLib.SHARED);
    }

    function test_migrateSuitesToNamespaces_RevertWhen_GrantDelayNotPreparedForARoleWithoutMembers() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setGrantDelay(RolesLib.AGENT_BURNER, 1 days);
        vm.warp(block.timestamp + 6 days);
        bytes32 nsA = RolesLib.namespaceOf(address(tokenA));
        uint64 namespacedBurner = RolesLib.forSuite(RolesLib.AGENT_BURNER, nsA);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GrantDelayNotPrepared.selector, RolesLib.AGENT_BURNER, nsA));
        this.migrateExternally(_only(tokenA), _namespaces(nsA), new AccessManagerSetupLib.Entitlement[](0));

        accessManager.setGrantDelay(namespacedBurner, 1 days);
        vm.warp(block.timestamp + 6 days);
        AccessManagerSetupLib.migrateSuitesToNamespaces(
            accessManager, _only(tokenA), _namespaces(nsA), new AccessManagerSetupLib.Entitlement[](0)
        );
        assertEq(accessManager.getTargetFunctionRole(address(tokenA), IERC3643.burn.selector), namespacedBurner);
        assertEq(accessManager.getRoleGrantDelay(namespacedBurner), 1 days);
    }

    function test_commissionSuite_Success_SharedModeLeavesExistingRoleAdministratorsUntouched() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setRoleAdmin(RolesLib.AGENT, 4242);
        accessManager.grantRole(4242, address(this), 0);

        _commission(tokenB, RolesLib.SHARED);

        assertEq(accessManager.getRoleAdmin(RolesLib.AGENT), 4242);
        (bool tokenBIsAgent,) = accessManager.hasRole(RolesLib.AGENT, address(tokenB));
        assertTrue(tokenBIsAgent);
    }

    function test_commissionSuite_Success_SharedModeKeepsAdministratorsExplicitlySetToAdminRole() public {
        _commission(tokenA, RolesLib.SHARED);
        accessManager.setRoleAdmin(RolesLib.AGENT, 0);
        accessManager.setRoleAdmin(RolesLib.AGENT_MINTER, 4242);

        _commission(tokenB, RolesLib.SHARED);

        assertEq(accessManager.getRoleAdmin(RolesLib.AGENT), 0);
        assertEq(accessManager.getRoleAdmin(RolesLib.AGENT_MINTER), 4242);
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

    function migrateExternally(
        address[] memory tokens,
        bytes32[] memory namespaces,
        AccessManagerSetupLib.Entitlement[] memory entitlements
    ) external {
        AccessManagerSetupLib.migrateSuitesToNamespaces(accessManager, tokens, namespaces, entitlements);
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
