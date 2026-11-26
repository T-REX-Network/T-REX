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

import { IReceiptHandler } from "contracts/interop/IReceiptHandler.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Each half is pinned to the receipt route and the peer it left through. An issuer changing an away chain's
///      receipt bridge sends new tickets through the new one; a receipt for a half already in flight is taken from
///      its pinned pair or from the current one, so the change never strands it.
///      The validations here are dispatched by the token alone, never issued by the compliance, so every leg
///      that passes the transport is parked by the compliance under its id and pauses the satellite's inbound,
///      the token itself staying open: the transport verdict is what these tests read, and the parking is
///      asserted where a leg gets through.
contract RouteSwitchTest is InteropSuiteTest {

    ERC7786GatewayMock oldGateway;
    ERC7786GatewayMock newGateway;

    address compliance;

    bytes32 satellite = polygon;

    bytes32 inFlight = bytes32(uint256(1));
    bytes32 issuedAfterSwitch = bytes32(uint256(2));
    bytes32 neverDispatched = bytes32(uint256(99));
    uint256 amount = 100;

    bytes validationBody = abi.encode("validation");

    function setUp() public override {
        super.setUp();

        oldGateway = _newReceiptBridge(POLYGON);
        newGateway = _newReceiptBridge(POLYGON);
        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(oldGateway));
        _dispatch(inFlight);

        // The switch: from here on the issuer's traffic goes through the new gateway.
        _openEvmChain(token, POLYGON, address(newGateway));

        vm.prank(agent);
        token.unpause();
    }

    function _dispatch(bytes32 ticketId) private {
        vm.prank(compliance);
        token.dispatchComplianceValidation(satellite, ticketId, validationBody);
    }

    function _settlementFrom(ERC7786GatewayMock gateway, bytes32 ticketId) private returns (uint256) {
        return
            _liteSends(
                gateway, token, MessageTypesLib.encodeSettlement(_sameChainSettlement(ticketId, POLYGON, amount))
            );
    }

    function _expectHandled(bytes32 ticketId) private {
        vm.expectCall(
            compliance,
            abi.encodeCall(IReceiptHandler.receiveReceipt, (satellite, _sameChainSettlement(ticketId, POLYGON, amount)))
        );
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptWaiting(ticketId, satellite, amount, bytes32(0));
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(satellite);
    }

    /// @dev A leg that got through: parked under its id, its chain's inbound paused, the token itself open.
    function _assertParked(ERC7786GatewayMock gateway, uint256 index, bytes32 ticketId) private view {
        assertTrue(token.messageReceived(address(gateway), gateway.receiveIdFor(index)), "consumed");
        assertTrue(boundCompliance.waitingReceiptOf(ticketId, satellite).exists, "parked");
        assertTrue(token.isInboundPaused(satellite), "never issued by the compliance: the chain's inbound pauses");
        assertFalse(token.paused(), "the token itself stays open");
    }

    function _expectNotOnRoute(ERC7786GatewayMock gateway) private {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(gateway), satellite));
    }

    /* ----- The old leg ----- */

    function testTheSwitchIsInPlace() public view {
        assertEq(token.receiptRouteFor(satellite), address(newGateway));
        assertEq(_pinnedBridgeOf(inFlight, satellite), address(oldGateway));
    }

    function testOldLegIsAcceptedFromThePinnedGatewayAfterTheSwitch() public {
        uint256 index = _settlementFrom(oldGateway, inFlight);

        _expectHandled(inFlight);
        oldGateway.relay(index);

        _assertParked(oldGateway, index, inFlight);
    }

    function test_receiveMessage_acceptsAReceiptOnTheCurrentRoute_whenTheHalfIsPinnedToTheOldOne() public {
        uint256 index = _settlementFrom(newGateway, inFlight);

        _expectHandled(inFlight);
        newGateway.relay(index);

        _assertParked(newGateway, index, inFlight);
    }

    /// @dev Cross-chain: the second leg of the same ticket, from the same chain, is taken from the pinned or the
    ///      current route alike. Both pass the route check and reach the inbound pause the first leg's parking raised.
    function testEveryLegOfTheOldTicketIsTakenFromThePinnedOrTheCurrentRoute() public {
        uint256 burnLeg = _liteSends(
            oldGateway,
            token,
            MessageTypesLib.encodeSettlement(
                _settlement(inFlight, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("From")), "", amount)
            )
        );
        uint256 replayOnNewRoute = _settlementFrom(newGateway, inFlight);

        vm.expectCall(compliance, abi.encodeWithSelector(IReceiptHandler.receiveReceipt.selector), 1);
        oldGateway.relay(burnLeg);
        _assertParked(oldGateway, burnLeg, inFlight);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, satellite));
        newGateway.relay(replayOnNewRoute);
    }

    /* ----- The new validation ----- */

    function testNewValidationGoesOutThroughTheNewRouteAndPinsIt() public {
        _dispatch(issuedAfterSwitch);

        assertEq(oldGateway.queueLength(), 1, "only the in-flight one went through the old gateway");
        assertEq(newGateway.queueLength(), 1);
        assertEq(_pinnedBridgeOf(issuedAfterSwitch, satellite), address(newGateway));
    }

    function testNewValidationSettlesThroughTheNewRouteOnly() public {
        _dispatch(issuedAfterSwitch);

        uint256 viaOld = _settlementFrom(oldGateway, issuedAfterSwitch);
        uint256 viaNew = _settlementFrom(newGateway, issuedAfterSwitch);

        _expectNotOnRoute(oldGateway);
        oldGateway.relay(viaOld);

        _expectHandled(issuedAfterSwitch);
        newGateway.relay(viaNew);
        _assertParked(newGateway, viaNew, issuedAfterSwitch);
    }

    /* ----- What was never pinned follows the current route ----- */

    /// @dev An id this token never dispatched is not refused by transport: the compliance must see it to park
    ///      the leg and pause the chain. It follows the current route, like any unpinned message.
    function testUnpinnedSettlementFollowsTheCurrentRoute() public {
        uint256 viaOld = _settlementFrom(oldGateway, neverDispatched);
        uint256 viaNew = _settlementFrom(newGateway, neverDispatched);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(oldGateway), satellite));
        oldGateway.relay(viaOld);

        _expectHandled(neverDispatched);
        newGateway.relay(viaNew);
        _assertParked(newGateway, viaNew, neverDispatched);
    }

    /// @dev A recall carries no validation, so it checks against the current route: old gateway refused.
    function testBurnProofFollowsTheCurrentRoute() public {
        bytes memory payload =
            MessageTypesLib.encodeBurnProof(_burnProof(1, _satelliteEnvelope(POLYGON, makeAddr("Burned")), amount));

        uint256 viaOld = _liteSends(oldGateway, token, payload);
        uint256 viaNew = _liteSends(newGateway, token, payload);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(oldGateway), satellite));
        oldGateway.relay(viaOld);

        newGateway.relay(viaNew);
        assertTrue(token.messageReceived(address(newGateway), newGateway.receiveIdFor(viaNew)));
    }

    /* ----- Emergency removal of the pinned gateway ----- */

    /// @dev Distrust reaches pinned routes too: nothing arrives through the old bridge any more, and the old half's
    ///      receipt lands through the current route instead.
    function testDistrustingThePinnedBridgeLetsTheOldHalfLandOnTheCurrentRoute() public {
        uint256 viaOld = _settlementFrom(oldGateway, inFlight);
        uint256 viaNew = _settlementFrom(newGateway, inFlight);

        trustedGatewayRegistry.distrustBridge(address(oldGateway));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(oldGateway),
                InteroperableAddress.formatEvmV1(POLYGON, address(token))
            )
        );
        oldGateway.relay(viaOld);

        _expectHandled(inFlight);
        newGateway.relay(viaNew);
        _assertParked(newGateway, viaNew, inFlight);

        assertEq(_pinnedBridgeOf(inFlight, satellite), address(oldGateway), "the pin is a record, not a lever");
    }

}
