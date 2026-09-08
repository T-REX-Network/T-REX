// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

/// @notice An identity that answers any claim id with itself as the issuer, and vouches for itself.
/// @dev Models a modular account whose holder installed a `getClaim` fallback handler.
contract SelfAttestingIdentity {

    uint256 private immutable _topic;

    constructor(uint256 topic) {
        _topic = topic;
    }

    function getClaim(bytes32)
        external
        view
        returns (uint256, uint256, address, bytes memory, Structs.ClaimData memory, string memory)
    {
        Structs.ClaimData memory data =
            Structs.ClaimData({ issuedAt: block.timestamp, validUntil: 0, metadataHash: bytes32(0), payload: "" });
        return (_topic, 1, address(this), "", data, "");
    }

    function isClaimValid(IIdentity, uint256, bytes calldata, Structs.ClaimData calldata) external pure returns (bool) {
        return true;
    }

}

/// @notice An identity that names the trusted issuer while holding no claim from it.
contract IssuerSpoofingIdentity {

    uint256 private immutable _topic;
    address private immutable _issuer;

    constructor(uint256 topic, address issuer) {
        _topic = topic;
        _issuer = issuer;
    }

    function getClaim(bytes32)
        external
        view
        returns (uint256, uint256, address, bytes memory, Structs.ClaimData memory, string memory)
    {
        Structs.ClaimData memory data =
            Structs.ClaimData({ issuedAt: block.timestamp, validUntil: 0, metadataHash: bytes32(0), payload: "" });
        return (_topic, 1, _issuer, "", data, "");
    }

}

/// @notice H-01: the issuer an identity returns must not decide whether its own claim is valid.
contract TREXRegistryIsVerifiedIssuerBindingUnitTest is TREXRegistryBaseUnitTest {

    SelfAttestingIdentity public attackerIdentity;

    function setUp() public override {
        super.setUp();

        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.startPrank(deployer);
        registry.addClaimTopic(CLAIM_TOPIC_1);
        registry.addTrustedIssuer(address(claimIssuer), topics);
        vm.stopPrank();

        attackerIdentity = new SelfAttestingIdentity(CLAIM_TOPIC_1);
        vm.prank(agent);
        registry.registerIdentity(another, IIdentity(address(attackerIdentity)), 250);
    }

    /// @dev Previously true: the claim id came from the trusted issuer, the validation did not.
    function test_isVerified_ReturnsFalse_WhenIdentityReturnsSelfControlledIssuer() public view {
        assertFalse(registry.isVerified(another));
    }

    /// @dev The configured issuer signed nothing for this identity, so it rejects the claim.
    function test_isVerified_ReturnsFalse_WhenIdentityNamesTrustedIssuerWithoutAValidClaim() public {
        IssuerSpoofingIdentity spoofer = new IssuerSpoofingIdentity(CLAIM_TOPIC_1, address(claimIssuer));

        vm.prank(agent);
        registry.updateIdentity(another, IIdentity(address(spoofer)));

        assertFalse(registry.isVerified(another));
    }

}
