// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Each away chain has two routes. The ticket route carries tickets out and nothing else, through a ticket
///      bridge; the receipt route carries money messages out and is the only one receipts and burn proofs are taken
///      from, through a receipt bridge. A bridge has one record in the registry, so it is never both kinds, for any
///      away chain. Every message type is tried on each route.
contract TicketAndReceiptRoutesTest is InteropSuiteTest {

    /// @dev The depth the ticket bridges here wait for before they relay.
    uint64 constant TICKET_DEPTH = 3;

    ERC7786GatewayMock receiptBridge;
    ERC7786GatewayMock ticketBridge;
    ERC7786GatewayMock optimismReceiptBridge;

    bytes aliceSat;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        receiptBridge = _newReceiptBridge(POLYGON);
        ticketBridge = _newTicketBridge(POLYGON, TICKET_DEPTH);
        optimismReceiptBridge = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(receiptBridge));
        _openEvmChain(token, OPTIMISM, address(optimismReceiptBridge));
        _setTicketRoute(POLYGON, address(ticketBridge));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), 1000);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();
    }

    function _setTicketRoute(uint256 chainId, address bridge) private {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(chainId);
        vm.prank(deployer);
        token.setTicketRoute(chainType, chainReference, bridge);
    }

    function _issue() private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 100);
    }

    function _bringHome(uint256 amount) private returns (bytes32) {
        vm.prank(agent);
        return boundCompliance.bringHome(aliceSat, amount, alice, _salt());
    }

    /// @dev Queues the away token's receipt for a bring home's first half on `bridge`, burning `amount`.
    function _proof(ERC7786GatewayMock bridge, bytes32 bringHomeId, uint256 amount) private returns (uint256) {
        MessageTypesLib.ReceiptMessage memory receipt = MessageTypesLib.ReceiptMessage({
            ticketId: bringHomeId,
            from: aliceSat,
            to: "",
            amount: amount,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: 1,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
        return _liteSettles(bridge, token, receipt);
    }

    function _aliceHome() private view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, alice);
    }

    /// @dev What the receiving side reverts with when a bridge that is not a receipt bridge delivers.
    function _expectNotAReceiptBridgeDelivery(ERC7786GatewayMock bridge) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(bridge),
                InteroperableAddress.formatEvmV1(bridge.originChainId(), address(token))
            )
        );
    }

    /* ----- Configuration ----- */

    function test_setTicketRoute_setsTheRoutePerAwayChain() public {
        ERC7786GatewayMock otherTicketBridge = _newTicketBridge(POLYGON, TICKET_DEPTH);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.TicketRouteSet(polygon, address(otherTicketBridge));
        _setTicketRoute(POLYGON, address(otherTicketBridge));

        assertEq(token.ticketRouteFor(polygon), address(otherTicketBridge));
        assertEq(token.receiptRouteFor(polygon), address(receiptBridge), "the receipt route is untouched");
        assertEq(token.ticketRouteFor(optimism), address(0), "another away chain is untouched");
        assertEq(token.receiptRouteFor(optimism), address(optimismReceiptBridge));
    }

    function test_setTicketRoute_zeroSendsTicketsOnTheReceiptRoute() public {
        _setTicketRoute(POLYGON, address(0));

        assertEq(token.ticketRouteFor(polygon), address(0));
        assertTrue(token.isChainOpen(polygon), "the away chain stays open on its receipt route");
    }

    function test_setTicketRoute_RevertWhen_TheBridgeIsNotRecorded() public {
        address unknownBridge = address(new ERC7786GatewayMock(POLYGON));
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotATicketBridge.selector, unknownBridge));
        vm.prank(deployer);
        token.setTicketRoute(chainType, chainReference, unknownBridge);
    }

    function test_setTicketRoute_RevertWhen_TheBridgeIsTheReceiptRoute() public {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotATicketBridge.selector, address(receiptBridge)));
        vm.prank(deployer);
        token.setTicketRoute(chainType, chainReference, address(receiptBridge));
    }

    function test_setTicketRoute_RevertWhen_TheBridgeIsTheReceiptBridgeOfAnotherAwayChain() public {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotATicketBridge.selector, address(optimismReceiptBridge)));
        vm.prank(deployer);
        token.setTicketRoute(chainType, chainReference, address(optimismReceiptBridge));
    }

    function test_setReceiptRoute_RevertWhen_TheBridgeIsTheTicketRoute() public {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAReceiptBridge.selector, address(ticketBridge)));
        vm.prank(deployer);
        token.setReceiptRoute(
            chainType, chainReference, address(ticketBridge), _awayChainSelector(POLYGON), _awayReceiptBridge(POLYGON)
        );
    }

    /// @dev One bridge cannot be the ticket route of one away chain and the receipt route of another: a bridge that
    ///  relays before finality would then deliver receipts.
    function test_setReceiptRoute_RevertWhen_TheBridgeIsATicketBridgeOfAnotherAwayChain() public {
        ERC7786GatewayMock sharedBridge = _newTicketBridge(OPTIMISM, TICKET_DEPTH);
        _setTicketRoute(OPTIMISM, address(sharedBridge));
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAReceiptBridge.selector, address(sharedBridge)));
        vm.prank(deployer);
        token.setReceiptRoute(
            chainType, chainReference, address(sharedBridge), _awayChainSelector(POLYGON), _awayReceiptBridge(POLYGON)
        );

        assertEq(token.receiptRouteFor(polygon), address(receiptBridge), "the receipt route is untouched");
    }

    function test_setTicketRoute_RevertWhen_TheCallerHasNoRole() public {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        token.setTicketRoute(chainType, chainReference, address(0));
    }

    /* ----- Ticket ----- */

    function test_askToMove_sendsTheTicketOnTheTicketRouteAndPinsTheReceiptRoute() public {
        bytes32 id = _issue();

        assertEq(ticketBridge.queueLength(), 1, "the ticket took the ticket route");
        assertEq(receiptBridge.queueLength(), 0);
        assertEq(_decodeQueuedValidation(ticketBridge, 0).ticketId, id);
        assertEq(_pinnedBridgeOf(id), address(receiptBridge), "its receipt comes back on the receipt route");
    }

    function test_askToMove_sendsTheTicketOnTheReceiptRoute_whenNoTicketRouteIsSet() public {
        _setTicketRoute(POLYGON, address(0));

        bytes32 id = _issue();

        assertEq(receiptBridge.queueLength(), 1);
        assertEq(ticketBridge.queueLength(), 0);
        assertEq(_pinnedBridgeOf(id), address(receiptBridge));
    }

    /// @dev The registry distrusted the ticket bridge: tickets fall back to the receipt route rather than stopping.
    function test_askToMove_sendsTheTicketOnTheReceiptRoute_whenTheTicketBridgeIsDistrusted() public {
        trustedGatewayRegistry.distrustBridge(address(ticketBridge));

        _issue();

        assertEq(receiptBridge.queueLength(), 1);
        assertEq(ticketBridge.queueLength(), 0);
    }

    /// @dev Without a receipt route nothing could answer the ticket, so the ticket route alone opens nothing.
    function test_askToMove_RevertWhen_TheReceiptRouteIsClosed() public {
        _closeEvmChain(token, POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        _issue();

        assertEq(ticketBridge.queueLength(), 0);
    }

    /// @dev An ask for the receipt goes out on the route chosen at the ask, the same copy byte for byte.
    function test_sendTicket_sendsOnTheTicketRouteAgain() public {
        bytes32 id = _issue();
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        vm.warp(ticket.validUntil + ticket.waitingTime);

        vm.prank(address(aliceIdentity));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(ticketBridge.queueLength(), 2);
        assertEq(ticketBridge.queuedMessage(1).payload, ticketBridge.queuedMessage(0).payload);
        assertEq(receiptBridge.queueLength(), 0);
    }

    /* ----- Money messages ----- */

    function test_askToMove_sendsAHomeWalletsMoveOutOnTheReceiptRouteOnly() public {
        vm.prank(alice);
        boundCompliance.askToMove(_aliceHome(), aliceSat, 100, 100, "", _salt());

        assertEq(receiptBridge.queueLength(), 1);
        assertEq(ticketBridge.queueLength(), 0, "never on the ticket route");
        (MessageTypesLib.Message messageType,) = MessageTypesLib.decode(receiptBridge.queuedMessage(0).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.MOVE_OUT));
    }

    function test_askToMove_reverts_when_theMoveOutsReceiptRouteIsClosed() public {
        _closeEvmChain(token, POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        vm.prank(alice);
        boundCompliance.askToMove(_aliceHome(), aliceSat, 100, 100, "", _salt());
    }

    function test_bringHome_sendsItsHalfOnTheReceiptRouteOnly() public {
        _bringHome(100);

        assertEq(receiptBridge.queueLength(), 1);
        assertEq(ticketBridge.queueLength(), 0, "never on the ticket route");
        (MessageTypesLib.Message messageType,) = MessageTypesLib.decode(receiptBridge.queuedMessage(0).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.BRING_HOME));
    }

    function test_bringHome_reverts_when_theReceiptRouteIsClosed() public {
        _closeEvmChain(token, POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        vm.prank(agent);
        boundCompliance.bringHome(aliceSat, 100, alice, _salt());
    }

    /* ----- Receipt ----- */

    function test_receiveReceipt_landsFromTheReceiptRoute() public {
        bytes32 id = _issue();

        receiptBridge.relay(_liteSettles(receiptBridge, token, _settlement(id, aliceSat, bobSat, 60)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 60);
    }

    function test_receiveReceipt_RevertWhen_ItArrivesThroughTheTicketRoute() public {
        bytes32 id = _issue();
        uint256 index = _liteSettles(ticketBridge, token, _settlement(id, aliceSat, bobSat, 60));

        _expectNotAReceiptBridgeDelivery(ticketBridge);
        ticketBridge.relay(index);

        assertFalse(token.messageReceived(address(ticketBridge), ticketBridge.receiveIdFor(index)));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    /// @dev The ticket bridge of another away chain is refused the same way: no bridge that relays before finality
    ///  delivers a receipt, whichever away chain it serves.
    function test_receiveReceipt_RevertWhen_ItArrivesThroughTheTicketBridgeOfAnotherAwayChain() public {
        ERC7786GatewayMock optimismTicketBridge = _newTicketBridge(POLYGON, TICKET_DEPTH);
        _setTicketRoute(OPTIMISM, address(optimismTicketBridge));
        bytes32 id = _issue();
        uint256 index = _liteSettles(optimismTicketBridge, token, _settlement(id, aliceSat, bobSat, 60));

        _expectNotAReceiptBridgeDelivery(optimismTicketBridge);
        optimismTicketBridge.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    /// @dev The policy is read again on every receipt. A refused receipt stays deliverable and lands once the
    ///  bridge's policy asks for full finality again.
    function test_receiveMessage_RevertWhen_TheBridgePolicyNoLongerAsksFullFinality() public {
        bytes4 depthThree = 0x00000003;
        bytes32 id = _issue();
        uint256 index = _liteSettles(receiptBridge, token, _settlement(id, aliceSat, bobSat, 60));
        receiptBridge.setReceivingPolicy(_awayChainSelector(POLYGON), _awayReceiptBridge(POLYGON), depthThree);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ReceiptBridgeNotFullFinality.selector, address(receiptBridge), polygon)
        );
        receiptBridge.relay(index);
        assertFalse(token.messageReceived(address(receiptBridge), receiptBridge.receiveIdFor(index)), "deliverable");

        receiptBridge.setReceivingPolicy(_awayChainSelector(POLYGON), _awayReceiptBridge(POLYGON), FULL_FINALITY);
        receiptBridge.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
    }

    /* ----- A bring home's receipt ----- */

    function test_receiveReceipt_landsABringHomeFromTheReceiptRoute() public {
        bytes32 bringHomeId = _bringHome(100);

        receiptBridge.relay(_proof(receiptBridge, bringHomeId, 100));

        assertEq(token.awayBalanceOf(aliceSat), 900);
        assertEq(uint8(boundCompliance.statusOf(bringHomeId)), uint8(ITickets.TicketStatus.Done), "ended");
    }

    function test_receiveReceipt_reverts_when_aBringHomeReceiptArrivesThroughTheTicketRoute() public {
        bytes32 bringHomeId = _bringHome(100);
        uint256 index = _proof(ticketBridge, bringHomeId, 100);

        _expectNotAReceiptBridgeDelivery(ticketBridge);
        ticketBridge.relay(index);

        assertEq(token.awayBalanceOf(aliceSat), 1000);
    }

    function test_receiveReceipt_reverts_when_theBridgePolicyNoLongerAsksFullFinality_forABringHome() public {
        bytes4 depthThree = 0x00000003;
        bytes32 bringHomeId = _bringHome(100);
        uint256 index = _proof(receiptBridge, bringHomeId, 100);
        receiptBridge.setReceivingPolicy(_awayChainSelector(POLYGON), _awayReceiptBridge(POLYGON), depthThree);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ReceiptBridgeNotFullFinality.selector, address(receiptBridge), polygon)
        );
        receiptBridge.relay(index);

        assertEq(uint8(boundCompliance.statusOf(bringHomeId)), uint8(ITickets.TicketStatus.Open), "still open");
    }

}
