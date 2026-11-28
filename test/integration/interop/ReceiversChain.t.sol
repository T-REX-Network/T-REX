// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { HoldsSuiteTest } from "test/integration/helpers/HoldsSuiteTest.sol";

/// @dev A move from one away chain to another involves both: Alice on Polygon to Bob on Optimism is refused while
///      Optimism is blocked, closed or under a hostile change, at the ask, at the first send of an approved ticket
///      and at an ask for its receipt, as it would be for Polygon.
contract ReceiversChainTest is HoldsSuiteTest {

    uint256 internal constant FOUR = 4;
    address internal approver = makeAddr("approver");

    /* ----- The ask ----- */

    function test_askToMove_reverts_when_theReceiversAwayChainIsBlocked() public {
        vm.prank(agent);
        boundCompliance.blockAwayChain(optimism);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, optimism));
        boundCompliance.askToMove(aliceSat, bobOptimismSat, FOUR, FOUR, "", _salt());
    }

    function test_askToMove_reverts_when_theReceiversAwayChainIsClosed() public {
        _closeEvmChain(token, OPTIMISM);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        boundCompliance.askToMove(aliceSat, bobOptimismSat, FOUR, FOUR, "", _salt());
    }

    function test_askToMove_reverts_when_aHostileChangeRunsOnTheReceiversAwayChain() public {
        vm.prank(deployer);
        token.replaceHostilePeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("newOptimismAwayToken")));
        uint64 endsAt = token.hostileChangeEndsAt(optimism);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, optimism, endsAt));
        boundCompliance.askToMove(aliceSat, bobOptimismSat, FOUR, FOUR, "", _salt());
    }

    /// @notice Asks pause per chain: pausing Polygon refuses asks whose first message goes there, and leaves the
    ///         others; zero pauses every chain.
    function test_askToMove_reverts_onlyOnThePausedChain() public {
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AsksPausedSet(optimism, true);
        vm.prank(deployer);
        boundCompliance.setAsksPaused(optimism, true);
        assertTrue(boundCompliance.areAsksPaused(optimism), "optimism paused");
        assertFalse(boundCompliance.areAsksPaused(bytes32(0)), "not every chain");
        _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);

        vm.prank(deployer);
        boundCompliance.setAsksPaused(polygon, true);
        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.AsksPaused.selector);
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", _salt());
    }

    /* ----- The first send of an approved ticket ----- */

    function test_sendTicket_reverts_when_theReceiversAwayChainIsBlockedAtTheFirstSend() public {
        bytes32 ticketId = _approvedAToB();
        vm.prank(agent);
        boundCompliance.blockAwayChain(optimism);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, optimism));
        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");
    }

    function test_sendTicket_reverts_when_theReceiversAwayChainIsClosedAtTheFirstSend() public {
        bytes32 ticketId = _approvedAToB();
        _closeEvmChain(token, OPTIMISM);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");
    }

    /* ----- An ask for the receipt ----- */

    function test_sendTicket_reverts_when_theReceiversAwayChainIsBlockedAtAnAskForTheReceipt() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobOptimismSat, FOUR, FOUR);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        vm.warp(ticket.validUntil + boundCompliance.waitingTimeOf(ticket.fromChainKey));
        vm.prank(agent);
        boundCompliance.blockAwayChain(optimism);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, optimism));
        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");
    }

    /// @dev Alice on Polygon asks to move 4 to Bob on Optimism, and the approver opens the ticket. Not sent yet.
    function _approvedAToB() private returns (bytes32 ticketId) {
        AsyncApprovalModule module = _bindApprovalModule(approver);
        ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobOptimismSat, FOUR, FOUR);
        vm.prank(approver);
        module.approveValidation(address(boundCompliance), ticketId, FOUR);
        module.finalize(address(boundCompliance), ticketId);
        _assertStatus(ticketId, ITickets.TicketStatus.Open, "approved, not sent");
    }

}
