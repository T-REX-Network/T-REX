// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenUnpauseUnitTest is TokenBaseUnitTest {

    function setUp() public override {
        super.setUp();
    }

    function testTokenUnpauseRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.unpause();
    }

    function testTokenUnpauseRevertsWhenNotPaused() public {
        vm.prank(agent);
        token.unpause();

        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vm.prank(agent);
        token.unpause();
    }

    function testTokenUnpauseNominal() public {
        address account = agent;

        vm.expectEmit(true, true, true, true, address(token));
        emit PausableUpgradeable.Unpaused(account);
        vm.prank(agent);
        token.unpause();

        assertFalse(token.paused());
    }

}
