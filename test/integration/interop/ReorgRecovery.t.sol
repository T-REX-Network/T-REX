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
    SatelliteLiteMock optimismLite;

    Account aliceOnPolygon;
    bytes aliceSat;
    bytes bobSat;
    bytes bobOptimism;
    address backend = makeAddr("institutionBackend");

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        optimismLite = new SatelliteLiteMock(OPTIMISM, address(token), optimismGateway);
        polygonLite.setPeer(optimismLite, optimismGateway);
        optimismLite.setPeer(polygonLite, polygonGateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)));
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, address(optimismLite)));
        vm.stopPrank();

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();

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

    /* ----- Case 2: the issuance is dropped from the canonical chain ----- */

    /// @notice The Lite executed an issuance the canonical chain never saw. Its leg is parked under the id and the
    ///         chain paused, the token untouched. The request sent again with the same terms and salt issues the
    ///         same id in a later block, sends nothing to the chain that already executed, and settles the parked
    ///         leg, which echoes the copy of the dropped block.
    function test_reorg_Success_WhenADroppedIssuanceIsResubmittedWithTheSameSalt() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        assertTrue(polygonLite.known(id));
        assertEq(boundCompliance.ticketOf(id).fromIdentity, address(0), "nothing recorded here");

        _execute(id, 95);
        uint256 report = _last(polygonGateway);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWaiting(id, polygon, 95, orphaned.askBlockHash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(report);

        assertFalse(token.paused(), "the token keeps running");
        assertTrue(token.isInboundPaused(polygon), "the chain that executed before finality is paused");
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(report)), "consumed");
        assertEq(token.awayBalanceOf(bobSat), 0, "nothing applied");
        ITickets.WaitingReceipt memory parked = boundCompliance.waitingReceiptOf(id, polygon);
        assertTrue(parked.exists);
        assertEq(parked.amount, 95);
        assertEq(parked.askBlockHash, orphaned.askBlockHash);

        // The operator lifts the pause once the reorg is understood; the requester sends the request again.
        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        uint256 queued = polygonGateway.queueLength();

        vm.prank(address(aliceIdentity));
        assertEq(boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt), id);
        assertEq(polygonGateway.queueLength(), queued, "no leg toward the chain that already executed");
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Open));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(id, polygon);
        boundCompliance.applyWaitingReceipt(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(id).moved, 95);
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED - 95);
        assertFalse(boundCompliance.waitingReceiptOf(id, polygon).exists);
        assertTrue(
            boundCompliance.ticketOf(id).askBlockHash != orphaned.askBlockHash,
            "same request, same id; another block, another copy"
        );
        assertFalse(token.isInboundPaused(polygon));
    }

    /// @notice A validation is not discarded over the leg parked under its id: the report of the movement is
    ///         already here, so the discard waits for it, for the public caller as for the keeper. Once the leg is
    ///         settled the validation is `Done`, and never a late reconciliation.
    function test_discardExpiredValidations_RevertWhen_ALegIsParkedUnderTheId_ThenTheLegSettles() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);

        // Nobody settled the parked leg, and the second window passed: the discard is open to anyone.
        ITickets.Ticket memory issued = boundCompliance.ticketOf(id);
        vm.warp(uint256(issued.waitingEndsAt) + (issued.waitingEndsAt - issued.validUntil) + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, id, polygon));
        boundCompliance.cancelTickets(ids);

        boundCompliance.applyWaitingReceipt(id, polygon);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.isIssuancePaused(polygon), "settled, not reconciled late");
    }

    /// @notice The pause the parking set gates both steps of the recovery: the request sent again and the settling
    ///         of the parked leg wait for the pauser, as a leg at the gateway does.
    function test_reorg_RevertWhen_TheChainIsStillPausedForEitherStep() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        assertTrue(token.isInboundPaused(polygon));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);

        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);

        // The pauser looks again before the parked leg is taken: it waits under the pause like any delivery.
        vm.prank(agent);
        token.setInboundPaused(polygon, true);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.applyWaitingReceipt(id, polygon);
        assertTrue(boundCompliance.waitingReceiptOf(id, polygon).exists);

        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        boundCompliance.applyWaitingReceipt(id, polygon);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
    }

    /// @notice The other way out of a drop. The Lite executed the dropped copy above what home narrows the same
    ///         request to when it is mined again: the parked leg fits no issued terms and its ask block hash is
    ///         not the issued one, so the validation ends `Orphaned`, nothing moves, and the chain is paused again.
    function test_reorg_OrphansTheValidation_WhenTheResubmittedTermsNoLongerCoverTheParkedLeg() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        _execute(id, 98);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        // Another ask reserved part of the wallet in the meantime: the same request is now narrowed to 95.
        uint256 reservedByTheOtherAsk = DELEGATED - 95;
        vm.startPrank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 1, reservedByTheOtherAsk, "", _salt());
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        vm.stopPrank();
        assertEq(boundCompliance.ticketOf(id).amountMax, 95, "narrowed by home");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationOrphaned(id, polygon, 98, orphaned.askBlockHash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        boundCompliance.applyWaitingReceipt(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Orphaned));
        assertTrue(token.isInboundPaused(polygon));
        assertEq(token.awayBalanceOf(bobSat), 0, "nothing applied");
        assertEq(token.reservedOf(aliceSat), reservedByTheOtherAsk, "the orphaned ticket's reservation is released");
        assertEq(boundCompliance.pendingInOf(address(bobIdentity)), reservedByTheOtherAsk);
        assertFalse(boundCompliance.waitingReceiptOf(id, polygon).exists);
    }

    /// @notice A dropped two-leg issuance: the sending Lite burned and the receiving Lite minted on its word,
    ///         each leg parked on its own chain. The request sent again settles both and sends nothing.
    function test_reorg_Success_WhenADroppedTwoLegIssuanceIsResubmitted() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobOptimism, 90, 100);
        bytes32 id = orphaned.ticketId;
        _deliverToLite(optimismGateway, optimismLite, orphaned);

        _execute(id, 95);
        _relayAll(polygonGateway);
        _relayAll(optimismGateway);
        assertEq(optimismLite.balanceOf(bobOptimism), 95, "minted on the burn message");
        assertTrue(boundCompliance.waitingReceiptOf(id, polygon).exists, "the burn leg is parked");
        assertTrue(boundCompliance.waitingReceiptOf(id, optimism).exists, "the mint leg is parked");
        assertTrue(token.isInboundPaused(polygon));
        assertTrue(token.isInboundPaused(optimism));
        assertFalse(token.paused());
        assertEq(token.onHoldOf(id), 0, "nothing applied");

        vm.startPrank(agent);
        token.setInboundPaused(polygon, false);
        token.setInboundPaused(optimism, false);
        vm.stopPrank();
        uint256 polygonQueued = polygonGateway.queueLength();
        uint256 optimismQueued = optimismGateway.queueLength();

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobOptimism, 90, 100, "", salt);
        assertEq(polygonGateway.queueLength(), polygonQueued, "nothing sent");
        assertEq(optimismGateway.queueLength(), optimismQueued, "nothing sent");

        // Either order: the mint leg first waits as it does at delivery.
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(id, optimism);
        boundCompliance.applyWaitingReceipt(id, optimism);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.AwaitingBurn));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(id, polygon);
        boundCompliance.applyWaitingReceipt(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED - 95);
        assertEq(token.awayBalanceOf(bobOptimism), 95);
        assertEq(token.onHoldOf(id), 0);
        assertEq(token.totalAwayBalance(), DELEGATED);
    }

    /// @notice A parked leg for a request that then waits for approval stays parked until the answer: issued, it
    ///         settles.
    function test_reorg_Success_WhenTheResubmittedRequestWaitsForApproval() public {
        AsyncApprovalModule module = _bindApprovalModule();
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.WaitingForApproval));
        assertTrue(boundCompliance.waitingReceiptOf(id, polygon).exists, "waits for the answer");
        assertEq(token.awayBalanceOf(bobSat), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoWaitingReceipt.selector, id, polygon));
        boundCompliance.applyWaitingReceipt(id, polygon);

        vm.prank(backend);
        module.approveValidation(address(boundCompliance), id, 100);
        module.finalize(address(boundCompliance), id);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Open));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(id, polygon);
        boundCompliance.applyWaitingReceipt(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.waitingReceiptOf(id, polygon).exists);
    }

    /// @notice Refused, the request issues nothing and the leg stays parked for the operator to read.
    function test_reorg_LeavesTheLegParked_WhenTheResubmittedRequestIsRefused() public {
        AsyncApprovalModule module = _bindApprovalModule();
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertTrue(boundCompliance.waitingReceiptOf(id, polygon).exists, "left for the operator");
        assertEq(boundCompliance.waitingReceiptOf(id, polygon).amount, 95);
        assertEq(token.awayBalanceOf(bobSat), 0);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoWaitingReceipt.selector, id, polygon));
        boundCompliance.applyWaitingReceipt(id, polygon);
    }

    /// @notice The requester need not come back: the copy the Lite holds carries the whole request, the asked
    ///         maximum and the salt included, so an agent sends the request again on their behalf from it.
    function test_reorg_Success_WhenAnAgentResubmitsFromTheLitesCopy() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        MessageTypesLib.TicketMessage memory held = polygonLite.ticketOf(id);
        ITickets.WaitingReceipt memory parked = boundCompliance.waitingReceiptOf(id, polygon);
        assertEq(held.salt, salt, "the salt is final on the satellite");

        assertEq(parked.from, held.from, "the parked leg names the wallets of the copy held");
        vm.prank(agent);
        assertEq(
            boundCompliance.askToMove(held.from, held.to, held.amountMin, held.requestedMax, held.spender, held.salt),
            id
        );
        boundCompliance.applyWaitingReceipt(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
    }

    /* ----- Case 3: the same id, another copy ----- */

    /// @notice The Lite holds the copy of the dropped block and has not executed when the copy mined again lands
    ///         under the same id: it keeps the first copy, executes it, and its receipt echoes it. The amount
    ///         sits inside the issued terms, so the leg settles, with the other copy on record.
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
        emit EventsLib.SettlementBodyDiverged(id, polygon, orphaned.askBlockHash);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertFalse(token.isInboundPaused(polygon));
    }

    /// @notice The Lite executed the copy of the dropped block at an amount the copy mined again also covers:
    ///         the leg settles, with the divergence on record.
    function test_reorg_Success_WhenTheLegExecutedUnderAnotherBodyFitsTheIssuedTerms() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.SettlementBodyDiverged(id, polygon, orphaned.askBlockHash);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(id, polygon);
        boundCompliance.applyWaitingReceipt(id, polygon);

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
