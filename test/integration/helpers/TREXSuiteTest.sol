// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity, Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { KeyApprovalModule } from "@onchain-id/solidity/contracts/modules/executors/KeyApprovalModule.sol";
import { ERC734Validator } from "@onchain-id/solidity/contracts/modules/validators/ERC734Validator.sol";
import { ReputationRegistry } from "@onchain-id/solidity/contracts/reputation/ReputationRegistry.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { IdentityModulesLib } from "contracts/libraries/IdentityModulesLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/beacon/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";
import { Countries } from "test/integration/helpers/Countries.sol";

contract TREXSuiteTest is AccessManagerHelper {

    uint256 public constant CLAIM_TOPIC_1 = uint256(keccak256(abi.encode("CLAIM_TOPIC_1")));
    uint32 public constant NO_DELAY = 0;

    // OnchainID
    Identity public identityImplementation;
    UpgradeableBeacon public identityBeacon;
    IdentityFactory public idFactory;

    // ONCHAINID module singletons. Identity is a SmartAccount with no native ERC-734/735 surface,
    // so every identity installs these to hold keys and claims. The merged ERC734Validator
    // (`validatorModule`) holds the enshrined key registry and backs the claim + ERC-734 getter surface;
    // it is also the Identity implementation's enshrined registry immutable.
    KeyApprovalModule public keyApprovalModule;
    ERC734Validator public validatorModule;
    ReputationRegistry public reputationRegistry;

    // Implementations
    Token tokenImplementation;
    IdentityRegistryStorage identityRegistryStorageImplementation;
    ModularCompliance modularComplianceImplementation;
    TREXRegistry trexRegistryImplementation;

    // Factories
    TREXFactory public trexFactory;
    TREXImplementationAuthority public trexImplementationAuthority;

    // TREX Suite
    Token public token;
    /// @dev A claim issuer is now just an Identity of type CLAIM_ISSUER with the ERC734Validator
    ///      installed; ONCHAINID no longer ships a standalone ClaimIssuer contract.
    Identity public claimIssuer;

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
        _deployOnchainId();
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

    /// @dev Deploys the ONCHAINID stack: the merged ERC734Validator (enshrined key/claim registry), the
    ///      identity implementation bound to it, the IdentityFactory governed by the suite's AccessManager
    ///      that owns the upgradeable beacon, and the module singletons every identity installs. Identity
    ///      types are registered with the factory here because it rejects unregistered types from both
    ///      deploy paths.
    ///
    ///      Deploy order follows the dependency chain: IdentityFactory (no beacon yet) ->
    ///      KeyApprovalModule (no deps) -> ReputationRegistry (needs the factory) -> ERC734Validator
    ///      (needs factory + registry) -> Identity impl (the validator is its enshrined registry
    ///      immutable) -> factory.initializeBeacon (deploys the beacon at its predetermined CREATE3 slot).
    function _deployOnchainId() internal {
        idFactory = _newIdentityFactory();

        vm.startPrank(deployer);
        keyApprovalModule = new KeyApprovalModule();
        reputationRegistry = new ReputationRegistry(address(accessManager), address(idFactory));
        validatorModule = new ERC734Validator(address(idFactory), address(reputationRegistry));
        identityImplementation = new Identity(address(validatorModule), address(idFactory));
        vm.stopPrank();

        // The factory's beacon owner is the suite AccessManager, so initializeBeacon is restricted;
        // the test contract is the AM admin and drives it.
        idFactory.initializeBeacon(address(identityImplementation));
        identityBeacon = UpgradeableBeacon(idFactory.beacon());

        claimIssuer = _deployClaimIssuer();
    }

    /// @dev Builds a TREXFactory wired to the suite's IdentityFactory and ONCHAINID module singletons.
    ///      The modules are constructor config because a token OID minted without them could not hold
    ///      claims.
    function _newTREXFactory(address implementationAuthority, address accessManagerAddress)
        internal
        returns (TREXFactory factory)
    {
        vm.startPrank(deployer);
        factory = new TREXFactory(
            implementationAuthority,
            address(idFactory),
            address(keyApprovalModule),
            address(validatorModule),
            accessManagerAddress
        );
        vm.stopPrank();
    }

    /// @dev Deploys an IdentityFactory governed by the suite's AccessManager and registers the identity
    ///      types the suite mints. The factory owns its own beacon (deployed later via initializeBeacon),
    ///      so no beacon is passed here. Tests that need a second, independent global registry call this
    ///      directly.
    function _newIdentityFactory() internal returns (IdentityFactory factory) {
        vm.startPrank(deployer);
        factory = new IdentityFactory(address(accessManager));
        vm.stopPrank();

        _registerIdentityTypePolicies(factory);
    }

    /// @dev Registers the identity types the suite mints; the factory rejects unregistered types from
    ///      both deploy paths. INDIVIDUAL and CLAIM_ISSUER are open (PUBLIC_ROLE, self-deployable) for
    ///      test convenience. ASSET is gated behind ASSET_DEPLOYER with self-deploy off, mirroring
    ///      production: only a registered token factory mints token OIDs, and a token cannot sign for
    ///      itself.
    /// @dev Called as the test contract, which is the AccessManager admin (see AccessManagerHelper);
    ///      `setIdentityTypePolicy` is restricted and its selector defaults to ADMIN_ROLE.
    function _registerIdentityTypePolicies(IdentityFactory factory) internal {
        uint64 publicRole = accessManager.PUBLIC_ROLE();

        factory.setIdentityTypePolicy(IdentityTypes.INDIVIDUAL, publicRole, true);
        factory.setIdentityTypePolicy(IdentityTypes.CLAIM_ISSUER, publicRole, true);
        factory.setIdentityTypePolicy(IdentityTypes.ASSET, RolesLib.ASSET_DEPLOYER, false);
    }

    /// @dev A claim issuer is an Identity of type CLAIM_ISSUER holding a CLAIM_SIGNER key. The
    ///      MANAGEMENT key satisfies the factory's post-deploy shape check; CLAIM_SIGNER is the key
    ///      ERC734Validator verifies claim signatures against.
    function _deployClaimIssuer() internal returns (Identity) {
        return _deployClaimIssuer(claimIssuerSigner.addr, "claimIssuer");
    }

    /// @dev Deploys a claim issuer whose CLAIM_SIGNER (and management) key is `signer`.
    function _deployClaimIssuer(address signer, string memory salt) internal returns (Identity) {
        Structs.KeyParam[] memory issuerKeys = new Structs.KeyParam[](2);
        issuerKeys[0] = _ecdsaKey(signer, KeyPurposes.MANAGEMENT);
        issuerKeys[1] = _ecdsaKey(signer, KeyPurposes.CLAIM_SIGNER);

        vm.prank(deployer);
        address issuer = idFactory.createIdentityFor(
            signer,
            IdentityTypes.CLAIM_ISSUER,
            salt,
            issuerKeys,
            IdentityModulesLib.legacyQueueModules(address(keyApprovalModule), address(validatorModule))
        );
        return Identity(payable(issuer));
    }

    /// @dev Deploys an INDIVIDUAL identity in the suite's factory whose sole wallet and management
    ///      key is `wallet`.
    function _deployIdentity(address wallet, string memory salt) internal returns (IIdentity) {
        return _deployIdentityIn(idFactory, wallet, salt);
    }

    /// @dev Deploys an INDIVIDUAL identity in `factory`. Separate from {_deployIdentity} so tests can
    ///      register a wallet in a second global registry.
    function _deployIdentityIn(IdentityFactory factory, address wallet, string memory salt)
        internal
        returns (IIdentity)
    {
        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(wallet, KeyPurposes.MANAGEMENT);

        vm.prank(deployer);
        address identity = factory.createIdentityFor(
            wallet,
            IdentityTypes.INDIVIDUAL,
            salt,
            keys,
            IdentityModulesLib.legacyQueueModules(address(keyApprovalModule), address(validatorModule))
        );
        return IIdentity(identity);
    }

    /// @dev Resolves a wallet's identity in the global registry. The factory keys wallets by ERC-7930
    ///      interoperable address, so the wallet is wrapped in an EVM envelope for this chain.
    function _identityOf(address wallet) internal view returns (address) {
        return idFactory.getIdentity(InteroperableAddress.formatEvmV1(block.chainid, wallet));
    }

    function _ecdsaKey(address addr, uint256 purpose) internal pure returns (Structs.KeyParam memory) {
        return Structs.KeyParam({
            keyHash: keccak256(abi.encodePacked(addr)),
            purpose: purpose,
            keyType: KeyTypes.ECDSA,
            signerData: abi.encodePacked(addr),
            clientData: ""
        });
    }

    function _deployImplementations() internal {
        tokenImplementation = new Token();
        identityRegistryStorageImplementation = new IdentityRegistryStorage();
        modularComplianceImplementation = new ModularCompliance();
        trexRegistryImplementation = new TREXRegistry();
    }

    function _deployFactories() internal {
        trexImplementationAuthority = _deployTREXImplementationAuthority();

        trexFactory = _newTREXFactory(address(trexImplementationAuthority), address(accessManager));

        // The IdentityFactory gates ASSET minting on ASSET_DEPLOYER, resolved against its own
        // authority (the suite AccessManager here). Without this the auto-mint path reverts.
        _grantTokenOidMinterRole(address(trexFactory));

        _setupFactoryRoles(address(trexFactory));
        // deployTREXSuite grants the AGENT role, which is administered by AGENT_ADMIN
        _grantAgentAdminRole(address(trexFactory));
    }

    /// @dev Deploys an authority seeded with version 5.0.0. The constructor deploys and owns the 4
    ///      beacons, so there is no separate version-pinning call; `publish` / `upgrade` are then wired
    ///      to VERSION_MANAGER, which the deployer holds.
    function _deployTREXImplementationAuthority() internal returns (TREXImplementationAuthority) {
        TREXImplementationAuthority ia = new TREXImplementationAuthority(
            address(accessManager),
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 }),
            _suiteImplementations()
        );

        _authorizeIAGovernance(address(ia));
        _grantOwnerRole(deployer);
        _grantVersionManagerRole(deployer);

        return ia;
    }

    function _suiteImplementations() internal view returns (ITREXImplementationAuthority.SuiteImplementations memory) {
        return ITREXImplementationAuthority.SuiteImplementations({
            tokenImplementation: address(tokenImplementation),
            trexRegistryImplementation: address(trexRegistryImplementation),
            irsImplementation: address(identityRegistryStorageImplementation),
            mcImplementation: address(modularComplianceImplementation)
        });
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
        // The registry answers topicsRegistry()/issuersRegistry() with its own address, so a single
        // registry wiring covers all three sub-surfaces.
        IERC3643IdentityRegistry ir = _token.identityRegistry();
        _setupSuiteRoles(address(_token), address(ir), address(ir.identityStorage()), address(_token.compliance()));
    }

    /// @notice Deploys a fresh ModularCompliance proxy with no token bound, managed by the test AccessManager
    ///         (`address(this)` holds the OWNER role). Initializes with a sentinel token then unbinds it so the
    ///         resulting MC is in a clean unbound state, ready to be wired to a token via `setCompliance`
    ///         (Token-self-bind path) by the caller.
    function _newUnboundComplianceProxy(address implementationAuthority_) internal returns (ModularCompliance) {
        address sentinel = address(uint160(uint256(keccak256("trex.test.unboundMC.sentinel"))));
        address[] memory noModules = new address[](0);
        bytes[] memory noSettings = new bytes[](0);
        address mcBeacon = ITREXImplementationAuthority(implementationAuthority_).current().mcBeacon;
        BeaconProxy proxy = new BeaconProxy(
            mcBeacon, abi.encodeCall(ModularCompliance.init, (sentinel, address(accessManager), noModules, noSettings))
        );
        ModularCompliance freshCompliance = ModularCompliance(address(proxy));
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, address(freshCompliance));
        freshCompliance.unbindToken(sentinel);
        return freshCompliance;
    }

    function _deployIdentities() internal {
        aliceIdentity = _deployIdentity(alice, "alice");
        bobIdentity = _deployIdentity(bob, "bob");
        charlieIdentity = _deployIdentity(charlie, "charlie");
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
    /// @notice Adds a claim signed now with no expiry. See {_addClaimWithValidity} for the windowed form.
    function _addClaim(
        IIdentity _identity,
        uint256 _claimTopic,
        bytes memory _claimData,
        uint256 _signerPrivateKey,
        address _claimIssuer,
        address _caller
    ) internal {
        _addClaimWithValidity(
            _identity,
            _claimTopic,
            Structs.ClaimData({ issuedAt: block.timestamp, validUntil: 0, payload: _claimData }),
            _signerPrivateKey,
            _claimIssuer,
            _caller
        );
    }

    /// @notice Adds a claim with an explicit validity envelope.
    /// @dev The claim is signed over the issuer's EIP-712 digest rather than a bare hash: the digest
    ///      is fetched from the issuer itself (`getClaimHash`, served by its ERC734Validator) so the
    ///      issuer's domain separator is baked in. The signature is an ERC-7913 envelope,
    ///      `abi.encode(signer, rawSig)`, which is how ERC734Validator dispatches to SignatureChecker.
    function _addClaimWithValidity(
        IIdentity _identity,
        uint256 _claimTopic,
        Structs.ClaimData memory _data,
        uint256 _signerPrivateKey,
        address _claimIssuer,
        address _caller
    ) internal {
        bytes memory signature = _signClaim(_identity, _claimTopic, _data, _signerPrivateKey, _claimIssuer);

        vm.prank(_caller);
        _identity.addClaim(_claimTopic, 1, _claimIssuer, signature, _data, "uri");
    }

    /// @notice Builds the claim signature without submitting it, for tests that need to drive
    ///         `addClaim` themselves (to wrap it in `expectRevert`, or to replay identical bytes).
    function _signClaim(
        IIdentity _identity,
        uint256 _claimTopic,
        Structs.ClaimData memory _data,
        uint256 _signerPrivateKey,
        address _claimIssuer
    ) internal view returns (bytes memory) {
        bytes32 digest = IIdentity(_claimIssuer).getClaimHash(address(_identity), _claimTopic, _data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, digest);
        return abi.encode(abi.encodePacked(vm.addr(_signerPrivateKey)), abi.encodePacked(r, s, v));
    }

}
