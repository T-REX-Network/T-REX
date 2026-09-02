// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { Errors } from "@onchain-id/solidity/contracts/libraries/Errors.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Create3 } from "@openzeppelin/contracts/utils/Create3.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorageProxy } from "contracts/proxy/IdentityRegistryStorageProxy.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { TestModule } from "test/integration/mocks/TestModule.sol";
import { TestTREXFactory } from "test/integration/mocks/TestTREXFactory.sol";

contract TREXFactoryTest is TREXSuiteTest {

    // Helper function to create empty TokenDetails
    function _createEmptyTokenDetails() internal view returns (ITREXFactory.TokenDetails memory) {
        address[] memory emptyAgents;
        address[] memory emptyModules;
        bytes[] memory emptySettings;

        return ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: emptyAgents,
            tokenAgents: emptyAgents,
            complianceModules: emptyModules,
            complianceSettings: emptySettings,
            accessManager: address(accessManager)
        });
    }

    // Helper function to create empty ClaimDetails
    function _createEmptyClaimDetails() internal pure returns (ITREXFactory.ClaimDetails memory) {
        uint256[] memory emptyTopics;
        address[] memory emptyIssuers;
        uint256[][] memory emptyClaims;

        return ITREXFactory.ClaimDetails({ claimTopics: emptyTopics, issuers: emptyIssuers, issuerClaims: emptyClaims });
    }

    // Re-derives the factory's CREATE3 address prediction for a given (salt, contractType), mirroring
    // TREXFactory._saltBytes / _predictAddress. Lets tests assert that deployed == predicted.
    function _predictSuiteAddress(string memory salt, string memory contractType) internal view returns (address) {
        bytes32 saltBytes = bytes20(address(trexFactory)) | keccak256(bytes(string.concat(salt, contractType))) >> 168;
        return Create3.computeAddress(saltBytes, address(trexFactory));
    }

    // ============ Existing Basic Tests ============

    function test_TREXSuiteDeploys() public view {
        // Verify all components are deployed
        assertNotEq(address(trexFactory), address(0), "TREX Factory should be deployed");
        assertNotEq(address(trexImplementationAuthority), address(0), "TREX IA should be deployed");
        assertNotEq(address(idFactory), address(0), "IdentityFactory should be deployed");
    }

    function test_TREXFactoryLinked() public view {
        // Verify factory knows about IA
        assertEq(
            trexFactory.getImplementationAuthority(),
            address(trexImplementationAuthority),
            "Factory should reference IA"
        );
        assertEq(trexFactory.getIdFactory(), address(idFactory), "Factory should reference IdentityFactory");
    }

    // ============ deployTREXSuite() Tests ============

    // Access Control Tests
    function test_deployTREXSuite_RevertWhen_NotOwner() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    // Validation Tests
    function test_deployTREXSuite_RevertWhen_SaltAlreadyUsed() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        // First deployment should succeed
        _deploySuite("salt2", tokenDetails, claimDetails);

        // Second deployment with same salt should revert
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TokenAlreadyDeployed.selector);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_InvalidClaimPattern() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();

        address[] memory issuers = new address[](1);
        issuers[0] = address(0x123);
        uint256[][] memory issuerClaims = new uint256[][](0); // Empty array - mismatch

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: new uint256[](0), issuers: issuers, issuerClaims: issuerClaims });

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidClaimPattern.selector);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_MoreThan5ClaimIssuers() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();

        address[] memory issuers = new address[](6); // 6 issuers > 5
        uint256[][] memory issuerClaims = new uint256[][](6);

        for (uint256 i = 0; i < 6; i++) {
            issuers[i] = address(uint160(i + 1));
            issuerClaims[i] = new uint256[](0);
        }

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: new uint256[](0), issuers: issuers, issuerClaims: issuerClaims });

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimIssuersReached.selector, 5));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_MoreThan5ClaimTopics() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();

        uint256[] memory claimTopics = new uint256[](6); // 6 topics > 5
        for (uint256 i = 0; i < 6; i++) {
            claimTopics[i] = uint256(i);
        }

        ITREXFactory.ClaimDetails memory claimDetails = ITREXFactory.ClaimDetails({
            claimTopics: claimTopics, issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 5));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_MoreThan5Agents() public {
        address[] memory irAgents = new address[](6); // 6 agents > 5
        for (uint256 i = 0; i < 6; i++) {
            irAgents[i] = address(uint160(i + 100));
        }

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: irAgents,
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });

        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxAgentsReached.selector, 5));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_MoreThan25ComplianceModules() public {
        address[] memory complianceModules = new address[](26); // 26 modules > 25
        for (uint256 i = 0; i < 26; i++) {
            complianceModules[i] = address(uint160(i + 200));
            // make each address behave like a bindable plug-and-play module so init binds the first
            // 25 and reaches ModularCompliance's own 25-module cap on the 26th, instead of failing
            // earlier on a call to a non-contract address
            vm.mockCall(complianceModules[i], abi.encodeWithSelector(IModule.isPlugAndPlay.selector), abi.encode(true));
            vm.mockCall(complianceModules[i], abi.encodeWithSelector(IModule.bindCompliance.selector), abi.encode());
            vm.mockCall(
                complianceModules[i],
                abi.encodeWithSelector(IModule.moduleCapabilities.selector),
                abi.encode(ModuleCapabilitiesLib.CHECK_TRANSFER)
            );
        }

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: complianceModules,
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });

        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxModulesReached.selector, 25));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_InvalidCompliancePattern() public {
        address[] memory complianceModules = new address[](1);
        complianceModules[0] = address(0x456);

        bytes[] memory complianceSettings = new bytes[](2); // 2 settings > 1 module

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: complianceModules,
            complianceSettings: complianceSettings,
            accessManager: address(accessManager)
        });

        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidCompliancePattern.selector);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_Success() public {
        // The TIR only records issuer addresses; it never calls back into them.
        address claimIssuer = makeAddr("suiteClaimIssuer");
        uint256 claimTopic = 1;

        _runDeployTREXSuiteSuccess(claimIssuer, claimTopic);

        address tokenAddress = trexFactory.getToken("salt2");
        assertNotEq(tokenAddress, address(0), "Token should be deployed");

        _assertDeployTREXSuiteSuccess(tokenAddress, claimTopic, address(claimIssuer));
    }

    // Replaces the removed AddressPredictionMismatch require: CREATE3 makes each suite contract's
    // address a pure function of (factory, salt, contractType). These assertions lock in that the
    // factory deploys Token and IR at the exact addresses it predicted and wired into dependents
    // (the predicted Token address into its OnchainID, the predicted IR address into the IRS proxy).
    function test_deployTREXSuite_DeployedAddressesMatchPredicted() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("predict-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("predict-salt"));

        assertEq(
            address(deployedToken),
            _predictSuiteAddress("predict-salt", "Token"),
            "Token must deploy at its predicted CREATE3 address"
        );
        assertEq(
            address(deployedToken.identityRegistry()),
            _predictSuiteAddress("predict-salt", "REGISTRY"),
            "IR must deploy at its predicted CREATE3 address"
        );
    }

    function _runDeployTREXSuiteSuccess(address claimIssuer, uint256 claimTopic) internal {
        // Deploy TestModule (implementation + proxy)
        TestModule testModuleImplementation = new TestModule();
        bytes memory initData = abi.encodeWithSelector(TestModule.initialize.selector);
        ModuleProxy testModuleProxy = new ModuleProxy(address(testModuleImplementation), initData);
        TestModule testModule = TestModule(address(testModuleProxy));

        // Prepare TokenDetails with agents and modules
        address[] memory irAgents = new address[](1);
        irAgents[0] = alice;
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = bob;
        address[] memory complianceModules = new address[](1);
        complianceModules[0] = address(testModule);

        // Encode blockModule function call, this function is included in the TestModule
        bytes memory blockModuleCall = abi.encodeWithSignature("blockModule(bool)", true);
        bytes[] memory complianceSettings = new bytes[](1);
        complianceSettings[0] = blockModuleCall;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: irAgents,
            tokenAgents: tokenAgents,
            complianceModules: complianceModules,
            complianceSettings: complianceSettings,
            accessManager: address(accessManager)
        });

        // Prepare ClaimDetails
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = claimTopic;

        address[] memory issuers = new address[](1);
        issuers[0] = address(claimIssuer);

        uint256[][] memory issuerClaims = new uint256[][](1);
        uint256[] memory claims = new uint256[](1);
        claims[0] = claimTopic;
        issuerClaims[0] = claims;

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: claimTopics, issuers: issuers, issuerClaims: issuerClaims });

        _deploySuite("salt2", tokenDetails, claimDetails);
    }

    function _assertDeployTREXSuiteSuccess(address tokenAddress, uint256 claimTopic, address claimIssuerAddress)
        internal
        view
    {
        Token deployedToken = Token(tokenAddress);

        // Verify token configuration
        assertEq(deployedToken.name(), "Token name", "Token name should match");
        assertEq(deployedToken.symbol(), "SYM", "Token symbol should match");

        // Verify CTR is owned by the suite AccessManager
        TREXRegistry ctr = TREXRegistry(address(deployedToken.identityRegistry().topicsRegistry()));
        assertEq(
            IAccessManaged(address(ctr)).authority(),
            address(accessManager),
            "CTR owner must be the suite AccessManager"
        );

        uint256[] memory storedTopics = ctr.getClaimTopics();
        assertEq(storedTopics.length, 1, "CTR should have 1 initial topic");
        assertEq(storedTopics[0], claimTopic, "CTR topic should match input");

        // Verify TIR is owned by the suite AccessManager
        TREXRegistry tir = TREXRegistry(address(deployedToken.identityRegistry().issuersRegistry()));
        assertEq(
            IAccessManaged(address(tir)).authority(),
            address(accessManager),
            "TIR owner must be the suite AccessManager"
        );
        assertTrue(tir.isTrustedIssuer(claimIssuerAddress), "Claim issuer should be registered in TIR");

        // Verify IRS is owned by the suite AccessManager and the IR is pre-bound at init time
        IdentityRegistryStorage irs =
            IdentityRegistryStorage(address(deployedToken.identityRegistry().identityStorage()));
        assertEq(
            IAccessManaged(address(irs)).authority(),
            address(accessManager),
            "IRS owner must be the suite AccessManager"
        );
        address irAddress = address(deployedToken.identityRegistry());
        address[] memory linkedIRs = irs.linkedIdentityRegistries();
        assertEq(linkedIRs.length, 1, "IRS must have exactly one linked IR after deploy");
        assertEq(linkedIRs[0], irAddress, "IRS linked IR must match the deployed IR");

        // Verify IR is owned by the suite AccessManager, with the Token and configured irAgents holding
        // the AGENT role from deploy time.
        TREXRegistry ir = TREXRegistry(irAddress);
        assertEq(
            IAccessManaged(address(ir)).authority(), address(accessManager), "IR owner must be the suite AccessManager"
        );
        assertTrue(_hasAgentRole(tokenAddress), "Deployed Token must be agent on IR");
        assertTrue(_hasAgentRole(alice), "Configured irAgent (alice) must be agent on IR");

        // Verify MC is owned by the suite AccessManager, bound to the deployed Token at init time, with
        // every configured complianceModule already bound.
        ModularCompliance mc = ModularCompliance(address(deployedToken.compliance()));
        assertEq(
            IAccessManaged(address(mc)).authority(), address(accessManager), "MC owner must be the suite AccessManager"
        );
        assertEq(mc.getTokenBound(), tokenAddress, "MC must be bound to the deployed Token at init time");

        // Verify Token is owned by the suite AccessManager, its OID was wired in via init (the auto-OID
        // path), the configured tokenAgents hold the AGENT role, and the factory holds no AGENT role.
        assertEq(
            IAccessManaged(address(deployedToken)).authority(),
            address(accessManager),
            "Token owner must be the suite AccessManager"
        );
        assertNotEq(deployedToken.onchainID(), address(0), "Token OID must be wired in at init time");
        assertEq(
            _identityOf(tokenAddress),
            deployedToken.onchainID(),
            "Token OID must match the one minted by IdentityFactory for the predicted Token address"
        );
        assertTrue(_hasAgentRole(bob), "Configured tokenAgent (bob) must be agent on Token");
        assertFalse(_hasAgentRole(address(trexFactory)), "Factory must not be agent on Token");
    }

    /// @notice TIR must be owned by the suite AccessManager
    function test_deployTREXSuite_TIR_OwnershipAndIssuers_SetAtInit() public {
        address issuerA = makeAddr("issuerA");
        address issuerB = makeAddr("issuerB");

        address[] memory issuers = new address[](2);
        issuers[0] = address(issuerA);
        issuers[1] = address(issuerB);

        uint256[][] memory issuerClaims = new uint256[][](2);
        uint256[] memory topicsA = new uint256[](2);
        topicsA[0] = 42;
        topicsA[1] = 1337;
        issuerClaims[0] = topicsA;
        uint256[] memory topicsB = new uint256[](1);
        topicsB[0] = 99;
        issuerClaims[1] = topicsB;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: new uint256[](0), issuers: issuers, issuerClaims: issuerClaims });

        _deploySuite("tir-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("tir-init-salt"));
        TREXRegistry tir = TREXRegistry(address(deployedToken.identityRegistry().issuersRegistry()));

        assertEq(
            IAccessManaged(address(tir)).authority(),
            address(accessManager),
            "TIR owner must be the suite AccessManager"
        );

        assertTrue(tir.isTrustedIssuer(address(issuerA)), "issuerA must be registered after init");
        assertTrue(tir.isTrustedIssuer(address(issuerB)), "issuerB must be registered after init");

        uint256[] memory storedTopicsA = tir.getTrustedIssuerClaimTopics(address(issuerA));
        assertEq(storedTopicsA.length, 2, "TIR topics length for issuerA must match input");
        assertEq(storedTopicsA[0], 42, "first topic for issuerA must match input");
        assertEq(storedTopicsA[1], 1337, "second topic for issuerA must match input");

        uint256[] memory storedTopicsB = tir.getTrustedIssuerClaimTopics(address(issuerB));
        assertEq(storedTopicsB.length, 1, "TIR topics length for issuerB must match input");
        assertEq(storedTopicsB[0], 99, "topic for issuerB must match input");
    }

    /// @notice CTR must be owned by the suite AccessManager
    function test_deployTREXSuite_CTR_OwnershipAndTopics_SetAtInit() public {
        uint256[] memory claimTopics = new uint256[](2);
        claimTopics[0] = 42;
        claimTopics[1] = 1337;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });

        ITREXFactory.ClaimDetails memory claimDetails = ITREXFactory.ClaimDetails({
            claimTopics: claimTopics, issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        _deploySuite("ctr-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("ctr-init-salt"));
        TREXRegistry ctr = TREXRegistry(address(deployedToken.identityRegistry().topicsRegistry()));

        assertEq(
            IAccessManaged(address(ctr)).authority(),
            address(accessManager),
            "CTR owner must be the suite AccessManager"
        );

        uint256[] memory storedTopics = ctr.getClaimTopics();
        assertEq(storedTopics.length, 2, "CTR.getClaimTopics length must match _claimDetails.claimTopics");
        assertEq(storedTopics[0], claimTopics[0], "first topic must match input");
        assertEq(storedTopics[1], claimTopics[1], "second topic must match input");
    }

    /// @notice IRS must be owned by the suite AccessManager, with the deployed IR pre-bound at init time
    function test_deployTREXSuite_IRS_OwnershipAndIRBinding_SetAtInit() public {
        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("irs-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("irs-init-salt"));
        IdentityRegistryStorage irs =
            IdentityRegistryStorage(address(deployedToken.identityRegistry().identityStorage()));
        address irAddress = address(deployedToken.identityRegistry());

        assertEq(
            IAccessManaged(address(irs)).authority(),
            address(accessManager),
            "IRS owner must be the suite AccessManager"
        );

        address[] memory linkedIRs = irs.linkedIdentityRegistries();
        assertEq(linkedIRs.length, 1, "IRS.linkedIdentityRegistries must contain exactly one IR after deploy");
        assertEq(linkedIRs[0], irAddress, "IRS.linkedIdentityRegistries[0] must match the deployed IR");
    }

    /// @notice MC must be owned by the suite AccessManager, bound to the deployed Token at init time with
    ///         every configured complianceModule already bound (no post-deploy `addModule` loop)
    function test_deployTREXSuite_MC_OwnershipAndTokenBinding_SetAtInit() public {
        // Deploy TestModule (implementation + proxy) so the configured module passes the isPlugAndPlay check
        TestModule testModuleImplementation = new TestModule();
        bytes memory initData = abi.encodeWithSelector(TestModule.initialize.selector);
        ModuleProxy testModuleProxy = new ModuleProxy(address(testModuleImplementation), initData);
        TestModule testModule = TestModule(address(testModuleProxy));

        address[] memory complianceModules = new address[](1);
        complianceModules[0] = address(testModule);

        bytes[] memory complianceSettings = new bytes[](1);
        complianceSettings[0] = abi.encodeWithSignature("blockModule(bool)", true);

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: complianceModules,
            complianceSettings: complianceSettings,
            accessManager: address(accessManager)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("mc-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("mc-init-salt"));
        ModularCompliance mc = ModularCompliance(address(deployedToken.compliance()));

        assertEq(
            IAccessManaged(address(mc)).authority(), address(accessManager), "MC owner must be the suite AccessManager"
        );
        assertEq(
            mc.getTokenBound(),
            address(deployedToken),
            "MC.getTokenBound must equal the deployed Token immediately after deployTREXSuite"
        );
        assertTrue(mc.isModuleBound(address(testModule)), "configured complianceModule must be bound at init time");
        assertTrue(
            testModule.getBlockedTransfers(address(mc)),
            "configured complianceSetting must be applied to the module at init time"
        );
    }

    /// @notice Token must be owned by the suite AccessManager, with the configured tokenAgents pre-granted
    ///         at init time, the OID minted by IdentityFactory and wired in at init time, and the factory holding
    ///         no role on the Token (no agent, no pending ownership)
    function test_deployTREXSuite_Token_OwnershipAgentsAndOID_SetAtInit() public {
        address[] memory tokenAgents = new address[](2);
        tokenAgents[0] = bob;
        tokenAgents[1] = charlie;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: tokenAgents,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("token-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("token-init-salt"));

        assertEq(
            IAccessManaged(address(deployedToken)).authority(),
            address(accessManager),
            "Token owner must be the suite AccessManager"
        );

        assertNotEq(deployedToken.onchainID(), address(0), "Token OID must be wired in at init time");
        assertEq(
            _identityOf(address(deployedToken)),
            deployedToken.onchainID(),
            "Token OID must match the IdentityFactory-registered identity for the deployed Token address"
        );

        assertTrue(_hasAgentRole(bob), "Configured tokenAgent bob must be agent on Token after init");
        assertTrue(_hasAgentRole(charlie), "Configured tokenAgent charlie must be agent on Token after init");
        assertFalse(_hasAgentRole(address(trexFactory)), "Factory must not be agent on Token");
    }

    /// @notice When the caller supplies an ONCHAINID, Token.onchainID must equal that exact address (and the
    ///         factory must NOT have created a new identity via IdentityFactory)
    function test_deployTREXSuite_Token_UsesProvidedONCHAINID() public {
        // Spawn a stand-in OID address. We don't deploy a real Identity contract because Token.init only
        // stores `onchainId` as an address — it does not call into it during init.
        address suppliedOID = makeAddr("SuppliedOID");

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: suppliedOID,
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("token-provided-oid-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("token-provided-oid-salt"));
        assertEq(deployedToken.onchainID(), suppliedOID, "Token.onchainID must equal the supplied ONCHAINID");
        assertEq(
            _identityOf(address(deployedToken)),
            address(0),
            "IdentityFactory must not have minted a new identity when ONCHAINID was supplied"
        );
    }

    /// @notice The auto-mint path is gated on the factory holding ASSET_DEPLOYER at the IdentityFactory's
    ///         own authority. Strip the role and a deploy that leaves ONCHAINID at zero must revert from
    ///         inside `createIdentityFor`, not silently fall back to a zero OID.
    /// @dev Locks the deploy-time prerequisite documented on `TREXFactory._deployToken` and bundled by
    ///      `AccessManagerSetupLib.setupIdentityFactoryPolicy`. The suite grants this role in
    ///      `_deployFactories`, so the test has to revoke it first.
    function test_deployTREXSuite_RevertWhen_FactoryLacksTokenOidMinter() public {
        // Revoked as the test contract, which is the AccessManager admin (see AccessManagerHelper).
        accessManager.revokeRole(RolesLib.ASSET_DEPLOYER, address(trexFactory));

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        assertEq(tokenDetails.ONCHAINID, address(0), "Test only covers the auto-mint path");

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.NotAuthorizedForIdentityType.selector,
                address(trexFactory),
                IdentityTypes.ASSET,
                RolesLib.ASSET_DEPLOYER
            )
        );
        _deploySuite("no-oid-minter-salt", tokenDetails, _createEmptyClaimDetails());
    }

    /// @notice The ASSET_DEPLOYER gate covers minting only. With the role revoked, a caller-supplied
    ///         ONCHAINID must still deploy, since that path never calls `createIdentityFor`.
    function test_deployTREXSuite_Succeeds_WithoutTokenOidMinter_WhenONCHAINIDSupplied() public {
        accessManager.revokeRole(RolesLib.ASSET_DEPLOYER, address(trexFactory));

        address suppliedOID = makeAddr("SuppliedOID");
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.ONCHAINID = suppliedOID;

        _deploySuite("no-oid-minter-supplied-salt", tokenDetails, _createEmptyClaimDetails());

        Token deployedToken = Token(trexFactory.getToken("no-oid-minter-supplied-salt"));
        assertEq(deployedToken.onchainID(), suppliedOID, "Supplied ONCHAINID must survive the missing role");
    }

    // ============ AccessManagerSetupLib.setupIdentityFactoryPolicy() Tests ============

    /// @notice The helper must be sufficient wiring on its own: starting from a fully unwired state
    ///         (ASSET unregistered on the IdentityFactory, factory holding no ASSET_DEPLOYER), the
    ///         single call restores the auto-mint path end to end.
    /// @dev Nothing in production calls this helper — it exists for deployers, and `TREXFactory._deployToken`
    ///      points at it — so without a test it would rot silently against IdentityFactory changes.
    /// @dev Teardown and the helper both run as the test contract, which is the AccessManager admin and
    ///      therefore satisfies the helper's two documented reachability conditions: it can call the
    ///      `restricted` `setIdentityTypePolicy`, and it is ASSET_DEPLOYER's role admin.
    function test_setupIdentityFactoryPolicy_RestoresAutoMintPath() public {
        // Undo both prerequisites the suite wires by hand in `_registerIdentityTypePolicies` and
        // `_deployFactories`. roleId 0 unregisters the type, so even a role holder is rejected.
        idFactory.setIdentityTypePolicy(IdentityTypes.ASSET, 0, false);
        accessManager.revokeRole(RolesLib.ASSET_DEPLOYER, address(trexFactory));

        AccessManagerSetupLib.setupIdentityFactoryPolicy(accessManager, idFactory, address(trexFactory));

        (uint64 roleId, bool selfDeployable) = idFactory.getIdentityTypePolicy(IdentityTypes.ASSET);
        assertEq(roleId, RolesLib.ASSET_DEPLOYER, "ASSET minting must be gated behind ASSET_DEPLOYER");
        assertFalse(selfDeployable, "A token must not be able to self-deploy its own OID");

        (bool isMember, uint32 executionDelay) = accessManager.hasRole(RolesLib.ASSET_DEPLOYER, address(trexFactory));
        assertTrue(isMember, "TREX factory must hold ASSET_DEPLOYER after the helper call");
        // Auto-mint is a direct call from inside deployTREXSuite; a delay would make it unschedulable.
        assertEq(executionDelay, NO_EXECUTION_DELAY, "ASSET_DEPLOYER must be granted without execution delay");

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        assertEq(tokenDetails.ONCHAINID, address(0), "Test only covers the auto-mint path");

        _deploySuite("setup-policy-salt", tokenDetails, _createEmptyClaimDetails());

        Token deployedToken = Token(trexFactory.getToken("setup-policy-salt"));
        assertNotEq(deployedToken.onchainID(), address(0), "Auto-mint must have produced a token OID");
        assertEq(
            _identityOf(address(deployedToken)),
            deployedToken.onchainID(),
            "Token OID must match the IdentityFactory-registered identity for the deployed Token address"
        );
    }

    /// @notice Locks the footgun the helper's NatSpec warns about: `createIdentityFor` resolves
    ///         ASSET_DEPLOYER against the IdentityFactory's own `authority()`, so passing any other
    ///         manager grants the role somewhere the check never looks and auto-mint still reverts.
    function test_setupIdentityFactoryPolicy_RevertWhen_RoleGrantedOnForeignAuthority() public {
        idFactory.setIdentityTypePolicy(IdentityTypes.ASSET, 0, false);
        accessManager.revokeRole(RolesLib.ASSET_DEPLOYER, address(trexFactory));

        // Not the IdentityFactory's authority. The policy write still lands (that call is routed by the
        // factory's real authority), but the grant is stranded on this manager.
        AccessManager foreignManager = new AccessManager(address(this));
        AccessManagerSetupLib.setupIdentityFactoryPolicy(foreignManager, idFactory, address(trexFactory));

        (bool isMemberOnForeign,) = foreignManager.hasRole(RolesLib.ASSET_DEPLOYER, address(trexFactory));
        assertTrue(isMemberOnForeign, "Grant must have landed on the foreign manager");
        (bool isMemberOnAuthority,) = accessManager.hasRole(RolesLib.ASSET_DEPLOYER, address(trexFactory));
        assertFalse(isMemberOnAuthority, "Grant must be absent from the authority the factory actually checks");

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.NotAuthorizedForIdentityType.selector,
                address(trexFactory),
                IdentityTypes.ASSET,
                RolesLib.ASSET_DEPLOYER
            )
        );
        _deploySuite("foreign-authority-salt", _createEmptyTokenDetails(), _createEmptyClaimDetails());
    }

    /// @notice IR must be owned by the suite AccessManager, with the Token + irAgents pre-granted at init time
    function test_deployTREXSuite_IR_OwnershipAndAgents_SetAtInit() public {
        address[] memory irAgents = new address[](2);
        irAgents[0] = bob;
        irAgents[1] = charlie;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: irAgents,
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("ir-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("ir-init-salt"));
        TREXRegistry ir = TREXRegistry(address(deployedToken.identityRegistry()));

        assertEq(
            IAccessManaged(address(ir)).authority(), address(accessManager), "IR owner must be the suite AccessManager"
        );

        assertTrue(_hasAgentRole(address(deployedToken)), "Token must be agent on IR after init");
        assertTrue(_hasAgentRole(bob), "Configured irAgent bob must be agent on IR after init");
        assertTrue(_hasAgentRole(charlie), "Configured irAgent charlie must be agent on IR after init");
    }

    /// @notice End-to-end guard: with a fully-populated `_claimTopics`, `_issuers`, `_irAgents`,
    ///         `_tokenAgents`, `_complianceModules` + `_complianceSettings`, and the auto-OID path
    ///         (`ONCHAINID == address(0)`), every configuration item must land at init time, all six
    ///         suite contracts must end up owned by the suite AccessManager, and the factory must hold
    ///         no role on any suite contract.
    function test_deployTREXSuite_FullConfig_FactoryOwnsNothing() public {
        (address testModuleAddr, address issuerAddr) = _runFullConfigDeploy("full-config-salt");
        _assertFullConfigSuite("full-config-salt", testModuleAddr, issuerAddr);
    }

    /// @notice Builds and submits a fully-populated `TokenDetails` + `ClaimDetails` to the factory.
    function _runFullConfigDeploy(string memory salt) internal returns (address testModuleAddr, address issuerAddr) {
        // Deploy TestModule (implementation + proxy) so the configured module passes isPlugAndPlay
        TestModule testModuleImplementation = new TestModule();
        ModuleProxy testModuleProxy =
            new ModuleProxy(address(testModuleImplementation), abi.encodeWithSelector(TestModule.initialize.selector));
        testModuleAddr = address(testModuleProxy);

        // Issuer for the TIR + claim topic. The TIR only records the address.
        issuerAddr = makeAddr("tirClaimIssuer");

        address[] memory irAgents = new address[](1);
        irAgents[0] = alice;
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = bob;

        address[] memory complianceModules = new address[](1);
        complianceModules[0] = testModuleAddr;
        bytes[] memory complianceSettings = new bytes[](1);
        complianceSettings[0] = abi.encodeWithSignature("blockModule(bool)", true);

        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1;
        address[] memory issuers = new address[](1);
        issuers[0] = issuerAddr;
        uint256[][] memory issuerClaims = new uint256[][](1);
        uint256[] memory claims = new uint256[](1);
        claims[0] = 1;
        issuerClaims[0] = claims;

        _deploySuite(
            salt,
            ITREXFactory.TokenDetails({
                name: "Token name",
                symbol: "SYM",
                decimals: 8,
                irs: address(0),
                ONCHAINID: address(0),
                irAgents: irAgents,
                tokenAgents: tokenAgents,
                complianceModules: complianceModules,
                complianceSettings: complianceSettings,
                accessManager: address(accessManager)
            }),
            ITREXFactory.ClaimDetails({ claimTopics: claimTopics, issuers: issuers, issuerClaims: issuerClaims })
        );
    }

    /// @notice Verifies that every config item landed at init time and the factory holds no role on any
    ///         suite contract. Split out of the test body so the function fits inside the stack budget.
    function _assertFullConfigSuite(string memory salt, address testModuleAddr, address issuerAddr) internal view {
        Token deployedToken = Token(trexFactory.getToken(salt));
        TREXRegistry ir = TREXRegistry(address(deployedToken.identityRegistry()));
        _assertFullConfigOwnership(deployedToken, ir);
        _assertFullConfigInitState(deployedToken, ir, testModuleAddr, issuerAddr);
    }

    /// @notice All 6 suite contracts must report the suite AccessManager as their authority.
    function _assertFullConfigOwnership(Token deployedToken, TREXRegistry ir) internal view {
        assertEq(
            IAccessManaged(address(ir.topicsRegistry())).authority(),
            address(accessManager),
            "CTR authority must be the suite AccessManager"
        );
        assertEq(
            IAccessManaged(address(ir.issuersRegistry())).authority(),
            address(accessManager),
            "TIR authority must be the suite AccessManager"
        );
        assertEq(
            IAccessManaged(address(ir.identityStorage())).authority(),
            address(accessManager),
            "IRS authority must be the suite AccessManager"
        );
        assertEq(
            IAccessManaged(address(ir)).authority(),
            address(accessManager),
            "IR authority must be the suite AccessManager"
        );
        assertEq(
            IAccessManaged(address(deployedToken.compliance())).authority(),
            address(accessManager),
            "MC authority must be the suite AccessManager"
        );
        assertEq(
            IAccessManaged(address(deployedToken)).authority(),
            address(accessManager),
            "Token authority must be the suite AccessManager"
        );
    }

    /// @notice Topics, issuers, agents, modules, settings, OID, IRS binding all in place at init time.
    function _assertFullConfigInitState(
        Token deployedToken,
        TREXRegistry ir,
        address testModuleAddr,
        address issuerAddr
    ) internal view {
        TREXRegistry ctr = TREXRegistry(address(ir.topicsRegistry()));
        uint256[] memory storedTopics = ctr.getClaimTopics();
        assertEq(storedTopics.length, 1, "CTR must have the configured claim topic");
        assertEq(storedTopics[0], 1, "CTR topic must match input");

        TREXRegistry tir = TREXRegistry(address(ir.issuersRegistry()));
        assertTrue(tir.isTrustedIssuer(issuerAddr), "TIR must have the configured issuer registered");

        IdentityRegistryStorage irs = IdentityRegistryStorage(address(ir.identityStorage()));
        address[] memory linkedIRs = irs.linkedIdentityRegistries();
        assertEq(linkedIRs.length, 1, "IRS must have the deployed IR bound at init time");
        assertEq(linkedIRs[0], address(ir), "IRS.linkedIdentityRegistries[0] must match the deployed IR");

        assertTrue(_hasAgentRole(address(deployedToken)), "Token must be agent on IR after init");
        assertTrue(_hasAgentRole(alice), "Configured irAgent must be agent on IR after init");

        ModularCompliance mc = ModularCompliance(address(deployedToken.compliance()));
        assertEq(mc.getTokenBound(), address(deployedToken), "MC must be bound to the deployed Token at init time");
        assertTrue(mc.isModuleBound(testModuleAddr), "Configured compliance module must be bound at init time");
        assertTrue(
            TestModule(testModuleAddr).getBlockedTransfers(address(mc)),
            "Configured compliance setting must be applied to the module at init time"
        );

        assertNotEq(deployedToken.onchainID(), address(0), "Token OID must be wired in at init time");
        assertEq(
            _identityOf(address(deployedToken)),
            deployedToken.onchainID(),
            "Token OID must match the IdentityFactory-registered identity for the deployed Token address"
        );
        assertTrue(_hasAgentRole(bob), "Configured tokenAgent must be agent on Token after init");
    }

    /// @notice deployTREXSuite must grant the AGENT role to the token, the IR and every configured
    ///         agent, with the factory holding only the AGENT_ADMIN role on the AccessManager
    function test_deployTREXSuite_GrantsAgentRoles() public {
        address[] memory irAgents = new address[](1);
        irAgents[0] = alice;
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = bob;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: irAgents,
            tokenAgents: tokenAgents,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });

        assertFalse(_hasAgentRole(alice), "precondition: irAgent must not hold AGENT yet");
        assertFalse(_hasAgentRole(bob), "precondition: tokenAgent must not hold AGENT yet");

        _deploySuite("agent-grant-salt", tokenDetails, _createEmptyClaimDetails());

        Token deployedToken = Token(trexFactory.getToken("agent-grant-salt"));
        address ir = address(deployedToken.identityRegistry());

        assertTrue(_hasAgentRole(address(deployedToken)), "Token must hold AGENT after deployTREXSuite");
        assertTrue(_hasAgentRole(ir), "IR must hold AGENT after deployTREXSuite");
        assertTrue(_hasAgentRole(alice), "Configured irAgent must hold AGENT after deployTREXSuite");
        assertTrue(_hasAgentRole(bob), "Configured tokenAgent must hold AGENT after deployTREXSuite");
    }

    // ============ getToken() Tests ============

    function test_getToken_ReturnsTokenAddress() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("salt2", tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken("salt2");
        assertNotEq(tokenAddress, address(0), "Token address should not be zero");
    }

    // ============ constructor() Tests ============

    function test_constructor_RevertWhen_AccessManagerZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXFactory(
            address(trexImplementationAuthority),
            address(idFactory),
            address(keyApprovalModule),
            address(validatorModule),
            address(0)
        );
    }

    function test_constructor_RevertWhen_IdentityModuleZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXFactory(
            address(trexImplementationAuthority),
            address(idFactory),
            address(0),
            address(validatorModule),
            address(accessManager)
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXFactory(
            address(trexImplementationAuthority),
            address(idFactory),
            address(keyApprovalModule),
            address(0),
            address(accessManager)
        );
    }

    function test_setIdentityModules_Success() public {
        address newKeyApprovalModule = makeAddr("newKeyApprovalModule");
        address newValidatorModule = makeAddr("newValidatorModule");

        vm.prank(deployer);
        trexFactory.setIdentityModules(newKeyApprovalModule, newValidatorModule);

        (address keyApproval, address validator) = trexFactory.getIdentityModules();
        assertEq(keyApproval, newKeyApprovalModule);
        assertEq(validator, newValidatorModule);
    }

    function test_setIdentityModules_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trexFactory.setIdentityModules(address(keyApprovalModule), address(validatorModule));
    }

    // ============ setImplementationAuthority() Tests ============

    function test_setImplementationAuthority_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexFactory.setImplementationAuthority(address(0));
    }

    function test_setImplementationAuthority_RevertWhen_IncompleteIA() public {
        // Deploy a new IA but don't add any version (incomplete)
        TREXImplementationAuthority incompleteIA =
            new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));
        _authorizeIAGovernance(address(incompleteIA));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidImplementationAuthority.selector);
        trexFactory.setImplementationAuthority(address(incompleteIA));
    }

    function test_setImplementationAuthority_Success() public {
        // Deploy a complete IA using the helper
        TREXImplementationAuthority newIA = _deployTREXImplementationAuthority(true);

        vm.prank(deployer);
        trexFactory.setImplementationAuthority(address(newIA));

        assertEq(trexFactory.getImplementationAuthority(), address(newIA), "Implementation Authority should be updated");
    }

    function test_deployTREXSuite_RevertWhen_CREATE2Fails() public {
        // Deploy test factory that invoke the internal functon _deploy
        TestTREXFactory testFactory = new TestTREXFactory(
            address(trexImplementationAuthority),
            address(idFactory),
            address(keyApprovalModule),
            address(validatorModule),
            address(accessManager)
        );

        // Use empty bytecode so the CREATE2 will return address(0)
        bytes memory emptyBytecode = new bytes(0);

        vm.expectRevert(); // Should revert from the assembly revert(0, 0) because CREATE2 will return address(0) so the extcodesize(address(0)) = 0
        testFactory.testDeploy("test-salt-empty", emptyBytecode);
    }

    // ============ setIdFactory() Tests ============

    function test_setIdFactory_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexFactory.setIdFactory(address(0));
    }

    function test_setIdFactory_Success() public {
        IdentityFactory newIdFactory = _newIdentityFactory();

        vm.prank(deployer);
        trexFactory.setIdFactory(address(newIdFactory));

        assertEq(trexFactory.getIdFactory(), address(newIdFactory), "IdentityFactory should be updated");
    }

    /// @notice Should revert when the CREATE3 target address already contains code
    function test_deployTREXSuite_RevertWhen_Create3AddressCollides() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        string memory salt = "collision-salt";

        // The first contract deployed by deployTREXSuite is the IRS. Pre-populating code at its
        // predicted CREATE3 address makes the inner CREATE return zero, so the deploy reverts.
        vm.etch(_predictSuiteAddress(salt, "IRS"), hex"60006000");

        vm.prank(deployer);
        vm.expectRevert();
        trexFactory.deployTREXSuite(salt, tokenDetails, claimDetails);
    }

    /// @notice Should deploy TREX suite when irs is provided (not address(0))
    function test_deployTREXSuite_Success_WithProvidedIRS() public {
        // First deploy a TREX suite to get an IRS that's already properly set up
        ITREXFactory.TokenDetails memory tempTokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory tempClaimDetails = _createEmptyClaimDetails();

        _deploySuite("temp-salt", tempTokenDetails, tempClaimDetails);

        // Get the IRS from the deployed token's identity registry
        address tempTokenAddress = trexFactory.getToken("temp-salt");
        Token tempToken = Token(tempTokenAddress);
        address irAddress = address(tempToken.identityRegistry());
        IERC3643IdentityRegistry ir = IERC3643IdentityRegistry(irAddress);
        address deployedIRS = address(ir.identityStorage());

        require(deployedIRS != address(0), "IRS should be deployed");

        // Wire bindIdentityRegistry -> IRS_BINDER on the reused IRS. The factory does NOT get any
        // standing role here: it self-grants IRS_BINDER (admin = AGENT_ADMIN, which it already holds)
        // for the bind window during deployTREXSuite and revokes it before returning.
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, deployedIRS);

        // Sanity: the factory holds neither OWNER nor IRS_BINDER going into the reused-IRS deploy.
        (bool hasOwner,) = accessManager.hasRole(RolesLib.OWNER, address(trexFactory));
        (bool hasBinder,) = accessManager.hasRole(RolesLib.IRS_BINDER, address(trexFactory));
        assertFalse(hasOwner, "Factory must not hold standing OWNER");
        assertFalse(hasBinder, "Factory must not hold standing IRS_BINDER before deploy");

        // Now use the deployed IRS in a new deployment
        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: deployedIRS, // Use provided IRS instead of address(0)
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        _deploySuite("salt-irs", tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken("salt-irs");
        assertNotEq(tokenAddress, address(0), "Token should be deployed");

        // Verify both tokens share the same identity registry storage
        Token newToken = Token(tokenAddress);
        IERC3643IdentityRegistry newIR = newToken.identityRegistry();
        IERC3643IdentityRegistry tempIR = tempToken.identityRegistry();
        assertEq(
            address(newIR.identityStorage()),
            address(tempIR.identityStorage()),
            "Both tokens should share the same identity registry storage"
        );

        // Reused-IRS path must bind the new IR (regression guard for Part 3)
        IdentityRegistryStorage reusedIRS = IdentityRegistryStorage(deployedIRS);
        address[] memory linked = reusedIRS.linkedIdentityRegistries();
        assertEq(linked.length, 2, "Reused IRS should have both old and new IR bound");

        bool sawOld;
        bool sawNew;
        for (uint256 i = 0; i < linked.length; i++) {
            if (linked[i] == address(tempIR)) sawOld = true;
            if (linked[i] == address(newIR)) sawNew = true;
        }
        assertTrue(sawOld, "Reused IRS should still have the old IR bound");
        assertTrue(sawNew, "Reused IRS should have the new IR bound");

        // Transient-grant invariant: the factory must hold no standing privilege over the IRS after
        // the deploy. IRS_BINDER was self-granted only for the bind call and revoked before return.
        (bool stillBinder,) = accessManager.hasRole(RolesLib.IRS_BINDER, address(trexFactory));
        assertFalse(stillBinder, "Factory must not retain IRS_BINDER after deploy");
        (bool stillOwner,) = accessManager.hasRole(RolesLib.OWNER, address(trexFactory));
        assertFalse(stillOwner, "Factory must not hold standing OWNER on the IRS");
    }

    /// @notice The reused-IRS bind must fail closed when the factory cannot obtain IRS_BINDER, proving
    ///         the bind is genuinely gated and not reachable without the transient grant. Stripping the
    ///         factory's AGENT_ADMIN removes its ability to self-grant IRS_BINDER, so deployTREXSuite
    ///         reverts at the bind step.
    function test_deployTREXSuite_RevertWhen_ProvidedIRS_FactoryCannotSelfGrantBinder() public {
        // Deploy a first suite to obtain a properly initialized IRS to reuse.
        ITREXFactory.TokenDetails memory tempTokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory tempClaimDetails = _createEmptyClaimDetails();
        _deploySuite("temp-salt-2", tempTokenDetails, tempClaimDetails);

        address tempTokenAddress = trexFactory.getToken("temp-salt-2");
        Token tempToken = Token(tempTokenAddress);
        address irAddress = address(tempToken.identityRegistry());
        address deployedIRS = address(IERC3643IdentityRegistry(irAddress).identityStorage());

        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, deployedIRS);

        // Remove the factory's ability to administer IRS_BINDER (admin = AGENT_ADMIN). Without it,
        // the self-grant inside deployTREXSuite reverts and the reused-IRS bind cannot proceed.
        accessManager.revokeRole(RolesLib.AGENT_ADMIN, address(trexFactory));

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.irs = deployedIRS;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert();
        trexFactory.deployTREXSuite("salt-irs-revert", tokenDetails, claimDetails);
    }

    // ============ AccessManagerSetupLib.setupTREXImplementationAuthorityRoles() Tests ============

    /// @notice Wires the 5 TREXImplementationAuthority governance selectors to the OWNER role.
    function test_setupTREXImplementationAuthorityRoles_MapsSelectorsToOwner() public {
        address authority = address(trexImplementationAuthority);

        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, authority);

        assertEq(
            accessManager.getTargetFunctionRole(authority, TREXImplementationAuthority.setTREXFactory.selector),
            RolesLib.OWNER,
            "setTREXFactory must be mapped to OWNER"
        );
        assertEq(
            accessManager.getTargetFunctionRole(authority, TREXImplementationAuthority.setIAFactory.selector),
            RolesLib.OWNER,
            "setIAFactory must be mapped to OWNER"
        );
        assertEq(
            accessManager.getTargetFunctionRole(authority, TREXImplementationAuthority.addTREXVersion.selector),
            RolesLib.OWNER,
            "addTREXVersion must be mapped to OWNER"
        );
        assertEq(
            accessManager.getTargetFunctionRole(authority, TREXImplementationAuthority.useTREXVersion.selector),
            RolesLib.OWNER,
            "useTREXVersion must be mapped to OWNER"
        );
        assertEq(
            accessManager.getTargetFunctionRole(authority, TREXImplementationAuthority.addAndUseTREXVersion.selector),
            RolesLib.OWNER,
            "addAndUseTREXVersion must be mapped to OWNER"
        );
    }

    // ============ deployTREXSuite() branch Tests ============

    /// @notice Should revert when tokenDetails.accessManager is the zero address
    function test_deployTREXSuite_RevertWhen_AccessManagerZeroAddress() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.accessManager = address(0);
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexFactory.deployTREXSuite("salt-zero-am", tokenDetails, claimDetails);
    }

    /// @notice Should revert when a reused IRS is governed by a different AccessManager than the suite
    function test_deployTREXSuite_RevertWhen_ReusedIRS_ForeignAuthority() public {
        // Deploy a standalone IRS proxy governed by a DIFFERENT AccessManager than the suite's accessManager
        AccessManager otherAccessManager = new AccessManager(address(this));
        IdentityRegistryStorageProxy foreignIRSProxy = new IdentityRegistryStorageProxy(
            address(trexImplementationAuthority), address(otherAccessManager), address(0)
        );
        address foreignIRS = address(foreignIRSProxy);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.irs = foreignIRS;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        // bindIdentityRegistry's `restricted` guard rejects the factory: it holds no IRS_BINDER on the
        // foreign AccessManager, so the revert is AccessManagedUnauthorized, not AuthorityMismatch.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(trexFactory)));
        trexFactory.deployTREXSuite("salt-authority-mismatch", tokenDetails, claimDetails);
    }

}
