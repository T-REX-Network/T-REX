// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { IERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

import { ClaimIssuerTrick } from "../mocks/ClaimIssuerTrick.sol";
import { Countries } from "test/integration/helpers/Countries.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract EligibilityCheckTest is TREXSuiteTest {

    UtilityChecker public utilityChecker;

    TREXRegistry public identityRegistry;
    IERC3643ClaimTopicsRegistry public claimTopicsRegistry;
    IERC3643TrustedIssuersRegistry public trustedIssuersRegistry;

    function setUp() public override {
        super.setUp();

        token = _deployTokenWithClaimTopic("salt2", "Dino Token", "DINO");

        // Get registries
        IERC3643IdentityRegistry ir = token.identityRegistry();
        identityRegistry = TREXRegistry(address(ir));
        claimTopicsRegistry = ir.topicsRegistry();
        trustedIssuersRegistry = ir.issuersRegistry();

        // The issuer is minted with claimIssuerSigner as its CLAIM_SIGNER key, so no key setup here.

        // Register alice in IdentityRegistry
        vm.prank(agent);
        identityRegistry.registerIdentity(alice, aliceIdentity, Countries.FRANCE);

        // Add claim to alice's identity
        bytes memory claimData = "Some claim public data.";
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), alice);

        // Deploy UtilityChecker via proxy
        UtilityChecker utilityCheckerImpl = new UtilityChecker();
        bytes memory utilityCheckerInitData = abi.encodeWithSelector(UtilityChecker.initialize.selector);
        UtilityCheckerProxy utilityCheckerProxy =
            new UtilityCheckerProxy(address(utilityCheckerImpl), utilityCheckerInitData);
        utilityChecker = UtilityChecker(address(utilityCheckerProxy));
    }

    // ============ getVerifiedDetails() Tests ============

    /// @notice Should return false when the identity is registered with topics
    function test_getVerifiedDetails_ReturnsFalse_WhenIdentityRegisteredWithTopics() public {
        // Register charlie, but we did net add claims for charlie
        vm.prank(agent);
        identityRegistry.registerIdentity(charlie, charlieIdentity, 0);

        UtilityChecker.EligibilityCheckDetails[] memory results =
            utilityChecker.getVerifiedDetails(address(token), charlie);

        assertEq(results.length, 1);
        assertEq(address(results[0].issuer), address(0));
        assertEq(results[0].topic, 0);
        assertFalse(results[0].pass);
    }

    /// @notice Should return empty result when the identity is registered without topics
    function test_getVerifiedDetails_ReturnsEmpty_WhenNoClaimTopics() public {
        // Register charlie
        vm.prank(agent);
        identityRegistry.registerIdentity(charlie, charlieIdentity, 0);

        // Remove all claim topics
        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        for (uint256 i = 0; i < topics.length; i++) {
            vm.prank(deployer);
            claimTopicsRegistry.removeClaimTopic(topics[i]);
        }

        UtilityChecker.EligibilityCheckDetails[] memory results =
            utilityChecker.getVerifiedDetails(address(token), charlie);

        assertEq(results.length, 0);
    }

    /// @notice Should return true because alice has claims
    function test_getVerifiedDetails_ReturnsTrue_AfterFixture() public view {
        UtilityChecker.EligibilityCheckDetails[] memory results =
            utilityChecker.getVerifiedDetails(address(token), alice);

        assertEq(results.length, 1);
        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        address[] memory trustedIssuers = trustedIssuersRegistry.getTrustedIssuersForClaimTopic(topics[0]);

        assertEq(address(results[0].issuer), address(trustedIssuers[0]));
        assertEq(results[0].topic, topics[0]);
        assertTrue(results[0].pass);
    }

    /// @notice Should return true for multiple issuers and topics
    function test_getVerifiedDetails_ReturnsTrue_ForMultipleIssuersAndTopics() public {
        // Deploy a second claim issuer for this test, signing with its own key
        Account memory newClaimIssuerSigner = makeAccount("newClaimIssuerSigner");
        uint256 newClaimIssuerSigningKeyPrivateKey = newClaimIssuerSigner.key;
        Identity newclaimIssuer = _deployClaimIssuer(newClaimIssuerSigner.addr, "newClaimIssuer");

        // Add two more claim topics
        uint256 claimTopic2 = 2;
        uint256 claimTopic3 = 3;

        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(claimTopic2);
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(claimTopic3);

        // Add the new claim issuer for these topics
        uint256[] memory newTopics = new uint256[](2);
        newTopics[0] = claimTopic2;
        newTopics[1] = claimTopic3;
        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(newclaimIssuer), newTopics);

        // Add claims to alice's identity for the new topics using the new claim issuer
        bytes memory claimData = "Some claim public data 2.";
        _addClaim(
            aliceIdentity, claimTopic2, claimData, newClaimIssuerSigningKeyPrivateKey, address(newclaimIssuer), alice
        );
        _addClaim(
            aliceIdentity, claimTopic3, claimData, newClaimIssuerSigningKeyPrivateKey, address(newclaimIssuer), alice
        );

        UtilityChecker.EligibilityCheckDetails[] memory results =
            utilityChecker.getVerifiedDetails(address(token), alice);

        assertEq(results.length, 3);

        uint256[] memory allTopics = claimTopicsRegistry.getClaimTopics();
        for (uint256 i = 0; i < allTopics.length; i++) {
            address[] memory trustedIssuers = trustedIssuersRegistry.getTrustedIssuersForClaimTopic(allTopics[i]);
            assertEq(address(results[i].issuer), address(trustedIssuers[0]));
            assertEq(results[i].topic, allTopics[i]);
            assertTrue(results[i].pass);
        }
    }

    /// @notice Should return false when claim issuer throws an error in isClaimValid
    function test_getVerifiedDetails_ReturnsFalse_WhenClaimIssuerThrowsError() public {
        // Deploy ClaimIssuerTrick (always throws error on isClaimValid unless called by identity)
        ClaimIssuerTrick trickyClaimIssuer = new ClaimIssuerTrick(address(validatorModule));

        uint256[] memory topics = claimTopicsRegistry.getClaimTopics();
        uint256 topic = topics[0];

        // Add tricky issuer as trusted
        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(trickyClaimIssuer), topics);

        // Get alice's existing claim and remove it
        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(topic);
        vm.prank(alice);
        aliceIdentity.removeClaim(claimIds[0]);

        // Add tricky claim (will throw error when isClaimValid is called)
        // Built before the prank: computing the metadata hash calls the validator, which would
        // otherwise consume the prank meant for addClaim.
        Structs.ClaimData memory trickyData = Structs.ClaimData({
            issuedAt: block.timestamp,
            validUntil: 0,
            metadataHash: validatorModule.getMetadataHash(1, ""),
            payload: "0x00"
        });
        vm.prank(alice);
        aliceIdentity.addClaim(topic, 1, address(trickyClaimIssuer), "0x00", trickyData, "");

        // getVerifiedDetails should handle the error and return false
        UtilityChecker.EligibilityCheckDetails[] memory results =
            utilityChecker.getVerifiedDetails(address(token), alice);

        assertEq(results.length, 1);
        assertEq(address(results[0].issuer), address(trickyClaimIssuer));
        assertEq(results[0].topic, topic);
        assertFalse(results[0].pass); // Should be false because isClaimValid threw an error
    }

    /// @notice Should resolve the per-identity-type topics, mirroring isVerified. The default set is
    ///         the KYC topic every investor needs; corporates must additionally pass KYB.
    function test_getVerifiedDetails_UsesTypeTopics_WhenOverrideSetForIdentityType() public {
        uint256 claimTopicKyb = uint256(keccak256(abi.encode("CLAIM_TOPIC_KYB")));

        // A business investor: a CORPORATE identity holding the same KYC claim as everyone else.
        address business = makeAddr("business");
        IIdentity businessIdentity = _deployCorporateIdentity(business, "business");
        vm.prank(agent);
        identityRegistry.registerIdentity(business, businessIdentity, Countries.FRANCE);
        _addClaim(businessIdentity, CLAIM_TOPIC_1, "KYC data", claimIssuerSigner.key, address(claimIssuer), business);

        // Trust the issuer for KYB as well, then require KYC + KYB of corporates only.
        uint256[] memory issuerTopics = new uint256[](2);
        issuerTopics[0] = CLAIM_TOPIC_1;
        issuerTopics[1] = claimTopicKyb;
        vm.startPrank(deployer);
        trustedIssuersRegistry.updateIssuerClaimTopics(address(claimIssuer), issuerTopics);
        identityRegistry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_1);
        identityRegistry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, claimTopicKyb);
        vm.stopPrank();

        // The corporate set replaces the default one: KYC passes, KYB is missing.
        UtilityChecker.EligibilityCheckDetails[] memory results =
            utilityChecker.getVerifiedDetails(address(token), business);
        assertEq(results.length, 2);
        assertTrue(results[0].pass, "KYC claim must pass for the corporate investor");
        assertEq(address(results[1].issuer), address(0), "KYB has no matching claim yet");
        assertFalse(results[1].pass);
        assertFalse(identityRegistry.isVerified(business));

        // alice is a natural person: still on the default KYC-only set, unaffected by the override.
        UtilityChecker.EligibilityCheckDetails[] memory aliceResults =
            utilityChecker.getVerifiedDetails(address(token), alice);
        assertEq(aliceResults.length, 1);
        assertEq(aliceResults[0].topic, CLAIM_TOPIC_1);
        assertTrue(aliceResults[0].pass);
        assertTrue(identityRegistry.isVerified(alice));

        // With the KYB claim attached, the corporate row passes and diagnostics agree with isVerified.
        _addClaim(businessIdentity, claimTopicKyb, "KYB data", claimIssuerSigner.key, address(claimIssuer), business);
        results = utilityChecker.getVerifiedDetails(address(token), business);
        assertEq(results.length, 2);
        assertEq(address(results[1].issuer), address(claimIssuer));
        assertEq(results[1].topic, claimTopicKyb);
        assertTrue(results[1].pass);
        assertTrue(identityRegistry.isVerified(business));
    }

}
