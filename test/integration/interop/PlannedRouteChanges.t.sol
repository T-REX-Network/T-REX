// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev A planned change of an away chain's receipt route or peer. Home changes first and keeps the pair it had as
///      the former pair for four waiting times: every receipt the away token sent before it switched still lands on
///      it, an ask for the receipt of a ticket pinned to it still reaches the away token that holds the ticket, and a
///      receipt that came on it inside the window and waits stays applicable after the window. Two changes on one
///      chain stay four waiting times apart.
contract PlannedRouteChangesTest is InteropSuiteTest {

    uint256 internal constant ALICE_HOME_BALANCE = 1000;
    uint256 internal constant ALICE_AWAY_BALANCE = 500;
    uint256 internal constant BASE = 8453;

    ERC7786GatewayMock internal polygonBridge;
    SatelliteLiteMock internal polygonLite;
    bytes internal liteEnvelope;
    bytes internal nextPeerEnvelope;
    address internal nextPeer = makeAddr("nextPolygonLite");
    address internal anyone = makeAddr("anyone");

    Account internal aliceOnPolygon;
    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        polygonBridge = _newReceiptBridge(POLYGON);
        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonBridge);
        liteEnvelope = InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite));
        nextPeerEnvelope = InteroperableAddress.formatEvmV1(POLYGON, nextPeer);

        // The away token is the peer before the route opens: a peer set on an open route is a planned change.
        vm.prank(deployer);
        token.setPeer(polygon, liteEnvelope);
        _openEvmChain(token, POLYGON, address(polygonBridge));

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, ALICE_HOME_BALANCE);
        token.unpause();
        vm.stopPrank();

        // Alice's away balance is minted by the away token itself, so home and the away token agree.
        vm.prank(alice);
        boundCompliance.askToMove(
            InteroperableAddress.formatEvmV1(block.chainid, alice),
            aliceSat,
            ALICE_AWAY_BALANCE,
            ALICE_AWAY_BALANCE,
            "",
            _salt()
        );
        _relayAll(polygonBridge);
        assertEq(polygonLite.balanceOf(aliceSat), ALICE_AWAY_BALANCE, "the away token minted the move out");
        assertEq(token.awayBalanceOf(aliceSat), ALICE_AWAY_BALANCE, "and home applied its receipt");
    }

    /* ----- The former pair, for four waiting times ----- */

    /// @notice A ticket pinned to the new receipt bridge still has its receipt taken from the former bridge until
    ///         the last second of the window: the away token may answer on the pair it had before it switched.
    function test_receiveReceipt_acceptsTheFormerRoute_duringTheSwapWindow() public {
        uint64 acceptedUntil = uint64(block.timestamp) + 4 * POLYGON_WINDOW;
        ERC7786GatewayMock nextBridge = _changeRoute();
        bytes32 answeredInTheWindow = _ask(10, 50);
        bytes32 answeredAfterTheWindow = _ask(10, 50);
        assertEq(_pinnedBridgeOf(answeredInTheWindow), address(nextBridge), "pinned to the new bridge");

        uint256 lastSecondIndex = _formerLiteSends(polygonBridge, _receipt(answeredInTheWindow, 40));
        uint256 tooLateIndex = _formerLiteSends(polygonBridge, _receipt(answeredAfterTheWindow, 40));

        vm.warp(acceptedUntil - 1);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(answeredInTheWindow, polygon, 40);
        polygonBridge.relay(lastSecondIndex);
        assertEq(uint8(boundCompliance.statusOf(answeredInTheWindow)), uint8(ITickets.TicketStatus.Done));

        vm.warp(acceptedUntil);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(polygonBridge), polygon));
        polygonBridge.relay(tooLateIndex);
    }

    /// @notice A second change inside the window would drop the former pair while receipts on it may still travel:
    ///         both setters refuse it until the window ends.
    function test_setReceiptRoute_reverts_when_aSecondChangeComesInsideTheSwapWindow() public {
        uint64 acceptedUntil = uint64(block.timestamp) + 4 * POLYGON_WINDOW;
        _changeRoute();
        ERC7786GatewayMock thirdBridge = _newReceiptBridge(POLYGON);
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);
        bytes memory tooRecent =
            abi.encodeWithSelector(ErrorsLib.RouteChangedTooRecently.selector, polygon, acceptedUntil);

        vm.warp(acceptedUntil - 1);
        vm.prank(deployer);
        vm.expectRevert(tooRecent);
        token.setReceiptRoute(
            chainType, chainReference, address(thirdBridge), _awayChainSelector(POLYGON), _awayReceiptBridge(POLYGON)
        );
        vm.prank(deployer);
        vm.expectRevert(tooRecent);
        token.setPeer(polygon, nextPeerEnvelope);

        vm.warp(acceptedUntil);
        _openEvmChain(token, POLYGON, address(thirdBridge));
        assertEq(token.receiptRouteFor(polygon), address(thirdBridge), "the change passes once the window ends");
    }

    /// @notice The window is four of the chain's waiting times after the change, the waiting time read as it is at
    ///         each use: lengthening it after the change keeps the former pair, and holds a second change, longer.
    function test_receiveReceipt_acceptsTheFormerRoute_untilTheEndTheLongerWaitingTimeGives() public {
        uint64 changedAt = uint64(block.timestamp);
        uint64 longerWaitingTime = 2 * POLYGON_WINDOW;
        uint64 endBeforeTheChange = changedAt + 4 * POLYGON_WINDOW;
        uint64 endAfterTheChange = changedAt + 4 * longerWaitingTime;
        _changeRoute();
        bytes32 answeredLate = _ask(10, 50);
        uint256 index = _formerLiteSends(polygonBridge, _receipt(answeredLate, 40));
        vm.prank(deployer);
        boundCompliance.setWaitingTime(polygon, longerWaitingTime);

        vm.warp(endBeforeTheChange);
        polygonBridge.relay(index);
        assertEq(uint8(boundCompliance.statusOf(answeredLate)), uint8(ITickets.TicketStatus.Done), "still taken");

        ERC7786GatewayMock thirdBridge = _newReceiptBridge(POLYGON);
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RouteChangedTooRecently.selector, polygon, endAfterTheChange));
        vm.prank(deployer);
        token.setReceiptRoute(
            chainType, chainReference, address(thirdBridge), _awayChainSelector(POLYGON), _awayReceiptBridge(POLYGON)
        );

        vm.warp(endAfterTheChange);
        _openEvmChain(token, POLYGON, address(thirdBridge));
        assertEq(token.receiptRouteFor(polygon), address(thirdBridge), "the change passes at the new end");
    }

    /// @notice A closed route has no pair a change could drop: inside the window of an earlier change, its peer and
    ///         its route are set again at once, and the former pair kept by that earlier change still lands receipts.
    function test_setReceiptRoute_setsAClosedRouteAgain_insideTheWindowOfAnEarlierChange() public {
        uint256 executed = 40;
        bytes32 sentOnTheFirstPair = _ask(10, 50);
        _changeRoute();
        _closeEvmChain(token, POLYGON);
        ERC7786GatewayMock thirdBridge = _newReceiptBridge(POLYGON);

        vm.prank(deployer);
        token.setPeer(polygon, nextPeerEnvelope);
        _openEvmChain(token, POLYGON, address(thirdBridge));

        assertEq(token.peerFor(polygon), nextPeerEnvelope, "the peer of a closed route is set inside the window");
        assertEq(token.receiptRouteFor(polygon), address(thirdBridge), "and so is the route");
        uint256 index = _formerLiteSends(polygonBridge, _receipt(sentOnTheFirstPair, executed));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(sentOnTheFirstPair, polygon, executed);
        polygonBridge.relay(index);
    }

    /// @notice Home changes the route first; the away token executed the ticket, its receipt was lost, and the ask
    ///         for the receipt goes out on the former pair, which still reaches it. Its answer lands, the ticket is
    ///         done, and nobody can cancel an executed ticket.
    function test_cancelTickets_doesNotCancelAnExecutedTicket_whenTheRouteChangesHomeFirst() public {
        bytes32 ticketId = _ask(10, 50);
        _relayAll(polygonBridge);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(ticketId, 40);
        polygonBridge.drop(polygonBridge.queueLength() - 1);

        ERC7786GatewayMock nextBridge = _changeRoute();
        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);
        vm.warp(issued.validUntil + POLYGON_WINDOW);
        boundCompliance.sendTicket(ticketId, bobSat, "");
        assertEq(nextBridge.queueLength(), 0, "the ask went out on the former pair");
        _relayAll(polygonBridge);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 40, "home agrees with the away token");
        assertEq(polygonLite.balanceOf(bobSat), 40);

        vm.warp(block.timestamp + 2 * POLYGON_WINDOW);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, ticketId, uint8(ITickets.TicketStatus.Done))
        );
        boundCompliance.cancelTickets(_ids(ticketId));
    }

    /// @notice A home reorg drops the ask after the away token received it; home changes the route meanwhile, and
    ///         the ask mined again under the same id is pinned to the new bridge. The away token's receipt of the
    ///         dropped copy comes on the former pair and is applied on older terms; its chain is not blocked.
    function test_receiveReceipt_appliesTheDroppedCopy_whenTheAskIsMinedAgainAfterAPlannedChange() public {
        bytes32 salt = _salt();
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(aliceIdentity));
        bytes32 ticketId = boundCompliance.askToMove(aliceSat, bobSat, 10, 50, "", salt);
        ITickets.Ticket memory droppedCopy = boundCompliance.ticketOf(ticketId);
        vm.revertToState(snapshot);

        vm.warp(block.timestamp + 1);
        ERC7786GatewayMock nextBridge = _changeRoute();
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 50, "", salt);
        assertEq(_pinnedBridgeOf(ticketId), address(nextBridge), "the ask mined again is pinned to the new bridge");

        MessageTypesLib.ReceiptMessage memory receipt =
            _settlementUnder(ticketId, aliceSat, bobSat, 40, droppedCopy.askBlockHash);
        receipt.seenValidUntil = droppedCopy.validUntil;
        uint256 index = _formerLiteSends(polygonBridge, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(ticketId, polygon, droppedCopy.amountMax);
        polygonBridge.relay(index);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 40);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest away chain is not blocked");
    }

    /// @notice Slow callers: the first ask for the receipt comes only after the window, and goes to the current
    ///         pair; the cancel comes late too, and passes.
    function test_cancelTickets_succeeds_whenTheAskAndTheCancelComeLate_afterAPlannedChange() public {
        bytes32 ticketId = _ask(10, 50);
        uint64 acceptedUntil = uint64(block.timestamp) + 4 * POLYGON_WINDOW;
        _changePeer();

        vm.warp(acceptedUntil + 1);
        uint256 askIndex = polygonBridge.queueLength();
        boundCompliance.sendTicket(ticketId, bobSat, "");
        assertEq(polygonBridge.queuedMessage(askIndex).recipient, nextPeerEnvelope, "the late ask goes to the peer now");

        vm.warp(block.timestamp + POLYGON_WINDOW + 1);
        vm.prank(anyone);
        boundCompliance.cancelTickets(_ids(ticketId));

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.reservedOf(aliceSat), 0, "the reservation comes back");
    }

    /// @notice The accepted cost of the window: the former peer can still report a ticket pinned to the new peer,
    ///         inside its terms, and home applies it. Home cannot tell it from the away token's last honest receipt.
    function test_receiveReceipt_appliesAForgedReceiptOfTheFormerPeer_insideTheChangeWindow() public {
        _changePeer();
        bytes32 ticketId = _ask(10, 50);
        (, bytes32 pinnedPeerKey) = token.pinOf(MessageTypesLib.halfKeyOf(ticketId, 0));
        assertEq(pinnedPeerKey, keccak256(nextPeerEnvelope), "pinned to the new peer");

        uint256 forgedIndex = _formerLiteSends(polygonBridge, _receipt(ticketId, 50));
        polygonBridge.relay(forgedIndex);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 50, "applied");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "inside its terms, nothing is blocked");
    }

    /* ----- What a change keeps ----- */

    /// @notice A chain with no receipt route takes no receipt, so a change there keeps nothing and starts no window.
    function test_setPeer_keepsNoFormerRoute_whenTheChainHasNoRoute() public {
        bytes32 base = _evmChainKey(BASE);
        bytes memory secondPeer = InteroperableAddress.formatEvmV1(BASE, makeAddr("nextBaseLite"));

        vm.recordLogs();
        vm.startPrank(deployer);
        token.setPeer(base, InteroperableAddress.formatEvmV1(BASE, makeAddr("baseLite")));
        token.setPeer(base, secondPeer);
        vm.stopPrank();

        _assertNoFormerRouteKept(vm.getRecordedLogs());
        assertEq(token.peerFor(base), secondPeer, "the second change passed at once");
    }

    function test_setReceiptRoute_keepsNoFormerRoute_whenTheChainHasNoRoute() public {
        ERC7786GatewayMock firstBaseBridge = _newReceiptBridge(BASE);
        ERC7786GatewayMock secondBaseBridge = _newReceiptBridge(BASE);

        vm.recordLogs();
        _openEvmChain(token, BASE, address(firstBaseBridge));
        _assertNoFormerRouteKept(vm.getRecordedLogs());

        _openEvmChain(token, BASE, address(secondBaseBridge));
        assertEq(token.receiptRouteFor(_evmChainKey(BASE)), address(secondBaseBridge), "no window held it back");
    }

    /// @notice A peer change on an open route keeps the bridge and the old peer as the former pair: a receipt from
    ///         the old peer for a half with no pin is admitted inside the window and refused after it.
    function test_setPeer_keepsTheFormerPair_forFourWaitingTimes() public {
        uint64 acceptedUntil = uint64(block.timestamp) + 4 * POLYGON_WINDOW;
        bytes32 neverSent = keccak256("a second half home never sent");
        bytes memory payload = MessageTypesLib.encodeSettlement(_secondHalfReceipt(neverSent));

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.FormerRouteKept(polygon, address(polygonBridge), keccak256(liteEnvelope), acceptedUntil);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.PeerSet(polygon, nextPeerEnvelope);
        _changePeer();

        uint256 insideIndex = _formerLiteSends(polygonBridge, payload);
        uint256 afterIndex = _formerLiteSends(polygonBridge, payload);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptUnknown(MessageTypesLib.halfKeyOf(neverSent, 1), polygon);
        polygonBridge.relay(insideIndex);

        vm.warp(acceptedUntil);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotPeer.selector, polygon, liteEnvelope));
        polygonBridge.relay(afterIndex);
    }

    /// @notice A bridge whose receiving policy is per sender is asked about the away side it had as the route: the
    ///         former one. Asked about the new away side, the same former bridge would refuse.
    function test_receiveReceipt_readsTheFormerAwaySide_throughTheFormerBridge() public {
        bytes memory nextAwayReceiptBridge = abi.encode(makeAddr("next away receipt bridge"));
        uint64 awayChainSelector = _awayChainSelector(POLYGON);
        ERC7786GatewayMock nextBridge = new ERC7786GatewayMock(POLYGON);
        nextBridge.setReceivingPolicy(awayChainSelector, nextAwayReceiptBridge, FULL_FINALITY);
        trustedGatewayRegistry.setTrustedGateway(address(nextBridge), true, 0);
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);
        vm.prank(deployer);
        token.setReceiptRoute(chainType, chainReference, address(nextBridge), awayChainSelector, nextAwayReceiptBridge);
        bytes32 throughTheFormerSide = _ask(10, 50);
        bytes32 throughTheNewSide = _ask(10, 50);

        polygonBridge.relay(_formerLiteSends(polygonBridge, _receipt(throughTheFormerSide, 40)));
        assertEq(uint8(boundCompliance.statusOf(throughTheFormerSide)), uint8(ITickets.TicketStatus.Done));

        // The former bridge now answers for the new away side only.
        polygonBridge.setReceivingPolicy(awayChainSelector, nextAwayReceiptBridge, FULL_FINALITY);
        uint256 index = _formerLiteSends(polygonBridge, _receipt(throughTheNewSide, 40));
        vm.expectRevert(bytes("ERC7786GatewayMock: no receiving policy for this source"));
        polygonBridge.relay(index);
    }

    /// @notice A half pinned to a bridge older than the former pair is answered through it, and that bridge's
    ///         receiving policy is asked about the away side it was set with, not the chain's current one.
    function test_receiveReceipt_readsThePinnedBridgesOwnAwaySide_afterTwoChanges() public {
        bytes32 pinnedToTheFirstBridge = _ask(10, 50);
        uint256 index = _formerLiteSends(polygonBridge, _receipt(pinnedToTheFirstBridge, 40));
        _changeRouteWithItsAwaySide(abi.encode(makeAddr("second away receipt bridge")));
        vm.warp(block.timestamp + 4 * POLYGON_WINDOW);
        _changeRouteWithItsAwaySide(abi.encode(makeAddr("third away receipt bridge")));

        polygonBridge.relay(index);

        assertEq(uint8(boundCompliance.statusOf(pinnedToTheFirstBridge)), uint8(ITickets.TicketStatus.Done));
    }

    /// @notice The route check run again on a kept receipt judges the former pair at the receipt's arrival.
    function test_checkReceiptOrigin_judgesTheFormerPair_atTheArrival() public {
        uint64 changedAt = uint64(block.timestamp);
        uint64 acceptedUntil = changedAt + 4 * POLYGON_WINDOW;
        bytes32 liteKey = keccak256(liteEnvelope);
        _changePeer();
        bytes32 halfOnTheNewPeer = MessageTypesLib.halfKeyOf(_ask(10, 50), 0);

        token.checkReceiptOrigin(polygon, address(polygonBridge), liteKey, halfOnTheNewPeer, changedAt);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, polygon));
        token.checkReceiptOrigin(polygon, address(polygonBridge), liteKey, halfOnTheNewPeer, acceptedUntil);
    }

    function test_checkReceiptOrigin_reverts_forTheFormerBridge_whenTheReceiptArrivedAfterTheWindow() public {
        uint64 changedAt = uint64(block.timestamp);
        uint64 acceptedUntil = changedAt + 4 * POLYGON_WINDOW;
        bytes32 liteKey = keccak256(liteEnvelope);
        _changeRoute();
        bytes32 halfOnTheNewBridge = MessageTypesLib.halfKeyOf(_ask(10, 50), 0);

        token.checkReceiptOrigin(polygon, address(polygonBridge), liteKey, halfOnTheNewBridge, changedAt);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(polygonBridge), polygon));
        token.checkReceiptOrigin(polygon, address(polygonBridge), liteKey, halfOnTheNewBridge, acceptedUntil);
    }

    /* ----- Asks for the receipt after a change ----- */

    /// @notice The away token that holds the ticket answers the ask: inside the window that is the former peer, so
    ///         the ask goes to it, and its answer lands.
    function test_sendTicket_asksThroughTheFormerPair_whenTheTicketWasSentBeforeAPlannedChange() public {
        bytes32 ticketId = _ask(10, 50);
        _relayAll(polygonBridge);
        _changePeer();
        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);

        vm.warp(issued.validUntil + POLYGON_WINDOW);
        uint256 askIndex = polygonBridge.queueLength();
        boundCompliance.sendTicket(ticketId, bobSat, "");
        assertEq(polygonBridge.queuedMessage(askIndex).recipient, liteEnvelope, "the ask goes to the former peer");
        _relayAll(polygonBridge);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done), "its answer landed");
        assertEq(boundCompliance.ticketOf(ticketId).moved, 0, "the away token never executed it");
    }

    /// @notice After the window the ask goes to the current pair; the pin stays the record of where the ticket went.
    function test_sendTicket_asksThroughTheCurrentPair_afterTheWindow() public {
        bytes32 ticketId = _ask(10, 50);
        uint64 acceptedUntil = uint64(block.timestamp) + 4 * POLYGON_WINDOW;
        _changePeer();

        vm.warp(acceptedUntil);
        uint256 askIndex = polygonBridge.queueLength();
        boundCompliance.sendTicket(ticketId, bobSat, "");
        assertEq(polygonBridge.queuedMessage(askIndex).recipient, nextPeerEnvelope, "the ask goes to the peer now");
        (address pinnedBridge, bytes32 pinnedPeerKey) = token.pinOf(MessageTypesLib.halfKeyOf(ticketId, 0));
        assertEq(pinnedBridge, address(polygonBridge), "the pin is not rewritten");
        assertEq(pinnedPeerKey, keccak256(liteEnvelope));

        MessageTypesLib.ReceiptMessage memory expiredAnswer = _receipt(ticketId, 0);
        expiredAnswer.answer = MessageTypesLib.ReceiptAnswer.Expired;
        polygonBridge.relay(_queue(polygonBridge, nextPeer, token, MessageTypesLib.encodeSettlement(expiredAnswer)));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done), "its answer landed");
    }

    /// @notice A former bridge distrusted inside the window cannot carry the answer back, so the ask goes through
    ///         the current route instead.
    function test_sendTicket_asksThroughTheCurrentPair_whenTheFormerBridgeIsDistrusted() public {
        bytes32 ticketId = _ask(10, 50);
        ERC7786GatewayMock nextBridge = _changeRoute();
        trustedGatewayRegistry.setTrustedGateway(address(polygonBridge), false, 0);
        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);
        uint256 formerQueueLength = polygonBridge.queueLength();

        vm.warp(issued.validUntil + POLYGON_WINDOW);
        boundCompliance.sendTicket(ticketId, bobSat, "");

        assertEq(polygonBridge.queueLength(), formerQueueLength, "nothing went through the distrusted bridge");
        assertEq(nextBridge.queueLength(), 1);
        assertEq(nextBridge.queuedMessage(0).recipient, liteEnvelope, "to the current peer");
    }

    /// @notice A ticket sent before a planned change whose receipt never comes: the ask goes out on the former pair,
    ///         goes unanswered, and the cancel passes at its due time.
    function test_cancelTickets_succeeds_afterAnUnansweredAskThroughTheFormerPair() public {
        bytes32 ticketId = _ask(10, 50);
        polygonBridge.drop(polygonBridge.queueLength() - 1);
        _changePeer();
        uint256 askIndex = polygonBridge.queueLength();

        _askAndLetTheAskGoUnanswered(ticketId, bobSat, "");
        assertEq(polygonBridge.queuedMessage(askIndex).recipient, liteEnvelope, "the ask went to the former peer");
        vm.prank(anyone);
        boundCompliance.cancelTickets(_ids(ticketId));

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.reservedOf(aliceSat), 0);
    }

    /* ----- Waiting receipts that came on the former pair ----- */

    /// @notice A receipt that came on the former pair inside the window and waited under a block is still applied
    ///         after the window: it is judged at its arrival.
    function test_applyWaitingReceipt_appliesAReceiptThatCameOnTheFormerPair_afterTheWindowEnds() public {
        uint64 acceptedUntil = uint64(block.timestamp) + 4 * POLYGON_WINDOW;
        _changeRoute();
        bytes32 ticketId = _ask(10, 50);
        uint64 deliveredAt = uint64(block.timestamp);
        MessageTypesLib.ReceiptMessage memory receipt = _formerPairReceiptWaitingUnderABlock(ticketId, 40);

        ITickets.WaitingReceipt memory waiting = boundCompliance.waitingReceiptOf(ticketId);
        assertEq(waiting.arrivedAt, deliveredAt, "kept with its arrival");
        assertEq(waiting.deliveredBy, address(polygonBridge));

        vm.warp(acceptedUntil);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.prank(anyone);
        boundCompliance.applyWaitingReceipt(ticketId, receipt);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 40);
    }

    function test_applyWaitingReceipt_reverts_when_theFormerBridgeWasDistrusted() public {
        _changeRoute();
        bytes32 ticketId = _ask(10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _formerPairReceiptWaitingUnderABlock(ticketId, 40);
        trustedGatewayRegistry.setTrustedGateway(address(polygonBridge), false, 0);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAReceiptBridge.selector, address(polygonBridge)));
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
    }

    /// @notice That waiting receipt can still be applied after the window, so it holds the cancel.
    function test_cancelTickets_reverts_when_aReceiptThatCameOnTheFormerPairWaitsAfterTheWindow() public {
        uint64 acceptedUntil = uint64(block.timestamp) + 4 * POLYGON_WINDOW;
        _changeRoute();
        bytes32 ticketId = _ask(10, 50);
        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);
        vm.warp(issued.validUntil + POLYGON_WINDOW);
        boundCompliance.sendTicket(ticketId, bobSat, "");
        MessageTypesLib.ReceiptMessage memory receipt = _formerPairReceiptWaitingUnderABlock(ticketId, 40);

        vm.warp(acceptedUntil);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, ticketId, polygon));
        boundCompliance.cancelTickets(_ids(ticketId));

        vm.prank(anyone);
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
    }

    /* ----- Helpers ----- */

    function _ask(uint256 amountMin, uint256 requestedMax) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, amountMin, requestedMax);
    }

    /// @dev A planned change of Polygon's receipt route to a new bridge, the peer kept.
    function _changeRoute() private returns (ERC7786GatewayMock nextBridge) {
        nextBridge = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(nextBridge));
    }

    /// @dev A planned change of Polygon's receipt route to a new bridge whose receiving policy admits
    ///  `awayReceiptBridge` only, the peer kept.
    function _changeRouteWithItsAwaySide(bytes memory awayReceiptBridge) private {
        uint64 awayChainSelector = _awayChainSelector(POLYGON);
        ERC7786GatewayMock nextBridge = new ERC7786GatewayMock(POLYGON);
        nextBridge.setReceivingPolicy(awayChainSelector, awayReceiptBridge, FULL_FINALITY);
        trustedGatewayRegistry.setTrustedGateway(address(nextBridge), true, 0);
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);
        vm.prank(deployer);
        token.setReceiptRoute(chainType, chainReference, address(nextBridge), awayChainSelector, awayReceiptBridge);
    }

    /// @dev A planned change of Polygon's peer, the route kept.
    function _changePeer() private {
        vm.prank(deployer);
        token.setPeer(polygon, nextPeerEnvelope);
    }

    function _receipt(bytes32 ticketId, uint256 amount) private view returns (MessageTypesLib.ReceiptMessage memory) {
        return _settlement(ticketId, aliceSat, bobSat, amount);
    }

    /// @dev A receipt the away token sends from the pair it had before the change: through the first bridge, from
    ///  its own address.
    function _formerLiteSends(ERC7786GatewayMock gateway, MessageTypesLib.ReceiptMessage memory receipt)
        private
        returns (uint256)
    {
        return _formerLiteSends(gateway, MessageTypesLib.encodeSettlement(receipt));
    }

    function _formerLiteSends(ERC7786GatewayMock gateway, bytes memory payload) private returns (uint256) {
        return _queue(gateway, address(polygonLite), token, payload);
    }

    /// @dev Blocks Polygon, then delivers a receipt for the ticket on the former pair: it waits.
    function _formerPairReceiptWaitingUnderABlock(bytes32 ticketId, uint256 amount)
        private
        returns (MessageTypesLib.ReceiptMessage memory receipt)
    {
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        receipt = _receipt(ticketId, amount);
        polygonBridge.relay(_formerLiteSends(polygonBridge, receipt));
        assertEq(boundCompliance.waitingReceiptOf(ticketId).amount, amount, "the receipt waits");
    }

    /// @dev A second-half receipt for an id home never sent: it has no pin, so only the route check judges it.
    function _secondHalfReceipt(bytes32 ticketId) private pure returns (MessageTypesLib.ReceiptMessage memory) {
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: "",
            to: "",
            amount: 0,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: 1,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    /// @dev Delivers every queued entry of `gateway` not yet delivered or dropped, including the ones a delivery
    ///  queues behind it.
    function _relayAll(ERC7786GatewayMock gateway) private {
        for (uint256 i = 0; i < gateway.queueLength(); i++) {
            ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(i);
            if (message.deliveries == 0 && !message.dropped) gateway.relay(i);
        }
    }

    function _assertNoFormerRouteKept(Vm.Log[] memory logs) private pure {
        for (uint256 i = 0; i < logs.length; i++) {
            bool hasTopic = logs[i].topics.length > 0;
            if (hasTopic) assertTrue(logs[i].topics[0] != EventsLib.FormerRouteKept.selector, "no former pair kept");
        }
    }

    function _ids(bytes32 ticketId) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = ticketId;
    }

}
