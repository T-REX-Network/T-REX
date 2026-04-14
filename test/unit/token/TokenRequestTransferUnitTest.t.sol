// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { HashLib } from "contracts/libraries/HashLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { TokenProxy } from "contracts/proxy/TokenProxy.sol";
import { Token } from "contracts/token/Token.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";
import { CrossChainHookMock } from "../mocks/CrossChainHookMock.sol";

contract TokenRequestTransferUnitTest is TokenBaseUnitTest {

    CrossChainHookMock internal hookMock;

    address internal hookManager = makeAddr("HookManager");
    address internal alice = makeAddr("Alice");
    address internal bob = makeAddr("Bob");

    uint64 internal constant DST_CHAIN_ID = 11_155_111;

    function setUp() public override {
        super.setUp();

        hookMock = new CrossChainHookMock();

        // Wire the HOOK_MANAGER role so we can call setHook.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("setHook(address)"));
        accessManager.setTargetFunctionRole(address(token), selectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookManager, 0);

        vm.prank(hookManager);
        token.setHook(address(hookMock));

        vm.prank(agent);
        token.unpause();
    }

    function test_requestTransfer_succeedsAndAllocatesNonce() public {
        uint64 expiry = uint64(block.timestamp + 5 minutes);
        bytes32 expectedHash = HashLib.hash(DST_CHAIN_ID, alice, bob, 100, 0, expiry);

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.TransferRequested(expectedHash, DST_CHAIN_ID, alice, bob, 100, 0, expiry);

        bytes32 returned = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);

        assertEq(returned, expectedHash);
        assertTrue(token.isPending(expectedHash));
        assertEq(token.nextNonce(alice), 1);

        assertEq(hookMock.sentCount(), 1);
        CrossChainHookMock.Sent memory s = hookMock.lastSent();
        assertEq(s.dstChainId, DST_CHAIN_ID);
        assertEq(s.hash, expectedHash);
        assertEq(s.expiry, expiry);
        assertEq(s.from, alice);
        assertEq(s.to, bob);
        assertEq(s.value, 100);
    }

    function test_requestTransfer_callableByAnyone() public {
        address stranger = makeAddr("Stranger");
        vm.prank(stranger);
        bytes32 hash = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        assertTrue(token.isPending(hash));
    }

    function test_requestTransfer_incrementsNonceAcrossCalls() public {
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        assertEq(token.nextNonce(alice), 2);
        assertEq(hookMock.sentCount(), 2);
    }

    function test_requestTransfer_revertsWhenPaused() public {
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenFromFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, alice));
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenToFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(bob, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, bob));
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenToNotVerified() public {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector, bob),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.TransferNotPossible.selector);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenComplianceRejects() public {
        vm.mockCall(
            compliance,
            abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector, alice, bob, 100),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.TransferNotPossible.selector);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenHookNotSet() public {
        // Build an isolated token with no hook configured.
        TokenProxy freshProxy = new TokenProxy(
            implementationAuthority,
            identityRegistry,
            compliance,
            "Fresh",
            "FRSH",
            18,
            address(onchainId),
            address(accessManager)
        );
        Token fresh = Token(address(freshProxy));

        AccessManagerSetupLib.setupTokenRoles(accessManager, address(fresh));

        // Unpause through the agent.
        vm.prank(agent);
        fresh.unpause();

        vm.expectRevert(ErrorsLib.HookNotSet.selector);
        fresh.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

}
