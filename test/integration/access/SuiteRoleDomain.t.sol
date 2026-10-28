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
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";
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

    /// @notice After suite setup, every batch has a row of its own on the role of its single-item function, so
    ///         it takes the full check, scheduled operations included, rather than the immediate-only fallback.
    function test_explicitDomain_EveryBatchHasTheRoleOfItsSingleItemFunction() public {
        _commission(tokenA, DOMAIN_A);
        address token = address(tokenA);
        _assertBatchRole(token, IERC3643.batchMint.selector, IERC3643.mint.selector);
        _assertBatchRole(token, IERC3643.batchBurn.selector, IERC3643.burn.selector);
        _assertBatchRole(token, IERC3643.batchFreezePartialTokens.selector, IERC3643.freezePartialTokens.selector);
        _assertBatchRole(token, IERC3643.batchUnfreezePartialTokens.selector, IERC3643.unfreezePartialTokens.selector);
        _assertBatchRole(token, IERC3643.batchSetAddressFrozen.selector, IERC3643.setAddressFrozen.selector);
        _assertBatchRole(token, IERC3643.batchForcedTransfer.selector, IERC3643.forcedTransfer.selector);
        _assertBatchRole(
            address(tokenA.identityRegistry()),
            IERC3643IdentityRegistry.batchRegisterIdentity.selector,
            IERC3643IdentityRegistry.registerIdentity.selector
        );
    }

    function _assertBatchRole(address target, bytes4 batchSelector, bytes4 singleItemSelector) private view {
        uint64 singleItemRole = accessManager.getTargetFunctionRole(target, singleItemSelector);
        assertNotEq(singleItemRole, accessManager.ADMIN_ROLE(), "single-item function is mapped");
        assertEq(accessManager.getTargetFunctionRole(target, batchSelector), singleItemRole);
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

    /// @dev The setup of the audit's scenario: two tokens of two domains, and Y deployed on X's storage.
    struct TwoDomainsOneStorage {
        Token tokenX;
        Token tokenY;
        IdentityRegistryStorage irs;
        uint32 fundX;
        uint32 fundY;
    }

    /// @dev Token X is commissioned into fund X and alice holds 100 of it. Token Y is deployed on X's storage
    ///      and assigned to fund Y, but not commissioned: that is the step the tests then try.
    function _twoDomainsOneStorage() private returns (TwoDomainsOneStorage memory s) {
        s.tokenX = _deployBare("seize-x", address(0), address(domainManager));
        s.irs = IdentityRegistryStorage(address(s.tokenX.identityRegistry().identityStorage()));
        s.tokenY = _deployBare("seize-y", address(s.irs), address(domainManager));
        s.fundX = domainManager.createDomain("Fund X");
        s.fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(s.fundX, address(s.tokenX));
        domainManager.assign(s.fundY, address(s.tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(s.tokenX));

        _grantAllAgentRoles(domainManager, agentA, s.fundX);
        vm.startPrank(agentA);
        s.tokenX.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        s.tokenX.unpause();
        s.tokenX.mint(alice, 100);
        vm.stopPrank();
    }

    /// @dev Sets Y's suite up in fund Y by hand, table by table, which is what `commissionSuite` would do if it
    ///      did not refuse X's storage. Then X's `IRS_BINDER` binds Y's registry to X's storage. This is the
    ///      one way left to put a registry of another domain on a storage, and it takes the admin plus X's
    ///      binder to do it.
    function _setUpYByHandOnXsStorage(TwoDomainsOneStorage memory s) private {
        address registryY = address(s.tokenY.identityRegistry());
        // The two grants come first, as in `commissionSuite`: once the role admins are set, `AGENT` is handed
        // out by `AGENT_ADMIN`, which the admin does not hold.
        domainManager.grantRole(RolesLib.forDomain(s.fundY, RolesLib.Role.AGENT), address(s.tokenY), 0);
        domainManager.grantRole(RolesLib.forDomain(s.fundY, RolesLib.Role.IRS_WRITER), registryY, 0);
        AccessManagerSetupLib.setupTokenRoles(domainManager, address(s.tokenY), s.fundY);
        AccessManagerSetupLib.setupTREXRegistryRoles(domainManager, registryY, s.fundY);
        AccessManagerSetupLib.setupModularComplianceRoles(domainManager, address(s.tokenY.compliance()), s.fundY);
        AccessManagerSetupLib.setupRoleAdmins(domainManager, s.fundY);

        _grantStorageBinder(domainManager, s.fundX);
        s.irs.bindIdentityRegistry(registryY);
        assertTrue(s.irs.isIdentityRegistryBound(registryY));
        assertEq(address(s.tokenY.identityRegistry().identityStorage()), address(s.irs));
    }

    /// @dev A storage that no suite uses yet: its rows are all at `ADMIN_ROLE`, so the admin binds and writes it.
    function _deployFreshStorage() private returns (IdentityRegistryStorage) {
        return IdentityRegistryStorage(
            address(
                new ERC1967Proxy(
                    address(identityRegistryStorageImplementation),
                    abi.encodeCall(IdentityRegistryStorage.init, (address(domainManager), address(0)))
                )
            )
        );
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

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(irs), fundX));
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
    ///         writing. The caller holds X's `IRS_BINDER`, so the domain check is the only thing refusing.
    function test_registry_RevertWhen_PureFormPointsAStorageAtAnotherDomain() public {
        Token tokenX = _deployBare("pure-x", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("pure-y", address(irs), address(domainManager));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        _grantStorageBinder(domainManager, fundX);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(irs), fundX));
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

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(irs), fundX));
        this.commissionExternally(address(tokenY));

        assertEq(domainManager.getTargetFunctionRole(address(tokenY), IERC3643.mint.selector), 0);
        assertFalse(irs.isIdentityRegistryBound(address(tokenY.identityRegistry())));
    }

    /// @notice The manager form also reads its own record of the storage's domain. A storage recorded in Y
    ///         by a bare `assign`, with no row mapped yet, is refused for X's token: the record and the rows
    ///         must agree, and while the rows are empty the record is all there is.
    function test_registry_RevertWhen_StorageIsRecordedInAnotherDomainBeforeItsRowsAreMapped() public {
        Token tokenX = _deployBare("record-x", address(0), address(domainManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        domainManager.assign(fundY, address(irs));
        assertEq(
            domainManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            0,
            "the storage's rows are still empty"
        );

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(irs), fundY));
        this.commissionExternally(address(tokenX));

        assertEq(domainManager.getTargetFunctionRole(address(tokenX), IERC3643.mint.selector), 0);
    }

    /// @notice A registry belongs to one domain too, so two domains cannot share one. X's registry moves to
    ///         a fresh storage, which the storage check has nothing to say about, and Y's token adopts X's
    ///         registry. Commissioning Y is refused on the registry's own rows: X's agents keep their
    ///         registry and Y's agents never get it.
    function test_registry_RevertWhen_TheRegistryIsSetUpInAnotherDomain() public {
        Token tokenX = _deployBare("one-reg-x", address(0), address(domainManager));
        Token tokenY = _deployBare("one-reg-y", address(0), address(domainManager));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        domainManager.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        ITREXRegistry registryX = ITREXRegistry(address(tokenX.identityRegistry()));

        // X's OWNER points X's registry at a never commissioned storage, then Y's token adopts X's registry.
        IdentityRegistryStorage freshStorage = _deployFreshStorage();
        freshStorage.bindIdentityRegistry(address(registryX));
        domainManager.grantRole(RolesLib.forDomain(fundX, RolesLib.Role.OWNER), address(this), 0);
        registryX.setIdentityRegistryStorage(address(freshStorage));
        tokenY.setIdentityRegistry(address(registryX));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(registryX), fundX));
        this.commissionExternally(address(tokenY));

        // The registry's rows still belong to X, and nothing of Y's suite was set up.
        assertEq(
            domainManager.getTargetFunctionRole(address(registryX), IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forDomain(fundX, RolesLib.Role.AGENT)
        );
        assertEq(domainManager.getTargetFunctionRole(address(tokenY), IERC3643.mint.selector), 0);

        // Commissioning X again maps the fresh storage into X; it needs X's `AGENT_ADMIN` for the token's
        // `AGENT` grant, which `_grantAllAgentRoles` gives this contract. X's agents write, Y's are refused.
        _grantAllAgentRoles(domainManager, agentA, fundX);
        _grantAllAgentRoles(domainManager, agentB, fundY);
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        vm.prank(agentA);
        registryX.registerIdentity(alice, aliceIdentity, 0);
        vm.prank(agentB);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentB));
        registryX.registerIdentity(bob, bobIdentity, 0);
        assertEq(address(registryX.identity(alice)), address(aliceIdentity));
    }

    /// @notice A compliance belongs to one domain too. X's OWNER unbinds X's compliance (X has no supply),
    ///         Y's token adopts it, and commissioning Y is refused on the compliance's own rows.
    /// @dev A compliance only accepts a token its manager governs, so Y's token functions are mapped to fund Y
    ///      first, as an admin does before handing a token to its team. Y's `IDENTITY_MANAGER` then points
    ///      the token at X's compliance.
    function test_registry_RevertWhen_TheComplianceIsSetUpInAnotherDomain() public {
        Token tokenX = _deployBare("one-mc-x", address(0), address(domainManager));
        Token tokenY = _deployBare("one-mc-y", address(0), address(domainManager));
        uint32 fundX = domainManager.createDomain("Fund X");
        uint32 fundY = domainManager.createDomain("Fund Y");
        domainManager.assign(fundX, address(tokenX));
        domainManager.assign(fundY, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        IModularCompliance complianceX = IModularCompliance(address(tokenX.compliance()));

        domainManager.grantRole(RolesLib.forDomain(fundX, RolesLib.Role.OWNER), address(this), 0);
        complianceX.unbindToken(address(tokenX));
        AccessManagerSetupLib.setupTokenRoles(domainManager, address(tokenY), fundY);
        domainManager.grantRole(RolesLib.forDomain(fundY, RolesLib.Role.IDENTITY_MANAGER), address(this), 0);
        tokenY.setCompliance(address(complianceX));
        assertEq(complianceX.getTokenBound(), address(tokenY));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(complianceX), fundX));
        this.commissionExternally(address(tokenY));

        // The compliance's rows still belong to X, and nothing else of Y's suite was set up: Y's registry has
        // no row and Y's token is not an agent of fund Y.
        assertEq(
            domainManager.getTargetFunctionRole(address(complianceX), IModularCompliance.addModule.selector),
            RolesLib.forDomain(fundX, RolesLib.Role.OWNER)
        );
        assertEq(
            domainManager.getTargetFunctionRole(
                address(tokenY.identityRegistry()), IERC3643IdentityRegistry.registerIdentity.selector
            ),
            0
        );
        (bool tokenYIsAgent,) = domainManager.hasRole(RolesLib.forDomain(fundY, RolesLib.Role.AGENT), address(tokenY));
        assertFalse(tokenYIsAgent);
    }

    /// @notice Two tokens of one domain may share one registry: its rows are already in that domain, so the
    ///         second commission is let through and the domain's agents reach both tokens through it.
    function test_registry_TokensOfOneDomainShareOneRegistry() public {
        Token tokenX = _deployBare("share-reg-x", address(0), address(domainManager));
        Token tokenY = _deployBare("share-reg-y", address(0), address(domainManager));
        uint32 fund = domainManager.createDomain("Fund");
        domainManager.assign(fund, address(tokenX));
        domainManager.assign(fund, address(tokenY));
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenX));
        IERC3643IdentityRegistry registryX = tokenX.identityRegistry();

        tokenY.setIdentityRegistry(address(registryX));
        domainManager.grantRole(RolesLib.forDomain(fund, RolesLib.Role.AGENT_ADMIN), address(this), 0);
        AccessManagerSetupLib.commissionSuite(domainManager, address(tokenY));

        assertEq(
            domainManager.getTargetFunctionRole(address(registryX), IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forDomain(fund, RolesLib.Role.AGENT)
        );
        _grantAllAgentRoles(domainManager, agentA, fund);
        vm.startPrank(agentA);
        registryX.registerIdentity(alice, aliceIdentity, 0);
        tokenX.unpause();
        tokenY.unpause();
        tokenX.mint(alice, 1);
        tokenY.mint(alice, 2);
        vm.stopPrank();
        assertEq(tokenX.balanceOf(alice), 1);
        assertEq(tokenY.balanceOf(alice), 2);
    }

    /// @notice A registry of another domain bound to the storage by hand writes nothing: it holds `IRS_WRITER`
    ///         in its own domain, and the storage's rows ask for the storage's domain.
    function test_registry_RegistryOfAnotherDomainBoundByHandWritesNothing() public {
        TwoDomainsOneStorage memory s = _twoDomainsOneStorage();
        _setUpYByHandOnXsStorage(s);
        IERC3643IdentityRegistry registryY = s.tokenY.identityRegistry();
        bytes memory registryYRefused =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryY));
        _grantAllAgentRoles(domainManager, agentB, s.fundY);

        vm.startPrank(agentB);
        vm.expectRevert(registryYRefused);
        registryY.registerIdentity(charlie, charlieIdentity, 0);
        vm.expectRevert(registryYRefused);
        registryY.updateIdentity(alice, charlieIdentity);
        vm.expectRevert(registryYRefused);
        registryY.deleteIdentity(alice);
        vm.stopPrank();

        ITREXRegistry registryX = ITREXRegistry(address(s.tokenX.identityRegistry()));
        assertEq(address(s.irs.storedIdentity(alice)), address(aliceIdentity));
        assertFalse(registryX.isLocallyRegistered(charlie), "nothing was written for charlie");
        assertEq(address(registryX.identity(alice)), address(aliceIdentity));
    }

    /// @notice The audit's scenario, step by step. An agent of Y wants X's storage, where alice, a holder of
    ///         X, is recorded. Step 1 is the way the audit found: commission Y's suite onto X's storage, which
    ///         is now refused. Steps 2 to 4 are what is left once Y's registry is put on that storage by hand:
    ///         register a wallet of theirs under alice's identity, rebind alice to an identity they control,
    ///         move her balance with `identityTransfer`. Every step fails and alice keeps her 100.
    function test_registry_AgentOfAnotherDomainCannotSeizeAHolder() public {
        TwoDomainsOneStorage memory s = _twoDomainsOneStorage();
        _grantStorageBinder(domainManager, s.fundX);

        // 1. Commission Y onto X's storage. Refused: X's storage stays X's, Y's registry gets no writer role.
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(s.irs), s.fundX));
        this.commissionExternally(address(s.tokenY));
        assertFalse(s.irs.isIdentityRegistryBound(address(s.tokenY.identityRegistry())));
        _assertWritesOnlyInDomain(address(s.tokenX.identityRegistry()), s.fundX);

        _setUpYByHandOnXsStorage(s);
        IERC3643IdentityRegistry registryY = s.tokenY.identityRegistry();
        bytes memory registryYRefused =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryY));
        _grantAllAgentRoles(domainManager, agentB, s.fundY);

        // 2. Register a recipient the agent controls under alice's identity, so it passes X's checks.
        vm.prank(agentB);
        vm.expectRevert(registryYRefused);
        registryY.registerIdentity(charlie, aliceIdentity, 0);

        // 3. Rebind alice's wallet to an identity the agent controls.
        vm.prank(agentB);
        vm.expectRevert(registryYRefused);
        registryY.updateIdentity(alice, charlieIdentity);

        // 4. Move alice's balance from that identity. Alice's wallet still answers to her own identity.
        vm.prank(address(charlieIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, alice, address(charlieIdentity)));
        s.tokenX.identityTransfer(alice, charlie, 100);

        assertEq(s.tokenX.balanceOf(alice), 100);
        assertEq(s.tokenX.balanceOf(charlie), 0);
        assertEq(address(s.irs.storedIdentity(alice)), address(aliceIdentity));
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
