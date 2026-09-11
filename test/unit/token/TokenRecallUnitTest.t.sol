// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

contract TokenRecallUnitTest is TokenLedgerBaseUnitTest {

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        ledger.delegateOut(user1, satellite1, 60);
        vm.stopPrank();
    }

    function test_recall_BringsTheBridgedPositionBack() public {
        vm.prank(agent);
        ledger.recall(satellite1, user1, 40);

        assertEq(token.bridgedBalanceOf(satellite1), 20);
        assertEq(token.balanceOf(user1), 80);
        assertEq(token.freeBalanceOf(user1), 80);
        assertEq(token.totalBridged(), 20);
        assertEq(token.totalSupply(), 100, "the supply never moves on a recall");
        _assertPartition();
    }

    function test_recall_EmitsTransferFromZeroThenRecalled() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(address(0), user1, 40);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.Recalled(keccak256(satellite1), user1, satellite1, 40);

        vm.prank(agent);
        ledger.recall(satellite1, user1, 40);
    }

    function test_recall_TheWholePosition() public {
        vm.prank(agent);
        ledger.recall(satellite1, user1, 60);

        assertEq(token.bridgedBalanceOf(satellite1), 0);
        assertEq(token.totalBridged(), 0);
        assertEq(token.balanceOf(user1), 100);
        _assertPartition();
    }

    function test_recall_ZeroAmountSucceeds() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.Recalled(keccak256(satellite1), user1, satellite1, 0);
        vm.prank(agent);
        ledger.recall(satellite1, user1, 0);

        assertEq(token.bridgedBalanceOf(satellite1), 60);
    }

    /// @dev Which native wallet receives is the flow's decision (same identity as the burned wallet); the ledger
    ///      credits whichever it is handed.
    function test_recall_LandsOnAnotherNativeWallet() public {
        vm.prank(agent);
        ledger.recall(satellite1, user2, 60);

        assertEq(token.balanceOf(user2), 60);
        assertEq(token.balanceOf(user1), 40);
        _assertPartition();
    }

    function test_recall_LeavesTheFrozenBucketAlone() public {
        vm.startPrank(agent);
        token.freezePartialTokens(user1, 40);
        ledger.recall(satellite1, user1, 60);
        vm.stopPrank();

        assertEq(token.getFrozenTokens(user1), 40);
        assertEq(token.freeBalanceOf(user1), 60);
    }

    function test_recall_DoesNotNotifyTheComplianceNorCheckEligibility() public {
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.created.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), 0);
        vm.expectCall(identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector), 0);
        vm.prank(agent);
        ledger.recall(satellite1, user1, 40);
    }

    function test_recall_RoundTripRestoresTheNativePosition() public {
        vm.startPrank(agent);
        ledger.recall(satellite1, user1, 60);
        ledger.delegateOut(user1, satellite1, 60);
        ledger.recall(satellite1, user1, 60);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 100);
        assertEq(token.bridgedBalanceOf(satellite1), 0);
        assertEq(token.totalBridged(), 0);
        assertEq(token.totalSupply(), 100);
    }

    function test_recall_RevertWhen_AmountAboveTheBridgedPosition() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite1, 60, 61));
        vm.prank(agent);
        ledger.recall(satellite1, user1, 61);
    }

    function test_recall_RevertWhen_WalletHoldsNoPosition() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite2, 0, 1));
        vm.prank(agent);
        ledger.recall(satellite2, user1, 1);
    }

    function test_recall_RevertWhen_WalletIsOnTheReferenceChain() public {
        bytes memory native = satelliteEnvelope(block.chainid, user1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        vm.prank(agent);
        ledger.recall(native, user1, 0);
    }

    function test_recall_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite1, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        vm.prank(agent);
        ledger.recall(padded, user1, 10);
    }

    function test_recall_RevertWhen_HolderIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(agent);
        ledger.recall(satellite1, address(0), 10);
    }

}
