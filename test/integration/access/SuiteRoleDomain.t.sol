// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { KeyManager } from "@onchain-id/solidity/contracts/KeyManager.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { ITREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract SuiteRoleDomainTest is TREXSuiteTest {

    uint32 internal constant TEAM = 5;
    uint32 internal constant DOMAIN_A = 10;
    uint32 internal constant DOMAIN_B = 20;
    Token internal tokenA;
    Token internal tokenB;
    TREXAccessManager internal registry;
    address internal agentA = makeAddr("agentA");
    address internal agentB = makeAddr("agentB");

    function setUp() public override {
        super.setUp();
        tokenA = _deployBare("ns-a", address(0), address(accessManager));
        tokenB = _deployBare("ns-b", address(0), address(accessManager));
        registry = TREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TREXAccessManager()),
                    abi.encodeCall(AccessManagerUpgradeable.initialize, (address(this)))
                )
            )
        );
    }

    function testFuzz_forDomain_PacksAndDecodes(uint32 domainId, uint8 roleIndex) public pure {
        vm.assume(domainId != 0 && domainId != RolesLib.PLATFORM_DOMAIN);
        RolesLib.Role role = RolesLib.Role(roleIndex % (uint8(type(RolesLib.Role).max) + 1));
        uint64 id = RolesLib.forDomain(domainId, role);
        (uint32 decodedDomain, uint32 decodedRole, bool custom) = RolesLib.decode(id);
        assertEq(decodedDomain, domainId);
        assertEq(decodedRole, uint32(role) + RolesLib.ROLE_NUMBER_OFFSET);
        assertFalse(custom);
        assertNotEq(id, 0);
    }

    function test_forDomain_DistinctAcrossDomainsAndRoles() public pure {
        assertNotEq(
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_MINTER),
            RolesLib.forDomain(DOMAIN_B, RolesLib.Role.AGENT_MINTER)
        );
        assertNotEq(
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_MINTER),
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_BURNER)
        );
    }

    function test_forDomain_CustomRoleIsFlaggedAndDistinctFromStandardRoles() public pure {
        uint64 custom = RolesLib.forDomain(DOMAIN_A, bytes32("COMPLIANCE_OFFICER"));
        (uint32 domainId, uint32 role, bool isCustom) = RolesLib.decode(custom);
        assertEq(domainId, DOMAIN_A);
        assertTrue(isCustom);
        assertTrue(role & RolesLib.CUSTOM_ROLE_FLAG != 0);
        for (uint8 i = 0; i <= uint8(type(RolesLib.Role).max); i++) {
            assertNotEq(custom, RolesLib.forDomain(DOMAIN_A, RolesLib.Role(i)));
        }
        assertEq(custom, RolesLib.forDomain(DOMAIN_A, bytes32("COMPLIANCE_OFFICER")));
        assertNotEq(custom, RolesLib.forDomain(DOMAIN_A, bytes32("AUDITOR")));
    }

    function test_forDomain_RevertWhen_DomainIsZero() public {
        vm.expectRevert(ErrorsLib.InvalidDomain.selector);
        this.packExternally(0, RolesLib.Role.AGENT);
    }

    function testFuzz_forDomain_RevertWhen_DomainIsThePlatformDomain(uint8 roleIndex, bytes32 customName) public {
        RolesLib.Role role = RolesLib.Role(roleIndex % (uint8(type(RolesLib.Role).max) + 1));
        vm.expectRevert(ErrorsLib.InvalidDomain.selector);
        this.packExternally(RolesLib.PLATFORM_DOMAIN, role);
        vm.expectRevert(ErrorsLib.InvalidDomain.selector);
        this.packCustomExternally(RolesLib.PLATFORM_DOMAIN, customName);
    }

    function test_platform_RolesLiveInTheReservedDomainOnly() public pure {
        (uint32 domainId,,) = RolesLib.decode(RolesLib.platform(RolesLib.PlatformRole.VERSION_MANAGER));
        assertEq(domainId, RolesLib.PLATFORM_DOMAIN);
        assertNotEq(RolesLib.platform(RolesLib.PlatformRole.OWNER), RolesLib.forDomain(DOMAIN_A, RolesLib.Role.OWNER));
    }

    function packExternally(uint32 domainId, RolesLib.Role role) external pure returns (uint64) {
        return RolesLib.forDomain(domainId, role);
    }

    function packCustomExternally(uint32 domainId, bytes32 customName) external pure returns (uint64) {
        return RolesLib.forDomain(domainId, customName);
    }

    function test_explicitDomain_AgentOfAOperatesAOnly() public {
        _commission(tokenA, DOMAIN_A);
        _commission(tokenB, DOMAIN_B);
        _grantAllAgentRoles(accessManager, agentA, DOMAIN_A);

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

    function test_explicitDomain_AgentOfBOperatesBOnly() public {
        _commission(tokenA, DOMAIN_A);
        _commission(tokenB, DOMAIN_B);
        _grantAllAgentRoles(accessManager, agentB, DOMAIN_B);

        vm.startPrank(agentB);
        tokenB.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        tokenB.unpause();
        tokenB.mint(alice, 5);
        vm.stopPrank();
        assertEq(tokenB.balanceOf(alice), 5);

        _assertLockedOut(agentB, tokenA);
    }

    function test_explicitDomain_TwoTokensInOneDomainShareOneTeam() public {
        _commissionIntoTeam(tokenA);
        _commissionIntoTeam(tokenB);
        _grantAllAgentRoles(accessManager, agentA, TEAM);

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

    function test_explicitDomain_MapsEverySuiteContractIntoTheDomain() public {
        _commission(tokenA, DOMAIN_A);
        address suiteRegistry = address(tokenA.identityRegistry());
        address irs = address(tokenA.identityRegistry().identityStorage());
        address mc = address(tokenA.compliance());

        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_MINTER)
        );
        assertEq(
            accessManager.getTargetFunctionRole(suiteRegistry, IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT)
        );
        assertEq(
            accessManager.getTargetFunctionRole(irs, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.IRS_WRITER)
        );
        assertEq(
            accessManager.getTargetFunctionRole(mc, IModularCompliance.addModule.selector),
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.OWNER)
        );
        assertEq(
            accessManager.getRoleAdmin(RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT)),
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_ADMIN)
        );
        (bool tokenIsAgent,) = accessManager.hasRole(RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT), address(tokenA));
        (bool registryWrites,) =
            accessManager.hasRole(RolesLib.forDomain(DOMAIN_A, RolesLib.Role.IRS_WRITER), suiteRegistry);
        assertTrue(tokenIsAgent);
        assertTrue(registryWrites);
    }

    function test_explicitDomain_StorageWriterStaysUnderAdminRole() public {
        _commission(tokenA, DOMAIN_A);
        uint64 writer = RolesLib.forDomain(DOMAIN_A, RolesLib.Role.IRS_WRITER);
        uint64 agentAdmin = RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_ADMIN);
        accessManager.grantRole(agentAdmin, agentA, 0);

        assertEq(accessManager.getRoleAdmin(writer), 0);
        vm.prank(agentA);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, agentA, uint64(0))
        );
        accessManager.grantRole(writer, agentB, 0);
    }

    function test_registry_CommissionUsesTheAssignedDomain() public {
        Token fundToken = _deployBare("fund-a", address(0), address(registry));
        uint32 fund = registry.createDomain("Fund A");
        registry.assign(fund, address(fundToken));
        address irs = address(fundToken.identityRegistry().identityStorage());

        AccessManagerSetupLib.commissionSuite(registry, address(fundToken));

        assertEq(registry.domainName(fund), "Fund A");
        assertEq(registry.domainOf(irs), fund);
        assertEq(
            registry.getTargetFunctionRole(address(fundToken), IERC3643.mint.selector),
            RolesLib.forDomain(fund, RolesLib.Role.AGENT_MINTER)
        );
        assertEq(
            registry.getTargetFunctionRole(irs, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.forDomain(fund, RolesLib.Role.IRS_WRITER)
        );
        _grantAllAgentRoles(registry, agentA, fund);
        vm.startPrank(agentA);
        fundToken.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        fundToken.unpause();
        fundToken.mint(alice, 3);
        vm.stopPrank();
        assertEq(fundToken.balanceOf(alice), 3);
    }

    function test_registry_RevertWhen_TokenIsNotAssigned() public {
        Token fundToken = _deployBare("fund-x", address(0), address(registry));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAssigned.selector, address(fundToken)));
        this.commissionExternally(address(fundToken));
    }

    function commissionExternally(address token) external {
        AccessManagerSetupLib.commissionSuite(registry, token);
    }

    function test_registry_ShareClassesOfOneFundShareOneTeam() public {
        Token classA = _deployBare("class-a", address(0), address(registry));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(classA.identityRegistry().identityStorage()));
        Token classB = _deployBare("class-b", address(irs), address(registry));
        uint32 fund = registry.createDomain("Fund");
        registry.assign(fund, address(classA));
        registry.assign(fund, address(classB));
        AccessManagerSetupLib.commissionSuite(registry, address(classA));
        _grantStorageBinder(registry, fund);
        AccessManagerSetupLib.commissionSuite(registry, address(classB));
        _grantAllAgentRoles(registry, agentA, fund);

        vm.startPrank(agentA);
        classA.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        classB.identityRegistry().registerIdentity(bob, bobIdentity, 0);
        classA.unpause();
        classB.unpause();
        classA.mint(alice, 1);
        classB.mint(bob, 2);
        vm.stopPrank();
        assertEq(classA.balanceOf(alice), 1);
        assertEq(classB.balanceOf(bob), 2);
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertEq(address(irs.storedIdentity(bob)), address(bobIdentity));
        assertTrue(_isBound(irs, address(classB.identityRegistry())));
        _assertCannotTouchStorage(agentA, irs);
    }

    function test_registry_ReusedStorageKeepsItsDomainAcrossFunds() public {
        Token tokenX = _deployBare("fund-x", address(0), address(registry));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("fund-y", address(irs), address(registry));
        uint32 fundX = registry.createDomain("Fund X");
        uint32 fundY = registry.createDomain("Fund Y");
        registry.assign(fundX, address(tokenX));
        registry.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(registry, address(tokenX));
        _grantStorageBinder(registry, fundX);
        AccessManagerSetupLib.commissionSuite(registry, address(tokenY));

        assertEq(registry.domainOf(address(irs)), fundX);
        assertEq(
            registry.getTargetFunctionRole(address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.forDomain(fundX, RolesLib.Role.IRS_WRITER)
        );
        (bool registryYWrites,) =
            registry.hasRole(RolesLib.forDomain(fundX, RolesLib.Role.IRS_WRITER), address(tokenY.identityRegistry()));
        assertTrue(registryYWrites);

        _grantAllAgentRoles(registry, agentA, fundX);
        _grantAllAgentRoles(registry, agentB, fundY);
        IERC3643IdentityRegistry registryX = tokenX.identityRegistry();
        IERC3643IdentityRegistry registryY = tokenY.identityRegistry();
        vm.prank(agentA);
        registryX.registerIdentity(alice, aliceIdentity, 0);
        vm.prank(agentB);
        registryY.registerIdentity(bob, bobIdentity, 0);
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertEq(address(irs.storedIdentity(bob)), address(bobIdentity));
        _assertLockedOut(agentA, tokenY);
        _assertLockedOut(agentB, tokenX);
        _assertCannotTouchStorage(agentA, irs);
        _assertCannotTouchStorage(agentB, irs);
    }

    function test_registry_BindsAReusedStorageAndRevertsWhenTheCallerCannotBind() public {
        Token tokenX = _deployBare("bind-x", address(0), address(registry));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("bind-y", address(irs), address(registry));
        uint32 fundX = registry.createDomain("Fund X");
        uint32 fundY = registry.createDomain("Fund Y");
        registry.assign(fundX, address(tokenX));
        registry.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(registry, address(tokenX));
        registry.grantRole(RolesLib.forDomain(fundX, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        assertFalse(_isBound(irs, address(tokenY.identityRegistry())));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        this.commissionExternally(address(tokenY));
        assertEq(registry.getTargetFunctionRole(address(tokenY), IERC3643.mint.selector), 0);

        registry.grantRole(RolesLib.forDomain(fundX, RolesLib.Role.IRS_BINDER), address(this), 0);
        AccessManagerSetupLib.commissionSuite(registry, address(tokenY));
        assertTrue(_isBound(irs, address(tokenY.identityRegistry())));
    }

    function test_migrate_Success_LocksAgentsOfAOutOfBOnASharedTeam() public {
        _commissionIntoTeam(tokenA);
        _commissionIntoTeam(tokenB);
        _grantAllAgentRoles(accessManager, agentA, TEAM);
        _grantAllAgentRoles(accessManager, agentB, TEAM);

        AccessManagerSetupLib.migrateSuitesToDomains(
            accessManager,
            _both(),
            TEAM,
            _domains(DOMAIN_A, DOMAIN_B),
            _assignAgentRoles(agentA, DOMAIN_A),
            _revokeAgentRoles(agentA)
        );
        _grantAllAgentRoles(accessManager, agentB, DOMAIN_B);

        _assertHoldsEveryAgentRole(agentA, DOMAIN_A);
        _assertHoldsNoAgentRole(agentA, TEAM);
        _assertHoldsNoAgentRole(agentA, DOMAIN_B);
        _assertHoldsEveryAgentRole(agentB, TEAM);
        _assertHoldsNoAgentRole(agentB, DOMAIN_A);

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

    function test_migrate_Success_PartialMigrationKeepsTheTeamRolesForAnUnmigratedSibling() public {
        _commissionIntoTeam(tokenA);
        _commissionIntoTeam(tokenB);
        _grantAllAgentRoles(accessManager, agentA, TEAM);
        _grantAllAgentRoles(accessManager, agentB, TEAM);

        AccessManagerSetupLib.migrateSuitesToDomains(
            accessManager,
            _only(tokenA),
            TEAM,
            _domains(DOMAIN_A),
            _assignAgentRoles(agentA, DOMAIN_A),
            _noRevocations()
        );

        _assertHoldsEveryAgentRole(agentA, DOMAIN_A);
        _assertHoldsEveryAgentRole(agentA, TEAM);
        _assertHoldsEveryAgentRole(agentB, TEAM);

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

    function test_migrate_Success_ExplicitRevocationRemovesTheSourceRoleAndKeepsTheNewOne() public {
        _commissionIntoTeam(tokenA);
        accessManager.grantRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_MINTER), agentA, 0);
        accessManager.grantRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_BURNER), agentA, 0);

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](1);
        assignments[0] = _assign(agentA, RolesLib.Role.AGENT_MINTER, DOMAIN_A);
        AccessManagerSetupLib.RoleRevocation[] memory revocations = new AccessManagerSetupLib.RoleRevocation[](1);
        revocations[0] = _revoke(agentA, RolesLib.Role.AGENT_MINTER);
        AccessManagerSetupLib.migrateSuitesToDomains(
            accessManager, _only(tokenA), TEAM, _domains(DOMAIN_A), assignments, revocations
        );

        (bool newMinter,) = accessManager.hasRole(RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_MINTER), agentA);
        (bool oldMinter,) = accessManager.hasRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_MINTER), agentA);
        (bool oldBurner,) = accessManager.hasRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_BURNER), agentA);
        (bool newBurner,) = accessManager.hasRole(RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_BURNER), agentA);
        assertTrue(newMinter);
        assertFalse(oldMinter);
        assertTrue(oldBurner);
        assertFalse(newBurner);
    }

    function test_migrate_Success_SameAccountDifferentRolesOnDifferentSuites() public {
        _commissionIntoTeam(tokenA);
        _commissionIntoTeam(tokenB);
        _grantAllAgentRoles(accessManager, agentA, TEAM);

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](6);
        assignments[0] = _assign(agentA, RolesLib.Role.AGENT, DOMAIN_A);
        assignments[1] = _assign(agentA, RolesLib.Role.AGENT_PAUSER, DOMAIN_A);
        assignments[2] = _assign(agentA, RolesLib.Role.AGENT_MINTER, DOMAIN_A);
        assignments[3] = _assign(agentA, RolesLib.Role.AGENT, DOMAIN_B);
        assignments[4] = _assign(agentA, RolesLib.Role.AGENT_PAUSER, DOMAIN_B);
        assignments[5] = _assign(agentA, RolesLib.Role.AGENT_BURNER, DOMAIN_B);
        AccessManagerSetupLib.migrateSuitesToDomains(
            accessManager, _both(), TEAM, _domains(DOMAIN_A, DOMAIN_B), assignments, _revokeAgentRoles(agentA)
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
        _assertHoldsNoAgentRole(agentA, TEAM);
    }

    function test_migrate_Success_KeepsStructuralGrantsAndExecutionDelays() public {
        _commissionIntoTeam(tokenA);
        accessManager.grantRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_MINTER), agentA, 1 hours);
        address suiteRegistry = address(tokenA.identityRegistry());

        AccessManagerSetupLib.RoleAssignment[] memory assignments = new AccessManagerSetupLib.RoleAssignment[](1);
        assignments[0] = _assign(agentA, RolesLib.Role.AGENT_MINTER, DOMAIN_A);
        AccessManagerSetupLib.RoleRevocation[] memory revocations = new AccessManagerSetupLib.RoleRevocation[](1);
        revocations[0] = _revoke(agentA, RolesLib.Role.AGENT_MINTER);
        AccessManagerSetupLib.migrateSuitesToDomains(
            accessManager, _only(tokenA), TEAM, _domains(DOMAIN_A), assignments, revocations
        );

        (bool isMinter, uint32 delay) =
            accessManager.hasRole(RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_MINTER), agentA);
        assertTrue(isMinter);
        assertEq(delay, 1 hours);
        (bool tokenIsAgent,) = accessManager.hasRole(RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT), address(tokenA));
        (bool registryWrites,) =
            accessManager.hasRole(RolesLib.forDomain(TEAM, RolesLib.Role.IRS_WRITER), suiteRegistry);
        assertTrue(tokenIsAgent);
        assertTrue(registryWrites);
        (bool tokenStillInTeam,) = accessManager.hasRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT), address(tokenA));
        assertFalse(tokenStillInTeam);
        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forDomain(DOMAIN_A, RolesLib.Role.AGENT_MINTER)
        );
    }

    function test_migrate_Success_LeavesASharedStorageAloneSoBothRegistriesKeepWriting() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenA.identityRegistry().identityStorage()));
        Token tokenC = _deployBare("batch-c", address(irs), address(accessManager));
        _commissionIntoTeam(tokenA);
        _grantStorageBinder(accessManager, TEAM);
        _commissionIntoTeam(tokenC);
        _grantAllAgentRoles(accessManager, agentA, TEAM);
        _grantAllAgentRoles(accessManager, agentB, TEAM);

        AccessManagerSetupLib.migrateSuitesToDomains(
            accessManager,
            _only(tokenA),
            TEAM,
            _domains(DOMAIN_A),
            _assignAgentRoles(agentA, DOMAIN_A),
            _revokeAgentRoles(agentA)
        );

        assertEq(
            accessManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forDomain(TEAM, RolesLib.Role.IRS_WRITER)
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
        _commissionIntoTeam(tokenA);
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentB, RolesLib.Role.AGENT_MINTER, DOMAIN_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.RoleNotHeld.selector, agentB, RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_MINTER)
            )
        );
        this.migrateExternally(_only(tokenA), TEAM, _domains(DOMAIN_A), one, _noRevocations());
    }

    function test_migrate_RevertWhen_AHolderHasAPendingGrant() public {
        _commissionIntoTeam(tokenA);
        uint64 teamMinter = RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_MINTER);
        accessManager.setGrantDelay(teamMinter, 1 days);
        vm.warp(block.timestamp + 6 days);
        accessManager.grantRole(teamMinter, agentA, 0);
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentA, RolesLib.Role.AGENT_MINTER, DOMAIN_A);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PendingRoleGrant.selector, agentA, teamMinter));
        this.migrateExternally(_only(tokenA), TEAM, _domains(DOMAIN_A), one, _noRevocations());
    }

    function test_migrate_RevertWhen_AHolderHasAPendingDelayChange() public {
        _commissionIntoTeam(tokenA);
        uint64 teamMinter = RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_MINTER);
        accessManager.grantRole(teamMinter, agentA, 1 hours);
        accessManager.grantRole(teamMinter, agentA, 0);
        AccessManagerSetupLib.RoleAssignment[] memory one = new AccessManagerSetupLib.RoleAssignment[](1);
        one[0] = _assign(agentA, RolesLib.Role.AGENT_MINTER, DOMAIN_A);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PendingDelayChange.selector, agentA, teamMinter));
        this.migrateExternally(_only(tokenA), TEAM, _domains(DOMAIN_A), one, _noRevocations());
    }

    function test_migrate_RevertWhen_TokenHoldsNoAgentRoleInTheSourceDomain() public {
        _commission(tokenA, DOMAIN_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.RoleNotHeld.selector, address(tokenA), RolesLib.forDomain(TEAM, RolesLib.Role.AGENT)
            )
        );
        this.migrateExternally(_only(tokenA), TEAM, _domains(DOMAIN_B), _noAssignments(), _noRevocations());
    }

    function test_migrate_RevertWhen_ARevocationFailsLate_LeavesNothingChanged() public {
        _commissionIntoTeam(tokenA);
        _grantAllAgentRoles(accessManager, agentA, TEAM);
        uint64 teamAgentAdmin = RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_ADMIN);
        accessManager.revokeRole(teamAgentAdmin, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, address(this), teamAgentAdmin
            )
        );
        this.migrateExternally(
            _only(tokenA), TEAM, _domains(DOMAIN_A), _assignAgentRoles(agentA, DOMAIN_A), _revokeAgentRoles(agentA)
        );

        assertEq(
            accessManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_MINTER)
        );
        _assertHoldsEveryAgentRole(agentA, TEAM);
        _assertHoldsNoAgentRole(agentA, DOMAIN_A);
    }

    function migrateExternally(
        address[] memory tokens,
        uint32 fromDomainId,
        uint32[] memory toDomainIds,
        AccessManagerSetupLib.RoleAssignment[] memory assignments,
        AccessManagerSetupLib.RoleRevocation[] memory revocations
    ) external {
        AccessManagerSetupLib.migrateSuitesToDomains(
            accessManager, tokens, fromDomainId, toDomainIds, assignments, revocations
        );
    }

    function _assign(address account, RolesLib.Role role, uint32 domainId)
        private
        pure
        returns (AccessManagerSetupLib.RoleAssignment memory)
    {
        return AccessManagerSetupLib.RoleAssignment({ account: account, role: role, domainId: domainId });
    }

    function _revoke(address account, RolesLib.Role role)
        private
        pure
        returns (AccessManagerSetupLib.RoleRevocation memory)
    {
        return AccessManagerSetupLib.RoleRevocation({ account: account, role: role });
    }

    function _assignAgentRoles(address account, uint32 domainId)
        private
        pure
        returns (AccessManagerSetupLib.RoleAssignment[] memory assignments)
    {
        RolesLib.Role[8] memory roles = _agentRoles();
        assignments = new AccessManagerSetupLib.RoleAssignment[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            assignments[i] = _assign(account, roles[i], domainId);
        }
    }

    function _revokeAgentRoles(address account)
        private
        pure
        returns (AccessManagerSetupLib.RoleRevocation[] memory revocations)
    {
        RolesLib.Role[8] memory roles = _agentRoles();
        revocations = new AccessManagerSetupLib.RoleRevocation[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            revocations[i] = _revoke(account, roles[i]);
        }
    }

    function _noAssignments() private pure returns (AccessManagerSetupLib.RoleAssignment[] memory) {
        return new AccessManagerSetupLib.RoleAssignment[](0);
    }

    function _noRevocations() private pure returns (AccessManagerSetupLib.RoleRevocation[] memory) {
        return new AccessManagerSetupLib.RoleRevocation[](0);
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

    function _domains(uint32 first) private pure returns (uint32[] memory domainIds) {
        domainIds = new uint32[](1);
        domainIds[0] = first;
    }

    function _domains(uint32 first, uint32 second) private pure returns (uint32[] memory domainIds) {
        domainIds = new uint32[](2);
        domainIds[0] = first;
        domainIds[1] = second;
    }

    function _assertHoldsEveryAgentRole(address account, uint32 domainId) private view {
        RolesLib.Role[8] memory roles = _agentRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            (bool isMember,) = accessManager.hasRole(RolesLib.forDomain(domainId, roles[i]), account);
            assertTrue(isMember);
        }
    }

    function _assertHoldsNoAgentRole(address account, uint32 domainId) private view {
        RolesLib.Role[8] memory roles = _agentRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            (bool isMember,) = accessManager.hasRole(RolesLib.forDomain(domainId, roles[i]), account);
            assertFalse(isMember);
        }
    }

    function _agentRoles() private pure returns (RolesLib.Role[8] memory) {
        return [
            RolesLib.Role.AGENT,
            RolesLib.Role.AGENT_MINTER,
            RolesLib.Role.AGENT_BURNER,
            RolesLib.Role.AGENT_PARTIAL_FREEZER,
            RolesLib.Role.AGENT_ADDRESS_FREEZER,
            RolesLib.Role.AGENT_RECOVERY_ADDRESS,
            RolesLib.Role.AGENT_FORCED_TRANSFER,
            RolesLib.Role.AGENT_PAUSER
        ];
    }

    function _allowRecoveryTo(IIdentity identity, address newWallet) private {
        bytes memory signerData = abi.encodePacked(newWallet);
        vm.prank(alice);
        KeyManager(address(identity)).addKeyWithData(keccak256(signerData), 1, 1, signerData, "");
    }

    function _assertLockedOut(address agentAccount, Token other) private {
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentAccount);
        IERC3643IdentityRegistry otherRegistry = other.identityRegistry();

        vm.startPrank(agentAccount);
        vm.expectRevert(unauthorized);
        otherRegistry.registerIdentity(alice, aliceIdentity, 0);
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

    function _assertCannotTouchStorage(address agentAccount, IdentityRegistryStorage irs) private {
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentAccount);
        vm.startPrank(agentAccount);
        vm.expectRevert(unauthorized);
        irs.addIdentityToStorage(another, aliceIdentity, 0);
        vm.expectRevert(unauthorized);
        irs.modifyStoredIdentity(alice, bobIdentity);
        vm.expectRevert(unauthorized);
        irs.removeIdentityFromStorage(bob);
        vm.stopPrank();
    }

    function _commission(Token target, uint32 domainId) private {
        AccessManagerSetupLib.commissionSuite(accessManager, address(target), domainId, domainId);
    }

    function _commissionIntoTeam(Token target) private {
        AccessManagerSetupLib.commissionSuite(accessManager, address(target), TEAM, TEAM);
        accessManager.grantRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_ADMIN), address(this), 0);
    }

    function _grantStorageBinder(IAccessManager manager, uint32 domainId) private {
        manager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        manager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.IRS_BINDER), address(this), 0);
    }

    function _grantAllAgentRoles(IAccessManager manager, address account, uint32 domainId) private {
        manager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        RolesLib.Role[8] memory roles = _agentRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            manager.grantRole(RolesLib.forDomain(domainId, roles[i]), account, 0);
        }
    }

    function _isBound(IdentityRegistryStorage irs, address suiteRegistry) private view returns (bool) {
        address[] memory linked = irs.linkedIdentityRegistries();
        for (uint256 i = 0; i < linked.length; i++) {
            if (linked[i] == suiteRegistry) {
                return true;
            }
        }
        return false;
    }

    function _deployBare(string memory salt, address irs, address manager) private returns (Token) {
        ITREXFactory.TokenDetails memory details = ITREXFactory.TokenDetails({
            name: salt,
            symbol: salt,
            decimals: 0,
            irs: irs,
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
