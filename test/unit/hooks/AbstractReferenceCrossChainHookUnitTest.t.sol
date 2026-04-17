// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { AbstractReferenceCrossChainHook } from "contracts/hooks/AbstractReferenceCrossChainHook.sol";
import { IReferenceCrossChainHook } from "contracts/hooks/IReferenceCrossChainHook.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

contract HookSpy is AbstractReferenceCrossChainHook {

    struct Call {
        uint64 dstChainId;
        bytes32 hash;
        uint64 expiry;
        address from;
        address to;
        uint256 value;
    }
    Call[] public calls;
    bytes32 public lastSettled;

    constructor(address accessManager_, address token_) AbstractReferenceCrossChainHook(accessManager_, token_) { }

    function _sendAuthorization(uint64 dstChainId, bytes32 hash, uint64 expiry, address from, address to, uint256 value)
        internal
        override
    {
        calls.push(Call(dstChainId, hash, expiry, from, to, value));
    }

    function simulateSettlement(bytes32 hash) external {
        lastSettled = hash;
        _onSettlement(hash);
    }

    function callsLength() external view returns (uint256) {
        return calls.length;
    }

}

contract TokenSpy {

    bytes32 public lastSettled;

    function onTransferSettled(bytes32 hash) external {
        lastSettled = hash;
    }

}

contract AbstractReferenceCrossChainHookUnitTest is Test {

    AccessManager internal accessManager;
    HookSpy internal hook;
    TokenSpy internal tokenSpy;

    address internal admin = makeAddr("admin");
    address internal tokenCaller = makeAddr("tokenCaller");

    function setUp() public {
        accessManager = new AccessManager(admin);
        tokenSpy = new TokenSpy();
        hook = new HookSpy(address(accessManager), address(tokenSpy));

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IReferenceCrossChainHook.sendAuthorization.selector;
        accessManager.setTargetFunctionRole(address(hook), selectors, RolesLib.TOKEN);
        accessManager.grantRole(RolesLib.TOKEN, tokenCaller, 0);
        vm.stopPrank();
    }

    function test_sendAuthorization_callsTemplate() public {
        vm.prank(tokenCaller);
        hook.sendAuthorization(
            11_155_111, bytes32(uint256(1)), uint64(block.timestamp + 1), address(0x1), address(0x2), 100
        );

        assertEq(hook.callsLength(), 1);
        (uint64 dst, bytes32 h, uint64 exp, address from, address to, uint256 value) = hook.calls(0);
        assertEq(dst, 11_155_111);
        assertEq(h, bytes32(uint256(1)));
        assertEq(from, address(0x1));
        assertEq(to, address(0x2));
        assertEq(value, 100);
        assertGt(exp, 0);
    }

    function test_sendAuthorization_revertsWithoutTokenRole() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        hook.sendAuthorization(1, bytes32(0), 0, address(0), address(0), 0);
    }

    function test_onSettlement_dispatchesToToken() public {
        bytes32 h = bytes32(uint256(0xdead));
        hook.simulateSettlement(h);
        assertEq(tokenSpy.lastSettled(), h);
    }

    function test_token_returnsAddress() public view {
        assertEq(hook.token(), address(tokenSpy));
    }

}
