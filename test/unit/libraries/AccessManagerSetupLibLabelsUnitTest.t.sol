// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test, Vm } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

/// @title setupLabels coverage
/// @notice `AccessManagerSetupLib.setupLabels` only attaches human-readable labels to roles (off-chain display)
///         and is never asserted by the suite tests. This exercises it so the library's coverage is complete and
///         the label wiring is sanity-checked. The test contract is the manager admin, so `labelRole`
///         (admin-gated) is callable directly.
contract AccessManagerSetupLibLabelsUnitTest is Test {

    function test_setupLabels_LabelsEveryRole() public {
        AccessManager accessManager = new AccessManager(address(this));

        // The first label set is the OWNER role.
        vm.expectEmit(true, false, false, true, address(accessManager));
        emit IAccessManager.RoleLabel(RolesLib.OWNER, "TREX-Suite Owner");
        AccessManagerSetupLib.setupLabels(accessManager);
    }

    function test_setupLabels_LabelsTheComplianceManager() public {
        AccessManager accessManager = new AccessManager(address(this));

        vm.recordLogs();
        AccessManagerSetupLib.setupLabels(accessManager);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IAccessManager.RoleLabel.selector) continue;
            if (uint256(logs[i].topics[1]) == RolesLib.COMPLIANCE_MANAGER) {
                assertEq(abi.decode(logs[i].data, (string)), "TREX-Suite Manager: Compliance");
                found = true;
            }
        }
        assertTrue(found, "COMPLIANCE_MANAGER is labelled");
    }

}
