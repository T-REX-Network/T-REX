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

/// @dev An ask for the receipt of a ticket, sent through the real messaging layer: anyone may, at fixed times after
///      the ticket's valid until, three times at most; what goes out is the copy home sent, byte for byte, through
///      the pair the ticket was pinned to; and every refusal.
contract ValidationResendTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 100;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    bytes internal aliceSat;
    bytes internal bobSat;
    address internal stranger = makeAddr("stranger");
    bytes32 internal id;
    uint64 internal firstAskDueAt;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.prank(agent);
        token.unpause();

        id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
        polygonGateway.drop(0);
        firstAskDueAt = boundCompliance.ticketOf(id).validUntil + POLYGON_WINDOW;
    }

    /* ----- Success ----- */

    /// @notice One waiting time after valid until anyone asks for the receipt: a second queue entry with the first
    ///         one's payload, announced, and the pair pinned at the first send is not pinned again.
    function test_sendTicket_asksForTheReceipt_withTheCopyHomeSent() public {
        vm.warp(firstAskDueAt);
        vm.recordLogs();
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ReceiptAsked(id, 1);
        vm.prank(stranger);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(polygonGateway.queuedMessage(1).payload, polygonGateway.queuedMessage(0).payload);
        assertEq(_pinnedBridgeOf(id), address(polygonGateway));
        _assertNotPinnedAgain();
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(boundCompliance.ticketOf(id).asksForReceipt, 1);
        assertEq(boundCompliance.ticketOf(id).lastSentAt, firstAskDueAt);
    }

    /// @notice The receipt that answers the ask settles the ticket like the original would.
    function test_sendTicket_succeeds_andTheReceiptSettles() public {
        vm.warp(firstAskDueAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 50));
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 50);
        assertEq(token.awayBalanceOf(bobSat), 50);
    }

    /// @notice The asks come at fixed times, one waiting time apart, three at most.
    function test_sendTicket_reverts_afterThreeAsks() public {
        vm.warp(firstAskDueAt);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        vm.warp(firstAskDueAt + POLYGON_WINDOW - 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, firstAskDueAt + POLYGON_WINDOW));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.warp(firstAskDueAt + POLYGON_WINDOW);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        vm.warp(firstAskDueAt + 2 * POLYGON_WINDOW);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.warp(firstAskDueAt + 3 * POLYGON_WINDOW);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoAsksLeft.selector, id));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    /// @notice A spender travels with the object, so it is part of what must be supplied again.
    function test_sendTicket_succeeds_whenTheSpenderIsSuppliedAgain() public {
        bytes memory spender = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        vm.prank(address(aliceIdentity));
        bytes32 withSpender = boundCompliance.askToMove(aliceSat, bobSat, 1, 5, spender, _salt());
        vm.warp(firstAskDueAt);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, withSpender));
        boundCompliance.sendTicket(withSpender, polygon, bobSat, "");

        boundCompliance.sendTicket(withSpender, polygon, bobSat, spender);
        assertEq(_decodeQueuedValidation(polygonGateway, 2).spender, spender);
    }

    /* ----- Refusals ----- */

    function test_sendTicket_reverts_when_theIdWasNeverIssued() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, bytes32(uint256(999))));
        boundCompliance.sendTicket(bytes32(uint256(999)), polygon, bobSat, "");
    }

    function test_sendTicket_reverts_when_theReceiverDiffersFromTheAskedOne() public {
        bytes memory other = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        vm.warp(firstAskDueAt);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, id));
        boundCompliance.sendTicket(id, polygon, other, "");
    }

    function test_sendTicket_reverts_when_theChainIsNotPartOfTheTicket() public {
        vm.warp(firstAskDueAt);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotPartOfValidation.selector, id, optimism));
        boundCompliance.sendTicket(id, optimism, bobSat, "");
    }

    /// @notice Before valid until plus one waiting time an ask could cross the receipt: it is not due.
    function test_sendTicket_reverts_beforeOneWaitingTimeAfterValidUntil() public {
        vm.warp(firstAskDueAt - 1);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, firstAskDueAt));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    function test_sendTicket_reverts_when_alreadySettled() public {
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 50));
        polygonGateway.relay(index);
        vm.warp(firstAskDueAt);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationNotResendable.selector, id, uint8(ITickets.TicketStatus.Done))
        );
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    /// @notice A blocked away chain's receipts wait unapplied; an ask sent now could only add to what cannot be
    ///         applied.
    function test_sendTicket_reverts_when_theAwayChainIsBlocked() public {
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        vm.warp(firstAskDueAt);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        assertEq(polygonGateway.queueLength(), 1);
    }

    /// @notice After a planned peer change the ask goes to the peer the ticket was pinned to, inside the change
    ///         window: the away token that holds the ticket is the one that answers.
    function test_sendTicket_asksThePinnedFormerPeer_afterAPlannedPeerChange() public {
        bytes memory formerPeer = token.peerFor(polygon);
        bytes memory newPeer = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("newPolygonLite"));
        vm.prank(deployer);
        token.setPeer(polygon, newPeer);
        vm.warp(firstAskDueAt);

        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(polygonGateway.queuedMessage(1).recipient, formerPeer, "the pinned peer, not the new one");
    }

    /// @notice A paused token sends nothing out: its report could not land until the unpause anyway.
    function test_sendTicket_reverts_when_theTokenIsPaused() public {
        vm.prank(agent);
        token.pause();
        vm.warp(firstAskDueAt);

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 1, "only the first send went out");
    }

    /// @notice After a planned route change the ask goes through the bridge the ticket was pinned to, inside the
    ///         change window.
    function test_sendTicket_asksThroughThePinnedFormerBridge_afterARouteChange() public {
        ERC7786GatewayMock replacement = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(replacement));
        vm.warp(firstAskDueAt);

        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(replacement.queueLength(), 0);
    }

    function _assertNotPinnedAgain() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.HalfPinned.selector, "the route was pinned again");
        }
    }

}
