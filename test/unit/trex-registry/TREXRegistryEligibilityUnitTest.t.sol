// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

contract TREXRegistryEligibilityUnitTest is TREXRegistryBaseUnitTest {

    // ============ disableEligibilityChecks() ============

    function test_disableEligibilityChecks_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.disableEligibilityChecks();
    }

    /// @notice The kill switch skips the claims, not the identity: a wallet with an identity passes without the
    ///         claim a topic requires, and an address with no identity is still refused.
    function test_disableEligibilityChecks_Success_SkipsTheClaimsButNotTheIdentity() public {
        vm.prank(deployer);
        registry.addClaimTopic(CLAIM_TOPIC_1);
        assertFalse(registry.isVerified(charlie), "charlie holds no claim for the topic");

        vm.prank(deployer);
        vm.expectEmit(false, false, false, false, address(registry));
        emit EventsLib.EligibilityChecksDisabled();
        registry.disableEligibilityChecks();

        assertTrue(registry.isVerified(charlie), "the claim is skipped");
        assertFalse(registry.isVerified(another), "an address with no identity is still refused");
    }

    function test_disableEligibilityChecks_RevertWhen_AlreadyDisabled() public {
        vm.prank(deployer);
        registry.disableEligibilityChecks();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EligibilityChecksDisabledAlready.selector);
        registry.disableEligibilityChecks();
    }

    // ============ enableEligibilityChecks() ============

    function test_enableEligibilityChecks_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.enableEligibilityChecks();
    }

    function test_enableEligibilityChecks_RevertWhen_AlreadyEnabled() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EligibilityChecksEnabledAlready.selector);
        registry.enableEligibilityChecks();
    }

    function test_enableEligibilityChecks_Success() public {
        vm.startPrank(deployer);
        registry.addClaimTopic(CLAIM_TOPIC_1);
        registry.disableEligibilityChecks();
        vm.stopPrank();

        assertTrue(registry.isVerified(charlie));

        vm.prank(deployer);
        vm.expectEmit(false, false, false, false, address(registry));
        emit EventsLib.EligibilityChecksEnabled();
        registry.enableEligibilityChecks();

        // The claim is required again.
        assertFalse(registry.isVerified(charlie));
    }

    // ============ isVerified() ============

    function test_isVerified_ReturnsFalse_WhenNoIdentity() public view {
        assertFalse(registry.isVerified(another));
    }

    function test_isVerified_ReturnsTrue_WhenNoClaimTopicsRequired() public {
        _registerBaseIdentities();
        // No claim topics added — every registered identity must be verified.
        assertTrue(registry.isVerified(alice));
        assertTrue(registry.isVerified(bob));
    }

    function test_isVerified_ReturnsFalse_WhenClaimTopicWithoutTrustedIssuer() public {
        _registerBaseIdentities();

        vm.prank(deployer);
        registry.addClaimTopic(CLAIM_TOPIC_1);

        // No trusted issuer for the topic → no verification possible.
        assertFalse(registry.isVerified(alice));
    }

}
