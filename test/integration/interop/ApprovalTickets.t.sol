// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A ticket that waits for an approver: the answer only narrows and opens it, anyone makes the first send, it
///      travels the receipt route at full finality whatever ticket bridge the chain has, and its only honest copy is
///      home's own, so a receipt on any other ask block hash blocks its chain. Polygon has a trusted ticket bridge
///      here, so every receipt-route send below is the approval's doing.
contract ApprovalTicketsTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 2000;
    uint64 internal constant TICKET_DEPTH = 3;

    AsyncApprovalModule internal module;
    address internal backend = makeAddr("institutionBackend");
    address internal stranger = makeAddr("stranger");
    ERC7786GatewayMock internal receiptBridge;
    ERC7786GatewayMock internal ticketBridge;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal bobOnOptimism;

    function setUp() public override {
        super.setUp();
        receiptBridge = _newReceiptBridge(POLYGON);
        ticketBridge = _newTicketBridge(POLYGON, TICKET_DEPTH);
        _openEvmChain(token, POLYGON, address(receiptBridge));
        _openEvmChain(token, OPTIMISM, address(_newReceiptBridge(OPTIMISM)));
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);
        vm.prank(deployer);
        token.setTicketRoute(chainType, chainReference, address(ticketBridge));

        aliceSat =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOnOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        module = _bindApprovalModule();
        vm.prank(agent);
        token.unpause();
    }

    /* ----- The answer ----- */

    /// @notice The answer narrows the ticket and opens it, and sends nothing; the first send then writes the ticket
    ///         at the approved maximum.
    function test_answerApproval_narrowsTheTicket() public {
        bytes32 ticketId = _ask(bobSat, 1, 2);
        bytes32 salt = lastSalt;
        uint64 validUntil = boundCompliance.ticketOf(ticketId).validUntil;
        assertEq(token.reservedOf(aliceSat), 2);
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 2);

        vm.recordLogs();
        _approve(ticketId, 1);
        _assertNothingSent(vm.getRecordedLogs());

        ITickets.Ticket memory opened = boundCompliance.ticketOf(ticketId);
        assertEq(opened.amountMax, 1);
        assertEq(uint8(opened.status), uint8(ITickets.TicketStatus.Open));
        assertEq(opened.askBlockHash, bytes32(0), "not sent yet");
        assertEq(token.reservedOf(aliceSat), 1, "the difference is released on the wallet");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 1, "and in the ledger");
        assertEq(_ledger().pendingOutOf(address(aliceIdentity)), 1);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketWritten(
            ticketId, aliceSat, bobSat, "", 1, 1, 2, validUntil, TicketLib.askBlockHashOf(1, validUntil), salt
        );
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    /// @notice The answer sends nothing, so it needs neither a running token, nor an open chain, nor the end of a
    ///         hostile change: it opens the ticket under all three.
    function test_answerApproval_succeeds_whileTheTokenIsStoppedTheChainBlockedAndAHostileChangeRuns() public {
        bytes32 ticketId = _ask(bobSat, 1, 50);
        vm.prank(agent);
        token.pause();
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        vm.prank(deployer);
        token.replaceHostilePeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("replacementLite")));

        _approve(ticketId, 50);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open));
    }

    /* ----- The first send ----- */

    /// @notice After the yes anyone sends the ticket: it is pinned to the receipt route, written with the send's own
    ///         ask block hash, and its last send is now.
    function test_sendTicket_canBeCalledByAnyone_afterTheApproverSaidYes() public {
        bytes32 ticketId = _ask(bobSat, 1, 50);
        bytes32 salt = lastSalt;
        _approve(ticketId, 50);
        vm.warp(block.timestamp + 5 minutes);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).validUntil;
        bytes32 sendBlocksAskBlockHash = TicketLib.askBlockHashOf(50, validUntil);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketWritten(
            ticketId, aliceSat, bobSat, "", 1, 50, 50, validUntil, sendBlocksAskBlockHash, salt
        );
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.HalfPinned(MessageTypesLib.halfKeyOf(ticketId, 0), polygon, address(receiptBridge));
        vm.prank(stranger);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");

        ITickets.Ticket memory sent = boundCompliance.ticketOf(ticketId);
        assertEq(sent.askBlockHash, sendBlocksAskBlockHash);
        assertEq(sent.lastSentAt, block.timestamp);
    }

    /// @notice A ticket that waited for an approver travels the receipt route, its first send and every ask for its
    ///         receipt, even though the chain has a trusted ticket bridge: a home reorg short of finality could drop
    ///         the answer after the away token acted.
    function test_sendTicket_usesTheReceiptRoute_whenTheTicketWaitedForApproval() public {
        uint64 askedAt = uint64(block.timestamp);
        bytes32 ticketId = _ask(bobSat, 1, 50);
        ITickets.Ticket memory waiting = boundCompliance.ticketOf(ticketId);
        assertTrue(waiting.waitedForApproval);
        assertTrue(waiting.onReceiptRoute);
        assertEq(waiting.validUntil, askedAt + VALIDITY_WINDOW, "the receipt route's window");

        _approve(ticketId, 50);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        assertEq(receiptBridge.queueLength(), 1, "the first send on the receipt bridge");

        vm.warp(waiting.validUntil + POLYGON_WINDOW);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        assertEq(receiptBridge.queueLength(), 2, "the ask on the receipt bridge");
        assertEq(ticketBridge.queueLength(), 0, "never on the ticket bridge");
    }

    /// @notice The first send is refused at valid until: the away token would refuse it there.
    function test_sendTicket_reverts_when_theFirstSendIsAtValidUntil() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).validUntil;
        vm.warp(validUntil);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationExpired.selector, ticketId, validUntil));
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    function test_sendTicket_reverts_when_theFirstSendNamesAnotherChain() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotPartOfValidation.selector, ticketId, optimism));
        boundCompliance.sendTicket(ticketId, optimism, bobSat, "");
    }

    function test_sendTicket_reverts_when_theTokenIsStoppedAtTheFirstSend() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        vm.prank(agent);
        token.pause();

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    function test_sendTicket_reverts_when_theChainIsBlockedAtTheFirstSend() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    function test_sendTicket_reverts_when_aHostileChangeRunsAtTheFirstSend() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        vm.prank(deployer);
        token.replaceHostilePeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("replacementLite")));
        uint64 endsAt = token.hostileChangeEndsAt(polygon);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt));
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    /// @notice The envelopes are checked first, before the token's stop: a wrong receiver or spender is named as such.
    function test_sendTicket_checksTheEnvelopesFirst_atTheFirstSend() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        bytes memory charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        vm.prank(agent);
        token.pause();

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, ticketId));
        boundCompliance.sendTicket(ticketId, polygon, charlieSat, "");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, ticketId));
        boundCompliance.sendTicket(ticketId, polygon, bobSat, charlieSat);
    }

    /// @notice A receipt that waits for a ticket home never sent answers no copy of it: the first send is refused,
    ///         the receipt is booked on hold once applied, and the ticket can no longer be sent.
    function test_sendTicket_reverts_when_aReceiptWaitsForTheApprovedTicket() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory receipt =
            _settlementUnder(ticketId, aliceSat, bobSat, 40, keccak256("a copy home never sent"));
        receiptBridge.relay(_liteSettles(receiptBridge, token, receipt));
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, ticketId, polygon));
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");

        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(ticketId, 0), receipt);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.OnHold));
        assertFalse(boundCompliance.ticketOf(ticketId).written, "booked as a receipt with no ticket");
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector, ticketId, uint8(ITickets.TicketStatus.OnHold)
            )
        );
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    /// @notice An approved ticket's first send counts toward the latest valid until sent to its chain: the per-ticket
    ///         cap is lowered only once that valid until passed, or an honest copy sent under the higher cap would
    ///         echo a maximum above the new one.
    function test_setTicketLimits_reverts_when_theCapIsLoweredBeforeAnApprovedTicketsValidUntil() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        uint64 validUntil = boundCompliance.ticketOf(ticketId).validUntil;
        uint256 lowerCap = 10;

        vm.warp(validUntil - 1);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PerTicketCapLoweredTooEarly.selector, polygon, validUntil));
        boundCompliance.setTicketLimits(polygon, lowerCap, lowerCap);

        vm.warp(validUntil);
        vm.prank(deployer);
        boundCompliance.setTicketLimits(polygon, lowerCap, lowerCap);
        assertEq(boundCompliance.ticketLimitsOf(polygon).perTicketCap, lowerCap);
    }

    /* ----- Cancel of a ticket never sent ----- */

    /// @notice An approved ticket nobody sent is cancelled by anyone from its valid until, not a second before.
    function test_cancelTickets_cancelsAnApprovedTicketNeverSent_fromItsValidUntil() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).validUntil;

        vm.warp(validUntil - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, ticketId, validUntil));
        boundCompliance.cancelTickets(_ids(ticketId));

        vm.warp(validUntil);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketCancelled(ticketId);
        vm.prank(stranger);
        boundCompliance.cancelTickets(_ids(ticketId));
        assertEq(token.reservedOf(aliceSat), 0, "the reservation is back");
    }

    /// @notice A ticket waiting for approval is not cancelled while its away chain is blocked or the token is
    ///         stopped: a receipt waiting there may answer it. Once both are lifted, anyone cancels it.
    function test_cancelTickets_reverts_when_aTicketWaitingForApprovalHasItsChainBlockedAndTheTokenStopped() public {
        bytes32 ticketId = _ask(bobSat, 1, 50);
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil);
        vm.startPrank(agent);
        boundCompliance.blockAwayChain(polygon);
        token.pause();
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.cancelTickets(_ids(ticketId));

        vm.prank(agent);
        token.unpause();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.cancelTickets(_ids(ticketId));

        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.prank(stranger);
        boundCompliance.cancelTickets(_ids(ticketId));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /* ----- A home wallet's move out ----- */

    /// @notice A home wallet's move out waits for the approver with nothing burned; the first send burns it onto hold
    ///         and sends the move out. Unsent, it is cancelled at valid until with nothing burned.
    function test_sendTicket_burnsAHomeWalletOntoHold_atTheFirstSendAfterTheYes() public {
        uint256 homeAmount = 100;
        bytes32 ticketId = _askFromAliceHome(homeAmount);

        _approve(ticketId, homeAmount);
        assertEq(token.balanceOf(alice), homeAmount, "the answer burns nothing");

        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");

        assertEq(token.balanceOf(alice), 0, "burned at the first send");
        assertEq(token.onHoldOf(ticketId), homeAmount);
        (MessageTypesLib.Message messageType,) = MessageTypesLib.decode(receiptBridge.queuedMessage(0).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.MOVE_OUT));
    }

    function test_cancelTickets_burnsNothing_whenAnApprovedHomeMoveOutWasNeverSent() public {
        uint256 homeAmount = 100;
        bytes32 ticketId = _askFromAliceHome(homeAmount);
        _approve(ticketId, homeAmount);
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil);

        boundCompliance.cancelTickets(_ids(ticketId));

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.balanceOf(alice), homeAmount, "nothing was burned");
    }

    /// @notice The home wallet's tokens are burned at the first send, not reserved at the ask: a holder that spent
    ///         them meanwhile makes the first send fail on its balance.
    function test_sendTicket_reverts_when_theHomeHolderSpentItsTokensBeforeTheFirstSend() public {
        uint256 homeAmount = 100;
        bytes32 ticketId = _askFromAliceHome(homeAmount);
        _approve(ticketId, homeAmount);
        vm.prank(agent);
        token.burn(alice, homeAmount);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, homeAmount));
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    /* ----- Receipts on another ask block hash ----- */

    /// @notice An approval-bound ticket narrowed from 2 to 1 comes back executed at 2 under a copy home never sent:
    ///         applied as it happened, on older terms, and its chain is blocked, since only home's own copy is honest.
    function test_receiveReceipt_blocksTheChain_whenAnApprovalBoundTicketComesBackOnAnotherBlock() public {
        bytes32 ticketId = _ask(bobSat, 1, 2);
        _approve(ticketId, 1);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        uint256 index = receiptBridge.queueLength();
        _liteSettles(receiptBridge, token, _receiptUnderACopyHomeNeverSent(ticketId, bobSat, 2));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(ticketId, polygon, 2);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockSet(polygon, true);
        receiptBridge.relay(index);

        assertEq(token.awayBalanceOf(bobSat), 2, "applied as it happened");
        assertEq(boundCompliance.ticketOf(ticketId).moved, 2);
        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice The same toward another away chain: the 2 the away token burned go on hold, and the chain is blocked.
    function test_receiveReceipt_blocksTheChain_whenAnApprovalBoundTicketToAnotherChainComesBackOnAnotherBlock()
        public
    {
        bytes32 ticketId = _ask(bobOnOptimism, 1, 2);
        _approve(ticketId, 1);
        boundCompliance.sendTicket(ticketId, polygon, bobOnOptimism, "");
        uint256 index = receiptBridge.queueLength();
        _liteSettles(receiptBridge, token, _receiptUnderACopyHomeNeverSent(ticketId, bobOnOptimism, 2));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(ticketId, polygon, 2);
        receiptBridge.relay(index);

        ITickets.Ticket memory held = boundCompliance.ticketOf(ticketId);
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold));
        assertEq(held.moved, 2, "on hold as it happened");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "the receiving chain is not blocked");
    }

    /// @notice An approval-bound ticket travels at full finality, so a home reorg drops the ask, the answer and the
    ///         first send together, before any copy left. Mined again once, then twice, the away token only ever holds
    ///         the copy that stayed, and its honest receipt on home's own ask block hash blocks nothing.
    function test_receiveReceipt_doesNotBlockAnHonestChain_underOneAndTwoHomeReorgs() public {
        bytes32 salt = _salt();
        uint256 beforeTheAsk = vm.snapshotState();

        bytes32 firstAskBlockHash = _askApproveAndSendInANewBlock(salt);
        vm.revertToState(beforeTheAsk);
        bytes32 secondAskBlockHash = _askApproveAndSendInANewBlock(salt);
        vm.revertToState(beforeTheAsk);
        vm.roll(block.number + 1);
        bytes32 ticketId = _ticketId(aliceSat, bobSat, "", 1, 50, salt);
        bytes32 keptAskBlockHash = _askApproveAndSendInANewBlock(salt);
        assertTrue(keptAskBlockHash != firstAskBlockHash, "the dropped copies had other ask block hashes");
        assertTrue(keptAskBlockHash != secondAskBlockHash);

        receiptBridge.relay(_liteSettles(receiptBridge, token, _settlement(ticketId, aliceSat, bobSat, 40)));

        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest chain is not blocked");
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 40);
    }

    /* ----- A receipt before the first send ----- */

    /// @notice A receipt that comes before the yes answers no ticket home sent: it is put on hold with no ticket,
    ///         the approver can no longer answer, the ticket can no longer be sent, and once home stopped waiting
    ///         anyone cancels the hold.
    function test_receiveReceipt_putsTheReceiptOnHold_whenItComesBeforeTheYes() public {
        bytes32 ticketId = _ask(bobSat, 1, 50);
        _relayAReceiptHomeNeverSentATicketFor(ticketId, 40);

        vm.prank(address(module));
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotAwaitingApproval.selector, ticketId, uint8(ITickets.TicketStatus.OnHold)
            )
        );
        boundCompliance.answerApproval(ticketId, 50);
        _assertTheHoldIsCancelledOnceHomeStopsWaiting(ticketId);
    }

    /// @notice The same for a receipt that comes between the yes and the first send.
    function test_receiveReceipt_putsTheReceiptOnHold_whenItComesBetweenTheYesAndTheFirstSend() public {
        bytes32 ticketId = _askAndApprove(bobSat, 50);
        _relayAReceiptHomeNeverSentATicketFor(ticketId, 40);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector, ticketId, uint8(ITickets.TicketStatus.OnHold)
            )
        );
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        _assertTheHoldIsCancelledOnceHomeStopsWaiting(ticketId);
    }

    /* ----- Helpers ----- */

    function _ask(bytes memory to, uint256 amountMin, uint256 amountMax) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, to, amountMin, amountMax);
    }

    function _askAndApprove(bytes memory to, uint256 amountMax) private returns (bytes32 ticketId) {
        ticketId = _ask(to, 1, amountMax);
        _approve(ticketId, amountMax);
    }

    /// @dev Alice's home wallet holds `amount` and asks to move it out to Bob on Polygon.
    function _askFromAliceHome(uint256 amount) private returns (bytes32 ticketId) {
        vm.prank(agent);
        token.mint(alice, amount);
        bytes memory aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(alice);
        ticketId = boundCompliance.askToMove(aliceHome, bobSat, amount, amount, "", _salt());
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.WaitingForApproval));
    }

    /// @dev The approver says yes at `amountMax`, and the module answers the compliance.
    function _approve(bytes32 ticketId, uint256 amountMax) private {
        vm.prank(backend);
        module.approveValidation(address(boundCompliance), ticketId, amountMax);
        module.finalize(address(boundCompliance), ticketId);
    }

    /// @dev In a new block: Alice asks with `salt`, the approver says yes, and anyone sends. Returns the copy's ask
    ///  block hash. Writes nothing in this contract, so a revert to a snapshot taken before restores everything.
    function _askApproveAndSendInANewBlock(bytes32 salt) private returns (bytes32) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        vm.prank(address(aliceIdentity));
        bytes32 ticketId = boundCompliance.askToMove(aliceSat, bobSat, 1, 50, "", salt);
        _approve(ticketId, 50);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
        return boundCompliance.ticketOf(ticketId).askBlockHash;
    }

    /// @dev A receipt executed at `amount` toward `to`, echoing a maximum of `seenMax` under a copy home never sent.
    function _receiptUnderACopyHomeNeverSent(bytes32 ticketId, bytes memory to, uint256 seenMax)
        private
        view
        returns (MessageTypesLib.ReceiptMessage memory receipt)
    {
        receipt = _settlementUnder(ticketId, aliceSat, to, seenMax, keccak256("a copy home never sent"));
        receipt.seenMax = seenMax;
    }

    function _relayAReceiptHomeNeverSentATicketFor(bytes32 ticketId, uint256 amount) private {
        MessageTypesLib.ReceiptMessage memory receipt =
            _settlementUnder(ticketId, aliceSat, bobSat, amount, keccak256("a copy home never sent"));
        uint256 index = _liteSettles(receiptBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(ticketId, polygon, aliceSat, bobSat, amount);
        receiptBridge.relay(index);

        assertFalse(boundCompliance.ticketOf(ticketId).written, "no ticket home sent answers it");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "nothing blocks the chain");
    }

    function _assertTheHoldIsCancelledOnceHomeStopsWaiting(bytes32 ticketId) private {
        uint64 stopWaitingAt = boundCompliance.ticketOf(ticketId).stopWaitingAt;
        vm.warp(stopWaitingAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, ticketId, stopWaitingAt));
        boundCompliance.cancelHold(ticketId, bobSat);

        vm.warp(stopWaitingAt);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.HoldCancelled(ticketId);
        vm.prank(stranger);
        boundCompliance.cancelHold(ticketId, bobSat);
    }

    function _assertNothingSent(Vm.Log[] memory logs) private pure {
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.ProtocolMessageSent.selector, "something was sent");
            assertTrue(logs[i].topics[0] != EventsLib.TicketWritten.selector, "the ticket was written");
        }
    }

    function _bindApprovalModule() private returns (AsyncApprovalModule approval) {
        approval = AsyncApprovalModule(
            address(
                new ModuleProxy(
                    address(new AsyncApprovalModule()),
                    abi.encodeCall(AsyncApprovalModule.initialize, (address(suiteManager)))
                )
            )
        );
        address[] memory approvers = new address[](1);
        approvers[0] = backend;
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(AsyncApprovalModule.setApprovers, (approvers));
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(true);
        boundCompliance.addAndSetModule(address(approval), settings);
        boundCompliance.setAsksPaused(false);
        vm.stopPrank();
    }

    function _ledger() private view returns (IComplianceLedger) {
        return IComplianceLedger(address(boundCompliance));
    }

    function _ids(bytes32 one) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = one;
    }

}
