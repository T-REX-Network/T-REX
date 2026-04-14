// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenSetHookUnitTest is TokenBaseUnitTest {

    address internal hookManager = makeAddr("HookManager");
    address internal newHook = makeAddr("Hook");

    function setUp() public override {
        super.setUp();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("setHook(address)"));
        accessManager.setTargetFunctionRole(address(token), selectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookManager, 0);
    }

    function test_setHook_storesAddressAndEmits() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.HookSet(newHook);

        vm.prank(hookManager);
        token.setHook(newHook);

        assertEq(token.hook(), newHook);
    }

    function test_setHook_revertsOnZeroAddress() public {
        vm.prank(hookManager);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        token.setHook(address(0));
    }

    function test_setHook_revertsWithoutHookManagerRole() public {
        address stranger = makeAddr("Stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        token.setHook(newHook);
    }

}
