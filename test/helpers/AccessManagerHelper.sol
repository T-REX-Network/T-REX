// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { RolesLib } from "contracts/libraries/RolesLib.sol";

contract AccessManagerHelper is Test {

    uint32 public constant NO_DELAY = 0;

    AccessManager public accessManager;

    address public accessManagerAdmin = makeAddr("accessManagerAdmin");

    constructor() {
        accessManager = new AccessManager(accessManagerAdmin);
    }

    function _setRoles(address owner, address agent) internal {
        vm.startPrank(accessManagerAdmin);

        accessManager.grantRole(RolesLib.OWNER, owner, NO_DELAY);

        accessManager.grantRole(RolesLib.AGENT, agent, NO_DELAY);
        accessManager.grantRole(RolesLib.AGENT_MINTER, agent, NO_DELAY);
        accessManager.grantRole(RolesLib.AGENT_BURNER, agent, NO_DELAY);
        accessManager.grantRole(RolesLib.AGENT_PARTIAL_FREEZER, agent, NO_DELAY);
        accessManager.grantRole(RolesLib.AGENT_ADDRESS_FREEZER, agent, NO_DELAY);
        accessManager.grantRole(RolesLib.AGENT_RECOVERY_ADDRESS, agent, NO_DELAY);
        accessManager.grantRole(RolesLib.AGENT_FORCED_TRANSFER, agent, NO_DELAY);
        accessManager.grantRole(RolesLib.AGENT_PAUSER, agent, NO_DELAY);

        accessManager.grantRole(RolesLib.TOKEN_ADMIN, owner, NO_DELAY);
        accessManager.grantRole(RolesLib.IDENTITY_ADMIN, owner, NO_DELAY);
        accessManager.grantRole(RolesLib.INFRA_ADMIN, owner, NO_DELAY);
        accessManager.grantRole(RolesLib.SPENDING_ADMIN, owner, NO_DELAY);

        vm.stopPrank();
    }

}
