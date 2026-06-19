// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
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

}
