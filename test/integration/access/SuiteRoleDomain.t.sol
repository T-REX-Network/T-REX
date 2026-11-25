// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

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
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";
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

    /// @notice After suite setup, every batch has a row of its own on the role of its single-item function, so
    ///         it takes the full check, scheduled operations included, rather than the immediate-only fallback.
    function test_explicitDomain_EveryBatchHasTheRoleOfItsSingleItemFunction() public {
        _setupSuiteInto(suiteManager, tokenA, domainA);
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
        uint64 singleItemRole = suiteManager.getTargetFunctionRole(target, singleItemSelector);
        assertNotEq(singleItemRole, suiteManager.ADMIN_ROLE(), "single-item function is mapped");
        assertEq(suiteManager.getTargetFunctionRole(target, batchSelector), singleItemRole);
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

    /// @notice A storage reused by a second fund is refused: the second fund's registry would write into the
    ///         first fund's records, and its agents could register and revoke the first fund's holders.
    function test_issuerManager_RevertWhen_ReusedStorageIsSetUpInAnotherFund() public {
        Token tokenX = _deployBare("fund-x", address(0), address(issuerManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("fund-y", address(irs), address(issuerManager));
        uint32 fundX = issuerManager.createDomain("Fund X");
        uint32 fundY = issuerManager.createDomain("Fund Y");
        _setupSuiteInto(issuerManager, tokenX, fundX);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(irs), fundX));
        issuerManager.setupSuite(fundY, address(tokenY));

        _grantStorageBinder(issuerManager, fundX);
        irs.bindIdentityRegistry(address(tokenY.identityRegistry()));
        (bool registryYWrites,) = issuerManager.hasRole(
            RolesLib.forDomain(fundX, RolesLib.Role.IRS_WRITER), address(tokenY.identityRegistry())
        );
        assertFalse(registryYWrites, "a bound registry of another fund cannot write");
        _grantAllAgentRoles(issuerManager, agentB, fundY);
        IERC3643IdentityRegistry registryY = tokenY.identityRegistry();
        vm.prank(agentB);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentB));
        registryY.registerIdentity(bob, bobIdentity, 0);
        _assertCannotTouchStorage(agentB, irs);
    }

    // ============================================================
    // One domain per storage, registry and compliance
    // ============================================================

    /// @dev The setup of the audit's scenario: two tokens of two domains, and Y deployed on X's storage.
    struct TwoDomainsOneStorage {
        Token tokenX;
        Token tokenY;
        IdentityRegistryStorage irs;
        uint32 fundX;
        uint32 fundY;
    }

    /// @dev Token X is set up in fund X and alice holds 100 of it. Token Y is deployed on X's storage but not
    ///      set up: that is the step the tests then try.
    function _twoDomainsOneStorage() private returns (TwoDomainsOneStorage memory s) {
        s.tokenX = _deployBare("seize-x", address(0), address(issuerManager));
        s.irs = IdentityRegistryStorage(address(s.tokenX.identityRegistry().identityStorage()));
        s.tokenY = _deployBare("seize-y", address(s.irs), address(issuerManager));
        s.fundX = issuerManager.createDomain("Fund X");
        s.fundY = issuerManager.createDomain("Fund Y");
        _setupSuiteInto(issuerManager, s.tokenX, s.fundX);

        _grantAllAgentRoles(issuerManager, agentA, s.fundX);
        vm.startPrank(agentA);
        s.tokenX.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        s.tokenX.unpause();
        s.tokenX.mint(alice, 100);
        vm.stopPrank();
    }

    /// @dev Maps Y's registry into fund Y by hand, which is what `setupSuite` would do if it did not refuse X's
    ///      storage, and has X's `IRS_BINDER` bind it to X's storage. This is the one way left to put a registry
    ///      of another domain on a storage, and it takes the admin plus X's binder to do it.
    function _setUpYByHandOnXsStorage(TwoDomainsOneStorage memory s) private {
        address registryY = address(s.tokenY.identityRegistry());
        bytes4[] memory agentFunctions = new bytes4[](3);
        agentFunctions[0] = IERC3643IdentityRegistry.registerIdentity.selector;
        agentFunctions[1] = IERC3643IdentityRegistry.updateIdentity.selector;
        agentFunctions[2] = IERC3643IdentityRegistry.deleteIdentity.selector;
        issuerManager.setTargetFunctionRole(registryY, agentFunctions, RolesLib.forDomain(s.fundY, RolesLib.Role.AGENT));
        issuerManager.grantRole(RolesLib.forDomain(s.fundY, RolesLib.Role.IRS_WRITER), registryY, 0);

        _grantStorageBinder(issuerManager, s.fundX);
        s.irs.bindIdentityRegistry(registryY);
        assertTrue(s.irs.isIdentityRegistryBound(registryY));
        assertEq(address(s.tokenY.identityRegistry().identityStorage()), address(s.irs));
    }

    /// @notice The audit's scenario, step by step. An agent of Y wants X's storage, where alice, a holder of
    ///         X, is recorded. Step 1 is the way the audit found: set Y's suite up onto X's storage, which is
    ///         now refused. Steps 2 to 4 are what is left once Y's registry is put on that storage by hand:
    ///         register a wallet of theirs under alice's identity, rebind alice to an identity they control,
    ///         move her balance with `identityTransfer`. Every step fails and alice keeps her 100.
    function test_registry_AgentOfAnotherDomainCannotSeizeAHolder() public {
        TwoDomainsOneStorage memory s = _twoDomainsOneStorage();

        // 1. Set Y up onto X's storage. Refused: X's storage stays X's, Y's registry gets no writer role.
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(s.irs), s.fundX));
        issuerManager.setupSuite(s.fundY, address(s.tokenY));
        assertFalse(s.irs.isIdentityRegistryBound(address(s.tokenY.identityRegistry())));
        _assertWritesOnlyInDomain(address(s.tokenX.identityRegistry()), s.fundX);

        _setUpYByHandOnXsStorage(s);
        IERC3643IdentityRegistry registryY = s.tokenY.identityRegistry();
        bytes memory registryYRefused =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryY));
        _grantAllAgentRoles(issuerManager, agentB, s.fundY);

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

    /// @notice A registry of another domain bound to the storage by hand writes nothing: it holds `IRS_WRITER`
    ///         in its own domain, and the storage's rows ask for the storage's domain.
    function test_registry_RegistryOfAnotherDomainBoundByHandWritesNothing() public {
        TwoDomainsOneStorage memory s = _twoDomainsOneStorage();
        _setUpYByHandOnXsStorage(s);
        IERC3643IdentityRegistry registryY = s.tokenY.identityRegistry();
        bytes memory registryYRefused =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(registryY));
        _grantAllAgentRoles(issuerManager, agentB, s.fundY);

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

    /// @notice A registry belongs to one domain too, so two domains cannot share one. Y's token adopts X's
    ///         registry, and setting Y's suite up is refused on the registry: X's agents keep their registry
    ///         and Y's agents never get it.
    function test_registry_RevertWhen_TheRegistryIsSetUpInAnotherDomain() public {
        Token tokenX = _deployBare("one-reg-x", address(0), address(issuerManager));
        Token tokenY = _deployBare("one-reg-y", address(0), address(issuerManager));
        uint32 fundX = issuerManager.createDomain("Fund X");
        uint32 fundY = issuerManager.createDomain("Fund Y");
        _setupSuiteInto(issuerManager, tokenX, fundX);
        ITREXRegistry registryX = ITREXRegistry(address(tokenX.identityRegistry()));

        // Y's token is not set up yet, so its setters still answer to the manager's admin.
        tokenY.setIdentityRegistry(address(registryX));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(registryX), fundX));
        issuerManager.setupSuite(fundY, address(tokenY));

        // The registry's rows still belong to X, and nothing of Y's suite was set up.
        assertEq(
            issuerManager.getTargetFunctionRole(address(registryX), IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forDomain(fundX, RolesLib.Role.AGENT)
        );
        assertEq(issuerManager.getTargetFunctionRole(address(tokenY), IERC3643.mint.selector), 0);
        assertEq(issuerManager.domainOf(address(tokenY)), 0);

        // X's agents write through the registry, Y's are refused.
        _grantAllAgentRoles(issuerManager, agentA, fundX);
        _grantAllAgentRoles(issuerManager, agentB, fundY);
        vm.prank(agentA);
        registryX.registerIdentity(alice, aliceIdentity, 0);
        vm.prank(agentB);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentB));
        registryX.registerIdentity(bob, bobIdentity, 0);
        assertEq(address(registryX.identity(alice)), address(aliceIdentity));
    }

    /// @notice A compliance belongs to one domain too. X's OWNER unbinds X's compliance (X has no supply),
    ///         Y's token adopts it, and setting Y's suite up is refused on the compliance.
    /// @dev A compliance only accepts a token its manager governs, so Y's `setCompliance` is given a role of
    ///      fund Y first, as an admin does before handing a token to its team. Y's `IDENTITY_MANAGER` then
    ///      points the token at X's compliance.
    function test_registry_RevertWhen_TheComplianceIsSetUpInAnotherDomain() public {
        Token tokenX = _deployBare("one-mc-x", address(0), address(issuerManager));
        Token tokenY = _deployBare("one-mc-y", address(0), address(issuerManager));
        uint32 fundX = issuerManager.createDomain("Fund X");
        uint32 fundY = issuerManager.createDomain("Fund Y");
        _setupSuiteInto(issuerManager, tokenX, fundX);
        IModularCompliance complianceX = IModularCompliance(address(tokenX.compliance()));

        issuerManager.grantRole(RolesLib.forDomain(fundX, RolesLib.Role.OWNER), address(this), 0);
        complianceX.unbindToken(address(tokenX));
        bytes4[] memory setCompliance = new bytes4[](1);
        setCompliance[0] = IERC3643.setCompliance.selector;
        issuerManager.setTargetFunctionRole(
            address(tokenY), setCompliance, RolesLib.forDomain(fundY, RolesLib.Role.IDENTITY_MANAGER)
        );
        issuerManager.grantRole(RolesLib.forDomain(fundY, RolesLib.Role.SUITE_ADMIN), address(this), 0);
        issuerManager.grantRole(RolesLib.forDomain(fundY, RolesLib.Role.IDENTITY_MANAGER), address(this), 0);
        tokenY.setCompliance(address(complianceX));
        assertEq(complianceX.getTokenBound(), address(tokenY));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, address(complianceX), fundX));
        issuerManager.setupSuite(fundY, address(tokenY));

        // The compliance's rows still belong to X, and nothing else of Y's suite was set up: Y's registry has
        // no row and Y's token is not an agent of fund Y.
        assertEq(
            issuerManager.getTargetFunctionRole(address(complianceX), IModularCompliance.addModule.selector),
            RolesLib.forDomain(fundX, RolesLib.Role.OWNER)
        );
        assertEq(
            issuerManager.getTargetFunctionRole(
                address(tokenY.identityRegistry()), IERC3643IdentityRegistry.registerIdentity.selector
            ),
            0
        );
        (bool tokenYIsAgent,) = issuerManager.hasRole(RolesLib.forDomain(fundY, RolesLib.Role.AGENT), address(tokenY));
        assertFalse(tokenYIsAgent);
    }

    /// @notice Two tokens of one domain may share one registry: it is already in that domain, so the second
    ///         suite is let through and the domain's agents reach both tokens through it.
    function test_registry_TokensOfOneDomainShareOneRegistry() public {
        Token tokenX = _deployBare("share-reg-x", address(0), address(issuerManager));
        Token tokenY = _deployBare("share-reg-y", address(0), address(issuerManager));
        uint32 fund = issuerManager.createDomain("Fund");
        _setupSuiteInto(issuerManager, tokenX, fund);
        IERC3643IdentityRegistry registryX = tokenX.identityRegistry();

        tokenY.setIdentityRegistry(address(registryX));
        _setupSuiteInto(issuerManager, tokenY, fund);

        assertEq(
            issuerManager.getTargetFunctionRole(address(registryX), IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forDomain(fund, RolesLib.Role.AGENT)
        );
        _grantAllAgentRoles(issuerManager, agentA, fund);
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

    /// @notice Two tokens of one domain, each with its own registry, still share one storage: both registries
    ///         write through that domain's `IRS_WRITER`, and the domain's agents reach both.
    function test_registry_TokensOfOneDomainShareOneStorage() public {
        Token tokenX = _deployBare("class-x", address(0), address(issuerManager));
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(tokenX.identityRegistry().identityStorage()));
        Token tokenY = _deployBare("class-y", address(irs), address(issuerManager));
        uint32 fund = issuerManager.createDomain("Fund");
        _setupSuiteInto(issuerManager, tokenX, fund);
        _setupSuiteInto(issuerManager, tokenY, fund);
        _grantStorageBinder(issuerManager, fund);
        irs.bindIdentityRegistry(address(tokenY.identityRegistry()));

        assertEq(issuerManager.domainOf(address(irs)), fund);
        _assertWritesOnlyInDomain(address(tokenX.identityRegistry()), fund);
        _assertWritesOnlyInDomain(address(tokenY.identityRegistry()), fund);

        _grantAllAgentRoles(issuerManager, agentA, fund);
        vm.startPrank(agentA);
        tokenX.identityRegistry().registerIdentity(alice, aliceIdentity, 0);
        tokenY.identityRegistry().registerIdentity(bob, bobIdentity, 0);
        vm.stopPrank();
        assertEq(address(irs.storedIdentity(alice)), address(aliceIdentity));
        assertEq(address(irs.storedIdentity(bob)), address(bobIdentity));
        _assertCannotTouchStorage(agentA, irs);
    }

    /// @notice Whatever domain a suite is set up in, its registry holds `IRS_WRITER` there and nowhere else.
    function test_registry_RegistryWritesThroughItsOwnDomainOnly() public {
        Token tokenX = _deployBare("own-x", address(0), address(issuerManager));
        Token tokenY = _deployBare("own-y", address(0), address(issuerManager));
        uint32 fundX = issuerManager.createDomain("Fund X");
        uint32 fundY = issuerManager.createDomain("Fund Y");
        _setupSuiteInto(issuerManager, tokenX, fundX);
        _setupSuiteInto(issuerManager, tokenY, fundY);

        _assertWritesOnlyInDomain(address(tokenX.identityRegistry()), fundX);
        _assertWritesOnlyInDomain(address(tokenY.identityRegistry()), fundY);
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

    /// @dev `identityRegistry` holds `IRS_WRITER` in `domainId` and in no other domain of the issuer's manager.
    function _assertWritesOnlyInDomain(address identityRegistry, uint32 domainId) private view {
        for (uint32 candidate = 1; candidate <= issuerManager.domainCount(); candidate++) {
            (bool writes,) =
                issuerManager.hasRole(RolesLib.forDomain(candidate, RolesLib.Role.IRS_WRITER), identityRegistry);
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
