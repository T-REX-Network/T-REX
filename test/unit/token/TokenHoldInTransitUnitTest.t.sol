// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @dev The in-transit hold: who may take it, what it moves, and how a settlement under the same id releases it.
contract TokenHoldInTransitUnitTest is TokenLedgerBaseUnitTest {

    uint256 internal constant VALIDATION_ID = 7;

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        ledger.delegateOut(user1, satellite1, 60);
        vm.stopPrank();
    }

    // ==== caller Tests ====

    function test_holdInTransit_RevertWhen_CallerIsNotTheBoundCompliance() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.holdInTransit(satellite1, 30, VALIDATION_ID, 0);

        vm.prank(user1);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.holdInTransit(satellite1, 30, VALIDATION_ID, 0);
    }

    // ==== hold Tests ====

    function test_holdInTransit_Success_WhenTheBurnLegLands() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.HeldInTransit(keccak256(satellite1), VALIDATION_ID, satellite1, 30);
        vm.prank(compliance);
        token.holdInTransit(satellite1, 30, VALIDATION_ID, 0);

        assertEq(token.bridgedBalanceOf(satellite1), 30, "the wallet no longer holds it");
        assertEq(token.inTransitOf(VALIDATION_ID), 30, "the validation does");
        assertEq(token.totalInTransit(), 30);
        assertEq(token.totalBridged(), 60, "still bridged");
        assertEq(token.totalSupply(), 100, "still issued");
        assertEq(token.balanceOf(user1), 40);
        _assertPartition();
    }

    function test_holdInTransit_Success_WhenTheWholePositionIsBurned() public {
        vm.prank(compliance);
        token.holdInTransit(satellite1, 60, VALIDATION_ID, 0);

        assertEq(token.bridgedBalanceOf(satellite1), 0);
        assertEq(token.inTransitOf(VALIDATION_ID), 60);
        _assertPartition();
    }

    function test_holdInTransit_RevertWhen_TheSatelliteSenderHasNotEnoughBridged() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite1, 60, 61));
        token.holdInTransit(satellite1, 61, VALIDATION_ID, 0);
    }

    function test_holdInTransit_RevertWhen_TheValidationAlreadyHolds() public {
        vm.startPrank(compliance);
        token.holdInTransit(satellite1, 30, VALIDATION_ID, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAlreadyHeld.selector, VALIDATION_ID));
        token.holdInTransit(satellite1, 10, VALIDATION_ID, 0);
        vm.stopPrank();

        assertEq(token.inTransitOf(VALIDATION_ID), 30, "held once");
    }

    function test_holdInTransit_RevertWhen_TheSenderIsNative() public {
        bytes memory nativeUser1 = satelliteEnvelope(block.chainid, user1);

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, nativeUser1));
        token.holdInTransit(nativeUser1, 10, VALIDATION_ID, 0);
    }

    // ==== release Tests ====

    function test_settleValidation_Success_WhenTheMintLegReleasesTheHold() public {
        vm.startPrank(compliance);
        token.holdInTransit(satellite1, 30, VALIDATION_ID, 0);

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(
            keccak256(satellite1), keccak256(satellite3), VALIDATION_ID, satellite1, satellite3, 30
        );
        token.settleValidation(satellite1, satellite3, 30, VALIDATION_ID);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite1), 30, "not debited twice");
        assertEq(token.bridgedBalanceOf(satellite3), 30, "credited from the hold");
        assertEq(token.inTransitOf(VALIDATION_ID), 0);
        assertEq(token.totalInTransit(), 0);
        assertEq(token.totalBridged(), 60);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    function test_settleValidation_RevertWhen_TheSettledAmountIsNotTheHeldOne() public {
        vm.startPrank(compliance);
        token.holdInTransit(satellite1, 30, VALIDATION_ID, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAmountMismatch.selector, VALIDATION_ID, 30, 31));
        token.settleValidation(satellite1, satellite3, 31, VALIDATION_ID);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAmountMismatch.selector, VALIDATION_ID, 30, 29));
        token.settleValidation(satellite1, satellite3, 29, VALIDATION_ID);
        vm.stopPrank();

        assertEq(token.inTransitOf(VALIDATION_ID), 30, "still held");
    }

    function test_settleValidation_Success_WhenAnotherValidationSettlesBesideTheHold() public {
        vm.startPrank(compliance);
        token.holdInTransit(satellite1, 30, VALIDATION_ID, 0);
        token.settleValidation(satellite1, satellite2, 20, VALIDATION_ID + 1);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite1), 10, "the other one debits the wallet as usual");
        assertEq(token.bridgedBalanceOf(satellite2), 20);
        assertEq(token.inTransitOf(VALIDATION_ID), 30, "the hold is untouched");
        _assertPartition();
    }

}
