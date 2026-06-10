// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TokenAgentRestrictionsTest is TREXSuiteTest {

    // ============ setAgentRestrictions() Tests ============

    /// @notice Should revert when called by not owner
    function test_setAgentRestrictions_RevertWhen_NotOwner() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: true,
            disablePartialFreeze: true,
            disableAddressFreeze: true,
            disableRecovery: true,
            disableForceTransfer: true,
            disablePause: true
        });

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        token.setAgentRestrictions(agent, restrictions);
    }

    /// @notice Should revert when the given address is not an agent
    function test_setAgentRestrictions_RevertWhen_AddressNotAgent() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: true,
            disablePartialFreeze: true,
            disableAddressFreeze: true,
            disableRecovery: true,
            disableForceTransfer: true,
            disablePause: true
        });

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AddressNotAgent.selector, another));
        token.setAgentRestrictions(another, restrictions);
    }

    /// @notice Should set restrictions when the given address is an agent
    function test_setAgentRestrictions_Success() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: true,
            disablePartialFreeze: true,
            disableAddressFreeze: true,
            disableRecovery: true,
            disableForceTransfer: true,
            disablePause: true
        });

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit EventsLib.AgentRestrictionsSet(agent, true, true, true, true, true, true, true);
        token.setAgentRestrictions(agent, restrictions); // agent already added in the setup above
    }

    // ============ getAgentRestrictions() Tests ============

    /// @notice Should return restrictions after they are set
    function test_getAgentRestrictions_ReturnsRestrictions() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: true,
            disablePartialFreeze: true,
            disableAddressFreeze: true,
            disableRecovery: true,
            disableForceTransfer: true,
            disablePause: true
        });

        // Set restrictions
        vm.prank(deployer);
        token.setAgentRestrictions(agent, restrictions);

        // Get restrictions
        TokenRoles memory retrieved = token.getAgentRestrictions(agent);

        // Verify all restrictions are set correctly
        assertTrue(retrieved.disableAddressFreeze, "disableAddressFreeze should be true");
        assertTrue(retrieved.disableBurn, "disableBurn should be true");
        assertTrue(retrieved.disableForceTransfer, "disableForceTransfer should be true");
        assertTrue(retrieved.disableMint, "disableMint should be true");
        assertTrue(retrieved.disablePartialFreeze, "disablePartialFreeze should be true");
        assertTrue(retrieved.disablePause, "disablePause should be true");
        assertTrue(retrieved.disableRecovery, "disableRecovery should be true");
    }

}
