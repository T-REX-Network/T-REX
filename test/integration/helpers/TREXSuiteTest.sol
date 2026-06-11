// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import { IIdentity, Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdFactory } from "@onchain-id/solidity/contracts/factory/IdFactory.sol";
import { ImplementationAuthority } from "@onchain-id/solidity/contracts/proxy/ImplementationAuthority.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ModularComplianceProxy } from "contracts/proxy/ModularComplianceProxy.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { ClaimTopicsRegistry } from "contracts/registry/implementation/ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry, IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TrustedIssuersRegistry } from "contracts/registry/implementation/TrustedIssuersRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";
import { Countries } from "test/integration/helpers/Countries.sol";

contract TREXSuiteTest is AccessManagerHelper {

    uint256 public constant CLAIM_TOPIC_1 = uint256(keccak256(abi.encode("CLAIM_TOPIC_1")));
    uint32 public constant NO_DELAY = 0;

    // OnchainID
    Identity public identityImplementation;
    ImplementationAuthority public implementationAuthority;
    IdFactory public idFactory;

    // Implementations
    Token tokenImplementation;
    IdentityRegistry identityRegistryImplementation;
    IdentityRegistryStorage identityRegistryStorageImplementation;
    ClaimTopicsRegistry claimTopicsRegistryImplementation;
    TrustedIssuersRegistry trustedIssuersRegistryImplementation;
    ModularCompliance modularComplianceImplementation;

    // Factories
    TREXFactory public trexFactory;
    TREXImplementationAuthority public trexImplementationAuthority;

    // TREX Suite
    Token public token;
    ClaimIssuer public claimIssuer;

    // Admin roles
    address public deployer = makeAddr("deployer");
    address public agent = makeAddr("agent");

    // User roles
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");
    address public another = makeAddr("another");

    IIdentity public aliceIdentity;
    IIdentity public bobIdentity;
    IIdentity public charlieIdentity;

    Account public claimIssuerSigner = makeAccount("claimIssuerSigner");
    Account public aliceSigner = makeAccount("aliceSigner");
    Account public bobSigner = makeAccount("bobSigner");

    function setUp() public virtual {
        _deployAccessManager();
        _deployOnchainId(deployer);
        _deployImplementations();
        _deployFactories();

        _grantOwnerRole(deployer);
        _grantOwnerRole(address(this));
        _grantManagerRoles(deployer);
        _grantAllAgentRoles(agent);

        token = _deployToken("salt", "Token", "TKN");

        _deployIdentities();
        _registerIdentities(token);
    }

    function _deployOnchainId(address initialManagementKey) internal {
        vm.startPrank(deployer);
        identityImplementation = new Identity(initialManagementKey, true);
        implementationAuthority = new ImplementationAuthority(address(identityImplementation));
        idFactory = new IdFactory(address(implementationAuthority));

        claimIssuer = new ClaimIssuer(claimIssuerSigner.addr);
        vm.stopPrank();
    }

    function _deployImplementations() internal {
        tokenImplementation = new Token();
        identityRegistryImplementation = new IdentityRegistry();
        identityRegistryStorageImplementation = new IdentityRegistryStorage();
        claimTopicsRegistryImplementation = new ClaimTopicsRegistry();
        trustedIssuersRegistryImplementation = new TrustedIssuersRegistry();
        modularComplianceImplementation = new ModularCompliance();
    }

    function _deployFactories() internal {
        vm.startPrank(deployer);

        trexImplementationAuthority = _deployTREXImplementationAuthority(true);

        trexFactory = new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));
        idFactory.addTokenFactory(address(trexFactory));

        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        vm.stopPrank();

        _setupFactoryRoles(address(trexFactory));
        // deployTREXSuite grants the AGENT role, which is administered by AGENT_ADMIN
        _grantAgentAdminRole(address(trexFactory));
    }

    function _deployTREXImplementationAuthority(bool isReference) internal returns (TREXImplementationAuthority) {
        TREXImplementationAuthority ia = new TREXImplementationAuthority(isReference, address(0), address(0));
        ia.addAndUseTREXVersion(
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 }),
            ITREXImplementationAuthority.TREXContracts({
                tokenImplementation: address(tokenImplementation),
                irImplementation: address(identityRegistryImplementation),
                irsImplementation: address(identityRegistryStorageImplementation),
                ctrImplementation: address(claimTopicsRegistryImplementation),
                tirImplementation: address(trustedIssuersRegistryImplementation),
                mcImplementation: address(modularComplianceImplementation)
            })
        );

        return ia;
    }

    function _deployToken(string memory salt, string memory name, string memory symbol) internal returns (Token) {
        address[] memory agents = new address[](1);
        agents[0] = agent;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: name,
            symbol: symbol,
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: agents,
            tokenAgents: agents,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });

        ITREXFactory.ClaimDetails memory claimDetails = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        _deploySuite(salt, tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken(salt);
        vm.label(tokenAddress, symbol);

        Token deployedToken = Token(tokenAddress);
        _setupTokenSuiteRoles(deployedToken);

        return deployedToken;
    }

    function _deployTokenWithClaimTopic(string memory salt, string memory name, string memory symbol)
        internal
        returns (Token)
    {
        address[] memory agents = new address[](1);
        agents[0] = agent;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: name,
            symbol: symbol,
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: agents,
            tokenAgents: agents,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });

        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        address[] memory issuers = new address[](1);
        issuers[0] = address(claimIssuer);

        uint256[][] memory issuerClaims = new uint256[][](1);
        uint256[] memory claims = new uint256[](1);
        claims[0] = CLAIM_TOPIC_1;
        issuerClaims[0] = claims;

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: claimTopics, issuers: issuers, issuerClaims: issuerClaims });

        _deploySuite(salt, tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken(salt);
        vm.label(tokenAddress, symbol);

        Token deployedToken = Token(tokenAddress);
        _setupTokenSuiteRoles(deployedToken);

        return deployedToken;
    }

    /// @notice Deploys a TREX suite as `deployer`.
    function _deploySuite(
        string memory salt,
        ITREXFactory.TokenDetails memory tokenDetails,
        ITREXFactory.ClaimDetails memory claimDetails
    ) internal {
        vm.prank(deployer);
        trexFactory.deployTREXSuite(salt, tokenDetails, claimDetails);
    }

    /// @notice Wires the selector-to-role mappings on the AccessManager for every contract of `_token`'s suite.
    function _setupTokenSuiteRoles(Token _token) internal {
        IERC3643IdentityRegistry ir = _token.identityRegistry();
        _setupSuiteRoles(
            address(_token),
            address(ir),
            address(ir.identityStorage()),
            address(ir.topicsRegistry()),
            address(ir.issuersRegistry()),
            address(_token.compliance())
        );
    }

    /// @notice Deploys a fresh ModularCompliance proxy with no token bound, managed by the test AccessManager
    ///         (`address(this)` holds the OWNER role). Initializes with a sentinel token then unbinds it so the
    ///         resulting MC is in a clean unbound state, ready to be wired to a token via `setCompliance`
    ///         (Token-self-bind path) by the caller.
    function _newUnboundComplianceProxy(address implementationAuthority_) internal returns (ModularCompliance) {
        address sentinel = address(uint160(uint256(keccak256("trex.test.unboundMC.sentinel"))));
        address[] memory noModules = new address[](0);
        bytes[] memory noSettings = new bytes[](0);
        ModularComplianceProxy proxy = new ModularComplianceProxy(
            implementationAuthority_, sentinel, address(accessManager), noModules, noSettings
        );
        ModularCompliance freshCompliance = ModularCompliance(address(proxy));
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, address(freshCompliance));
        freshCompliance.unbindToken(sentinel);
        return freshCompliance;
    }

    function getTREXContracts() public view returns (ITREXImplementationAuthority.TREXContracts memory) {
        return ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: address(tokenImplementation),
            ctrImplementation: address(claimTopicsRegistryImplementation),
            irImplementation: address(identityRegistryImplementation),
            irsImplementation: address(identityRegistryStorageImplementation),
            tirImplementation: address(trustedIssuersRegistryImplementation),
            mcImplementation: address(modularComplianceImplementation)
        });
    }

    function _deployIdentities() internal {
        vm.startPrank(deployer);
        aliceIdentity = IIdentity(idFactory.createIdentity(alice, "alice"));
        bobIdentity = IIdentity(idFactory.createIdentity(bob, "bob"));
        charlieIdentity = IIdentity(idFactory.createIdentity(charlie, "charlie"));
        vm.stopPrank();
    }

    function _registerIdentities(Token _token) internal {
        vm.startPrank(agent);
        IERC3643IdentityRegistry ir = _token.identityRegistry();
        ir.registerIdentity(alice, aliceIdentity, Countries.FRANCE);
        ir.registerIdentity(bob, bobIdentity, Countries.UNITED_STATES);
        ir.registerIdentity(charlie, charlieIdentity, Countries.SPAIN);
        vm.stopPrank();
    }

    /// @notice Helper function to create and add a claim to an identity
    function _addClaim(
        IIdentity _identity,
        uint256 _claimTopic,
        bytes memory _claimData,
        uint256 _signerPrivateKey,
        address _claimIssuer,
        address _caller
    ) internal {
        // Compute dataHash = keccak256(abi.encode(identity, topic, data))
        bytes32 dataHash = keccak256(abi.encode(address(_identity), _claimTopic, _claimData));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, MessageHashUtils.toEthSignedMessageHash(dataHash));
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(_caller);
        _identity.addClaim(_claimTopic, 1, _claimIssuer, signature, _claimData, "uri");
    }

}
