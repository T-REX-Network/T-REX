// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { Vm } from "@forge-std/Vm.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { IdentityModulesHelper } from "test/helpers/IdentityModulesHelper.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

/// @notice Stand-in for an identity contract the suite's IdentityFactory never minted: the factory
///         holds no type record for it, so `identityTypeOf` reports 0.
contract NoTypeIdentity { }

contract TREXRegistryClaimTopicsByTypeUnitTest is TREXRegistryBaseUnitTest {

    uint256 public constant CLAIM_TOPIC_KYB = uint256(keccak256(abi.encode("CLAIM_TOPIC_KYB")));

    address public corp = makeAddr("corp");
    IIdentity public corpIdentity;

    function setUp() public override {
        super.setUp();
        _registerBaseIdentities();

        // The harness only registers INDIVIDUAL / CLAIM_ISSUER / ASSET policies; open CORPORATE too
        // (this contract is the AccessManager admin) so corporate identities can be minted.
        idFactory.setIdentityTypePolicy(IdentityTypes.CORPORATE, accessManager.PUBLIC_ROLE(), true, false);
        idFactory.setIdentityTypeModules(
            IdentityTypes.CORPORATE,
            IdentityModulesHelper.legacyQueueModules(address(keyApprovalModule), address(validatorModule))
        );
        corpIdentity = _deployTypedIdentity(corp, "corp", IdentityTypes.CORPORATE);
        vm.prank(agent);
        registry.registerIdentity(corp, corpIdentity, 442);

        // Default topic set = [CLAIM_TOPIC_1]; the issuer is trusted for the KYB topic as well so
        // per-type overrides can be satisfied.
        uint256[] memory topics = new uint256[](2);
        topics[0] = CLAIM_TOPIC_1;
        topics[1] = CLAIM_TOPIC_KYB;
        vm.startPrank(deployer);
        registry.addClaimTopic(CLAIM_TOPIC_1);
        registry.addTrustedIssuer(address(claimIssuer), topics);
        vm.stopPrank();

        // Everyone starts with the default (KYC-style) claim.
        bytes memory claimData = "Some claim public data.";
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), alice);
        _addClaim(corpIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), corp);
    }

    // ============ addClaimTopicForIdentityType() ============

    function test_addClaimTopicForIdentityType_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
    }

    function test_addClaimTopicForIdentityType_RevertWhen_TypeZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidIdentityType.selector);
        registry.addClaimTopicForIdentityType(0, CLAIM_TOPIC_KYB);
    }

    function test_addClaimTopicForIdentityType_RevertWhen_TopicAlreadyExists() public {
        vm.startPrank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        vm.expectRevert(ErrorsLib.ClaimTopicAlreadyExists.selector);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        vm.stopPrank();
    }

    function test_addClaimTopicForIdentityType_RevertWhen_MoreThan14Topics() public {
        vm.startPrank(deployer);
        for (uint256 i = 0; i < 15; i++) {
            registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, i);
        }
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, 15);
        vm.stopPrank();
    }

    function test_addClaimTopicForIdentityType_Success_EmitsEvent() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, false, address(registry));
        emit EventsLib.ClaimTopicAddedForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);

        uint256[] memory topics = registry.getClaimTopicsForIdentityType(IdentityTypes.CORPORATE);
        assertEq(topics.length, 1);
        assertEq(topics[0], CLAIM_TOPIC_KYB);
    }

    function test_addClaimTopicForIdentityType_SetsAreIndependent() public {
        vm.startPrank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        registry.addClaimTopicForIdentityType(IdentityTypes.SMART_CONTRACT, CLAIM_TOPIC_2);
        vm.stopPrank();

        // Per-type sets do not leak into each other or into the default set.
        assertEq(registry.getClaimTopicsForIdentityType(IdentityTypes.CORPORATE).length, 1);
        assertEq(registry.getClaimTopicsForIdentityType(IdentityTypes.SMART_CONTRACT).length, 1);
        assertEq(registry.getClaimTopicsForIdentityType(IdentityTypes.INDIVIDUAL).length, 0);
        uint256[] memory defaultTopics = registry.getClaimTopics();
        assertEq(defaultTopics.length, 1);
        assertEq(defaultTopics[0], CLAIM_TOPIC_1);
    }

    // ============ removeClaimTopicForIdentityType() ============

    function test_removeClaimTopicForIdentityType_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.removeClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
    }

    function test_removeClaimTopicForIdentityType_RevertWhen_TypeZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidIdentityType.selector);
        registry.removeClaimTopicForIdentityType(0, CLAIM_TOPIC_KYB);
    }

    function test_removeClaimTopicForIdentityType_Success_EmitsEvent() public {
        vm.startPrank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);

        vm.expectEmit(true, true, false, false, address(registry));
        emit EventsLib.ClaimTopicRemovedForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        registry.removeClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        vm.stopPrank();

        assertEq(registry.getClaimTopicsForIdentityType(IdentityTypes.CORPORATE).length, 0);
    }

    function test_removeClaimTopicForIdentityType_NoOpWhenAbsent() public {
        // Removing an absent topic must NOT revert and must NOT emit, mirroring removeClaimTopic.
        vm.recordLogs();
        vm.prank(deployer);
        registry.removeClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    // ============ getClaimTopicsForIdentityType() ============

    function test_getClaimTopicsForIdentityType_ReturnsEmptyByDefault() public view {
        assertEq(registry.getClaimTopicsForIdentityType(IdentityTypes.CORPORATE).length, 0);
        assertEq(registry.getClaimTopicsForIdentityType(0).length, 0);
    }

    // ============ isVerified() type-aware resolution ============

    function test_isVerified_UsesDefaultTopics_WhenNoOverrideForIdentityType() public view {
        // No overrides registered: everyone verifies against the default set, as before the feature.
        assertTrue(registry.isVerified(alice));
        assertTrue(registry.isVerified(corp));
    }

    function test_isVerified_UsesTypeTopics_WhenOverrideSetForIdentityType() public {
        // Corporate KYB end-to-end, written the way an issuer would configure it: businesses need
        // the same KYC as everyone plus KYB, so the override restates KYC and adds KYB.
        vm.startPrank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_1);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        vm.stopPrank();

        // corp holds KYC but not KYB yet.
        assertFalse(registry.isVerified(corp));
        // alice is a natural person: still on the default KYC-only set.
        assertTrue(registry.isVerified(alice));

        // Once the KYB claim is attached, corp satisfies both topics and verifies.
        _addClaim(corpIdentity, CLAIM_TOPIC_KYB, "KYB data", claimIssuerSigner.key, address(claimIssuer), corp);
        assertTrue(registry.isVerified(corp));
    }

    function test_isVerified_OverrideOmittingDefaultTopic_DropsThatRequirement() public {
        // The override is a replacement, not an addition: an override listing only KYB stops
        // requiring the default KYC topic of corporates. This is the documented foot-gun, pinned
        // here so a future change to additive semantics fails loudly.
        vm.prank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);

        // corp holds KYC only, which its type no longer asks for, and lacks KYB: not verified.
        assertFalse(registry.isVerified(corp));

        // Adding KYB alone is enough, even though the default KYC topic is absent from the set.
        _addClaim(corpIdentity, CLAIM_TOPIC_KYB, "KYB data", claimIssuerSigner.key, address(claimIssuer), corp);
        assertTrue(registry.isVerified(corp));
    }

    function test_isVerified_FallsBackToDefaultTopics_WhenOverrideRemoved() public {
        vm.prank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        assertFalse(registry.isVerified(corp));

        // Emptying the override set restores the default fallback.
        vm.prank(deployer);
        registry.removeClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        assertTrue(registry.isVerified(corp));
    }

    function test_isVerified_ReflectsIdentityTypeChange() public {
        // The ONCHAINID type is immutable, so a type change happens by swapping the stored identity.
        vm.prank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        assertFalse(registry.isVerified(corp));

        // The factory binds one identity per wallet, so the replacement is minted for a fresh key.
        address corpSigner = makeAddr("corpSigner");
        IIdentity individualIdentity = _deployTypedIdentity(corpSigner, "corp-as-individual", IdentityTypes.INDIVIDUAL);
        _addClaim(
            individualIdentity, CLAIM_TOPIC_1, "KYC data", claimIssuerSigner.key, address(claimIssuer), corpSigner
        );
        vm.prank(agent);
        registry.updateIdentity(corp, individualIdentity);

        // The next verification reads the new type and resolves the default set.
        assertTrue(registry.isVerified(corp));
    }

    function test_isVerified_ReadsTypeFromFactoryRecord_NotFromIdentity() public {
        vm.prank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        assertFalse(registry.isVerified(corp));

        // A hostile corporate identity claims to be INDIVIDUAL to dodge the stricter KYB set. The
        // registry reads the factory's creation-time record, so the lie changes nothing.
        vm.mockCall(
            address(corpIdentity),
            abi.encodeWithSelector(IIdentity.getIdentityType.selector),
            abi.encode(IdentityTypes.INDIVIDUAL)
        );
        assertFalse(registry.isVerified(corp));

        // Refusing to answer at all changes nothing either: the identity is never consulted.
        vm.mockCallRevert(
            address(corpIdentity), abi.encodeWithSelector(IIdentity.getIdentityType.selector), "type unavailable"
        );
        assertFalse(registry.isVerified(corp));
    }

    function test_isVerified_UsesDefaultTopics_WhenIdentityNotFactoryMinted() public {
        // A contract the factory never minted has no type record: `identityTypeOf` returns 0, which
        // resolves to the default topics even when per-type overrides exist.
        NoTypeIdentity foreignIdentity = new NoTypeIdentity();
        vm.prank(agent);
        registry.registerIdentity(another, IIdentity(address(foreignIdentity)), 250);

        vm.startPrank(deployer);
        registry.addClaimTopicForIdentityType(IdentityTypes.CORPORATE, CLAIM_TOPIC_KYB);
        // Empty the default set so the resolution outcome is observable without claims: an empty
        // required set verifies trivially, so reaching `true` proves the default set was chosen.
        registry.removeClaimTopic(CLAIM_TOPIC_1);
        vm.stopPrank();

        assertTrue(registry.isVerified(another));
    }

    /// @dev Mirrors the harness's `_deployIdentity` with a caller-chosen identity type.
    function _deployTypedIdentity(address wallet, string memory salt, uint256 identityType)
        internal
        returns (IIdentity)
    {
        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(wallet, KeyPurposes.MANAGEMENT);

        vm.prank(deployer);
        address identity = idFactory.createIdentityFor(wallet, identityType, salt, keys);
        return IIdentity(identity);
    }

}
