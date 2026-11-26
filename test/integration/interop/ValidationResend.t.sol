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

/// @dev A lost validation leg sent again through the real messaging layer: who may, what goes out, that it is the
///      issued leg byte for byte, that it still settles, and every refusal.
contract ValidationResendTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 100;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    bytes internal aliceSat;
    bytes internal bobSat;
    address internal stranger = makeAddr("stranger");
    bytes32 internal id;

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
    }

    /* ----- Success ----- */

    /// @notice The identity resends the lost leg: a second queue entry with the first one's payload, announced,
    ///         and the route pinned at issuance is not pinned again.
    function test_resendValidation_Success_WhenTheIdentityResendsTheLostLeg() public {
        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.TicketSent(id, polygon);
        vm.prank(address(aliceIdentity));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(polygonGateway.queuedMessage(1).payload, polygonGateway.queuedMessage(0).payload);
        assertEq(_pinnedBridgeOf(id), address(polygonGateway));
        _assertNotPinnedAgain();
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    function test_resendValidation_Success_WhenAnAgentResendsForTheWallet() public {
        vm.prank(agent);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(_decodeQueuedValidation(polygonGateway, 1).ticketId, id);
    }

    /// @notice The resent leg is the one the Lite executes against: relayed, it settles like the original would.
    function test_resendValidation_Success_WhenTheResentLegSettles() public {
        vm.prank(address(aliceIdentity));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 50));
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 50);
        assertEq(token.awayBalanceOf(bobSat), 50);
    }

    /// @notice The receiver on the same away chain is left waiting too, so their identity may resend the ticket.
    function test_resendValidation_Success_WhenTheRecipientResendsTheLegTowardTheirChain() public {
        vm.prank(address(bobIdentity));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(polygonGateway.queuedMessage(1).payload, polygonGateway.queuedMessage(0).payload);
    }

    /// @notice A spender travels with the object, so it is part of what must be supplied again.
    function test_resendValidation_Success_WhenTheSpenderIsSuppliedAgain() public {
        bytes memory spender = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        vm.prank(address(aliceIdentity));
        bytes32 withSpender = boundCompliance.askToMove(aliceSat, bobSat, 1, 5, spender, _salt());

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, withSpender));
        boundCompliance.sendTicket(withSpender, polygon, bobSat, "");

        vm.prank(address(aliceIdentity));
        boundCompliance.sendTicket(withSpender, polygon, bobSat, spender);
        assertEq(_decodeQueuedValidation(polygonGateway, 2).spender, spender);
    }

    /* ----- Refusals ----- */

    function test_resendValidation_RevertWhen_IdWasNeverIssued() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, bytes32(uint256(999))));
        boundCompliance.sendTicket(bytes32(uint256(999)), polygon, bobSat, "");
    }

    function test_resendValidation_RevertWhen_TheRecipientDiffersFromTheIssued() public {
        bytes memory other = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, id));
        boundCompliance.sendTicket(id, polygon, other, "");
    }

    function test_resendValidation_RevertWhen_TheChainIsNotPartOfTheValidation() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotPartOfValidation.selector, id, optimism));
        boundCompliance.sendTicket(id, optimism, bobSat, "");
    }

    function test_resendValidation_RevertWhen_AStrangerAsks() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, stranger, aliceSat));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    /// @notice A home receiver's identity waits on no away chain: it may not resend the sender's ticket.
    function test_resendValidation_RevertWhen_TheRecipientAsksForTheSendersLeg() public {
        bytes memory nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);
        bytes32 toHome = _requestValidation(address(aliceIdentity), aliceSat, nativeBob, 1, 5);

        vm.prank(address(bobIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, address(bobIdentity), aliceSat)
        );
        boundCompliance.sendTicket(toHome, polygon, nativeBob, "");
    }

    function test_resendValidation_RevertWhen_PastTheSatelliteDeadline() public {
        uint64 validUntil = boundCompliance.ticketOf(id).validUntil;
        vm.warp(validUntil);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationExpired.selector, id, validUntil));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    function test_resendValidation_RevertWhen_AlreadySettled() public {
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 50));
        polygonGateway.relay(index);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationNotResendable.selector, id, uint8(ITickets.TicketStatus.Done))
        );
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    /// @notice A blocked away chain's receipts wait unapplied; a ticket sent now could only add to what cannot be
    ///         applied.
    function test_resendValidation_RevertWhen_TheChainsInboundIsPaused() public {
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        assertEq(polygonGateway.queueLength(), 1);
    }

    /// @notice The leg's settlement is matched against the peer it was sent to, so it is never resent to another:
    ///         the leg already out keeps settling from the previous peer.
    function test_resendValidation_RevertWhen_ThePeerChanged() public {
        bytes memory newPeer = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("newPolygonLite"));
        vm.prank(deployer);
        token.setPeer(polygon, newPeer);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationAlreadyRouted.selector, id, polygon, address(polygonGateway))
        );
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 1);
    }

    /// @notice A paused token sends nothing out: its report could not land until the unpause anyway. The leg goes
    ///         again once the pause is lifted, see `ValidationTokenPause.t.sol`.
    function test_resendValidation_RevertWhen_TheTokenIsPaused() public {
        vm.prank(agent);
        token.pause();

        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 1, "only the issuance went out");
    }

    /// @notice The leg's settlement is matched against the pinned gateway, so it is never resent through another.
    function test_resendValidation_RevertWhen_TheRouteWasSwitched() public {
        ERC7786GatewayMock replacement = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(replacement));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationAlreadyRouted.selector, id, polygon, address(polygonGateway))
        );
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        assertEq(replacement.queueLength(), 0);
    }

    function _assertNotPinnedAgain() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.HalfPinned.selector, "the route was pinned again");
        }
    }

}
