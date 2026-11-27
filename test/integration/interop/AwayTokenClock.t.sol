// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev The clock of a ticket against an away token that follows `docs/satellite-lite.md`: it executes strictly
///      before valid until, answers a first copy that arrives late with a zero receipt, answers an ask with what it
///      stored, and ignores a copy whose valid until is too far ahead. Every receipt here is the away token's own.
contract AwayTokenClockTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;
    uint256 internal constant MOVED_OUT = 500;

    ERC7786GatewayMock internal polygonGateway;
    SatelliteLiteMock internal polygonLite;
    Account internal aliceOnPolygon;
    bytes internal aliceSat;
    bytes internal bobSat;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)));
        _openEvmChain(token, POLYGON, address(polygonGateway));

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();

        bytes memory aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(alice);
        boundCompliance.askToMove(aliceHome, aliceSat, MOVED_OUT, MOVED_OUT, "", _salt());
        _relayAll();
        assertEq(token.awayBalanceOf(aliceSat), MOVED_OUT, "the move out landed");
    }

    /* ----- No cancel without an unanswered ask ----- */

    /// @notice The away token executed the ticket and its receipt was lost. With no ask for the receipt sent, nobody
    ///         cancels it, neither one waiting time after valid until nor two: the cancel would free a reservation
    ///         whose move already happened. The ask then brings the stored receipt home.
    function test_cancelTickets_reverts_when_noAskForTheReceiptWentUnanswered() public {
        bytes32 ticketId = _askAndDeliver(10, 50);
        _execute(ticketId, 40);
        polygonGateway.drop(_last());
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        uint64 earliestCancel = ticket.validUntil + 2 * POLYGON_WINDOW;

        vm.warp(ticket.validUntil + POLYGON_WINDOW + 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, ticketId, earliestCancel));
        boundCompliance.cancelTickets(_ids(ticketId));

        vm.warp(earliestCancel + 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, ticketId, earliestCancel));
        boundCompliance.cancelTickets(_ids(ticketId));
        assertEq(token.reservedOf(aliceSat), 50, "the reservation stands");

        vm.prank(stranger);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        _relayAll();

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 40);
        assertEq(polygonLite.balanceOf(bobSat), 40, "home and the away token agree");
    }

    /// @notice The answer to an ask that lands in the very block the cancel becomes due is applied first, and the
    ///         cancel then finds the ticket done.
    function test_cancelTickets_losesToTheAnswer_thatLandsInTheCancelsBlock() public {
        bytes32 ticketId = _askAndDeliver(10, 50);
        _execute(ticketId, 40);
        polygonGateway.drop(_last());
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        uint64 askedAt = ticket.validUntil + POLYGON_WINDOW;
        vm.warp(askedAt);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        polygonGateway.relay(_last());

        vm.warp(askedAt + POLYGON_WINDOW + 1);
        polygonGateway.relay(_last());
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, ticketId, uint8(ITickets.TicketStatus.Done))
        );
        boundCompliance.cancelTickets(_ids(ticketId));

        assertEq(token.awayBalanceOf(bobSat), 40);
    }

    /* ----- Strictly before valid until ----- */

    /// @notice With the receipt route's window one second above its floor, a holder executing at valid until minus
    ///         one is served, and one executing at valid until is refused by the away token.
    function test_awayToken_executesAtValidUntilMinusOne_andRefusesAtValidUntil() public {
        uint64 receiptRouteFloor = 20 minutes + 30 seconds;
        vm.prank(deployer);
        boundCompliance.setValidityWindows(TICKET_ROUTE_WINDOW, receiptRouteFloor + 1);
        bytes32 servedTicket = _askAndDeliver(10, 50);
        bytes32 lateTicket = _askAndDeliver(10, 50);
        uint64 validUntil = boundCompliance.ticketOf(servedTicket).validUntil;

        vm.warp(validUntil - 1);
        _execute(servedTicket, 40);
        _relayAll();
        assertEq(uint8(boundCompliance.statusOf(servedTicket)), uint8(ITickets.TicketStatus.Done));

        vm.warp(validUntil);
        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.ValidationExpired.selector, lateTicket));
        polygonLite.execute(lateTicket, 40);
    }

    /// @notice A window shorter than a full finality delivery plus the clock lead is refused, since a ticket on the
    ///         receipt route would arrive expired; a ticket that still arrives at its valid until is answered zero,
    ///         and home ends it with nothing moved.
    function test_awayToken_answersZero_whenTheTicketArrivesAtItsValidUntil() public {
        uint64 fifteenMinutes = 15 minutes;
        uint64 receiptRouteFloor = 20 minutes + 30 seconds;
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidityWindowOutOfRange.selector, fifteenMinutes, receiptRouteFloor, 1 days
            )
        );
        boundCompliance.setValidityWindows(fifteenMinutes, fifteenMinutes);

        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 50);
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil);
        _relayAll();

        assertEq(uint8(polygonLite.storedReceipt(ticketId, 0).answer), uint8(MessageTypesLib.ReceiptAnswer.Expired));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(ticketId).moved, 0);
        assertEq(token.reservedOf(aliceSat), 0, "the reservation is back");
    }

    /// @notice A ticket the away token refused at its valid until stays refused: the holder's late execution is
    ///         refused there, and the stored zero receipt sent again is a duplicate at home.
    function test_receiveReceipt_changesNothing_whenATicketRefusedAfterValidUntilIsExecutedLate() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 50);
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil);
        _relayAll();

        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.ValidationExpired.selector, ticketId));
        polygonLite.execute(ticketId, 40);

        polygonLite.resendReceipt(ticketId, 0);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(ticketId, polygon);
        polygonGateway.relay(_last());

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(aliceSat), MOVED_OUT, "nothing moved at home");
        assertEq(polygonLite.balanceOf(aliceSat), MOVED_OUT, "nor on the away chain");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /* ----- A valid until too far ahead ----- */

    /// @notice A forged copy whose valid until is far ahead is ignored by the away token's bound, and a still open
    ///         answer carrying such a valid until is ignored by home's cap: the ticket's clock does not move.
    function test_awayToken_ignoresAForgedFarValidUntil_andHomeIgnoresItsStillOpenAnswer() public {
        uint64 lagBudget = 1 minutes;
        polygonLite.setValidUntilBound(VALIDITY_WINDOW + lagBudget);
        bytes32 ticketId = _askAndDeliver(10, 50);
        uint64 farValidUntil = uint64(block.timestamp) + 10 days;

        bytes32 forgedId = keccak256("a ticket home never wrote");
        _deliverToLite(_forgedCopy(forgedId, farValidUntil));
        assertFalse(polygonLite.known(forgedId), "the away token never holds it");

        MessageTypesLib.ReceiptMessage memory stillOpen =
            _settlementUnder(ticketId, aliceSat, bobSat, 0, keccak256("a copy home never sent"));
        stillOpen.seenValidUntil = farValidUntil;
        stillOpen.answer = MessageTypesLib.ReceiptAnswer.StillOpen;
        bytes memory payload = MessageTypesLib.encodeSettlement(stillOpen);
        polygonGateway.relay(_queue(polygonGateway, address(polygonLite), token, payload));

        assertEq(boundCompliance.ticketOf(ticketId).seenValidUntil, 0, "home's cap ignored it");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /* ----- Helpers ----- */

    /// @dev Alice asks to move to Bob on Polygon, and the ticket reaches the away token.
    function _askAndDeliver(uint256 amountMin, uint256 amountMax) private returns (bytes32 ticketId) {
        ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, amountMin, amountMax);
        _relayAll();
    }

    function _execute(bytes32 ticketId, uint256 amount) private {
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(ticketId, amount);
    }

    /// @dev A ticket copy for `forgedId` authored as home's token, valid until `validUntil`.
    function _forgedCopy(bytes32 forgedId, uint64 validUntil)
        private
        view
        returns (MessageTypesLib.TicketMessage memory)
    {
        return MessageTypesLib.TicketMessage({
            ticketId: forgedId,
            salt: bytes32(0),
            from: aliceSat,
            to: bobSat,
            spender: "",
            amountMin: 1,
            amountMax: MOVED_OUT,
            requestedMax: MOVED_OUT,
            token: address(token),
            validUntil: validUntil,
            askBlockHash: TicketLib.askBlockHashOf(MOVED_OUT, validUntil)
        });
    }

    /// @dev Delivers a ticket copy to Polygon's away token, authored by home's token as the gateway attributes it.
    function _deliverToLite(MessageTypesLib.TicketMessage memory copy) private {
        bytes memory recipient = InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite));
        vm.prank(address(token));
        polygonGateway.sendMessage(recipient, MessageTypesLib.encodeValidation(copy), new bytes[](0));
        polygonGateway.relay(_last());
    }

    /// @dev Delivers every queued entry not yet delivered or dropped, in order, the ones a delivery queues included.
    function _relayAll() private {
        for (uint256 i = 0; i < polygonGateway.queueLength(); i++) {
            ERC7786GatewayMock.QueuedMessage memory message = polygonGateway.queuedMessage(i);
            if (message.deliveries == 0 && !message.dropped) polygonGateway.relay(i);
        }
    }

    function _last() private view returns (uint256) {
        return polygonGateway.queueLength() - 1;
    }

    function _ids(bytes32 one) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = one;
    }

}
