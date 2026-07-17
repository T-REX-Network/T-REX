// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { ClaimTopicsRegistryProxy } from "contracts/proxy/ClaimTopicsRegistryProxy.sol";
import { IdentityRegistryProxy } from "contracts/proxy/IdentityRegistryProxy.sol";
import { IdentityRegistryStorageProxy } from "contracts/proxy/IdentityRegistryStorageProxy.sol";
import { TrustedIssuersRegistryProxy } from "contracts/proxy/TrustedIssuersRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { ClaimTopicsRegistry } from "contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    IERC3643IdentityRegistry,
    IIdentityRegistry,
    IdentityRegistry
} from "contracts/registry/implementation/IdentityRegistry.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TrustedIssuersRegistry } from "contracts/registry/implementation/TrustedIssuersRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { Countries } from "../helpers/Countries.sol";
import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";
import { ClaimIssuerTrick } from "../mocks/ClaimIssuerTrick.sol";
import { MockContract } from "../mocks/MockContract.sol";

contract IdentityRegistryTest is TREXSuiteTest {

    // Contracts
    IdentityRegistry public identityRegistry;
    ClaimTopicsRegistry public claimTopicsRegistry;
    TrustedIssuersRegistry public trustedIssuersRegistry;
    IdentityRegistryStorage public identityRegistryStorage;

    /// @notice Sets up IdentityRegistry via proxy with full suite
    function setUp() public override {
        super.setUp();

        token = _deployTokenWithClaimTopic("salt2", "Dino Token", "DINO");

        claimTopicsRegistry = ClaimTopicsRegistry(address(token.identityRegistry().topicsRegistry()));
        identityRegistry = IdentityRegistry(address(token.identityRegistry()));
        identityRegistryStorage = IdentityRegistryStorage(address(token.identityRegistry().identityStorage()));
        trustedIssuersRegistry = TrustedIssuersRegistry(address(token.identityRegistry().issuersRegistry()));

        _registerIdentities(token);

        bytes memory claimData = "Some claim public data.";
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), alice);
        _addClaim(bobIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), bob);
    }

    // ============ init() Tests ============

    /// @notice Should prevent to initialize again
    function test_init_RevertWhen_AlreadyInitialized() public {
        vm.prank(deployer);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        identityRegistry.init(address(0), address(0), address(0), deployer);
    }

    /// @notice Should reject zero address for all parameters when calling init directly
    function test_init_RevertWhen_ZeroAddress_InitCall() public {
        // Deploy new implementation
        IdentityRegistry implementation = new IdentityRegistry();

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(
                IdentityRegistry.init.selector,
                address(0), // Zero address for Trusted Issuers Registry
                address(claimTopicsRegistry),
                address(identityRegistryStorage),
                deployer
            )
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(
                IdentityRegistry.init.selector,
                address(trustedIssuersRegistry),
                address(0), // Zero address for Claim Topics Registry
                address(identityRegistryStorage),
                deployer
            )
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(
                IdentityRegistry.init.selector,
                address(trustedIssuersRegistry),
                address(claimTopicsRegistry),
                address(0), // Zero address for Identity Storage
                deployer
            )
        );
    }

    /// @notice Should reject zero address for Trusted Issuers Registry
    function test_init_RevertWhen_TrustedIssuersRegistryZeroAddress() public {
        // Deploy proxy with zero address for Trusted Issuers Registry
        address randomAddress = vm.addr(999);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryProxy(
            address(trexImplementationAuthority), randomAddress, address(0), randomAddress, deployer
        );
    }

    /// @notice Should reject zero address for Claim Topics Registry
    function test_init_RevertWhen_ClaimTopicsRegistryZeroAddress() public {
        // Deploy proxy with zero address for Claim Topics Registry
        address randomAddress = vm.addr(999);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryProxy(
            address(trexImplementationAuthority), randomAddress, randomAddress, address(0), deployer
        );
    }

    /// @notice Should reject zero address for Identity Storage
    function test_init_RevertWhen_IdentityStorageZeroAddress() public {
        // Deploy proxy with zero address for Identity Storage
        address randomAddress = vm.addr(999);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryProxy(
            address(trexImplementationAuthority), address(0), randomAddress, randomAddress, deployer
        );
    }

    /// @notice Should revert when initialization fails (invalid implementation)
    function test_constructor_RevertWhen_InitializationFails() public {
        // Deploy a mock contract that doesn't have init() function
        MockContract mockImpl = new MockContract();

        // Deploy an IA and manually set an invalid IR implementation
        TREXImplementationAuthority incompleteIA =
            new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));

        // Create a version with invalid IR implementation (mock contract without init())
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 0 });

        ITREXImplementationAuthority.TREXContracts memory contracts = ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: address(mockImpl), // Invalid - doesn't have proper init
            ctrImplementation: address(mockImpl), // Invalid
            irImplementation: address(mockImpl), // Invalid - doesn't have init() function
            irsImplementation: address(mockImpl), // Invalid
            tirImplementation: address(mockImpl), // Invalid
            mcImplementation: address(mockImpl) // Invalid
        });

        // Add version to IA (need to be owner)
        _authorizeIAGovernance(address(incompleteIA));
        vm.prank(deployer);
        incompleteIA.addAndUseTREXVersion(version, contracts);

        // Now try to deploy proxy - delegatecall to mockImpl.init() will fail
        // because MockContract doesn't have init() function, so the proxy constructor bubbles the empty revert
        address randomAddress = vm.addr(999);
        vm.expectRevert();
        new IdentityRegistryProxy(address(incompleteIA), randomAddress, randomAddress, randomAddress, deployer);
    }

    // ============ updateIdentity() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_updateIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.updateIdentity(bob, charlieIdentity);
    }

    /// @notice Should update identity successfully when called by agent
    function test_updateIdentity_Success() public {
        // Get bob's current identity
        IIdentity oldIdentity = identityRegistry.identity(bob);
        assertEq(address(oldIdentity), address(bobIdentity));

        // Update to charlie's identity
        vm.expectEmit(true, true, false, false, address(identityRegistry));
        emit ERC3643EventsLib.IdentityUpdated(oldIdentity, charlieIdentity);
        vm.prank(agent);
        identityRegistry.updateIdentity(bob, charlieIdentity);

        // Verify identity was updated
        IIdentity newIdentity = identityRegistry.identity(bob);
        assertEq(address(newIdentity), address(charlieIdentity));
    }

    // ============ updateCountry() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_updateCountry_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.updateCountry(bob, 100);
    }

    // ============ deleteIdentity() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_deleteIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.deleteIdentity(bob);
    }

    // ============ registerIdentity() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_registerIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.registerIdentity(address(0), IIdentity(address(0)), 0);
    }

    /// @notice Should register an identity when sender holds the umbrella AGENT role
    function test_registerIdentity_Success_WithUmbrellaAgentRole() public {
        address umbrellaAgent = makeAddr("umbrellaAgent");
        _grantAgentRole(umbrellaAgent);

        vm.prank(umbrellaAgent);
        identityRegistry.registerIdentity(david, charlieIdentity, Countries.FRANCE);

        assertTrue(identityRegistry.contains(david));
    }

    // ============ batchRegisterIdentity() Tests ============

    /// @notice Should register multiple identities in a single call. `batchRegisterIdentity` is not
    ///         itself wired to a role, so the inner `registerIdentity` restricted check resolves the
    ///         outer selector to the default ADMIN role; the test contract holds it as manager admin.
    function test_batchRegisterIdentity_Success() public {
        IIdentity davidIdentity = _deployIdentity(david, "david");
        IIdentity anotherIdentity = _deployIdentity(another, "another");

        address[] memory userAddresses = new address[](2);
        userAddresses[0] = david;
        userAddresses[1] = another;

        IIdentity[] memory identities = new IIdentity[](2);
        identities[0] = davidIdentity;
        identities[1] = anotherIdentity;

        uint16[] memory countries = new uint16[](2);
        countries[0] = Countries.FRANCE;
        countries[1] = Countries.SPAIN;

        identityRegistry.batchRegisterIdentity(userAddresses, identities, countries);

        assertTrue(identityRegistry.contains(david));
        assertTrue(identityRegistry.contains(another));
        assertEq(address(identityRegistry.identity(david)), address(davidIdentity));
        assertEq(address(identityRegistry.identity(another)), address(anotherIdentity));
        assertEq(identityRegistry.investorCountry(david), Countries.FRANCE);
        assertEq(identityRegistry.investorCountry(another), Countries.SPAIN);
    }

    // ============ setIdentityRegistryStorage() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_setIdentityRegistryStorage_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.setIdentityRegistryStorage(address(0));
    }

    /// @notice Should set the identity registry storage. The replacement must share the registry's
    ///         AccessManager authority (onlySharedAuthority), so a sibling IRS proxy is deployed against it.
    function test_setIdentityRegistryStorage_Success() public {
        address newStorage = address(
            new IdentityRegistryStorageProxy(address(trexImplementationAuthority), address(accessManager), address(0))
        );

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.IdentityStorageSet(newStorage);
        identityRegistry.setIdentityRegistryStorage(newStorage);

        assertEq(address(identityRegistry.identityStorage()), newStorage);
    }

    // ============ setClaimTopicsRegistry() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_setClaimTopicsRegistry_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.setClaimTopicsRegistry(address(0));
    }

    /// @notice Should set the claim topics registry. The replacement must share the registry's AccessManager
    ///         authority (onlySharedAuthority), so a sibling CTR proxy is deployed against it.
    function test_setClaimTopicsRegistry_Success() public {
        address newRegistry = address(
            new ClaimTopicsRegistryProxy(address(trexImplementationAuthority), address(accessManager), new uint256[](0))
        );

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.ClaimTopicsRegistrySet(newRegistry);
        identityRegistry.setClaimTopicsRegistry(newRegistry);

        assertEq(address(identityRegistry.topicsRegistry()), newRegistry);
    }

    // ============ setTrustedIssuersRegistry() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_setTrustedIssuersRegistry_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.setTrustedIssuersRegistry(address(0));
    }

    /// @notice Should set the trusted issuers registry. The replacement must share the registry's
    ///         AccessManager authority (onlySharedAuthority), so a sibling TIR proxy is deployed against it.
    function test_setTrustedIssuersRegistry_Success() public {
        address newRegistry = address(
            new TrustedIssuersRegistryProxy(
                address(trexImplementationAuthority), address(accessManager), new address[](0), new uint256[][](0)
            )
        );

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.TrustedIssuersRegistrySet(newRegistry);
        identityRegistry.setTrustedIssuersRegistry(newRegistry);

        assertEq(address(identityRegistry.issuersRegistry()), newRegistry);
    }

    // ============ supportsInterface() Tests ============

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(identityRegistry.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the IIdentityRegistry interface ID
    function test_supportsInterface_ReturnsTrue_ForIIdentityRegistry() public view {
        assertTrue(identityRegistry.supportsInterface(type(IIdentityRegistry).interfaceId));
    }

    /// @notice Should correctly identify the IERC3643IdentityRegistry interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC3643IdentityRegistry() public view {
        assertTrue(identityRegistry.supportsInterface(type(IERC3643IdentityRegistry).interfaceId));
    }

    /// @notice IERC173 is part of the public interface via the AccessManagerOwnable ERC-173 ownership shim
    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(identityRegistry.supportsInterface(type(IERC173).interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(identityRegistry.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ isVerified() Tests ============

    /// @notice Should return true when the identity is registered and there are no required claim topics
    function test_isVerified_ReturnsTrue_WhenNoClaimTopics() public {
        // Initially charlie is not verified (has claim topic requirement)
        assertFalse(identityRegistry.isVerified(charlie));

        // Remove all claim topics, Basically we just added claim topic = 1 in the setup function
        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        for (uint256 i = 0; i < topics.length; i++) {
            vm.prank(deployer);
            claimTopicsRegistry.removeClaimTopic(topics[i]);
        }

        // Now charlie should be verified
        assertTrue(identityRegistry.isVerified(charlie));
    }

    /// @notice Should return false when claim topics are required but there are no trusted issuers for them
    function test_isVerified_ReturnsFalse_WhenNoTrustedIssuersForClaimTopic() public {
        // Initially alice is verified (has claim and trusted issuer)
        assertTrue(identityRegistry.isVerified(alice));

        // Remove all trusted issuers for the claim topic
        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        address[] memory trustedIssuers = trustedIssuersRegistry.getTrustedIssuersForClaimTopic(topics[0]);
        for (uint256 i = 0; i < trustedIssuers.length; i++) {
            vm.prank(deployer);
            trustedIssuersRegistry.removeTrustedIssuer(trustedIssuers[i]);
        }

        // Now alice should not be verified
        assertFalse(identityRegistry.isVerified(alice));
    }

    /// @notice Should return false when the only claim required was revoked
    function test_isVerified_ReturnsFalse_WhenClaimRevoked() public {
        // Initially alice is verified
        assertTrue(identityRegistry.isVerified(alice));

        // Get claim and revoke it
        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(topics[0]);

        // claimIds[0] is already issued by the claim issuer in the setup. Revocation is now keyed by
        // the EIP-712 claim digest rather than the raw signature.
        (,,,, Structs.ClaimData memory data,) = aliceIdentity.getClaim(claimIds[0]);
        bytes32 digest = IIdentity(address(claimIssuer)).getClaimHash(address(aliceIdentity), topics[0], data);

        vm.prank(claimIssuerSigner.addr);
        IClaimIssuer(address(claimIssuer)).revokeClaimByDigest(digest);

        // Now alice should not be verified
        assertFalse(identityRegistry.isVerified(alice));
    }

    /// @notice Should return true if there is another valid claim when one claim issuer throws an error
    function test_isVerified_ReturnsTrue_WhenClaimIssuerThrowsErrorButAnotherValidClaimExists() public {
        // Deploy ClaimIssuerTrick (always throws error on isClaimValid)
        ClaimIssuerTrick trickyClaimIssuer = new ClaimIssuerTrick(address(claimsModule));

        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        uint256 topic = topics[0];

        // Remove existing trusted issuer and add both tricky and normal issuer
        vm.startPrank(deployer);
        trustedIssuersRegistry.removeTrustedIssuer(address(claimIssuer));
        trustedIssuersRegistry.addTrustedIssuer(address(trickyClaimIssuer), topics);
        trustedIssuersRegistry.addTrustedIssuer(address(claimIssuer), topics);
        vm.stopPrank();

        // Alice keeps her valid claim from setUp and gains a second one from the tricky issuer. Claim
        // ids are keyed by (issuer, topic), so the two coexist rather than overwrite. The valid claim
        // is deliberately left untouched: removing a claim revokes its digest for good, so it could
        // not be added back.
        vm.prank(alice);
        aliceIdentity.addClaim(topic, 1, address(trickyClaimIssuer), "0x00", _trickyClaimData(), "");

        // Should still be verified (normal claim works)
        assertTrue(identityRegistry.isVerified(alice));
    }

    /// @notice Should return false if there are no other valid claims when claim issuer throws an error
    function test_isVerified_ReturnsFalse_WhenClaimIssuerThrowsErrorAndNoOtherValidClaim() public {
        // Deploy ClaimIssuerTrick (always throws error on isClaimValid)
        ClaimIssuerTrick trickyClaimIssuer = new ClaimIssuerTrick(address(claimsModule));

        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        uint256 topic = topics[0];

        // Add tricky issuer as trusted
        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(trickyClaimIssuer), topics);

        // Get alice's existing claim and remove it
        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(topic);
        vm.prank(alice);
        aliceIdentity.removeClaim(claimIds[0]);

        // Add only tricky claim (will throw error, no other valid claim)
        vm.prank(alice);
        aliceIdentity.addClaim(topic, 1, address(trickyClaimIssuer), "0x00", _trickyClaimData(), "");

        // Should not be verified (only claim throws error)
        assertFalse(identityRegistry.isVerified(alice));
    }

    // ============ disableEligibilityChecks() Tests ============

    /// @notice Should revert when called by a non-owner
    function test_disableEligibilityChecks_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.disableEligibilityChecks();
    }

    /// @notice Should disable eligibility checks and allow all addresses to be verified
    function test_disableEligibilityChecks_Success() public {
        vm.prank(deployer);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.EligibilityChecksDisabled();
        identityRegistry.disableEligibilityChecks();

        // Now any address should be verified
        assertTrue(identityRegistry.isVerified(charlie));
    }

    /// @notice Should revert when eligibility checks are already disabled
    function test_disableEligibilityChecks_RevertWhen_AlreadyDisabled() public {
        vm.prank(deployer);
        identityRegistry.disableEligibilityChecks();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EligibilityChecksDisabledAlready.selector);
        identityRegistry.disableEligibilityChecks();
    }

    // ============ enableEligibilityChecks() Tests ============

    /// @notice Should revert when called by a non-owner
    function test_enableEligibilityChecks_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistry.enableEligibilityChecks();
    }

    /// @notice Should re-enable eligibility checks and enforce normal verification
    function test_enableEligibilityChecks_Success() public {
        vm.prank(deployer);
        identityRegistry.disableEligibilityChecks();
        assertTrue(identityRegistry.isVerified(another)); // another should be verified when disabled

        vm.prank(deployer);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.EligibilityChecksEnabled();
        identityRegistry.enableEligibilityChecks();

        // Now another should not be verified (no identity registered)
        assertFalse(identityRegistry.isVerified(another));
    }

    /// @notice Should revert when eligibility checks are already enabled
    function test_enableEligibilityChecks_RevertWhen_AlreadyEnabled() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EligibilityChecksEnabledAlready.selector);
        identityRegistry.enableEligibilityChecks();
    }

    // ============ isVerified() Tests (with eligibility checks) ============

    /// @notice Should return true for any address when eligibility checks are disabled
    function test_isVerified_ReturnsTrue_WhenEligibilityChecksDisabled() public {
        vm.prank(deployer);
        identityRegistry.disableEligibilityChecks();

        assertTrue(identityRegistry.isVerified(charlie));
    }

    /// @notice Should resume normal eligibility checks when re-enabled
    function test_isVerified_ResumesNormalChecks_WhenReEnabled() public {
        vm.prank(deployer);
        identityRegistry.disableEligibilityChecks();
        assertTrue(identityRegistry.isVerified(charlie));

        vm.prank(deployer);
        identityRegistry.enableEligibilityChecks();

        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        if (topics.length > 0) {
            // charlie is not registered and has claim topics, so should be false
            assertFalse(identityRegistry.isVerified(charlie));
        } else {
            // If no topics required, verification should pass
            assertTrue(identityRegistry.isVerified(charlie));
        }
    }

    /// @dev Claim envelope for the tricky issuer: the payload is never read because the issuer
    ///      reverts before inspecting it, but `issuedAt` must be set for the claim to be stored.
    function _trickyClaimData() private view returns (Structs.ClaimData memory) {
        return Structs.ClaimData({ issuedAt: block.timestamp, validUntil: 0, payload: "0x00" });
    }

}
