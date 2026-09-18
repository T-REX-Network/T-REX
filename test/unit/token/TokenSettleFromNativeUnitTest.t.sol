// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @notice The settled leg of a validation whose sender is on the reference chain. Same bucket arithmetic as a
///         delegation-out, but ownership moves, so `satellite2` here belongs to a counterparty and not to `user1`.
contract TokenSettleFromNativeUnitTest is TokenLedgerBaseUnitTest {

    uint256 internal constant VALIDATION_ID = 11;

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        token.freezePartialTokens(user1, 20);
        vm.stopPrank();
    }

    function test_settleFromNative_MovesFreeBalanceToTheCounterpartySatellite() public {
        vm.prank(agent);
        ledger.settleFromNative(user1, satellite2, 50, VALIDATION_ID);

        assertEq(token.balanceOf(user1), 50);
        assertEq(token.freeBalanceOf(user1), 30);
        assertEq(token.getFrozenTokens(user1), 20, "frozen tokens are never drawn on");
        assertEq(token.bridgedBalanceOf(satellite2), 50);
        assertEq(token.totalBridged(), 50);
        assertEq(token.totalSupply(), 100, "the supply never moves on a settlement");
        _assertPartition();
    }

    function test_settleFromNative_EmitsTransferToZeroThenSettledFromNative() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(user1, address(0), 50);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledFromNative(user1, keccak256(satellite2), VALIDATION_ID, satellite2, 50);

        vm.prank(agent);
        ledger.settleFromNative(user1, satellite2, 50, VALIDATION_ID);
    }

    /// @dev The whole point of the transition: an indexer reading the trail must not see a relocation.
    function test_settleFromNative_NeverEmitsDelegatedOut() public {
        vm.recordLogs();
        vm.prank(agent);
        ledger.settleFromNative(user1, satellite2, 50, VALIDATION_ID);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "only Transfer and SettledFromNative are emitted");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.DelegatedOut.selector, "a settlement emitted DelegatedOut");
        }
    }

    /// @dev The two differ by their event only, so a drift in either one's arithmetic shows up here.
    function test_settleFromNative_LeavesTheSameBucketsAsADelegationOut() public {
        uint256 snapshot = vm.snapshotState();

        vm.prank(agent);
        ledger.delegateOut(user1, satellite2, 50);
        (uint256 free, uint256 frozen, uint256 bridged, uint256 bridgedTotal, uint256 supply) = _buckets();

        vm.revertToState(snapshot);

        vm.prank(agent);
        ledger.settleFromNative(user1, satellite2, 50, VALIDATION_ID);
        (uint256 free2, uint256 frozen2, uint256 bridged2, uint256 bridgedTotal2, uint256 supply2) = _buckets();

        assertEq(free2, free, "free balance diverged");
        assertEq(frozen2, frozen, "frozen balance diverged");
        assertEq(bridged2, bridged, "bridged position diverged");
        assertEq(bridgedTotal2, bridgedTotal, "totalBridged diverged");
        assertEq(supply2, supply, "totalSupply diverged");
    }

    function test_settleFromNative_AddsToAnExistingPosition() public {
        vm.startPrank(agent);
        ledger.delegateOut(user1, satellite2, 30);
        ledger.settleFromNative(user1, satellite2, 20, VALIDATION_ID);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite2), 50);
        assertEq(token.totalBridged(), 50);
        _assertPartition();
    }

    function test_settleFromNative_SettlesOnAnotherChain() public {
        vm.prank(agent);
        ledger.settleFromNative(user1, satellite3, 80, VALIDATION_ID);

        assertEq(token.bridgedBalanceOf(satellite3), 80);
        assertEq(token.freeBalanceOf(user1), 0);
        _assertPartition();
    }

    function test_settleFromNative_ZeroAmountSucceeds() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledFromNative(user1, keccak256(satellite2), VALIDATION_ID, satellite2, 0);
        vm.prank(agent);
        ledger.settleFromNative(user1, satellite2, 0, VALIDATION_ID);

        assertEq(token.balanceOf(user1), 100);
        assertEq(token.bridgedBalanceOf(satellite2), 0);
        assertEq(token.totalBridged(), 0);
    }

    /// @dev The ledger owns the state, the flow owns the checks: eligibility and compliance were settled upstream.
    function test_settleFromNative_ChecksNeitherComplianceNorEligibility() public {
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.destroyed.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), 0);
        vm.expectCall(identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector), 0);
        vm.prank(agent);
        ledger.settleFromNative(user1, satellite2, 50, VALIDATION_ID);
    }

    function test_settleFromNative_IsNotGatedByPause() public {
        vm.startPrank(agent);
        token.pause();
        ledger.settleFromNative(user1, satellite2, 50, VALIDATION_ID);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite2), 50);
    }

    function test_settleFromNative_RevertWhen_FrozenTokensWouldMove() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 80, 90));
        vm.prank(agent);
        ledger.settleFromNative(user1, satellite2, 90, VALIDATION_ID);
    }

    function test_settleFromNative_RevertWhen_SenderHasNothing() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user2, 0, 1));
        vm.prank(agent);
        ledger.settleFromNative(user2, satellite2, 1, VALIDATION_ID);
    }

    function test_settleFromNative_RevertWhen_ReceiverIsOnTheReferenceChain() public {
        bytes memory native = satelliteEnvelope(block.chainid, user2);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        vm.prank(agent);
        ledger.settleFromNative(user1, native, 10, VALIDATION_ID);
    }

    function test_settleFromNative_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite2, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        vm.prank(agent);
        ledger.settleFromNative(user1, padded, 10, VALIDATION_ID);
    }

    function test_settleFromNative_RevertWhen_SenderIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(agent);
        ledger.settleFromNative(address(0), satellite2, 0, VALIDATION_ID);
    }

    function _buckets()
        private
        view
        returns (uint256 free, uint256 frozen, uint256 bridged, uint256 bridgedTotal, uint256 supply)
    {
        return (
            token.freeBalanceOf(user1),
            token.getFrozenTokens(user1),
            token.bridgedBalanceOf(satellite2),
            token.totalBridged(),
            token.totalSupply()
        );
    }

}
