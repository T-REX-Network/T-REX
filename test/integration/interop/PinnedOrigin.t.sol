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
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A half is pinned to the receipt bridge and the peer it was sent to. Its receipt is taken from that pair or
///      from the current one, so a peer change does not strand it, and closing the receipt route stops it like every
///      other message from that chain.
///      The tickets are sent by the token alone, never written by the compliance, so a receipt that passes the
///      transport reaches `receiveReceipt`, which refuses an id it has no record of: that refusal is what these
///      tests read.
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
        token.dispatchComplianceValidation(satellite, inFlight, abi.encode("validation"));

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
        token.setPeer(satellite, InteroperableAddress.formatEvmV1(POLYGON, newLite));
    }

    /// @dev The receipt got through the transport and reached the compliance, which has no record of the id.
    function _expectHandled(bytes32 ticketId) private {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, ticketId));
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

    function testRedispatchAfterAPeerChangeIsRefused() public {
        _changePeer();

        vm.prank(compliance);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationAlreadyRouted.selector, inFlight, satellite, address(gateway))
        );
        token.dispatchComplianceValidation(satellite, inFlight, abi.encode("validation"));
    }

    function testAnUnpinnedSettlementFollowsTheCurrentPeer() public {
        _changePeer();
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
