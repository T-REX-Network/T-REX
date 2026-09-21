// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

/// @dev A batch is authorized by its single-item counterpart, but it must still consume a scheduled
///  operation of its own. An AGENT granted with an execution delay would otherwise have no way to call
///  `batchRegisterIdentity` at all.
contract TREXRegistryScheduledBatchUnitTest is TREXRegistryBaseUnitTest {

    function test_batchRegisterIdentity_Success_WhenScheduledByDelayedAgent() public {
        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, address(registry), RolesLib.SHARED);

        address delayed = makeAddr("delayedAgent");
        accessManager.grantRole(RolesLib.role(RolesLib.SHARED, RolesLib.AGENT), delayed, 1 days);

        IIdentity id = _deployIdentity(another, "another");
        address[] memory addrs = new address[](1);
        addrs[0] = another;
        IIdentity[] memory ids = new IIdentity[](1);
        ids[0] = id;
        uint16[] memory countries = new uint16[](1);
        countries[0] = 1;

        bytes memory data = abi.encodeWithSelector(registry.batchRegisterIdentity.selector, addrs, ids, countries);

        vm.prank(delayed);
        accessManager.schedule(address(registry), data, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(delayed);
        (bool ok,) = address(registry).call(data);

        assertTrue(ok, "scheduled batchRegisterIdentity must execute");
        assertTrue(registry.contains(another));
    }

}
