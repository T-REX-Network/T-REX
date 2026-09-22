// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { TREXRegistryBaseUnitTest } from "../trex-registry/helpers/TREXRegistryBaseUnitTest.t.sol";

import { Utils } from "../helpers/Utils.sol";

/// @dev Reads TREXRegistry's real storage: `checksDisabled` must sit at byte 0 of the T-REX domain,
///  and the pre-split domain must hold nothing. Reusing the old domain would have left the low
///  byte of the old storage address deciding whether checks run. Why it matters: docs/erc3643-oz-swap.md.
contract RegistryStorageLayoutTest is TREXRegistryBaseUnitTest {

    function test_storageLayout_ChecksDisabledAtByteZero() public {
        bytes32 slot = Utils.erc7201("erc3643.storage.TREXEligibility");

        assertEq(uint8(uint256(vm.load(address(registry), slot)) & 0xff), 0, "starts enabled");

        vm.prank(deployer);
        registry.disableEligibilityChecks();

        assertEq(uint8(uint256(vm.load(address(registry), slot)) & 0xff), 1, "reads back as disabled");
        assertTrue(registry.isVerified(makeAddr("anyone")), "disabled means everyone verifies");
    }

    function test_storageLayout_OldDomainUnused() public view {
        bytes32 oldSlot = Utils.erc7201("erc3643.storage.TREXRegistry");

        assertEq(vm.load(address(registry), oldSlot), bytes32(0), "old domain must stay empty");
    }

}
