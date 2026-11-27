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

        // The transport cases below run on a real ticket, whose receipt settles for good.
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

    /// @dev A receipt for an id this token has no record of reaches the compliance, which puts its amount on hold under
    ///      its sender with no destination: the delivery is consumed and no chain is blocked over an id home does not
    ///      know.
    function testAReceiptForAnUnknownIdIsPutOnHoldAndBlocksNobody() public {
        bytes32 neverIssued = bytes32(uint256(ticketId) + 1);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(neverIssued, satelliteFrom, satelliteTo, amount);
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(receipt));

        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptWithoutTicket(neverIssued, originChain, satelliteFrom, satelliteTo, amount);
        routedGateway.relay(index);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(index)), "consumed");
        assertEq(uint8(boundCompliance.statusOf(neverIssued)), uint8(ITickets.TicketStatus.OnHold));
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

    /* ----- A bring home's receipt ----- */

    /// @dev A bring home's receipt reaches the compliance through the same handler as every receipt and mints at the
    ///      home wallet what the away token burned.
    function testABringHomeReceiptReachesTheComplianceIntact() public {
        bytes32 bringHomeId = _bringHome(100);
        MessageTypesLib.ReceiptMessage memory receipt = _bringHomeReceipt(bringHomeId, 100);
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(receipt));
        uint256 nativeBefore = token.balanceOf(alice);

        vm.expectCall(
            compliance,
            abi.encodeCall(IReceiptHandler.receiveReceipt, (originChain, address(routedGateway), _peerKey(), receipt))
        );
        routedGateway.relay(index);

        assertEq(token.balanceOf(alice), nativeBefore + 100);
        assertEq(token.awayBalanceOf(satelliteFrom), 900);
    }

    /// @dev A second-half receipt for an id home has no record of is consumed and announced: it stops nothing.
    function testASecondHalfReceiptForAnUnknownIdStopsNothing() public {
        bytes32 neverIssued = keccak256("a bring home this token never wrote");
        uint256 index =
            _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(_bringHomeReceipt(neverIssued, amount)));
        uint256 nativeBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptUnknown(MessageTypesLib.halfKeyOf(neverIssued, 1), originChain);
        routedGateway.relay(index);

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

        uint256 bringHome =
            _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.BRING_HOME, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.Message.BRING_HOME)
        );
        routedGateway.relay(bringHome);
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

    /// @dev A blocked away chain's receipts are consumed and wait at the compliance, tagged with their bridge and
    ///      peer, a bring home's included. Once the block is lifted, anyone applies the waiting receipts.
    function testABlockedChainsReceiptsWait() public {
        bytes32 bringHomeId = _bringHome(100);
        MessageTypesLib.ReceiptMessage memory receipt = _issuedSettlement();
        MessageTypesLib.ReceiptMessage memory bringHomeReceipt = _bringHomeReceipt(bringHomeId, 100);
        uint256 settlement = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(receipt));
        uint256 burned = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(bringHomeReceipt));
        uint256 nativeBefore = token.balanceOf(alice);
        vm.prank(agent);
        boundCompliance.blockAwayChain(originChain);

        routedGateway.relay(settlement);
        routedGateway.relay(burned);
        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(settlement)), "consumed");
        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(burned)), "consumed");
        assertEq(token.awayBalanceOf(satelliteTo), 0, "the receipt waits");
        assertEq(token.balanceOf(alice), nativeBefore, "the bring home's receipt waits");
        assertTrue(token.isChainOpen(originChain), "outbound is not gated");
        assertFalse(token.paused());

        vm.prank(agent);
        boundCompliance.unblockAwayChain(originChain);
        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(receipt.ticketId, 0), receipt);
        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(bringHomeId, 1), bringHomeReceipt);

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
        bytes32 bringHomeId = _bringHome(100);
        uint256 nativeBefore = token.balanceOf(alice);

        _deliverWithZeroReceiveId(_settlementPayload());
        _deliverWithZeroReceiveId(MessageTypesLib.encodeSettlement(_bringHomeReceipt(bringHomeId, 100)));

        assertEq(token.awayBalanceOf(satelliteTo), amount, "the settlement applied");
        assertEq(token.balanceOf(alice), nativeBefore + 100, "the bring home's receipt applied");
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

    /// @dev A bring home's receipt delivered twice under a zero id is recognised by the half's receipt: minted once,
    ///      and the second delivery changes nothing.
    function testZeroReceiveIdBringHomeReceiptReplayIsADuplicate() public {
        bytes32 bringHomeId = _bringHome(100);
        bytes memory payload = MessageTypesLib.encodeSettlement(_bringHomeReceipt(bringHomeId, 100));
        uint256 nativeBefore = token.balanceOf(alice);
        _deliverWithZeroReceiveId(payload);

        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptDuplicate(bringHomeId, originChain);
        _deliverWithZeroReceiveId(payload);

        assertFalse(token.paused());
        assertEq(token.balanceOf(alice), nativeBefore + 100, "minted once");
        assertEq(token.awayBalanceOf(satelliteFrom), 900, "debited once");
    }

    /// @dev Another receipt for a bring home half that already has one, under a zero id, blocks the chain.
    function testZeroReceiveIdAnotherReceiptForAnsweredHalfBlocksTheChain() public {
        bytes32 bringHomeId = _bringHome(100);
        uint256 nativeBefore = token.balanceOf(alice);
        _deliverWithZeroReceiveId(MessageTypesLib.encodeSettlement(_bringHomeReceipt(bringHomeId, 100)));

        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptRefused(bringHomeId, originChain, 60, bytes32(0));
        _deliverWithZeroReceiveId(MessageTypesLib.encodeSettlement(_bringHomeReceipt(bringHomeId, 60)));

        assertTrue(boundCompliance.isAwayChainBlocked(originChain));
        assertFalse(token.paused());
        assertEq(token.balanceOf(alice), nativeBefore + 100, "minted once");
    }

    /// @dev An agent brings `bringAmount` of alice's away wallet home.
    function _bringHome(uint256 bringAmount) private returns (bytes32) {
        vm.prank(agent);
        return boundCompliance.bringHome(satelliteFrom, bringAmount, alice, _salt());
    }

    /// @dev The away token's receipt for the first half of a bring home: it names the burned wallet only.
    function _bringHomeReceipt(bytes32 bringHomeId, uint256 burned)
        private
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return MessageTypesLib.ReceiptMessage({
            ticketId: bringHomeId,
            from: satelliteFrom,
            to: "",
            amount: burned,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: 1,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
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
