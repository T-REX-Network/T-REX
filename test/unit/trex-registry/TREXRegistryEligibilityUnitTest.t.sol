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

    function test_disableEligibilityChecks_Success_IsVerifiedAlwaysTrue() public {
        vm.prank(deployer);
        vm.expectEmit(false, false, false, false, address(registry));
        emit EventsLib.EligibilityChecksDisabled();
        registry.disableEligibilityChecks();

        // Even an unregistered address must be considered verified.
        assertTrue(registry.isVerified(charlie));
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
        vm.prank(deployer);
        registry.disableEligibilityChecks();

        assertTrue(registry.isVerified(another));

        vm.prank(deployer);
        vm.expectEmit(false, false, false, false, address(registry));
        emit EventsLib.EligibilityChecksEnabled();
        registry.enableEligibilityChecks();

        // No registered identity = unverified
        assertFalse(registry.isVerified(another));
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
