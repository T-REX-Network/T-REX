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
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A receipt that lands after its ticket was cancelled is applied anyway, as the move the away token made:
///      the modules catch up with no live reservation, a rule the move breaks now is announced, and nothing stops
///      or blocks by itself.
contract LateReconciliationTest is InteropSuiteTest {

    uint256 internal constant CAP = 100;
    uint256 internal constant BALANCE = 1000;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    CappedRecipientModule internal cappedRule;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal carolSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        carolSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("carolOnPolygon"));

        cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(cappedRule));
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (CAP)), address(cappedRule));
        vm.stopPrank();
        vm.prank(agent);
        token.unpause();
    }

    /// @notice The full journey: cancel, ask again, then the old receipt lands and is applied regardless. Bob now
    ///         holds more than his cap allows: home says so, and asks toward the chain go on.
    function test_handleSettlement_Success_WhenASameChainSettlementLandsAfterTheDiscard() public {
        bytes32 late = _issue(aliceSat, bobSat, 10, CAP);
        _discard(late);
        bytes32 fresh = _issue(aliceSat, bobSat, 10, CAP);
        assertEq(
            IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)),
            CAP,
            "the fresh one holds the whole cap"
        );
        uint256 index = _liteSettles(polygonGateway, token, _settlement(late, aliceSat, bobSat, CAP));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.MoveBreachedRule(late, polygon, CAP);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(keccak256(aliceSat), keccak256(bobSat), late, aliceSat, bobSat, CAP);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(late, polygon, CAP);
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITickets.TicketStatus.Done));
        assertEq(uint8(boundCompliance.statusOf(fresh)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - CAP);
        assertEq(token.awayBalanceOf(bobSat), CAP);
        assertEq(
            IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)),
            CAP,
            "caught up with no reservation"
        );
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "nor blocks the away chain");
        assertFalse(token.paused(), "nor stops the token");

        // Toward another identity, which has a cap of its own and nothing pending against it.
        assertEq(boundCompliance.ticketOf(_issue(aliceSat, carolSat, 10, 50)).amountMax, 50);
    }

    /// @notice Another body for a half that already has a receipt is a bad receipt: its chain is blocked.
    function test_handleSettlement_Success_WhenALateLegIsReplayed() public {
        bytes32 late = _issue(aliceSat, bobSat, 10, CAP);
        _discard(late);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(late, aliceSat, bobSat, CAP)));
        uint256 replay = _liteSettles(polygonGateway, token, _settlement(late, aliceSat, bobSat, CAP - 1));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(
            late, polygon, CAP - 1, boundCompliance.ticketOf(late).askBlockHash, ITickets.ReceiptRefusal.AnotherBody
        );
        polygonGateway.relay(replay);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(token.paused());
        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), CAP, "applied once");
    }

    /// @notice A late receipt from a blocked away chain never reverts: it waits, and once the block is lifted
    ///         anyone applies it as the move it is.
    function test_receiveReceipt_waits_whenALateReceiptComesFromABlockedChain() public {
        bytes32 late = _issue(aliceSat, bobSat, 10, CAP);
        _discard(late);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(late, aliceSat, bobSat, CAP);
        polygonGateway.relay(_liteSettles(polygonGateway, token, receipt));
        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITickets.TicketStatus.Cancelled), "it waits");

        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(late, polygon, CAP);
        boundCompliance.applyWaitingReceipt(MessageTypesLib.halfKeyOf(late, 0), receipt);

        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), CAP);
    }

    function _issue(bytes memory from, bytes memory to, uint256 min, uint256 max) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), from, to, min, max);
    }

    /// @dev Cancels a ticket to bob once an ask for its receipt went unanswered.
    function _discard(bytes32 id) private {
        _cancelUnanswered(id, bobSat, "");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
    }

}
