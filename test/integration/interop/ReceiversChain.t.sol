// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { HoldsSuiteTest } from "test/integration/helpers/HoldsSuiteTest.sol";

/// @dev A move from one away chain to another involves both: Alice on Polygon to Bob on Optimism is refused while
///      Optimism is blocked, closed or under a hostile change at the ask, as it would be for Polygon. The first send
///      of an approved ticket, a resend and an ask for the receipt go to Polygon: they are refused while Optimism is
///      blocked, never because Optimism's route closed or its peer was replaced as hostile since the ask.
contract ReceiversChainTest is HoldsSuiteTest {

    uint256 internal constant FOUR = 4;
    uint256 internal constant BASE = 8453;
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

    /// @notice Asks paused on the receiver's away chain refuse a move toward it, though its first message goes to
    ///         the sender's chain.
    function test_askToMove_reverts_when_asksArePausedOnTheReceiversAwayChain() public {
        vm.prank(deployer);
        boundCompliance.setAsksPaused(optimism, true);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.AsksPaused.selector);
        boundCompliance.askToMove(aliceSat, bobOptimismSat, FOUR, FOUR, "", _salt());
    }

    /// @notice A receiver's away chain with an open route but no waiting time is refused at the ask: its second half
    ///         could never go there.
    function test_askToMove_reverts_when_theReceiversAwayChainHasNoWaitingTime() public {
        bytes32 base = _evmChainKey(BASE);
        _openEvmChain(token, BASE, address(_newReceiptBridge(BASE)));
        bytes memory bobBaseSat = _linkSatelliteWallet(bobIdentity, BASE, makeAccount("bobOnBase"));
        assertTrue(token.isChainOpen(base), "the route is open");

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WaitingTimeNotSet.selector, base));
        boundCompliance.askToMove(aliceSat, bobBaseSat, FOUR, FOUR, "", _salt());
    }

    /// @notice An ask that waits for approval sends nothing, so the sender's chain is checked open at the ask itself.
    function test_askToMove_reverts_when_theSendersAwayChainIsClosed_whileAnApprovalModuleIsBound() public {
        _bindApprovalModule(approver);
        _closeEvmChain(token, POLYGON);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", _salt());
    }

    function test_askToMove_reverts_when_aHostileChangeRunsOnTheReceiversAwayChain() public {
        vm.prank(deployer);
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("newOptimismAwayToken")), true);
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

    /// @notice Optimism's route closes after the approval. The first send still goes to Polygon, at or after
    ///         `waitingEndsAt` it is the first ask for the receipt, and once that ask went unanswered for one waiting
    ///         time anyone cancels the ticket: it is not held open while the receiver's chain stays closed.
    function test_sendTicket_sendsTheApprovedTicket_whenTheReceiversAwayChainClosedSinceTheAsk() public {
        bytes32 ticketId = _approvedAToB();
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        uint64 waitingTime = boundCompliance.waitingTimeOf(ticket.fromChainKey);
        _closeEvmChain(token, OPTIMISM);
        vm.warp(ticket.validUntil + waitingTime);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ReceiptAsked(ticketId, 1);
        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");
        assertTrue(boundCompliance.ticketOf(ticketId).sent, "the ticket left for polygon");

        vm.warp(block.timestamp + waitingTime);
        bytes32[] memory ticketIds = new bytes32[](1);
        ticketIds[0] = ticketId;
        boundCompliance.cancelTickets(ticketIds);
        _assertStatus(ticketId, ITickets.TicketStatus.Cancelled, "cancelled after the unanswered ask");
    }

    /// @notice Optimism's peer is replaced as hostile after the approval: the first send goes to Polygon, whose route
    ///         and peer are untouched.
    function test_sendTicket_sendsTheApprovedTicket_whileAHostileChangeRunsOnTheReceiversAwayChain() public {
        bytes32 ticketId = _approvedAToB();
        _replaceOptimismPeerAsHostile();
        assertGt(token.hostileChangeEndsAt(optimism), block.timestamp, "optimism is frozen");

        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");
        _relayAll(polygonGateway);

        assertTrue(boundCompliance.ticketOf(ticketId).sent, "the ticket left for polygon");
        assertEq(
            polygonLite.storedTicketValidUntil(ticketId),
            boundCompliance.ticketOf(ticketId).validUntil,
            "polygon holds the copy"
        );
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

    /// @notice Optimism's peer is replaced as hostile after the ask. The ask for the receipt goes to Polygon, whose
    ///         route and peer are untouched, and once it went unanswered for one waiting time anyone cancels the
    ///         ticket, inside Optimism's freeze.
    function test_sendTicket_asksForTheReceipt_whileAHostileChangeRunsOnTheReceiversAwayChain() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobOptimismSat, FOUR, FOUR);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        uint64 waitingTime = boundCompliance.waitingTimeOf(ticket.fromChainKey);
        vm.warp(ticket.validUntil + waitingTime);
        _replaceOptimismPeerAsHostile();
        uint64 freezeEndsAt = token.hostileChangeEndsAt(optimism);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ReceiptAsked(ticketId, 1);
        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");

        vm.warp(block.timestamp + waitingTime);
        assertLt(block.timestamp, freezeEndsAt, "optimism is still frozen");
        bytes32[] memory ticketIds = new bytes32[](1);
        ticketIds[0] = ticketId;
        boundCompliance.cancelTickets(ticketIds);
        _assertStatus(ticketId, ITickets.TicketStatus.Cancelled, "cancelled after the unanswered ask");
    }

    /// @notice A lost ticket is sent again to Polygon before its valid until while Optimism's peer is replaced as
    ///         hostile: nothing of it reaches Optimism. Possible only with a validity window longer than the waiting
    ///         time.
    function test_sendTicket_resendsALostTicket_whileAHostileChangeRunsOnTheReceiversAwayChain() public {
        vm.prank(deployer);
        boundCompliance.setValidityWindows(1 days, 1 days);
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobOptimismSat, FOUR, FOUR);
        polygonGateway.drop(polygonGateway.queueLength() - 1);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        vm.warp(ticket.lastSentAt + boundCompliance.waitingTimeOf(ticket.fromChainKey));
        assertLt(block.timestamp, ticket.validUntil, "before its valid until");
        _replaceOptimismPeerAsHostile();

        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");
        _relayAll(polygonGateway);

        assertEq(polygonLite.storedTicketValidUntil(ticketId), ticket.validUntil, "polygon holds the copy");
        assertEq(boundCompliance.ticketOf(ticketId).asksForReceipt, 0, "a resend is no ask");
    }

    /// @notice Optimism's route closes after the ask. The ask for the receipt still goes to Polygon, which owes it,
    ///         and once it went unanswered for one waiting time anyone cancels the ticket: it is not held open while
    ///         the receiver's chain stays closed.
    function test_sendTicket_asksForTheReceipt_whenTheReceiversAwayChainClosedSinceTheAsk() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobOptimismSat, FOUR, FOUR);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        uint64 waitingTime = boundCompliance.waitingTimeOf(ticket.fromChainKey);
        _closeEvmChain(token, OPTIMISM);
        assertFalse(token.isChainOpen(optimism), "the receiver's chain is closed");
        vm.warp(ticket.validUntil + waitingTime);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ReceiptAsked(ticketId, 1);
        boundCompliance.sendTicket(ticketId, bobOptimismSat, "");
        assertEq(boundCompliance.ticketOf(ticketId).asksForReceipt, 1, "one ask for the receipt stands");

        vm.warp(block.timestamp + waitingTime);
        bytes32[] memory ticketIds = new bytes32[](1);
        ticketIds[0] = ticketId;
        boundCompliance.cancelTickets(ticketIds);
        _assertStatus(ticketId, ITickets.TicketStatus.Cancelled, "cancelled after the unanswered ask");
    }

    /// @dev Replaces the optimism peer as hostile: a hostile change runs on optimism from now.
    function _replaceOptimismPeerAsHostile() private {
        vm.prank(deployer);
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("newOptimismAwayToken")), true);
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
