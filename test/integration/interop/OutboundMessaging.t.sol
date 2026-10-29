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

    uint256 validationId = 1;
    bytes validationBody = abi.encode(uint256(1), "validation");

    bytes aliceSat;

    function setUp() public override {
        super.setUp();

        gateway = _newTrustedGateway(POLYGON);
        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(gateway));

        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOnPolygon"));
        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();
    }

    /// @dev Alice delegates `amount` of her own balance to her Polygon wallet: the one way a mint instruction leaves.
    function _delegate(uint256 amount) private returns (bytes32) {
        vm.prank(alice);
        return token.delegateOut(alice, aliceSat, amount);
    }

    /// @dev The agent orders `amount` of Alice's Polygon wallet back: the one way a recall instruction leaves.
    function _instruct(uint256 amount) private returns (uint256) {
        vm.prank(agent);
        return token.instructRecall(aliceSat, amount, alice);
    }

    function _dispatch(uint256 id, bytes32 chainKey) private returns (bytes32) {
        vm.prank(compliance);
        return token.dispatchComplianceValidation(chainKey, id, validationBody);
    }

    /* ----- Happy path ----- */

    /// @dev The peer is the token's own address on the satellite, not on the reference chain.
    function testComplianceDispatchesAValidationToItsLiteOnTheSatellite() public {
        _dispatch(validationId, satellite);

        assertEq(gateway.queueLength(), 1);
        assertEq(gateway.queuedMessage(0).recipient, token.peerFor(satellite));
        assertEq(gateway.queuedMessage(0).recipient, InteroperableAddress.formatEvmV1(POLYGON, address(token)));
    }

    function testDispatchedPayloadDecodesBackToWhatWasSent() public {
        _dispatch(validationId, satellite);

        (uint8 messageType, uint8 version, bytes memory body) =
            abi.decode(gateway.queuedMessage(0).payload, (uint8, uint8, bytes));

        assertEq(messageType, uint8(MessageTypesLib.Message.COMPLIANCE_VALIDATION));
        assertEq(version, MessageTypesLib.VERSION);
        assertEq(body, validationBody);
    }

    function testEverySendAnnouncesItsTypeChainAndSendId() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(
            MessageTypesLib.Message.COMPLIANCE_VALIDATION, satellite, gateway.receiveIdFor(0)
        );

        _dispatch(validationId, satellite);
    }

    function testBothTypesQueueSeparately() public {
        _dispatch(validationId, satellite);
        _delegate(10);

        assertEq(gateway.queueLength(), 2);
    }

    /* ----- Route snapshot ----- */

    function testDispatchPinsTheRouteForTheValidation() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ValidationRoutePinned(validationId, satellite, address(gateway));

        _dispatch(validationId, satellite);

        assertEq(token.pinnedRouteFor(validationId, satellite), address(gateway));
    }

    /// @dev A lost message may be re-sent: same validation, same chain, same gateway.
    function testRedispatchThroughThePinnedGatewayIsAllowed() public {
        _dispatch(validationId, satellite);
        _dispatch(validationId, satellite);

        assertEq(gateway.queueLength(), 2);
        assertEq(token.pinnedRouteFor(validationId, satellite), address(gateway));
    }

    /// @dev Its legs could never be accepted through the new gateway, so the re-dispatch says so now.
    function testRedispatchThroughAnotherGatewayIsRefused() public {
        _dispatch(validationId, satellite);

        ERC7786GatewayMock other = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(other));

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationAlreadyRouted.selector, validationId, satellite, address(gateway)
            )
        );
        _dispatch(validationId, satellite);

        assertEq(other.queueLength(), 0);
    }

    /// @dev One validation, two chains: each leg pins the route it took, independently.
    function testACrossChainValidationPinsOneRoutePerChain() public {
        ERC7786GatewayMock optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        _dispatch(validationId, satellite);
        _dispatch(validationId, optimism);

        assertEq(token.pinnedRouteFor(validationId, satellite), address(gateway));
        assertEq(token.pinnedRouteFor(validationId, optimism), address(optimismGateway));
        assertEq(gateway.queueLength(), 1);
        assertEq(optimismGateway.queueLength(), 1);
    }

    /* ----- Mint instruction: one per delegation ----- */

    function testADelegationOutSendsAMintInstructionAndItIsAnnounced() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(MessageTypesLib.Message.MINT_INSTRUCTION, satellite, gateway.receiveIdFor(0));

        bytes32 sendId = _delegate(10);

        assertEq(gateway.queueLength(), 1);
        assertEq(sendId, gateway.receiveIdFor(0));

        (uint8 messageType,, bytes memory body) = abi.decode(gateway.queuedMessage(0).payload, (uint8, uint8, bytes));
        assertEq(messageType, uint8(MessageTypesLib.Message.MINT_INSTRUCTION));
        MessageTypesLib.MintInstruction memory instruction = MessageTypesLib.decodeMintInstruction(body);
        assertEq(instruction.delegationId, 1);
        assertEq(instruction.toWallet, aliceSat);
        assertEq(instruction.amount, 10);
        assertEq(instruction.holder, alice);
    }

    /// @dev A mint instruction pins no route: its validation-free resend goes through the current one.
    function testAMintInstructionPinsNothing() public {
        _delegate(10);
        _delegate(10);

        assertEq(gateway.queueLength(), 2);
        assertEq(token.pinnedRouteFor(1, satellite), address(0));
        assertEq(token.pinnedRouteFor(2, satellite), address(0));
    }

    /* ----- Recall instruction: an order out, a proof back ----- */

    function testARecallInstructionIsAnnouncedAndRecorded() public {
        _delegate(100);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(
            MessageTypesLib.Message.RECALL_INSTRUCTION, satellite, gateway.receiveIdFor(1)
        );

        uint256 recallId = _instruct(40);

        assertEq(recallId, 1);
        assertEq(gateway.queueLength(), 2);

        (uint8 messageType,, bytes memory body) = abi.decode(gateway.queuedMessage(1).payload, (uint8, uint8, bytes));
        assertEq(messageType, uint8(MessageTypesLib.Message.RECALL_INSTRUCTION));
        MessageTypesLib.RecallInstruction memory instruction = MessageTypesLib.decodeRecallInstruction(body);
        assertEq(instruction.recallId, 1);
        assertEq(instruction.wallet, aliceSat);
        assertEq(instruction.amount, 40);
        assertEq(instruction.nativeWallet, alice);

        assertEq(token.pendingRecall(1).amount, 40);
        assertEq(token.pendingRecall(1).gateway, address(gateway), "the dispatch gateway is recorded");
        assertEq(token.pendingRecall(1).peerKey, keccak256(token.peerFor(satellite)), "and the dispatch peer");
    }

    /// @dev The order changes nothing on the ledger: the position only moves when the answering proof arrives.
    function testARecallInstructionMovesNothing() public {
        _delegate(100);
        _instruct(40);

        assertEq(token.bridgedBalanceOf(aliceSat), 100);
        assertEq(token.balanceOf(alice), 900);
    }

    /* ----- Fail closed ----- */

    function testDispatchRevertsOnAChainThatWasNeverOpened() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, closedChain));
        _dispatch(validationId, closedChain);

        assertEq(gateway.queueLength(), 0);
    }

    /// @dev Routed, but with no address to send to: a non-EVM chain has no CREATE3 default.
    function testDispatchRevertsOnARoutedChainWithNoPeer() public {
        vm.prank(deployer);
        token.setRoute(bytes2(0x0002), hex"01", address(gateway));

        assertEq(token.peerFor(solana), "");
        assertFalse(token.isChainOpen(solana));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, solana));
        _dispatch(validationId, solana);

        vm.prank(deployer);
        token.setPeer(solana, hex"0001000201010401020304");

        _dispatch(validationId, solana);
        assertEq(gateway.queuedMessage(0).recipient, hex"0001000201010401020304");
    }

    function testDispatchRevertsForAnUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotCompliance.selector, alice));
        vm.prank(alice);
        token.dispatchComplianceValidation(satellite, validationId, validationBody);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        vm.prank(bob);
        token.delegateOut(alice, aliceSat, 1);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        token.instructRecall(aliceSat, 1, alice);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        token.resend(0, 1, "");

        assertEq(gateway.queueLength(), 0);
    }

    /// @dev The agent issues instructions, never a validation: the body and the id it travels under are
    ///      the compliance's to author, and no role reaches past that.
    function testAgentCannotDispatchAValidationEvenThoughItDispatchesInstructions() public {
        _delegate(100);
        _instruct(40);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotCompliance.selector, agent));
        vm.prank(agent);
        token.dispatchComplianceValidation(satellite, validationId, validationBody);

        assertEq(gateway.queueLength(), 2);
        assertEq(token.pinnedRouteFor(validationId, satellite), address(0));
    }

    /// @dev The emergency lever, proven end to end: removal stops traffic with no call on the token.
    function testRemovingTheGatewayStopsTrafficWithNoConfigChange() public {
        _dispatch(validationId, satellite);
        assertEq(gateway.queueLength(), 1);

        trustedGatewayRegistry.setTrustedGateway(address(gateway), false);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, satellite));
        _dispatch(2, satellite);

        assertEq(gateway.queueLength(), 1, "nothing new was queued");
        assertEq(token.routeFor(satellite), address(gateway), "the route is untouched, trust is what moved");
    }

}
