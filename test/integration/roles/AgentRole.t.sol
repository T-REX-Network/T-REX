// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TestAgentRole } from "../mocks/TestAgentRole.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract AgentRoleTest is TREXSuiteTest {

    TestAgentRole public agentRole;

    address public owner = makeAddr("owner");

    /// @notice Sets up AgentRole contract
    function setUp() public override {
        super.setUp();

        // Deploy TestAgentRole - owner will be the test contract (msg.sender)
        agentRole = new TestAgentRole();
        // Transfer ownership to owner address for consistency with Hardhat tests
        agentRole.transferOwnership(owner);
    }

    // ============ addAgent() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_addAgent_RevertWhen_NotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        agentRole.addAgent(alice);
    }

    /// @notice Should revert when address to add is zero address
    function test_addAgent_RevertWhen_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        agentRole.addAgent(address(0));
    }

    /// @notice Should revert when address to add is already an agent
    function test_addAgent_RevertWhen_AlreadyAgent() public {
        vm.prank(owner);
        agentRole.addAgent(alice);

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AccountAlreadyHasRole.selector);
        agentRole.addAgent(alice);
    }

    /// @notice Should add the agent successfully
    function test_addAgent_Success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit EventsLib.AgentAdded(alice);
        agentRole.addAgent(alice);

        assertTrue(agentRole.isAgent(alice), "Alice should be an agent");
    }

    // ============ removeAgent() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_removeAgent_RevertWhen_NotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        agentRole.removeAgent(alice);
    }

    /// @notice Should revert when address to remove is zero address
    function test_removeAgent_RevertWhen_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        agentRole.removeAgent(address(0));
    }

    /// @notice Should revert when address to remove is not an agent
    function test_removeAgent_RevertWhen_NotAgent() public {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AccountDoesNotHaveRole.selector);
        agentRole.removeAgent(alice);
    }

    /// @notice Should remove the agent successfully
    function test_removeAgent_Success() public {
        // First add the agent
        vm.prank(owner);
        agentRole.addAgent(alice);

        // Then remove it
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit EventsLib.AgentRemoved(alice);
        agentRole.removeAgent(alice);

        assertFalse(agentRole.isAgent(alice), "Alice should not be an agent");
    }

    // ============ onlyAgent Modifier Tests ============

    /// @notice Should revert when onlyAgent modifier is called by non-agent
    function test_onlyAgent_RevertWhen_NotAgent() public {
        vm.prank(bob);
        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        agentRole.callOnlyAgent();
    }

    /// @notice Should succeed when onlyAgent modifier is called by agent
    function test_onlyAgent_Success() public {
        // Add bob as an agent
        vm.prank(owner);
        agentRole.addAgent(bob);

        // Call should succeed
        vm.prank(bob);
        agentRole.callOnlyAgent();
    }

}
