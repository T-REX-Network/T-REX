// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenBurnUnitTest is TokenBaseUnitTest {

    uint256 mintAmount = 1000;
    uint256 burnAmount = 500;

    function setUp() public override {
        super.setUp();

        vm.startPrank(agent);
        token.unpause();
        token.mint(user1, mintAmount);
        vm.stopPrank();
    }

    function testTokenBurnRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        vm.prank(caller);
        token.burn(user1, burnAmount);
    }

    function testTokenBurnNominal() public {
        // The post-burn compliance hook must fire (Token._update: compliance.destroyed(from, value)).
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.destroyed.selector, user1, burnAmount));

        vm.prank(agent);
        token.burn(user1, burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testTokenBurnUnfreezesTokensWhenNeeded() public {
        uint256 frozenAmount = 300;
        uint256 burnAmountExceedingFree = 800;

        // Freeze some tokens
        vm.prank(agent);
        token.freezePartialTokens(user1, frozenAmount);

        uint256 tokensToUnfreeze = burnAmountExceedingFree - (mintAmount - frozenAmount);
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.TokensUnfrozen(user1, tokensToUnfreeze);
        vm.prank(agent);
        token.burn(user1, burnAmountExceedingFree);

        assertEq(token.balanceOf(user1), mintAmount - burnAmountExceedingFree);
        assertEq(token.getFrozenTokens(user1), frozenAmount - tokensToUnfreeze);
    }

    function testTokenBurnRevertsWhenDisableBurnRestrictionIsSet() public {
        vm.prank(accessManagerAdmin);
        accessManager.revokeRole(RolesLib.AGENT_BURNER, agent);

        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        vm.prank(agent);
        token.burn(user1, burnAmount);
    }

}
