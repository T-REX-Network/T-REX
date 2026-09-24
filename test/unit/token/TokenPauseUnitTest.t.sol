// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
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
        accessManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.AGENT_MINTER), minter, 0);

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

    function testPauseBlocksEveryMovementBetweenWalletsAndLeavesMintAndBurnOpen() public {
        address holder = makeAddr("Holder");
        address other = makeAddr("Other");
        address investorOnchainId = makeAddr("Identity");
        address[] memory froms = new address[](1);
        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        froms[0] = holder;
        tos[0] = other;
        amounts[0] = 1;
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.contains.selector, holder),
            abi.encode(true)
        );
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.contains.selector, other),
            abi.encode(false)
        );
        vm.startPrank(agent);
        token.mint(holder, 10);
        token.pause();
        vm.stopPrank();
        vm.prank(holder);
        IERC20(address(token)).approve(other, 1);

        vm.prank(holder);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        IERC20(address(token)).transfer(other, 1);
        vm.prank(other);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        IERC20(address(token)).transferFrom(holder, other, 1);
        vm.prank(agent);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.forcedTransfer(holder, other, 1);
        vm.prank(agent);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.batchForcedTransfer(froms, tos, amounts);
        vm.prank(agent);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.recoveryAddress(holder, other, investorOnchainId);
        vm.prank(compliance);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.settleValidation("", "", 1, 1);
        vm.prank(compliance);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.holdInTransit("", 1, 1);

        vm.startPrank(agent);
        token.mint(holder, 5);
        token.burn(holder, 3);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 12);
        assertEq(token.balanceOf(other), 0);
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
