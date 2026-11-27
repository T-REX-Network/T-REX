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

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TicketsHarness } from "test/integration/helpers/TicketsHarness.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The cancel against a real suite: the status over time, the cancel releasing a counter module once an ask for
///      the receipt went unanswered, the re-issuance it enables, and every refusal, including one whose receipt waits.
contract ValidationDiscardTest is InteropSuiteTest {

    uint256 internal constant CAP = 100;
    uint256 internal constant BALANCE = 1000;

    bytes internal aliceSat;
    bytes internal bobSat;
    CappedRecipientModule internal cappedRule;
    uint256 internal issuedAt;
    bytes32 internal id;
    ERC7786GatewayMock internal polygonBridge;

    function setUp() public override {
        super.setUp();
        // Running: a paused token refuses every request (TokenPaused).
        vm.prank(agent);
        token.unpause();
        polygonBridge = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(polygonBridge));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(cappedRule));
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (CAP)), address(cappedRule));
        vm.stopPrank();

        issuedAt = block.timestamp;
        id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, CAP);
    }

    function _deployImplementations() internal override {
        super._deployImplementations();
        modularComplianceImplementation = ModularCompliance(address(new TicketsHarness()));
    }

    // ==== .statusOf Tests ====

    /// @notice A ticket stays `Open` past its deadlines until something moves it: the clock moves nothing.
    function test_statusOf_Success_WhenTheClockMovesPastTheDeadlines() public {
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        vm.warp(issuedAt + VALIDITY_WINDOW + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    // ==== .cancelTickets Tests ====

    /// @notice Once an ask for the receipt went unanswered for one waiting time, anyone cancels: the counter is
    ///         released, the id marked and announced, and the cap is available again.
    function test_cancelTickets_succeeds_afterAnUnansweredAsk_andTheCapIsFreeAgain() public {
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
        _askAndLetTheAskGoUnanswered(id, bobSat, "");

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketCancelled(id);
        vm.prank(makeAddr("stranger"));
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 0);

        bytes32 next = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, CAP);
        assertEq(boundCompliance.ticketOf(next).amountMax, CAP);
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
    }

    /// @notice Nobody cancels on silence alone, however late: a cancel needs an ask for the receipt that went
    ///         unanswered, and is told when the earliest one could come.
    function test_cancelTickets_reverts_when_noAskForTheReceiptWentUnanswered() public {
        uint64 earliestCancel = uint64(issuedAt) + VALIDITY_WINDOW + 2 * POLYGON_WINDOW;
        vm.warp(earliestCancel + 1);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, earliestCancel));
        boundCompliance.cancelTickets(_ids(id));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, earliestCancel));
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
    }

    /// @notice A batch is judged id by id: one with no unanswered ask refuses the whole call, and nothing is
    ///         released.
    function test_cancelTickets_reverts_when_oneIdOfTheBatchWasNeverAsked() public {
        bytes memory charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        bytes32 later = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 10, CAP);
        uint64 laterValidUntil = boundCompliance.ticketOf(later).validUntil;
        _askAndLetTheAskGoUnanswered(id, bobSat, "");

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id;
        ids[1] = later;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, later, laterValidUntil + 2 * POLYGON_WINDOW)
        );
        boundCompliance.cancelTickets(ids);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
    }

    /// @notice The answer to an ask may land in the last second of its waiting time, so the cancel comes after.
    function test_cancelTickets_reverts_when_theAskIsStillInsideItsWaitingTime() public {
        uint64 askedAt = uint64(issuedAt) + VALIDITY_WINDOW + POLYGON_WINDOW;
        vm.warp(askedAt);
        boundCompliance.sendTicket(id, bobSat, "");

        vm.warp(askedAt + POLYGON_WINDOW);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, askedAt + POLYGON_WINDOW));
        boundCompliance.cancelTickets(_ids(id));
    }

    /// @notice A blocked away chain's receipt waits at home and may answer the ticket, so the cancel waits for the
    ///         pauser. Once the block is lifted, the cancel is refused while that receipt can be applied: whoever
    ///         wants the ticket to move on applies it first, and the cancel never wins the race.
    function test_cancelTickets_reverts_when_theAwayChainIsBlocked_thenWhileItsReceiptWaits() public {
        uint64 askedAt = uint64(issuedAt) + VALIDITY_WINDOW + POLYGON_WINDOW;
        vm.warp(askedAt);
        boundCompliance.sendTicket(id, bobSat, "");
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(id, aliceSat, bobSat, 40);
        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));
        vm.warp(askedAt + POLYGON_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.cancelTickets(_ids(id));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, id, polygon));
        boundCompliance.cancelTickets(_ids(id));

        boundCompliance.applyWaitingReceipt(id, receipt);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 40);
    }

    /// @notice An already cancelled id and an unknown id are refused by name.
    function test_cancelTickets_reverts_when_alreadyCancelledOrUnknown() public {
        _cancelUnanswered(id, bobSat, "");

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.Cancelled))
        );
        boundCompliance.cancelTickets(_ids(id));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, bytes32(uint256(999))));
        boundCompliance.cancelTickets(_ids(bytes32(uint256(999))));
    }

    /// @notice A ticket its receipt ended is done: no clock makes it cancellable.
    function test_cancelTickets_reverts_when_theTicketIsDone() public {
        ERC7786GatewayMock polygonGateway = ERC7786GatewayMock(token.receiptRouteFor(polygon));
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, CAP)));
        vm.warp(issuedAt + 100 * VALIDITY_WINDOW);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.Done))
        );
        boundCompliance.cancelTickets(_ids(id));
        assertEq(token.awayBalanceOf(bobSat), CAP, "the receipt stands");
    }

    /// @notice While the receipt route is closed the ticket's receipt cannot land, so the ticket is not cancelled:
    ///         the away token may have executed it already. Close by hand stays the way out.
    function test_cancelTickets_RevertWhen_TheReceiptRouteIsClosed() public {
        _askAndLetTheAskGoUnanswered(id, bobSat, "");
        _closeEvmChain(token, POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.ticketOf(id).status), uint8(ITickets.TicketStatus.Open), "still open");
    }

    /// @notice The same when the receipt bridge is distrusted: nothing can deliver the receipt meanwhile.
    function test_cancelTickets_RevertWhen_TheReceiptBridgeIsDistrusted() public {
        _askAndLetTheAskGoUnanswered(id, bobSat, "");
        trustedGatewayRegistry.setTrustedGateway(token.receiptRouteFor(polygon), false, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.ticketOf(id).status), uint8(ITickets.TicketStatus.Open), "still open");
    }

    function _ids(bytes32 one) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = one;
    }

}
