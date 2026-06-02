// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { AccessManagerHelper } from "../../helpers/AccessManagerHelper.sol";

/// @title setupLabels coverage
/// @notice `AccessManagerSetupLib.setupLabels` only attaches human-readable labels to roles (off-chain display)
///         and is never hit by the suite tests. This exercises it so the library's coverage is complete and the
///         label wiring is sanity-checked.
contract AccessManagerSetupLibLabelsUnitTest is AccessManagerHelper {

    function test_setupLabels_LabelsEveryRole() public {
        // The first label set is the OWNER role; labelRole is admin-gated, so prank the AccessManager admin.
        vm.startPrank(accessManagerAdmin);
        vm.expectEmit(true, false, false, true, address(accessManager));
        emit IAccessManager.RoleLabel(RolesLib.OWNER, "TREX-Suite Owner");
        AccessManagerSetupLib.setupLabels(accessManager);
        vm.stopPrank();
    }

}
