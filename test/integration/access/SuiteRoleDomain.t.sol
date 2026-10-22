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
    TREXAccessManager internal domainManager;
    address internal agentA = makeAddr("agentA");
    address internal agentB = makeAddr("agentB");

    function setUp() public override {
        super.setUp();
        tokenA = _deployBare("ns-a", address(0), address(accessManager));
        tokenB = _deployBare("ns-b", address(0), address(accessManager));
        domainManager = TREXAccessManager(
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
        assertEq(role & RolesLib.CUSTOM_ROLE_FLAG, 0);
        assertEq(
            role, uint32(uint256(keccak256(abi.encode(bytes32("COMPLIANCE_OFFICER"))))) & ~RolesLib.CUSTOM_ROLE_FLAG
        );
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

    function test_explicitDomain_MapsEveryTableEntry() public {
        _commission(tokenA, DOMAIN_A);
        _assertTableMapped(address(tokenA), AccessManagerSetupLib.tokenTable(), DOMAIN_A);
        _assertTableMapped(address(tokenA.identityRegistry()), AccessManagerSetupLib.registryTable(), DOMAIN_A);
        _assertTableMapped(
            address(tokenA.identityRegistry().identityStorage()), AccessManagerSetupLib.storageTable(), DOMAIN_A
        );
        _assertTableMapped(address(tokenA.compliance()), AccessManagerSetupLib.complianceTable(), DOMAIN_A);
    }

    function _assertTableMapped(address target, AccessManagerSetupLib.SelectorRole[] memory table, uint32 domainId)
        private
        view
    {
        for (uint256 i = 0; i < table.length; i++) {
            assertEq(
                accessManager.getTargetFunctionRole(target, table[i].selector),
                RolesLib.forDomain(domainId, table[i].role)
            );
        }
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
        Token fundToken = _deployBare("fund-a", address(0), address(domainManager));
        uint32 fund = domainManager.createDomain("Fund A");
        domainManager.assign(fund, address(fundToken));
        address irs = address(fundToken.identityRegistry().identityStorage());

        AccessManagerSetupLib.commissionSuite(domainManager, address(fundToken));

        assertEq(domainManager.domainName(fund), "Fund A");
        assertEq(domainManager.domainOf(irs), fund);
        assertEq(
            domainManager.getTargetFunctionRole(address(fundToken), IERC3643.mint.selector),
            RolesLib.forDomain(fund, RolesLib.Role.AGENT_MINTER)
        );
        assertEq(
            domainManager.getTargetFunctionRole(irs, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.forDomain(fund, RolesLib.Role.IRS_WRITER)
        );
        _grantAllAgentRoles(domainManager, agentA, fund);
        vm.startPrank(agentA);
        fundToken.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        fundToken.unpause();
        fundToken.mint(alice, 3);
        vm.stopPrank();
        assertEq(fundToken.balanceOf(alice), 3);
    }

    function test_registry_RevertWhen_TokenIsNotAssigned() public {
        Token fundToken = _deployBare("fund-x", address(0), address(domainManager));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAssigned.selector, address(fundToken)));
        this.commissionExternally(address(fundToken));
    }

    function commissionExternally(address token) external {
        AccessManagerSetupLib.commissionSuite(domainManager, token);
    }

    /// @dev The pure form, called on the manager as a plain `IAccessManager`.
    function commissionPureFormExternally(address token, uint32 domainId) external {
        AccessManagerSetupLib.commissionSuite(IAccessManager(address(domainManager)), token, domainId);
    }

    /// @dev Two suites in two domains, each commissioned with its own storage, and then Y's registry bound to
    ///      X's storage by hand, the one way left to put a registry of another domain on a storage: X's
    ///      `IRS_BINDER` binds it, and Y's `OWNER` points the registry at it. Alice holds 100 of X.
    function _twoDomainsOneStorageBoundByHand()
        private
        returns (Token tokenX, Token tokenY, IdentityRegistryStorage irs, uint32 fundY)
    {
        tokenX = _deployBare("seize-x", address(0), address(domainManager));
        tokenY = _deployBare("seize-y", address(0), address(domainManager));
        irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        uint32 fundX = domainManager.createDomain("Fund X");
        fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        domainManager.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenY));

        _grantAllAgentRoles(domainManager, agentA, fundX);
        vm.startPrank(agentA);
        tokenX.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        tokenX.unpause();
        tokenX.mint(alice, 100);
        vm.stopPrank();

        IERC3643IdentityRegistry registryY = tokenY.identityRegistry();
        _grantStorageBinder(domainManager, fundX);
        irs.bindIdentityRegistry(address(registryY));
        domainManager.grantRole(RolesLib.forDomain(fundY, RolesLib.Role.OWNER), address(this), 0);
        registryY.setIdentityRegistryStorage(address(irs));
        assertEq(address(registryY.identityStorage()), address(irs));
    }

    function test_registry_ShareClassesOfOneFundShareOneTeam() public {
        Token classA = _deployBare("class-a", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(classA.identityRegistry().identityStorage()));
        Token classB = _deployBare("class-b", address(irs), address(domainManager));
        uint32 fund = domainManager.createDomain("Fund");
        domainManager.assign(fund, address(classA));
        domainManager.assign(fund, address(classB));
        AccessManagerSetupLib.commissionSuite(domainManager, address(classA));
        _grantStorageBinder(domainManager, fund);
        AccessManagerSetupLib.commissionSuite(domainManager, address(classB));
        _grantAllAgentRoles(domainManager, agentA, fund);

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
        assertTrue(irs.isIdentityRegistryBound(address(classB.identityRegistry())));
        _assertCannotTouchStorage(agentA, irs);
    }

    /// @notice A storage belongs to one domain. Commissioning a second domain's token onto it is refused, so
    ///         no registry of another domain ever writes into it.
    function test_registry_RevertWhen_StorageIsAlreadyInAnotherDomain() public {
        Token tokenX = _deployBare("fund-x", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("fund-y", address(irs), address(domainManager));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        domainManager.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        _grantStorageBinder(domainManager, fundX);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.StorageInAnotherDomain.selector, address(irs), fundX));
        this.commissionExternally(address(tokenY));

        // Nothing of Y's suite was set up, and Y's registry cannot write into X's storage.
        assertEq(domainManager.getTargetFunctionRole(address(tokenY), IERC3643.mint.selector), 0);
        assertFalse(irs.isIdentityRegistryBound(address(tokenY.identityRegistry())));
        (bool registryYWritesInX,) = domainManager.hasRole(
            RolesLib.forDomain(fundX, RolesLib.Role.IRS_WRITER), address(tokenY.identityRegistry())
        );
        assertFalse(registryYWritesInX);
        (bool registryYWritesInY,) = domainManager.hasRole(
            RolesLib.forDomain(fundY, RolesLib.Role.IRS_WRITER), address(tokenY.identityRegistry())
        );
        assertFalse(registryYWritesInY);
    }

    /// @notice The pure form reads the domain from the storage's own rows, so calling it on the manager with
    ///         another domain is refused the same way: the storage's rows stay in X, and X's registry keeps
    ///         writing.
    function test_registry_RevertWhen_PureFormPointsAStorageAtAnotherDomain() public {
        Token tokenX = _deployBare("pure-x", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("pure-y", address(irs), address(domainManager));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.StorageInAnotherDomain.selector, address(irs), fundX));
        this.commissionPureFormExternally(address(tokenY), fundY);

        assertEq(
            domainManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forDomain(fundX, RolesLib.Role.IRS_WRITER)
        );
        _assertWritesOnlyInDomain(address(tokenX.identityRegistry()), fundX);
    }

    /// @notice A bare `assign` of the storage to another domain does not move it: its rows still say X, so
    ///         commissioning Y's token onto it is refused even though the manager's record now says Y.
    function test_registry_RevertWhen_StorageIsReassignedByHandToAnotherDomain() public {
        Token tokenX = _deployBare("reassign-x", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("reassign-y", address(irs), address(domainManager));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        domainManager.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        _grantStorageBinder(domainManager, fundX);

        domainManager.assign(fundY, address(irs));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.StorageInAnotherDomain.selector, address(irs), fundX));
        this.commissionExternally(address(tokenY));

        assertEq(domainManager.getTargetFunctionRole(address(tokenY), IERC3643.mint.selector), 0);
        assertFalse(irs.isIdentityRegistryBound(address(tokenY.identityRegistry())));
    }

    /// @notice A registry of another domain bound to the storage by hand writes nothing: it holds `IRS_WRITER`
    ///         in its own domain, and the storage's rows ask for the storage's domain.
    function test_registry_RegistryOfAnotherDomainBoundByHandWritesNothing() public {
        (Token tokenX, Token tokenY, IdentityRegistryStorage irs, uint32 fundY) = _twoDomainsOneStorageBoundByHand();
        IERC3643IdentityRegistry registryY = tokenY.identityRegistry();
        bytes memory registryYRefused =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryY));
        _grantAllAgentRoles(domainManager, agentB, fundY);

        vm.startPrank(agentB);
        vm.expectRevert(registryYRefused);
        registryY.registerIdentity(charlie, charlieIdentity, 0);
        vm.expectRevert(registryYRefused);
        registryY.updateIdentity(alice, charlieIdentity);
        vm.expectRevert(registryYRefused);
        registryY.deleteIdentity(alice);
        vm.stopPrank();

        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertFalse(irs.isLocallyRegistered(charlie), "nothing was written for charlie");
        assertEq(address(tokenX.identityRegistry().identity(alice)), address(aliceIdentity));
    }

    /// @notice The audit's scenario, step by step: an agent of Y tries to register a wallet of theirs under a
    ///         holder of X, then to rebind that holder's wallet to an identity they control, then to move the
    ///         balance with `identityTransfer`. Every step fails and the holder keeps everything.
    function test_registry_AgentOfAnotherDomainCannotSeizeAHolder() public {
        (Token tokenX, Token tokenY, IdentityRegistryStorage irs, uint32 fundY) = _twoDomainsOneStorageBoundByHand();
        IERC3643IdentityRegistry registryY = tokenY.identityRegistry();
        bytes memory registryYRefused =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryY));
        _grantAllAgentRoles(domainManager, agentB, fundY);

        // 1. Register a recipient the agent controls under alice's identity, so it passes X's checks.
        vm.prank(agentB);
        vm.expectRevert(registryYRefused);
        registryY.registerIdentity(charlie, aliceIdentity, 0);

        // 2. Rebind alice's wallet to an identity the agent controls.
        vm.prank(agentB);
        vm.expectRevert(registryYRefused);
        registryY.updateIdentity(alice, charlieIdentity);

        // 3. Move alice's balance from that identity. Alice's wallet still answers to her own identity.
        vm.prank(address(charlieIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, alice, address(charlieIdentity)));
        tokenX.identityTransfer(alice, charlie, 100);

        assertEq(tokenX.balanceOf(alice), 100);
        assertEq(tokenX.balanceOf(charlie), 0);
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
    }

    /// @notice Two tokens of one domain, each with its own registry, still share one storage: both registries
    ///         write through that domain's `IRS_WRITER`, and the domain's agents reach both.
    function test_registry_TokensOfOneDomainShareOneStorage() public {
        Token tokenX = _deployBare("class-x", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("class-y", address(irs), address(domainManager));
        uint32 fund = domainManager.createDomain("Fund");
        domainManager.assign(fund, address(tokenX));
        domainManager.assign(fund, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        _grantStorageBinder(domainManager, fund);
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenY));

        assertEq(domainManager.domainOf(address(irs)), fund);
        assertTrue(irs.isIdentityRegistryBound(address(tokenY.identityRegistry())));
        _assertWritesOnlyInDomain(address(tokenX.identityRegistry()), fund);
        _assertWritesOnlyInDomain(address(tokenY.identityRegistry()), fund);

        _grantAllAgentRoles(domainManager, agentA, fund);
        vm.startPrank(agentA);
        tokenX.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        tokenY.identityRegistry().registerIdentity(bob, bobIdentity, 0);
        vm.stopPrank();
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertEq(address(irs.storedIdentity(bob)), address(bobIdentity));
        _assertCannotTouchStorage(agentA, irs);
    }

    /// @notice Whatever domain a suite is commissioned into, its registry holds `IRS_WRITER` there and nowhere
    ///         else.
    function test_registry_RegistryWritesThroughItsOwnDomainOnly() public {
        Token tokenX = _deployBare("own-x", address(0), address(domainManager));
        Token tokenY = _deployBare("own-y", address(0), address(domainManager));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        domainManager.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenY));

        _assertWritesOnlyInDomain(address(tokenX.identityRegistry()), fundX);
        _assertWritesOnlyInDomain(address(tokenY.identityRegistry()), fundY);
    }

    function test_registry_BindsAReusedStorageAndRevertsWhenTheCallerCannotBind() public {
        Token tokenX = _deployBare("bind-x", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("bind-y", address(irs), address(domainManager));
        uint32 fund = domainManager.createDomain("Fund");
        domainManager.assign(fund, address(tokenX));
        domainManager.assign(fund, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        domainManager.grantRole(RolesLib.forDomain(fund, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        assertFalse(irs.isIdentityRegistryBound(address(tokenY.identityRegistry())));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        this.commissionExternally(address(tokenY));
        assertEq(domainManager.getTargetFunctionRole(address(tokenY), IERC3643.mint.selector), 0);

        domainManager.grantRole(RolesLib.forDomain(fund, RolesLib.Role.IRS_BINDER), address(this), 0);
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenY));
        assertTrue(irs.isIdentityRegistryBound(address(tokenY.identityRegistry())));
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
        AccessManagerSetupLib.commissionSuite(accessManager, address(target), domainId);
    }

    function _commissionIntoTeam(Token target) private {
        AccessManagerSetupLib.commissionSuite(accessManager, address(target), TEAM);
        accessManager.grantRole(RolesLib.forDomain(TEAM, RolesLib.Role.AGENT_ADMIN), address(this), 0);
    }

    /// @dev `identityRegistry` holds `IRS_WRITER` in `domainId` and in no other domain the test created.
    function _assertWritesOnlyInDomain(address identityRegistry, uint32 domainId) private view {
        for (uint32 candidate = 1; candidate <= domainManager.domainCount(); candidate++) {
            (bool writes,) =
                domainManager.hasRole(RolesLib.forDomain(candidate, RolesLib.Role.IRS_WRITER), identityRegistry);
            assertEq(writes, candidate == domainId, "IRS_WRITER must land in the suite's own domain only");
        }
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
