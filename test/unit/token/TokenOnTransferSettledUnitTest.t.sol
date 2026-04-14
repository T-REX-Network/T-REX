// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";
import { CrossChainHookMock } from "../mocks/CrossChainHookMock.sol";

contract TokenOnTransferSettledUnitTest is TokenBaseUnitTest {

    CrossChainHookMock internal hookMock;
    address internal hookManager = makeAddr("HookManager");
    address internal hookCaller = makeAddr("HookCaller");
    address internal alice = makeAddr("Alice");
    address internal bob = makeAddr("Bob");

    uint64 internal constant DST_CHAIN_ID = 11_155_111;

    function setUp() public override {
        super.setUp();

        hookMock = new CrossChainHookMock();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("setHook(address)"));
        accessManager.setTargetFunctionRole(address(token), selectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookManager, 0);

        bytes4[] memory settledSelectors = new bytes4[](1);
        settledSelectors[0] = bytes4(keccak256("onTransferSettled(bytes32)"));
        accessManager.setTargetFunctionRole(address(token), settledSelectors, RolesLib.HOOK);
        accessManager.grantRole(RolesLib.HOOK, hookCaller, 0);

        vm.prank(hookManager);
        token.setHook(address(hookMock));

        vm.prank(agent);
        token.unpause();
    }

    function test_onTransferSettled_clearsPendingAndEmits() public {
        bytes32 h = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        assertTrue(token.isPending(h));

        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.TransferSettled(h);

        vm.prank(hookCaller);
        token.onTransferSettled(h);

        assertFalse(token.isPending(h));
    }

    function test_onTransferSettled_isIdempotent() public {
        bytes32 h = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);

        vm.prank(hookCaller);
        token.onTransferSettled(h);

        // Second call: no revert, no event.
        vm.prank(hookCaller);
        token.onTransferSettled(h);

        assertFalse(token.isPending(h));
    }

    function test_onTransferSettled_revertsWithoutHookRole() public {
        bytes32 h = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);

        address stranger = makeAddr("Stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        token.onTransferSettled(h);
    }

}
