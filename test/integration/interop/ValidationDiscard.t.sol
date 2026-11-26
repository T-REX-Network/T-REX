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
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TicketsHarness } from "test/integration/helpers/TicketsHarness.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The keeper against a real suite: the derived status over time, the discard releasing a counter module,
///      the re-issuance it enables, and every refusal, including one still awaiting its mint leg.
contract ValidationDiscardTest is InteropSuiteTest {

    uint256 internal constant CAP = 100;
    uint256 internal constant BALANCE = 1000;

    bytes internal aliceSat;
    bytes internal bobSat;
    CappedRecipientModule internal cappedRule;
    uint256 internal issuedAt;
    bytes32 internal id;

    function setUp() public override {
        super.setUp();
        // Running: a paused token refuses every request (TokenPaused).
        vm.prank(agent);
        token.unpause();
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
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

    /// @notice Open until the release deadline passes, Expired after it, stored Open throughout.
    function test_statusOf_Success_WhenTheClockMovesPastTheDeadlines() public {
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        vm.warp(issuedAt + VALIDITY_WINDOW + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Expired));
        assertEq(uint8(boundCompliance.ticketOf(id).status), uint8(ITickets.TicketStatus.Open));
    }

    // ==== .cancelTickets Tests ====

    /// @notice The keeper releases the counter, marks the id, announces it, and the cap is available again.
    function test_discardExpiredValidations_Success_WhenExpiredAndReissued() public {
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketCancelled(id);
        vm.prank(keeper);
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 0);

        bytes32 next = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, CAP);
        assertEq(boundCompliance.ticketOf(next).amountMax, CAP);
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
    }

    /// @notice Between the windows the keeper alone may discard: an agent, a manager or a stranger is told when
    ///         it opens to them.
    function test_discardExpiredValidations_RevertWhen_NonKeeperBeforeTheSecondWindow() public {
        uint64 publicAt = uint64(issuedAt + VALIDITY_WINDOW + 2 * POLYGON_WINDOW);
        vm.warp(publicAt);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotPubliclyDiscardable.selector, id, publicAt));
        boundCompliance.cancelTickets(_ids(id));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotPubliclyDiscardable.selector, id, publicAt));
        boundCompliance.cancelTickets(_ids(id));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotPubliclyDiscardable.selector, id, publicAt));
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Expired));
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
    }

    /// @notice Past the second window a stranger releases the reservation the keeper never did.
    function test_discardExpiredValidations_Success_WhenAnyoneAfterTheSecondWindow() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + 2 * POLYGON_WINDOW + 1);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketCancelled(id);
        vm.prank(makeAddr("stranger"));
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 0);
    }

    /// @notice A stranger's batch is judged id by id: one still inside the keeper's window refuses the whole call,
    ///         and the keeper's batch of the same ids goes through.
    function test_discardExpiredValidations_RevertWhen_NonKeeperBatchHasOneIdInsideTheKeeperWindow() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        bytes memory charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        bytes32 later = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 10, CAP);
        uint64 laterPublicAt = uint64(block.timestamp + VALIDITY_WINDOW + 2 * POLYGON_WINDOW);
        vm.warp(laterPublicAt);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id;
        ids[1] = later;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationNotPubliclyDiscardable.selector, later, laterPublicAt)
        );
        boundCompliance.cancelTickets(ids);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Expired));

        vm.prank(keeper);
        boundCompliance.cancelTickets(ids);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(uint8(boundCompliance.statusOf(later)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice A validation still inside its reconciliation window is refused.
    function test_discardExpiredValidations_RevertWhen_NotYetReleasable() public {
        uint64 waitingEndsAt = uint64(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW);
        vm.warp(waitingEndsAt);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, waitingEndsAt));
        boundCompliance.cancelTickets(_ids(id));
    }

    /// @notice A chain whose inbound is paused may hold the report that settles the validation at its gateway;
    ///         the discard waits for the pauser.
    function test_discardExpiredValidations_RevertWhen_TheChainsInboundIsPaused_ThenDiscardsOnceLifted() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        vm.prank(agent);
        token.setInboundPaused(polygon, true);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.cancelTickets(_ids(id));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Expired));

        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        vm.prank(keeper);
        boundCompliance.cancelTickets(_ids(id));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice One refused id reverts the whole batch and releases nothing.
    function test_discardExpiredValidations_RevertWhen_OneIdOfTheBatchIsPending() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        // A second validation toward bob is impossible while the first holds his whole cap, so this one goes
        // to another identity with a cap of its own.
        bytes memory charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        bytes32 pending = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 10, CAP);
        uint64 pendingReleaseAt = uint64(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id;
        ids[1] = pending;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, pending, pendingReleaseAt));
        boundCompliance.cancelTickets(ids);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Expired));
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), CAP);
    }

    /// @notice An already discarded id and an unknown id are refused by name.
    function test_discardExpiredValidations_RevertWhen_AlreadyDiscardedOrUnknown() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        vm.prank(keeper);
        boundCompliance.cancelTickets(_ids(id));

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.Cancelled))
        );
        boundCompliance.cancelTickets(_ids(id));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, bytes32(uint256(999))));
        boundCompliance.cancelTickets(_ids(bytes32(uint256(999))));
    }

    /// @notice A consumed leg pins the validation: no clock makes it discardable.
    function test_discardExpiredValidations_RevertWhen_AwaitingTheMintLeg() public {
        ERC7786GatewayMock polygonGateway = ERC7786GatewayMock(token.receiptRouteFor(polygon));
        _openEvmChain(token, OPTIMISM, address(_newReceiptBridge(OPTIMISM)));
        bytes memory bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));
        // The validation from setUp already holds bob's whole cap, and the cap is per identity, not per
        // wallet. Raise it so this second one can be issued at all.
        vm.prank(deployer);
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (2 * CAP)), address(cappedRule));
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, CAP);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(crossChain, token, aliceSat, CAP)));
        vm.warp(issuedAt + 100 * VALIDITY_WINDOW);

        assertEq(uint8(boundCompliance.statusOf(crossChain)), uint8(ITickets.TicketStatus.AwaitingMint));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.TicketNotCancellable.selector, crossChain, uint8(ITickets.TicketStatus.AwaitingMint)
            )
        );
        boundCompliance.cancelTickets(_ids(crossChain));
        assertEq(
            IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)),
            2 * CAP,
            "both validations toward bob are still outstanding"
        );
        assertEq(token.onHoldOf(crossChain), CAP, "the burned amount stays in transit");
    }

    /// @notice While the receipt route is closed the ticket's receipt cannot land, so the ticket is not cancelled:
    ///         the away token may have executed it already. Close by hand stays the way out.
    function test_cancelTickets_RevertWhen_TheReceiptRouteIsClosed() public {
        _closeEvmChain(token, POLYGON);
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        vm.prank(keeper);
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.ticketOf(id).status), uint8(ITickets.TicketStatus.Open), "still open");
    }

    /// @notice The same when the receipt bridge is distrusted: nothing can deliver the receipt meanwhile.
    function test_cancelTickets_RevertWhen_TheReceiptBridgeIsDistrusted() public {
        trustedGatewayRegistry.distrustBridge(token.receiptRouteFor(polygon));
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        vm.prank(keeper);
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.ticketOf(id).status), uint8(ITickets.TicketStatus.Open), "still open");
    }

    function _ids(bytes32 one) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = one;
    }

}
