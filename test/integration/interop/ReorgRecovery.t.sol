// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev The reference chain against Lites that execute a validation attested before this chain's finality, so a
///      reorg can reorder, drop or re-issue an issuance after a Lite acted on it. Three things hold it together: the
///      id is a function of the whole request, never of its block; a leg reported for an id nothing is issued
///      under is parked and settled once the request is sent again with the same terms and salt; and the ask block
///      hash a leg echoes tells a copy from a block a reorg dropped from a Lite that broke a rule. See
///      `docs/satellite-lite.md`, "Lanes".
///
///      The issuance a reorg dropped is replayed here by delivering, authored by the token, the body the orphaned
///      fork would have sent: the Lite cannot tell it from one that survived.
contract ReorgRecoveryTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;
    uint256 internal constant DELEGATED = 500;

    ERC7786GatewayMock polygonGateway;
    ERC7786GatewayMock optimismGateway;
    SatelliteLiteMock polygonLite;

    Account aliceOnPolygon;
    bytes aliceSat;
    bytes bobSat;
    address backend = makeAddr("institutionBackend");

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)));
        vm.stopPrank();

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();

        // A dropped copy carries at most the per-ticket cap of its away chain.
        vm.prank(deployer);
        boundCompliance.setTicketLimits(polygon, DELEGATED, DELEGATED);

        vm.prank(alice);
        token.delegateOut(alice, aliceSat, DELEGATED);
        _relayAll(polygonGateway);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED, "the Lite minted what the token delegated");
    }

    /* ----- Case 1: the issuance is re-included behind another one ----- */

    /// @notice Two requests land in the other order on the canonical fork. Each keeps the id its request derives,
    ///         so what the Lite executed under either id settles whatever the order was.
    function test_reorg_Success_WhenIssuancesAreReorderedTheIdsStay() public {
        bytes32 saltA = _salt();
        bytes32 saltB = _salt();
        bytes32 a = _ticketId(aliceSat, bobSat, "", 50, 60, saltA);
        bytes32 b = _ticketId(aliceSat, bobSat, "", 90, 100, saltB);

        // B lands before A: on the orphaned fork it was the other way round.
        vm.startPrank(address(aliceIdentity));
        assertEq(boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", saltB), b);
        assertEq(boundCompliance.askToMove(aliceSat, bobSat, 50, 60, "", saltA), a);
        vm.stopPrank();
        _relayAll(polygonGateway);

        _execute(a, 55);
        _execute(b, 95);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(a)), uint8(ITickets.TicketStatus.Done));
        assertEq(uint8(_status(b)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(a).moved, 55);
        assertEq(boundCompliance.ticketOf(b).moved, 95);
        assertEq(token.awayBalanceOf(bobSat), 150);
        assertFalse(token.isInboundPaused(polygon));
    }

    /* ----- Case 2: the ask is dropped from the canonical chain ----- */

    /// @notice The away token executed a ticket from a home block a reorg dropped. Its receipt names an id home has
    ///         no record of: it reverts and stays deliverable at the bridge, and no chain is blocked. The request
    ///         sent again with the same terms and salt takes the same id in a later block, and the receipt, delivered
    ///         again, is applied on the older terms it echoes.
    function test_reorg_Success_WhenADroppedIssuanceIsResubmittedWithTheSameSalt() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        assertTrue(polygonLite.known(id));
        assertEq(boundCompliance.ticketOf(id).fromIdentity, address(0), "nothing recorded here");

        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, id));
        polygonGateway.relay(receipt);

        assertFalse(token.paused(), "the token keeps running");
        assertFalse(token.isInboundPaused(polygon), "the honest away chain is not blocked");
        assertFalse(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(receipt)));
        assertEq(token.awayBalanceOf(bobSat), 0, "nothing applied");

        vm.prank(address(aliceIdentity));
        assertEq(boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt), id);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Open));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, 100);
        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(id).moved, 95);
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED - 95);
        assertTrue(
            boundCompliance.ticketOf(id).askBlockHash != orphaned.askBlockHash,
            "same request, same id; another block, another copy"
        );
        assertFalse(token.isInboundPaused(polygon));
    }

    /// @notice The ticket mined again is cancelled before the receipt of the dropped copy lands: the receipt is still
    ///         applied, as the move the away token made.
    function test_reorg_Success_WhenTheTicketMinedAgainIsCancelledBeforeTheReceiptLands() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);

        ITickets.Ticket memory issued = boundCompliance.ticketOf(id);
        vm.warp(uint256(issued.waitingEndsAt) + (issued.waitingEndsAt - issued.validUntil) + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        boundCompliance.cancelTickets(ids);
        assertEq(token.reservedOf(aliceSat), 0, "the cancel released the reservation");

        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertFalse(token.isInboundPaused(polygon));
        assertFalse(boundCompliance.isIssuancePaused(polygon), "a late receipt stops nothing");
    }

    /// @notice The away token executed the dropped copy above what home narrows the same request to when it is mined
    ///         again. The receipt is applied on the older terms it echoes, as it happened, and the honest away chain
    ///         stays open.
    function test_reorg_AppliesOnOlderTerms_WhenTheResubmittedTermsNoLongerCoverTheExecutedAmount() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        _execute(id, 98);
        uint256 receipt = _last(polygonGateway);

        // Another ask reserved part of the wallet in the meantime: the same request is now narrowed to 95.
        uint256 reservedByTheOtherAsk = DELEGATED - 95;
        vm.startPrank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 1, reservedByTheOtherAsk, "", _salt());
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        vm.stopPrank();
        assertEq(boundCompliance.ticketOf(id).amountMax, 95, "narrowed by home");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, orphaned.amountMax);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(id, polygon, 98);
        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertFalse(token.isInboundPaused(polygon));
        assertEq(token.awayBalanceOf(bobSat), 98, "applied as it happened");
        assertEq(token.reservedOf(aliceSat), reservedByTheOtherAsk, "the ticket's reservation is released");
        assertEq(boundCompliance.pendingInOf(address(bobIdentity)), reservedByTheOtherAsk);
    }

    /// @notice The request sent again waits for approval: the receipt of the dropped copy now names a ticket written
    ///         and not sent, so it waits here, and is applied once the approval sends the ticket.
    function test_reorg_Success_WhenTheResubmittedRequestWaitsForApproval() public {
        AsyncApprovalModule module = _bindApprovalModule();
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.WaitingForApproval));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWaiting(id, polygon, 95, orphaned.askBlockHash);
        polygonGateway.relay(receipt);
        assertTrue(boundCompliance.waitingReceiptOf(id, polygon).exists, "waits for the answer");
        assertFalse(token.isInboundPaused(polygon), "nothing is blocked");
        assertEq(token.awayBalanceOf(bobSat), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoWaitingReceipt.selector, id, polygon));
        boundCompliance.applyWaitingReceipt(id, polygon);

        vm.prank(backend);
        module.approveValidation(address(boundCompliance), id, 100);
        module.finalize(address(boundCompliance), id);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Open));

        // A waiting receipt waits under a block of its chain, and under a stop of the token, as a delivery does.
        vm.prank(agent);
        token.setInboundPaused(polygon, true);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.applyWaitingReceipt(id, polygon);
        vm.startPrank(agent);
        token.setInboundPaused(polygon, false);
        token.pause();
        vm.stopPrank();
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.applyWaitingReceipt(id, polygon);
        vm.prank(agent);
        token.unpause();

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(id, polygon);
        boundCompliance.applyWaitingReceipt(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.waitingReceiptOf(id, polygon).exists);
    }

    /// @notice Refused, the request sends nothing and the receipt stays waiting for the operator to read.
    function test_reorg_LeavesTheLegParked_WhenTheResubmittedRequestIsRefused() public {
        AsyncApprovalModule module = _bindApprovalModule();
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        polygonGateway.relay(receipt);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertTrue(boundCompliance.waitingReceiptOf(id, polygon).exists, "left for the operator");
        assertEq(boundCompliance.waitingReceiptOf(id, polygon).amount, 95);
        assertEq(token.awayBalanceOf(bobSat), 0);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoWaitingReceipt.selector, id, polygon));
        boundCompliance.applyWaitingReceipt(id, polygon);
    }

    /// @notice The requester need not come back: the copy the away token holds carries the whole request, the asked
    ///         maximum and the salt included, so an agent sends the request again on their behalf from it.
    function test_reorg_Success_WhenAnAgentResubmitsFromTheLitesCopy() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);

        MessageTypesLib.TicketMessage memory held = polygonLite.ticketOf(id);
        assertEq(held.salt, salt, "the salt is final on the satellite");

        vm.prank(agent);
        assertEq(
            boundCompliance.askToMove(held.from, held.to, held.amountMin, held.requestedMax, held.spender, held.salt),
            id
        );
        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
    }

    /* ----- Case 3: the same id, another copy ----- */

    /// @notice The away token holds the copy of the dropped block and has not executed when the copy mined again
    ///         lands under the same id: it keeps the first copy, executes it, and its receipt echoes it. The receipt
    ///         is applied on older terms.
    function test_reorg_Success_WhenTheLiteKeepsTheDroppedCopyAndIgnoresTheCopyMinedAgain() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        _relayAll(polygonGateway);
        assertEq(polygonLite.ticketOf(id).askBlockHash, orphaned.askBlockHash, "the first copy is kept");
        assertEq(polygonLite.ticketOf(id).validUntil, orphaned.validUntil, "with its own valid until");

        _execute(id, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, orphaned.amountMax);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertFalse(token.isInboundPaused(polygon));
    }

    /// @notice The away token executed the copy of the dropped block at an amount the copy mined again also covers:
    ///         the receipt is applied on the older terms it echoes.
    function test_reorg_Success_WhenTheLegExecutedUnderAnotherBodyFitsTheIssuedTerms() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, orphaned.amountMax);
        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertTrue(boundCompliance.ticketOf(id).askBlockHash != orphaned.askBlockHash);
    }

    /// @notice A resend repeats the issuance byte for byte: the Lite ignores it, and so does a Lite that already
    ///         consumed the id whatever body arrives under it.
    function test_reorg_Success_WhenALaterBodyUnderAConsumedIdIsIgnored() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 80, 100);
        bytes32 id = orphaned.ticketId;
        bytes32 executedUnder = orphaned.askBlockHash;
        _execute(id, 95);

        // `orphaned` is a memory reference: `later` is the same body, narrowed in place, so the Lite sees another
        // body under the id it already consumed.
        MessageTypesLib.TicketMessage memory later = orphaned;
        later.amountMin = 90;
        _deliverToLite(polygonGateway, polygonLite, later);

        assertEq(polygonLite.ticketOf(id).amountMin, 80, "consumed: the body held is the one executed");
        assertEq(polygonLite.ticketOf(id).askBlockHash, executedUnder);
    }

    /* ----- Helpers ----- */

    /// @dev Delivers every queued entry of `gateway` not yet delivered or dropped, in order, including the ones a
    ///      delivery queues behind it.
    function _relayAll(ERC7786GatewayMock gateway) private {
        for (uint256 i = 0; i < gateway.queueLength(); i++) {
            ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(i);
            if (message.deliveries == 0 && !message.dropped) gateway.relay(i);
        }
    }

    function _last(ERC7786GatewayMock gateway) private view returns (uint256) {
        return gateway.queueLength() - 1;
    }

    function _execute(bytes32 id, uint256 amount) private {
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(id, amount);
    }

    function _status(bytes32 id) private view returns (ITickets.TicketStatus) {
        return boundCompliance.statusOf(id);
    }

    /// @dev What the ask a reorg dropped sent to the sending Lite: the copy home wrote in the block that did not
    ///      survive, under the id the request gets, authored by the token as the gateway attributes it. Nothing is
    ///      recorded on this chain for it. The asked maximum is not narrowed. The chain then moves on one block and
    ///      one slot, where the same request can be mined again under another ask block hash.
    function _orphanedIssuance(bytes32 salt, bytes memory to, uint256 amountMin, uint256 requestedMax)
        private
        returns (MessageTypesLib.TicketMessage memory body)
    {
        uint64 validUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        body = MessageTypesLib.TicketMessage({
            ticketId: _ticketId(aliceSat, to, "", amountMin, requestedMax, salt),
            salt: salt,
            from: aliceSat,
            to: to,
            spender: "",
            amountMin: amountMin,
            amountMax: requestedMax,
            requestedMax: requestedMax,
            token: address(token),
            validUntil: validUntil,
            askBlockHash: TicketLib.askBlockHashOf(requestedMax, validUntil)
        });
        _deliverToLite(polygonGateway, polygonLite, body);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _deliverToLite(
        ERC7786GatewayMock gateway,
        SatelliteLiteMock lite,
        MessageTypesLib.TicketMessage memory body
    ) private {
        bytes memory recipient = InteroperableAddress.formatEvmV1(gateway.originChainId(), address(lite));
        vm.prank(address(token));
        gateway.sendMessage(recipient, MessageTypesLib.encodeValidation(body), new bytes[](0));
        gateway.relay(_last(gateway));
    }

    function _bindApprovalModule() private returns (AsyncApprovalModule module) {
        module = AsyncApprovalModule(
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
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(module), settings);
    }

}
