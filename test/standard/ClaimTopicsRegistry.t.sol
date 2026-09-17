// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/IERC3643ClaimTopicsRegistry.sol";

import { ClaimTopicsRegistryMock } from "./mocks/Mocks.sol";

/// @dev ERC-3643 standard: Claim Topics Registry.
///
///  Runs against the standard base alone (issue #65). Every assertion here is a statement about what the
///  ERC-3643 specification requires, never about how T-REX chooses to extend it, so this file must pass
///  unchanged when OpenZeppelin's base replaces ours.
contract ClaimTopicsRegistryBaseTest is Test {

    ClaimTopicsRegistryMock internal registry;

    function setUp() public {
        registry = new ClaimTopicsRegistryMock();
    }

    function test_getClaimTopics_IsEmptyInitially() public view {
        assertEq(registry.getClaimTopics().length, 0);
    }

    function test_addClaimTopic_StoresTheTopic() public {
        registry.addClaimTopic(1);

        uint256[] memory topics = registry.getClaimTopics();
        assertEq(topics.length, 1);
        assertEq(topics[0], 1);
    }

    function test_addClaimTopic_EmitsClaimTopicAdded() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643ClaimTopicsRegistry.ClaimTopicAdded(7);

        registry.addClaimTopic(7);
    }

    function test_addClaimTopic_RevertWhen_Duplicate() public {
        registry.addClaimTopic(1);

        vm.expectRevert(ERC3643ErrorsLib.ClaimTopicAlreadyExists.selector);
        registry.addClaimTopic(1);
    }

    function test_removeClaimTopic_DropsTheTopic() public {
        registry.addClaimTopic(1);
        registry.addClaimTopic(2);

        registry.removeClaimTopic(1);

        uint256[] memory topics = registry.getClaimTopics();
        assertEq(topics.length, 1);
        assertEq(topics[0], 2);
    }

    function test_removeClaimTopic_EmitsClaimTopicRemoved() public {
        registry.addClaimTopic(3);

        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643ClaimTopicsRegistry.ClaimTopicRemoved(3);

        registry.removeClaimTopic(3);
    }

    function test_removeClaimTopic_IsNoOpWhenAbsent() public {
        registry.removeClaimTopic(42);
        assertEq(registry.getClaimTopics().length, 0);
    }

    /// @dev The standard sets no cap; a deployment that wants one overrides `_maxClaimTopics`.
    ///  T-REX's own cap is covered in test/unit/trex-registry.
    function test_addClaimTopic_Success_PastFifteenTopics() public {
        for (uint256 i = 0; i < 20; i++) {
            registry.addClaimTopic(i);
        }

        assertEq(registry.getClaimTopics().length, 20);
    }

}
