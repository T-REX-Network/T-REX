// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenTransferFromUnitTest is TokenBaseUnitTest {

    address from = makeAddr("From");
    address to = makeAddr("To");
    address spender = makeAddr("Spender");
    uint256 mintAmount = 1000;
    uint256 transferAmount = 500;
    uint256 frozenAmount = 300;

    function setUp() public override {
        super.setUp();

        _mockIdentity(from, user1Identity);
        _mockIdentity(to, user2Identity);
        _mockIdentity(spender, makeAddr("SpenderIdentity"));

        vm.startPrank(agent);
        token.unpause();
        token.mint(from, mintAmount);
        vm.stopPrank();
    }

    function testTokenTransferFromRevertsWhenTokenPaused() public {
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(spender);
        token.transferFrom(from, to, transferAmount);
    }

    function testTokenTransferFromRevertsWhenReceiverFrozen() public {
        vm.prank(from);
        token.approve(spender, transferAmount);

        vm.prank(agent);
        token.setAddressFrozen(to, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, to));
        vm.prank(spender);
        token.transferFrom(from, to, transferAmount);
    }

    function testTokenTransferFromRevertsWhenSenderFrozen() public {
        vm.prank(from);
        token.approve(spender, transferAmount);

        vm.prank(agent);
        token.setAddressFrozen(from, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, from));
        vm.prank(spender);
        token.transferFrom(from, to, transferAmount);
    }

    function testTokenTransferFromRevertsWhenInsufficientBalance() public {
        // Approve spender
        vm.prank(from);
        token.approve(spender, transferAmount);

        uint256 excessiveAmount = mintAmount - frozenAmount + 1;

        // Freeze some tokens
        vm.prank(agent);
        token.freezePartialTokens(from, frozenAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, from, mintAmount - frozenAmount, excessiveAmount
            )
        );
        vm.prank(spender);
        token.transferFrom(from, to, excessiveAmount);
    }

    function testTokenTransferFromRevertsWhenReceiverNotVerified() public {
        // Approve spender
        vm.prank(from);
        token.approve(spender, transferAmount);

        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector, to),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.TransferNotPossible.selector);
        vm.prank(spender);
        token.transferFrom(from, to, transferAmount);
    }

    function testTokenTransferFromRevertsWhenComplianceNotFollowed() public {
        // Approve spender
        vm.prank(from);
        token.approve(spender, transferAmount);

        vm.mockCall(
            compliance,
            abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector, from, to, transferAmount),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.TransferNotPossible.selector);
        vm.prank(spender);
        token.transferFrom(from, to, transferAmount);
    }

    function testTokenTransferFromNominal() public {
        // Approve spender
        vm.prank(from);
        token.approve(spender, transferAmount);

        vm.prank(spender);
        bool success = token.transferFrom(from, to, transferAmount);

        assertTrue(success);
        assertEq(token.balanceOf(from), mintAmount - transferAmount);
        assertEq(token.balanceOf(to), transferAmount);
        assertEq(token.allowance(from, spender), 0);
    }

}

