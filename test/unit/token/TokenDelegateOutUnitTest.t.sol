// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

contract TokenDelegateOutUnitTest is TokenLedgerBaseUnitTest {

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        token.freezePartialTokens(user1, 20);
        vm.stopPrank();
    }

    function test_delegateOut_MovesFreeBalanceToTheSatellite() public {
        vm.prank(agent);
        ledger.delegateOut(user1, satellite1, 50);

        assertEq(token.balanceOf(user1), 50);
        assertEq(token.freeBalanceOf(user1), 30);
        assertEq(token.getFrozenTokens(user1), 20);
        assertEq(token.bridgedBalanceOf(satellite1), 50);
        assertEq(token.totalBridged(), 50);
        assertEq(token.totalSupply(), 100, "the supply never moves on a delegation");
        _assertPartition();
    }

    function test_delegateOut_EmitsTransferToZeroThenDelegatedOut() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(user1, address(0), 50);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.DelegatedOut(user1, keccak256(satellite1), satellite1, 50);

        vm.prank(agent);
        ledger.delegateOut(user1, satellite1, 50);
    }

    function test_delegateOut_TheWholeFreeBalance() public {
        vm.prank(agent);
        ledger.delegateOut(user1, satellite1, 80);

        assertEq(token.freeBalanceOf(user1), 0);
        assertEq(token.getFrozenTokens(user1), 20);
        assertEq(token.balanceOf(user1), 20);
        assertEq(token.bridgedBalanceOf(satellite1), 80);
        _assertPartition();
    }

    function test_delegateOut_ZeroAmountSucceeds() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.DelegatedOut(user1, keccak256(satellite1), satellite1, 0);
        vm.prank(agent);
        ledger.delegateOut(user1, satellite1, 0);

        assertEq(token.balanceOf(user1), 100);
        assertEq(token.bridgedBalanceOf(satellite1), 0);
    }

    function test_delegateOut_AccumulatesOnTheSameSatellite() public {
        vm.startPrank(agent);
        ledger.delegateOut(user1, satellite1, 30);
        ledger.delegateOut(user1, satellite1, 20);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite1), 50);
        assertEq(token.totalBridged(), 50);
        _assertPartition();
    }

    function test_delegateOut_SpreadsOverSeveralChains() public {
        vm.startPrank(agent);
        ledger.delegateOut(user1, satellite1, 30);
        ledger.delegateOut(user1, satellite3, 20);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite1), 30);
        assertEq(token.bridgedBalanceOf(satellite3), 20);
        assertEq(token.totalBridged(), 50);
        assertEq(token.balanceOf(user1), 50);
        _assertPartition();
    }

    /// @dev The ledger owns the state, the flow owns the checks: no compliance hook fires on a transition.
    function test_delegateOut_DoesNotNotifyTheCompliance() public {
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.destroyed.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), 0);
        vm.prank(agent);
        ledger.delegateOut(user1, satellite1, 50);
    }

    function test_delegateOut_IsNotGatedByPause() public {
        vm.startPrank(agent);
        token.pause();
        ledger.delegateOut(user1, satellite1, 50);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite1), 50);
    }

    function test_delegateOut_IsNotGatedByAddressFreeze() public {
        vm.startPrank(agent);
        token.setAddressFrozen(user1, true);
        ledger.delegateOut(user1, satellite1, 50);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellite1), 50);
    }

    function test_delegateOut_RevertWhen_FrozenTokensWouldMove() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 80, 90));
        vm.prank(agent);
        ledger.delegateOut(user1, satellite1, 90);
    }

    function test_delegateOut_RevertWhen_HolderHasNothing() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user2, 0, 1));
        vm.prank(agent);
        ledger.delegateOut(user2, satellite2, 1);
    }

    function test_delegateOut_RevertWhen_WalletIsOnTheReferenceChain() public {
        bytes memory native = satelliteEnvelope(block.chainid, user1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        vm.prank(agent);
        ledger.delegateOut(user1, native, 10);
    }

    function test_delegateOut_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite1, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        vm.prank(agent);
        ledger.delegateOut(user1, padded, 10);
    }

    function test_delegateOut_RevertWhen_HolderIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(agent);
        ledger.delegateOut(address(0), satellite1, 0);
    }

}
