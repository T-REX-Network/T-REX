// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

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

        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        vm.prank(caller);
        token.burn(user1, burnAmount);
    }

    function testTokenBurnNominal() public {
        vm.prank(agent);
        token.burn(user1, burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testTokenBurnUnfreezesTokensWhenNeeded() public {
        uint256 frozenAmount = 300;
        uint256 burnAmountExceedingFree = 800; // More than free balance (1000 - 300 = 700)

        // Freeze some tokens
        vm.prank(agent);
        token.freezePartialTokens(user1, frozenAmount);

        uint256 tokensToUnfreeze = burnAmountExceedingFree - (mintAmount - frozenAmount); // 800 - 700 = 100
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.TokensUnfrozen(user1, tokensToUnfreeze);
        vm.prank(agent);
        token.burn(user1, burnAmountExceedingFree);

        assertEq(token.balanceOf(user1), mintAmount - burnAmountExceedingFree); // 1000 - 800 = 200
        assertEq(token.getFrozenTokens(user1), frozenAmount - tokensToUnfreeze); // 300 - 100 = 200
    }

    function testTokenBatchBurnNominal() public {
        uint256 amount1 = 1000;
        uint256 amount2 = 500;
        uint256 burnAmount1 = 300;
        uint256 burnAmount2 = 200;

        // Mint tokens
        vm.startPrank(agent);
        token.mint(user1, amount1);
        token.mint(user2, amount2);

        uint256 user1BalanceBefore = token.balanceOf(user1);
        uint256 user2BalanceBefore = token.balanceOf(user2);

        address[] memory froms = new address[](2);
        froms[0] = user1;
        froms[1] = user2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = burnAmount1;
        amounts[1] = burnAmount2;

        token.batchBurn(froms, amounts);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), user1BalanceBefore - burnAmount1);
        assertEq(token.balanceOf(user2), user2BalanceBefore - burnAmount2);
        assertEq(token.totalSupply(), mintAmount + amount1 + amount2 - burnAmount1 - burnAmount2);
    }

    function testTokenBurnRevertsWhenDisableBurnRestrictionIsSet() public {
        // Set restriction to disable burn
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: true,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        token.setAgentRestrictions(agent, restrictions);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "burn disabled"));
        vm.prank(agent);
        token.burn(user1, burnAmount);
    }

}
