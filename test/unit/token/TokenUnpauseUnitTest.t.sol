// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenUnpauseUnitTest is TokenBaseUnitTest {

    function setUp() public override {
        super.setUp();
    }

    function testTokenUnpauseRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
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

    function testTokenUnpauseRevertsWhenDisablePauseRestrictionIsSet() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: true
        });

        token.setAgentRestrictions(agent, restrictions);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "pause disabled"));
        vm.prank(agent);
        token.unpause();
    }

}
