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
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A peer replaced as hostile. Home keeps no former pair, since it cannot tell the hostile peer's receipts from
///      honest ones, and freezes asks, ticket sends, asks for the receipt and cancels toward that away chain for
///      four waiting times, so nothing is decided while the away token's honest receipts may still be refused.
///      Receipts keep landing meanwhile.
contract HostilePeerReplacementTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 1000;
    uint256 internal constant BASE = 8453;

    ERC7786GatewayMock internal polygonBridge;
    ERC7786GatewayMock internal optimismBridge;

    address internal replacedPeer = makeAddr("polygonLiteReplacedAsHostile");
    address internal replacementPeer = makeAddr("replacementPolygonLite");
    bytes internal replacedPeerEnvelope;
    bytes internal replacementPeerEnvelope;

    bytes internal aliceOnPolygon;
    bytes internal aliceOnOptimism;
    bytes internal bobOnPolygon;
    bytes internal bobAtHome;
    address internal backend = makeAddr("institutionBackend");
    address internal anyone = makeAddr("anyone");

    function setUp() public override {
        super.setUp();
        polygonBridge = _newReceiptBridge(POLYGON);
        optimismBridge = _newReceiptBridge(OPTIMISM);
        replacedPeerEnvelope = InteroperableAddress.formatEvmV1(POLYGON, replacedPeer);
        replacementPeerEnvelope = InteroperableAddress.formatEvmV1(POLYGON, replacementPeer);

        // The peer is set before the route opens: a peer set on an open route is a planned change.
        vm.prank(deployer);
        token.setPeer(polygon, replacedPeerEnvelope);
        _openEvmChain(token, POLYGON, address(polygonBridge));
        _openEvmChain(token, OPTIMISM, address(optimismBridge));

        aliceOnPolygon =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        aliceOnOptimism =
            _fundSatelliteWallet(aliceIdentity, alice, OPTIMISM, makeAccount("aliceOnOptimism"), ALICE_AWAY_BALANCE);
        bobOnPolygon = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobAtHome = InteroperableAddress.formatEvmV1(block.chainid, bob);

        vm.prank(agent);
        token.unpause();
    }

    /* ----- The freeze ----- */

    /// @notice For four waiting times nothing is asked, asked for or cancelled toward the away chain; other away
    ///         chains go on. At the end of the freeze each of them passes.
    function test_replaceHostilePeer_freezesAsksAndCancels() public {
        bytes32 ticketToAskFor = _ask(10, 50);
        bytes32 ticketToCancel = _ask(10, 50);
        _askAndLetTheAskGoUnanswered(ticketToCancel, bobOnPolygon, "");

        uint64 endsAt = _replaceThePeer();
        assertEq(endsAt, block.timestamp + 4 * POLYGON_WINDOW, "four waiting times");
        bytes memory frozen = abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt);

        bytes32 salt = _salt();
        vm.prank(address(aliceIdentity));
        vm.expectRevert(frozen);
        boundCompliance.askToMove(aliceOnPolygon, bobOnPolygon, 10, 50, "", salt);
        vm.expectRevert(frozen);
        boundCompliance.sendTicket(ticketToAskFor, bobOnPolygon, "");
        vm.prank(anyone);
        vm.expectRevert(frozen);
        boundCompliance.cancelTickets(_ids(ticketToCancel));

        bytes32 onAnotherChain = _requestValidation(address(aliceIdentity), aliceOnOptimism, bobAtHome, 10, 50);
        assertEq(uint8(boundCompliance.statusOf(onAnotherChain)), uint8(ITickets.TicketStatus.Open), "not frozen");

        vm.warp(endsAt);
        _ask(10, 50);
        boundCompliance.sendTicket(ticketToAskFor, bobOnPolygon, "");
        vm.prank(anyone);
        boundCompliance.cancelTickets(_ids(ticketToCancel));
        assertEq(uint8(boundCompliance.statusOf(ticketToCancel)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice The approver's answer sends nothing, so it is not frozen; the first send of the approved ticket is,
    ///         and so is the cancel of a ticket still waiting for approval. After the freeze, an approved ticket is
    ///         sent.
    function test_replaceHostilePeer_freezesTheSendOfAnApprovedTicket_butNotTheApproval() public {
        AsyncApprovalModule approval = _bindApprovalModule();
        bytes32 approvedInTheFreeze = _ask(10, 50);
        bytes32 waitingInTheFreeze = _ask(10, 50);

        uint64 endsAt = _replaceThePeer();
        bytes memory frozen = abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt);

        _approve(approval, approvedInTheFreeze);
        assertEq(uint8(boundCompliance.statusOf(approvedInTheFreeze)), uint8(ITickets.TicketStatus.Open), "approved");
        vm.expectRevert(frozen);
        boundCompliance.sendTicket(approvedInTheFreeze, bobOnPolygon, "");
        vm.prank(anyone);
        vm.expectRevert(frozen);
        boundCompliance.cancelTickets(_ids(waitingInTheFreeze));

        vm.warp(endsAt);
        bytes32 approvedAfterTheFreeze = _ask(10, 50);
        _approve(approval, approvedAfterTheFreeze);
        boundCompliance.sendTicket(approvedAfterTheFreeze, bobOnPolygon, "");
        assertEq(_pinnedBridgeOf(approvedAfterTheFreeze), address(polygonBridge), "sent");
    }

    /// @notice The freeze ends exactly at `endsAt`.
    function test_askToMove_succeeds_atExactlyTheEndOfTheFreeze() public {
        uint64 endsAt = _replaceThePeer();

        vm.warp(endsAt - 1);
        bytes32 salt = _salt();
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt));
        boundCompliance.askToMove(aliceOnPolygon, bobOnPolygon, 10, 50, "", salt);

        vm.warp(endsAt);
        bytes32 ticketId = _ask(10, 50);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open));
    }

    /* ----- No former pair ----- */

    /// @notice A hostile change right after a planned one deletes the former pair the planned one kept: the peer of
    ///         before both is refused at once, and the spacing between changes is lifted.
    function test_replaceHostilePeer_keepsNoFormerPeer() public {
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("plannedPolygonLite")));
        vm.warp(block.timestamp + 1);

        vm.recordLogs();
        _replaceThePeer();
        _assertNoFormerRouteKept(vm.getRecordedLogs());

        bytes memory payload = MessageTypesLib.encodeSettlement(_secondHalfReceipt(keccak256("a half never sent")));
        uint256 index = _queue(polygonBridge, replacedPeer, token, payload);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotPeer.selector, polygon, replacedPeerEnvelope));
        polygonBridge.relay(index);

        bytes memory nextPlannedPeer = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("nextPlannedPolygonLite"));
        vm.prank(deployer);
        token.setPeer(polygon, nextPlannedPeer);
        assertEq(token.peerFor(polygon), nextPlannedPeer, "a planned change right after is allowed");
    }

    function test_replaceHostilePeer_emitsPeerSetThenHostilePeerReplaced() public {
        uint64 endsAt = uint64(block.timestamp) + 4 * POLYGON_WINDOW;

        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.PeerSet(polygon, replacementPeerEnvelope);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.HostilePeerReplaced(polygon, replacementPeerEnvelope, endsAt);
        _replaceThePeer();

        assertEq(token.peerFor(polygon), replacementPeerEnvelope);
    }

    /* ----- Receipts still land ----- */

    /// @notice Inside the freeze a receipt from the new peer on the route, a receipt from the replaced peer for a
    ///         half pinned to it, and a waiting receipt applied by anyone all land.
    function test_receiveReceipt_stillLands_duringTheFourWaitingTimesAfterAHostileChange() public {
        bytes32 answeredByTheReplacement = _ask(10, 50);
        bytes32 answeredByTheReplacedPeer = _ask(10, 50);
        bytes32 appliedFromTheShelf = _ask(10, 50);
        uint64 endsAt = _replaceThePeer();

        polygonBridge.relay(_peerSends(replacementPeer, _receipt(answeredByTheReplacement, 20)));
        polygonBridge.relay(_peerSends(replacedPeer, _receipt(answeredByTheReplacedPeer, 30)));
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory waiting = _receipt(appliedFromTheShelf, 40);
        polygonBridge.relay(_peerSends(replacedPeer, waiting));
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.prank(anyone);
        boundCompliance.applyWaitingReceipt(appliedFromTheShelf, waiting);

        assertLt(block.timestamp, endsAt, "still inside the freeze");
        assertEq(uint8(boundCompliance.statusOf(answeredByTheReplacement)), uint8(ITickets.TicketStatus.Done));
        assertEq(uint8(boundCompliance.statusOf(answeredByTheReplacedPeer)), uint8(ITickets.TicketStatus.Done));
        assertEq(uint8(boundCompliance.statusOf(appliedFromTheShelf)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobOnPolygon), 20 + 30 + 40);
    }

    /// @notice Inside the freeze the ask for the receipt is refused; after it, it goes to the new peer. The pin
    ///         still names the replaced peer.
    function test_sendTicket_asksThroughTheCurrentPair_afterAHostileChange() public {
        bytes32 ticketId = _ask(10, 50);
        uint64 endsAt = _replaceThePeer();
        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);

        vm.warp(issued.validUntil + issued.waitingTime);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt));
        boundCompliance.sendTicket(ticketId, bobOnPolygon, "");

        vm.warp(endsAt);
        uint256 askIndex = polygonBridge.queueLength();
        boundCompliance.sendTicket(ticketId, bobOnPolygon, "");
        assertEq(polygonBridge.queuedMessage(askIndex).recipient, replacementPeerEnvelope, "to the new peer");
        (, bytes32 pinnedPeerKey) = token.pinOf(MessageTypesLib.halfKeyOf(ticketId, 0));
        assertEq(pinnedPeerKey, keccak256(replacedPeerEnvelope), "the pin is kept");
    }

    /// @notice A receipt that came on the former pair of a planned change, for a ticket pinned to the new pair, is
    ///         refused once a hostile change deletes that former pair. A ticket pinned to the old pair keeps its pin
    ///         and its waiting receipt still applies.
    function test_applyWaitingReceipt_reverts_afterAHostileChange() public {
        bytes32 pinnedToTheOldPair = _ask(10, 50);
        ERC7786GatewayMock nextBridge = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(nextBridge));
        bytes32 pinnedToTheNewPair = _ask(10, 50);
        uint64 arrivedAt = uint64(block.timestamp);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory forTheOldPair = _receipt(pinnedToTheOldPair, 20);
        MessageTypesLib.ReceiptMessage memory forTheNewPair = _receipt(pinnedToTheNewPair, 30);
        polygonBridge.relay(_peerSends(replacedPeer, forTheOldPair));
        polygonBridge.relay(_peerSends(replacedPeer, forTheNewPair));

        _replaceThePeer();
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);

        bytes memory peerChanged = abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, polygon);
        vm.expectRevert(peerChanged);
        token.checkReceiptOrigin(
            polygon,
            address(polygonBridge),
            keccak256(replacedPeerEnvelope),
            MessageTypesLib.halfKeyOf(pinnedToTheNewPair, 0),
            arrivedAt
        );
        vm.prank(anyone);
        vm.expectRevert(peerChanged);
        boundCompliance.applyWaitingReceipt(pinnedToTheNewPair, forTheNewPair);

        vm.prank(anyone);
        boundCompliance.applyWaitingReceipt(pinnedToTheOldPair, forTheOldPair);
        assertEq(uint8(boundCompliance.statusOf(pinnedToTheOldPair)), uint8(ITickets.TicketStatus.Done));
    }

    /* ----- Edges ----- */

    /// @notice With no waiting time set for the chain, the freeze ends at once.
    function test_replaceHostilePeer_endsAtOnce_whenTheChainHasNoWaitingTime() public {
        bytes32 base = _evmChainKey(BASE);

        vm.prank(deployer);
        token.replaceHostilePeer(base, InteroperableAddress.formatEvmV1(BASE, makeAddr("baseLite")));

        assertEq(token.hostileChangeEndsAt(base), block.timestamp, "no freeze");
    }

    function test_hostileChangeEndsAt_isZero_forAChainNeverReplaced() public view {
        assertEq(token.hostileChangeEndsAt(polygon), 0);
        assertEq(token.hostileChangeEndsAt(optimism), 0);
    }

    function test_replaceHostilePeer_reverts_when_theCallerHasNoRole() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, anyone));
        token.replaceHostilePeer(polygon, replacementPeerEnvelope);
    }

    /* ----- Helpers ----- */

    function _ask(uint256 amountMin, uint256 requestedMax) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceOnPolygon, bobOnPolygon, amountMin, requestedMax);
    }

    /// @dev Replaces Polygon's peer as hostile and returns when the freeze ends.
    function _replaceThePeer() private returns (uint64 endsAt) {
        vm.prank(deployer);
        token.replaceHostilePeer(polygon, replacementPeerEnvelope);
        endsAt = token.hostileChangeEndsAt(polygon);
    }

    function _receipt(bytes32 ticketId, uint256 amount) private view returns (MessageTypesLib.ReceiptMessage memory) {
        return _settlement(ticketId, aliceOnPolygon, bobOnPolygon, amount);
    }

    /// @dev Queues a receipt sent by `peer` through Polygon's first bridge, returning its index.
    function _peerSends(address peer, MessageTypesLib.ReceiptMessage memory receipt) private returns (uint256) {
        return _queue(polygonBridge, peer, token, MessageTypesLib.encodeSettlement(receipt));
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
        // An approval module is bound only while asks are paused.
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.addAndSetModule(address(approval), settings);
        boundCompliance.setAsksPaused(bytes32(0), false);
        vm.stopPrank();
    }

    /// @dev The backend approves the whole ticket and anyone hands the answer to the compliance.
    function _approve(AsyncApprovalModule approval, bytes32 ticketId) private {
        uint256 approvedMax = boundCompliance.ticketOf(ticketId).amountMax;
        vm.prank(backend);
        approval.approveValidation(address(boundCompliance), ticketId, approvedMax);
        approval.finalize(address(boundCompliance), ticketId);
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
