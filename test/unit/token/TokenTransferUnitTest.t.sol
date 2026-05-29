// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

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

    function testTokenTransferRevertsWhenPaused() public {
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(from);
        token.transfer(to, transferAmount);
    }

    function testTokenTransferRevertsWhenSenderFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(from, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, from));
        vm.prank(from);
        token.transfer(to, transferAmount);
    }

    function testTokenTransferRevertsWhenReceiverFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(to, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, to));
        vm.prank(from);
        token.transfer(to, transferAmount);
    }

    function testTokenTransferRevertsWhenInsufficientBalance() public {
        uint256 excessiveAmount = mintAmount - frozenAmount + 1;

        // Freeze some tokens
        vm.prank(agent);
        token.freezePartialTokens(from, frozenAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, from, mintAmount - frozenAmount, excessiveAmount
            )
        );
        vm.prank(from);
        token.transfer(to, excessiveAmount);
    }

    function testTokenTransferRevertsWhenReceiverNotVerified() public {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector, to),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        vm.prank(from);
        token.transfer(to, transferAmount);
    }

    function testTokenTransferRevertsWhenComplianceNotFollowed() public {
        vm.mockCall(
            compliance,
            abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector, from, to, transferAmount),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        vm.prank(from);
        token.transfer(to, transferAmount);
    }

    function testTokenTransferNominal() public {
        vm.prank(from);
        bool success = token.transfer(to, transferAmount);

        assertTrue(success);
        assertEq(token.balanceOf(from), mintAmount - transferAmount);
        assertEq(token.balanceOf(to), transferAmount);
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
        uint256 excessiveAmount = mintAmount - frozenAmount + 1;

        // Approve spender for the attempted excessive amount so allowance check passes
        // and the free-balance check inside _update fires the expected error.
        vm.prank(from);
        token.approve(spender, excessiveAmount);

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

        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
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

        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
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

