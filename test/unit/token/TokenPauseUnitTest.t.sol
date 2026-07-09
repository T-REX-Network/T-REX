// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenPauseUnitTest is TokenBaseUnitTest {

    function setUp() public override {
        super.setUp();

        vm.prank(agent);
        token.unpause();
    }

    function testTokenPauseRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.pause();
    }

    function testTokenPauseRevertsWhenCallerOnlyMinter() public {
        address minter = makeAddr("Minter");
        accessManager.grantRole(RolesLib.AGENT_MINTER, minter, 0);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, minter));
        vm.prank(minter);
        token.pause();
    }

    function testTokenPauseRevertsWhenAlreadyPaused() public {
        // Token is already paused from setUp (we unpaused it, but let's pause it again to test)
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(agent);
        token.pause();
    }

    function testTokenPauseNominal() public {
        address account = agent;

        vm.expectEmit(true, true, true, true);
        emit PausableUpgradeable.Paused(account);
        vm.prank(agent);
        token.pause();

        assertTrue(token.paused());
    }

}
