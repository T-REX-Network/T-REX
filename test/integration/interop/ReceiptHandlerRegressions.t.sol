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
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev Two scenarios the receipt handler once got wrong, run against an away token that follows its rules: a
///      stranger cancelling a ticket the away token already executed while its receipt could not land, and one
///      holder's dropped ticket stopping every other holder of the same away chain.
contract ReceiptHandlerRegressionsTest is InteropSuiteTest {

    uint256 internal constant ALICE_HOME_BALANCE = 1000;
    uint256 internal constant ALICE_AWAY_BALANCE = 500;
    uint256 internal constant BOB_AWAY_BALANCE = 100;

    ERC7786GatewayMock internal polygonBridge;
    SatelliteLiteMock internal polygonLite;
    address internal stranger = makeAddr("stranger");

    Account internal aliceOnPolygon;
    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        polygonBridge = _newReceiptBridge(POLYGON);
        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonBridge, polygonBridge);
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)), false);
        _openEvmChain(token, POLYGON, address(polygonBridge));

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, ALICE_HOME_BALANCE);
        token.unpause();
        vm.stopPrank();

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
    }

    /// @notice The away token executed the ticket and its receipt is on its way when the issuer closes the receipt
    ///         route. A stranger past the cancel time cannot cancel: the receipt cannot land meanwhile. Once the
    ///         route opens again the receipt lands and home agrees with the away token.
    function test_cancelTickets_reverts_forAnExecutedTicket_whileItsReceiptRouteIsClosed() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 50);
        _relayAll(polygonBridge);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(ticketId, 40);
        uint256 receiptInFlight = polygonBridge.queueLength() - 1;

        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);
        vm.warp(issued.validUntil + boundCompliance.waitingTimeOf(issued.fromChainKey));
        boundCompliance.sendTicket(ticketId, bobSat, "");
        _closeEvmChain(token, POLYGON);
        vm.warp(block.timestamp + boundCompliance.waitingTimeOf(issued.fromChainKey) + 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.cancelTickets(_ids(ticketId));
        assertEq(token.reservedOf(aliceSat), 50, "the reservation is kept");

        _openEvmChain(token, POLYGON, address(polygonBridge));
        polygonBridge.relay(receiptInFlight);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), polygonLite.balanceOf(bobSat), "home agrees with the away token");
        assertEq(token.awayBalanceOf(bobSat), 40);
    }

    /// @notice A receipt for a ticket home has no record of, a holder's ticket a home reorg dropped, stops nobody
    ///         else: another holder still asks to move on the same away chain, and its receipt lands.
    function test_askToMove_succeeds_forAnotherHolder_afterAReceiptForAnUnknownTicket() public {
        bytes32 droppedTicket = keccak256("alice's ticket a home reorg dropped");
        MessageTypesLib.ReceiptMessage memory unknownReceipt =
            _settlementUnder(droppedTicket, aliceSat, bobSat, 95, keccak256("the dropped copy"));
        polygonBridge.relay(_liteSends(unknownReceipt));
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the away chain is not blocked");

        vm.startPrank(agent);
        token.mint(bob, BOB_AWAY_BALANCE);
        TokenLedgerHarness(address(token)).ledgerMoveOut(bob, bobSat, BOB_AWAY_BALANCE);
        vm.stopPrank();
        bytes32 bobsTicket = _requestValidation(address(bobIdentity), bobSat, aliceSat, 10, 50);
        polygonBridge.relay(_liteSends(_settlement(bobsTicket, bobSat, aliceSat, 30)));

        assertEq(uint8(boundCompliance.statusOf(bobsTicket)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), BOB_AWAY_BALANCE - 30, "another holder's receipt landed");
    }

    /* ----- Helpers ----- */

    /// @dev Queues a receipt authored by the away token on Polygon's bridge, returning its index.
    function _liteSends(MessageTypesLib.ReceiptMessage memory receipt) private returns (uint256) {
        return _queue(polygonBridge, address(polygonLite), token, MessageTypesLib.encodeSettlement(receipt));
    }

    /// @dev Delivers every queued entry of `gateway` not yet delivered or dropped, including the ones a delivery
    ///  queues behind it.
    function _relayAll(ERC7786GatewayMock gateway) private {
        for (uint256 i = 0; i < gateway.queueLength(); i++) {
            ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(i);
            if (message.deliveries == 0 && !message.dropped) gateway.relay(i);
        }
    }

    function _ids(bytes32 ticketId) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = ticketId;
    }

}
