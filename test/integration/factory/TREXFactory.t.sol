// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import { IdFactory } from "@onchain-id/solidity/contracts/factory/IdFactory.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { ClaimTopicsRegistry } from "contracts/registry/implementation/ClaimTopicsRegistry.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TrustedIssuersRegistry } from "contracts/registry/implementation/TrustedIssuersRegistry.sol";
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
            owner: deployer,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: emptyAgents,
            tokenAgents: emptyAgents,
            complianceModules: emptyModules,
            complianceSettings: emptySettings
        });
    }

    // Helper function to create empty ClaimDetails
    function _createEmptyClaimDetails() internal pure returns (ITREXFactory.ClaimDetails memory) {
        uint256[] memory emptyTopics;
        address[] memory emptyIssuers;
        uint256[][] memory emptyClaims;

        return ITREXFactory.ClaimDetails({ claimTopics: emptyTopics, issuers: emptyIssuers, issuerClaims: emptyClaims });
    }

    // ============ Existing Basic Tests ============

    function test_TREXSuiteDeploys() public view {
        // Verify all components are deployed
        assertNotEq(address(trexFactory), address(0), "TREX Factory should be deployed");
        assertNotEq(address(trexImplementationAuthority), address(0), "TREX IA should be deployed");
        assertNotEq(address(idFactory), address(0), "IdFactory should be deployed");
    }

    function test_TREXFactoryLinked() public view {
        // Verify factory knows about IA
        assertEq(
            trexFactory.getImplementationAuthority(),
            address(trexImplementationAuthority),
            "Factory should reference IA"
        );
        assertEq(trexFactory.getIdFactory(), address(idFactory), "Factory should reference IdFactory");
    }

    // ============ deployTREXSuite() Tests ============

    // Access Control Tests
    function test_deployTREXSuite_RevertWhen_NotOwner() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    // Validation Tests
    function test_deployTREXSuite_RevertWhen_SaltAlreadyUsed() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        // First deployment should succeed
        vm.prank(deployer);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);

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
            owner: deployer,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: irAgents,
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });

        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxAgentsReached.selector, 5));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_MoreThan30ComplianceModules() public {
        address[] memory complianceModules = new address[](31); // 31 modules > 30
        for (uint256 i = 0; i < 31; i++) {
            complianceModules[i] = address(uint160(i + 200));
        }

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: deployer,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: complianceModules,
            complianceSettings: new bytes[](0)
        });

        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxModuleActionsReached.selector, 30));
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_RevertWhen_InvalidCompliancePattern() public {
        address[] memory complianceModules = new address[](1);
        complianceModules[0] = address(0x456);

        bytes[] memory complianceSettings = new bytes[](2); // 2 settings > 1 module

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: deployer,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: complianceModules,
            complianceSettings: complianceSettings
        });

        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidCompliancePattern.selector);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function test_deployTREXSuite_Success() public {
        // Deploy ClaimIssuer once so its address survives the inner deployment scope
        ClaimIssuer claimIssuer = new ClaimIssuer(charlie);
        uint256 claimTopic = 1;

        _runDeployTREXSuiteSuccess(claimIssuer, claimTopic);

        address tokenAddress = trexFactory.getToken("salt2");
        assertNotEq(tokenAddress, address(0), "Token should be deployed");

        _assertDeployTREXSuiteSuccess(tokenAddress, claimTopic, address(claimIssuer));
    }

    function _runDeployTREXSuiteSuccess(ClaimIssuer claimIssuer, uint256 claimTopic) internal {
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
            owner: deployer,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: irAgents,
            tokenAgents: tokenAgents,
            complianceModules: complianceModules,
            complianceSettings: complianceSettings
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

        vm.prank(deployer);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);
    }

    function _assertDeployTREXSuiteSuccess(address tokenAddress, uint256 claimTopic, address claimIssuerAddress)
        internal
        view
    {
        Token deployedToken = Token(tokenAddress);

        // Verify token configuration
        assertEq(deployedToken.name(), "Token name", "Token name should match");
        assertEq(deployedToken.symbol(), "SYM", "Token symbol should match");

        // Verify CTR is directly owned by _tokenDetails.owner (no intermediate factory ownership)
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(deployedToken.identityRegistry().topicsRegistry()));
        assertEq(ctr.owner(), deployer, "CTR owner should be the token details owner");
        assertEq(ctr.pendingOwner(), address(0), "CTR should have no pending owner");

        uint256[] memory storedTopics = ctr.getClaimTopics();
        assertEq(storedTopics.length, 1, "CTR should have 1 initial topic");
        assertEq(storedTopics[0], claimTopic, "CTR topic should match input");

        // Verify TIR is directly owned by _tokenDetails.owner (no intermediate factory ownership)
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(deployedToken.identityRegistry().issuersRegistry()));
        assertEq(tir.owner(), deployer, "TIR owner should be the token details owner");
        assertEq(tir.pendingOwner(), address(0), "TIR should have no pending owner");
        assertTrue(tir.isTrustedIssuer(claimIssuerAddress), "Claim issuer should be registered in TIR");

        // Verify IRS is directly owned by _tokenDetails.owner and the IR is pre-bound at init time
        IdentityRegistryStorage irs =
            IdentityRegistryStorage(address(deployedToken.identityRegistry().identityStorage()));
        assertEq(irs.owner(), deployer, "IRS owner should be the token details owner");
        assertEq(irs.pendingOwner(), address(0), "IRS should have no pending owner");
        address irAddress = address(deployedToken.identityRegistry());
        assertTrue(irs.isAgent(irAddress), "Deployed IR must be agent on IRS");
        address[] memory linkedIRs = irs.linkedIdentityRegistries();
        assertEq(linkedIRs.length, 1, "IRS must have exactly one linked IR after deploy");
        assertEq(linkedIRs[0], irAddress, "IRS linked IR must match the deployed IR");

        // Verify IR is directly owned by _tokenDetails.owner, with the Token and configured irAgents as
        // agents at init time (no post-deploy `addAgent` loop, no `transferOwnership` round trip).
        IdentityRegistry ir = IdentityRegistry(irAddress);
        assertEq(ir.owner(), deployer, "IR owner should be the token details owner");
        assertEq(ir.pendingOwner(), address(0), "IR should have no pending owner");
        assertTrue(ir.isAgent(tokenAddress), "Deployed Token must be agent on IR");
        assertTrue(ir.isAgent(alice), "Configured irAgent (alice) must be agent on IR");

        // Verify MC is directly owned by _tokenDetails.owner, bound to the deployed Token at init time, with
        // every configured complianceModule already bound (no post-deploy `addModule` loop, no
        // `transferOwnership` round trip).
        ModularCompliance mc = ModularCompliance(address(deployedToken.compliance()));
        assertEq(mc.owner(), deployer, "MC owner should be the token details owner");
        assertEq(mc.pendingOwner(), address(0), "MC should have no pending owner");
        assertEq(mc.getTokenBound(), tokenAddress, "MC must be bound to the deployed Token at init time");

        // Verify Token is directly owned by _tokenDetails.owner with no pending-owner state, its OID was
        // wired in via init (the auto-OID path), the configured tokenAgents are agents, and the factory
        // never became an agent on Token (regression check on the previous post-deploy `addAgent` loop).
        assertEq(deployedToken.owner(), deployer, "Token owner should be the token details owner");
        assertEq(deployedToken.pendingOwner(), address(0), "Token should have no pending owner");
        assertNotEq(deployedToken.onchainID(), address(0), "Token OID must be wired in at init time");
        assertEq(
            idFactory.getIdentity(tokenAddress),
            deployedToken.onchainID(),
            "Token OID must match the one minted by IdFactory for the predicted Token address"
        );
        assertTrue(deployedToken.isAgent(bob), "Configured tokenAgent (bob) must be agent on Token");
        assertFalse(deployedToken.isAgent(address(trexFactory)), "Factory must not be agent on Token");

        _assertFactoryHoldsNothingForToken(deployedToken);
    }

    /// @notice Re-derives every suite address from the deployed Token and forwards to
    ///         `_assertFactoryHoldsNothing`. Lives outside `_assertDeployTREXSuiteSuccess` to keep that
    ///         function within the stack budget under solc 0.8.30 without `--via-ir`.
    function _assertFactoryHoldsNothingForToken(Token deployedToken) internal view {
        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(deployedToken.identityRegistry().topicsRegistry()),
            address(deployedToken.identityRegistry().issuersRegistry()),
            address(deployedToken.identityRegistry().identityStorage()),
            address(deployedToken.identityRegistry()),
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice TIR must be owned directly by _tokenDetails.owner with no pending-owner state
    function test_deployTREXSuite_TIR_OwnershipAndIssuers_SetAtInit() public {
        ClaimIssuer issuerA = new ClaimIssuer(charlie);
        ClaimIssuer issuerB = new ClaimIssuer(bob);

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
            owner: alice,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: new uint256[](0), issuers: issuers, issuerClaims: issuerClaims });

        vm.prank(deployer);
        trexFactory.deployTREXSuite("tir-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("tir-init-salt"));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(deployedToken.identityRegistry().issuersRegistry()));

        assertEq(tir.owner(), alice, "TIR.owner must equal _tokenDetails.owner immediately after deployTREXSuite");
        assertEq(tir.pendingOwner(), address(0), "TIR.pendingOwner must be zero after deployTREXSuite");

        assertTrue(tir.isTrustedIssuer(address(issuerA)), "issuerA must be registered after init");
        assertTrue(tir.isTrustedIssuer(address(issuerB)), "issuerB must be registered after init");

        uint256[] memory storedTopicsA = tir.getTrustedIssuerClaimTopics(ClaimIssuer(address(issuerA)));
        assertEq(storedTopicsA.length, 2, "TIR topics length for issuerA must match input");
        assertEq(storedTopicsA[0], 42, "first topic for issuerA must match input");
        assertEq(storedTopicsA[1], 1337, "second topic for issuerA must match input");

        uint256[] memory storedTopicsB = tir.getTrustedIssuerClaimTopics(ClaimIssuer(address(issuerB)));
        assertEq(storedTopicsB.length, 1, "TIR topics length for issuerB must match input");
        assertEq(storedTopicsB[0], 99, "topic for issuerB must match input");

        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(deployedToken.identityRegistry().topicsRegistry()),
            address(tir),
            address(deployedToken.identityRegistry().identityStorage()),
            address(deployedToken.identityRegistry()),
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice CTR must be owned directly by _tokenDetails.owner with no pending-owner state
    function test_deployTREXSuite_CTR_OwnershipAndTopics_SetAtInit() public {
        uint256[] memory claimTopics = new uint256[](2);
        claimTopics[0] = 42;
        claimTopics[1] = 1337;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: alice,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });

        ITREXFactory.ClaimDetails memory claimDetails = ITREXFactory.ClaimDetails({
            claimTopics: claimTopics, issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.prank(deployer);
        trexFactory.deployTREXSuite("ctr-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("ctr-init-salt"));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(deployedToken.identityRegistry().topicsRegistry()));

        assertEq(ctr.owner(), alice, "CTR.owner must equal _tokenDetails.owner immediately after deployTREXSuite");
        assertEq(ctr.pendingOwner(), address(0), "CTR.pendingOwner must be zero after deployTREXSuite");

        uint256[] memory storedTopics = ctr.getClaimTopics();
        assertEq(storedTopics.length, 2, "CTR.getClaimTopics length must match _claimDetails.claimTopics");
        assertEq(storedTopics[0], claimTopics[0], "first topic must match input");
        assertEq(storedTopics[1], claimTopics[1], "second topic must match input");

        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(ctr),
            address(deployedToken.identityRegistry().issuersRegistry()),
            address(deployedToken.identityRegistry().identityStorage()),
            address(deployedToken.identityRegistry()),
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice IRS must be owned directly by _tokenDetails.owner, with the deployed IR pre-bound at init time
    function test_deployTREXSuite_IRS_OwnershipAndIRBinding_SetAtInit() public {
        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: alice,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("irs-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("irs-init-salt"));
        IdentityRegistryStorage irs =
            IdentityRegistryStorage(address(deployedToken.identityRegistry().identityStorage()));
        address irAddress = address(deployedToken.identityRegistry());

        assertEq(irs.owner(), alice, "IRS.owner must equal _tokenDetails.owner immediately after deployTREXSuite");
        assertEq(irs.pendingOwner(), address(0), "IRS.pendingOwner must be zero after deployTREXSuite");

        assertTrue(irs.isAgent(irAddress), "IR must be agent on IRS after init");
        address[] memory linkedIRs = irs.linkedIdentityRegistries();
        assertEq(linkedIRs.length, 1, "IRS.linkedIdentityRegistries must contain exactly one IR after deploy");
        assertEq(linkedIRs[0], irAddress, "IRS.linkedIdentityRegistries[0] must match the deployed IR");

        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(deployedToken.identityRegistry().topicsRegistry()),
            address(deployedToken.identityRegistry().issuersRegistry()),
            address(irs),
            irAddress,
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice MC must be owned directly by _tokenDetails.owner, bound to the deployed Token at init time with
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
            owner: alice,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: complianceModules,
            complianceSettings: complianceSettings
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("mc-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("mc-init-salt"));
        ModularCompliance mc = ModularCompliance(address(deployedToken.compliance()));

        assertEq(mc.owner(), alice, "MC.owner must equal _tokenDetails.owner immediately after deployTREXSuite");
        assertEq(mc.pendingOwner(), address(0), "MC.pendingOwner must be zero after deployTREXSuite");
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

        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(deployedToken.identityRegistry().topicsRegistry()),
            address(deployedToken.identityRegistry().issuersRegistry()),
            address(deployedToken.identityRegistry().identityStorage()),
            address(deployedToken.identityRegistry()),
            address(mc),
            address(deployedToken)
        );
    }

    /// @notice Token must be owned directly by _tokenDetails.owner, with the configured tokenAgents pre-granted
    ///         at init time, the OID minted by IdFactory and wired in at init time, and the factory holding
    ///         no role on the Token (no agent, no pending ownership)
    function test_deployTREXSuite_Token_OwnershipAgentsAndOID_SetAtInit() public {
        address[] memory tokenAgents = new address[](2);
        tokenAgents[0] = bob;
        tokenAgents[1] = charlie;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: alice,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: tokenAgents,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("token-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("token-init-salt"));

        assertEq(deployedToken.owner(), alice, "Token.owner must equal _tokenDetails.owner immediately after deploy");
        assertEq(deployedToken.pendingOwner(), address(0), "Token.pendingOwner must be zero after deployTREXSuite");

        assertNotEq(deployedToken.onchainID(), address(0), "Token OID must be wired in at init time");
        assertEq(
            idFactory.getIdentity(address(deployedToken)),
            deployedToken.onchainID(),
            "Token OID must match the IdFactory-registered identity for the deployed Token address"
        );

        assertTrue(deployedToken.isAgent(bob), "Configured tokenAgent bob must be agent on Token after init");
        assertTrue(deployedToken.isAgent(charlie), "Configured tokenAgent charlie must be agent on Token after init");
        assertFalse(deployedToken.isAgent(address(trexFactory)), "Factory must not be agent on Token");

        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(deployedToken.identityRegistry().topicsRegistry()),
            address(deployedToken.identityRegistry().issuersRegistry()),
            address(deployedToken.identityRegistry().identityStorage()),
            address(deployedToken.identityRegistry()),
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice When the caller supplies an ONCHAINID, Token.onchainID must equal that exact address (and the
    ///         factory must NOT have created a new identity via IdFactory)
    function test_deployTREXSuite_Token_UsesProvidedONCHAINID() public {
        // Spawn a stand-in OID address. We don't deploy a real Identity contract because Token.init only
        // stores `onchainId` as an address — it does not call into it during init.
        address suppliedOID = makeAddr("SuppliedOID");

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: alice,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: suppliedOID,
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("token-provided-oid-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("token-provided-oid-salt"));
        assertEq(deployedToken.onchainID(), suppliedOID, "Token.onchainID must equal the supplied ONCHAINID");
        assertEq(
            idFactory.getIdentity(address(deployedToken)),
            address(0),
            "IdFactory must not have minted a new identity when ONCHAINID was supplied"
        );

        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(deployedToken.identityRegistry().topicsRegistry()),
            address(deployedToken.identityRegistry().issuersRegistry()),
            address(deployedToken.identityRegistry().identityStorage()),
            address(deployedToken.identityRegistry()),
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice IR must be owned directly by _tokenDetails.owner, with the Token + irAgents pre-granted at init time
    function test_deployTREXSuite_IR_OwnershipAndAgents_SetAtInit() public {
        address[] memory irAgents = new address[](2);
        irAgents[0] = bob;
        irAgents[1] = charlie;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: alice,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: irAgents,
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("ir-init-salt", tokenDetails, claimDetails);

        Token deployedToken = Token(trexFactory.getToken("ir-init-salt"));
        IdentityRegistry ir = IdentityRegistry(address(deployedToken.identityRegistry()));

        assertEq(ir.owner(), alice, "IR.owner must equal _tokenDetails.owner immediately after deployTREXSuite");
        assertEq(ir.pendingOwner(), address(0), "IR.pendingOwner must be zero after deployTREXSuite");

        assertTrue(ir.isAgent(address(deployedToken)), "Token must be agent on IR after init");
        assertTrue(ir.isAgent(bob), "Configured irAgent bob must be agent on IR after init");
        assertTrue(ir.isAgent(charlie), "Configured irAgent charlie must be agent on IR after init");

        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(ir.topicsRegistry()),
            address(ir.issuersRegistry()),
            address(ir.identityStorage()),
            address(ir),
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice End-to-end regression guard for the part-1..7 refactor: with a fully-populated
    ///         `_claimTopics`, `_issuers`, `_irAgents`, `_tokenAgents`, `_complianceModules` +
    ///         `_complianceSettings`, and the auto-OID path (`ONCHAINID == address(0)`), every
    ///         configuration item must land at init time, all six suite contracts must end up owned
    ///         by `_tokenDetails.owner` with no pending-owner state, and the factory must hold no
    ///         role on any suite contract. No `acceptOwnership` call is made between `deployTREXSuite`
    ///         and the assertions.
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

        // ClaimIssuer for the TIR + claim topic
        issuerAddr = address(new ClaimIssuer(charlie));

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

        vm.prank(deployer);
        trexFactory.deployTREXSuite(
            salt,
            ITREXFactory.TokenDetails({
                owner: alice,
                name: "Token name",
                symbol: "SYM",
                decimals: 8,
                irs: address(0),
                ONCHAINID: address(0),
                irAgents: irAgents,
                tokenAgents: tokenAgents,
                complianceModules: complianceModules,
                complianceSettings: complianceSettings
            }),
            ITREXFactory.ClaimDetails({ claimTopics: claimTopics, issuers: issuers, issuerClaims: issuerClaims })
        );
    }

    /// @notice Verifies that every config item landed at init time and the factory holds no role on any
    ///         suite contract. Split out of the test body so the function fits inside the stack budget.
    function _assertFullConfigSuite(string memory salt, address testModuleAddr, address issuerAddr) internal view {
        // No acceptOwnership call between deploy and assertions — that is the whole point of this test.
        Token deployedToken = Token(trexFactory.getToken(salt));
        IdentityRegistry ir = IdentityRegistry(address(deployedToken.identityRegistry()));
        _assertFullConfigOwnership(deployedToken, ir);
        _assertFullConfigInitState(deployedToken, ir, testModuleAddr, issuerAddr);
        _assertFactoryHoldsNothing(
            address(trexFactory),
            address(ir.topicsRegistry()),
            address(ir.issuersRegistry()),
            address(ir.identityStorage()),
            address(ir),
            address(deployedToken.compliance()),
            address(deployedToken)
        );
    }

    /// @notice All 6 suite contracts must be owned by `_tokenDetails.owner` with no pending-owner state.
    function _assertFullConfigOwnership(Token deployedToken, IdentityRegistry ir) internal view {
        Ownable2Step ctr = Ownable2Step(address(ir.topicsRegistry()));
        Ownable2Step tir = Ownable2Step(address(ir.issuersRegistry()));
        Ownable2Step irs = Ownable2Step(address(ir.identityStorage()));
        Ownable2Step mc = Ownable2Step(address(deployedToken.compliance()));

        assertEq(ctr.owner(), alice, "CTR.owner must equal _tokenDetails.owner");
        assertEq(tir.owner(), alice, "TIR.owner must equal _tokenDetails.owner");
        assertEq(irs.owner(), alice, "IRS.owner must equal _tokenDetails.owner");
        assertEq(ir.owner(), alice, "IR.owner must equal _tokenDetails.owner");
        assertEq(mc.owner(), alice, "MC.owner must equal _tokenDetails.owner");
        assertEq(deployedToken.owner(), alice, "Token.owner must equal _tokenDetails.owner");
        assertEq(ctr.pendingOwner(), address(0), "CTR must have no pending owner");
        assertEq(tir.pendingOwner(), address(0), "TIR must have no pending owner");
        assertEq(irs.pendingOwner(), address(0), "IRS must have no pending owner");
        assertEq(ir.pendingOwner(), address(0), "IR must have no pending owner");
        assertEq(mc.pendingOwner(), address(0), "MC must have no pending owner");
        assertEq(deployedToken.pendingOwner(), address(0), "Token must have no pending owner");
    }

    /// @notice Topics, issuers, agents, modules, settings, OID, IRS binding all in place at init time.
    function _assertFullConfigInitState(
        Token deployedToken,
        IdentityRegistry ir,
        address testModuleAddr,
        address issuerAddr
    ) internal view {
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        uint256[] memory storedTopics = ctr.getClaimTopics();
        assertEq(storedTopics.length, 1, "CTR must have the configured claim topic");
        assertEq(storedTopics[0], 1, "CTR topic must match input");

        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));
        assertTrue(tir.isTrustedIssuer(issuerAddr), "TIR must have the configured issuer registered");

        IdentityRegistryStorage irs = IdentityRegistryStorage(address(ir.identityStorage()));
        address[] memory linkedIRs = irs.linkedIdentityRegistries();
        assertEq(linkedIRs.length, 1, "IRS must have the deployed IR bound at init time");
        assertEq(linkedIRs[0], address(ir), "IRS.linkedIdentityRegistries[0] must match the deployed IR");

        assertTrue(ir.isAgent(address(deployedToken)), "Token must be agent on IR after init");
        assertTrue(ir.isAgent(alice), "Configured irAgent must be agent on IR after init");

        ModularCompliance mc = ModularCompliance(address(deployedToken.compliance()));
        assertEq(mc.getTokenBound(), address(deployedToken), "MC must be bound to the deployed Token at init time");
        assertTrue(mc.isModuleBound(testModuleAddr), "Configured compliance module must be bound at init time");
        assertTrue(
            TestModule(testModuleAddr).getBlockedTransfers(address(mc)),
            "Configured compliance setting must be applied to the module at init time"
        );

        assertNotEq(deployedToken.onchainID(), address(0), "Token OID must be wired in at init time");
        assertEq(
            idFactory.getIdentity(address(deployedToken)),
            deployedToken.onchainID(),
            "Token OID must match the IdFactory-registered identity for the deployed Token address"
        );
        assertTrue(deployedToken.isAgent(bob), "Configured tokenAgent must be agent on Token after init");
    }

    // ============ getToken() Tests ============

    function test_getToken_ReturnsTokenAddress() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken("salt2");
        assertNotEq(tokenAddress, address(0), "Token address should not be zero");
    }

    // ============ setImplementationAuthority() Tests ============

    function test_setImplementationAuthority_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexFactory.setImplementationAuthority(address(0));
    }

    function test_setImplementationAuthority_RevertWhen_IncompleteIA() public {
        // Deploy a new IA but don't add any version (incomplete)
        TREXImplementationAuthority incompleteIA = new TREXImplementationAuthority(true, address(0), address(0));
        Ownable(address(incompleteIA)).transferOwnership(deployer);

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
        TestTREXFactory testFactory = new TestTREXFactory(address(trexImplementationAuthority), address(idFactory));

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
        // Deploy a new IdFactory using the helper
        IdFactory newIdFactory = new IdFactory(address(trexImplementationAuthority));

        vm.prank(deployer);
        trexFactory.setIdFactory(address(newIdFactory));

        assertEq(trexFactory.getIdFactory(), address(newIdFactory), "IdFactory should be updated");
    }

    // ============ recoverContractOwnership() Tests ============

    function test_recoverContractOwnership_RevertWhen_NotOwner() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken("salt2");

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        trexFactory.recoverContractOwnership(tokenAddress, another);
    }

    function test_recoverContractOwnership_Success() public {
        // Deploy TREXSuite with factory as owner
        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: address(trexFactory), // Factory as owner
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("salt2", tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken("salt2");
        Token symToken = Token(tokenAddress);

        // Verify factory is the owner
        assertEq(symToken.owner(), address(trexFactory), "Factory should be owner");

        vm.expectEmit(true, true, false, false, tokenAddress);
        emit Ownable2Step.OwnershipTransferStarted(address(trexFactory), alice);
        vm.prank(deployer);
        trexFactory.recoverContractOwnership(tokenAddress, alice);

        // Accept ownership
        vm.prank(alice);
        symToken.acceptOwnership();

        // Verify alice is now the owner
        assertEq(symToken.owner(), alice, "Alice should be the new owner");
    }

    /// @notice Should deploy TREX suite when irs is provided (not address(0))
    function test_deployTREXSuite_Success_WithProvidedIRS() public {
        // First deploy a TREX suite to get an IRS that's already properly set up
        ITREXFactory.TokenDetails memory tempTokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory tempClaimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("temp-salt", tempTokenDetails, tempClaimDetails);

        // Get the IRS from the deployed token's identity registry
        address tempTokenAddress = trexFactory.getToken("temp-salt");
        Token tempToken = Token(tempTokenAddress);
        address irAddress = address(tempToken.identityRegistry());
        IERC3643IdentityRegistry ir = IERC3643IdentityRegistry(irAddress);
        address deployedIRS = address(ir.identityStorage());

        require(deployedIRS != address(0), "IRS should be deployed");

        // The reused IRS must be owned by the factory so it can bind the new IR after `_resolveIR`
        // produces it. Transfer ownership from `deployer` (the suite owner) back to the factory for
        // this second deployment. This mirrors the pre-refactor precondition: the factory needed to
        // be the IRS owner to bind the new IR. IRS uses Ownable2Step, so the factory must accept.
        vm.prank(deployer);
        Ownable2Step(deployedIRS).transferOwnership(address(trexFactory));
        vm.prank(address(trexFactory));
        Ownable2Step(deployedIRS).acceptOwnership();

        // Now use the deployed IRS in a new deployment
        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: deployer,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: deployedIRS, // Use provided IRS instead of address(0)
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("salt-irs", tokenDetails, claimDetails);

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
        assertTrue(reusedIRS.isAgent(address(newIR)), "New IR should be agent on reused IRS");
    }

}
