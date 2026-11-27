// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { HoldsSuiteTest } from "test/integration/helpers/HoldsSuiteTest.sol";

/// @dev Close by hand: an away chain whose receipt route is closed, or whose bridge is distrusted, delivers no
///      receipt, and its silence cannot tell a dead chain from a lost message. Home decides from a read of that
///      chain's own state: a stored receipt is applied as if it had arrived; without one, the away chain's own clock
///      must be past every valid until the half or the ticket can carry there.
contract CloseByHandTest is HoldsSuiteTest {

    uint256 internal constant EIGHT = 8;
    uint256 internal constant FOUR = 4;
    uint256 internal constant TWO = 2;
    uint64 internal constant REORG_SLOT_SHIFT = 1 minutes;

    address internal stranger = makeAddr("stranger");
    address internal approver = makeAddr("approver");

    /* ----- A stored receipt in the read ----- */

    function test_closeByHand_appliesTheStoredReceipt_whenTheAwayChainExecutedTheHalf() public {
        bytes32 ticketId = _moveToBobOnOptimismUntilTheMoveOutIsOut(EIGHT);
        _relayNext(optimismGateway); // optimism mints 8 to bob
        // The receipt optimism sent back is lost.
        optimismGateway.drop(optimismGateway.queueLength() - 1);
        _closeEvmChain(token, OPTIMISM);
        MessageTypesLib.ReceiptMessage memory stored =
            optimismLite.storedReceipt(ticketId, boundCompliance.ticketOf(ticketId).half);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(ticketId, optimism, EIGHT);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ClosedByHand(ticketId, 0, uint64(block.number), uint64(block.timestamp));
        _closeByHand(ticketId, bobOptimismSat, _readingWith(stored));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the move is finished");
        assertEq(token.awayBalanceOf(bobOptimismSat), EIGHT, "bob is counted what optimism minted");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - EIGHT, "nothing returned to alice");
        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "the honest chain is not blocked");
    }

    /// @notice The receiving chain minted and its receipt is lost: however late the read, home never gives the money
    ///         back to the sender too, so the tokens never exist twice.
    function test_closeByHand_doesNotReturnWhatTheOtherAwayChainMinted() public {
        bytes32 ticketId = _moveToBobOnOptimismUntilTheMoveOutIsOut(TWO);
        _relayNext(optimismGateway);
        optimismGateway.drop(optimismGateway.queueLength() - 1);
        _closeEvmChain(token, OPTIMISM);
        ITickets.Ticket memory held = boundCompliance.ticketOf(ticketId);
        ITickets.AwayChainReading memory reading = _readingWith(optimismLite.storedReceipt(ticketId, held.half));
        reading.awayClockTime = held.secondHalfValidUntil + 1 days;

        _closeByHand(ticketId, bobOptimismSat, reading);

        assertEq(token.awayBalanceOf(aliceSat), polygonLite.balanceOf(aliceSat), "alice: home and polygon agree");
        assertEq(
            token.awayBalanceOf(bobOptimismSat), optimismLite.balanceOf(bobOptimismSat), "bob: home and optimism agree"
        );
        assertEq(
            polygonLite.balanceOf(aliceSat) + optimismLite.balanceOf(bobOptimismSat),
            ALICE_AWAY_BALANCE,
            "the tokens exist once"
        );
    }

    /// @notice A receipt that waits at home under the half says the read is wrong when it reads nothing: the read
    ///         again, with that receipt, applies it.
    function test_closeByHand_appliesAWaitingReceiptInsteadOfReturning() public {
        bytes32 ticketId = _moveToBobOnOptimismUntilTheMoveOutIsOut(EIGHT);
        uint8 half = boundCompliance.ticketOf(ticketId).half;
        vm.prank(agent);
        boundCompliance.blockAwayChain(optimism);
        _relayAll(optimismGateway); // optimism mints; its receipt waits under the block
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, half);
        assertTrue(boundCompliance.waitingReceiptOf(halfKey).bodyHash != bytes32(0), "the receipt waits");
        vm.prank(agent);
        boundCompliance.unblockAwayChain(optimism);
        _closeEvmChain(token, OPTIMISM);
        uint64 pastTheHalf = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, ticketId, optimism));
        boundCompliance.closeByHand(ticketId, bobOptimismSat, _reading(pastTheHalf));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(halfKey, optimism);
        _closeByHand(ticketId, bobOptimismSat, _readingWith(optimismLite.storedReceipt(ticketId, half)));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "applied, nothing returned");
        assertEq(token.awayBalanceOf(bobOptimismSat), EIGHT);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - EIGHT);
    }

    function test_closeByHand_recordsAStoredReceiptForAnIdWithNoRecord() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.drop(receiptIndex);
        _closeEvmChain(token, POLYGON);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(ticketId, polygon, aliceSat, bobSat, FOUR);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ClosedByHand(ticketId, 0, uint64(block.number), uint64(block.timestamp));
        _closeByHand(ticketId, bobSat, _readingWith(polygonLite.storedReceipt(ticketId, 0)));

        _assertStatus(ticketId, ITickets.TicketStatus.OnHold, "booked on hold");
        assertEq(token.onHoldOf(ticketId), FOUR);
        assertEq(boundCompliance.uncountedCreditOf(bobSat), FOUR);
    }

    /// @notice A bring home burned in time and its receipt is stuck behind the closed route: the stored receipt
    ///         mints at home.
    function test_closeByHand_mintsAtHome_whenTheBringHomeBurnedAndItsReceiptIsStuck() public {
        uint256 broughtHome = 3;
        vm.prank(agent);
        bytes32 ticketId = boundCompliance.bringHome(aliceSat, broughtHome, alice, _salt());
        _relayNext(polygonGateway); // polygon burns 3 on alice
        polygonGateway.drop(polygonGateway.queueLength() - 1);
        _closeEvmChain(token, POLYGON);

        _closeByHand(ticketId, aliceHome, _readingWith(polygonLite.storedReceipt(ticketId, 1)));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "brought home");
        assertEq(token.balanceOf(alice), broughtHome, "minted at home");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - broughtHome);
        _assertHomeAgreesWithPolygon();
    }

    /// @notice The receipt route stays open but its bridge is distrusted: no receipt can land, so the chain is read.
    function test_closeByHand_appliesTheStoredReceipt_whenTheReceiptBridgeIsDistrusted() public {
        bytes32 ticketId = _executedTicketWhoseReceiptIsLost(FOUR);
        trustedGatewayRegistry.distrustBridge(address(polygonGateway));
        assertFalse(token.isChainOpen(polygon), "a distrusted bridge closes the chain");

        _closeByHand(ticketId, bobSat, _readingWith(polygonLite.storedReceipt(ticketId, 0)));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "applied");
        assertEq(token.awayBalanceOf(bobSat), FOUR);
    }

    /* ----- No stored receipt: the away chain's clock ----- */

    function test_closeByHand_reverts_when_theAwayChainClockIsBeforeTheHalfValidUntil() public {
        bytes32 ticketId = _moveToBobOnOptimismUntilTheMoveOutIsOut(EIGHT);
        optimismGateway.drop(_nextUndelivered(optimismGateway));
        _closeEvmChain(token, OPTIMISM);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.AwayClockBeforeValidUntil.selector, ticketId, validUntil - 1, validUntil)
        );
        boundCompliance.closeByHand(ticketId, bobOptimismSat, _reading(validUntil - 1));

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ClosedByHand(ticketId, EIGHT, uint64(block.number), validUntil);
        _closeByHand(ticketId, bobOptimismSat, _reading(validUntil));
        _relayAll(polygonGateway); // the new move out mints the 8 back to alice

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "returned");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        assertEq(optimismLite.balanceOf(bobOptimismSat), 0, "optimism never minted");
        _assertHomeAgreesWithPolygon();
    }

    /// @notice Home's own clock proves nothing about the closed chain: days later at home, a read whose clock is
    ///         before the half's valid until is still refused.
    function test_closeByHand_readsTheAwayClock_notHomes() public {
        bytes32 ticketId = _moveToBobOnOptimismUntilTheMoveOutIsOut(EIGHT);
        _closeEvmChain(token, OPTIMISM);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;
        vm.warp(validUntil + 3 days);
        uint64 laggingAwayClock = validUntil - 1 hours;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.AwayClockBeforeValidUntil.selector, ticketId, laggingAwayClock, validUntil)
        );
        boundCompliance.closeByHand(ticketId, bobOptimismSat, _reading(laggingAwayClock));
    }

    /// @notice After close by hand returned the money, the old move out reaches the receiving chain late: that chain
    ///         refuses it past its valid until, and its zero answer for the old half changes nothing at home.
    function test_closeByHand_isSafe_whenTheOldMoveOutIsExecutedLate() public {
        bytes32 ticketId = _moveToBobOnOptimismUntilTheMoveOutIsOut(EIGHT);
        uint256 oldMoveOut = _nextUndelivered(optimismGateway);
        _closeEvmChain(token, OPTIMISM);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;
        _closeByHand(ticketId, bobOptimismSat, _reading(validUntil));
        _relayAll(polygonGateway);

        vm.warp(validUntil);
        optimismGateway.relay(oldMoveOut);
        assertEq(optimismLite.balanceOf(bobOptimismSat), 0, "refused past its valid until");

        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        _relayAll(optimismGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "still returned");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        assertEq(token.awayBalanceOf(bobOptimismSat), 0);
        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "the honest late answer blocks nobody");
    }

    /// @notice After close by hand ended an open bring home with nothing moved, its half reaches the closed chain
    ///         late: that chain refuses it past its valid until, and its zero answer changes nothing at home.
    function test_closeByHand_isSafe_whenTheOldBringHomeArrivesLate() public {
        uint256 broughtHome = 3;
        vm.prank(agent);
        bytes32 ticketId = boundCompliance.bringHome(aliceSat, broughtHome, alice, _salt());
        uint256 oldBringHome = _nextUndelivered(polygonGateway);
        _closeEvmChain(token, POLYGON);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;
        _closeByHand(ticketId, aliceHome, _reading(validUntil));

        vm.warp(validUntil);
        polygonGateway.relay(oldBringHome);
        assertEq(polygonLite.balanceOf(aliceSat), ALICE_AWAY_BALANCE, "refused past its valid until");

        _openEvmChain(token, POLYGON, address(polygonGateway));
        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "still ended with nothing moved");
        assertEq(token.balanceOf(alice), 0, "nothing minted at home");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest late answer blocks nobody");
    }

    /// @notice A cancel's bring home on the receiver is out when the chain closes; close by hand applies the move
    ///         inside that chain. The bring home reaches the chain late, and its zero answer changes nothing at home.
    function test_closeByHand_isSafe_whenTheCancelsBringHomeArrivesLate() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        boundCompliance.cancelHold(ticketId, bobSat);
        uint256 oldBringHome = _nextUndelivered(polygonGateway);
        _closeEvmChain(token, POLYGON);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;
        _closeByHand(ticketId, bobSat, _reading(validUntil));
        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the move inside polygon is applied");

        vm.warp(validUntil);
        polygonGateway.relay(oldBringHome);
        assertEq(polygonLite.balanceOf(bobSat), FOUR, "refused past its valid until");

        _openEvmChain(token, POLYGON, address(polygonGateway));
        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "still applied");
        assertEq(token.awayBalanceOf(bobSat), FOUR, "bob is counted once");
        assertEq(boundCompliance.uncountedCreditOf(bobSat), 0, "no credit given back twice");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest late answer blocks nobody");
        _assertHomeAgreesWithPolygon();
    }

    function test_cancelTickets_readsTheClosedChain_whenTheReceiptRouteIsClosed() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _relayAll(polygonGateway);
        _askAndLetTheAskGoUnanswered(ticketId, bobSat, "");
        _closeEvmChain(token, POLYGON);
        uint64 latestValidUntil = boundCompliance.ticketOf(ticketId).validUntil + REORG_SLOT_SHIFT;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ticketId;

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.cancelTickets(ids);

        ITickets.AwayChainReading memory tooEarly = _readingOfTheTicket(ticketId, latestValidUntil - 1);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.AwayClockBeforeValidUntil.selector, ticketId, latestValidUntil - 1, latestValidUntil
            )
        );
        boundCompliance.closeByHand(ticketId, bobSat, tooEarly);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketCancelled(ticketId);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ClosedByHand(ticketId, 0, uint64(block.number), latestValidUntil);
        _closeByHand(ticketId, bobSat, _readingOfTheTicket(ticketId, latestValidUntil));

        _assertStatus(ticketId, ITickets.TicketStatus.Cancelled, "cancelled on the away clock");
        assertEq(token.reservedOf(aliceSat), 0, "the reservation is back");
    }

    /// @notice A copy from a home block a reorg dropped may be valid up to one reorg slot shift later than home's:
    ///         a read at home's own valid until does not cancel.
    function test_closeByHand_waitsOutTheReorgSlotShift() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _relayAll(polygonGateway);
        _closeEvmChain(token, POLYGON);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).validUntil;

        ITickets.AwayChainReading memory atHomesValidUntil = _readingOfTheTicket(ticketId, validUntil);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.AwayClockBeforeValidUntil.selector, ticketId, validUntil, validUntil + REORG_SLOT_SHIFT
            )
        );
        boundCompliance.closeByHand(ticketId, bobSat, atHomesValidUntil);

        _closeByHand(ticketId, bobSat, _readingOfTheTicket(ticketId, validUntil + REORG_SLOT_SHIFT));
        _assertStatus(ticketId, ITickets.TicketStatus.Cancelled, "cancelled once the shift is past");
    }

    /// @notice Anyone may not cancel a ticket the away token executed while its receipt cannot land: the cancel
    ///         refuses a closed route, close by hand needs its role, and the honest read applies the receipt.
    function test_closeByHand_refusesToCancelAnExecutedTicket_onAClosedRoute() public {
        bytes32 ticketId = _executedTicketWhoseReceiptIsLost(FOUR);
        _askAndLetTheAskGoUnanswered(ticketId, bobSat, "");
        _closeEvmChain(token, POLYGON);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ticketId;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.cancelTickets(ids);

        ITickets.AwayChainReading memory honestRead = _readingWith(polygonLite.storedReceipt(ticketId, 0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        boundCompliance.closeByHand(ticketId, bobSat, honestRead);

        _closeByHand(ticketId, bobSat, honestRead);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "applied, never cancelled");
        assertEq(token.awayBalanceOf(bobSat), FOUR);
        _assertHomeAgreesWithPolygon();
    }

    function test_closeByHand_waitsForTheStoredCopysValidUntil_whenItIsAboveHomes() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);
        uint64 storedCopyValidUntil = boundCompliance.ticketOf(ticketId).validUntil + 10 minutes;
        ITickets.AwayChainReading memory reading = _reading(storedCopyValidUntil - 1);
        reading.storedTicketValidUntil = storedCopyValidUntil;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.AwayClockBeforeValidUntil.selector, ticketId, storedCopyValidUntil - 1, storedCopyValidUntil
            )
        );
        boundCompliance.closeByHand(ticketId, bobSat, reading);
    }

    function test_closeByHand_waitsForTheSeenValidUntil_whenItIsAboveTheShift() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        uint64 seenValidUntil = boundCompliance.ticketOf(ticketId).validUntil + 5 minutes;
        // A still open answer on another copy of the ticket, valid later than home's.
        MessageTypesLib.ReceiptMessage memory stillOpen = _receiptWithNoTicket(ticketId, aliceSat, bobSat, 0);
        stillOpen.seenMax = FOUR;
        stillOpen.seenValidUntil = seenValidUntil;
        stillOpen.answer = MessageTypesLib.ReceiptAnswer.StillOpen;
        polygonGateway.relay(_awayTokenSends(polygonGateway, polygonLite, stillOpen));
        assertEq(boundCompliance.ticketOf(ticketId).seenValidUntil, seenValidUntil, "home saw the later copy");
        _closeEvmChain(token, POLYGON);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.AwayClockBeforeValidUntil.selector, ticketId, seenValidUntil - 1, seenValidUntil
            )
        );
        boundCompliance.closeByHand(ticketId, bobSat, _reading(seenValidUntil - 1));
    }

    function test_closeByHand_endsAnOpenBringHomeWithNothingMoved() public {
        uint256 broughtHome = 3;
        vm.prank(agent);
        bytes32 ticketId = boundCompliance.bringHome(aliceSat, broughtHome, alice, _salt());
        assertEq(token.reservedOf(aliceSat), broughtHome);
        _closeEvmChain(token, POLYGON);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.AwayClockBeforeValidUntil.selector, ticketId, validUntil - 1, validUntil)
        );
        boundCompliance.closeByHand(ticketId, aliceHome, _reading(validUntil - 1));

        _closeByHand(ticketId, aliceHome, _reading(validUntil));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "nothing moved");
        assertEq(token.reservedOf(aliceSat), 0, "the reservation is released");
        assertEq(token.balanceOf(alice), 0, "nothing minted at home");

        _openEvmChain(token, POLYGON, address(polygonGateway));
        vm.prank(agent);
        boundCompliance.bringHome(aliceSat, broughtHome, alice, _salt());
        assertEq(token.reservedOf(aliceSat), broughtHome, "a new bring home on the wallet is allowed");
    }

    /// @notice A home wallet that moved out: the move out never reached the closed receiving chain, so the money is
    ///         minted back at home at once.
    function test_closeByHand_mintsTheReturnAtHome_whenTheSenderIsAHomeWallet() public {
        uint256 movedOut = 5;
        vm.prank(agent);
        token.mint(alice, movedOut);
        vm.prank(alice);
        bytes32 ticketId = boundCompliance.askToMove(aliceHome, bobOptimismSat, movedOut, movedOut, "", _salt());
        assertEq(token.balanceOf(alice), 0, "burned at home");
        _closeEvmChain(token, OPTIMISM);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).secondHalfValidUntil;

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ClosedByHand(ticketId, movedOut, uint64(block.number), validUntil);
        _closeByHand(ticketId, bobOptimismSat, _reading(validUntil));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "returned");
        assertEq(token.balanceOf(alice), movedOut, "minted back at home");
    }

    /* ----- Money on hold with no ticket, moved inside the closed chain ----- */

    function test_closeByHand_appliesTheCreditOnTheReceivingWalletAsAMoveInsideThatChain() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        _closeEvmChain(token, POLYGON);
        uint64 stopWaitingAt = boundCompliance.ticketOf(ticketId).stopWaitingAt;
        uint256 movesToldBefore = rules.transferActionCalls();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, ticketId, stopWaitingAt));
        boundCompliance.closeByHand(ticketId, bobSat, _reading(stopWaitingAt));

        vm.warp(stopWaitingAt);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ClosedByHand(ticketId, 0, uint64(block.number), stopWaitingAt);
        _closeByHand(ticketId, bobSat, _reading(stopWaitingAt));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the move inside polygon is applied");
        assertEq(token.awayBalanceOf(bobSat), FOUR, "bob is counted");
        assertEq(boundCompliance.uncountedCreditOf(bobSat), 0);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - FOUR, "nothing minted back to alice");
        assertEq(boundCompliance.positionOf(address(bobIdentity)), FOUR);
        assertEq(boundCompliance.positionOf(address(aliceIdentity)), ALICE_AWAY_BALANCE - FOUR);
        assertEq(rules.transferActionCalls(), movesToldBefore + 1, "the tracker is told once");
        _assertHomeAgreesWithPolygon();
    }

    function test_closeByHand_keepsLastInFirstOut() public {
        (bytes32 aliceId, bytes32 bobId) = _bookTwoRelatedDroppedAsks();
        _closeEvmChain(token, POLYGON);
        vm.warp(boundCompliance.ticketOf(bobId).stopWaitingAt);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.LaterHoldStillCarries.selector, aliceId, bobId));
        boundCompliance.closeByHand(aliceId, bobSat, _reading(uint64(block.timestamp)));

        _closeByHand(bobId, charlieSat, _reading(uint64(block.timestamp)));

        _assertStatus(aliceId, ITickets.TicketStatus.Done, "alice's move applied first, for what bob carried");
        _assertStatus(bobId, ITickets.TicketStatus.Done, "then bob's");
        assertEq(token.awayBalanceOf(charlieSat), TWO);
        assertEq(token.awayBalanceOf(bobSat), 0);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - TWO);
        assertEq(boundCompliance.uncountedCreditOf(bobSat), 0);
        assertEq(boundCompliance.uncountedCreditOf(charlieSat), 0);
        assertEq(token.totalOnHold(), 0);
        _assertHomeAgreesWithPolygon();
        _assertPositionsAreTheSupply();
    }

    /// @notice The receiver was linked to no identity when the receipt was booked, and to Bob's by the close: the move
    ///         is applied to the identity the receiver has now, as a move inside one chain would be.
    function test_closeByHand_appliesTheMoveToTheReceiversIdentityOfNow() public {
        Account memory newWallet = makeAccount("newWalletOnPolygon");
        bytes memory newWalletSat = InteroperableAddress.formatEvmV1(POLYGON, newWallet.addr);
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, newWalletSat, TWO);
        polygonGateway.relay(receiptIndex);
        assertEq(boundCompliance.ticketOf(ticketId).toIdentity, address(0), "booked with no receiver identity");

        _linkSatelliteWallet(bobIdentity, POLYGON, newWallet);
        _closeEvmChain(token, POLYGON);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        _closeByHand(ticketId, newWalletSat, _reading(uint64(block.timestamp)));

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the move inside polygon is applied");
        assertEq(token.awayBalanceOf(newWalletSat), TWO);
        assertEq(boundCompliance.positionOf(address(bobIdentity)), TWO, "counted for bob's identity");
        assertEq(boundCompliance.positionOf(address(0)), 0, "never for no identity");
    }

    /// @notice A receiver still linked to no identity at the close cannot take the move: the money stays on hold
    ///         under its sender.
    function test_closeByHand_reverts_when_theReceiverHasNoIdentityAtTheClose() public {
        bytes memory unlinkedSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("unlinkedOnPolygon"));
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, unlinkedSat, TWO);
        polygonGateway.relay(receiptIndex);
        _closeEvmChain(token, POLYGON);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, unlinkedSat));
        boundCompliance.closeByHand(ticketId, unlinkedSat, _reading(uint64(block.timestamp)));

        _assertStatus(ticketId, ITickets.TicketStatus.OnHold, "still on hold");
        assertEq(token.onHoldOf(ticketId), TWO, "under alice");
    }

    /// @notice Alice to Bob 2, Bob to Charlie 2, Charlie to Alice 2, all dropped. Bob's hold owns nothing, it only
    ///         carries Alice's credit, so Charlie's receipt has nothing to carry and waits. Bob then gets 2 of his own
    ///         by a normal move: closing Bob's hold by hand applies Alice's move and Bob's, and never takes Bob's own 2.
    function test_closeByHand_neverTakesTheMiddleSendersOwnTokens_whenThreeRelatedAsksWereDropped() public {
        (bytes32 aliceId, bytes32 bobId) = _bookTwoRelatedDroppedAsks();
        (bytes32 charlieId,, uint256 charlieReceipt) = _droppedAsk(charlieOnPolygon, charlieSat, aliceSat, TWO);
        polygonGateway.relay(charlieReceipt);

        assertEq(boundCompliance.waitingReceiptOf(charlieId).amount, TWO, "charlie's receipt waits");
        assertEq(boundCompliance.ticketOf(bobId).carriedBy, bytes32(0), "nothing carries from bob's hold");

        bytes32 bobsOwnId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, TWO, TWO);
        _relayAll(polygonGateway);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(bobsOwnId, TWO);
        _relayAll(polygonGateway);
        assertEq(token.awayBalanceOf(bobSat), TWO, "bob holds 2 of his own");

        _closeEvmChain(token, POLYGON);
        vm.warp(boundCompliance.ticketOf(bobId).stopWaitingAt);
        _closeByHand(bobId, charlieSat, _reading(uint64(block.timestamp)));

        _assertStatus(aliceId, ITickets.TicketStatus.Done, "alice's move applied for what bob carried");
        _assertStatus(bobId, ITickets.TicketStatus.Done, "then bob's");
        assertEq(token.awayBalanceOf(bobSat), TWO, "bob's own 2 untouched");
        assertEq(token.awayBalanceOf(charlieSat), TWO);
        assertEq(token.onHoldOf(aliceId), 0, "nothing left on hold under alice");
    }

    /// @notice A short cancel burned 1 of 2 and gave that 1 back to alice; close by hand applies only what bob still
    ///         holds as credit inside polygon, and mints nothing more to alice.
    function test_closeByHand_returnsOnlyTheLatestHalfAmount() public {
        (bytes32 aliceId,) = _bookAliceAndLetBobSpend(1);
        vm.warp(boundCompliance.ticketOf(aliceId).stopWaitingAt);
        boundCompliance.cancelHold(aliceId, bobSat);
        _relayAll(polygonGateway);
        assertEq(boundCompliance.ticketOf(aliceId).moved, 1, "short: 1 left on hold");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - 1, "1 returned to alice");
        _closeEvmChain(token, POLYGON);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ClosedByHand(aliceId, 0, uint64(block.number), uint64(block.timestamp));
        _closeByHand(aliceId, bobSat, _reading(uint64(block.timestamp)));

        _assertStatus(aliceId, ITickets.TicketStatus.Done, "the rest applied inside polygon");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - 1, "nothing more minted to alice");
        assertEq(token.awayBalanceOf(bobSat), 1);
        assertEq(boundCompliance.uncountedCreditOf(bobSat), 0);
    }

    /* ----- Refusals ----- */

    function test_closeByHand_reverts_when_theIdIsUnknownAndTheReadStoresNothing() public {
        bytes32 unknownId = keccak256("never seen");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, unknownId));
        boundCompliance.closeByHand(unknownId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theStoredReceiptNamesAnotherId() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);
        MessageTypesLib.ReceiptMessage memory another =
            _receiptWithNoTicket(keccak256("another id"), aliceSat, bobSat, FOUR);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, ticketId));
        boundCompliance.closeByHand(ticketId, bobSat, _readingWith(another));
    }

    /// @notice A read that carries a receipt home would refuse, a mistake in the read for instance, is never taken:
    ///         nothing is applied, the chain is not blocked, and no close by hand is announced.
    function test_closeByHand_reverts_when_theStoredReceiptIsABadReceipt() public {
        bytes32 ticketId = _moveToBobOnOptimismUntilTheMoveOutIsOut(EIGHT);
        _closeEvmChain(token, OPTIMISM);
        MessageTypesLib.ReceiptMessage memory mintedLess = MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: "",
            to: bobOptimismSat,
            amount: EIGHT - 1,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: boundCompliance.ticketOf(ticketId).half,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, ticketId));
        boundCompliance.closeByHand(ticketId, bobOptimismSat, _readingWith(mintedLess));

        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "the chain is not blocked");
        _assertStatus(ticketId, ITickets.TicketStatus.OnHold, "still on hold");
    }

    /// @notice A stored receipt that home cannot apply now would only wait, tagged with no bridge: the close by hand
    ///         reverts instead, and is decided once the receipt can be applied. Here its sender has no identity.
    function test_closeByHand_reverts_when_theStoredReceiptCannotBeAppliedNow() public {
        bytes memory strangerSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("strangerOnPolygon"));
        bytes32 unknownId = keccak256("from a wallet nobody linked");
        MessageTypesLib.ReceiptMessage memory stored = _receiptWithNoTicket(unknownId, strangerSat, bobSat, FOUR);
        _closeEvmChain(token, POLYGON);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, unknownId));
        boundCompliance.closeByHand(unknownId, bobSat, _readingWith(stored));
        assertEq(boundCompliance.waitingReceiptOf(MessageTypesLib.halfKeyOf(unknownId, 0)).bodyHash, bytes32(0));
    }

    function test_closeByHand_reverts_when_theReceiverIsNotTheTickets() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, ticketId));
        boundCompliance.closeByHand(ticketId, charlieSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theReceiptRouteIsOpen() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ReceiptRouteNotClosed.selector, polygon));
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theReceiptRouteWasOpenedAgain() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);
        _openEvmChain(token, POLYGON, address(polygonGateway));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ReceiptRouteNotClosed.selector, polygon));
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theTokenIsPaused() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);
        _pauseTheToken();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TokenPaused.selector));
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theChainIsBlocked() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);
        _blockPolygon();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_aHostileChangeRuns() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _replacePolygonPeerAsHostile();
        _closeEvmChain(token, POLYGON);
        uint64 endsAt = token.hostileChangeEndsAt(polygon);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt));
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theCallerHasNoRole() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theTicketIsDone() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _relayAll(polygonGateway);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(ticketId, FOUR);
        _relayAll(polygonGateway);
        _closeEvmChain(token, POLYGON);

        _expectNotCancellable(ticketId, ITickets.TicketStatus.Done);
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theTicketIsCancelled() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _relayAll(polygonGateway);
        _cancelUnanswered(ticketId, bobSat, "");
        _closeEvmChain(token, POLYGON);

        _expectNotCancellable(ticketId, ITickets.TicketStatus.Cancelled);
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    function test_closeByHand_reverts_when_theTicketWaitsForApproval() public {
        _bindApprovalModule(approver);
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        _closeEvmChain(token, POLYGON);

        _expectNotCancellable(ticketId, ITickets.TicketStatus.WaitingForApproval);
        boundCompliance.closeByHand(ticketId, bobSat, _reading(uint64(block.timestamp)));
    }

    /// @notice Money going back to a sender whose own chain is the closed one waits for that chain.
    function test_closeByHand_reverts_when_theReturnGoesToAClosedSenderChain() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobOptimismSat, FOUR, FOUR);
        _relayAll(polygonGateway);
        rules.setAllow(false);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(ticketId, FOUR);
        _relayNext(polygonGateway); // the receipt lands; bob is refused, the move out goes back to alice
        _closeEvmChain(token, POLYGON);

        _expectNotCancellable(ticketId, ITickets.TicketStatus.OnHold);
        boundCompliance.closeByHand(ticketId, bobOptimismSat, _reading(uint64(block.timestamp + 1 days)));
    }

    function test_closeByHand_reverts_when_theHoldWithNoTicketLeftItsChain() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobOptimismSat, FOUR);
        polygonGateway.relay(receiptIndex);
        _closeEvmChain(token, POLYGON);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);

        _expectNotCancellable(ticketId, ITickets.TicketStatus.OnHold);
        boundCompliance.closeByHand(ticketId, bobOptimismSat, _reading(uint64(block.timestamp)));
    }

    /* ----- Helpers ----- */

    function _closeByHand(bytes32 ticketId, bytes memory receiver, ITickets.AwayChainReading memory reading) private {
        vm.prank(deployer);
        boundCompliance.closeByHand(ticketId, receiver, reading);
    }

    function _expectNotCancellable(bytes32 ticketId, ITickets.TicketStatus status) private {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, ticketId, uint8(status)));
    }

    /// @dev A read of a final block whose clock is `awayClockTime`, with no receipt and no ticket copy stored.
    function _reading(uint64 awayClockTime) private view returns (ITickets.AwayChainReading memory reading) {
        reading.blockNumber = uint64(block.number);
        reading.awayClockTime = awayClockTime;
    }

    /// @dev A read of the closed chain that holds home's copy of the ticket, unexecuted.
    function _readingOfTheTicket(bytes32 ticketId, uint64 awayClockTime)
        private
        view
        returns (ITickets.AwayChainReading memory reading)
    {
        reading = _reading(awayClockTime);
        reading.storedTicketValidUntil = polygonLite.storedTicketValidUntil(ticketId);
    }

    /// @dev A read of the closed chain that found `stored` for the half.
    function _readingWith(MessageTypesLib.ReceiptMessage memory stored)
        private
        view
        returns (ITickets.AwayChainReading memory reading)
    {
        reading = _reading(uint64(block.timestamp));
        reading.storedReceipt = stored;
    }

    /// @dev Alice on polygon asks to move `amount` to Bob on optimism; polygon executes and burns, its receipt lands,
    ///  and the move out to optimism is queued, undelivered.
    function _moveToBobOnOptimismUntilTheMoveOutIsOut(uint256 amount) private returns (bytes32 ticketId) {
        ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobOptimismSat, amount, amount);
        _relayAll(polygonGateway);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(ticketId, amount);
        _relayAll(polygonGateway);
        _assertStatus(ticketId, ITickets.TicketStatus.OnHold, "on hold for the move out");
    }

    /// @dev Alice asks to move `amount` to Bob on polygon; polygon executes it and its receipt is lost.
    function _executedTicketWhoseReceiptIsLost(uint256 amount) private returns (bytes32 ticketId) {
        ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, amount, amount);
        _relayAll(polygonGateway);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(ticketId, amount);
        polygonGateway.drop(polygonGateway.queueLength() - 1);
    }

}
