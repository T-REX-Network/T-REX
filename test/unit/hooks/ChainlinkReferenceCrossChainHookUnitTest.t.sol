// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { ChainlinkReferenceCrossChainHook } from "contracts/hooks/ChainlinkReferenceCrossChainHook.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

contract TokenStub {

    bytes32 public lastSettled;

    function onTransferSettled(bytes32 hash) external {
        lastSettled = hash;
    }

}

contract ChainlinkReferenceCrossChainHookUnitTest is Test {

    AccessManager internal accessManager;
    ChainlinkReferenceCrossChainHook internal hook;
    TokenStub internal tokenStub;

    address internal admin = makeAddr("admin");
    address internal hookAdmin = makeAddr("hookAdmin");
    address internal tokenCaller = makeAddr("tokenCaller");

    address internal router = makeAddr("router");
    address internal link = makeAddr("link");

    uint64 internal constant DST = 11_155_111;
    bytes32 internal constant PEER_HOOK = bytes32(uint256(uint160(0xBEEF)));

    function setUp() public {
        accessManager = new AccessManager(admin);
        tokenStub = new TokenStub();

        // CCIPReceiver constructor calls router.getRouter via no-op — actually it just stores router address.
        // But the receiver also tries to call router methods sometimes. Mock common methods up front.
        vm.mockCall(router, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(uint256(123)));
        vm.mockCall(
            router, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(bytes32(uint256(0xCAFE)))
        );
        vm.mockCall(link, abi.encodeWithSelector(LinkTokenInterface.approve.selector), abi.encode(true));

        hook = new ChainlinkReferenceCrossChainHook(router, link, address(accessManager), address(tokenStub));

        vm.startPrank(admin);
        bytes4[] memory hookAdminSelectors = new bytes4[](2);
        hookAdminSelectors[0] = ChainlinkReferenceCrossChainHook.configureBridgedHook.selector;
        hookAdminSelectors[1] = ChainlinkReferenceCrossChainHook.setGasLimit.selector;
        accessManager.setTargetFunctionRole(address(hook), hookAdminSelectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookAdmin, 0);

        bytes4[] memory tokenSelectors = new bytes4[](1);
        tokenSelectors[0] = bytes4(keccak256("sendAuthorization(uint64,bytes32,uint64,address,address,uint256)"));
        accessManager.setTargetFunctionRole(address(hook), tokenSelectors, RolesLib.TOKEN);
        accessManager.grantRole(RolesLib.TOKEN, tokenCaller, 0);
        vm.stopPrank();

        vm.prank(hookAdmin);
        hook.configureBridgedHook(DST, PEER_HOOK);
    }

    function test_sendAuthorization_revertsWhenDstNotConfigured() public {
        vm.prank(tokenCaller);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DestinationChainNotConfigured.selector, uint64(80_002)));
        hook.sendAuthorization(80_002, bytes32(0), uint64(block.timestamp + 1), address(0x1), address(0x2), 100);
    }

    function test_sendAuthorization_callsCcipSend() public {
        bytes32 h = bytes32(uint256(0xABCD));
        uint64 expiry = uint64(block.timestamp + 5 minutes);

        vm.expectCall(router, abi.encodeWithSelector(IRouterClient.ccipSend.selector));

        vm.prank(tokenCaller);
        hook.sendAuthorization(DST, h, expiry, address(0x1), address(0x2), 100);
    }

    function test_ccipReceive_dispatchesSettlementToToken() public {
        bytes32 h = bytes32(uint256(0x1234));
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(0),
            sourceChainSelector: DST,
            sender: abi.encode(PEER_HOOK),
            data: abi.encode(h),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(router);
        hook.ccipReceive(msg_);

        assertEq(tokenStub.lastSettled(), h);
    }

    function test_ccipReceive_revertsOnUnknownPeer() public {
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(0),
            sourceChainSelector: DST,
            sender: abi.encode(bytes32(uint256(0xBAD))),
            data: abi.encode(bytes32(uint256(0x1234))),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(router);
        vm.expectRevert(ErrorsLib.UnauthorizedHookCaller.selector);
        hook.ccipReceive(msg_);
    }

    function test_configureBridgedHook_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit EventsLib.BridgedHookConfigured(80_002, bytes32(uint256(0x1)));

        vm.prank(hookAdmin);
        hook.configureBridgedHook(80_002, bytes32(uint256(0x1)));
    }

}
