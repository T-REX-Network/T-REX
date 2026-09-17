// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @notice The settled leg of a validation whose receiver is on the reference chain. Same bucket arithmetic as a
///         recall, but ownership moves: the position leaves `user1`'s satellite wallet and lands on `user2`.
contract TokenSettleToNativeUnitTest is TokenLedgerBaseUnitTest {

    uint256 internal constant VALIDATION_ID = 13;

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        ledger.delegateOut(user1, satellite1, 60);
        vm.stopPrank();
    }

    function test_settleToNative_MovesTheSatellitePositionToTheCounterpartyWallet() public {
        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 50, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 10);
        assertEq(token.totalBridged(), 10);
        assertEq(token.balanceOf(user2), 50);
        assertEq(token.freeBalanceOf(user2), 50, "the credit lands free, never frozen");
        assertEq(token.getFrozenTokens(user2), 0);
        assertEq(token.balanceOf(user1), 40, "the sender's native balance is untouched");
        assertEq(token.totalSupply(), 100, "the supply never moves on a settlement");
        _assertPartition();
    }

    function test_settleToNative_EmitsTransferFromZeroThenSettledToNative() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(address(0), user2, 50);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledToNative(keccak256(satellite1), user2, VALIDATION_ID, satellite1, 50);

        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 50, VALIDATION_ID);
    }

    /// @dev The whole point of the transition: an indexer reading the trail must not see a relocation.
    function test_settleToNative_NeverEmitsRecalled() public {
        vm.recordLogs();
        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 50, VALIDATION_ID);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "only Transfer and SettledToNative are emitted");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.Recalled.selector, "a settlement emitted Recalled");
        }
    }

    /// @dev The two differ by their event only, so a drift in either one's arithmetic shows up here.
    function test_settleToNative_LeavesTheSameBucketsAsARecall() public {
        uint256 snapshot = vm.snapshotState();

        vm.prank(agent);
        ledger.recall(satellite1, user2, 50);
        (uint256 free, uint256 bridged, uint256 bridgedTotal, uint256 supply) = _buckets();

        vm.revertToState(snapshot);

        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 50, VALIDATION_ID);
        (uint256 free2, uint256 bridged2, uint256 bridgedTotal2, uint256 supply2) = _buckets();

        assertEq(free2, free, "free balance diverged");
        assertEq(bridged2, bridged, "bridged position diverged");
        assertEq(bridgedTotal2, bridgedTotal, "totalBridged diverged");
        assertEq(supply2, supply, "totalSupply diverged");
    }

    function test_settleToNative_SettlesTheWholePosition() public {
        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 60, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 0);
        assertEq(token.totalBridged(), 0);
        assertEq(token.balanceOf(user2), 60);
        _assertPartition();
    }

    function test_settleToNative_ThenSettlesBackOut() public {
        vm.startPrank(agent);
        ledger.settleToNative(satellite1, user2, 50, VALIDATION_ID);
        ledger.settleFromNative(user2, satellite3, 50, VALIDATION_ID + 1);
        vm.stopPrank();

        assertEq(token.balanceOf(user2), 0);
        assertEq(token.bridgedBalanceOf(satellite3), 50);
        assertEq(token.totalBridged(), 60);
        _assertPartition();
    }

    function test_settleToNative_ZeroAmountSucceeds() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledToNative(keccak256(satellite1), user2, VALIDATION_ID, satellite1, 0);
        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 0, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite1), 60);
        assertEq(token.balanceOf(user2), 0);
    }

    /// @dev The ledger owns the state, the flow owns the checks: eligibility and compliance were settled upstream.
    function test_settleToNative_ChecksNeitherComplianceNorEligibility() public {
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.created.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), 0);
        vm.expectCall(identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector), 0);
        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 50, VALIDATION_ID);
    }

    function test_settleToNative_IsNotGatedByPause() public {
        vm.startPrank(agent);
        token.pause();
        ledger.settleToNative(satellite1, user2, 50, VALIDATION_ID);
        vm.stopPrank();

        assertEq(token.balanceOf(user2), 50);
    }

    function test_settleToNative_RevertWhen_AmountAboveTheSourcePosition() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite1, 60, 61));
        vm.prank(agent);
        ledger.settleToNative(satellite1, user2, 61, VALIDATION_ID);
    }

    function test_settleToNative_RevertWhen_SourceHoldsNoPosition() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite2, 0, 1));
        vm.prank(agent);
        ledger.settleToNative(satellite2, user2, 1, VALIDATION_ID);
    }

    function test_settleToNative_RevertWhen_SenderIsOnTheReferenceChain() public {
        bytes memory native = satelliteEnvelope(block.chainid, user1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        vm.prank(agent);
        ledger.settleToNative(native, user2, 10, VALIDATION_ID);
    }

    function test_settleToNative_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite1, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        vm.prank(agent);
        ledger.settleToNative(padded, user2, 10, VALIDATION_ID);
    }

    function test_settleToNative_RevertWhen_ReceiverIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(agent);
        ledger.settleToNative(satellite1, address(0), 0, VALIDATION_ID);
    }

    function _buckets() private view returns (uint256 free, uint256 bridged, uint256 bridgedTotal, uint256 supply) {
        return
            (token.freeBalanceOf(user2), token.bridgedBalanceOf(satellite1), token.totalBridged(), token.totalSupply());
    }

}
