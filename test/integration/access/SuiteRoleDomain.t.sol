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
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract SuiteRoleDomainTest is TREXSuiteTest {

    /// @dev Three domains created on the fixture's manager next to its own `DOMAIN`: two unrelated funds and
    ///      one team that runs several tokens.
    uint32 internal domainA;
    uint32 internal domainB;
    uint32 internal team;
    /// @dev Fixed ids used only to check the packing arithmetic.
    uint32 internal constant DOMAIN_A = 10;
    uint32 internal constant DOMAIN_B = 20;
    Token internal tokenA;
    Token internal tokenB;
    /// @dev A second manager with no domain yet, the shape an issuer gets when they run one themselves.
    TREXAccessManager internal issuerManager;
    address internal agentA = makeAddr("agentA");
    address internal agentB = makeAddr("agentB");

    function setUp() public override {
        super.setUp();
        domainA = suiteManager.createDomain("Fund A");
        domainB = suiteManager.createDomain("Fund B");
        team = suiteManager.createDomain("Team");
        tokenA = _deployBare("ns-a", address(0), address(suiteManager));
        tokenB = _deployBare("ns-b", address(0), address(suiteManager));
        issuerManager = _newTREXAccessManager(address(this));
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

    function test_platform_CustomRoleIsFlaggedAndDistinctFromEnumRoles() public pure {
        uint64 custom = RolesLib.platform(bytes32("TOKEN_ISSUER"));
        (uint32 domainId, uint32 role, bool isCustom) = RolesLib.decode(custom);
        assertEq(domainId, RolesLib.PLATFORM_DOMAIN);
        assertTrue(isCustom);
        assertEq(role, uint32(uint256(keccak256(abi.encode(bytes32("TOKEN_ISSUER"))))) & ~RolesLib.CUSTOM_ROLE_FLAG);
        for (uint8 i = 0; i <= uint8(type(RolesLib.PlatformRole).max); i++) {
            assertNotEq(custom, RolesLib.platform(RolesLib.PlatformRole(i)));
        }
        assertEq(custom, RolesLib.platform(bytes32("TOKEN_ISSUER")));
        assertNotEq(custom, RolesLib.platform(bytes32("VERSION_MANAGER")));
        assertNotEq(custom, RolesLib.forDomain(DOMAIN_A, bytes32("TOKEN_ISSUER")));
    }

    function packExternally(uint32 domainId, RolesLib.Role role) external pure returns (uint64) {
        return RolesLib.forDomain(domainId, role);
    }

    function packCustomExternally(uint32 domainId, bytes32 customName) external pure returns (uint64) {
        return RolesLib.forDomain(domainId, customName);
    }

    function test_explicitDomain_AgentOfAOperatesAOnly() public {
        _setupSuiteInto(suiteManager, tokenA, domainA);
        _setupSuiteInto(suiteManager, tokenB, domainB);
        _grantAllAgentRoles(suiteManager, agentA, domainA);

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
        _setupSuiteInto(suiteManager, tokenA, domainA);
        _setupSuiteInto(suiteManager, tokenB, domainB);
        _grantAllAgentRoles(suiteManager, agentB, domainB);

        vm.startPrank(agentB);
        tokenB.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        tokenB.unpause();
        tokenB.mint(alice, 5);
        vm.stopPrank();
        assertEq(tokenB.balanceOf(alice), 5);

        _assertLockedOut(agentB, tokenA);
    }

    function test_explicitDomain_TwoTokensInOneDomainShareOneTeam() public {
        _setupSuiteInto(suiteManager, tokenA, team);
        _setupSuiteInto(suiteManager, tokenB, team);
        _grantAllAgentRoles(suiteManager, agentA, team);

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
        _setupSuiteInto(suiteManager, tokenA, domainA);
        address suiteRegistry = address(tokenA.identityRegistry());
        address irs = address(tokenA.identityRegistry().identityStorage());
        address mc = address(tokenA.compliance());

        assertEq(suiteManager.domainOf(address(tokenA)), domainA);
        assertEq(suiteManager.domainOf(suiteRegistry), domainA);
        assertEq(suiteManager.domainOf(irs), domainA);
        assertEq(suiteManager.domainOf(mc), domainA);
        assertEq(
            suiteManager.getTargetFunctionRole(address(tokenA), IERC3643.mint.selector),
            RolesLib.forDomain(domainA, RolesLib.Role.AGENT_MINTER)
        );
        assertEq(
            suiteManager.getTargetFunctionRole(suiteRegistry, IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forDomain(domainA, RolesLib.Role.AGENT)
        );
        assertEq(
            suiteManager.getTargetFunctionRole(irs, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.forDomain(domainA, RolesLib.Role.IRS_WRITER)
        );
        assertEq(
            suiteManager.getTargetFunctionRole(mc, IModularCompliance.addModule.selector),
            RolesLib.forDomain(domainA, RolesLib.Role.OWNER)
        );
        assertEq(
            suiteManager.getRoleAdmin(RolesLib.forDomain(domainA, RolesLib.Role.AGENT)),
            RolesLib.forDomain(domainA, RolesLib.Role.AGENT_ADMIN)
        );
        (bool tokenIsAgent,) = suiteManager.hasRole(RolesLib.forDomain(domainA, RolesLib.Role.AGENT), address(tokenA));
        (bool registryWrites,) =
            suiteManager.hasRole(RolesLib.forDomain(domainA, RolesLib.Role.IRS_WRITER), suiteRegistry);
        assertTrue(tokenIsAgent);
        assertTrue(registryWrites);
    }

    function test_explicitDomain_StorageWriterStaysUnderAdminRole() public {
        _setupSuiteInto(suiteManager, tokenA, domainA);
        uint64 writer = RolesLib.forDomain(domainA, RolesLib.Role.IRS_WRITER);
        uint64 agentAdmin = RolesLib.forDomain(domainA, RolesLib.Role.AGENT_ADMIN);
        suiteManager.grantRole(agentAdmin, agentA, 0);

        assertEq(suiteManager.getRoleAdmin(writer), 0);
        vm.prank(agentA);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, agentA, uint64(0))
        );
        suiteManager.grantRole(writer, agentB, 0);
    }

    /// @notice An issuer running their own manager creates a domain, then sets a suite up in it.
    function test_issuerManager_SetupSuiteUsesTheGivenDomain() public {
        Token fundToken = _deployBare("fund-a", address(0), address(issuerManager));
        address irs = address(fundToken.identityRegistry().identityStorage());
        uint32 fund = issuerManager.createDomain("Fund A");

        _setupSuiteInto(issuerManager, fundToken, fund);

        assertEq(issuerManager.domainName(fund), "Fund A");
        assertEq(issuerManager.domainOf(irs), fund);
        assertEq(
            issuerManager.getTargetFunctionRole(address(fundToken), IERC3643.mint.selector),
            RolesLib.forDomain(fund, RolesLib.Role.AGENT_MINTER)
        );
        assertEq(
            issuerManager.getTargetFunctionRole(irs, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector),
            RolesLib.forDomain(fund, RolesLib.Role.IRS_WRITER)
        );
        _grantAllAgentRoles(issuerManager, agentA, fund);
        vm.startPrank(agentA);
        fundToken.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        fundToken.unpause();
        fundToken.mint(alice, 3);
        vm.stopPrank();
        assertEq(fundToken.balanceOf(alice), 3);
    }

    /// @notice The issuer's whole part is one transaction: a new domain and its first suite go through the
    ///         manager's `multicall`, with the domain id read as `domainCount() + 1` before sending.
    function test_issuerManager_CreateDomainAndSetupSuiteInOneTransaction() public {
        address acmeBoard = makeAddr("acmeBoard");
        TREXAccessManager acmeManager = _newTREXAccessManager(acmeBoard);
        Token acmeToken = _deployBare("acme", address(0), address(acmeManager));
        uint32 nextDomainId = acmeManager.domainCount() + 1;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(TREXAccessManager.createDomain, ("Acme Bonds"));
        calls[1] = abi.encodeCall(TREXAccessManager.setupSuite, (nextDomainId, address(acmeToken)));

        vm.prank(acmeBoard);
        acmeManager.multicall(calls);

        assertEq(acmeManager.domainName(nextDomainId), "Acme Bonds");
        assertEq(acmeManager.domainOf(address(acmeToken)), nextDomainId);
        assertEq(
            acmeManager.getTargetFunctionRole(address(acmeToken), IERC3643.mint.selector),
            RolesLib.forDomain(nextDomainId, RolesLib.Role.AGENT_MINTER)
        );
    }

    function test_issuerManager_SetupSuiteRevertWhen_DomainDoesNotExist() public {
        Token fundToken = _deployBare("fund-x", address(0), address(issuerManager));
        uint32 missingDomain = 7;

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DomainNotFound.selector, missingDomain));
        issuerManager.setupSuite(missingDomain, address(fundToken));
    }

    /// @notice Two share classes of one fund share one storage and one team. The second registry is bound to
    ///         the shared storage by a holder of `IRS_BINDER`; `setupSuite` does not bind.
    function test_issuerManager_ShareClassesOfOneFundShareOneTeam() public {
        Token classA = _deployBare("class-a", address(0), address(issuerManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(classA.identityRegistry().identityStorage()));
        Token classB = _deployBare("class-b", address(irs), address(issuerManager));
        uint32 fund = issuerManager.createDomain("Fund");
        _setupSuiteInto(issuerManager, classA, fund);
        _setupSuiteInto(issuerManager, classB, fund);
        _grantStorageBinder(issuerManager, fund);
        irs.bindIdentityRegistry(address(classB.identityRegistry()));
        _grantAllAgentRoles(issuerManager, agentA, fund);

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

    /// @notice A storage reused by a second fund keeps the domain of the first: the second fund's registry
    ///         writes through the first domain's `IRS_WRITER`, and neither fund's agents reach the other's token.
    function test_issuerManager_ReusedStorageKeepsItsDomainAcrossFunds() public {
        Token tokenX = _deployBare("fund-x", address(0), address(issuerManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("fund-y", address(irs), address(issuerManager));
        uint32 fundX = issuerManager.createDomain("Fund X");
        uint32 fundY = issuerManager.createDomain("Fund Y");
        _setupSuiteInto(issuerManager, tokenX, fundX);
        _setupSuiteInto(issuerManager, tokenY, fundY);
        _grantStorageBinder(issuerManager, fundX);
        irs.bindIdentityRegistry(address(tokenY.identityRegistry()));

        assertEq(issuerManager.domainOf(address(irs)), fundX);
        assertEq(
            issuerManager.getTargetFunctionRole(
                address(irs), IERC3643IdentityRegistryStorage.addIdentityToStorage.selector
            ),
            RolesLib.forDomain(fundX, RolesLib.Role.IRS_WRITER)
        );
        (bool registryYWrites,) = issuerManager.hasRole(
            RolesLib.forDomain(fundX, RolesLib.Role.IRS_WRITER), address(tokenY.identityRegistry())
        );
        assertTrue(registryYWrites);

        _grantAllAgentRoles(issuerManager, agentA, fundX);
        _grantAllAgentRoles(issuerManager, agentB, fundY);
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

    // ============================================================
    // Helpers
    // ============================================================

    function _setupSuiteInto(TREXAccessManager manager, Token target, uint32 domainId) private {
        manager.setupSuite(domainId, address(target));
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
