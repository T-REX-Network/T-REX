// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/IERC3643TrustedIssuersRegistry.sol";

import { TrustedIssuersRegistryHarness } from "./harnesses/StandardHarnesses.sol";

/// @dev ERC-3643 standard: Trusted Issuers Registry.
///
///  Runs against the standard base alone (issue #65). Every assertion states what the specification
///  requires, so this file must pass unchanged when OpenZeppelin's base replaces ours.
contract TrustedIssuersRegistryStandardTest is Test {

    TrustedIssuersRegistryHarness internal registry;

    address internal issuer = makeAddr("issuer");
    address internal otherIssuer = makeAddr("otherIssuer");

    function setUp() public {
        registry = new TrustedIssuersRegistryHarness();
    }

    function _topics(uint256 a) internal pure returns (uint256[] memory t) {
        t = new uint256[](1);
        t[0] = a;
    }

    function _topics(uint256 a, uint256 b) internal pure returns (uint256[] memory t) {
        t = new uint256[](2);
        t[0] = a;
        t[1] = b;
    }

    function test_getTrustedIssuers_IsEmptyInitially() public view {
        assertEq(registry.getTrustedIssuers().length, 0);
    }

    function test_addTrustedIssuer_RegistersIssuerAndTopics() public {
        registry.addTrustedIssuer(issuer, _topics(1, 2));

        assertTrue(registry.isTrustedIssuer(issuer));
        assertEq(registry.getTrustedIssuers().length, 1);
        assertEq(registry.getTrustedIssuerClaimTopics(issuer).length, 2);
        assertTrue(registry.hasClaimTopic(issuer, 1));
        assertTrue(registry.hasClaimTopic(issuer, 2));
    }

    function test_addTrustedIssuer_IndexesIssuerByTopic() public {
        registry.addTrustedIssuer(issuer, _topics(1));
        registry.addTrustedIssuer(otherIssuer, _topics(1));

        address[] memory forTopic = registry.getTrustedIssuersForClaimTopic(1);
        assertEq(forTopic.length, 2);
    }

    function test_addTrustedIssuer_EmitsTrustedIssuerAdded() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643TrustedIssuersRegistry.TrustedIssuerAdded(issuer, _topics(1));

        registry.addTrustedIssuer(issuer, _topics(1));
    }

    function test_addTrustedIssuer_RevertWhen_ZeroAddress() public {
        vm.expectRevert(ERC3643ErrorsLib.ZeroAddress.selector);
        registry.addTrustedIssuer(address(0), _topics(1));
    }

    function test_addTrustedIssuer_RevertWhen_AlreadyRegistered() public {
        registry.addTrustedIssuer(issuer, _topics(1));

        vm.expectRevert(ERC3643ErrorsLib.TrustedIssuerAlreadyExists.selector);
        registry.addTrustedIssuer(issuer, _topics(2));
    }

    function test_addTrustedIssuer_RevertWhen_NoTopics() public {
        vm.expectRevert(ERC3643ErrorsLib.TrustedClaimTopicsCannotBeEmpty.selector);
        registry.addTrustedIssuer(issuer, new uint256[](0));
    }

    function test_removeTrustedIssuer_DropsIssuerAndItsIndexEntries() public {
        registry.addTrustedIssuer(issuer, _topics(1, 2));

        registry.removeTrustedIssuer(issuer);

        assertFalse(registry.isTrustedIssuer(issuer));
        assertEq(registry.getTrustedIssuers().length, 0);
        assertEq(registry.getTrustedIssuerClaimTopics(issuer).length, 0);
        assertEq(registry.getTrustedIssuersForClaimTopic(1).length, 0);
        assertEq(registry.getTrustedIssuersForClaimTopic(2).length, 0);
    }

    function test_removeTrustedIssuer_EmitsTrustedIssuerRemoved() public {
        registry.addTrustedIssuer(issuer, _topics(1));

        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643TrustedIssuersRegistry.TrustedIssuerRemoved(issuer);

        registry.removeTrustedIssuer(issuer);
    }

    function test_removeTrustedIssuer_RevertWhen_NotRegistered() public {
        vm.expectRevert(ERC3643ErrorsLib.NotATrustedIssuer.selector);
        registry.removeTrustedIssuer(issuer);
    }

    function test_updateIssuerClaimTopics_ReplacesTheTopicSet() public {
        registry.addTrustedIssuer(issuer, _topics(1, 2));

        registry.updateIssuerClaimTopics(issuer, _topics(3));

        assertTrue(registry.hasClaimTopic(issuer, 3));
        assertFalse(registry.hasClaimTopic(issuer, 1));
        assertFalse(registry.hasClaimTopic(issuer, 2));
        assertEq(registry.getTrustedIssuersForClaimTopic(1).length, 0);
        assertEq(registry.getTrustedIssuersForClaimTopic(3).length, 1);
    }

    function test_updateIssuerClaimTopics_EmitsClaimTopicsUpdated() public {
        registry.addTrustedIssuer(issuer, _topics(1));

        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643TrustedIssuersRegistry.ClaimTopicsUpdated(issuer, _topics(4));

        registry.updateIssuerClaimTopics(issuer, _topics(4));
    }

    function test_updateIssuerClaimTopics_RevertWhen_NotRegistered() public {
        vm.expectRevert(ERC3643ErrorsLib.NotATrustedIssuer.selector);
        registry.updateIssuerClaimTopics(issuer, _topics(1));
    }

    function test_hasClaimTopic_IsFalseForUnknownIssuer() public view {
        assertFalse(registry.hasClaimTopic(issuer, 1));
    }

}
