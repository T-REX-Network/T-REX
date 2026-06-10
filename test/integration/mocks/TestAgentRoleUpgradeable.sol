// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AgentRoleUpgradeable } from "contracts/roles/AgentRoleUpgradeable.sol";

/// @notice Test contract that inherits from AgentRoleUpgradeable to test the onlyAgent modifier
contract TestAgentRoleUpgradeable is AgentRoleUpgradeable {

    function initialize() external initializer {
        __Ownable_init(msg.sender);
    }

    function callOnlyAgent() external onlyAgent {
        // Empty function to test the onlyAgent modifier
    }

}
