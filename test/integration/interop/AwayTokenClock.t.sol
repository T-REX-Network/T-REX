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
    uint8 internal constant TICKET_TYPE = uint8(MessageTypesLib.Message.TICKET);
    uint8 internal constant MOVE_OUT_TYPE = uint8(MessageTypesLib.Message.MOVE_OUT);
    uint8 internal constant BRING_HOME_TYPE = uint8(MessageTypesLib.Message.BRING_HOME);

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
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)), false);
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
        boundCompliance.sendTicket(ticketId, bobSat, "");
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
        boundCompliance.sendTicket(ticketId, bobSat, "");
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

    /// @notice A ticket that arrives at its valid until, as one would on a validity window sized below the full
    ///         finality delivery, is answered zero, and home ends it with nothing moved.
    function test_awayToken_answersZero_whenTheTicketArrivesAtItsValidUntil() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 50);
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil);
        _relayAll();

        assertEq(
            uint8(polygonLite.storedReceipt(TICKET_TYPE, ticketId).answer), uint8(MessageTypesLib.ReceiptAnswer.Expired)
        );
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

        vm.warp(block.timestamp + polygonLite.receiptResendWait());
        polygonLite.resendReceipt(TICKET_TYPE, ticketId);
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

    /// @notice Every away token starts with its limits on: a valid until bound, a resend wait and an answer window,
    ///         none of them zero, so a forged far valid until is ignored with no setting changed.
    function test_constructor_startsWithEveryLimitOn() public {
        SatelliteLiteMock freshAwayToken = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);

        assertEq(freshAwayToken.validUntilBound(), freshAwayToken.DEFAULT_VALID_UNTIL_BOUND(), "the bound is on");
        assertGt(freshAwayToken.receiptResendWait(), 0, "resends are spaced");
        assertGt(freshAwayToken.answerWindow(), 0, "answers are counted over a window");

        bytes32 forgedId = keccak256("a ticket home never wrote");
        uint64 farValidUntil = uint64(block.timestamp) + 10 days;
        _deliverToLite(_forgedCopy(forgedId, farValidUntil));
        assertFalse(polygonLite.known(forgedId), "the away token never holds it");
    }

    /* ----- The away token's own checks and limits ----- */

    /// @notice The kind is one of the terms the id hashes: home's copy carries a move's kind and its id is the id the
    ///  away token computes, while the same copy under another kind is refused.
    function test_awayToken_hashesTheKind_andRefusesTheCopyUnderAnotherKind() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 50);
        _relayAll();
        MessageTypesLib.TicketMessage memory heldCopy = polygonLite.ticketOf(ticketId);
        assertEq(heldCopy.kind, uint8(ITickets.TicketKind.MOVE), "home sends a move's kind");
        assertEq(polygonLite.idOfTheTerms(heldCopy), ticketId, "both sides hash the kind alike");

        MessageTypesLib.TicketMessage memory otherKind = heldCopy;
        otherKind.kind = uint8(ITickets.TicketKind.BRING_HOME);
        bytes32 idUnderTheOtherKind = polygonLite.idOfTheTerms(otherKind);
        uint256 otherKindIndex = _queueCopyForLite(otherKind);

        vm.expectRevert(
            abi.encodeWithSelector(SatelliteLiteMock.TicketIdMismatch.selector, ticketId, idUnderTheOtherKind)
        );
        polygonGateway.relay(otherKindIndex);
    }

    /// @notice A ticket whose id is not the id of its own terms is refused: nobody puts other terms under a known id.
    function test_awayToken_refusesATicket_whenItsIdIsNotTheIdOfItsTerms() public {
        bytes32 forgedId = keccak256("a ticket home never wrote");
        MessageTypesLib.TicketMessage memory forged = _forgedCopy(forgedId, uint64(block.timestamp) + VALIDITY_WINDOW);
        bytes memory recipient = InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite));
        vm.prank(address(token));
        polygonGateway.sendMessage(recipient, MessageTypesLib.encodeValidation(forged), new bytes[](0));

        bytes32 idOfTheTerms = polygonLite.idOfTheTerms(forged);
        uint256 forgedCopyIndex = _last();

        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.TicketIdMismatch.selector, forgedId, idOfTheTerms));
        polygonGateway.relay(forgedCopyIndex);
        assertFalse(polygonLite.known(forgedId), "never held");
    }

    /// @notice Later copies of an executed ticket get its stored receipt six times at most in one answer window; the
    ///  seventh is consumed with nothing sent. Once the window ended, the next copy is answered again.
    function test_awayToken_sendsNoAnswer_afterSixAnswersInOneWindow_andAnswersAgainInTheNextWindow() public {
        uint64 window = 1 days;
        polygonLite.setAnswerWindow(window);
        bytes32 ticketId = _askAndDeliver(10, 50);
        _execute(ticketId, 40);
        MessageTypesLib.TicketMessage memory heldCopy = polygonLite.ticketOf(ticketId);
        uint64 windowStartedAt = uint64(block.timestamp);
        uint8 answers = polygonLite.MAX_ANSWERS_PER_WINDOW();
        for (uint8 i = 0; i < answers; i++) {
            _deliverToLite(heldCopy);
        }
        uint256 seventhCopyIndex = _queueCopyForLite(heldCopy);
        uint256 queuedBeforeTheSeventh = polygonGateway.queueLength();

        vm.expectEmit(true, false, false, true, address(polygonLite));
        emit SatelliteLiteMock.AnswerNotSent(TICKET_TYPE, ticketId);
        polygonGateway.relay(seventhCopyIndex);
        assertEq(polygonGateway.queueLength(), queuedBeforeTheSeventh, "nothing sent");

        vm.warp(windowStartedAt + window);
        _deliverToLite(heldCopy);
        bytes memory storedReceipt = MessageTypesLib.encodeSettlement(polygonLite.storedReceipt(TICKET_TYPE, ticketId));
        assertEq(polygonGateway.queuedMessage(_last()).payload, storedReceipt, "answered in the next window");
    }

    /// @notice Still open answers are not counted: after more of them than the limit, home's ask for the executed
    ///  ticket's receipt still gets the stored receipt.
    function test_awayToken_answersWithTheStoredReceipt_afterMoreStillOpenAnswersThanTheLimit() public {
        polygonLite.setAnswerWindow(1 days);
        bytes32 ticketId = _askAndDeliver(10, 50);
        MessageTypesLib.TicketMessage memory heldCopy = polygonLite.ticketOf(ticketId);
        uint8 answers = polygonLite.MAX_ANSWERS_PER_WINDOW();
        for (uint8 i = 0; i <= answers; i++) {
            _deliverToLite(heldCopy);
        }
        (,, uint8 answersInWindow,) = polygonLite.receiptSends(TICKET_TYPE, ticketId);
        assertEq(answersInWindow, 0, "still open answers are not counted");
        _execute(ticketId, 40);

        _deliverToLite(heldCopy);

        bytes memory storedReceipt = MessageTypesLib.encodeSettlement(polygonLite.storedReceipt(TICKET_TYPE, ticketId));
        assertEq(polygonGateway.queuedMessage(_last()).payload, storedReceipt, "the stored receipt is sent again");
    }

    /// @notice Anyone may ask for a stored receipt again three times, each one the same set wait after the last send.
    function test_resendReceipt_waitsTheSameWaitEachTime_andStopsAfterThreeResends() public {
        uint64 wait = 10 minutes;
        polygonLite.setReceiptResendWait(wait);
        bytes32 ticketId = _askAndDeliver(10, 50);
        _execute(ticketId, 40);
        uint64 sentAt = uint64(block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                SatelliteLiteMock.ReceiptResendTooSoon.selector, TICKET_TYPE, ticketId, sentAt + wait
            )
        );
        polygonLite.resendReceipt(TICKET_TYPE, ticketId);
        vm.warp(sentAt + wait);
        polygonLite.resendReceipt(TICKET_TYPE, ticketId);

        uint64 secondAllowedAt = sentAt + 2 * wait;
        vm.warp(secondAllowedAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SatelliteLiteMock.ReceiptResendTooSoon.selector, TICKET_TYPE, ticketId, secondAllowedAt
            )
        );
        polygonLite.resendReceipt(TICKET_TYPE, ticketId);
        vm.warp(secondAllowedAt);
        polygonLite.resendReceipt(TICKET_TYPE, ticketId);
        vm.warp(secondAllowedAt + wait);
        polygonLite.resendReceipt(TICKET_TYPE, ticketId);

        vm.warp(block.timestamp + 100 days);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.NoReceiptResendLeft.selector, TICKET_TYPE, ticketId));
        polygonLite.resendReceipt(TICKET_TYPE, ticketId);
    }

    /// @notice Neither rate can be turned off: a wait or a window of zero is refused.
    function test_setReceiptResendWait_and_setAnswerWindow_revert_when_setToZero() public {
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        polygonLite.setReceiptResendWait(0);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        polygonLite.setAnswerWindow(0);
    }

    /// @notice A move out's and a bring home's receipt under one half key are two receipts: each is stored, read and
    ///  sent again under its own message type.
    function test_resendReceipt_keepsAMoveOutAndABringHomeOfOneHalfKeyApart() public {
        bytes32 ticketId = keccak256("one half key, two types");
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, 1);
        uint64 validUntil = uint64(block.timestamp) + 1 hours;
        _deliverHalfToLite(
            MessageTypesLib.encode(
                MessageTypesLib.Message.MOVE_OUT,
                abi.encode(
                    MessageTypesLib.MoveOutMessage({
                        ticketId: ticketId, half: 1, toWallet: bobSat, amount: 7, validUntil: validUntil
                    })
                )
            )
        );
        _deliverHalfToLite(
            MessageTypesLib.encode(
                MessageTypesLib.Message.BRING_HOME,
                abi.encode(
                    MessageTypesLib.BringHomeMessage({
                        ticketId: ticketId, half: 1, wallet: bobSat, amount: 3, validUntil: validUntil
                    })
                )
            )
        );

        assertEq(polygonLite.storedReceipt(MOVE_OUT_TYPE, halfKey).amount, 7, "the move out minted 7");
        assertEq(polygonLite.storedReceipt(BRING_HOME_TYPE, halfKey).amount, 3, "the bring home burned 3");
        vm.warp(block.timestamp + polygonLite.receiptResendWait());
        polygonLite.resendReceipt(BRING_HOME_TYPE, halfKey);
        bytes memory bringHomeReceipt =
            MessageTypesLib.encodeSettlement(polygonLite.storedReceipt(BRING_HOME_TYPE, halfKey));
        assertEq(polygonGateway.queuedMessage(_last()).payload, bringHomeReceipt, "the bring home's receipt again");
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
            kind: uint8(ITickets.TicketKind.MOVE),
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

    /// @dev Queues a ticket copy for Polygon's away token, authored by home's token, undelivered.
    /// @return index its place in the gateway's queue
    function _queueCopyForLite(MessageTypesLib.TicketMessage memory copy) private returns (uint256 index) {
        bytes memory recipient = InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite));
        vm.prank(address(token));
        polygonGateway.sendMessage(recipient, MessageTypesLib.encodeValidation(copy), new bytes[](0));
        index = _last();
    }

    /// @dev Delivers an encoded half to Polygon's away token, authored by home's token.
    function _deliverHalfToLite(bytes memory payload) private {
        bytes memory recipient = InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite));
        vm.prank(address(token));
        polygonGateway.sendMessage(recipient, payload, new bytes[](0));
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
