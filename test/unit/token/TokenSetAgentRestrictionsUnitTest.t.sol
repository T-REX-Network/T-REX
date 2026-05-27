// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenSetAgentRestrictionsUnitTest is TokenBaseUnitTest {

    address anotherAgent = makeAddr("AnotherAgent");
    address nonAgent = makeAddr("NonAgent");

    function setUp() public override {
        super.setUp();

        // Add another agent for testing
        token.addAgent(anotherAgent);
    }

    function testSetAgentRestrictionsRevertsWhenNotOwner(address caller) public {
        vm.assume(caller != token.owner());

        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        token.setAgentRestrictions(agent, restrictions);
    }

    function testSetAgentRestrictionsRevertsWhenAddressNotAgent() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AddressNotAgent.selector, nonAgent));
        token.setAgentRestrictions(nonAgent, restrictions);
    }

    function testSetAgentRestrictionsNominal() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: true,
            disablePartialFreeze: true,
            disableAddressFreeze: true,
            disableRecovery: true,
            disableForceTransfer: true,
            disablePause: true
        });

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.AgentRestrictionsSet(agent, true, true, true, true, true, true, true);

        token.setAgentRestrictions(agent, restrictions);

        TokenRoles memory retrieved = token.getAgentRestrictions(agent);
        assertTrue(retrieved.disableMint);
        assertTrue(retrieved.disableBurn);
        assertTrue(retrieved.disablePartialFreeze);
        assertTrue(retrieved.disableAddressFreeze);
        assertTrue(retrieved.disableRecovery);
        assertTrue(retrieved.disableForceTransfer);
        assertTrue(retrieved.disablePause);
    }

    function testSetAgentRestrictionsWithPartialRestrictions() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: false,
            disablePartialFreeze: true,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: true,
            disablePause: false
        });

        token.setAgentRestrictions(agent, restrictions);

        TokenRoles memory retrieved = token.getAgentRestrictions(agent);
        assertTrue(retrieved.disableMint);
        assertFalse(retrieved.disableBurn);
        assertTrue(retrieved.disablePartialFreeze);
        assertFalse(retrieved.disableAddressFreeze);
        assertFalse(retrieved.disableRecovery);
        assertTrue(retrieved.disableForceTransfer);
        assertFalse(retrieved.disablePause);
    }

    function testSetAgentRestrictionsCanUpdateExistingRestrictions() public {
        // Set initial restrictions
        TokenRoles memory initialRestrictions = TokenRoles({
            disableMint: true,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        token.setAgentRestrictions(agent, initialRestrictions);

        // Update restrictions
        TokenRoles memory updatedRestrictions = TokenRoles({
            disableMint: false,
            disableBurn: true,
            disablePartialFreeze: true,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        token.setAgentRestrictions(agent, updatedRestrictions);

        TokenRoles memory retrieved = token.getAgentRestrictions(agent);
        assertFalse(retrieved.disableMint);
        assertTrue(retrieved.disableBurn);
        assertTrue(retrieved.disablePartialFreeze);
        assertFalse(retrieved.disableAddressFreeze);
        assertFalse(retrieved.disableRecovery);
        assertFalse(retrieved.disableForceTransfer);
        assertFalse(retrieved.disablePause);
    }

    function testSetAgentRestrictionsForMultipleAgents() public {
        TokenRoles memory restrictions1 = TokenRoles({
            disableMint: true,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        TokenRoles memory restrictions2 = TokenRoles({
            disableMint: false,
            disableBurn: true,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        token.setAgentRestrictions(agent, restrictions1);
        token.setAgentRestrictions(anotherAgent, restrictions2);

        TokenRoles memory retrieved1 = token.getAgentRestrictions(agent);
        TokenRoles memory retrieved2 = token.getAgentRestrictions(anotherAgent);

        assertTrue(retrieved1.disableMint);
        assertFalse(retrieved1.disableBurn);
        assertFalse(retrieved2.disableMint);
        assertTrue(retrieved2.disableBurn);
    }

    function testGetAgentRestrictionsReturnsDefaultValuesForNewAgent() public {
        address newAgent = makeAddr("NewAgent");
        token.addAgent(newAgent);

        TokenRoles memory retrieved = token.getAgentRestrictions(newAgent);
        assertFalse(retrieved.disableMint);
        assertFalse(retrieved.disableBurn);
        assertFalse(retrieved.disablePartialFreeze);
        assertFalse(retrieved.disableAddressFreeze);
        assertFalse(retrieved.disableRecovery);
        assertFalse(retrieved.disableForceTransfer);
        assertFalse(retrieved.disablePause);
    }

    function testGetAgentRestrictionsReturnsZeroForNonAgent() public view {
        TokenRoles memory retrieved = token.getAgentRestrictions(nonAgent);
        assertFalse(retrieved.disableMint);
        assertFalse(retrieved.disableBurn);
        assertFalse(retrieved.disablePartialFreeze);
        assertFalse(retrieved.disableAddressFreeze);
        assertFalse(retrieved.disableRecovery);
        assertFalse(retrieved.disableForceTransfer);
        assertFalse(retrieved.disablePause);
    }

}
