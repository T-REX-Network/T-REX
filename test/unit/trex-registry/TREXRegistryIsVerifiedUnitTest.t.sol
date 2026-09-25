// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

/// @notice Stand-in claim issuer that returns true to the ERC734Validator (so `addClaim` can store
///         the claim) and reverts for every other reader — mirrors the `ClaimIssuerTrick` mock.
/// @dev The signature must track `IClaimIssuer.isClaimValid`; if it drifts, callers fail to dispatch
///      rather than reverting inside the function, which is a different code path from the one tested.
contract ClaimIssuerAlwaysRevert {

    /// @dev The ERC734Validator singleton, which calls this on the claim-write path.
    address private immutable _validatorModule;

    constructor(address validatorModule) {
        _validatorModule = validatorModule;
    }

    function isClaimValid(IIdentity, uint256, bytes calldata, Structs.ClaimData calldata) external view returns (bool) {
        if (msg.sender == _validatorModule) {
            return true;
        }
        revert("CLAIM_INVALID");
    }

}

contract TREXRegistryIsVerifiedUnitTest is TREXRegistryBaseUnitTest {

    function setUp() public override {
        super.setUp();
        _registerBaseIdentities();

        // Register CLAIM_TOPIC_1 + the base ClaimIssuer for that topic.
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.startPrank(deployer);
        registry.addClaimTopic(CLAIM_TOPIC_1);
        registry.addTrustedIssuer(address(claimIssuer), topics);
        vm.stopPrank();

        // Attach a valid claim signed by the trusted issuer for alice and bob.
        bytes memory claimData = "Some claim public data.";
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), alice);
        _addClaim(bobIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), bob);
    }

    // ============ Verified path ============

    function test_isVerified_ReturnsTrue_WithValidClaim() public view {
        assertTrue(registry.isVerified(alice));
        assertTrue(registry.isVerified(bob));
    }

    function test_isVerified_ReturnsFalse_WhenIdentityHasNoMatchingClaim() public view {
        // charlie has no claim attached
        assertFalse(registry.isVerified(charlie));
    }

    // ============ Wallet revocation (#69) ============

    /// @notice A locally registered wallet the factory has revoked is attributed but no longer admitted,
    ///  exactly as a wallet resolved through the factory fallback.
    function test_isVerified_ReturnsFalse_WhenLocallyRegisteredWalletIsRevoked() public {
        assertTrue(registry.isVerified(alice));
        assertTrue(registry.isLocallyRegistered(alice));

        vm.prank(address(aliceIdentity));
        idFactory.revokeAccount(InteroperableAddress.formatEvmV1(block.chainid, alice));

        assertFalse(registry.isVerified(alice));
        assertTrue(registry.contains(alice));
        assertEq(address(registry.identity(alice)), address(aliceIdentity));
    }

    /// @notice A wallet resolved through the factory fallback fails the same way once revoked, so both
    ///  registration paths give one answer.
    function test_isVerified_ReturnsFalse_WhenGloballyResolvedWalletIsRevoked() public {
        vm.prank(agent);
        registry.deleteIdentity(alice);
        assertFalse(registry.isLocallyRegistered(alice));
        assertTrue(registry.isVerified(alice));

        vm.prank(address(aliceIdentity));
        idFactory.revokeAccount(InteroperableAddress.formatEvmV1(block.chainid, alice));

        assertFalse(registry.isVerified(alice));
    }

    /// @notice A locally registered wallet the factory never linked keeps verifying: only a `Revoked`
    ///  status denies, never the absence of a factory record.
    function test_isVerified_ReturnsTrue_WhenLocallyRegisteredWalletIsUnknownToFactory() public {
        vm.prank(agent);
        registry.registerIdentity(another, aliceIdentity, 0);

        assertEq(address(idFactory.getIdentity(InteroperableAddress.formatEvmV1(block.chainid, another))), address(0));
        assertTrue(registry.isVerified(another));
    }

    /// @notice The kill switch still admits a revoked wallet: it bypasses the binding check as well.
    function test_isVerified_ReturnsTrue_WhenWalletIsRevokedAndChecksAreDisabled() public {
        vm.prank(address(aliceIdentity));
        idFactory.revokeAccount(InteroperableAddress.formatEvmV1(block.chainid, alice));
        assertFalse(registry.isVerified(alice));

        vm.prank(deployer);
        registry.disableEligibilityChecks();
        assertTrue(registry.isVerified(alice));
    }

    // ============ Topic / issuer mutations ============

    function test_isVerified_ReturnsTrue_WhenAllClaimTopicsRemoved() public {
        // Remove all required claim topics → verification short-circuits to true.
        uint256[] memory topics = registry.getClaimTopics();
        for (uint256 i = 0; i < topics.length; i++) {
            vm.prank(deployer);
            registry.removeClaimTopic(topics[i]);
        }
        assertTrue(registry.isVerified(charlie));
    }

    function test_isVerified_ReturnsFalse_WhenNoTrustedIssuerForClaimTopic() public {
        assertTrue(registry.isVerified(alice));

        address[] memory issuers = registry.getTrustedIssuersForClaimTopic(CLAIM_TOPIC_1);
        for (uint256 i = 0; i < issuers.length; i++) {
            vm.prank(deployer);
            registry.removeTrustedIssuer(issuers[i]);
        }
        assertFalse(registry.isVerified(alice));
    }

    function test_isVerified_ReturnsFalse_WhenClaimRevoked() public {
        assertTrue(registry.isVerified(alice));

        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(CLAIM_TOPIC_1);
        // Revocation is keyed by the EIP-712 claim digest rather than the raw signature.
        (,,,, Structs.ClaimData memory data,) = aliceIdentity.getClaim(claimIds[0]);
        bytes32 digest = IIdentity(address(claimIssuer)).getClaimHash(address(aliceIdentity), CLAIM_TOPIC_1, data);

        vm.prank(claimIssuerSigner.addr);
        IClaimIssuer(address(claimIssuer)).revokeClaimByDigest(digest);

        assertFalse(registry.isVerified(alice));
    }

    function test_isVerified_ReturnsTrue_WhenAnotherValidClaimExists() public {
        // Plug in a tricky issuer that reverts on isClaimValid; the second claim from the legit
        // issuer should still satisfy verification.
        ClaimIssuerAlwaysRevert trickyIssuer = new ClaimIssuerAlwaysRevert(address(validatorModule));
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;

        vm.startPrank(deployer);
        registry.removeTrustedIssuer(address(claimIssuer));
        registry.addTrustedIssuer(address(trickyIssuer), topics);
        registry.addTrustedIssuer(address(claimIssuer), topics);
        vm.stopPrank();

        // Alice keeps her valid claim from setUp and gains a second one from the tricky issuer.
        // Claim ids are keyed by (issuer, topic), so the two coexist rather than overwrite. The valid
        // claim is deliberately left untouched: removing a claim revokes its digest for good.
        // Built before the prank: constructing the claim data calls the validator, which would
        // otherwise consume the prank meant for addClaim.
        Structs.ClaimData memory trickyData = _trickyClaimData();
        vm.prank(alice);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(trickyIssuer), "0x00", trickyData, "");

        assertTrue(registry.isVerified(alice));
    }

    function test_isVerified_ReturnsFalse_WhenOnlyTrickyClaimAndIssuer() public {
        ClaimIssuerAlwaysRevert trickyIssuer = new ClaimIssuerAlwaysRevert(address(validatorModule));
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        registry.addTrustedIssuer(address(trickyIssuer), topics);

        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(CLAIM_TOPIC_1);
        vm.prank(alice);
        aliceIdentity.removeClaim(claimIds[0]);
        // Built before the prank: constructing the claim data calls the validator, which would
        // otherwise consume the prank meant for addClaim.
        Structs.ClaimData memory trickyData = _trickyClaimData();
        vm.prank(alice);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(trickyIssuer), "0x00", trickyData, "");

        assertFalse(registry.isVerified(alice));
    }

    // ============ Helpers ============

    /// @dev Claim envelope for the tricky issuer: the payload is never read because the issuer
    ///      reverts before inspecting it, but `issuedAt` must be set for the claim to be stored.
    function _trickyClaimData() private view returns (Structs.ClaimData memory) {
        return Structs.ClaimData({
            issuedAt: block.timestamp,
            validUntil: 0,
            metadataHash: validatorModule.getMetadataHash(1, ""),
            payload: "0x00"
        });
    }

}
