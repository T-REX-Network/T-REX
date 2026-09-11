// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

contract TokenBridgedTransferUnitTest is TokenLedgerBaseUnitTest {

    uint256 internal constant VALIDATION_ID = 7;

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        ledger.delegateOut(user1, satellite1, 60);
        vm.stopPrank();
    }

    function test_bridgedTransfer_MovesThePositionBetweenSatellites() public {
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, satellite2, 30, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 30);
        assertEq(token.bridgedBalanceOf(satellite2), 30);
        assertEq(token.totalBridged(), 60);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    function test_bridgedTransfer_EmitsTheFullEnvelopesAndTheValidationId() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(
            keccak256(satellite1), keccak256(satellite2), VALIDATION_ID, satellite1, satellite2, 30
        );
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, satellite2, 30, VALIDATION_ID);
    }

    /// @dev The native ledger is not involved: no `Transfer`, no compliance hook, `balanceOf` untouched.
    function test_bridgedTransfer_LeavesTheNativeLedgerAlone() public {
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), 0);
        vm.recordLogs();
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, satellite2, 30, VALIDATION_ID);

        assertEq(vm.getRecordedLogs().length, 1, "only BridgedTransfer is emitted");
        assertEq(token.balanceOf(user1), 40);
        assertEq(token.totalSupply(), 100);
    }

    function test_bridgedTransfer_AcrossChainsIsOneAtomicTouch() public {
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, satellite3, 60, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 0);
        assertEq(token.bridgedBalanceOf(satellite3), 60);
        assertEq(token.totalBridged(), 60);
        _assertPartition();
    }

    function test_bridgedTransfer_ChainsThroughAnIntermediateSatellite() public {
        vm.startPrank(agent);
        ledger.bridgedTransfer(satellite1, satellite2, 30, VALIDATION_ID);
        ledger.bridgedTransfer(satellite2, satellite3, 10, VALIDATION_ID + 1);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite1), 30);
        assertEq(token.bridgedBalanceOf(satellite2), 20);
        assertEq(token.bridgedBalanceOf(satellite3), 10);
        _assertPartition();
    }

    function test_bridgedTransfer_ToSelfIsANoOp() public {
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, satellite1, 30, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 60);
        _assertPartition();
    }

    function test_bridgedTransfer_ZeroAmountSucceeds() public {
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, satellite2, 0, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 60);
        assertEq(token.bridgedBalanceOf(satellite2), 0);
    }

    function test_bridgedTransfer_ThenRecallFromTheReceiver() public {
        vm.startPrank(agent);
        ledger.bridgedTransfer(satellite1, satellite2, 30, VALIDATION_ID);
        ledger.recall(satellite2, user2, 30);
        vm.stopPrank();

        assertEq(token.balanceOf(user2), 30);
        assertEq(token.bridgedBalanceOf(satellite2), 0);
        assertEq(token.totalBridged(), 30);
        _assertPartition();
    }

    function test_bridgedTransfer_RevertWhen_AmountAboveTheSourcePosition() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite1, 60, 61));
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, satellite2, 61, VALIDATION_ID);
    }

    function test_bridgedTransfer_RevertWhen_SourceHoldsNoPosition() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite2, 0, 1));
        vm.prank(agent);
        ledger.bridgedTransfer(satellite2, satellite1, 1, VALIDATION_ID);
    }

    function test_bridgedTransfer_RevertWhen_ReceiverIsOnTheReferenceChain() public {
        bytes memory native = satelliteEnvelope(block.chainid, user2);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, native, 10, VALIDATION_ID);
    }

    function test_bridgedTransfer_RevertWhen_SourceIsOnTheReferenceChain() public {
        bytes memory native = satelliteEnvelope(block.chainid, user1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        vm.prank(agent);
        ledger.bridgedTransfer(native, satellite2, 0, VALIDATION_ID);
    }

    function test_bridgedTransfer_RevertWhen_SourceEnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite1, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        vm.prank(agent);
        ledger.bridgedTransfer(padded, satellite2, 10, VALIDATION_ID);
    }

    function test_bridgedTransfer_RevertWhen_ReceiverEnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite2, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        vm.prank(agent);
        ledger.bridgedTransfer(satellite1, padded, 10, VALIDATION_ID);
    }

}
