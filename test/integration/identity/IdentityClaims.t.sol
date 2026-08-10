// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { Errors } from "@onchain-id/solidity/contracts/libraries/Errors.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";
import { ClaimIssuerAlwaysReverts } from "../mocks/ClaimIssuerAlwaysReverts.sol";

/// @notice Locks the two claim-write behaviors the ONCHAINID migration introduced, both called out in
///         the PR body: `addClaim` verifies with the issuer before storing, and `removeClaim` revokes
///         the claim's digest permanently.
/// @dev These live at the identity level rather than under `registries/` because the behavior belongs to
///      ERC734Validator, not to IdentityRegistry. The registry tests cover how a *reader* copes with a
///      misbehaving issuer (see IdentityRegistry.t.sol); here the write path is the subject.
contract IdentityClaimsTest is TREXSuiteTest {

    bytes internal constant CLAIM_PAYLOAD = "Some claim public data.";

    function _claimData(bytes memory payload) internal view returns (Structs.ClaimData memory) {
        return Structs.ClaimData({ issuedAt: block.timestamp, validUntil: 0, payload: payload });
    }

    /// @dev Claim ids are keyed by (issuer, topic), mirroring `ERC734Validator._addClaim`.
    function _claimId(address issuer, uint256 topic) internal pure returns (bytes32) {
        return keccak256(abi.encode(issuer, topic));
    }

    // ============ addClaim() issuer-verification Tests ============

    /// @notice `addClaim` calls `isClaimValid` on the declared issuer before storing. An issuer that
    ///         reverts must abort the write, not be swallowed into a stored-but-unverifiable claim.
    function test_addClaim_RevertWhen_IssuerReverts() public {
        ClaimIssuerAlwaysReverts brokenIssuer = new ClaimIssuerAlwaysReverts();
        Structs.ClaimData memory data = _claimData(CLAIM_PAYLOAD);

        vm.prank(alice);
        vm.expectRevert(ClaimIssuerAlwaysReverts.IssuerDown.selector);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(brokenIssuer), "", data, "uri");

        assertEq(
            aliceIdentity.getClaimIdsByTopic(CLAIM_TOPIC_1).length, 0, "No claim may be stored when the issuer reverts"
        );
    }

    // ============ removeClaim() digest-revocation Tests ============

    /// @notice Removing a claim revokes its digest for good: replaying the identical (issuer, topic,
    ///         ClaimData) bytes fails issuer verification and reverts with `InvalidClaim`.
    function test_addClaim_RevertWhen_ReAddingRemovedClaim() public {
        Structs.ClaimData memory data = _claimData(CLAIM_PAYLOAD);
        bytes memory signature =
            _signClaim(aliceIdentity, CLAIM_TOPIC_1, data, claimIssuerSigner.key, address(claimIssuer));

        vm.prank(alice);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(claimIssuer), signature, data, "uri");

        bytes32 claimId = _claimId(address(claimIssuer), CLAIM_TOPIC_1);
        vm.prank(alice);
        aliceIdentity.removeClaim(claimId);

        assertEq(aliceIdentity.getClaimIdsByTopic(CLAIM_TOPIC_1).length, 0, "Claim must be gone after removeClaim");

        // Pin the reason: InvalidClaim is also what a bad signature yields. Queried on the validator
        // as the issuer, since it reads `msg.sender`'s revoked digests and Identity only routes
        // `isClaimValid`.
        vm.prank(address(claimIssuer));
        IClaimIssuer.ClaimStatus status = validatorModule.getClaimStatus(aliceIdentity, CLAIM_TOPIC_1, signature, data);
        assertEq(
            uint256(status),
            uint256(IClaimIssuer.ClaimStatus.Revoked),
            "Removed claim's digest must read back as Revoked"
        );

        // Identical bytes, identical signature: the digest is revoked, so isClaimValid now returns false.
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidClaim.selector);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(claimIssuer), signature, data, "uri");
    }

    /// @notice Revocation is scoped to the digest, not to the (issuer, topic) pair: the issuer can
    ///         re-attest by signing fresh ClaimData. Without this, a single removal would lock the
    ///         holder out of that topic forever.
    function test_addClaim_Succeeds_WhenIssuerReAttestsWithFreshData() public {
        Structs.ClaimData memory data = _claimData(CLAIM_PAYLOAD);
        bytes memory signature =
            _signClaim(aliceIdentity, CLAIM_TOPIC_1, data, claimIssuerSigner.key, address(claimIssuer));

        vm.prank(alice);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(claimIssuer), signature, data, "uri");

        vm.prank(alice);
        aliceIdentity.removeClaim(_claimId(address(claimIssuer), CLAIM_TOPIC_1));

        Structs.ClaimData memory freshData = _claimData("A freshly attested payload.");
        bytes memory freshSignature =
            _signClaim(aliceIdentity, CLAIM_TOPIC_1, freshData, claimIssuerSigner.key, address(claimIssuer));

        vm.prank(alice);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(claimIssuer), freshSignature, freshData, "uri");

        assertEq(
            aliceIdentity.getClaimIdsByTopic(CLAIM_TOPIC_1).length,
            1,
            "Issuer must be able to re-attest the same topic with fresh data"
        );
    }

}
