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

import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { IReceiptHandler } from "contracts/interop/IReceiptHandler.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

contract InboundMessagingTest is InteropSuiteTest {

    ERC7786GatewayMock routedGateway;
    ERC7786GatewayMock otherTrustedGateway;
    ERC7786GatewayMock untrustedGateway;

    address impostor = makeAddr("Impostor");

    address compliance;

    bytes32 originChain = polygon;

    bytes32 ticketId;
    uint256 amount = 500;
    bytes satelliteFrom;
    bytes satelliteTo;

    function setUp() public override {
        super.setUp();

        routedGateway = _newReceiptBridge(POLYGON);
        otherTrustedGateway = _newReceiptBridge(POLYGON);
        untrustedGateway = new ERC7786GatewayMock(POLYGON);

        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(routedGateway));

        // A never-issued id reverts at the compliance, so the transport cases below run on a real one, which
        // settles for good.
        vm.prank(agent);
        token.unpause();
        satelliteFrom = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), 1000);
        satelliteTo = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        ticketId = _requestValidation(address(aliceIdentity), satelliteFrom, satelliteTo, 1, amount);
    }

    function _issuedSettlement() private view returns (MessageTypesLib.ReceiptMessage memory) {
        return _settlement(ticketId, satelliteFrom, satelliteTo, amount);
    }

    function _settlementPayload() private view returns (bytes memory) {
        return MessageTypesLib.encodeSettlement(_issuedSettlement());
    }

    function _peerSendsSettlement() private returns (uint256) {
        return _liteSends(routedGateway, token, _settlementPayload());
    }

    function _expectSettlementNotified(MessageTypesLib.ReceiptMessage memory n) private {
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptReceived(originChain, n.ticketId, n.from, n.to, n.amount);
    }

    /// @dev The `keccak256` of the token's Lite on Polygon, the peer every delivery here comes from.
    function _peerKey() private view returns (bytes32) {
        return keccak256(InteroperableAddress.formatEvmV1(POLYGON, address(token)));
    }

    /// @dev A refusal rolls the whole delivery back, so the token never records having seen it.
    function _assertNothingApplied(ERC7786GatewayMock gateway, uint256 index) private view {
        assertFalse(token.messageReceived(address(gateway), gateway.receiveIdFor(index)));
    }

    /* ----- Receipt delivery ----- */

    /// @dev Same-chain transfer: one notification with real `from` and `to`, forwarded as decoded and settled.
    function testOneLegSettlementReachesTheBoundComplianceIntact() public {
        MessageTypesLib.ReceiptMessage memory n = _issuedSettlement();
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(n));

        vm.expectCall(
            compliance,
            abi.encodeCall(IReceiptHandler.receiveReceipt, (originChain, address(routedGateway), _peerKey(), n))
        );
        _expectSettlementNotified(n);

        routedGateway.relay(index);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(index)));
        assertEq(token.awayBalanceOf(satelliteTo), amount);
        assertFalse(token.paused());
    }

    /// @dev A receipt for an id this token has no record of reaches the compliance, which refuses it: the delivery
    ///      reverts and stays deliverable at the bridge, and no chain is blocked over an id home does not know.
    function testAReceiptForAnUnknownIdRevertsAndBlocksNobody() public {
        bytes32 neverIssued = bytes32(uint256(ticketId) + 1);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(neverIssued, satelliteFrom, satelliteTo, amount);
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(receipt));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, neverIssued));
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
        assertFalse(boundCompliance.isAwayChainBlocked(originChain), "no chain is blocked");
        assertFalse(token.paused());
    }

    /// @dev One side on the reference chain: a single leg, from the one satellite involved, reaches the
    ///      compliance intact.
    function testSingleLegSettlementWhenOneSideIsTheReferenceChain() public {
        MessageTypesLib.ReceiptMessage memory leg = _settlement(
            ticketId,
            InteroperableAddress.formatEvmV1(POLYGON, makeAddr("From")),
            InteroperableAddress.formatEvmV1(block.chainid, makeAddr("NativeTo")),
            amount
        );
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(leg));

        vm.expectCall(
            compliance,
            abi.encodeCall(IReceiptHandler.receiveReceipt, (originChain, address(routedGateway), _peerKey(), leg)),
            1
        );
        // Not the issued wallets, under the issued ask block hash: the compliance rejects the leg and pauses the chain
        // that reported it. The delivery is consumed, nothing applied, the validation untouched.
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptRefused(ticketId, originChain, amount, leg.askBlockHash);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(originChain);
        routedGateway.relay(index);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(index)));
        assertTrue(boundCompliance.isAwayChainBlocked(originChain));
        assertFalse(token.paused());
        assertEq(token.awayBalanceOf(satelliteTo), 0);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open));
    }

    function testReceiveIsAnnounced() public {
        uint256 index = _peerSendsSettlement();

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageReceived(
            MessageTypesLib.Message.RECEIPT, originChain, routedGateway.receiveIdFor(index)
        );

        routedGateway.relay(index);
    }

    /// @dev The compliance's entry point belongs to the token alone.
    function testOnlyTheBoundTokenMayHandASettlementToTheCompliance() public {
        MessageTypesLib.ReceiptMessage memory n = _issuedSettlement();

        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        vm.prank(impostor);
        IReceiptHandler(compliance).receiveReceipt(originChain, address(routedGateway), _peerKey(), n);
    }

    /* ----- Burn proof: the recall path ----- */

    /// @dev The proof reaches the recall path with every field intact and credits the instructed wallet; the
    ///      settlement handler never sees it.
    function testBurnProofReachesTheRecallPathIntact() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(satelliteFrom, 100, alice);
        uint256 index =
            _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 100)));
        uint256 nativeBefore = token.balanceOf(alice);

        vm.expectCall(compliance, abi.encodeWithSelector(IReceiptHandler.receiveReceipt.selector), 0);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.BurnProofReceived(originChain, recallId, satelliteFrom, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.RecallSettled(recallId, originChain, 100);
        routedGateway.relay(index);

        assertEq(token.balanceOf(alice), nativeBefore + 100);
        assertEq(token.awayBalanceOf(satelliteFrom), 900);
    }

    /// @dev A proof answering a recall this token never issued stops nothing: the delivery reverts and stays
    ///      deliverable, the token keeps running and the chain stays open.
    function testBurnProofForANeverIssuedRecallStopsNothing() public {
        uint256 index =
            _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(99, satelliteFrom, amount)));
        uint256 nativeBefore = token.balanceOf(alice);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallNotPending.selector, 99));
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
        assertFalse(token.paused());
        assertFalse(boundCompliance.isAwayChainBlocked(originChain));
        assertEq(token.balanceOf(alice), nativeBefore);
        assertEq(token.awayBalanceOf(satelliteFrom), 1000);
    }

    /* ----- Outbound-only types have no inbound handler ----- */

    function testOutboundOnlyTypesAreRefusedInbound() public {
        bytes memory body = abi.encode(uint256(1), "not for us");

        uint256 validation =
            _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.TICKET, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.Message.TICKET)
        );
        routedGateway.relay(validation);

        uint256 mint = _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.MOVE_OUT, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.Message.MOVE_OUT)
        );
        routedGateway.relay(mint);

        uint256 recall =
            _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.BRING_HOME, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.Message.BRING_HOME)
        );
        routedGateway.relay(recall);
    }

    /* ----- The rejection matrix: three trust levels, three errors ----- */

    function testUntrustedGatewayIsRefused() public {
        uint256 index = _liteSends(untrustedGateway, token, _settlementPayload());

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(untrustedGateway),
                InteroperableAddress.formatEvmV1(POLYGON, address(token))
            )
        );
        untrustedGateway.relay(index);

        _assertNothingApplied(untrustedGateway, index);
    }

    /// @dev The issued validation is pinned to the routed gateway, so an unpinned id is what exercises the
    ///      current-route check.
    function testTrustedButUnroutedGatewayIsRefused() public {
        bytes memory unpinned = MessageTypesLib.encodeSettlement(
            _settlement(bytes32(uint256(ticketId) + 1), satelliteFrom, satelliteTo, amount)
        );
        uint256 index = _liteSends(otherTrustedGateway, token, unpinned);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(otherTrustedGateway), originChain)
        );
        otherTrustedGateway.relay(index);

        _assertNothingApplied(otherTrustedGateway, index);
    }

    function testNonPeerAuthorIsRefusedThroughTheRightGateway() public {
        uint256 index = _queue(routedGateway, impostor, token, _settlementPayload());

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector, originChain, InteroperableAddress.formatEvmV1(POLYGON, impostor)
            )
        );
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /// @dev The token's own address, but on a chain the issuer never opened: a chain with no route accepts
    ///      no settlement.
    function testASettlementFromAnUnopenedChainIsRefused() public {
        ERC7786GatewayMock strangerChain = _newReceiptBridge(OPTIMISM);
        uint256 index = _liteSends(strangerChain, token, _settlementPayload());

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        strangerChain.relay(index);
    }

    /* ----- Replay: transport versus semantic ----- */

    function testTransportReplayIsRefused() public {
        uint256 index = _peerSendsSettlement();

        routedGateway.relay(index);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.MessageAlreadyReceived.selector, address(routedGateway), routedGateway.receiveIdFor(index)
            )
        );
        routedGateway.relay(index);

        assertEq(routedGateway.queuedMessage(index).deliveries, 1, "delivered once");
    }

    /// @dev A fresh receiveId carrying already-consumed content is the compliance's to judge, not this layer's:
    ///      both deliveries reach it. The very leg it applied comes back a duplicate: consumed, nothing paused.
    function testSemanticRedeliveryIsPassedThroughUntouched() public {
        uint256 first = _peerSendsSettlement();
        uint256 second = _peerSendsSettlement();
        assertTrue(routedGateway.receiveIdFor(first) != routedGateway.receiveIdFor(second));

        vm.expectCall(compliance, abi.encodeWithSelector(IReceiptHandler.receiveReceipt.selector), 2);
        routedGateway.relay(first);

        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptDuplicate(ticketId, originChain);
        routedGateway.relay(second);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(second)), "consumed");
        assertFalse(boundCompliance.isAwayChainBlocked(originChain), "a duplicate pauses nothing");
        assertFalse(token.paused());
        assertEq(token.awayBalanceOf(satelliteTo), amount, "applied once");
    }

    /// @dev A blocked away chain's receipt is consumed and waits at the compliance, tagged with its bridge and peer;
    ///      its burn proof is refused after attribution and stays deliverable. Once the block is lifted, anyone
    ///      applies the waiting receipt and the proof lands.
    function testABlockedChainsReceiptWaitsAndItsBurnProofStaysDeliverable() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(satelliteFrom, 100, alice);
        MessageTypesLib.ReceiptMessage memory receipt = _issuedSettlement();
        uint256 settlement = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(receipt));
        uint256 proof =
            _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 100)));
        uint256 nativeBefore = token.balanceOf(alice);
        vm.prank(agent);
        boundCompliance.blockAwayChain(originChain);

        routedGateway.relay(settlement);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, originChain));
        routedGateway.relay(proof);
        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(settlement)), "consumed");
        _assertNothingApplied(routedGateway, proof);
        assertEq(token.awayBalanceOf(satelliteTo), 0, "the receipt waits");
        assertTrue(token.isChainOpen(originChain), "outbound is not gated");
        assertFalse(token.paused());

        vm.prank(agent);
        boundCompliance.unblockAwayChain(originChain);
        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(receipt.ticketId, 0), receipt);
        routedGateway.relay(proof);

        assertEq(token.awayBalanceOf(satelliteTo), amount);
        assertEq(token.balanceOf(alice), nativeBefore + 100);
    }

    /* ----- Zero receive ids: no transport record, deduplicated by what the message carries ----- */

    /// @dev The routed gateway delivering from the token's peer on Polygon without naming the delivery.
    function _deliverWithZeroReceiveId(bytes memory payload) private {
        vm.prank(address(routedGateway));
        token.receiveMessage(bytes32(0), InteroperableAddress.formatEvmV1(POLYGON, address(token)), payload);
    }

    /// @dev A gateway that names no delivery keeps delivering: a first zero id must not refuse every later one.
    function testZeroReceiveIdDoesNotBlockLaterMessages() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(satelliteFrom, 100, alice);
        uint256 nativeBefore = token.balanceOf(alice);

        _deliverWithZeroReceiveId(_settlementPayload());
        _deliverWithZeroReceiveId(MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 100)));

        assertEq(token.awayBalanceOf(satelliteTo), amount, "the settlement applied");
        assertEq(token.balanceOf(alice), nativeBefore + 100, "the burn proof applied");
        assertFalse(token.messageReceived(address(routedGateway), bytes32(0)), "a zero id is never recorded");
        assertFalse(token.paused());
    }

    /// @dev A settlement delivered twice under a zero id is judged by the compliance: applied once, and the second
    ///      delivery is a duplicate, consumed with nothing paused, as under two distinct ids.
    function testZeroReceiveIdSettlementRedeliveryIsADuplicateAppliedOnce() public {
        _deliverWithZeroReceiveId(_settlementPayload());

        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptDuplicate(ticketId, originChain);
        _deliverWithZeroReceiveId(_settlementPayload());

        assertFalse(boundCompliance.isAwayChainBlocked(originChain), "a duplicate pauses nothing");
        assertFalse(token.paused());
        assertEq(token.awayBalanceOf(satelliteTo), amount, "applied once");
        assertEq(token.awayBalanceOf(satelliteFrom), 1000 - amount, "debited once");
    }

    /// @dev A burn proof delivered twice under a zero id is recognised by the settled proof's hash: credited once,
    ///      and the second delivery changes nothing.
    function testZeroReceiveIdBurnProofReplayIsRefusedByTheSettledProof() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(satelliteFrom, 100, alice);
        bytes memory proof = MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 100));
        uint256 nativeBefore = token.balanceOf(alice);
        _deliverWithZeroReceiveId(proof);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.BurnProofDuplicate(recallId, originChain);
        _deliverWithZeroReceiveId(proof);

        assertFalse(token.paused());
        assertEq(token.balanceOf(alice), nativeBefore + 100, "credited once");
        assertEq(token.awayBalanceOf(satelliteFrom), 900, "debited once");
    }

    /// @dev A different proof for the recall already settled, under a zero id, is the replay emergency.
    function testZeroReceiveIdDifferentProofForASettledRecallPausesTheChain() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(satelliteFrom, 100, alice);
        uint256 nativeBefore = token.balanceOf(alice);
        _deliverWithZeroReceiveId(MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 100)));

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ReplayedBurnProof(recallId, originChain);
        _deliverWithZeroReceiveId(MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 60)));

        assertTrue(boundCompliance.isAwayChainBlocked(originChain));
        assertFalse(token.paused());
        assertEq(token.balanceOf(alice), nativeBefore + 100, "credited once");
    }

    /* ----- Envelope refusals ----- */

    /// @dev The refusal carries no data, so what is asserted is that it lands before any handler and
    /// leaves the receipt unrecorded, letting a corrected message follow.
    function testUndefinedMessageTypeReachesNoHandler() public {
        uint8 undefinedType = uint8(type(MessageTypesLib.Message).max) + 1;
        uint256 index = _liteSends(routedGateway, token, abi.encode(undefinedType, MessageTypesLib.VERSION, "x"));

        vm.expectCall(compliance, abi.encodeWithSelector(IReceiptHandler.receiveReceipt.selector), 0);

        vm.expectRevert();
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    function testUnsupportedVersionReachesNoHandler() public {
        uint8 futureVersion = MessageTypesLib.VERSION + 1;
        uint256 index =
            _liteSends(routedGateway, token, abi.encode(MessageTypesLib.Message.RECEIPT, futureVersion, "x"));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, futureVersion));
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /// @dev A well-typed envelope around a body that is not a settlement never reaches the compliance.
    function testMalformedSettlementBodyIsRefused() public {
        uint256 index =
            _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.RECEIPT, hex"deadbeef"));

        vm.expectCall(compliance, abi.encodeWithSelector(IReceiptHandler.receiveReceipt.selector), 0);
        vm.expectRevert();
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /* ----- Teardown: the emergency lever closes the door both ways ----- */

    function testUntrustingTheGatewayStopsInboundToo() public {
        uint256 index = _peerSendsSettlement();

        trustedGatewayRegistry.distrustBridge(address(routedGateway));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(routedGateway),
                InteroperableAddress.formatEvmV1(POLYGON, address(token))
            )
        );
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

}
