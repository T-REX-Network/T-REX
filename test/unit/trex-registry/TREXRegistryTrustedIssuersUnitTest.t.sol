// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

contract TREXRegistryTrustedIssuersUnitTest is TREXRegistryBaseUnitTest {

    function setUp() public override {
        super.setUp();

        // Pre-register the base ClaimIssuer with CLAIM_TOPIC_1
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        registry.addTrustedIssuer(address(claimIssuer), topics);
    }

    // ============ addTrustedIssuer() ============

    function test_addTrustedIssuer_RevertWhen_NotOwner() public {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        address anotherIssuer = makeAddr("anotherIssuer");
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.addTrustedIssuer(address(anotherIssuer), topics);
    }

    function test_addTrustedIssuer_RevertWhen_ZeroAddress() public {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        registry.addTrustedIssuer(address(0), topics);
    }

    function test_addTrustedIssuer_RevertWhen_AlreadyRegistered() public {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TrustedIssuerAlreadyExists.selector);
        registry.addTrustedIssuer(address(claimIssuer), topics);
    }

    function test_addTrustedIssuer_RevertWhen_ClaimTopicsEmpty() public {
        address newIssuer = makeAddr("newIssuer");
        uint256[] memory empty = new uint256[](0);
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TrustedClaimTopicsCannotBeEmpty.selector);
        registry.addTrustedIssuer(address(newIssuer), empty);
    }

    function test_addTrustedIssuer_RevertWhen_MoreThan15ClaimTopics() public {
        address newIssuer = makeAddr("newIssuer");
        uint256[] memory topics = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            topics[i] = i;
        }
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        registry.addTrustedIssuer(address(newIssuer), topics);
    }

    function test_addTrustedIssuer_RevertWhen_MoreThan49Issuers() public {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        // We already have 1 issuer from setUp; add 49 more to reach 50 total.
        for (uint256 i = 0; i < 49; i++) {
            address issuerAddress = address(uint160(uint256(keccak256(abi.encodePacked("issuer", i)))));
            vm.prank(deployer);
            registry.addTrustedIssuer(issuerAddress, topics);
        }

        address overflow = makeAddr("overflow");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxTrustedIssuersReached.selector, 50));
        registry.addTrustedIssuer(address(overflow), topics);
    }

    function test_addTrustedIssuer_Success_EmitsEvent() public {
        address newIssuer = makeAddr("newIssuer");
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_2;

        vm.prank(deployer);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ERC3643EventsLib.TrustedIssuerAdded(address(newIssuer), topics);
        registry.addTrustedIssuer(address(newIssuer), topics);

        assertTrue(registry.isTrustedIssuer(address(newIssuer)));
    }

    // ============ removeTrustedIssuer() ============

    function test_removeTrustedIssuer_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.removeTrustedIssuer(address(claimIssuer));
    }

    function test_removeTrustedIssuer_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        registry.removeTrustedIssuer(address(0));
    }

    function test_removeTrustedIssuer_RevertWhen_NotRegistered() public {
        address newIssuer = makeAddr("newIssuer");
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NotATrustedIssuer.selector);
        registry.removeTrustedIssuer(address(newIssuer));
    }

    function test_removeTrustedIssuer_Success() public {
        address bobIssuer = makeAddr("bobIssuer");
        address anotherIssuer = makeAddr("anotherIssuer");
        address charlieIssuer = makeAddr("charlieIssuer");

        uint256[] memory topicsBob = new uint256[](3);
        topicsBob[0] = CLAIM_TOPIC_3;
        topicsBob[1] = CLAIM_TOPIC_4;
        topicsBob[2] = CLAIM_TOPIC_1;
        uint256[] memory topicsAnother = new uint256[](2);
        topicsAnother[0] = CLAIM_TOPIC_1;
        topicsAnother[1] = CLAIM_TOPIC_2;
        uint256[] memory topicsCharlie = new uint256[](3);
        topicsCharlie[0] = CLAIM_TOPIC_2;
        topicsCharlie[1] = CLAIM_TOPIC_3;
        topicsCharlie[2] = CLAIM_TOPIC_1;

        vm.startPrank(deployer);
        registry.addTrustedIssuer(address(bobIssuer), topicsBob);
        registry.addTrustedIssuer(address(anotherIssuer), topicsAnother);
        registry.addTrustedIssuer(address(charlieIssuer), topicsCharlie);
        vm.stopPrank();

        assertTrue(registry.isTrustedIssuer(address(anotherIssuer)));

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false, address(registry));
        emit ERC3643EventsLib.TrustedIssuerRemoved(address(anotherIssuer));
        registry.removeTrustedIssuer(address(anotherIssuer));

        assertFalse(registry.isTrustedIssuer(address(anotherIssuer)));

        address[] memory trusted = registry.getTrustedIssuers();
        assertEq(trusted.length, 3);
        assertEq(address(trusted[0]), address(claimIssuer));
        assertEq(address(trusted[1]), address(bobIssuer));
        assertEq(address(trusted[2]), address(charlieIssuer));
    }

    function test_removeTrustedIssuer_ClearsClaimTopics() public {
        address bobIssuer = makeAddr("bobIssuer");
        uint256[] memory topicsBob = new uint256[](2);
        topicsBob[0] = CLAIM_TOPIC_2;
        topicsBob[1] = CLAIM_TOPIC_3;

        vm.prank(deployer);
        registry.addTrustedIssuer(address(bobIssuer), topicsBob);

        vm.prank(deployer);
        registry.removeTrustedIssuer(address(bobIssuer));

        assertEq(registry.getTrustedIssuersForClaimTopic(CLAIM_TOPIC_2).length, 0);
        assertEq(registry.getTrustedIssuersForClaimTopic(CLAIM_TOPIC_3).length, 0);
        assertFalse(registry.hasClaimTopic(address(bobIssuer), CLAIM_TOPIC_2));
        assertFalse(registry.hasClaimTopic(address(bobIssuer), CLAIM_TOPIC_3));

        vm.expectRevert(ErrorsLib.TrustedIssuerDoesNotExist.selector);
        registry.getTrustedIssuerClaimTopics(address(bobIssuer));
    }

    function test_removeTrustedIssuer_KeepsCoIssuerOnSharedTopic() public {
        address bobIssuer = makeAddr("bobIssuer");
        address charlieIssuer = makeAddr("charlieIssuer");
        uint256[] memory sharedTopics = new uint256[](1);
        sharedTopics[0] = CLAIM_TOPIC_2;

        vm.startPrank(deployer);
        registry.addTrustedIssuer(address(bobIssuer), sharedTopics);
        registry.addTrustedIssuer(address(charlieIssuer), sharedTopics);
        registry.removeTrustedIssuer(address(bobIssuer));
        vm.stopPrank();

        address[] memory issuers = registry.getTrustedIssuersForClaimTopic(CLAIM_TOPIC_2);
        assertEq(issuers.length, 1);
        assertEq(address(issuers[0]), address(charlieIssuer));
        assertTrue(registry.hasClaimTopic(address(charlieIssuer), CLAIM_TOPIC_2));
    }

    // ============ updateIssuerClaimTopics() ============

    function test_updateIssuerClaimTopics_RevertWhen_NotOwner() public {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.updateIssuerClaimTopics(address(claimIssuer), topics);
    }

    function test_updateIssuerClaimTopics_RevertWhen_ZeroAddress() public {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        registry.updateIssuerClaimTopics(address(0), topics);
    }

    function test_updateIssuerClaimTopics_RevertWhen_NotRegistered() public {
        address newIssuer = makeAddr("newIssuer");
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NotATrustedIssuer.selector);
        registry.updateIssuerClaimTopics(address(newIssuer), topics);
    }

    function test_updateIssuerClaimTopics_RevertWhen_MoreThan15ClaimTopics() public {
        uint256[] memory topics = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            topics[i] = i;
        }
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        registry.updateIssuerClaimTopics(address(claimIssuer), topics);
    }

    function test_updateIssuerClaimTopics_RevertWhen_ClaimTopicsEmpty() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicsCannotBeEmpty.selector);
        registry.updateIssuerClaimTopics(address(claimIssuer), empty);
    }

    function test_updateIssuerClaimTopics_KeepsTopics_WhenEmptySetRejected() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicsCannotBeEmpty.selector);
        registry.updateIssuerClaimTopics(address(claimIssuer), empty);

        uint256[] memory topics = registry.getTrustedIssuerClaimTopics(address(claimIssuer));
        assertEq(topics.length, 1);
        assertEq(topics[0], CLAIM_TOPIC_1);
        assertTrue(registry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_1));
    }

    function test_updateIssuerClaimTopics_Success() public {
        uint256[] memory initial = registry.getTrustedIssuerClaimTopics(address(claimIssuer));
        assertGt(initial.length, 0);

        uint256[] memory newTopics = new uint256[](2);
        newTopics[0] = CLAIM_TOPIC_3;
        newTopics[1] = CLAIM_TOPIC_4;

        vm.prank(deployer);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ERC3643EventsLib.ClaimTopicsUpdated(address(claimIssuer), newTopics);
        registry.updateIssuerClaimTopics(address(claimIssuer), newTopics);

        assertTrue(registry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_3));
        assertTrue(registry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_4));
        assertFalse(registry.hasClaimTopic(address(claimIssuer), initial[0]));

        uint256[] memory after_ = registry.getTrustedIssuerClaimTopics(address(claimIssuer));
        assertEq(after_.length, 2);
        assertEq(after_[0], CLAIM_TOPIC_3);
        assertEq(after_[1], CLAIM_TOPIC_4);
    }

    function test_updateIssuerClaimTopics_CoversInnerLoopIncrement() public {
        address firstIssuer = makeAddr("firstIssuer");
        address secondIssuer = makeAddr("secondIssuer");

        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;

        vm.startPrank(deployer);
        registry.addTrustedIssuer(address(firstIssuer), topics);
        registry.addTrustedIssuer(address(secondIssuer), topics);
        vm.stopPrank();

        uint256[] memory newTopics = new uint256[](1);
        newTopics[0] = CLAIM_TOPIC_2;

        vm.prank(deployer);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ERC3643EventsLib.ClaimTopicsUpdated(address(secondIssuer), newTopics);
        registry.updateIssuerClaimTopics(address(secondIssuer), newTopics);

        assertFalse(registry.hasClaimTopic(address(secondIssuer), CLAIM_TOPIC_1));
        assertTrue(registry.hasClaimTopic(address(secondIssuer), CLAIM_TOPIC_2));
    }

    // ============ getTrustedIssuerClaimTopics() ============

    function test_getTrustedIssuerClaimTopics_RevertWhen_NotRegistered() public {
        address newIssuer = makeAddr("newIssuer");
        vm.expectRevert(ErrorsLib.TrustedIssuerDoesNotExist.selector);
        registry.getTrustedIssuerClaimTopics(address(newIssuer));
    }

    function test_getTrustedIssuerClaimTopics_Success_ReturnsSetTopics() public view {
        uint256[] memory topics = registry.getTrustedIssuerClaimTopics(address(claimIssuer));
        assertEq(topics.length, 1);
        assertEq(topics[0], CLAIM_TOPIC_1);
    }

    // ============ getTrustedIssuersForClaimTopic() ============

    function test_getTrustedIssuersForClaimTopic_ReturnsTrustedIssuers() public view {
        address[] memory issuers = registry.getTrustedIssuersForClaimTopic(CLAIM_TOPIC_1);
        assertEq(issuers.length, 1);
        assertEq(address(issuers[0]), address(claimIssuer));
    }

    function test_getTrustedIssuersForClaimTopic_ReturnsEmptyForUnknownTopic() public view {
        address[] memory issuers = registry.getTrustedIssuersForClaimTopic(CLAIM_TOPIC_4);
        assertEq(issuers.length, 0);
    }

    // ============ hasClaimTopic() ============

    function test_hasClaimTopic_ReturnsFalseForUnknownIssuer() public view {
        assertFalse(registry.hasClaimTopic(another, CLAIM_TOPIC_1));
    }

}
