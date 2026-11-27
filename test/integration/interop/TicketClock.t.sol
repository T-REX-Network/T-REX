// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The clock of one ticket: when its receipt may be asked for, three asks at most at fixed times, when an
///      unanswered ask lets anyone cancel it, the still open answers that move its valid until up to a cap, and the
///      waiting time it keeps from its ask. Every edge is strict: the away token executes strictly before valid until,
///      and an answer may land in the last second of a waiting time.
contract TicketClockTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 1000;
    uint256 internal constant ASKED_MAX = 90;

    ERC7786GatewayMock internal polygonBridge;
    bytes internal aliceSat;
    bytes internal bobSat;
    address internal stranger = makeAddr("stranger");

    bytes32 internal id;
    uint64 internal validUntil;
    uint64 internal firstAskDueAt;

    function setUp() public override {
        super.setUp();
        polygonBridge = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(polygonBridge));
        aliceSat =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.prank(agent);
        token.unpause();

        id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, ASKED_MAX);
        validUntil = boundCompliance.ticketOf(id).validUntil;
        firstAskDueAt = validUntil + POLYGON_WINDOW;
    }

    /* ----- The asks for the receipt ----- */

    /// @notice The first ask comes one waiting time after valid until, not a second earlier: before it, the receipt
    ///         may still be on its way.
    function test_sendTicket_asksOnlyAfterValidUntilPlusOneWaitingTime() public {
        vm.warp(firstAskDueAt - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, firstAskDueAt));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.warp(firstAskDueAt);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ReceiptAsked(id, 1);
        vm.prank(stranger);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(boundCompliance.ticketOf(id).asksForReceipt, 1);
        assertEq(boundCompliance.ticketOf(id).lastSentAt, firstAskDueAt);
    }

    /// @notice Each next ask is due one waiting time after the previous due time, never counted from a late ask: the
    ///         second at valid until plus two waiting times, the third at three.
    function test_sendTicket_asksAtFixedTimes_whenTheFirstAskComesLate() public {
        uint64 secondAskDueAt = validUntil + 2 * POLYGON_WINDOW;
        uint64 thirdAskDueAt = validUntil + 3 * POLYGON_WINDOW;
        uint64 lateFirstAsk = firstAskDueAt + 30 minutes;

        vm.warp(lateFirstAsk);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.warp(secondAskDueAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, secondAskDueAt));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        vm.warp(secondAskDueAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.warp(thirdAskDueAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, thirdAskDueAt));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        vm.warp(thirdAskDueAt);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ReceiptAsked(id, 3);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    /* ----- The cancel after an unanswered ask ----- */

    /// @notice An ask at T is answered at the latest at T plus one waiting time, so the cancel comes strictly after.
    function test_cancelTickets_reverts_before_theSeenValidUntilPlusOneWaitingTime() public {
        uint64 askedAt = firstAskDueAt;
        uint64 cancelDueAt = askedAt + POLYGON_WINDOW;
        vm.warp(askedAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.warp(cancelDueAt);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, cancelDueAt));
        boundCompliance.cancelTickets(_ids(id));

        vm.warp(cancelDueAt + 1);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketCancelled(id);
        vm.prank(stranger);
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.reservedOf(aliceSat), 0, "the reservation is back");
    }

    /// @notice The ticket keeps the waiting time of the chain that owes its receipt, the sender's, whatever the
    ///         receiver's chain waits: a ticket from Polygon to Optimism counts in Polygon's waiting time.
    function test_cancelTickets_usesTheWaitingTimeOfTheAwayChainThatOwesTheReceipt() public {
        _openEvmChain(token, OPTIMISM, address(_newReceiptBridge(OPTIMISM)));
        bytes memory bobOnOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));
        bytes32 crossChainId = _requestValidation(address(aliceIdentity), aliceSat, bobOnOptimism, 10, ASKED_MAX);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(crossChainId);
        assertEq(ticket.waitingTime, POLYGON_WINDOW, "the sender's chain's waiting time");

        uint64 askedAt = ticket.validUntil + POLYGON_WINDOW;
        vm.warp(askedAt);
        boundCompliance.sendTicket(crossChainId, polygon, bobOnOptimism, "");

        uint64 cancelableAt = askedAt + POLYGON_WINDOW + 1;
        assertLt(cancelableAt, askedAt + OPTIMISM_WINDOW, "before the receiver's chain's waiting time is over");
        vm.warp(cancelableAt);
        boundCompliance.cancelTickets(_ids(crossChainId));

        assertEq(uint8(boundCompliance.statusOf(crossChainId)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice The waiting time is kept on the ticket at its ask: raising the setting afterwards moves neither the
    ///         asks nor the cancel of a ticket already out.
    function test_cancelTime_IsFixedAtTheAsk_WhenTheWaitingTimeChangesLater() public {
        uint64 raisedWaitingTime = 3 hours;
        vm.prank(deployer);
        boundCompliance.setWaitingTime(polygon, raisedWaitingTime);
        assertEq(boundCompliance.ticketOf(id).waitingTime, POLYGON_WINDOW, "the ticket keeps its own");

        vm.warp(firstAskDueAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        vm.warp(firstAskDueAt + POLYGON_WINDOW + 1);
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice The block of the away chain holds its receipt waiting; once lifted, the cancel is refused in the very
    ///         block of the unblock while that receipt can be applied: the receipt goes first, never the cancel.
    function test_cancelTickets_cannotBeatTheWaitingReceipt_afterTheAwayChainIsUnblocked() public {
        vm.warp(firstAskDueAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(id, aliceSat, bobSat, 40);
        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));
        vm.warp(firstAskDueAt + 10 * POLYGON_WINDOW);

        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, id, polygon));
        boundCompliance.cancelTickets(_ids(id));

        vm.prank(stranger);
        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(id, 0), receipt);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 40);
    }

    /* ----- Still open answers ----- */

    /// @notice A still open answer from an older copy that moves valid until within the cap raises the seen valid
    ///         until and gives the ask back: the next ask is due one waiting time after the new valid until, and a
    ///         cancel needs a new ask.
    function test_receiveReceipt_givesTheAskBack_whenAStillOpenAnswerMovesValidUntil() public {
        uint64 seenValidUntil = validUntil + 10;
        uint64 nextAskDueAt = seenValidUntil + POLYGON_WINDOW;
        vm.warp(firstAskDueAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        uint256 index = _queueStillOpen(keccak256("a copy a home reorg dropped"), seenValidUntil);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketStillOpen(id, seenValidUntil);
        polygonBridge.relay(index);

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        assertEq(ticket.asksForReceipt, 0, "the ask is given back");
        assertEq(ticket.seenValidUntil, seenValidUntil);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, nextAskDueAt));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.warp(firstAskDueAt + POLYGON_WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, nextAskDueAt + POLYGON_WINDOW));
        boundCompliance.cancelTickets(_ids(id));

        uint64 newAskAt = uint64(block.timestamp);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        vm.warp(newAskAt + POLYGON_WINDOW + 1);
        boundCompliance.cancelTickets(_ids(id));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice On home's own ask block hash the away token holds home's copy, so a still open answer echoing another
    ///         valid until is a bad receipt: refused, and its chain blocked.
    function test_receiveReceipt_blocksTheChain_whenAStillOpenAnswerOnHomesOwnAskBlockCarriesAnotherValidUntil()
        public
    {
        bytes32 homesAskBlockHash = boundCompliance.ticketOf(id).askBlockHash;
        uint64 anotherValidUntil = validUntil + 10;
        uint256 index = _queueStillOpen(homesAskBlockHash, anotherValidUntil);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, polygon, 0, homesAskBlockHash);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonBridge.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(boundCompliance.ticketOf(id).seenValidUntil, 0, "the clock did not move");
    }

    /// @notice Past the cap, valid until plus the chain's full finality delivery plus its clock lead, no honest copy
    ///         can be valid: the still open answer counts as no answer and changes nothing.
    function test_receiveReceipt_ignoresAStillOpenAnswerBeyondTheCap() public {
        uint64 measuredDelivery = 1148;
        uint64 measuredLead = 30;
        _setDeliveryAndLead(measuredDelivery, measuredLead);
        uint64 beyondTheCap = validUntil + measuredDelivery + measuredLead + 1;
        vm.warp(firstAskDueAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        uint256 index = _queueStillOpen(keccak256("a copy a home reorg dropped"), beyondTheCap);

        vm.recordLogs();
        polygonBridge.relay(index);

        _assertNoStillOpenLogged(vm.getRecordedLogs());
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        assertEq(ticket.seenValidUntil, 0, "nothing seen");
        assertEq(ticket.asksForReceipt, 1, "the ask still stands");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "nothing blocked");
    }

    /// @notice At exactly the cap the still open answer is taken.
    function test_receiveReceipt_takesAStillOpenAnswer_atExactlyTheCap() public {
        uint64 measuredDelivery = 1148;
        uint64 measuredLead = 30;
        _setDeliveryAndLead(measuredDelivery, measuredLead);
        uint64 atTheCap = validUntil + measuredDelivery + measuredLead;
        uint256 index = _queueStillOpen(keccak256("a copy a home reorg dropped"), atTheCap);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketStillOpen(id, atTheCap);
        polygonBridge.relay(index);

        assertEq(boundCompliance.ticketOf(id).seenValidUntil, atTheCap);
    }

    /* ----- The validity window of the route ----- */

    /// @notice A chain with no ticket route takes every ticket on the receipt route, valid for that route's window;
    ///         with a trusted ticket bridge the ticket takes the ticket route and its shorter window.
    function test_askToMove_usesTheReceiptRouteWindow_whenNoTicketRouteIsSet() public {
        uint64 askedAt = uint64(block.timestamp);
        assertEq(validUntil, askedAt + VALIDITY_WINDOW, "the receipt route's window");
        assertTrue(boundCompliance.ticketOf(id).onReceiptRoute);

        ERC7786GatewayMock ticketBridge = _newTicketBridge(POLYGON, 3);
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);
        vm.prank(deployer);
        token.setTicketRoute(chainType, chainReference, address(ticketBridge));

        bytes32 onTheTicketRoute = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, ASKED_MAX);

        assertEq(boundCompliance.ticketOf(onTheTicketRoute).validUntil, askedAt + TICKET_ROUTE_WINDOW);
        assertFalse(boundCompliance.ticketOf(onTheTicketRoute).onReceiptRoute);
        assertEq(ticketBridge.queueLength(), 1, "sent on the ticket bridge");
    }

    /* ----- Helpers ----- */

    /// @dev Queues a still open answer for `id` from Polygon's away token, on the copy `askBlockHash` names.
    function _queueStillOpen(bytes32 askBlockHash, uint64 seenValidUntil) private returns (uint256) {
        MessageTypesLib.ReceiptMessage memory stillOpen = _settlementUnder(id, aliceSat, bobSat, 0, askBlockHash);
        stillOpen.seenValidUntil = seenValidUntil;
        stillOpen.answer = MessageTypesLib.ReceiptAnswer.StillOpen;
        return _liteSettles(polygonBridge, token, stillOpen);
    }

    /// @dev Measures Polygon again with another full finality delivery and clock lead, the rest as the suite has it.
    function _setDeliveryAndLead(uint64 fullFinalityDelivery, uint64 clockLead) private {
        ITickets.MeasuredTimes memory times = _measuredTimes();
        times.fullFinalityDelivery = fullFinalityDelivery;
        times.clockLead = clockLead;
        vm.prank(deployer);
        boundCompliance.setMeasuredTimes(polygon, times);
    }

    function _assertNoStillOpenLogged(Vm.Log[] memory logs) private pure {
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.TicketStillOpen.selector, "a still open answer was taken");
        }
    }

    function _ids(bytes32 one) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = one;
    }

}
