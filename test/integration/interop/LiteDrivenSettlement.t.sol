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

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev The reference chain run against Lites that follow `docs/satellite-lite.md`: every inbound message is produced
///      by a Lite acting on what the token sent it, never hand-built. Each gateway mock carries both directions of one
///      chain and is the token's route there; each Lite is the token's registered peer.
contract LiteDrivenSettlementTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;
    uint256 internal constant DELEGATED = 500;

    ERC7786GatewayMock polygonGateway;
    ERC7786GatewayMock optimismGateway;
    SatelliteLiteMock polygonLite;
    SatelliteLiteMock optimismLite;

    Account aliceOnPolygon;
    bytes aliceSat;
    bytes bobSat;
    bytes nativeBob;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);

        // Each away token is the token's peer before its route opens: a peer set on an open route is a change.
        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        optimismLite = new SatelliteLiteMock(OPTIMISM, address(token), optimismGateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)), false);
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, address(optimismLite)), false);
        vm.stopPrank();
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();

        _moveOut(DELEGATED);
        _relayAll(polygonGateway);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED, "the Lite minted what the token moved out");
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED, "and its receipt landed");
    }

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

    function _issueAndDeliver(bytes memory to, uint256 min, uint256 max) private returns (bytes32 id) {
        id = _requestValidation(address(aliceIdentity), aliceSat, to, min, max);
        _relayAll(polygonGateway);
        _relayAll(optimismGateway);
    }

    /// @dev Alice's home wallet moves `amount` out to her away wallet; returns the ticket.
    function _moveOut(uint256 amount) private returns (bytes32) {
        bytes memory aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(alice);
        return boundCompliance.askToMove(aliceHome, aliceSat, amount, amount, "", _salt());
    }

    function _bringHome(uint256 amount) private returns (bytes32) {
        vm.prank(agent);
        return boundCompliance.bringHome(aliceSat, amount, alice, _salt());
    }

    function _execute(bytes32 id, uint256 amount) private {
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(id, amount);
    }

    function _status(bytes32 id) private view returns (ITickets.TicketStatus) {
        return boundCompliance.statusOf(id);
    }

    /// @dev A copy of an ask from `aliceSat` to `bobSat` written in the current block, with `amountMax` as home
    ///      narrowed it, as the token would send it.
    function _copy(bytes32 id, bytes32 salt, uint256 amountMax)
        private
        view
        returns (MessageTypesLib.TicketMessage memory copy)
    {
        uint64 validUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        copy = MessageTypesLib.TicketMessage({
            ticketId: id,
            kind: uint8(ITickets.TicketKind.MOVE),
            salt: salt,
            from: aliceSat,
            to: bobSat,
            spender: "",
            amountMin: 1,
            amountMax: amountMax,
            requestedMax: 1000,
            token: address(token),
            validUntil: validUntil,
            askBlockHash: TicketLib.askBlockHashOf(amountMax, validUntil)
        });
    }

    /// @dev Delivers a ticket copy to the polygon Lite, authored by the token as the gateway attributes it.
    function _deliverToLite(MessageTypesLib.TicketMessage memory copy) private {
        bytes memory recipient = InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite));
        vm.prank(address(token));
        polygonGateway.sendMessage(recipient, MessageTypesLib.encodeValidation(copy), new bytes[](0));
        polygonGateway.relay(_last(polygonGateway));
    }

    /* ----- One leg ----- */

    function test_oneLeg_Success_WhenTheLiteSettlesToTheReferenceChain() public {
        bytes32 id = _issueAndDeliver(nativeBob, 100, 100);

        _execute(id, 100);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.balanceOf(bob), 100);
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED - 100);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED - 100);
        assertEq(token.totalSupply(), MINTED);
    }

    function test_oneLeg_Success_WhenTheLiteSettlesOnItsOwnChain() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);

        _execute(id, 50);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 50);
        assertEq(polygonLite.balanceOf(bobSat), 50);
    }

    /// @notice The receipt is slow: home asks for it one waiting time after valid until, and the Lite answers the
    ///         ask with its stored receipt. Nothing executes twice, and the receipt that was in flight is a duplicate.
    function test_sendTicket_landsTheStoredReceipt_whenTheAwayTokenAlreadyExecuted() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);
        _execute(id, 50);
        uint256 settlement = _last(polygonGateway);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Open));

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        vm.warp(ticket.validUntil + boundCompliance.waitingTimeOf(ticket.fromChainKey));
        vm.prank(makeAddr("anyone"));
        boundCompliance.sendTicket(id, bobSat, "");
        polygonGateway.relay(_last(polygonGateway));
        assertEq(polygonLite.balanceOf(bobSat), 50, "nothing executed twice");
        polygonGateway.relay(_last(polygonGateway));
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done), "the stored receipt answered the ask");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(settlement);
        assertFalse(token.paused());
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice Asked once its valid until passed, a ticket the Lite never executed is answered with a stored zero
    ///         receipt: it never will be, and home ends it with nothing moved.
    function test_sendTicket_isAnsweredExpired_whenTheAwayTokenNeverExecuted() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        vm.warp(ticket.validUntil + boundCompliance.waitingTimeOf(ticket.fromChainKey));
        boundCompliance.sendTicket(id, bobSat, "");

        polygonGateway.relay(_last(polygonGateway));

        (, bytes memory body) = MessageTypesLib.decode(polygonGateway.queuedMessage(_last(polygonGateway)).payload);
        MessageTypesLib.ReceiptMessage memory answer = MessageTypesLib.decodeSettlement(body);
        assertEq(uint8(answer.answer), uint8(MessageTypesLib.ReceiptAnswer.Expired), "past valid until: expired");
        assertEq(answer.amount, 0);
        polygonGateway.relay(_last(polygonGateway));
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done), "a zero receipt ends the ticket");
        assertEq(token.reservedOf(aliceSat), 0, "and gives its reservation back");
    }

    /* ----- The Lite's own rules ----- */

    function test_execute_RevertWhen_TheCallerIsNeitherSenderNorSpender() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.NotTheExecutor.selector, id, bob));
        polygonLite.execute(id, 50);
    }

    function test_execute_RevertWhen_TheValidationIsConsumed() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);
        _execute(id, 50);

        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.ValidationConsumed.selector, id));
        polygonLite.execute(id, 50);
    }

    function test_execute_RevertWhen_TheValidationExpired() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);
        vm.warp(block.timestamp + VALIDITY_WINDOW);

        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.ValidationExpired.selector, id));
        polygonLite.execute(id, 50);
    }

    function test_execute_RevertWhen_TheAmountIsOutsideTheRange() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);

        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.AmountOutOfRange.selector, id, 51));
        polygonLite.execute(id, 51);
    }

    /// @notice The receipt names the copy the Lite executed: its ask block hash, its maximum and its valid until,
    ///         and says it executed.
    function test_execute_echoesTheCopyItExecuted() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);
        ITickets.Ticket memory issued = boundCompliance.ticketOf(id);

        _execute(id, 30);

        (, bytes memory body) = MessageTypesLib.decode(polygonGateway.queuedMessage(_last(polygonGateway)).payload);
        MessageTypesLib.ReceiptMessage memory receipt = MessageTypesLib.decodeSettlement(body);
        assertEq(receipt.ticketId, id);
        assertEq(receipt.amount, 30);
        assertEq(receipt.askBlockHash, issued.askBlockHash, "the copy home wrote");
        assertEq(receipt.seenMax, 50, "the maximum of that copy");
        assertEq(receipt.seenValidUntil, issued.validUntil, "the valid until of that copy");
        assertEq(receipt.half, 0, "the away token's execution of the ticket");
        assertEq(uint8(receipt.answer), uint8(MessageTypesLib.ReceiptAnswer.Executed));
    }

    /// @notice A later copy of a ticket under the same id never takes the place of the first: here the first
    ///         copy, a maximum of 10, has expired, and a later copy with a maximum of 1000 must not bring it back.
    function test_hold_keepsTheFirstCopy_whenALaterCopyArrives() public {
        bytes32 salt = _salt();
        bytes32 id = _ticketId(aliceSat, bobSat, "", 1, 1000, salt);
        MessageTypesLib.TicketMessage memory firstCopy = _copy(id, salt, 10);
        _deliverToLite(firstCopy);

        vm.warp(firstCopy.validUntil);
        vm.roll(block.number + 1);
        MessageTypesLib.TicketMessage memory laterCopy = _copy(id, salt, 1000);
        _deliverToLite(laterCopy);

        assertEq(polygonLite.ticketOf(id).amountMax, 10, "the first copy is kept");
        assertEq(polygonLite.ticketOf(id).askBlockHash, firstCopy.askBlockHash, "the first copy is kept");
        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.ValidationExpired.selector, id));
        polygonLite.execute(id, 500);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED, "nothing moved");
    }

    function test_receiveMessage_RevertWhen_NotDeliveredByItsGateway() public {
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.NotTheGateway.selector, address(this)));
        polygonLite.receiveMessage(bytes32(0), "", "");
    }

    /* ----- Move out retries ----- */

    /// @notice The move out is slow; anyone sends it again at its due time, past its valid until, so the Lite answers
    ///         it expired; home sends a new half, which mints. The first copy, arriving last, is answered with the
    ///         stored zero receipt, which changes nothing. The Lite minted once, home burned once.
    function test_sendSecondHalf_mintsOnce_whenTheMoveOutWasSlow() public {
        bytes32 id = _moveOut(100);
        uint256 original = _last(polygonGateway);
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);

        vm.warp(ticket.secondHalfValidUntil + POLYGON_WINDOW);
        boundCompliance.sendSecondHalf(id, aliceSat);
        polygonGateway.relay(_last(polygonGateway));
        polygonGateway.relay(_last(polygonGateway));
        assertTrue(boundCompliance.ticketOf(id).secondHalfOwed, "the expired half makes a new one owed");

        boundCompliance.sendSecondHalf(id, aliceSat);
        uint256 newHalf = _last(polygonGateway);
        polygonGateway.relay(newHalf);
        polygonGateway.relay(_last(polygonGateway));
        polygonGateway.relay(original);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED + 100, "minted once");
        assertEq(polygonLite.mints(), DELEGATED + 100);
        assertEq(token.balanceOf(alice), MINTED - DELEGATED - 100, "burned once at home");
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED + 100);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /* ----- Bring home ----- */

    function test_bringHome_Success_WhenTheLiteAnswersTheHalf() public {
        bytes32 id = _bringHome(200);
        polygonGateway.relay(_last(polygonGateway));
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED - 200, "the Lite burned what was asked");

        polygonGateway.relay(_last(polygonGateway));

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.balanceOf(alice), MINTED - DELEGATED + 200);
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED - 200);
        assertEq(token.totalSupply(), MINTED);
    }

    /// @notice A ticket and a bring home on one wallet never count on the same tokens: the bring home is bounded by
    ///         what the ticket leaves free, so the Lite has what both ask for and both settle.
    function test_bringHome_andATicket_bothSettle_whenTheLiteExecutesBoth() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 400, 400);
        uint256 validation = _last(polygonGateway);
        bytes32 bringHomeId = _bringHome(DELEGATED - 400);
        uint256 bringHomeHalf = _last(polygonGateway);
        polygonGateway.relay(validation);
        _execute(id, 400);
        polygonGateway.relay(_last(polygonGateway));
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));

        polygonGateway.relay(bringHomeHalf);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(uint8(_status(bringHomeId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.balanceOf(alice), MINTED - 400);
        assertEq(token.awayBalanceOf(aliceSat), 0);
        assertEq(polygonLite.balanceOf(aliceSat), 0);
    }

    /// @notice The bring home's half is slow; anyone sends it again at its due time, past its valid until, so the
    ///         Lite answers it expired and burns nothing: the bring home ends with nothing moved. The first copy,
    ///         arriving last, is answered with the stored zero receipt, a duplicate.
    function test_sendSecondHalf_endsTheBringHomeWithNothingMoved_whenItsHalfArrivesExpired() public {
        bytes32 id = _bringHome(200);
        uint256 original = _last(polygonGateway);

        vm.warp(boundCompliance.ticketOf(id).secondHalfValidUntil + POLYGON_WINDOW);
        boundCompliance.sendSecondHalf(id, aliceSat);
        polygonGateway.relay(_last(polygonGateway));
        polygonGateway.relay(_last(polygonGateway));
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));

        polygonGateway.relay(original);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(polygonLite.burns(), 0, "burned nothing");
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED, "nothing came home");
        assertEq(token.reservedOf(aliceSat), 0);
        assertFalse(token.paused());
    }

    /// @notice The bring home's receipt is lost; the Lite sends its stored receipt again; it lands once.
    function test_resendReceipt_Success_WhenTheBringHomeReceiptWasLost() public {
        bytes32 id = _bringHome(200);
        polygonGateway.relay(_last(polygonGateway));
        polygonGateway.drop(_last(polygonGateway));
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Open), "still waiting");

        vm.warp(block.timestamp + polygonLite.receiptResendWait());
        polygonLite.resendReceipt(uint8(MessageTypesLib.Message.BRING_HOME), MessageTypesLib.halfKeyOf(id, 1));
        polygonGateway.relay(_last(polygonGateway));

        assertEq(token.balanceOf(alice), MINTED - DELEGATED + 200);
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
    }

    /* ----- Settlement resend ----- */

    /// @notice The settlement is lost; the Lite resends its stored report, byte for byte; it settles once.
    function test_resendSettlement_Success_WhenTheSettlementWasLost() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);
        _execute(id, 50);
        polygonGateway.drop(_last(polygonGateway));
        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Open), "still waiting");

        vm.warp(block.timestamp + polygonLite.receiptResendWait());
        polygonLite.resendReceipt(uint8(MessageTypesLib.Message.TICKET), id);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(uint8(_status(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 50);
    }

    /// @notice The Lite cannot tell a lost settlement from a slow one, so it may resend one that already landed,
    ///         as anyone may on T-REX-Lite. The reference chain recognises the leg it applied: nothing moves twice
    ///         and the chain is not paused.
    function test_resendSettlement_Success_WhenTheSettlementAlreadyLanded() public {
        bytes32 id = _issueAndDeliver(bobSat, 10, 50);
        _execute(id, 50);
        _relayAll(polygonGateway);

        vm.warp(block.timestamp + polygonLite.receiptResendWait());
        polygonLite.resendReceipt(uint8(MessageTypesLib.Message.TICKET), id);
        uint256 resent = _last(polygonGateway);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(resent);

        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(resent)), "consumed");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(token.paused());
        assertEq(token.awayBalanceOf(bobSat), 50, "credited once");
        assertEq(token.awayBalanceOf(aliceSat), DELEGATED - 50, "debited once");
    }

}
