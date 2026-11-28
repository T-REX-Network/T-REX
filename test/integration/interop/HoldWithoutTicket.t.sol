// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";

import { HoldsSuiteTest } from "test/integration/helpers/HoldsSuiteTest.sol";
import { Utils } from "test/unit/helpers/Utils.sol";

/// @dev A receipt no ticket home sent answers: an id home has no record of, after a home reorg dropped the ask, or a
///      ticket home wrote and never sent. Home blocks nobody for it: the amount goes on hold under the sender with no
///      destination, a receiver on the same away chain gets uncounted credit, and the hash is written so the same
///      receipt again changes nothing. The same ask mined again takes the money; four waiting times later anyone
///      cancels it, last in, first out.
contract HoldWithoutTicketTest is HoldsSuiteTest {

    uint256 internal constant FOUR = 4;
    uint256 internal constant TWO = 2;
    address internal approver = makeAddr("approver");

    /* ----- The booking ----- */

    function test_receiveReceipt_booksOnHoldWithNoDestination_whenTheTicketIsUnknown() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        uint64 bookedAt = uint64(block.timestamp);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(ticketId, polygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        ITickets.Ticket memory held = boundCompliance.ticketOf(ticketId);
        assertEq(token.onHoldOf(ticketId), FOUR, "the amount is on hold");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - FOUR, "it left alice's wallet");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), FOUR, "bob holds it, uncounted");
        assertEq(token.awayBalanceOf(bobSat), 0, "never counted for bob");
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold), "on hold");
        assertFalse(held.written, "no ticket home sent answers it");
        assertEq(held.stopWaitingAt, bookedAt + 4 * POLYGON_WINDOW, "four waiting times of the sender's chain");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "nobody is blocked");
        assertFalse(token.paused(), "the token runs");
    }

    /// @notice One holder's dropped ticket blocks nobody: the same away chain still takes new asks and lands their
    ///         honest receipts.
    function test_receiveReceipt_doesNotBlockTheAwayChain_whenTheTicketIsUnknown() public {
        (,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        uint256 honestAmount = 3;
        bytes32 honestId = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, honestAmount, honestAmount);
        _relayAll(polygonGateway);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(honestId, honestAmount);
        _relayAll(polygonGateway);

        _assertStatus(honestId, ITickets.TicketStatus.Done, "the honest receipt is applied");
        assertEq(token.awayBalanceOf(charlieSat), honestAmount);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the away chain stays open");
    }

    function test_resendReceipt_changesNothing_afterAReceiptWithNoTicketWasBooked() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        vm.warp(block.timestamp + polygonLite.receiptResendWait());
        polygonLite.resendReceipt(uint8(MessageTypesLib.Message.TICKET), ticketId);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(ticketId, polygon);
        polygonGateway.relay(polygonGateway.queueLength() - 1);

        assertEq(token.onHoldOf(ticketId), FOUR, "booked once");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), FOUR, "credited once");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - FOUR);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice A second reorg drops the same ask mined again: the away token answers the second copy with its stored
    ///         receipt, which home already counted.
    function test_receiveReceipt_countsTheReceiptOnce_whenASecondReorgDropsTheAskAgain() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        _deliverToTheAwayToken(polygonGateway, polygonLite, _droppedCopy(aliceSat, bobSat, FOUR, salt));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(ticketId, polygon);
        _relayAll(polygonGateway);

        assertEq(token.onHoldOf(ticketId), FOUR, "counted once");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), FOUR);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    function test_receiveReceipt_blocksTheChain_whenAReceiptWithNoTicketNamesASenderOnAnotherAwayChain() public {
        bytes32 inventedId = keccak256("an id the optimism away token invents");
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(inventedId, aliceSat, bobSat, FOUR);
        uint256 index = _awayTokenSends(optimismGateway, optimismLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(
            inventedId, optimism, FOUR, receipt.askBlockHash, ITickets.ReceiptRefusal.WrongChain
        );
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockSet(optimism, true);
        optimismGateway.relay(index);

        assertEq(boundCompliance.ticketOf(inventedId).fromIdentity, address(0), "nothing booked");
        assertEq(token.onHoldOf(inventedId), 0);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "alice's tokens never moved");
        assertTrue(boundCompliance.isAwayChainBlocked(optimism), "the chain that sent it is blocked");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the chain that holds alice is not");
    }

    /// @notice A sender that names no wallet is on no chain: the receipt is refused and the chain that sent it is
    ///         blocked, the delivery does not revert.
    function test_receiveReceipt_blocksTheChain_whenAReceiptWithNoTicketNamesNoSender() public {
        bytes32 inventedId = keccak256("an id with an empty sender");
        bytes memory noSender = "";
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(inventedId, noSender, bobSat, FOUR);
        uint256 index = _awayTokenSends(optimismGateway, optimismLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(
            inventedId, optimism, FOUR, receipt.askBlockHash, ITickets.ReceiptRefusal.WrongChain
        );
        optimismGateway.relay(index);

        assertEq(token.onHoldOf(inventedId), 0, "nothing booked");
        assertTrue(boundCompliance.isAwayChainBlocked(optimism), "the chain that sent it is blocked");
    }

    /// @notice A sender written with a trailing byte is not the wallet of the chain that sent it, even when the
    ///         wallet it starts with is: refused, and the chain blocked.
    function test_receiveReceipt_blocksTheChain_whenAReceiptWithNoTicketNamesASenderWithATrailingByte() public {
        bytes32 inventedId = keccak256("an id with a padded sender");
        bytes memory paddedSender = bytes.concat(aliceSat, hex"00");
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(inventedId, paddedSender, bobSat, FOUR);
        uint256 index = _awayTokenSends(polygonGateway, polygonLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(
            inventedId, polygon, FOUR, receipt.askBlockHash, ITickets.ReceiptRefusal.WrongChain
        );
        polygonGateway.relay(index);

        assertEq(token.onHoldOf(inventedId), 0, "nothing booked");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "alice's tokens never moved");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the chain that sent it is blocked");
    }

    /// @notice A receiver written with a trailing byte names no wallet: the receipt is refused and the chain that
    ///         sent it is blocked, the delivery does not revert.
    function test_receiveReceipt_blocksTheChain_whenAReceiptWithNoTicketNamesAReceiverWithATrailingByte() public {
        _assertAMalformedReceiverIsRefused(keccak256("an id with a padded receiver"), FOUR);
    }

    /// @notice The same for a zero receipt: it would otherwise end the id, and it reverted the delivery instead.
    function test_receiveReceipt_blocksTheChain_whenAZeroReceiptWithNoTicketNamesAReceiverWithATrailingByte() public {
        _assertAMalformedReceiverIsRefused(keccak256("a zero receipt with a padded receiver"), 0);
    }

    /// @notice A cancel of a ticket waiting for approval is refused while a receipt for its first half waits and can
    ///         now be placed: whoever wants the ticket to move on applies the receipt first.
    function test_cancelTickets_reverts_when_aReceiptForATicketWaitingForApprovalCanNowBePlaced() public {
        _bindApprovalModule(approver);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        _askAgain(aliceSat, bobSat, FOUR, salt);
        _blockPolygon();
        polygonGateway.relay(receiptIndex);
        _unblockPolygon();
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ticketId;

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, ticketId, polygon));
        boundCompliance.cancelTickets(ids);

        _assertStatus(ticketId, ITickets.TicketStatus.WaitingForApproval, "not cancelled");
    }

    /// @notice Taking money on hold is an ask: it counts in the identity's asks per window, so the next ask in the
    ///         window is refused once the take used the last one.
    function test_askToMove_countsATakeOfMoneyOnHold_inTheIdentitysAsksPerWindow() public {
        _setAsksPerWindow(1);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        _askAgain(aliceSat, bobSat, FOUR, salt);
        assertTrue(boundCompliance.ticketOf(ticketId).written, "the ask took the money on hold");

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AskLimitReached.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceSat, bobSat, 1, 1, "", _salt());
    }

    /// @notice A take over the identity's asks per window is refused before anything moves.
    function test_askToMove_reverts_when_aTakeOfMoneyOnHoldIsOverTheAskLimit() public {
        _setAsksPerWindow(1);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 1);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AskLimitReached.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);

        assertFalse(boundCompliance.ticketOf(ticketId).written, "the money is still on hold, not taken");
    }

    /// @notice A ticket home wrote and never sent waited for approval, so home's own copy is its only honest one: a
    ///         receipt on any other copy breaks its terms and blocks the chain, and is still booked on hold.
    function test_receiveReceipt_putsTheReceiptOnHoldAndBlocksTheChain_whenTheTicketNeverLeft() public {
        _bindApprovalModule(approver);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        _askAgain(aliceSat, bobSat, FOUR, salt);
        _assertStatus(ticketId, ITickets.TicketStatus.WaitingForApproval, "written, never sent");
        assertEq(token.reservedOf(aliceSat), FOUR, "the ask reserved it");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(ticketId, polygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        ITickets.Ticket memory held = boundCompliance.ticketOf(ticketId);
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold), "booked on hold");
        assertFalse(held.written, "no copy home sent was executed");
        assertEq(token.reservedOf(aliceSat), 0, "the ask's reservation is given back");
        assertEq(token.onHoldOf(ticketId), FOUR);
        assertEq(token.awayBalanceOf(bobSat), 0, "never applied as the ticket's move");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the receipt breaks the terms of the ticket");
        _assertPositionsAreTheSupply();
    }

    /// @notice A receipt that arrives before the approver's answer is booked on hold: the approver can no longer open
    ///         the ticket, so the receipt is never applied as the move home allowed.
    function test_answerApproval_doesNotApplyAReceiptThatCameBeforeTheAnswer() public {
        AsyncApprovalModule module = _bindApprovalModule(approver);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        _askAgain(aliceSat, bobSat, FOUR, salt);
        polygonGateway.relay(receiptIndex);

        vm.prank(approver);
        module.approveValidation(address(boundCompliance), ticketId, FOUR);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.NotWaitingForApproval.selector, ticketId, uint8(ITickets.TicketStatus.OnHold)
            )
        );
        module.finalize(address(boundCompliance), ticketId);

        assertEq(token.awayBalanceOf(bobSat), 0, "bob is not credited");
        _assertPositionsAreTheSupply();
    }

    /// @notice The ask mined again goes out even while the receipt of its dropped copy waits at home: the away token
    ///         answers the new copy with the receipt it stored.
    function test_askToMove_sendsTheTicket_whileTheReceiptOfItsDroppedCopyWaits() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        _blockPolygon();
        polygonGateway.relay(receiptIndex);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, 0);
        assertTrue(boundCompliance.waitingReceiptOf(halfKey).bodyHash != bytes32(0), "the receipt waits");
        _unblockPolygon();
        uint256 sentSoFar = polygonGateway.queueLength();

        _askAgain(aliceSat, bobSat, FOUR, salt);

        assertEq(polygonGateway.queueLength(), sentSoFar + 1, "the ticket left");
        assertTrue(boundCompliance.ticketOf(ticketId).sent, "sent");
    }

    /// @notice The same, while the chain is blocked: the receipt waits and the approver still answers. The first send
    ///         is refused over the waiting receipt, which is booked on hold once applied.
    function test_answerApproval_answers_whenAReceiptWithNoTicketWaitsUnderABlock() public {
        AsyncApprovalModule module = _bindApprovalModule(approver);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        _askAgain(aliceSat, bobSat, FOUR, salt);
        MessageTypesLib.ReceiptMessage memory receipt = _receiptAt(polygonGateway, receiptIndex);
        _blockPolygon();
        polygonGateway.relay(receiptIndex);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, 0);
        assertTrue(boundCompliance.waitingReceiptOf(halfKey).bodyHash != bytes32(0), "the receipt waits");

        vm.prank(approver);
        module.approveValidation(address(boundCompliance), ticketId, FOUR);
        module.finalize(address(boundCompliance), ticketId);
        _assertStatus(ticketId, ITickets.TicketStatus.Open, "opened by the answer");

        _unblockPolygon();
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, ticketId, polygon));
        boundCompliance.sendTicket(ticketId, bobSat, "");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(ticketId, polygon, aliceSat, bobSat, FOUR);
        boundCompliance.applyWaitingReceipt(halfKey, receipt);

        _assertStatus(ticketId, ITickets.TicketStatus.OnHold, "booked on hold");
        assertEq(token.onHoldOf(ticketId), FOUR);
        assertEq(token.reservedOf(aliceSat), 0);
    }

    /* ----- The take ----- */

    function test_askToMove_takesTheMoneyOnHold_whenTheSameAskIsMinedAgain() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        uint256 movesToldBefore = rules.transferActionCalls();

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.HoldTaken(ticketId);
        bytes32 takenId = _askAgain(aliceSat, bobSat, FOUR, salt);

        assertEq(takenId, ticketId, "the same id");
        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the move is finished");
        assertEq(token.awayBalanceOf(bobSat), FOUR, "counted for bob");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 0, "no credit left");
        assertEq(token.onHoldOf(ticketId), 0);
        assertEq(boundCompliance.positionOf(address(aliceIdentity)), ALICE_AWAY_BALANCE - FOUR, "alice's position");
        assertEq(boundCompliance.positionOf(address(bobIdentity)), FOUR, "bob's position");
        assertEq(rules.transferActionCalls(), movesToldBefore + 1, "the tracker is told once");
        _assertHomeAgreesWithPolygon();
    }

    function test_askToMove_takesTheMoney_evenWhenTheSenderHasNothingFreeLeft() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) =
            _droppedAsk(aliceOnPolygon, aliceSat, bobSat, ALICE_AWAY_BALANCE);
        polygonGateway.relay(receiptIndex);
        assertEq(token.awayBalanceOf(aliceSat), 0, "alice has nothing free");

        _askAgain(aliceSat, bobSat, ALICE_AWAY_BALANCE, salt);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "taken");
        assertEq(token.awayBalanceOf(bobSat), ALICE_AWAY_BALANCE);
        _assertHomeAgreesWithPolygon();
    }

    /// @notice A dropped copy above the away chain's per-ticket cap was executed all the same: the ask mined again
    ///         takes it as it happened, and the chain that made it is blocked. Nothing reverts.
    function test_askToMove_takesTheHeldReceiptAndBlocksTheChain_whenItPassesThePerTicketCap() public {
        // The cap may be lowered once every ticket sent toward the chain is past its valid until.
        vm.warp(block.timestamp + 1 days);
        uint256 perTicketCap = 1;
        vm.prank(deployer);
        boundCompliance.setTicketLimits(polygon, perTicketCap, perTicketCap);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, TWO);
        polygonGateway.relay(receiptIndex);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.HoldTaken(ticketId);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockSet(polygon, true);
        _askAgain(aliceSat, bobSat, TWO, salt);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "taken as it happened");
        assertEq(token.awayBalanceOf(bobSat), TWO, "counted for bob");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the chain that made the move is blocked");
        _assertHomeAgreesWithPolygon();
    }

    /// @notice A hostile away token books another holder's money under Bob's own request id. Bob's ask must not take
    ///         it: the held receipt names Alice's wallet, not Bob's.
    function test_askToMove_reverts_when_theHeldReceiptNamesOtherWallets() public {
        bytes32 salt = _salt();
        bytes32 bobsId = _ticketId(bobSat, bobHome, "", FOUR, FOUR, salt);
        MessageTypesLib.ReceiptMessage memory aliceAsSender = _receiptWithNoTicket(bobsId, aliceSat, bobHome, FOUR);
        polygonGateway.relay(_awayTokenSends(polygonGateway, polygonLite, aliceAsSender));
        assertEq(token.onHoldOf(bobsId), FOUR, "alice's money is on hold under bob's id");

        vm.prank(address(bobIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HeldReceiptBreaksItsTerms.selector, bobsId));
        boundCompliance.askToMove(bobSat, bobHome, FOUR, FOUR, "", salt);

        assertEq(token.balanceOf(bob), 0, "bob is minted nothing at home");
        assertEq(token.onHoldOf(bobsId), FOUR, "the money stays on hold for its cancel");
    }

    /// @notice A receipt naming Alice's wallet waits under Bob's request id while the token is stopped; Bob's ask is
    ///         then mined. Applying the waiting receipt judges it again against the ticket: it is refused and blocks
    ///         its chain, and Bob is minted nothing.
    function test_applyWaitingReceipt_refusesAReceiptNamingOtherWallets_onceTheTicketIsWritten() public {
        vm.prank(agent);
        token.mint(bob, FOUR);
        vm.prank(bob);
        boundCompliance.askToMove(bobHome, bobSat, FOUR, FOUR, "", _salt());
        _relayAll(polygonGateway);
        _relayAll(polygonGateway);
        assertEq(token.awayBalanceOf(bobSat), FOUR, "bob holds 4 on Polygon");

        bytes32 salt = _salt();
        bytes32 bobsId = _ticketId(bobSat, bobHome, "", FOUR, FOUR, salt);
        _pauseTheToken();
        MessageTypesLib.ReceiptMessage memory aliceAsSender = _receiptWithNoTicket(bobsId, aliceSat, bobHome, FOUR);
        polygonGateway.relay(_awayTokenSends(polygonGateway, polygonLite, aliceAsSender));
        bytes32 halfKey = MessageTypesLib.halfKeyOf(bobsId, 0);
        assertTrue(boundCompliance.waitingReceiptOf(halfKey).bodyHash != bytes32(0), "it waits");
        vm.prank(agent);
        token.unpause();
        vm.prank(address(bobIdentity));
        boundCompliance.askToMove(bobSat, bobHome, FOUR, FOUR, "", salt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(
            bobsId, polygon, FOUR, aliceAsSender.askBlockHash, ITickets.ReceiptRefusal.WrongWallets
        );
        boundCompliance.applyWaitingReceipt(halfKey, aliceAsSender);

        assertEq(token.balanceOf(bob), 0, "bob is minted nothing at home");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "alice keeps her away balance");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the chain that sent it is blocked");
        assertEq(boundCompliance.waitingReceiptOf(halfKey).bodyHash, bytes32(0), "it no longer waits");
        _assertStatus(bobsId, ITickets.TicketStatus.Open, "bob's ticket stays open");
    }

    /// @notice A zero receipt ended an id whose sender was linked to no identity. That id is recorded all the same:
    ///         once the wallet is linked, an ask under it is refused, so no ticket is written over an answered id
    ///         whose real receipt would then be refused as another body and block the chain.
    function test_askToMove_reverts_when_aZeroReceiptFromAnUnlinkedWalletEndedTheId() public {
        Account memory daveOnPolygon = makeAccount("daveOnPolygon");
        bytes memory daveSat = InteroperableAddress.formatEvmV1(POLYGON, daveOnPolygon.addr);
        bytes32 salt = _salt();
        bytes32 ticketId = _ticketId(daveSat, bobSat, "", FOUR, FOUR, salt);
        MessageTypesLib.ReceiptMessage memory nothingMoved = _receiptWithNoTicket(ticketId, daveSat, bobSat, 0);
        polygonGateway.relay(_awayTokenSends(polygonGateway, polygonLite, nothingMoved));
        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the id is ended");

        _linkSatelliteWallet(aliceIdentity, POLYGON, daveOnPolygon);
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketAlreadyWritten.selector, ticketId));
        boundCompliance.askToMove(daveSat, bobSat, FOUR, FOUR, "", salt);
    }

    function test_askToMove_reverts_when_theIdWasAnsweredWithZero() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory droppedCopy = _droppedCopy(aliceSat, bobSat, FOUR, salt);
        bytes32 ticketId = droppedCopy.ticketId;
        _deliverToTheAwayToken(polygonGateway, polygonLite, droppedCopy);
        // Past its valid until, a copy delivered again is answered with a stored zero receipt.
        vm.warp(droppedCopy.validUntil);
        _deliverToTheAwayToken(polygonGateway, polygonLite, droppedCopy);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(ticketId, polygon, 0);
        _relayAll(polygonGateway);
        _assertStatus(ticketId, ITickets.TicketStatus.Done, "nothing moved");

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketAlreadyWritten.selector, ticketId));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);
    }

    /// @notice An approver never saw the move the away token made: while an approval module is bound, the ask
    ///         mined again cannot take the money on hold. Modules change only while nothing is reserved, so the
    ///         module is bound before the receipt lands.
    function test_askToMove_reverts_when_anApprovalModuleIsBound() public {
        _bindApprovalModule(approver);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketAlreadyWritten.selector, ticketId));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);
    }

    /// @notice A ticket home wrote and never sent was booked on hold by a receipt: an ask wrote that id, so once the
    ///         approval module is gone the same ask mined again still cannot take the money over.
    function test_askToMove_reverts_when_theHoldIsOfATicketHomeWroteAndNeverSent() public {
        AsyncApprovalModule module = _bindApprovalModule(approver);
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        _askAgain(aliceSat, bobSat, FOUR, salt);
        polygonGateway.relay(receiptIndex);
        _assertStatus(ticketId, ITickets.TicketStatus.OnHold, "booked on hold");
        // Money on hold keeps the module set as it is; only the owner's forced removal takes the module out.
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.forceRemoveModule(address(module));
        boundCompliance.setAsksPaused(bytes32(0), false);
        vm.stopPrank();
        _unblockPolygon();

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketAlreadyWritten.selector, ticketId));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);
    }

    function test_askToMove_reverts_when_theTokenIsPausedAtTheTake() public {
        (, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        _pauseTheToken();

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TokenPaused.selector));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);
    }

    function test_askToMove_reverts_when_theSendersChainIsBlockedAtTheTake() public {
        (, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        _blockPolygon();

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);
    }

    function test_askToMove_reverts_when_aHostileChangeRunsAtTheTake() public {
        (, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        _replacePolygonPeerAsHostile();
        uint64 endsAt = token.hostileChangeEndsAt(polygon);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);
    }

    /// @notice The rules refuse the receiver when the same ask is mined again: the hold is cancelled at once, its bring
    ///         home leaving inside the ask, and the money goes back to the sender.
    function test_askToMove_cancelsTheHold_whenTheRulesRefuseTheReceiverAtTheTake() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        rules.setAllow(false);

        vm.expectEmit(true, true, false, false, address(boundCompliance));
        emit EventsLib.SecondHalfSent(ticketId, 1, polygon, bobSat, FOUR, 0);
        _askAgain(aliceSat, bobSat, FOUR, salt);
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 0, "the bring home takes bob's credit");

        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the money is back");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        assertEq(token.awayBalanceOf(bobSat), 0);
        _assertHomeAgreesWithPolygon();
    }

    /// @notice A move out of the away chain with no ticket: the take sends its second half inside the ask.
    function test_askToMove_sendsTheMoveOut_whenTheHeldReceiptLeftTheAwayChain() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) =
            _droppedAsk(aliceOnPolygon, aliceSat, bobOptimismSat, FOUR);
        polygonGateway.relay(receiptIndex);
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobOptimismSat)), 0, "no credit on another chain");

        _askAgain(aliceSat, bobOptimismSat, FOUR, salt);
        _relayAll(optimismGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "minted on optimism");
        assertEq(token.awayBalanceOf(bobOptimismSat), FOUR);
        assertEq(optimismLite.balanceOf(bobOptimismSat), FOUR);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - FOUR);
    }

    function test_askToMove_returnsTheMoneyToTheSender_whenTheRulesRefuseAReceiverOnAnotherChain() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) =
            _droppedAsk(aliceOnPolygon, aliceSat, bobOptimismSat, FOUR);
        polygonGateway.relay(receiptIndex);
        rules.setAllow(false);

        _askAgain(aliceSat, bobOptimismSat, FOUR, salt);
        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "back to alice");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        assertEq(token.awayBalanceOf(bobOptimismSat), 0);
        assertEq(optimismLite.balanceOf(bobOptimismSat), 0, "optimism minted nothing");
        _assertHomeAgreesWithPolygon();
    }

    function test_askToMove_mintsAtHome_whenTheHeldReceiptWasForAHomeWallet() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobHome, FOUR);
        polygonGateway.relay(receiptIndex);

        _askAgain(aliceSat, bobHome, FOUR, salt);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "minted at home");
        assertEq(token.balanceOf(bob), FOUR);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - FOUR);
        _assertPositionsAreTheSupply();
    }

    /// @notice The same ask mined again after the cancel of its hold started finds no money to take.
    function test_askToMove_reverts_when_theCancelOfTheHoldWasSentFirst() public {
        (bytes32 ticketId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        boundCompliance.cancelHold(ticketId);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketAlreadyWritten.selector, ticketId));
        boundCompliance.askToMove(aliceSat, bobSat, FOUR, FOUR, "", salt);
    }

    /// @notice A dropped ask asked again with other terms is another ticket: it is written as any ask, and the money
    ///         on hold under the first id waits for its own cancel.
    function test_askToMove_writesANewTicket_whenTheDroppedAskIsAskedWithOtherTerms() public {
        (bytes32 heldId, bytes32 salt, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);

        uint256 otherAmount = 3;
        bytes32 newId = _askAgain(aliceSat, bobSat, otherAmount, salt);

        assertTrue(newId != heldId, "another id");
        _assertStatus(newId, ITickets.TicketStatus.Open, "written and sent");
        _assertStatus(heldId, ITickets.TicketStatus.OnHold, "the hold is untouched");
        assertEq(token.onHoldOf(heldId), FOUR);
    }

    /* ----- The cancel ----- */

    function test_cancelHold_sendsTheMoneyBack_afterFourWaitingTimes() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        uint64 stopWaitingAt = boundCompliance.ticketOf(ticketId).stopWaitingAt;

        vm.warp(stopWaitingAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, ticketId, stopWaitingAt));
        boundCompliance.cancelHold(ticketId);

        vm.warp(stopWaitingAt);
        boundCompliance.cancelHold(ticketId);
        vm.expectEmit(true, true, false, false, address(boundCompliance));
        emit EventsLib.SecondHalfSent(ticketId, 1, polygon, bobSat, FOUR, 0);
        boundCompliance.sendSecondHalf(ticketId, bobSat);

        // The bring home burns 4 on bob, the move out mints 4 to alice, and its receipt ends the hold.
        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the hold is over");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "alice has her 10 back");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 0);
        assertEq(token.onHoldOf(ticketId), 0);
        assertEq(polygonLite.balanceOf(bobSat), 0, "burned on bob");
        _assertHomeAgreesWithPolygon();
        _assertPositionsAreTheSupply();
    }

    /// @notice Two related asks a reorg dropped, Alice to Bob then Bob to Charlie: Bob's receipt is booked carrying
    ///         Alice's credit, and the cancels run last in, first out.
    function test_cancelHold_reversesTheLaterMoveFirst_whenTwoRelatedAsksWereDropped() public {
        (bytes32 aliceId, bytes32 bobId) = _bookTwoRelatedDroppedAsks();

        ITickets.Ticket memory bobsHold = boundCompliance.ticketOf(bobId);
        assertEq(bobsHold.carriedFrom, aliceId, "bob's hold carries alice's credit");
        assertEq(bobsHold.carriedAmount, TWO);
        assertEq(boundCompliance.ticketOf(aliceId).carriedBy, bobId);
        assertEq(token.onHoldOf(bobId), 0, "the carried part stays in alice's hold");
        assertEq(token.onHoldOf(aliceId), TWO);
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 0, "bob's credit is carried");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(charlieSat)), TWO);

        vm.warp(bobsHold.stopWaitingAt);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.LaterHoldStillCarries.selector, aliceId, bobId));
        boundCompliance.cancelHold(aliceId);

        // Bob's move is undone first: charlie's 2 burn, and come back to bob as alice's credit again.
        _cancelHold(bobId, charlieSat);
        _relayAll(polygonGateway);
        _assertStatus(bobId, ITickets.TicketStatus.Done, "bob's hold is over");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), TWO, "the credit is back on bob");
        assertEq(token.awayBalanceOf(bobSat), 0, "never counted for bob");
        assertEq(boundCompliance.ticketOf(aliceId).carriedBy, bytes32(0), "unlinked");

        _cancelHold(aliceId, bobSat);
        _relayAll(polygonGateway);

        _assertStatus(aliceId, ITickets.TicketStatus.Done, "alice's hold is over");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "alice has everything back");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 0);
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(charlieSat)), 0);
        _assertHomeAgreesWithPolygon();
        _assertPositionsAreTheSupply();
    }

    function test_askToMove_waits_untilTheCarriedCreditIsTheHoldersOwn() public {
        (bytes32 aliceId, bytes32 bobId) = _bookTwoRelatedDroppedAsks();
        bytes32 bobSalt = _lastBobSalt;

        vm.prank(address(bobIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.LaterHoldStillCarries.selector, aliceId, bobId));
        boundCompliance.askToMove(bobSat, charlieSat, TWO, TWO, "", bobSalt);

        _askAgain(aliceSat, bobSat, TWO, _lastAliceSalt);
        _assertStatus(aliceId, ITickets.TicketStatus.Done, "alice's taken");
        _askAgainAs(address(bobIdentity), bobSat, charlieSat, TWO, bobSalt);

        _assertStatus(bobId, ITickets.TicketStatus.Done, "bob's taken");
        assertEq(token.awayBalanceOf(charlieSat), TWO);
        assertEq(token.awayBalanceOf(bobSat), 0);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - TWO);
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(charlieSat)), 0);
        _assertHomeAgreesWithPolygon();
        _assertPositionsAreTheSupply();
    }

    /// @notice The carried part is not held a second time: two holds on one wallet's credit reserve in the ledger's
    ///         total only the money actually on hold, and the carried part joins the later hold's reservation when it
    ///         becomes its own.
    function test_receiveReceipt_reservesOnlyTheMoneyOnHold_whenALaterHoldCarriesTheCredit() public {
        (bytes32 aliceId, bytes32 bobId) = _bookTwoRelatedDroppedAsks();
        assertEq(boundCompliance.ticketOf(bobId).carriedAmount, TWO, "bob's hold carries alice's credit");
        assertEq(token.totalOnHold(), TWO, "only alice's hold holds tokens");
        assertEq(_reservedTotal(), token.totalOnHold(), "the reserved total is the money on hold");

        _askAgain(aliceSat, bobSat, TWO, _lastAliceSalt);

        _assertStatus(aliceId, ITickets.TicketStatus.Done, "alice's hold is taken");
        assertEq(token.onHoldOf(bobId), TWO, "the carried part is bob's own now");
        assertEq(_reservedTotal(), token.totalOnHold(), "and reserved in bob's hold");
    }

    /// @dev The ledger's reserved total, read from its `erc3643.storage.ComplianceLedger` namespace: it has no view.
    function _reservedTotal() private view returns (uint256) {
        bytes32 base = Utils.erc7201("erc3643.storage.ComplianceLedger");
        uint256 pendingTotalField = 5;
        return uint256(vm.load(address(boundCompliance), bytes32(uint256(base) + pendingTotalField)));
    }

    /// @notice Taking the earlier hold adds the carried part to the later hold: the one path by which money on hold
    ///         grows. The same receipts again add nothing.
    function test_askToMove_addsTheCarriedPartToTheLaterHold_whenTheEarlierHoldIsTaken() public {
        (bytes32 aliceId, bytes32 bobId) = _bookTwoRelatedDroppedAsks();
        assertEq(token.onHoldOf(bobId), 0, "nothing of bob's own on hold yet");

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.HeldInTransit(keccak256(bobSat), bobId, bobSat, TWO);
        _askAgain(aliceSat, bobSat, TWO, _lastAliceSalt);

        assertEq(token.onHoldOf(bobId), TWO, "the later hold grew by the carried part");
        assertEq(token.onHoldOf(aliceId), 0);
        assertEq(token.awayBalanceOf(bobSat), 0, "bob's counted tokens went straight onto his hold");
        assertEq(token.totalOnHold(), TWO);
        ITickets.Ticket memory bobsHold = boundCompliance.ticketOf(bobId);
        assertEq(bobsHold.carriedFrom, bytes32(0), "no longer carries");
        assertEq(bobsHold.carriedAmount, 0);

        vm.warp(block.timestamp + polygonLite.receiptResendWait());
        polygonLite.resendReceipt(uint8(MessageTypesLib.Message.TICKET), aliceId);
        polygonLite.resendReceipt(uint8(MessageTypesLib.Message.TICKET), bobId);
        _relayAll(polygonGateway);
        assertEq(token.onHoldOf(bobId), TWO, "a receipt again adds nothing");
        assertEq(token.totalOnHold(), TWO);
    }

    function test_receiveReceipt_keepsTheMoneyOnHold_whenABringHomeBurnedNothing() public {
        (bytes32 aliceId,) = _bookAliceAndLetBobSpend(TWO);
        uint256 mintsBefore = polygonLite.mints();

        vm.warp(boundCompliance.ticketOf(aliceId).stopWaitingAt);
        _cancelHold(aliceId, bobSat);
        _relayNext(polygonGateway); // the bring home finds nothing to burn on bob
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.CancelHoldShort(aliceId, TWO);
        _relayNext(polygonGateway);
        _relayAll(polygonGateway);

        ITickets.Ticket memory held = boundCompliance.ticketOf(aliceId);
        assertTrue(held.shortCancel, "a short cancel");
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold), "still on hold");
        assertEq(polygonLite.mints(), mintsBefore, "no move out left");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), TWO, "the credit is back");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SecondHalfNotOwed.selector, aliceId));
        boundCompliance.sendSecondHalf(aliceId, bobSat);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.TicketNotCancellable.selector, aliceId, uint8(ITickets.TicketStatus.OnHold)
            )
        );
        boundCompliance.cancelHold(aliceId);
    }

    function test_cancelHold_resumes_whenTheCarriedCreditComesBack() public {
        (bytes32 aliceId, uint256 bobsReceiptIndex) = _bookAliceAndLetBobSpend(TWO);
        bytes32 bobId = _receiptAt(polygonGateway, bobsReceiptIndex).ticketId;
        vm.warp(boundCompliance.ticketOf(aliceId).stopWaitingAt);
        _cancelHold(aliceId, bobSat);
        _relayAll(polygonGateway);
        assertTrue(boundCompliance.ticketOf(aliceId).shortCancel, "alice's cancel came back short");

        // The away token sends Bob's lost receipt again, byte for byte.
        polygonLite.resendReceipt(uint8(MessageTypesLib.Message.TICKET), bobId);
        _relayAll(polygonGateway);
        assertEq(boundCompliance.ticketOf(bobId).carriedFrom, aliceId, "bob's hold carries from alice's");

        vm.warp(boundCompliance.ticketOf(bobId).stopWaitingAt);
        _cancelHold(bobId, charlieSat);
        _relayAll(polygonGateway);
        ITickets.Ticket memory resumed = boundCompliance.ticketOf(aliceId);
        assertFalse(resumed.shortCancel, "the short cancel resumes");
        assertTrue(resumed.secondHalfOwed, "its next bring home is owed");

        uint8 halfBefore = resumed.half;
        boundCompliance.sendSecondHalf(aliceId, bobSat);
        assertEq(boundCompliance.ticketOf(aliceId).half, halfBefore + 1, "a new bring home");
        _relayAll(polygonGateway);

        _assertStatus(aliceId, ITickets.TicketStatus.Done, "alice's hold is over");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        _assertHomeAgreesWithPolygon();
    }

    function test_cancelHold_returnsThePartBurned_andKeepsTheRestShort() public {
        (bytes32 aliceId,) = _bookAliceAndLetBobSpend(1);

        vm.warp(boundCompliance.ticketOf(aliceId).stopWaitingAt);
        _cancelHold(aliceId, bobSat);
        _relayNext(polygonGateway); // the bring home burns the 1 bob still holds
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.CancelHoldShort(aliceId, 1);
        _relayNext(polygonGateway);
        _relayAll(polygonGateway);

        ITickets.Ticket memory held = boundCompliance.ticketOf(aliceId);
        assertEq(held.moved, 1, "the rest stays on hold");
        assertTrue(held.shortCancel);
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - 1, "the part burned is back");
        assertEq(
            token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 1, "the part not burned is bob's credit again"
        );
    }

    /// @notice Once the cancel started, `cancelHold` is not a second door to its halves: an owed bring home is sent
    ///         with `sendSecondHalf` only.
    function test_cancelHold_reverts_when_theCancelAlreadyStarted() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        _cancelHold(ticketId, bobSat);

        vm.warp(boundCompliance.ticketOf(ticketId).secondHalfValidUntil);
        _relayAll(polygonGateway);
        assertTrue(boundCompliance.ticketOf(ticketId).secondHalfOwed, "owed");

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.TicketNotCancellable.selector, ticketId, uint8(ITickets.TicketStatus.OnHold)
            )
        );
        boundCompliance.cancelHold(ticketId);
    }

    /// @notice An owed bring home of the cancel is a half like any other: `sendSecondHalf` sends the next one, for
    ///         what the receiver's credit allows now.
    function test_sendSecondHalf_sendsTheCancelsBringHomeAgain_whenItExpiredUnexecuted() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        _cancelHold(ticketId, bobSat);
        vm.warp(boundCompliance.ticketOf(ticketId).secondHalfValidUntil);
        _relayAll(polygonGateway);
        ITickets.Ticket memory held = boundCompliance.ticketOf(ticketId);
        assertTrue(held.secondHalfOwed, "owed");

        vm.prank(makeAddr("anyone"));
        boundCompliance.sendSecondHalf(ticketId, bobSat);

        ITickets.Ticket memory resent = boundCompliance.ticketOf(ticketId);
        assertEq(resent.half, held.half + 1, "a new bring home");
        assertEq(resent.amountMax, FOUR, "for what bob's credit allows now");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 0, "the bring home takes bob's credit");
        _relayAll(polygonGateway);
        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the hold is over");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
    }

    function test_sendSecondHalf_sendsTheReturnAgain_whenTheMoveOutExpiredUnexecuted() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        _cancelHold(ticketId, bobSat);
        _relayNext(polygonGateway); // the bring home burns on bob
        _relayNext(polygonGateway); // its receipt sends the move out back to alice

        vm.warp(boundCompliance.ticketOf(ticketId).secondHalfValidUntil);
        _relayAll(polygonGateway);
        assertTrue(boundCompliance.ticketOf(ticketId).secondHalfOwed, "the return is owed");

        boundCompliance.sendSecondHalf(ticketId, aliceSat);
        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the hold is over");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        _assertHomeAgreesWithPolygon();
    }

    /// @notice A wallet that moved to itself is both the cancel's receiver and its sender. Once the bring home burned,
    ///         the cancel's half is the move out back to the sender, by its stage and not by its wallet: when that move
    ///         out expired unexecuted, the next half returns what burned, and is never a second bring home.
    function test_sendSecondHalf_sendsTheReturnAgainAsAMoveOut_whenAWalletMovedToItself() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, aliceSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        _cancelHold(ticketId, aliceSat);
        _relayNext(polygonGateway); // the bring home burns 4 on alice
        _relayNext(polygonGateway); // its receipt sends the move out of 4 back to alice
        assertEq(polygonLite.balanceOf(aliceSat), ALICE_AWAY_BALANCE - FOUR, "polygon burned 4");

        vm.warp(boundCompliance.ticketOf(ticketId).secondHalfValidUntil);
        _relayAll(polygonGateway);
        ITickets.Ticket memory held = boundCompliance.ticketOf(ticketId);
        assertTrue(held.secondHalfOwed, "the return is owed");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.SecondHalfSent(
            ticketId, held.half + 1, polygon, aliceSat, FOUR, uint64(block.timestamp) + POLYGON_WINDOW
        );
        boundCompliance.sendSecondHalf(ticketId, aliceSat);
        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "the hold is over");
        assertEq(polygonLite.balanceOf(aliceSat), ALICE_AWAY_BALANCE, "what burned is minted back on polygon");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "and counted at home");
        assertEq(token.onHoldOf(ticketId), 0, "nothing left on hold");
        _assertHomeAgreesWithPolygon();
        _assertPositionsAreTheSupply();
    }

    /// @notice Tokens that left the away chain have no receiver to burn from: the cancel's half is a move out back to
    ///         the sender, sent to her wallet.
    function test_cancelHold_owesTheMoveOutToTheSender_whenTheTokensLeftTheAwayChain() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobOptimismSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);

        _cancelHold(ticketId, aliceSat);
        _relayAll(polygonGateway);

        _assertStatus(ticketId, ITickets.TicketStatus.Done, "back to alice");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE);
        assertEq(optimismLite.balanceOf(bobOptimismSat), 0, "nothing reached optimism");
    }

    function test_sendSecondHalf_reverts_when_theCancelsReceiverIsNotTheOneTheReceiptNamed() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(receiptIndex);
        vm.warp(boundCompliance.ticketOf(ticketId).stopWaitingAt);
        boundCompliance.cancelHold(ticketId);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, ticketId));
        boundCompliance.sendSecondHalf(ticketId, charlieSat);
    }

    function test_cancelHold_reverts_when_theTicketWasWritten() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, ticketId, uint8(ITickets.TicketStatus.Open))
        );
        boundCompliance.cancelHold(ticketId);
    }

    function test_cancelHold_reverts_when_theIdIsUnknown() public {
        bytes32 unknownId = keccak256("never booked");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, unknownId));
        boundCompliance.cancelHold(unknownId);
    }

    /// @notice Within the hostile change, the replaced peer sends a receipt under an id home never wrote: the token
    ///         refuses it before the compliance sees it, and nothing is booked.
    function test_cancelHold_recordsNothing_whenTheFormerPeerSendsAnInventedId() public {
        _replacePolygonPeerAsHostile();
        bytes32 inventedId = keccak256("an id the replaced peer invents");
        uint256 index =
            _awayTokenSends(polygonGateway, polygonLite, _receiptWithNoTicket(inventedId, aliceSat, bobSat, FOUR));

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector,
                polygon,
                InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite))
            )
        );
        polygonGateway.relay(index);

        assertEq(boundCompliance.ticketOf(inventedId).fromIdentity, address(0), "nothing booked");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), 0);
    }

    /* ----- Receipts with no ticket, edge cases ----- */

    function test_receiveReceipt_announcesAndBlocksNobody_whenASecondHalfNamesAnUnknownId() public {
        bytes32 unknownId = keccak256("a second half of nothing");
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(unknownId, "", bobSat, FOUR);
        receipt.half = 1;
        bytes32 halfKey = MessageTypesLib.halfKeyOf(unknownId, 1);

        uint256 first = _awayTokenSends(polygonGateway, polygonLite, receipt);
        uint256 again = _awayTokenSends(polygonGateway, polygonLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptUnknown(halfKey, polygon);
        polygonGateway.relay(first);

        // No hash was written: the same receipt again is announced again, not a duplicate.
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptUnknown(halfKey, polygon);
        polygonGateway.relay(again);

        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(boundCompliance.ticketOf(unknownId).fromIdentity, address(0));
    }

    /// @notice The answer mark is not a refusal reason: an expired answer that moved something, with no ticket, is
    ///         booked on hold like any receipt with no ticket and blocks nobody.
    function test_receiveReceipt_booksOnHold_whenAnExpiredAnswerWithNoTicketMovedSomething() public {
        bytes32 unknownId = keccak256("expired yet moved");
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(unknownId, aliceSat, bobSat, FOUR);
        receipt.answer = MessageTypesLib.ReceiptAnswer.Expired;

        uint256 index = _awayTokenSends(polygonGateway, polygonLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(unknownId, polygon, aliceSat, bobSat, FOUR);
        polygonGateway.relay(index);

        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "nobody is blocked");
        assertEq(token.onHoldOf(unknownId), FOUR, "the amount is on hold");
        assertEq(uint8(boundCompliance.statusOf(unknownId)), uint8(ITickets.TicketStatus.OnHold), "on hold");
    }

    function test_receiveReceipt_blocksTheChain_whenANeverSentTicketsReceiptNamesOtherWallets() public {
        _bindApprovalModule(approver);
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, FOUR, FOUR);
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(ticketId, aliceSat, charlieSat, FOUR);

        uint256 index = _awayTokenSends(polygonGateway, polygonLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(
            ticketId, polygon, FOUR, receipt.askBlockHash, ITickets.ReceiptRefusal.WrongWallets
        );
        polygonGateway.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        _assertStatus(ticketId, ITickets.TicketStatus.WaitingForApproval, "the ticket is untouched");
    }

    /// @notice Only a zero answer moves nothing: a receipt from a wallet to itself is booked like any other, on hold
    ///         under the sender with the same wallet's uncounted credit.
    function test_receiveReceipt_booksOnHold_whenTheReceiptMovedTokensToTheSameWallet() public {
        bytes32 unknownId = keccak256("from a wallet to itself");
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(unknownId, aliceSat, aliceSat, FOUR);

        uint256 index = _awayTokenSends(polygonGateway, polygonLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(unknownId, polygon, aliceSat, aliceSat, FOUR);
        polygonGateway.relay(index);

        _assertStatus(unknownId, ITickets.TicketStatus.OnHold, "booked on hold");
        assertEq(token.onHoldOf(unknownId), FOUR, "the amount is on hold");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE - FOUR, "it left alice's away balance");
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(aliceSat)), FOUR, "and came back to her uncounted");
    }

    function test_applyWaitingReceipt_reverts_when_theSenderCannotCoverAReceiptWithNoTicket() public {
        bytes32 unknownId = keccak256("more than alice holds");
        uint256 aboveTheBalance = ALICE_AWAY_BALANCE + 1;
        MessageTypesLib.ReceiptMessage memory receipt =
            _receiptWithNoTicket(unknownId, aliceSat, bobSat, aboveTheBalance);
        polygonGateway.relay(_awayTokenSends(polygonGateway, polygonLite, receipt));
        bytes32 halfKey = MessageTypesLib.halfKeyOf(unknownId, 0);
        assertTrue(boundCompliance.waitingReceiptOf(halfKey).bodyHash != bytes32(0), "it waits");

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.InsufficientBridgedBalance.selector, aliceSat, ALICE_AWAY_BALANCE, aboveTheBalance
            )
        );
        boundCompliance.applyWaitingReceipt(halfKey, receipt);
    }

    /// @notice A receipt with no ticket waits only while the token is stopped, its chain blocked, or its amount above
    ///         what the sender may spend: a sender with no identity waits for that last reason alone.
    function test_applyWaitingReceipt_reverts_onTheBalanceAlone_when_theSenderOfAReceiptWithNoTicketHasNoIdentity()
        public
    {
        bytes memory strangerSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("strangerOnPolygon"));
        bytes32 unknownId = keccak256("from a wallet nobody linked");
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWithNoTicket(unknownId, strangerSat, bobSat, FOUR);
        polygonGateway.relay(_awayTokenSends(polygonGateway, polygonLite, receipt));
        bytes32 halfKey = MessageTypesLib.halfKeyOf(unknownId, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, strangerSat, 0, FOUR));
        boundCompliance.applyWaitingReceipt(halfKey, receipt);
    }

    function test_applyWaitingReceipt_reverts_when_theRouteOfAReceiptWithNoTicketWasClosed() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        MessageTypesLib.ReceiptMessage memory receipt = _receiptAt(polygonGateway, receiptIndex);
        _blockPolygon();
        polygonGateway.relay(receiptIndex);
        _unblockPolygon();
        _closeEvmChain(token, POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(ticketId, 0), receipt);
    }

    function test_applyWaitingReceipt_booksAReceiptWithNoTicket_onceTheChainIsUnblocked() public {
        (bytes32 ticketId,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);
        MessageTypesLib.ReceiptMessage memory receipt = _receiptAt(polygonGateway, receiptIndex);
        _blockPolygon();
        polygonGateway.relay(receiptIndex);
        _unblockPolygon();

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(ticketId, polygon, aliceSat, bobSat, FOUR);
        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(ticketId, 0), receipt);

        assertEq(token.onHoldOf(ticketId), FOUR);
        assertEq(token.uncountedCreditOf(WalletKeyLib.canonicalKey(bobSat)), FOUR);
    }

    /// @notice What one receipt with no ticket costs to deliver: its hash is written before it is booked.
    function test_receiveReceipt_gasOfAReceiptWithNoTicket() public {
        (,, uint256 receiptIndex) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, FOUR);

        uint256 gasBefore = gasleft();
        polygonGateway.relay(receiptIndex);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("gas to deliver and book a receipt with no ticket", gasUsed);
    }

    function _assertAMalformedReceiverIsRefused(bytes32 inventedId, uint256 amount) private {
        bytes memory paddedReceiver = bytes.concat(bobSat, hex"00");
        MessageTypesLib.ReceiptMessage memory receipt =
            _receiptWithNoTicket(inventedId, aliceSat, paddedReceiver, amount);
        uint256 index = _awayTokenSends(polygonGateway, polygonLite, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(
            inventedId, polygon, amount, receipt.askBlockHash, ITickets.ReceiptRefusal.WrongWallets
        );
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockSet(polygon, true);
        polygonGateway.relay(index);

        assertEq(boundCompliance.ticketOf(inventedId).fromIdentity, address(0), "nothing booked");
        assertEq(token.onHoldOf(inventedId), 0, "nothing on hold");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "alice's tokens never moved");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the chain that sent it is blocked");
    }

    /// @dev Gives every identity `asksPerWindow` asks per day, the other limits out of reach, from a new window: the
    ///  set up's move out of Alice's home wallet was an ask of her identity.
    function _setAsksPerWindow(uint32 asksPerWindow) private {
        ITickets.AskLimits memory limits = ITickets.AskLimits({
            openTicketsPerIdentity: 100, asksPerIdentityPerWindow: asksPerWindow, askWindow: 1 days, smallestAmount: 1
        });
        vm.prank(deployer);
        boundCompliance.setAskLimits(limits);
        vm.warp(block.timestamp + limits.askWindow);
    }

}
