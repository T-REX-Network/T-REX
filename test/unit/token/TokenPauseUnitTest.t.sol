// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenPauseUnitTest is TokenBaseUnitTest {

    function setUp() public override {
        super.setUp();

        vm.prank(agent);
        token.unpause();
    }

    function testTokenPauseRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        vm.prank(caller);
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

    function testTokenPauseRevertsWhenDisablePauseRestrictionIsSet() public {
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
        token.pause();
    }

}
