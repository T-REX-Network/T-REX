// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @dev The compliance-only ledger entry: who may call it, and which transition each wallet shape resolves to.
contract TokenSettleValidationUnitTest is TokenLedgerBaseUnitTest {

    uint256 internal constant VALIDATION_ID = 7;

    bytes internal nativeUser1;
    bytes internal nativeUser2;

    function setUp() public override {
        super.setUp();
        nativeUser1 = satelliteEnvelope(block.chainid, user1);
        nativeUser2 = satelliteEnvelope(block.chainid, user2);
        vm.startPrank(agent);
        token.mint(user1, 100);
        ledger.delegateOut(user1, satellite1, 60);
        vm.stopPrank();
    }

    // ==== caller Tests ====

    function test_settleValidation_RevertWhen_CallerIsNotTheBoundCompliance() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.settleValidation(satellite1, satellite2, 30, VALIDATION_ID);

        vm.prank(user1);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.settleValidation(satellite1, satellite2, 30, VALIDATION_ID);
    }

    // ==== shape Tests ====

    function test_settleValidation_Success_WhenBothWalletsAreSatellites() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(
            keccak256(satellite1), keccak256(satellite2), VALIDATION_ID, satellite1, satellite2, 30
        );
        vm.prank(compliance);
        token.settleValidation(satellite1, satellite2, 30, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 30);
        assertEq(token.bridgedBalanceOf(satellite2), 30);
        assertEq(token.balanceOf(user1), 40);
        assertEq(token.totalBridged(), 60);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    function test_settleValidation_Success_WhenFromIsNative() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(user1, address(0), 25);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.DelegatedOut(user1, keccak256(satellite2), satellite2, 25);
        vm.prank(compliance);
        token.settleValidation(nativeUser1, satellite2, 25, VALIDATION_ID);

        assertEq(token.balanceOf(user1), 15);
        assertEq(token.bridgedBalanceOf(satellite2), 25);
        assertEq(token.totalBridged(), 85);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    function test_settleValidation_Success_WhenToIsNative() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(0), user2, 20);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.Recalled(keccak256(satellite1), user2, satellite1, 20);
        vm.prank(compliance);
        token.settleValidation(satellite1, nativeUser2, 20, VALIDATION_ID);

        assertEq(token.balanceOf(user2), 20);
        assertEq(token.bridgedBalanceOf(satellite1), 40);
        assertEq(token.totalBridged(), 40);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    // ==== refusal Tests ====

    function test_settleValidation_RevertWhen_TheNativeSenderNoLongerHasTheFreeBalance() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 40, 41));
        token.settleValidation(nativeUser1, satellite2, 41, VALIDATION_ID);
    }

    function test_settleValidation_RevertWhen_TheSatelliteSenderHasNotEnoughBridged() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite1, 60, 61));
        token.settleValidation(satellite1, satellite2, 61, VALIDATION_ID);
    }

    function test_settleValidation_RevertWhen_AnEnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite2, hex"00");

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        token.settleValidation(satellite1, padded, 10, VALIDATION_ID);
    }

    function test_settleValidation_RevertWhen_BothWalletsAreNative() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, nativeUser2));
        token.settleValidation(nativeUser1, nativeUser2, 10, VALIDATION_ID);
    }

}
