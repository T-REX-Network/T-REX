// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { IIdentity, Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { KeyApprovalModule } from "@onchain-id/solidity/contracts/modules/executors/KeyApprovalModule.sol";
import { ERC734Validator } from "@onchain-id/solidity/contracts/modules/validators/ERC734Validator.sol";
import { ReputationRegistry } from "@onchain-id/solidity/contracts/reputation/ReputationRegistry.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { IdentityModulesHelper } from "test/helpers/IdentityModulesHelper.sol";

import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";

/// @notice Base test harness for TREXRegistry unit tests.
/// @dev Deploys a fresh TREXRegistry behind an ERC1967 proxy, wires its AccessManager roles and
///      provides ONCHAINID test fixtures.
abstract contract TREXRegistryBaseUnitTest is Test, AccessManagerHelper {

    uint256 public constant CLAIM_TOPIC_1 = uint256(keccak256(abi.encode("CLAIM_TOPIC_1")));
    uint256 public constant CLAIM_TOPIC_2 = 42;
    uint256 public constant CLAIM_TOPIC_3 = 66;
    uint256 public constant CLAIM_TOPIC_4 = 100;

    TREXRegistry public registryImplementation;
    TREXRegistry public registry;
    IdentityRegistryStorage public identityRegistryStorage;
    IdentityRegistryStorage public identityRegistryStorageImpl;

    // OnchainID fixtures. Identity is a SmartAccount with no native ERC-734/735 surface, so the
    // merged ERC734Validator holds the enshrined key registry and backs the claim getters; a claim
    // issuer is just an Identity of type CLAIM_ISSUER holding a CLAIM_SIGNER key.
    Identity public identityImplementation;
    IdentityFactory public idFactory;
    KeyApprovalModule public keyApprovalModule;
    ERC734Validator public validatorModule;
    ReputationRegistry public reputationRegistry;
    Identity public claimIssuer;

    // Admin roles
    address public deployer = makeAddr("deployer");
    address public agent = makeAddr("agent");

    // User roles
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public another = makeAddr("another");

    IIdentity public aliceIdentity;
    IIdentity public bobIdentity;
    IIdentity public charlieIdentity;

    Account public claimIssuerSigner = makeAccount("claimIssuerSigner");

    function setUp() public virtual {
        _deployAccessManager();

        _deployOnchainId();

        // Deploy IdentityRegistryStorage behind a proxy
        identityRegistryStorageImpl = new IdentityRegistryStorage();
        identityRegistryStorage = IdentityRegistryStorage(
            address(
                new ERC1967Proxy(
                    address(identityRegistryStorageImpl),
                    // No initial identity registry: the registry is deployed below and bound explicitly.
                    abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0)))
                )
            )
        );

        // Deploy TREXRegistry behind a proxy
        registryImplementation = new TREXRegistry(address(idFactory));
        registry = TREXRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImplementation),
                    abi.encodeCall(
                        TREXRegistry.init,
                        (
                            address(identityRegistryStorage),
                            address(accessManager),
                            new uint256[](0),
                            new address[](0),
                            new uint256[][](0)
                        )
                    )
                )
            )
        );

        // Wire AccessManager roles for the new contracts (this contract is the AccessManager admin).
        _setupTREXRegistryRoles(address(registry));
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(identityRegistryStorage));

        // Grant standard owner/agent roles to deployer/agent so they can drive the registry.
        _grantOwnerRole(deployer);
        _grantManagerRoles(deployer);
        _grantAllAgentRoles(agent);
        // bindIdentityRegistry is gated on the transient IRS_BINDER role, not OWNER.
        _grantIRSBinderRole(deployer);
        // The registry writes to the IRS, whose mutators are AGENT-gated. `bindIdentityRegistry`
        // does not confer that role, so grant it here exactly as TREXFactory does for a deployed IR.
        _grantAgentRole(address(registry));

        // Bind the registry as an "identity registry" of the IRS so it can write to it.
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(address(registry));

        // Create base ONCHAINID identities
        aliceIdentity = _deployIdentity(alice, "alice");
        bobIdentity = _deployIdentity(bob, "bob");
        charlieIdentity = _deployIdentity(charlie, "charlie");
    }

    /// @dev Deploys the ONCHAINID stack the registry reads from, mirroring the integration suite:
    ///      IdentityFactory (no beacon yet) -> KeyApprovalModule -> ReputationRegistry (needs the
    ///      factory) -> ERC734Validator (needs factory + registry) -> Identity impl (the validator is
    ///      its enshrined registry immutable) -> `initializeBeacon`.
    function _deployOnchainId() internal {
        vm.startPrank(deployer);
        idFactory = new IdentityFactory(address(accessManager));
        keyApprovalModule = new KeyApprovalModule();
        reputationRegistry = new ReputationRegistry(address(accessManager), address(idFactory));
        validatorModule = new ERC734Validator(address(idFactory), address(reputationRegistry));
        identityImplementation = new Identity(address(validatorModule), address(idFactory));
        vm.stopPrank();

        // Registered after the module singletons exist: the per-type module bundles reference them.
        _registerIdentityTypePolicies(idFactory);

        // The factory's beacon owner is the AccessManager, so initializeBeacon is restricted; this
        // test contract is the AM admin and drives it.
        idFactory.initializeBeacon(address(identityImplementation));

        claimIssuer = _deployClaimIssuer(claimIssuerSigner.addr, "claimIssuer");
    }

    /// @dev The factory rejects unregistered identity types from both deploy paths. INDIVIDUAL and
    ///      CLAIM_ISSUER are open for test convenience; ASSET stays gated and single-binding as in
    ///      production. Modules are registered per type on the factory; deploy callers pass none.
    function _registerIdentityTypePolicies(IdentityFactory factory) internal {
        uint64 publicRole = accessManager.PUBLIC_ROLE();
        Structs.ModuleInstall[] memory standardModules =
            IdentityModulesHelper.legacyQueueModules(address(keyApprovalModule), address(validatorModule));

        factory.setIdentityTypePolicy(IdentityTypes.INDIVIDUAL, publicRole, true, false);
        factory.setIdentityTypeModules(IdentityTypes.INDIVIDUAL, standardModules);
        factory.setIdentityTypePolicy(IdentityTypes.CLAIM_ISSUER, publicRole, true, false);
        factory.setIdentityTypeModules(IdentityTypes.CLAIM_ISSUER, standardModules);
        factory.setIdentityTypePolicy(IdentityTypes.ASSET, RolesLib.ASSET_DEPLOYER, false, true);
        factory.setIdentityTypeModules(IdentityTypes.ASSET, standardModules);
    }

    /// @dev A claim issuer is an Identity of type CLAIM_ISSUER holding a CLAIM_SIGNER key. The
    ///      MANAGEMENT key satisfies the factory's post-deploy shape check; CLAIM_SIGNER is the key
    ///      ERC734Validator verifies claim signatures against.
    function _deployClaimIssuer(address signer, string memory salt) internal returns (Identity) {
        Structs.KeyParam[] memory issuerKeys = new Structs.KeyParam[](2);
        issuerKeys[0] = _ecdsaKey(signer, KeyPurposes.MANAGEMENT);
        issuerKeys[1] = _ecdsaKey(signer, KeyPurposes.CLAIM_SIGNER);

        vm.prank(deployer);
        address issuer = idFactory.createIdentityFor(signer, IdentityTypes.CLAIM_ISSUER, salt, issuerKeys);
        return Identity(payable(issuer));
    }

    /// @dev Deploys an INDIVIDUAL identity whose sole wallet and management key is `wallet`.
    function _deployIdentity(address wallet, string memory salt) internal returns (IIdentity) {
        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(wallet, KeyPurposes.MANAGEMENT);

        vm.prank(deployer);
        address identity = idFactory.createIdentityFor(wallet, IdentityTypes.INDIVIDUAL, salt, keys);
        return IIdentity(identity);
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

    /// @notice Wires AccessManager roles for the TREXRegistry contract.
    /// @dev Mirrors `AccessManagerSetupLib.setupTREXRegistryRoles`, kept local so the unit harness
    ///      does not depend on the library's internal wiring.
    function _setupTREXRegistryRoles(address registryAddress) internal {
        // ------ OWNER role ------
        // Identity registry owner-restricted functions
        bytes4[] memory ownerFunctions = new bytes4[](12);
        ownerFunctions[0] = TREXRegistry.setIdentityRegistryStorage.selector;
        ownerFunctions[1] = TREXRegistry.setClaimTopicsRegistry.selector;
        ownerFunctions[2] = TREXRegistry.setTrustedIssuersRegistry.selector;
        ownerFunctions[3] = TREXRegistry.disableEligibilityChecks.selector;
        ownerFunctions[4] = TREXRegistry.enableEligibilityChecks.selector;
        // Trusted issuers registry owner-restricted functions
        ownerFunctions[5] = TREXRegistry.addTrustedIssuer.selector;
        ownerFunctions[6] = TREXRegistry.removeTrustedIssuer.selector;
        ownerFunctions[7] = TREXRegistry.updateIssuerClaimTopics.selector;
        // Claim topics registry owner-restricted functions
        ownerFunctions[8] = TREXRegistry.addClaimTopic.selector;
        ownerFunctions[9] = TREXRegistry.removeClaimTopic.selector;
        ownerFunctions[10] = TREXRegistry.addClaimTopicForIdentityType.selector;
        ownerFunctions[11] = TREXRegistry.removeClaimTopicForIdentityType.selector;
        IAccessManager(accessManager).setTargetFunctionRole(registryAddress, ownerFunctions, RolesLib.OWNER);

        // ------ AGENT role ------
        bytes4[] memory agentFunctions = new bytes4[](4);
        agentFunctions[0] = TREXRegistry.updateIdentity.selector;
        agentFunctions[1] = TREXRegistry.updateCountry.selector;
        agentFunctions[2] = TREXRegistry.deleteIdentity.selector;
        agentFunctions[3] = TREXRegistry.registerIdentity.selector;
        IAccessManager(accessManager).setTargetFunctionRole(registryAddress, agentFunctions, RolesLib.AGENT);
    }

    /// @notice Creates a claim signed now with no expiry and adds it to `_identity`.
    /// @dev The claim is signed over the issuer's EIP-712 digest (`getClaimHash`, served by its
    ///      ERC734Validator) so the issuer's domain separator is baked in, and the signature is the
    ///      ERC-7913 envelope `abi.encode(signer, rawSig)` the validator dispatches on.
    function _addClaim(
        IIdentity _identity,
        uint256 _claimTopic,
        bytes memory _claimData,
        uint256 _signerPrivateKey,
        address _claimIssuer,
        address _caller
    ) internal {
        Structs.ClaimData memory data = Structs.ClaimData({
            issuedAt: block.timestamp,
            validUntil: 0,
            metadataHash: validatorModule.getMetadataHash(1, "uri"),
            payload: _claimData
        });

        bytes32 digest = IIdentity(_claimIssuer).getClaimHash(address(_identity), _claimTopic, data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, digest);
        bytes memory signature = abi.encode(abi.encodePacked(vm.addr(_signerPrivateKey)), abi.encodePacked(r, s, v));

        vm.prank(_caller);
        _identity.addClaim(_claimTopic, 1, _claimIssuer, signature, data, "uri");
    }

    /// @notice Registers all the base identities so they can be referenced by tests.
    function _registerBaseIdentities() internal {
        vm.startPrank(agent);
        registry.registerIdentity(alice, aliceIdentity, 250);
        registry.registerIdentity(bob, bobIdentity, 840);
        registry.registerIdentity(charlie, charlieIdentity, 724);
        vm.stopPrank();
    }

}
