// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenTransferUnitTest is TokenBaseUnitTest {

    address from = makeAddr("From");
    address to = makeAddr("To");
    address spender = makeAddr("Spender");
    uint256 mintAmount = 1000;
    uint256 transferAmount = 500;
    uint256 frozenAmount = 300;

    function setUp() public override {
        super.setUp();

        vm.startPrank(agent);
        token.unpause();
        token.mint(from, mintAmount);
        vm.stopPrank();
    }

    function testTokenForcedTransferRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.forcedTransfer(from, to, transferAmount);
    }

    function testTokenForcedTransferRevertsWhenCallerOnlyMinter() public {
        address minter = makeAddr("Minter");
        accessManager.grantRole(RolesLib.AGENT_MINTER, minter, 0);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, minter));
        vm.prank(minter);
        token.forcedTransfer(from, to, transferAmount);
    }

    function testTokenForcedTransferUnfreezesTokensWhenNeeded() public {
        uint256 forcedAmount = mintAmount - frozenAmount + 100; // More than free balance

        // Freeze some tokens
        vm.prank(agent);
        token.freezePartialTokens(from, frozenAmount);

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.TokensUnfrozen(from, forcedAmount - (mintAmount - frozenAmount));

        vm.prank(agent);
        token.forcedTransfer(from, to, forcedAmount);

        assertEq(token.balanceOf(from), mintAmount - forcedAmount);
        assertEq(token.balanceOf(to), forcedAmount);
    }

    function testTokenForcedTransferRevertsWhenReceiverNotVerified() public {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector, to),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        vm.prank(agent);
        token.forcedTransfer(from, to, transferAmount);
    }

    function testTokenForcedTransferNominal() public {
        vm.prank(agent);
        bool success = token.forcedTransfer(from, to, transferAmount);

        assertTrue(success);
        assertEq(token.balanceOf(from), mintAmount - transferAmount);
        assertEq(token.balanceOf(to), transferAmount);
    }

    function testTokenBatchForcedTransferRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        address[] memory froms = new address[](1);
        froms[0] = from;

        address[] memory tos = new address[](1);
        tos[0] = to;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = transferAmount;

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.batchForcedTransfer(froms, tos, amounts);
    }

    function testTokenBatchForcedTransferNominal() public {
        address from1 = makeAddr("From1");
        address from2 = makeAddr("From2");
        address to1 = makeAddr("To1");
        address to2 = makeAddr("To2");
        uint256 mintAmount1 = 1000;
        uint256 mintAmount2 = 500;
        uint256 transferAmount1 = 300;
        uint256 transferAmount2 = 200;

        // Mint tokens
        vm.prank(agent);
        token.mint(from1, mintAmount1);
        vm.prank(agent);
        token.mint(from2, mintAmount2);

        address[] memory froms = new address[](2);
        froms[0] = from1;
        froms[1] = from2;

        address[] memory tos = new address[](2);
        tos[0] = to1;
        tos[1] = to2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = transferAmount1;
        amounts[1] = transferAmount2;

        vm.prank(agent);
        token.batchForcedTransfer(froms, tos, amounts);

        assertEq(token.balanceOf(from1), mintAmount1 - transferAmount1);
        assertEq(token.balanceOf(from2), mintAmount2 - transferAmount2);
        assertEq(token.balanceOf(to1), transferAmount1);
        assertEq(token.balanceOf(to2), transferAmount2);
    }

}

