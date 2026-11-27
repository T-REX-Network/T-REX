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
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
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

        // The away token is the token's peer before the route opens: a peer set on an open route is a change.
        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)));
        vm.stopPrank();
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

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

        bytes memory aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(alice);
        boundCompliance.askToMove(aliceHome, aliceSat, DELEGATED, DELEGATED, "", _salt());
        _relayAll(polygonGateway);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED, "the Lite minted what the token moved out");
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED, "and its receipt landed");
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
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /* ----- Case 2: the ask is dropped from the canonical chain ----- */

    /// @notice The away token executed a ticket from a home block a reorg dropped. Its receipt names an id home has
    ///         no record of: its amount is put on hold under the sender with no destination, and no chain is blocked.
    ///         The request sent again with the same terms and salt takes the same id in a later block, and takes the
    ///         money on hold: the move the away token made is finished.
    function test_reorg_Success_WhenADroppedIssuanceIsResubmittedWithTheSameSalt() public {
        bytes32 salt = _salt();
        MessageTypesLib.TicketMessage memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.ticketId;
        assertTrue(polygonLite.known(id));
        assertEq(boundCompliance.ticketOf(id).fromIdentity, address(0), "nothing recorded here");

        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(id, polygon, aliceSat, bobSat, 95);
        polygonGateway.relay(receipt);

        assertFalse(token.paused(), "the token keeps running");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest away chain is not blocked");
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.OnHold), "on hold with no destination");
        assertEq(token.onHoldOf(id), 95);
        assertEq(boundCompliance.uncountedCreditOf(bobSat), 95, "bob holds tokens home does not count for him yet");

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.HoldTaken(id);
        vm.prank(address(aliceIdentity));
        assertEq(boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt), id);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(id).moved, 95);
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED - 95);
        assertEq(boundCompliance.uncountedCreditOf(bobSat), 0, "now counted");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
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

        _cancelUnanswered(id, bobSat, "");
        assertEq(token.reservedOf(aliceSat), 0, "the cancel released the reservation");

        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
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

        // A rule bound in the meantime caps what bob may receive: the same request is now narrowed to 95.
        _bindRecipientCap(95);
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        assertEq(boundCompliance.ticketOf(id).amountMax, 95, "narrowed by home");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, orphaned.amountMax);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(id, polygon, 98);
        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(token.awayBalanceOf(bobSat), 98, "applied as it happened");
        assertEq(token.reservedOf(aliceSat), 0, "the ticket's reservation is released");
        assertEq(boundCompliance.pendingInOf(address(bobIdentity)), 0);
    }

    /// @notice The request sent again waits for approval: the receipt of the dropped copy answers no ticket home
    ///         sent, so it is put on hold with no destination, never applied as that ticket's move. A ticket that waits
    ///         for approval has no honest copy but home's own, so the receipt breaks its terms and blocks the chain.
    ///         The approver can no longer answer the request.
    function test_reorg_putsTheReceiptOnHold_whenTheResubmittedRequestWaitsForApproval() public {
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
        emit EventsLib.ReceiptWithoutTicket(id, polygon, aliceSat, bobSat, 95);
        polygonGateway.relay(receipt);

        ITickets.Ticket memory held = boundCompliance.ticketOf(id);
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold), "on hold");
        assertFalse(held.written, "no ticket home sent answers it");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "only home's own copy of an approval ticket is honest");
        assertEq(token.reservedOf(aliceSat), 0, "the request's reservation is released");

        vm.prank(backend);
        module.approveValidation(address(boundCompliance), id, 100);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.NotWaitingForApproval.selector, id, uint8(ITickets.TicketStatus.OnHold))
        );
        module.finalize(address(boundCompliance), id);
    }

    /// @notice Refused before the receipt lands, the request sends nothing; the receipt of the dropped copy is then
    ///         put on hold with no destination, and blocks its chain as any copy but home's own of such a ticket does.
    function test_reorg_putsTheReceiptOnHold_whenTheResubmittedRequestIsRefused() public {
        AsyncApprovalModule module = _bindApprovalModule();
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).ticketId;
        _execute(id, 95);
        uint256 receipt = _last(polygonGateway);

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 90, 100, "", salt);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Cancelled));

        polygonGateway.relay(receipt);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.OnHold), "on hold with no destination");
        assertEq(token.onHoldOf(id), 95);
        assertEq(token.awayBalanceOf(bobSat), 0);
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the refused ticket had only its own copy");
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
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
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

        // `orphaned` is a memory reference: `later` is the same request, narrowed in place as a copy mined in another
        // block would be, so the away token sees another body under the id it already consumed. The id names the
        // request, not the narrowed maximum: a body with other requested terms would be refused as another id.
        MessageTypesLib.TicketMessage memory later = orphaned;
        later.amountMax = 90;
        later.askBlockHash = keccak256("another home block");
        _deliverToLite(polygonGateway, polygonLite, later);

        assertEq(polygonLite.ticketOf(id).amountMax, 100, "consumed: the body held is the one executed");
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

    /// @dev The receipt a queued delivery on the Polygon bridge carries, as `ReceiptWaiting` gives it back.
    function _receiptOf(uint256 index) private view returns (MessageTypesLib.ReceiptMessage memory) {
        (, bytes memory body) = MessageTypesLib.decode(polygonGateway.queuedMessage(index).payload);
        return MessageTypesLib.decodeSettlement(body);
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
        // An approval module is bound only while asks are paused.
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.addAndSetModule(address(module), settings);
        boundCompliance.setAsksPaused(bytes32(0), false);
        vm.stopPrank();
    }

    /// @dev A rule capping what any identity may receive at `cap`, bound while no ticket is open.
    function _bindRecipientCap(uint256 cap) private {
        CappedRecipientModule capRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(capRule));
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (cap)), address(capRule));
        vm.stopPrank();
    }

}
