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

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A half is pinned to the receipt bridge and the peer it was sent to. Its receipt is taken from that pair or
///      from the current one, so a peer change does not strand it, and closing the receipt route stops it like every
///      other message from that chain.
///      The tickets are sent by the token alone, never written by the compliance, so a receipt that passes the
///      transport reaches `receiveReceipt`, which announces it whatever becomes of it: that announcement is what
///      these tests read.
contract PinnedOriginTest is InteropSuiteTest {

    ERC7786GatewayMock gateway;
    address compliance;
    address newLite = makeAddr("newLite");

    bytes32 satellite = polygon;
    bytes32 inFlight = bytes32(uint256(1));
    bytes32 neverDispatched = bytes32(uint256(99));
    uint256 amount = 100;

    function setUp() public override {
        super.setUp();

        gateway = _newReceiptBridge(POLYGON);
        compliance = address(token.compliance());
        _openEvmChain(token, POLYGON, address(gateway));

        vm.prank(compliance);
        token.sendOnTicketRoute(satellite, inFlight, abi.encode("validation"));

        vm.prank(agent);
        token.unpause();
    }

    function _settlementFrom(address author, bytes32 ticketId) private returns (uint256) {
        return _queue(
            gateway, author, token, MessageTypesLib.encodeSettlement(_sameChainSettlement(ticketId, POLYGON, amount))
        );
    }

    function _changePeer() private {
        vm.prank(deployer);
        token.setPeer(satellite, InteroperableAddress.formatEvmV1(POLYGON, newLite), false);
    }

    /// @dev The receipt got through the transport and reached the compliance, which announces it.
    function _expectHandled(bytes32 ticketId) private {
        MessageTypesLib.ReceiptMessage memory receipt = _sameChainSettlement(ticketId, POLYGON, amount);
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReceiptReceived(satellite, ticketId, receipt.from, receipt.to, receipt.amount);
    }

    function _expectNotPeer(address author) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector, satellite, InteroperableAddress.formatEvmV1(POLYGON, author)
            )
        );
    }

    /* ----- A peer change ----- */

    function testThePreviousPeerStillSettlesWhatItWasSent() public {
        uint256 index = _settlementFrom(address(token), inFlight);
        _changePeer();

        _expectHandled(inFlight);
        gateway.relay(index);
    }

    function test_receiveMessage_acceptsAReceiptFromTheCurrentPeer_whenTheHalfIsPinnedToThePreviousOne() public {
        _changePeer();
        uint256 index = _settlementFrom(newLite, inFlight);

        _expectHandled(inFlight);
        gateway.relay(index);
    }

    /// @dev A peer that is neither the pinned one nor the current one is refused.
    function testAPeerThatIsNeitherPinnedNorCurrentIsRefused() public {
        _changePeer();
        address strangerLite = makeAddr("strangerLite");
        uint256 index = _settlementFrom(strangerLite, inFlight);

        _expectNotPeer(strangerLite);
        gateway.relay(index);
    }

    /// @dev Inside the change window an ask goes to the peer the ticket was pinned to, the former one: the away token
    ///      that holds it is the one that answers.
    function testRedispatchAfterAPeerChangeGoesToThePinnedFormerPeer() public {
        _changePeer();

        vm.prank(compliance);
        token.sendOnTicketRoute(satellite, inFlight, abi.encode("validation"));

        uint256 last = gateway.queueLength() - 1;
        assertEq(gateway.queuedMessage(last).recipient, InteroperableAddress.formatEvmV1(POLYGON, address(token)));
    }

    /// @dev Once the change window is over, a half never sent follows the current peer only.
    function testAnUnpinnedSettlementFollowsTheCurrentPeer() public {
        _changePeer();
        vm.warp(block.timestamp + 4 * POLYGON_WINDOW);
        uint256 fromPrevious = _settlementFrom(address(token), neverDispatched);
        uint256 fromCurrent = _settlementFrom(newLite, neverDispatched);

        _expectNotPeer(address(token));
        gateway.relay(fromPrevious);

        _expectHandled(neverDispatched);
        gateway.relay(fromCurrent);
    }

    /* ----- Closing the chain ----- */

    function testAClosedChainRefusesAPinnedSettlement() public {
        uint256 index = _settlementFrom(address(token), inFlight);
        _closeEvmChain(token, POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, satellite));
        gateway.relay(index);
    }

    function testReopeningTheChainLetsThePinnedSettlementLand() public {
        uint256 index = _settlementFrom(address(token), inFlight);
        _closeEvmChain(token, POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, satellite));
        gateway.relay(index);

        _openEvmChain(token, POLYGON, address(gateway));
        _expectHandled(inFlight);
        gateway.relay(index);
    }

}
