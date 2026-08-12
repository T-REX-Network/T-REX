// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

contract TREXRegistryClaimTopicsUnitTest is TREXRegistryBaseUnitTest {

    // ============ addClaimTopic() ============

    function test_addClaimTopic_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.addClaimTopic(1);
    }

    function test_addClaimTopic_Success_EmitsEvent() public {
        vm.prank(deployer);
        vm.expectEmit(true, false, false, false, address(registry));
        emit ERC3643EventsLib.ClaimTopicAdded(1);
        registry.addClaimTopic(1);

        uint256[] memory topics = registry.getClaimTopics();
        assertEq(topics.length, 1);
        assertEq(topics[0], 1);
    }

    function test_addClaimTopic_RevertWhen_MoreThan14Topics() public {
        // Add 14 topics first (0-13)
        for (uint256 i = 0; i < 14; i++) {
            vm.prank(deployer);
            registry.addClaimTopic(i);
        }

        // Add 15th topic (index 14), should succeed (length 14 < 15)
        vm.prank(deployer);
        registry.addClaimTopic(14);

        // 16th topic must revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        registry.addClaimTopic(15);
    }

    function test_addClaimTopic_RevertWhen_TopicAlreadyExists() public {
        vm.prank(deployer);
        registry.addClaimTopic(1);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicAlreadyExists.selector);
        registry.addClaimTopic(1);
    }

    // ============ removeClaimTopic() ============

    function test_removeClaimTopic_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.removeClaimTopic(1);
    }

    function test_removeClaimTopic_Success() public {
        vm.startPrank(deployer);
        registry.addClaimTopic(1);
        registry.addClaimTopic(2);
        registry.addClaimTopic(3);
        vm.stopPrank();

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false, address(registry));
        emit ERC3643EventsLib.ClaimTopicRemoved(2);
        registry.removeClaimTopic(2);

        uint256[] memory topics = registry.getClaimTopics();
        assertEq(topics.length, 2);
    }

    function test_removeClaimTopic_NoOpWhenAbsent() public {
        // Removing a topic that does not exist must NOT revert and must NOT emit (port verbatim).
        vm.prank(deployer);
        registry.removeClaimTopic(42);
        assertEq(registry.getClaimTopics().length, 0);
    }

    // ============ getClaimTopics() ============

    function test_getClaimTopics_ReturnsEmptyByDefault() public view {
        assertEq(registry.getClaimTopics().length, 0);
    }

}
