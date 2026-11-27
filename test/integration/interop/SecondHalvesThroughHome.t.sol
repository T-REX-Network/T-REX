// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { SecondHalvesSuiteTest } from "test/integration/helpers/SecondHalvesSuiteTest.sol";
import { TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A move from one away chain to another goes as one ticket through home: A's receipt puts the money on hold,
///      home asks the rules again and sends half 1 to the receiver on B, or back to the sender on A. B's receipt
///      ends the move. Every number below is read off home's records after real deliveries.
contract SecondHalvesThroughHomeTest is SecondHalvesSuiteTest {

    uint256 internal constant MOVED = 80;

    /* ----- The first half lands: forward or back ----- */

    function test_receiveReceipt_sendsAMoveOutToTheReceiver_whenTheRulesAllowIt() public {
        bytes32 id = _askAToB(MOVED);
        uint64 halfValidUntil = uint64(block.timestamp) + OPTIMISM_WINDOW;
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceOnA, bobOnB, MOVED));

        vm.expectEmit(true, true, true, true, address(boundCompliance));
        emit EventsLib.SecondHalfSent(id, 1, optimism, bobOnB, MOVED, halfValidUntil);
        polygonGateway.relay(index);

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.onHoldOf(id), MOVED, "the money waits on hold");
        assertEq(ledger.pendingInOf(address(bobIdentity)), MOVED, "kept for Bob while the half is out");
        assertEq(ticket.half, 1);
        assertEq(ticket.secondHalfToKey, keccak256(bobOnB), "forward to the receiver");
        assertEq(ticket.secondHalfValidUntil, halfValidUntil);
        (address pinnedBridge, bytes32 pinnedPeerKey) = token.pinOf(MessageTypesLib.halfKeyOf(id, 1));
        assertEq(pinnedBridge, address(optimismGateway), "half 1 is pinned to B's receipt route");
        assertEq(pinnedPeerKey, keccak256(token.peerFor(optimism)));
        MessageTypesLib.MoveOutMessage memory moveOut = _queuedMoveOut(optimismGateway, _lastIndex(optimismGateway));
        assertEq(moveOut.ticketId, id);
        assertEq(moveOut.half, 1);
        assertEq(moveOut.toWallet, bobOnB);
        assertEq(moveOut.amount, MOVED);
        assertEq(moveOut.validUntil, halfValidUntil);
        _assertTotalOwned();
    }

    /// @notice The rules are asked again when the money is on hold. Bob reached the cap meanwhile, by a forced
    ///         transfer no rule judges, so the half goes back to Alice on A, kept against nobody; its receipt gives
    ///         Alice her tokens back, moves no position and tells no tracker.
    function test_receiveReceipt_returnsTheMoneyToTheSender_whenTheRulesRefuseTheReceiver() public {
        uint256 cap = 500;
        uint256 bobReachesTheCap = 450;
        TrackerOnlyModule tracker = _bindTracker();
        _bindMaxBalance(cap);
        bytes32 id = _askAToB(MOVED);
        vm.prank(agent);
        token.forcedTransfer(alice, bob, bobReachesTheCap);
        uint256 trackerCallsBefore = tracker.transferActionCalls();
        uint256 alicePosition = ledger.positionOf(address(aliceIdentity));
        uint256 bobPosition = ledger.positionOf(address(bobIdentity));
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceOnA, bobOnB, MOVED));

        vm.expectEmit(true, true, true, true, address(boundCompliance));
        emit EventsLib.SecondHalfSent(id, 1, polygon, aliceOnA, MOVED, uint64(block.timestamp) + POLYGON_WINDOW);
        polygonGateway.relay(index);

        assertEq(boundCompliance.ticketOf(id).secondHalfToKey, keccak256(aliceOnA), "back to the sender");
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "nothing kept for Bob");
        assertEq(token.awayBalanceOf(aliceOnA), ALICE_ON_A - MOVED, "A burned it");

        _deliver(polygonGateway, _minted(id, 1, aliceOnA, MOVED));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(aliceOnA), ALICE_ON_A, "Alice has it back");
        assertEq(token.onHoldOf(id), 0);
        assertEq(ledger.positionOf(address(aliceIdentity)), alicePosition, "a return moves no position");
        assertEq(ledger.positionOf(address(bobIdentity)), bobPosition);
        assertEq(tracker.transferActionCalls(), trackerCallsBefore, "a return tells no tracker");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        _assertTotalOwned();
    }

    /// @notice A move between two chains ends `Done` at B's receipt, and only then are positions moved and the
    ///         trackers told, once, as a move between chains.
    function test_receiveReceipt_endsTheMoveAndTellsTheTrackersOnce_whenTheMoveOutLands() public {
        TrackerOnlyModule tracker = _bindTracker();
        bytes32 id = _firstHalfLanded(MOVED);
        uint256 callsAtTheFirstHalf = tracker.transferActionCalls();

        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED);
        assertEq(token.onHoldOf(id), 0);
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0);
        assertEq(ledger.positionOf(address(bobIdentity)), MOVED, "Bob owns it at Done");
        assertEq(ledger.positionOf(address(aliceIdentity)), MINTED - MOVED);
        assertEq(callsAtTheFirstHalf, 0, "nobody was told at the first half");
        assertEq(tracker.transferActionCalls(), 1, "told once, at Done");
        (,,,,,,, uint8 kind,,,) = tracker.lastContext();
        assertEq(kind, MovementKindLib.CROSS_CHAIN);
        _assertTotalOwned();
    }

    /// @notice The cap holds through a move between chains: home asks the rules at the decision, so a move that fits
    ///         reaches Bob unchanged and Bob ends at the cap, never above it.
    function test_receiveReceipt_doesNotTouchMovesBetweenTwoChains_whenTheCapCheckRuns() public {
        uint256 cap = 500;
        uint256 bobBefore = cap - MOVED;
        _bindMaxBalance(cap);
        vm.prank(agent);
        token.forcedTransfer(alice, bob, bobBefore);
        bytes32 id = _requestValidation(address(aliceIdentity), aliceOnA, bobOnB, MOVED, MOVED);

        _aSendsTheTicketsReceipt(id, bobOnB, MOVED);
        assertEq(boundCompliance.ticketOf(id).secondHalfToKey, keccak256(bobOnB), "the move that fits goes forward");
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED);
        assertEq(ledger.positionOf(address(bobIdentity)), cap, "at the cap, never above");
    }

    /// @notice A home reorg mined the ask again, narrowed by the cap to what Bob has room for; A had already executed
    ///         the first copy, wider. Its receipt lands under the same id on older terms, is applied as it happened,
    ///         and the rules asked again send the money back: Bob never passes the cap.
    function test_receiveReceipt_appliesANarrowedTicketBetweenTwoChains_whenTheAskWasMinedAgain() public {
        uint256 cap = 500;
        uint256 requestedMax = 100;
        uint256 executedOnTheFirstCopy = 90;
        uint256 bobAfterTheReorg = 450;
        _bindMaxBalance(cap);
        bytes32 salt = _salt();
        uint256 beforeTheReorg = vm.snapshotState();
        vm.prank(address(aliceIdentity));
        bytes32 firstId = boundCompliance.askToMove(aliceOnA, bobOnB, 10, requestedMax, "", salt);
        bytes32 firstCopy = boundCompliance.ticketOf(firstId).askBlockHash;

        vm.revertToState(beforeTheReorg);
        vm.roll(block.number + 1);
        vm.prank(agent);
        token.forcedTransfer(alice, bob, bobAfterTheReorg);
        vm.prank(address(aliceIdentity));
        bytes32 id = boundCompliance.askToMove(aliceOnA, bobOnB, 10, requestedMax, "", salt);
        assertEq(id, firstId, "the ask mined again keeps its id");
        assertEq(boundCompliance.ticketOf(id).amountMax, cap - bobAfterTheReorg, "narrowed to Bob's room");

        MessageTypesLib.ReceiptMessage memory receipt =
            _settlementUnder(id, aliceOnA, bobOnB, executedOnTheFirstCopy, firstCopy);
        receipt.seenMax = requestedMax;
        _deliver(polygonGateway, receipt);

        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.onHoldOf(id), executedOnTheFirstCopy, "applied as it happened");
        assertEq(boundCompliance.ticketOf(id).secondHalfToKey, keccak256(aliceOnA), "the rules sent it back");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "an honest older copy blocks nobody");
        assertEq(ledger.positionOf(address(bobIdentity)), bobAfterTheReorg);
    }

    /* ----- The receiving chain is bound to its own half ----- */

    /// @notice B's honest receipt for its own half ends the move and blocks nobody; so does the receipt of a home
    ///         wallet's move out.
    function test_receiveReceipt_doesNotBlockTheReceivingChain_forItsOwnHonestReceipt() public {
        bytes32 id = _firstHalfLanded(MOVED);
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));

        vm.prank(alice);
        bytes32 moveOutId = boundCompliance.askToMove(aliceHome, aliceOnB, MOVED, MOVED, "", _salt());
        _deliver(optimismGateway, _minted(moveOutId, 1, aliceOnB, MOVED));

        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "B is not blocked");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        _assertStatus(id, ITickets.TicketStatus.Done);
        _assertStatus(moveOutId, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED);
        assertEq(token.awayBalanceOf(aliceOnB), MOVED);
    }

    /// @notice A third chain C sends a receipt for B's half through C's own route: refused, C blocked, and B's honest
    ///         receipt still lands.
    function test_receiveReceipt_refusesASecondHalfReceiptFromAnotherAwayChain() public {
        (ERC7786GatewayMock baseGateway, bytes32 base) = _openBase();
        bytes32 id = _firstHalfLanded(MOVED);
        MessageTypesLib.ReceiptMessage memory forged = _minted(id, 1, bobOnB, MOVED);
        uint256 index = _liteSettles(baseGateway, token, forged);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, base, MOVED, bytes32(0));
        baseGateway.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(base), "C is blocked");
        assertFalse(boundCompliance.isAwayChainBlocked(optimism));
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));
        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED, "minted once");
    }

    /// @notice A forged zero answer from C would make a new half owed while B still mints: refused, C blocked,
    ///         nothing owed.
    function test_receiveReceipt_refusesAZeroAnswerForASecondHalfFromAnotherAwayChain() public {
        (ERC7786GatewayMock baseGateway, bytes32 base) = _openBase();
        bytes32 id = _firstHalfLanded(MOVED);

        _deliver(baseGateway, _expired(id, 1, bobOnB));

        assertTrue(boundCompliance.isAwayChainBlocked(base), "C is blocked");
        assertFalse(boundCompliance.ticketOf(id).secondHalfOwed, "nothing owed");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, _secondSendDueAt(id)));
        boundCompliance.sendSecondHalf(id, bobOnB);
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));
        _assertStatus(id, ITickets.TicketStatus.Done);
    }

    /* ----- Bad second-half receipts: each refused, B blocked, nothing moved ----- */

    function test_receiveReceipt_refusesASecondHalfReceipt_whenItNamesASender() public {
        bytes32 id = _firstHalfLanded(MOVED);
        MessageTypesLib.ReceiptMessage memory receipt = _minted(id, 1, bobOnB, MOVED);
        receipt.from = aliceOnA;

        _assertRefusedByB(id, receipt);
    }

    function test_receiveReceipt_refusesASecondHalfReceipt_whenItMintsLessThanTheMoneyOnHold() public {
        bytes32 id = _firstHalfLanded(MOVED);

        _assertRefusedByB(id, _minted(id, 1, bobOnB, MOVED - 1));
    }

    function test_receiveReceipt_refusesASecondHalfReceipt_whenItMintsAnOlderHalf() public {
        bytes32 id = _firstHalfLanded(MOVED);
        _deliver(optimismGateway, _expired(id, 1, bobOnB));
        boundCompliance.sendSecondHalf(id, bobOnB);
        assertEq(boundCompliance.ticketOf(id).half, 2);

        _assertRefusedByB(id, _minted(id, 1, bobOnB, MOVED));
    }

    function test_receiveReceipt_refusesASecondHalfReceipt_forAHalfNeverSent() public {
        bytes32 id = _firstHalfLanded(MOVED);

        _assertRefusedByB(id, _minted(id, 2, bobOnB, MOVED));
    }

    function test_receiveReceipt_refusesASecondHalfReceipt_forTheLatestHalfWhoseSendWasCaught() public {
        bytes32 id = _askAToB(MOVED);
        _bSendsFail();
        _aSendsTheTicketsReceipt(id, bobOnB, MOVED);
        vm.clearMockedCalls();
        assertEq(boundCompliance.ticketOf(id).secondHalfSends, 0, "half 1 never left");

        _assertRefusedByB(id, _minted(id, 1, bobOnB, MOVED));
    }

    /// @notice An older half's zero answer that comes again after a new half went changes nothing: that half is dead
    ///         already. Half 2 left only because half 1 answered zero; the away token then sends that zero again.
    function test_receiveReceipt_changesNothing_whenAnOlderHalfsZeroComesAgainAfterANewHalfWent() public {
        bytes32 id = _firstHalfLanded(MOVED);
        _deliver(optimismGateway, _expired(id, 1, bobOnB));
        boundCompliance.sendSecondHalf(id, bobOnB);
        ITickets.Ticket memory before = boundCompliance.ticketOf(id);
        assertEq(before.half, 2);
        uint256 index = _liteSettles(optimismGateway, token, _expired(id, 1, bobOnB));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, optimism);
        optimismGateway.relay(index);

        ITickets.Ticket memory afterwards = boundCompliance.ticketOf(id);
        assertEq(afterwards.half, before.half);
        assertEq(afterwards.secondHalfOwed, before.secondHalfOwed);
        assertEq(afterwards.secondHalfSends, before.secondHalfSends);
        assertEq(token.onHoldOf(id), MOVED);
        assertFalse(boundCompliance.isAwayChainBlocked(optimism));
    }

    /* ----- The send inside the delivery ----- */

    /// @notice Below the gas a second half's send needs, the whole delivery reverts: nothing is written and the
    ///         receipt stays deliverable, so no relayer can make the send fail on purpose.
    function test_receiveReceipt_revertsTheWholeDelivery_whenTooLittleGasIsLeftForTheMoveOut() public {
        bytes32 id = _askAToB(MOVED);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceOnA, bobOnB, MOVED));
        uint256 gasForTheReceiptButNotTheSend = 800_000;

        vm.expectPartialRevert(ErrorsLib.NotEnoughGasForTheSecondHalf.selector);
        polygonGateway.relay{ gas: gasForTheReceiptButNotTheSend }(index);

        _assertStatus(id, ITickets.TicketStatus.Open);
        assertEq(token.onHoldOf(id), 0, "nothing written");
        assertEq(token.awayBalanceOf(aliceOnA), ALICE_ON_A);
        polygonGateway.relay(index);
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.onHoldOf(id), MOVED, "the same delivery lands later");
    }

    /// @notice A relayer picks the gas so the check passes but the send inside runs out: the delivery must then
    ///         revert as a whole, or the half must have left. A caught failure here would let any relayer make the
    ///         send fail on purpose.
    function test_receiveReceipt_neverCatchesASendThatRanOutOfGas_onceTheGasCheckPassed() public {
        bytes32 id = _askAToB(MOVED);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceOnA, bobOnB, MOVED));
        uint256 gasAboveTheCheckButShortOfTheSend = 1_000_000;

        try polygonGateway.relay{ gas: gasAboveTheCheckButShortOfTheSend }(index) {
            assertEq(boundCompliance.ticketOf(id).secondHalfSends, 1, "the delivery landed, so the half must have left");
            assertFalse(boundCompliance.ticketOf(id).secondHalfOwed);
        } catch {
            _assertStatus(id, ITickets.TicketStatus.Open);
        }
    }

    /// @notice The same, for any gas a relayer picks: the delivery reverts as a whole and lands later, or the half
    ///         left inside it.
    function test_fuzz_receiveReceipt_neverCatchesASendThatRanOutOfGas(uint256 relayGas) public {
        uint256 leastGasTried = 500_000;
        uint256 mostGasTried = 3_000_000;
        relayGas = bound(relayGas, leastGasTried, mostGasTried);
        bytes32 id = _askAToB(MOVED);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceOnA, bobOnB, MOVED));

        try polygonGateway.relay{ gas: relayGas }(index) {
            assertEq(boundCompliance.ticketOf(id).secondHalfSends, 1, "the delivery landed, so the half must have left");
            assertFalse(boundCompliance.ticketOf(id).secondHalfOwed, "nothing caught");
        } catch {
            _assertStatus(id, ITickets.TicketStatus.Open);
            polygonGateway.relay(index);
            assertEq(boundCompliance.ticketOf(id).secondHalfSends, 1, "the same delivery lands later");
        }
    }

    /// @notice The gateway refuses the send: the receipt stays applied, the failure is announced and the half stays
    ///         owed under its own number, never sent; anyone sends it later as half 1.
    function test_receiveReceipt_leavesTheSecondHalfOwed_whenTheSendFails() public {
        bytes32 id = _askAToB(MOVED);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceOnA, bobOnB, MOVED));
        _bSendsFail();

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.SecondHalfNotSent(id, 1);
        polygonGateway.relay(index);
        vm.clearMockedCalls();

        ITickets.Ticket memory owed = boundCompliance.ticketOf(id);
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertTrue(owed.secondHalfOwed);
        assertEq(owed.secondHalfSends, 0);
        assertEq(owed.half, 1);
        (address pinnedBridge,) = token.pinOf(MessageTypesLib.halfKeyOf(id, 1));
        assertEq(pinnedBridge, address(0), "nothing left, nothing pinned");

        vm.prank(makeAddr("anyone"));
        boundCompliance.sendSecondHalf(id, bobOnB);

        ITickets.Ticket memory sent = boundCompliance.ticketOf(id);
        assertEq(sent.half, 1, "the same number");
        assertEq(sent.newHalves, 1);
        assertEq(sent.secondHalfSends, 1);
        assertFalse(sent.secondHalfOwed);
        assertEq(_queuedMoveOut(optimismGateway, _lastIndex(optimismGateway)).half, 1);
    }

    /* ----- Sending a half again ----- */

    function test_sendSecondHalf_isDueAtFixedTimes_notCountedFromTheLastSend() public {
        bytes32 id = _firstHalfLanded(MOVED);
        uint64 validUntil = boundCompliance.ticketOf(id).secondHalfValidUntil;
        uint64 secondDueAt = validUntil + OPTIMISM_WINDOW;
        uint64 thirdDueAt = validUntil + 3 * OPTIMISM_WINDOW;

        vm.warp(secondDueAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, secondDueAt));
        boundCompliance.sendSecondHalf(id, bobOnB);

        vm.warp(validUntil + 2 * OPTIMISM_WINDOW);
        boundCompliance.sendSecondHalf(id, bobOnB);
        assertEq(boundCompliance.ticketOf(id).secondHalfSends, 2, "sent late");

        vm.warp(thirdDueAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, thirdDueAt));
        boundCompliance.sendSecondHalf(id, bobOnB);

        vm.warp(thirdDueAt);
        boundCompliance.sendSecondHalf(id, bobOnB);
        assertEq(boundCompliance.ticketOf(id).secondHalfSends, 3);
        assertEq(boundCompliance.ticketOf(id).half, 1, "the same half, sent again");

        vm.warp(thirdDueAt + 10 * OPTIMISM_WINDOW);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SecondHalfNotOwed.selector, id));
        boundCompliance.sendSecondHalf(id, bobOnB);
    }

    function test_receiveReceipt_makesANewHalfOwed_whenTheMoveOutCameAfterItsValidUntil() public {
        bytes32 id = _firstHalfLanded(MOVED);

        _deliver(optimismGateway, _expired(id, 1, bobOnB));

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        assertTrue(ticket.secondHalfOwed, "a new half is owed");
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.onHoldOf(id), MOVED, "the money stays on hold");
        assertEq(token.awayBalanceOf(bobOnB), 0);

        boundCompliance.sendSecondHalf(id, bobOnB);
        MessageTypesLib.MoveOutMessage memory halfTwo = _queuedMoveOut(optimismGateway, _lastIndex(optimismGateway));
        assertEq(halfTwo.half, 2, "a new number");
        assertEq(halfTwo.validUntil, uint64(block.timestamp) + OPTIMISM_WINDOW, "its own valid until");
    }

    function test_sendSecondHalf_reverts_after_theNewHalfLimit() public {
        bytes32 id = _firstHalfLanded(MOVED);
        _deliver(optimismGateway, _expired(id, 1, bobOnB));
        boundCompliance.sendSecondHalf(id, bobOnB);
        _deliver(optimismGateway, _expired(id, 2, bobOnB));
        boundCompliance.sendSecondHalf(id, bobOnB);
        _deliver(optimismGateway, _expired(id, 3, bobOnB));

        boundCompliance.sendSecondHalf(id, bobOnB);
        assertEq(boundCompliance.ticketOf(id).newHalves, 4);

        _deliver(optimismGateway, _expired(id, 4, bobOnB));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoNewHalfLeft.selector, id));
        boundCompliance.sendSecondHalf(id, bobOnB);
        assertEq(token.onHoldOf(id), MOVED, "still on hold, for a human to end");
    }

    /// @notice Bob's chain had a planned peer change: half 1 is pinned to the former pair. At its due time the send
    ///         is the same half again, to the former peer that holds it, never a new half: a new half would be a
    ///         second move out of the same money. Half 1's receipt then ends the move.
    function test_sendSecondHalf_sendsTheSameHalfToTheFormerPeer_afterAPlannedPeerChange() public {
        bytes32 id = _firstHalfLanded(MOVED);
        bytes memory formerPeer = token.peerFor(optimism);
        vm.prank(deployer);
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("newOptimismPeer")));
        vm.warp(_secondSendDueAt(id));

        boundCompliance.sendSecondHalf(id, bobOnB);

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        assertEq(ticket.half, 1, "the same half");
        assertEq(ticket.secondHalfSends, 2, "sent a second time");
        assertEq(optimismGateway.queuedMessage(_lastIndex(optimismGateway)).recipient, formerPeer, "to the former peer");
        assertEq(_queuedMoveOut(optimismGateway, _lastIndex(optimismGateway)).half, 1);
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));
        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED, "minted once");
        assertFalse(boundCompliance.isAwayChainBlocked(optimism));
    }

    /// @notice Half 1 was minted on B in time but its receipt is late, and B's receipt bridge is changed as planned.
    ///         The due send asks for half 1 again through the former bridge, and half 1's late receipt ends the move:
    ///         no second move out leaves, and the honest chain is never blocked.
    function test_sendSecondHalf_resendsTheSameHalf_whileItsReceiptIsLate_afterAPlannedBridgeChange() public {
        bytes32 id = _firstHalfLanded(MOVED);
        ERC7786GatewayMock newBridge = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, OPTIMISM, address(newBridge));
        vm.warp(boundCompliance.ticketOf(id).secondHalfValidUntil + boundCompliance.waitingTimeOf(optimism));
        uint256 queuedOnTheFormerBridge = optimismGateway.queueLength();

        boundCompliance.sendSecondHalf(id, bobOnB);

        assertEq(boundCompliance.ticketOf(id).half, 1, "the same half, not a new one");
        assertEq(optimismGateway.queueLength(), queuedOnTheFormerBridge + 1, "asked through the former bridge");
        assertEq(newBridge.queueLength(), 0, "no move out on the new bridge");
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));
        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED, "minted once");
        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "the honest chain is not blocked");
    }

    /// @notice After a planned peer change the former peer is asked only inside its window of four waiting times;
    ///         the send due after it ends is refused rather than sent to the new peer, which does not hold the half.
    function test_sendSecondHalf_reverts_when_theFormerPeersWindowEnded() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.prank(deployer);
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("newOptimismPeer")));
        vm.warp(_secondSendDueAt(id));
        boundCompliance.sendSecondHalf(id, bobOnB);

        uint64 thirdSendDueAt = boundCompliance.ticketOf(id).secondHalfValidUntil + 3 * OPTIMISM_WINDOW;
        vm.warp(thirdSendDueAt);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, optimism));
        boundCompliance.sendSecondHalf(id, bobOnB);
        assertEq(boundCompliance.ticketOf(id).half, 1, "no new half");
    }

    /// @notice The peer half 1 was pinned to was replaced as hostile: home keeps no former pair, so the half is never
    ///         sent to the new peer, which does not hold it. Its exit is closing the chain by hand.
    function test_sendSecondHalf_reverts_when_thePinnedPeerWasReplacedAsHostile() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.prank(deployer);
        token.replaceHostilePeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("replacementPeer")));
        vm.warp(token.hostileChangeEndsAt(optimism) + 1);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, optimism));
        boundCompliance.sendSecondHalf(id, bobOnB);
        assertEq(boundCompliance.ticketOf(id).half, 1, "no new half");
    }

    function test_sendSecondHalf_reverts_when_theWalletIsNotTheHalfs() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.warp(_secondSendDueAt(id));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, id));
        boundCompliance.sendSecondHalf(id, aliceOnB);
    }

    function test_sendSecondHalf_reverts_when_theTicketIsStillOpen() public {
        bytes32 id = _askAToB(MOVED);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SecondHalfNotOwed.selector, id));
        boundCompliance.sendSecondHalf(id, bobOnB);
    }

    function test_sendSecondHalf_reverts_when_theMoveIsDone() public {
        bytes32 id = _firstHalfLanded(MOVED);
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SecondHalfNotOwed.selector, id));
        boundCompliance.sendSecondHalf(id, bobOnB);
    }

    function test_sendSecondHalf_reverts_when_theTokenIsPaused() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.warp(_secondSendDueAt(id));
        vm.prank(agent);
        token.pause();

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.sendSecondHalf(id, bobOnB);
    }

    function test_sendSecondHalf_reverts_when_theReceiversChainIsBlocked() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.warp(_secondSendDueAt(id));
        vm.prank(agent);
        boundCompliance.blockAwayChain(optimism);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, optimism));
        boundCompliance.sendSecondHalf(id, bobOnB);
    }

    function test_sendSecondHalf_reverts_while_aHostilePeerChangeRuns() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.warp(_secondSendDueAt(id));
        vm.prank(deployer);
        token.replaceHostilePeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("replacementPeer")));
        uint64 endsAt = token.hostileChangeEndsAt(optimism);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, optimism, endsAt));
        boundCompliance.sendSecondHalf(id, bobOnB);
    }

    /* ----- Forward refused, so the money goes back ----- */

    function test_receiveReceipt_returnsTheMoney_whenTheReceiversChainIsBlocked() public {
        bytes32 id = _askAToB(MOVED);
        vm.prank(agent);
        boundCompliance.blockAwayChain(optimism);

        _aSendsTheTicketsReceipt(id, bobOnB, MOVED);

        _assertGoesBackToAlice(id);
    }

    function test_receiveReceipt_returnsTheMoney_whenTheReceiversRouteIsClosed() public {
        bytes32 id = _askAToB(MOVED);
        _closeEvmChain(token, OPTIMISM);

        _aSendsTheTicketsReceipt(id, bobOnB, MOVED);

        _assertGoesBackToAlice(id);
    }

    function test_receiveReceipt_returnsTheMoney_whenTheReceiversChainHasNoWaitingTime() public {
        (, bytes32 base) = _openBase();
        bytes memory bobOnBase = _linkSatelliteWallet(bobIdentity, BASE, makeAccount("bobOnBase"));
        assertEq(boundCompliance.waitingTimeOf(base), 0);
        bytes32 id = _requestValidation(address(aliceIdentity), aliceOnA, bobOnBase, MOVED, MOVED);

        _aSendsTheTicketsReceipt(id, bobOnBase, MOVED);

        _assertGoesBackToAlice(id);
    }

    function test_receiveReceipt_returnsTheMoney_whenTheReceiverIsNoLongerVerified() public {
        bytes32 id = _askAToB(MOVED);
        _revokeWallet(bobIdentity, bobOnB);

        _aSendsTheTicketsReceipt(id, bobOnB, MOVED);

        _assertGoesBackToAlice(id);
    }

    /* ----- A receiver at home ----- */

    function test_receiveReceipt_mintsAHomeReceiverAtOnce_withNoSecondHalf() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceOnA, bobHome, MOVED, MOVED);
        uint256 queuedOnA = polygonGateway.queueLength();
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceOnA, bobHome, MOVED));

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledToNative(keccak256(aliceOnA), bob, id, aliceOnA, MOVED);
        polygonGateway.relay(index);

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(bob), MOVED, "minted in the receipt's transaction");
        assertEq(boundCompliance.ticketOf(id).half, 0, "no half");
        assertEq(token.onHoldOf(id), 0);
        assertEq(polygonGateway.queueLength(), queuedOnA + 1, "nothing sent but the receipt itself");
        assertEq(optimismGateway.queueLength(), 0);
        _assertTotalOwned();
    }

    function test_receiveReceipt_sendsTheMoneyBackToA_whenTheRulesRefuseTheHomeReceiver() public {
        uint256 cap = 500;
        _bindMaxBalance(cap);
        bytes32 id = _requestValidation(address(aliceIdentity), aliceOnA, bobHome, MOVED, MOVED);
        vm.prank(agent);
        token.forcedTransfer(alice, bob, cap - MOVED + 1);

        _aSendsTheTicketsReceipt(id, bobHome, MOVED);

        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.balanceOf(bob), cap - MOVED + 1, "nothing minted to Bob");
        MessageTypesLib.MoveOutMessage memory back = _queuedMoveOut(polygonGateway, _lastIndex(polygonGateway));
        assertEq(back.toWallet, aliceOnA);
        assertEq(back.amount, MOVED);
    }

    /* ----- Nothing gives the hold back but B's answer ----- */

    /// @notice Home never gives money on hold back while a half may still mint: no cancel and no ask for the first
    ///         half's receipt touches it, whatever the time. Only B's receipt ends it, or B's zero answer makes a new
    ///         half owed.
    function test_receiveReceipt_keepsTheMoneyOnHold_untilTheReceivingChainAnswers() public {
        uint256 held = 500;
        bytes32 id = _firstHalfLanded(held);
        vm.warp(block.timestamp + 20 * OPTIMISM_WINDOW);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.OnHold))
        );
        boundCompliance.cancelTickets(_ids(id));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationNotResendable.selector, id, uint8(ITickets.TicketStatus.OnHold))
        );
        boundCompliance.sendTicket(id, polygon, bobOnB, "");
        assertEq(token.onHoldOf(id), held, "the hold stands");
        assertEq(token.awayBalanceOf(aliceOnA), 0, "nothing given back to the sender");

        _deliver(optimismGateway, _expired(id, 1, bobOnB));
        assertEq(token.onHoldOf(id), held, "a zero answer keeps it on hold");
        boundCompliance.sendSecondHalf(id, bobOnB);
        _deliver(optimismGateway, _minted(id, 2, bobOnB, held));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), held);
        assertEq(token.awayBalanceOf(aliceOnA), 0);
        _assertTotalOwned();
    }

    /* ----- Second-half receipts that wait ----- */

    function test_applyWaitingReceipt_appliesASecondHalfReceiptThatWaitedForTheUnpause() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.prank(agent);
        token.pause();
        MessageTypesLib.ReceiptMessage memory receipt = _minted(id, 1, bobOnB, MOVED);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(id, 1);
        uint256 index = _liteSettles(optimismGateway, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWaiting(halfKey, optimism, address(optimismGateway), receipt);
        optimismGateway.relay(index);
        _assertStatus(id, ITickets.TicketStatus.OnHold);

        vm.prank(agent);
        token.unpause();
        boundCompliance.applyWaitingReceipt(halfKey, receipt);

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED);
    }

    function test_applyWaitingReceipt_appliesASecondHalfReceiptThatWaitedForTheUnblock() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.prank(agent);
        boundCompliance.blockAwayChain(optimism);
        MessageTypesLib.ReceiptMessage memory receipt = _minted(id, 1, bobOnB, MOVED);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(id, 1);

        _deliver(optimismGateway, receipt);
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertTrue(boundCompliance.waitingReceiptOf(halfKey).bodyHash != bytes32(0), "it waits");

        vm.prank(agent);
        boundCompliance.unblockAwayChain(optimism);
        boundCompliance.applyWaitingReceipt(halfKey, receipt);

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED);
    }

    /* ----- The token doors of the second half ----- */

    function test_burnOntoHold_reverts_when_theCallerIsNotTheBoundCompliance() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.burnOntoHold(aliceHome, 1, keccak256("ticket"));
    }

    function test_putOnHold_reverts_when_theCallerIsNotTheBoundCompliance() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.putOnHold(aliceOnA, 1, keccak256("ticket"));
    }

    function test_sendOnReceiptRoute_reverts_when_theCallerIsNotTheBoundCompliance() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.sendOnReceiptRoute(optimism, keccak256("half"), MessageTypesLib.Message.MOVE_OUT, "");
    }

    function test_sendOnReceiptRoute_reverts_when_aPinnedHalfIsSentAfterAHostilePeerChange() public {
        bytes32 id = _firstHalfLanded(MOVED);
        vm.prank(deployer);
        token.replaceHostilePeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("newOptimismPeer")));

        vm.prank(address(boundCompliance));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, optimism));
        token.sendOnReceiptRoute(optimism, MessageTypesLib.halfKeyOf(id, 1), MessageTypesLib.Message.MOVE_OUT, "");
    }

    /* ----- Helpers ----- */

    uint256 internal constant BASE = 8453;

    /// @dev Opens a third away chain, C, with a receipt route and measured times, but no waiting time.
    function _openBase() private returns (ERC7786GatewayMock baseGateway, bytes32 base) {
        base = _evmChainKey(BASE);
        baseGateway = _newReceiptBridge(BASE);
        _openEvmChain(token, BASE, address(baseGateway));
        vm.prank(deployer);
        boundCompliance.setMeasuredTimes(base, _measuredTimes());
    }

    /// @dev Every send on B's gateway reverts: the transport refuses the message.
    function _bSendsFail() private {
        vm.mockCallRevert(
            address(optimismGateway), abi.encodeWithSelector(ERC7786GatewayMock.sendMessage.selector), "gateway down"
        );
    }

    /// @dev When the latest half may be sent the second time: one waiting time of B after its valid until.
    function _secondSendDueAt(bytes32 id) private view returns (uint64) {
        return boundCompliance.ticketOf(id).secondHalfValidUntil + OPTIMISM_WINDOW;
    }

    /// @dev B sends `receipt`: it is refused, B is blocked, and the money stays on hold for Bob.
    function _assertRefusedByB(bytes32 id, MessageTypesLib.ReceiptMessage memory receipt) private {
        uint256 index = _liteSettles(optimismGateway, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, optimism, receipt.amount, bytes32(0));
        optimismGateway.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(optimism), "B is blocked");
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.onHoldOf(id), MOVED, "nothing moved");
        assertEq(token.awayBalanceOf(bobOnB), 0);
    }

    /// @dev A's receipt was applied and the money goes back to Alice on A as half 1, kept against nobody.
    function _assertGoesBackToAlice(bytes32 id) private view {
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(ticket.secondHalfToKey, keccak256(aliceOnA), "back to the sender");
        assertEq(ticket.half, 1);
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "nothing kept for Bob");
        MessageTypesLib.MoveOutMessage memory back = _queuedMoveOut(polygonGateway, _lastIndex(polygonGateway));
        assertEq(back.toWallet, aliceOnA);
        assertEq(back.amount, MOVED);
        assertEq(back.validUntil, uint64(block.timestamp) + POLYGON_WINDOW);
    }

}
