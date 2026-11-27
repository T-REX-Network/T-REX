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

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

contract OutboundMessagingTest is InteropSuiteTest {

    ERC7786GatewayMock gateway;

    address compliance;

    bytes32 satellite = polygon;
    bytes32 closedChain = optimism;

    /// @dev A non-EVM chain: CREATE3 gives no address there, so a peer must be registered explicitly.
    bytes32 solana = MessageTypesLib.chainKey(bytes2(0x0002), hex"01");

    bytes32 ticketId = bytes32(uint256(1));
    bytes validationBody = abi.encode(uint256(1), "validation");

    bytes aliceSat;

    function setUp() public override {
        super.setUp();

        gateway = _newReceiptBridge(POLYGON);
        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(gateway));

        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOnPolygon"));
        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();
    }

    /// @dev Alice's home wallet moves `amount` out to her Polygon wallet: a move out leaves at once.
    function _delegate(uint256 amount) private returns (bytes32) {
        bytes memory aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(alice);
        return boundCompliance.askToMove(aliceHome, aliceSat, amount, amount, "", _salt());
    }

    /// @dev The agent brings `amount` of Alice's Polygon wallet home: a bring home leaves at once.
    function _instruct(uint256 amount) private returns (bytes32) {
        vm.prank(agent);
        return boundCompliance.bringHome(aliceSat, amount, alice, _salt());
    }

    /// @dev Lands a move out's receipt for `amount`, so the away wallet holds it.
    function _landMoveOut(bytes32 moveOutId, uint256 amount) private {
        MessageTypesLib.ReceiptMessage memory receipt = MessageTypesLib.ReceiptMessage({
            ticketId: moveOutId,
            from: "",
            to: aliceSat,
            amount: amount,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: 1,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
        gateway.relay(_liteSettles(gateway, token, receipt));
    }

    function _dispatch(bytes32 id, bytes32 chainKey) private returns (bytes32) {
        vm.prank(compliance);
        return token.sendOnTicketRoute(chainKey, id, validationBody);
    }

    /* ----- Happy path ----- */

    /// @dev The peer is the token's own address on the satellite, not on the reference chain.
    function testComplianceDispatchesAValidationToItsLiteOnTheSatellite() public {
        _dispatch(ticketId, satellite);

        assertEq(gateway.queueLength(), 1);
        assertEq(gateway.queuedMessage(0).recipient, token.peerFor(satellite));
        assertEq(gateway.queuedMessage(0).recipient, InteroperableAddress.formatEvmV1(POLYGON, address(token)));
    }

    function testDispatchedPayloadDecodesBackToWhatWasSent() public {
        _dispatch(ticketId, satellite);

        (uint8 messageType, uint8 version, bytes memory body) =
            abi.decode(gateway.queuedMessage(0).payload, (uint8, uint8, bytes));

        assertEq(messageType, uint8(MessageTypesLib.Message.TICKET));
        assertEq(version, MessageTypesLib.VERSION);
        assertEq(body, validationBody);
    }

    function testEverySendAnnouncesItsTypeChainAndSendId() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(MessageTypesLib.Message.TICKET, satellite, gateway.receiveIdFor(0));

        _dispatch(ticketId, satellite);
    }

    function testBothTypesQueueSeparately() public {
        _dispatch(ticketId, satellite);
        _delegate(10);

        assertEq(gateway.queueLength(), 2);
    }

    /* ----- Route snapshot ----- */

    function testDispatchPinsTheRouteForTheValidation() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.HalfPinned(ticketId, satellite, address(gateway));

        _dispatch(ticketId, satellite);

        assertEq(_pinnedBridgeOf(ticketId), address(gateway));
    }

    /// @dev A lost message may be re-sent: same validation, same chain, same gateway.
    function testRedispatchThroughThePinnedGatewayIsAllowed() public {
        _dispatch(ticketId, satellite);
        _dispatch(ticketId, satellite);

        assertEq(gateway.queueLength(), 2);
        assertEq(_pinnedBridgeOf(ticketId), address(gateway));
    }

    /// @dev After a planned route change, a ticket sent before it is still asked through the pair it was pinned to:
    ///      the away token that holds it answers on that pair, which home keeps as the former one for a while.
    function testRedispatchAfterARouteChangeGoesThroughThePinnedFormerPair() public {
        _dispatch(ticketId, satellite);

        ERC7786GatewayMock other = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(other));

        _dispatch(ticketId, satellite);

        assertEq(gateway.queueLength(), 2, "asked through the pinned former bridge");
        assertEq(other.queueLength(), 0, "not through the new route");
        assertEq(_pinnedBridgeOf(ticketId), address(gateway), "the pin never moves");
    }

    /* ----- Move out: the second half of a move, here with no first half ----- */

    function testAHomeWalletMoveOutSendsAMoveOutAndItIsAnnounced() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(MessageTypesLib.Message.MOVE_OUT, satellite, gateway.receiveIdFor(0));

        bytes32 moveOutId = _delegate(10);

        assertEq(gateway.queueLength(), 1);
        (uint8 messageType,, bytes memory body) = abi.decode(gateway.queuedMessage(0).payload, (uint8, uint8, bytes));
        assertEq(messageType, uint8(MessageTypesLib.Message.MOVE_OUT));
        MessageTypesLib.MoveOutMessage memory moveOut = MessageTypesLib.decodeMintInstruction(body);
        assertEq(moveOut.ticketId, moveOutId);
        assertEq(moveOut.half, 1);
        assertEq(moveOut.toWallet, aliceSat);
        assertEq(moveOut.amount, 10);
        assertEq(moveOut.validUntil, block.timestamp + POLYGON_WINDOW);
    }

    /// @dev A move out pins its half to the route and peer it left through: its receipt is taken from that pair.
    function testAMoveOutPinsItsHalf() public {
        bytes32 first = _delegate(10);
        bytes32 second = _delegate(10);

        assertEq(gateway.queueLength(), 2);
        (address firstBridge,) = token.pinOf(MessageTypesLib.halfKeyOf(first, 1));
        (address secondBridge,) = token.pinOf(MessageTypesLib.halfKeyOf(second, 1));
        assertEq(firstBridge, address(gateway));
        assertEq(secondBridge, address(gateway));
    }

    /* ----- Bring home: a half out, a receipt back ----- */

    function testABringHomeIsAnnouncedAndRecorded() public {
        _landMoveOut(_delegate(100), 100);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(MessageTypesLib.Message.BRING_HOME, satellite, gateway.receiveIdFor(2));

        bytes32 bringHomeId = _instruct(40);

        assertEq(gateway.queueLength(), 3, "the move out, its receipt, the bring home");
        (uint8 messageType,, bytes memory body) = abi.decode(gateway.queuedMessage(2).payload, (uint8, uint8, bytes));
        assertEq(messageType, uint8(MessageTypesLib.Message.BRING_HOME));
        MessageTypesLib.BringHomeMessage memory half = MessageTypesLib.decodeBringHome(body);
        assertEq(half.ticketId, bringHomeId);
        assertEq(half.half, 1);
        assertEq(half.wallet, aliceSat);
        assertEq(half.amount, 40);

        assertEq(token.reservedOf(aliceSat), 40, "the bring home reserves its amount");
        (address pinnedBridge, bytes32 pinnedPeerKey) = token.pinOf(MessageTypesLib.halfKeyOf(bringHomeId, 1));
        assertEq(pinnedBridge, address(gateway), "the half is pinned to the bridge it left through");
        assertEq(pinnedPeerKey, keccak256(token.peerFor(satellite)), "and to the peer");
    }

    /// @dev The order changes nothing on the ledger: the position only moves when the answering receipt arrives.
    function testABringHomeMovesNothing() public {
        _landMoveOut(_delegate(100), 100);
        _instruct(40);

        assertEq(token.awayBalanceOf(aliceSat), 100);
        assertEq(token.balanceOf(alice), 900);
    }

    /* ----- Fail closed ----- */

    function testDispatchRevertsOnAChainThatWasNeverOpened() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, closedChain));
        _dispatch(ticketId, closedChain);

        assertEq(gateway.queueLength(), 0);
    }

    /// @dev Routed, but with no address to send to: a non-EVM chain has no CREATE3 default.
    function testDispatchRevertsOnARoutedChainWithNoPeer() public {
        uint64 solanaSelector = _awayChainSelector(0x01);
        bytes memory solanaReceiptBridge = abi.encode(makeAddr("solanaReceiptBridge"));
        ERC7786GatewayMock solanaRoute = new ERC7786GatewayMock(0x01);
        solanaRoute.setReceivingPolicy(solanaSelector, solanaReceiptBridge, FULL_FINALITY);
        trustedGatewayRegistry.setTrustedGateway(address(solanaRoute), true, 0);
        vm.prank(deployer);
        token.setReceiptRoute(bytes2(0x0002), hex"01", address(solanaRoute), solanaSelector, solanaReceiptBridge);

        assertEq(token.peerFor(solana), "");
        assertFalse(token.isChainOpen(solana));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, solana));
        _dispatch(ticketId, solana);

        vm.prank(deployer);
        token.setPeer(solana, hex"0001000201010401020304");

        _dispatch(ticketId, solana);
        assertEq(solanaRoute.queuedMessage(0).recipient, hex"0001000201010401020304");
    }

    function testDispatchRevertsForAnUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotCompliance.selector, alice));
        vm.prank(alice);
        token.sendOnTicketRoute(satellite, ticketId, validationBody);

        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        vm.prank(alice);
        token.sendOnReceiptRoute(satellite, ticketId, MessageTypesLib.Message.MOVE_OUT, validationBody);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        boundCompliance.bringHome(aliceSat, 1, alice, _salt());

        assertEq(gateway.queueLength(), 0);
    }

    /// @dev The agent brings home, never sends a validation: the body and the id it travels under are the
    ///      compliance's to author, and no role reaches past that.
    function testAgentCannotDispatchAValidationEvenThoughItBringsHome() public {
        _landMoveOut(_delegate(100), 100);
        _instruct(40);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotCompliance.selector, agent));
        vm.prank(agent);
        token.sendOnTicketRoute(satellite, ticketId, validationBody);

        assertEq(gateway.queueLength(), 3, "the move out, its receipt, the bring home");
        assertEq(_pinnedBridgeOf(ticketId), address(0));
    }

    /// @dev The emergency lever, proven end to end: removal stops traffic with no call on the token.
    function testRemovingTheGatewayStopsTrafficWithNoConfigChange() public {
        _dispatch(ticketId, satellite);
        assertEq(gateway.queueLength(), 1);

        trustedGatewayRegistry.setTrustedGateway(address(gateway), false, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, satellite));
        _dispatch(bytes32(uint256(2)), satellite);

        assertEq(gateway.queueLength(), 1, "nothing new was queued");
        assertEq(token.receiptRouteFor(satellite), address(gateway), "the route is untouched, trust is what moved");
    }

}
