// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AgentRole } from "contracts/roles/AgentRole.sol";

/// @notice Test contract that inherits from AgentRole to test the onlyAgent modifier
contract TestAgentRole is AgentRole {

    function callOnlyAgent() external onlyAgent {
        // Empty function to test the onlyAgent modifier
    }

}
