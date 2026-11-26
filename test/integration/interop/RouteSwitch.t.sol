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

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Each half is pinned to the receipt route and the peer it left through. An issuer changing an away chain's
///      receipt bridge sends new tickets through the new one; a receipt for a half already in flight is taken from
///      its pinned pair or from the current one, so the change never strands it.
///      The tickets here are sent by the token alone, never written by the compliance, so every receipt that passes
///      the transport reaches the compliance, which refuses an id it has no record of: the delivery reverts with
///      `UnknownTicket` and stays deliverable, nothing is blocked. The transport verdict is what these tests read.
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
        token.sendOnTicketRoute(satellite, ticketId, validationBody);
    }

    function _settlementFrom(ERC7786GatewayMock gateway, bytes32 ticketId) private returns (uint256) {
        return
            _liteSends(
                gateway, token, MessageTypesLib.encodeSettlement(_sameChainSettlement(ticketId, POLYGON, amount))
            );
    }

    /// @dev The receipt got through the transport and reached the compliance, which has no record of the id.
    function _expectHandled(bytes32 ticketId) private {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, ticketId));
    }

    /// @dev A receipt the compliance refused for an unknown id: left deliverable, nothing blocked, the token open.
    function _assertLeftDeliverable(ERC7786GatewayMock gateway, uint256 index) private view {
        assertFalse(token.messageReceived(address(gateway), gateway.receiveIdFor(index)), "still deliverable");
        assertFalse(boundCompliance.isAwayChainBlocked(satellite), "an unknown id blocks nobody");
        assertFalse(token.paused(), "the token itself stays open");
    }

    function _expectNotOnRoute(ERC7786GatewayMock gateway) private {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(gateway), satellite));
    }

    /* ----- The old leg ----- */

    function testTheSwitchIsInPlace() public view {
        assertEq(token.receiptRouteFor(satellite), address(newGateway));
        assertEq(_pinnedBridgeOf(inFlight), address(oldGateway));
    }

    function testOldLegIsAcceptedFromThePinnedGatewayAfterTheSwitch() public {
        uint256 index = _settlementFrom(oldGateway, inFlight);

        _expectHandled(inFlight);
        oldGateway.relay(index);

        _assertLeftDeliverable(oldGateway, index);
    }

    function test_receiveMessage_acceptsAReceiptOnTheCurrentRoute_whenTheHalfIsPinnedToTheOldOne() public {
        uint256 index = _settlementFrom(newGateway, inFlight);

        _expectHandled(inFlight);
        newGateway.relay(index);

        _assertLeftDeliverable(newGateway, index);
    }

    /// @dev The receipt of the old ticket is taken from the pinned or the current route alike: both reach the
    ///      compliance.
    function testEveryLegOfTheOldTicketIsTakenFromThePinnedOrTheCurrentRoute() public {
        uint256 viaOld = _settlementFrom(oldGateway, inFlight);
        uint256 viaNew = _settlementFrom(newGateway, inFlight);

        _expectHandled(inFlight);
        oldGateway.relay(viaOld);

        _expectHandled(inFlight);
        newGateway.relay(viaNew);
    }

    /* ----- The new validation ----- */

    function testNewValidationGoesOutThroughTheNewRouteAndPinsIt() public {
        _dispatch(issuedAfterSwitch);

        assertEq(oldGateway.queueLength(), 1, "only the in-flight one went through the old gateway");
        assertEq(newGateway.queueLength(), 1);
        assertEq(_pinnedBridgeOf(issuedAfterSwitch), address(newGateway));
    }

    function testNewValidationSettlesThroughTheNewRouteOnly() public {
        _dispatch(issuedAfterSwitch);

        uint256 viaOld = _settlementFrom(oldGateway, issuedAfterSwitch);
        uint256 viaNew = _settlementFrom(newGateway, issuedAfterSwitch);

        _expectNotOnRoute(oldGateway);
        oldGateway.relay(viaOld);

        _expectHandled(issuedAfterSwitch);
        newGateway.relay(viaNew);
        _assertLeftDeliverable(newGateway, viaNew);
    }

    /* ----- What was never pinned follows the current route ----- */

    /// @dev An id this token never sent is not refused by transport: the compliance must see it. It follows the
    ///      current route, like any unpinned message.
    function testUnpinnedSettlementFollowsTheCurrentRoute() public {
        uint256 viaOld = _settlementFrom(oldGateway, neverDispatched);
        uint256 viaNew = _settlementFrom(newGateway, neverDispatched);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(oldGateway), satellite));
        oldGateway.relay(viaOld);

        _expectHandled(neverDispatched);
        newGateway.relay(viaNew);
        _assertLeftDeliverable(newGateway, viaNew);
    }

    /// @dev A recall carries no validation, so it checks against the current route: old gateway refused.
    function testBurnProofFollowsTheCurrentRoute() public {
        bytes memory payload =
            MessageTypesLib.encodeBurnProof(_burnProof(1, _satelliteEnvelope(POLYGON, makeAddr("Burned")), amount));

        uint256 viaOld = _liteSends(oldGateway, token, payload);
        uint256 viaNew = _liteSends(newGateway, token, payload);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotOnRoute.selector, address(oldGateway), satellite));
        oldGateway.relay(viaOld);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallNotPending.selector, 1));
        newGateway.relay(viaNew);
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
        _assertLeftDeliverable(newGateway, viaNew);

        assertEq(_pinnedBridgeOf(inFlight), address(oldGateway), "the pin is a record, not a lever");
    }

}
