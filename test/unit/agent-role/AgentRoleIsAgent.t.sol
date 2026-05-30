// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManaged, IAccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { AgentRole } from "contracts/roles/AgentRole.sol";

contract AgentRoleMock is AgentRole, AccessManaged {

    constructor(address authority) AccessManaged(authority) { }

}

contract AgentRoleIsAgent is Test {

    AccessManager accessManager;
    AgentRole agentRole;

    address user1 = makeAddr("User1");

    constructor() {
        accessManager = new AccessManager(address(this));
        AccessManagerSetupLib.setupAgentManagerRole(accessManager);
        accessManager.grantRole(RolesLib.AGENT_MANAGER, address(this), 0);
        agentRole = new AgentRoleMock(address(accessManager));
    }

    function testWhenAddressIsAgent() public {
        accessManager.grantRole(RolesLib.AGENT, user1, 0);

        assertTrue(agentRole.isAgent(user1));
    }

    function testWhenAddressIsNotAgent() public view {
        assertFalse(agentRole.isAgent(user1));
    }

}
