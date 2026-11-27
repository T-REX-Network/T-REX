// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The route of a ticket is chosen at its ask and written on it. With a trusted ticket bridge, a ticket takes the
///      ticket route, before home's finality, unless it is above the chain's per-ticket cap or would carry the ticket
///      route above its per-window cap in the current window of one waiting time: then it takes the receipt route, at
///      full finality, with that route's longer validity window. The caps bound what a dropped home block can cost.
contract TicketRouteCapsTest is InteropSuiteTest {

    uint64 internal constant TICKET_DEPTH = 3;
    uint256 internal constant ALICE_AWAY_BALANCE = 1000;
    uint256 internal constant CAP = 10;

    ERC7786GatewayMock internal receiptBridge;
    ERC7786GatewayMock internal ticketBridge;
    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        receiptBridge = _newReceiptBridge(POLYGON);
        ticketBridge = _newTicketBridge(POLYGON, TICKET_DEPTH);
        _openEvmChain(token, POLYGON, address(receiptBridge));
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);
        vm.prank(deployer);
        token.setTicketRoute(chainType, chainReference, address(ticketBridge));

        aliceSat =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        vm.prank(agent);
        token.unpause();
    }

    /// @notice Above the per-ticket cap a ticket takes the receipt route with the receipt route's window; at the cap
    ///         it takes the ticket bridge with the ticket route's window.
    function test_askToMove_sendsOnTheReceiptRoute_whenTheTicketIsAboveTheExposureCap() public {
        _setCaps(CAP, type(uint256).max);
        uint64 askedAt = uint64(block.timestamp);

        bytes32 aboveTheCap = _ask(CAP + 1);
        assertEq(receiptBridge.queueLength(), 1, "the receipt route recorded the send");
        assertEq(ticketBridge.queueLength(), 0);
        assertTrue(boundCompliance.ticketOf(aboveTheCap).onReceiptRoute);
        assertEq(boundCompliance.ticketOf(aboveTheCap).validUntil, askedAt + VALIDITY_WINDOW);

        bytes32 atTheCap = _ask(CAP);
        assertEq(ticketBridge.queueLength(), 1, "the ticket bridge recorded the send");
        assertFalse(boundCompliance.ticketOf(atTheCap).onReceiptRoute);
        assertEq(boundCompliance.ticketOf(atTheCap).validUntil, askedAt + TICKET_ROUTE_WINDOW);
    }

    /// @notice In one window of one waiting time the ticket route carries at most the per-window cap: 6 takes it, 5
    ///         would pass the cap and takes the receipt route, 4 fills it exactly; the next window opens it again.
    function test_askToMove_sendsOnTheReceiptRoute_whenTheWindowWouldPassThePerWindowCap() public {
        _setCaps(CAP, CAP);
        uint64 windowStart = uint64(block.timestamp);

        assertFalse(boundCompliance.ticketOf(_ask(6)).onReceiptRoute, "6 on the ticket route");
        assertTrue(boundCompliance.ticketOf(_ask(5)).onReceiptRoute, "6 + 5 passes the cap");
        assertFalse(boundCompliance.ticketOf(_ask(4)).onReceiptRoute, "6 + 4 is the cap, equality allowed");
        assertEq(ticketBridge.queueLength(), 2);
        assertEq(receiptBridge.queueLength(), 1);

        vm.warp(windowStart + POLYGON_WINDOW);
        assertFalse(boundCompliance.ticketOf(_ask(CAP)).onReceiptRoute, "a new window carries the whole cap");
    }

    /// @notice A window starts at the first ticket after the last one ended, so across one edge the ticket route
    ///         carries at most twice the per-window cap in two seconds, and never more: an eleventh unit in either
    ///         window takes the receipt route.
    function test_ticketRoute_carriesAtMostTwiceThePerWindowCap_acrossAWindowEdge() public {
        _setCaps(CAP, CAP);
        uint64 windowStart = uint64(block.timestamp);
        uint256 opening = 1;
        assertFalse(boundCompliance.ticketOf(_ask(opening)).onReceiptRoute);

        vm.warp(windowStart + POLYGON_WINDOW - 1);
        uint256 lastSecondOfTheFirstWindow = CAP - opening;
        assertFalse(boundCompliance.ticketOf(_ask(lastSecondOfTheFirstWindow)).onReceiptRoute);
        assertTrue(boundCompliance.ticketOf(_ask(1)).onReceiptRoute, "an eleventh unit in the first window");

        vm.warp(windowStart + POLYGON_WINDOW);
        assertFalse(boundCompliance.ticketOf(_ask(CAP)).onReceiptRoute);
        assertTrue(boundCompliance.ticketOf(_ask(1)).onReceiptRoute, "an eleventh unit in the second window");

        uint256 carriedOnTheTicketRouteAcrossTheEdge = lastSecondOfTheFirstWindow + CAP;
        assertLe(carriedOnTheTicketRouteAcrossTheEdge, 2 * CAP);
        assertEq(ticketBridge.queueLength(), 3);
        assertEq(receiptBridge.queueLength(), 2);
    }

    /// @notice Caps of zero send every ticket on the receipt route, and a ticket on the receipt route is not counted
    ///         in the ticket route's window: once caps are raised, the whole cap is free.
    function test_askToMove_sendsEveryTicketOnTheReceiptRoute_whenThePerTicketCapIsZero() public {
        _setCaps(0, 0);
        assertTrue(boundCompliance.ticketOf(_ask(CAP)).onReceiptRoute);
        assertTrue(boundCompliance.ticketOf(_ask(1)).onReceiptRoute);
        assertEq(ticketBridge.queueLength(), 0);

        _setCaps(CAP, CAP);
        assertFalse(boundCompliance.ticketOf(_ask(CAP)).onReceiptRoute, "nothing was counted on the ticket route");
    }

    /// @notice A ticket bridge distrusted after the ask no longer carries the ticket's asks: they fall back to the
    ///         receipt bridge, which only adds finality. The route written on the ticket is not chosen again.
    function test_sendTicket_asksOnTheReceiptBridge_whenTheTicketBridgeIsDistrustedAfterTheAsk() public {
        bytes32 ticketId = _ask(CAP);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        assertFalse(ticket.onReceiptRoute);
        trustedGatewayRegistry.distrustBridge(address(ticketBridge));

        vm.warp(ticket.validUntil + ticket.waitingTime);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");

        assertEq(ticketBridge.queueLength(), 1, "only the first send went on the ticket bridge");
        assertEq(receiptBridge.queueLength(), 1, "the ask went on the receipt bridge");
        assertFalse(boundCompliance.ticketOf(ticketId).onReceiptRoute, "written at the ask, never chosen again");
    }

    /// @notice Bob may hold 150. A ticket of 100 on the ticket route reaches the away token and is executed, then a
    ///         home reorg drops its ask; a new ask of 150 is issued against the room the dropped one no longer holds
    ///         and executed too, so Bob holds 250 on the away chain. Home keeps its records right: the dropped
    ///         ticket's receipt answers no ticket home has, so its 100 goes on hold under Alice and Bob's position
    ///         stays at the 150 the rule allowed.
    function test_receiveReceipt_keepsHomesRecordsRight_whenADroppedTicketWasExecutedAndANewOneFilledTheCap() public {
        uint256 bobsCap = 150;
        uint256 droppedAmount = 100;
        _bindACapOnBob(bobsCap);
        bytes32 droppedSalt = _salt();
        uint256 beforeTheReorg = vm.snapshotState();
        vm.prank(address(aliceIdentity));
        bytes32 droppedId = boundCompliance.askToMove(aliceSat, bobSat, 1, droppedAmount, "", droppedSalt);
        ITickets.Ticket memory droppedCopy = boundCompliance.ticketOf(droppedId);
        vm.revertToState(beforeTheReorg);

        bytes32 keptId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 1, 200);
        assertEq(boundCompliance.ticketOf(keptId).amountMax, bobsCap, "the room the dropped ask no longer holds");
        receiptBridge.relay(_liteSettles(receiptBridge, token, _settlement(keptId, aliceSat, bobSat, bobsCap)));

        MessageTypesLib.ReceiptMessage memory droppedReceipt = MessageTypesLib.ReceiptMessage({
            ticketId: droppedId,
            from: aliceSat,
            to: bobSat,
            amount: droppedAmount,
            askBlockHash: droppedCopy.askBlockHash,
            seenMax: droppedCopy.amountMax,
            seenValidUntil: droppedCopy.validUntil,
            half: 0,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
        uint256 index = _liteSettles(receiptBridge, token, droppedReceipt);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(droppedId, polygon, aliceSat, bobSat, droppedAmount);
        receiptBridge.relay(index);

        assertEq(IComplianceLedger(address(boundCompliance)).positionOf(address(bobIdentity)), bobsCap);
        assertEq(token.onHoldOf(droppedId), droppedAmount, "on hold under Alice, not credited to Bob");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "an honest chain is not blocked");
    }

    /* ----- Helpers ----- */

    function _bindACapOnBob(uint256 cap) private {
        CappedRecipientModule capRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(CappedRecipientModule.setCap, (cap));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(capRule), settings);
    }

    function _ask(uint256 amountMax) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, 1, amountMax);
    }

    function _setCaps(uint256 perTicketCap, uint256 perWindowCap) private {
        vm.prank(deployer);
        boundCompliance.setTicketLimits(polygon, perTicketCap, perWindowCap);
    }

}
